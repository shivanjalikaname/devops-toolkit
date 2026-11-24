#!/usr/bin/env python3
"""TCP reachability matrix: is this port open (or closed) from where I'm standing?

Built for the questions that come up after every firewall or security group
change: can the app subnet reach the database, is SSH really closed to the
world, which of the three IPs behind that DNS name is the one dropping packets.

Each target is HOST:PORT with an optional expectation:

    db.example.com:5432            must accept a TCP connection (default)
    bastion.example.com:22/closed  must NOT accept one (refused or filtered both pass)
    [2001:db8::10]:443             IPv6 literal

Failures are classified so you know where to look:

    dns       name did not resolve (fails /closed targets too: likely a typo)
    refused   host answered with RST - reachable, nothing listening
    timeout   no answer - firewall, security group or routing drop
    error     anything else (unreachable network, etc.)

Usage:
    port_check.py [options] TARGET ...
    port_check.py --file targets.txt [--json]

Options:
    -f, --file FILE     read targets from FILE (one per line, '#' comments,
                        optional trailing label: "db.example.com:5432 primary-db")
    -t, --timeout SEC   connect timeout per attempt (default 3)
    -r, --retries N     extra attempts before declaring a failure (default 1)
    --slow MS           mark open ports slower than MS as WARN (default: off)
    -a, --all-addresses test every resolved address, not just the first that works
    -4 / -6             restrict resolution to IPv4 / IPv6
    -w, --workers N     parallel checks (default 32)
    --json              machine-readable output
    -q, --quiet         only print problems

Examples:
    port_check.py db.example.com:5432 cache.example.com:6379
    port_check.py -a -t 2 api.example.com:443
    port_check.py -f prod-egress.txt --slow 150 --json > report.json
    port_check.py 203.0.113.10:22/closed 203.0.113.10:3306/closed

Exit codes:
    0  every target matched its expectation
    1  all matched, but at least one was slower than --slow
    2  at least one target did not match, or bad usage
"""

import argparse
import json
import socket
import sys
import time
from concurrent.futures import ThreadPoolExecutor

OK, WARN, CRIT = 0, 1, 2
LABELS = {OK: "OK", WARN: "WARN", CRIT: "FAIL"}


class TargetError(ValueError):
    pass


def parse_target(raw):
    """Return (host, port, expect_open, label) from 'host:port[/closed] [label]'."""
    spec, _, label = raw.strip().partition(" ")
    expect_open = True
    if "/" in spec:
        spec, _, mode = spec.rpartition("/")
        if mode not in ("open", "closed"):
            raise TargetError(f"bad expectation '{mode}' in '{raw.strip()}' (use /open or /closed)")
        expect_open = mode == "open"

    if spec.startswith("["):
        host, sep, port = spec[1:].partition("]:")
        if not sep:
            raise TargetError(f"bad IPv6 target '{spec}' (use [addr]:port)")
    else:
        host, sep, port = spec.rpartition(":")
        if not sep or not host:
            raise TargetError(f"missing port in '{spec}'")
        if ":" in host:
            raise TargetError(f"IPv6 literal must be bracketed: '{spec}'")

    if not port.isdigit() or not 0 < int(port) < 65536:
        raise TargetError(f"bad port in '{spec}'")
    return host, int(port), expect_open, label.strip() or None


def resolve(host, port, family):
    infos = socket.getaddrinfo(host, port, family, socket.SOCK_STREAM)
    seen, addrs = set(), []
    for fam, _, _, _, sockaddr in infos:
        if sockaddr[0] not in seen:
            seen.add(sockaddr[0])
            addrs.append((fam, sockaddr))
    return addrs


