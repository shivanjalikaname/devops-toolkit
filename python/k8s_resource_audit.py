#!/usr/bin/env python3
"""Audit CPU/memory requests and limits on Kubernetes workloads.

Looks at the pod templates of Deployments, StatefulSets, DaemonSets, CronJobs and
standalone Jobs (not running pods, so each finding maps to something you can fix
in a manifest). Flags containers the scheduler can't place sensibly and the ones
that will get OOM-killed or starve their neighbours:

    CRIT  no memory request, or no CPU request
    WARN  no memory limit, memory limit below request, limit/request ratio above
          --max-ratio, request above --max-cpu / --max-memory
    INFO  CPU limit set (only with --flag-cpu-limits; CFS throttling is a common
          source of latency spikes)

If the namespace has a LimitRange with a default for the missing value, the
finding is downgraded to INFO, because admission will fill it in.

Needs kubectl on PATH and read access to the workload types plus limitranges,
or a saved `kubectl get ... -o json` dump via --file.

Usage:
    k8s_resource_audit.py [-n NS | -A] [--context CTX] [--file FILE]
                          [--exclude-ns NS ...] [--max-ratio N]
                          [--max-cpu Q] [--max-memory Q] [--flag-cpu-limits]
                          [--min-level LEVEL] [--json]

Examples:
    k8s_resource_audit.py -A
    k8s_resource_audit.py -n payments --max-ratio 2 --flag-cpu-limits
    k8s_resource_audit.py -A --min-level CRIT --json | jq '.findings | length'
    kubectl get deploy,sts,ds,cronjob,job,limitrange -A -o json > dump.json
    k8s_resource_audit.py --file dump.json

Exit codes:
    0  nothing at WARN or above
    1  warnings only
    2  at least one CRIT, kubectl failure, or bad usage
"""

import argparse
import json
import re
import shutil
import subprocess
import sys
from decimal import Decimal, InvalidOperation

INFO, WARN, CRIT = 0, 1, 2
LABELS = {INFO: "INFO", WARN: "WARN", CRIT: "CRIT"}
LEVEL_BY_NAME = {v: k for k, v in LABELS.items()}

WORKLOAD_KINDS = "deployments,statefulsets,daemonsets,cronjobs,jobs"
DEFAULT_EXCLUDED_NS = ["kube-system", "kube-public", "kube-node-lease"]

SUFFIXES = {
    "n": Decimal("1e-9"), "u": Decimal("1e-6"), "m": Decimal("1e-3"),
    "": Decimal(1), "k": Decimal("1e3"), "M": Decimal("1e6"), "G": Decimal("1e9"),
    "T": Decimal("1e12"), "P": Decimal("1e15"), "E": Decimal("1e18"),
    "Ki": Decimal(2) ** 10, "Mi": Decimal(2) ** 20, "Gi": Decimal(2) ** 30,
    "Ti": Decimal(2) ** 40, "Pi": Decimal(2) ** 50, "Ei": Decimal(2) ** 60,
}
QUANTITY_RE = re.compile(r"^([+-]?[0-9.]+(?:[eE][+-]?[0-9]+)?)(Ki|Mi|Gi|Ti|Pi|Ei|[numkMGTPE]?)$")


def parse_quantity(value):
    """Kubernetes resource quantity -> Decimal base units (cores or bytes)."""
    if value is None:
        return None
    m = QUANTITY_RE.match(str(value).strip())
    if not m:
        raise ValueError(f"unparseable quantity: {value!r}")
    try:
        return Decimal(m.group(1)) * SUFFIXES[m.group(2)]
    except InvalidOperation:
        raise ValueError(f"unparseable quantity: {value!r}") from None


def human(resource, value):
    if resource == "cpu":
        return f"{value * 1000:.0f}m" if value < 1 else f"{value.normalize():f}"
    for unit in ("Gi", "Mi", "Ki"):
        if value >= SUFFIXES[unit]:
            return f"{(value / SUFFIXES[unit]):.1f}{unit}".replace(".0" + unit, unit)
    return f"{value:f}"


def kubectl(args, context):
    cmd = ["kubectl"] + (["--context", context] if context else []) + args
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        # client-go repeats discovery errors; the last line is the useful one.
        lines = [ln for ln in proc.stderr.splitlines() if ln.strip()]
        raise RuntimeError(f"{' '.join(cmd)}: {lines[-1] if lines else 'exit ' + str(proc.returncode)}")
    return json.loads(proc.stdout).get("items", [])


def load_objects(args):
    if args.file:
        with open(args.file, encoding="utf-8") as fh:
            doc = json.load(fh)
        return doc.get("items", [doc]) if isinstance(doc, dict) else doc

    if not shutil.which("kubectl"):
        raise RuntimeError("kubectl not found on PATH (or use --file)")
    scope = ["-A"] if args.all_namespaces else (["-n", args.namespace] if args.namespace else [])
    items = kubectl(["get", WORKLOAD_KINDS, "-o", "json"] + scope, args.context)
    try:
        items += kubectl(["get", "limitranges", "-o", "json"] + scope, args.context)
    except RuntimeError as exc:
        # Not fatal: we just lose the downgrade-to-INFO logic.
        print(f"warning: could not list limitranges ({exc}); defaults not considered", file=sys.stderr)
    return items


def limitrange_defaults(objects):
    """namespace -> {("requests"|"limits", resource): True} for container defaults."""
    defaults = {}
    for obj in objects:
        if obj.get("kind") != "LimitRange":
            continue
        ns = obj["metadata"].get("namespace", "default")
        for lim in obj.get("spec", {}).get("limits", []):
            if lim.get("type") != "Container":
                continue
            for res in lim.get("defaultRequest", {}):
                defaults.setdefault(ns, set()).add(("requests", res))
            for res in lim.get("default", {}):
                # A default limit also becomes the request when none is given.
                defaults.setdefault(ns, set()).update({("limits", res), ("requests", res)})
    return defaults


def pod_spec(obj):
    kind = obj.get("kind")
    spec = obj.get("spec", {})
    if kind == "CronJob":
        return spec.get("jobTemplate", {}).get("spec", {}).get("template", {}).get("spec", {})
    if kind in ("Deployment", "StatefulSet", "DaemonSet", "Job", "ReplicaSet"):
        return spec.get("template", {}).get("spec", {})
    return None


def owned_by_cronjob(obj):
    return any(ref.get("kind") == "CronJob" for ref in obj["metadata"].get("ownerReferences", []))


def audit_container(container, ns_defaults, args):
    res = container.get("resources", {}) or {}
    req = res.get("requests", {}) or {}
    lim = res.get("limits", {}) or {}
    findings = []

    def add(level, msg, defaulted_by=None):
        if defaulted_by and defaulted_by in ns_defaults:
            level, msg = INFO, msg + " (LimitRange default applies)"
        findings.append((level, msg))

    # Kubernetes copies a limit into the request when only the limit is set.
    for resource in ("memory", "cpu"):
        if resource not in req and resource not in lim:
            add(CRIT, f"no {resource} request", ("requests", resource))

    if "memory" not in lim:
        add(WARN, "no memory limit", ("limits", "memory"))
    if "cpu" in lim and args.flag_cpu_limits:
        add(INFO, f"cpu limit {lim['cpu']} (throttling risk)")

    for resource in ("cpu", "memory"):
        try:
            r = parse_quantity(req.get(resource, lim.get(resource)))
            l = parse_quantity(lim.get(resource))
        except ValueError as exc:
            add(WARN, str(exc))
            continue
        if r is not None and l is not None:
            if l < r:
                add(WARN, f"{resource} limit {lim[resource]} below request {req[resource]}")
            elif r > 0 and l / r > args.max_ratio:
                add(WARN, f"{resource} limit/request ratio {l / r:.1f}x > {args.max_ratio:g}x")
        cap = args.max_cpu if resource == "cpu" else args.max_memory
        if cap is not None and r is not None and r > cap:
            add(WARN, f"{resource} request {human(resource, r)} above cap {human(resource, cap)}")
    return findings