def probe(fam, sockaddr, timeout, retries):
    """One address. Returns (state, latency_ms, detail)."""
    state, detail = "error", ""
    for _ in range(retries + 1):
        sock = socket.socket(fam, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        start = time.perf_counter()
        try:
            sock.connect(sockaddr)
            return "open", round((time.perf_counter() - start) * 1000, 1), ""
        except ConnectionRefusedError:
            # A refusal is a definitive answer; retrying won't change it.
            return "refused", None, ""
        except socket.timeout:
            state, detail = "timeout", f"no response in {timeout:g}s"
        except OSError as exc:
            state, detail = "error", exc.strerror or str(exc)
        finally:
            sock.close()
    return state, None, detail


def check(target, args):
    host, port, expect_open = target["host"], target["port"], target["expect_open"]
    result = dict(target, addresses=[], latency_ms=None, state=None, detail="")
    try:
        addrs = resolve(host, port, args.family)
    except socket.gaierror as exc:
        result.update(state="dns", status=CRIT, detail=exc.strerror or str(exc))
        return result

    for fam, sockaddr in addrs:
        state, latency, detail = probe(fam, sockaddr, args.timeout, args.retries)
        result["addresses"].append(
            {"address": sockaddr[0], "state": state, "latency_ms": latency, "detail": detail}
        )
        if state == "open" and not args.all_addresses:
            break

    states = [a["state"] for a in result["addresses"]]
    if expect_open:
        if args.all_addresses:
            good = all(s == "open" for s in states)
        else:
            good = "open" in states
    else:
        good = "open" not in states

    open_lat = [a["latency_ms"] for a in result["addresses"] if a["state"] == "open"]
    result["latency_ms"] = max(open_lat) if open_lat else None
    if "open" in states and (not args.all_addresses or len(set(states)) == 1):
        result["state"] = "open"
    elif len(set(states)) == 1:
        result["state"] = states[0]
    else:
        result["state"] = "mixed"
    result["detail"] = next((a["detail"] for a in result["addresses"] if a["detail"]), "")

    if not good:
        result["status"] = CRIT
    elif expect_open and args.slow and result["latency_ms"] and result["latency_ms"] > args.slow:
        result["status"] = WARN
        result["detail"] = f"slower than {args.slow:g}ms"
    else:
        result["status"] = OK
    return result


def load_targets(args):
    lines = list(args.targets)
    if args.file:
        try:
            with open(args.file, encoding="utf-8") as fh:
                lines += [ln.split("#", 1)[0] for ln in fh]
        except OSError as exc:
            raise TargetError(f"cannot read {args.file}: {exc.strerror}") from exc

    targets = []
    for ln in lines:
        if not ln.strip():
            continue
        host, port, expect_open, label = parse_target(ln)
        targets.append({"host": host, "port": port, "expect_open": expect_open, "label": label})
    return targets


def print_table(results, quiet):
    rows = []
    for r in results:
        if quiet and r["status"] == OK:
            continue
        name = f"[{r['host']}]" if ":" in r["host"] else r["host"]
        lat = f"{r['latency_ms']}ms" if r["latency_ms"] is not None else "-"
        note = r["detail"]
        if r["state"] == "mixed":
            note = ", ".join(f"{a['address']}={a['state']}" for a in r["addresses"])
        rows.append((
            LABELS[r["status"]],
            f"{name}:{r['port']}",
            "open" if r["expect_open"] else "closed",
            r["state"],
            lat,
            r["label"] or "",
            note,
        ))
    if not rows:
        return
    header = ("STATUS", "TARGET", "EXPECT", "STATE", "LATENCY", "LABEL", "NOTE")
    widths = [max(len(str(c)) for c in col) for col in zip(header, *rows)]
    for row in (header, *rows):
        print("  ".join(str(c).ljust(w) for c, w in zip(row, widths)).rstrip())


def main():
    p = argparse.ArgumentParser(
        description="TCP reachability check with open/closed expectations.",
        epilog="Target format: HOST:PORT[/open|/closed]. See the file header for details.",
    )
    p.add_argument("targets", nargs="*", metavar="TARGET")
    p.add_argument("-f", "--file")
    p.add_argument("-t", "--timeout", type=float, default=3.0)
    p.add_argument("-r", "--retries", type=int, default=1)
    p.add_argument("--slow", type=float, default=0, metavar="MS")
    p.add_argument("-a", "--all-addresses", action="store_true")
    fam = p.add_mutually_exclusive_group()
    fam.add_argument("-4", dest="family", action="store_const", const=socket.AF_INET)
    fam.add_argument("-6", dest="family", action="store_const", const=socket.AF_INET6)
    p.add_argument("-w", "--workers", type=int, default=32)
    p.add_argument("--json", action="store_true")
    p.add_argument("-q", "--quiet", action="store_true")
    args = p.parse_args()
    args.family = args.family or socket.AF_UNSPEC

    if args.timeout <= 0 or args.retries < 0 or args.workers < 1:
        p.error("--timeout must be > 0, --retries >= 0, --workers >= 1")

    try:
        targets = load_targets(args)
    except TargetError as exc:
        p.error(str(exc))
    if not targets:
        p.error("no targets given (pass TARGET arguments or --file)")

    with ThreadPoolExecutor(max_workers=min(args.workers, len(targets))) as pool:
        results = list(pool.map(lambda t: check(t, args), targets))

    worst = max(r["status"] for r in results)
    if args.json:
        for r in results:
            r["status"] = LABELS[r["status"]]
        json.dump(results, sys.stdout, indent=2)
        print()
    else:
        print_table(results, args.quiet)
        sys.stdout.flush()
        failed = sum(1 for r in results if r["status"] == CRIT)
        if failed or not args.quiet:
            print(f"\n{len(results)} checked, {failed} failed", file=sys.stderr)
    return worst


if __name__ == "__main__":
    sys.exit(main())