def audit(objects, args):
    defaults = limitrange_defaults(objects)
    excluded = set(args.exclude_ns)
    results = []
    for obj in objects:
        kind = obj.get("kind")
        if kind == "LimitRange" or (kind == "Job" and owned_by_cronjob(obj)):
            continue
        spec = pod_spec(obj)
        if spec is None:
            continue
        meta = obj["metadata"]
        ns = meta.get("namespace", "default")
        if ns in excluded:
            continue
        groups = [("", spec.get("containers", [])), ("init:", spec.get("initContainers", []))]
        for prefix, containers in groups:
            for c in containers:
                for level, msg in audit_container(c, defaults.get(ns, set()), args):
                    if level >= args.min_level:
                        results.append({
                            "level": LABELS[level], "namespace": ns, "kind": kind,
                            "name": meta["name"], "container": prefix + c.get("name", "?"),
                            "message": msg,
                        })
    order = {"CRIT": 0, "WARN": 1, "INFO": 2}
    results.sort(key=lambda f: (order[f["level"]], f["namespace"], f["kind"], f["name"], f["container"]))
    return results


def print_table(findings):
    if not findings:
        print("No findings.")
        return
    rows = [(f["level"], f["namespace"], f"{f['kind']}/{f['name']}", f["container"], f["message"]) for f in findings]
    head = ("LEVEL", "NAMESPACE", "WORKLOAD", "CONTAINER", "FINDING")
    widths = [max(len(r[i]) for r in rows + [head]) for i in range(4)]
    for r in [head] + rows:
        print("  ".join(r[i].ljust(widths[i]) for i in range(4)) + "  " + r[4])
    counts = {lvl: sum(f["level"] == lvl for f in findings) for lvl in ("CRIT", "WARN", "INFO")}
    workloads = len({(f["namespace"], f["kind"], f["name"]) for f in findings})
    print(f"\n{counts['CRIT']} critical, {counts['WARN']} warning, {counts['INFO']} info across {workloads} workload(s)")


def parse_args(argv):
    p = argparse.ArgumentParser(
        description="Audit CPU/memory requests and limits on Kubernetes workloads.",
        epilog="Exit codes: 0 OK, 1 warnings, 2 critical or error.")
    scope = p.add_mutually_exclusive_group()
    scope.add_argument("-n", "--namespace", help="namespace to audit (default: current context namespace)")
    scope.add_argument("-A", "--all-namespaces", action="store_true", help="audit every namespace")
    p.add_argument("--context", help="kubeconfig context to use")
    p.add_argument("--file", help="read a kubectl -o json dump instead of calling kubectl")
    p.add_argument("--exclude-ns", nargs="*", default=DEFAULT_EXCLUDED_NS, metavar="NS",
                   help="namespaces to skip (default: %(default)s; pass with no value to include all)")
    p.add_argument("--max-ratio", type=float, default=4.0,
                   help="warn when limit/request exceeds this (default: %(default)s)")
    p.add_argument("--max-cpu", help="warn on CPU requests above this quantity, e.g. 4 or 3500m")
    p.add_argument("--max-memory", help="warn on memory requests above this quantity, e.g. 8Gi")
    p.add_argument("--flag-cpu-limits", action="store_true", help="report containers with CPU limits as INFO")
    p.add_argument("--min-level", choices=list(LEVEL_BY_NAME), default="WARN",
                   help="lowest level to report (default: %(default)s)")
    p.add_argument("--json", action="store_true", help="machine-readable output")
    args = p.parse_args(argv)

    if args.max_ratio < 1:
        p.error("--max-ratio must be >= 1")
    try:
        args.max_cpu = parse_quantity(args.max_cpu)
        args.max_memory = parse_quantity(args.max_memory)
    except ValueError as exc:
        p.error(str(exc))
    args.min_level = LEVEL_BY_NAME[args.min_level]
    # --flag-cpu-limits is pointless if INFO is filtered out.
    if args.flag_cpu_limits and args.min_level > INFO:
        args.min_level = INFO
    return args


def main(argv=None):
    args = parse_args(argv)
    try:
        objects = load_objects(args)
    except (RuntimeError, OSError, json.JSONDecodeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return CRIT

    findings = audit(objects, args)
    if args.json:
        json.dump({"findings": findings}, sys.stdout, indent=2)
        print()
    else:
        print_table(findings)

    levels = {f["level"] for f in findings}
    if "CRIT" in levels:
        return CRIT
    return WARN if "WARN" in levels else 0


if __name__ == "__main__":
    sys.exit(main())
