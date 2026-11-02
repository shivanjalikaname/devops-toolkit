#!/usr/bin/env python3
"""Validate a .env file against its .env.example template.

Catches the usual deploy-day breakage before the app does: keys that were added
to the template but never set, empty values, leftover placeholders, duplicates,
and lines the dotenv loader will silently ignore. Values are never printed, so
the output is safe to keep in CI logs.

Template annotations (comment lines directly above a key in the template):
    # @optional          key may be missing or empty
    # @type: int         one of: int, bool, port, url, email

Usage:
    env_check.py [--env FILE] [--template FILE] [--strict] [--json]

Examples:
    env_check.py                                   # .env vs .env.example in cwd
    env_check.py --env deploy/prod.env --template .env.example --strict
    env_check.py --json | jq '.findings[] | select(.level == "CRIT")'

Exit codes:
    0  everything matches the template
    1  warnings only (extra keys, duplicates, placeholders)
    2  missing/empty required keys, bad types, unparseable lines, or bad usage
"""

import argparse
import json
import re
import sys

OK, WARN, CRIT = 0, 1, 2
LABELS = {OK: "OK", WARN: "WARN", CRIT: "CRIT"}

KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
PLACEHOLDER_RE = re.compile(r"^(changeme|change_me|todo|fixme|xxx+|placeholder|your[_-].*|<.*>|\$\{.*\})$", re.I)

TYPE_CHECKS = {
    "int": lambda v: re.fullmatch(r"-?\d+", v) is not None,
    "bool": lambda v: v.lower() in {"true", "false", "1", "0", "yes", "no", "on", "off"},
    "port": lambda v: v.isdigit() and 1 <= int(v) <= 65535,
    "url": lambda v: re.match(r"^[a-z][a-z0-9+.-]*://[^\s/]+", v, re.I) is not None,
    "email": lambda v: re.fullmatch(r"[^@\s]+@[^@\s]+\.[^@\s]+", v) is not None,
}


class EnvFile:
    def __init__(self):
        self.values = {}       # key -> value (last one wins, like most loaders)
        self.lines = {}        # key -> [line numbers]
        self.meta = {}         # key -> {"optional": bool, "type": str|None}
        self.malformed = []    # (line number, reason)


def parse_value(raw):
    raw = raw.strip()
    if raw[:1] in ("'", '"'):
        quote = raw[0]
        end = raw.find(quote, 1)
        if end == -1:
            return None, "unterminated quote"
        rest = raw[end + 1:].strip()
        if rest and not rest.startswith("#"):
            return None, "trailing characters after quoted value"
        return raw[1:end], None
    # Unquoted: " #" starts a comment, a bare # inside the value does not.
    return re.split(r"\s+#", raw, maxsplit=1)[0].strip(), None


def load(path):
    env = EnvFile()
    pending = {"optional": False, "type": None}
    with open(path, encoding="utf-8-sig") as fh:
        for num, line in enumerate(fh, 1):
            stripped = line.strip()
            if not stripped:
                pending = {"optional": False, "type": None}
                continue
            if stripped.startswith("#"):
                note = stripped.lstrip("#").strip()
                if note.lower() == "@optional":
                    pending["optional"] = True
                elif note.lower().startswith("@type:"):
                    pending["type"] = note.split(":", 1)[1].strip().lower()
                continue

            if stripped.startswith("export "):
                stripped = stripped[len("export "):].lstrip()
            key, sep, raw = stripped.partition("=")
            key = key.strip()
            if not sep:
                env.malformed.append((num, "no '=' found"))
                continue
            if not KEY_RE.match(key):
                env.malformed.append((num, f"invalid key name {key!r}"))
                continue
            value, err = parse_value(raw)
            if err:
                env.malformed.append((num, f"{key}: {err}"))
                continue

            env.values[key] = value
            env.lines.setdefault(key, []).append(num)
            env.meta[key] = pending
            pending = {"optional": False, "type": None}
    return env


def validate(env, template):
    findings = []

    def add(level, key, message):
        findings.append({"level": level, "key": key, "message": message})

    for num, reason in env.malformed:
        add(CRIT, None, f"line {num}: {reason} (loader will skip it)")
    for num, reason in template.malformed:
        add(WARN, None, f"template line {num}: {reason}")

    for key, meta in template.meta.items():
        if meta["type"] and meta["type"] not in TYPE_CHECKS:
            add(WARN, key, f"unknown @type {meta['type']!r} in template")
        if key not in env.values:
            if not meta["optional"]:
                add(CRIT, key, "missing (required by template)")
            continue
        value = env.values[key]
        if value == "":
            if not meta["optional"]:
                add(CRIT, key, "empty value")
            continue
        check = TYPE_CHECKS.get(meta["type"])
        if check and not check(value):
            add(CRIT, key, f"not a valid {meta['type']}")
        if PLACEHOLDER_RE.match(value):
            add(WARN, key, "looks like a placeholder")

    for key, nums in env.lines.items():
        if len(nums) > 1:
            add(WARN, key, f"defined {len(nums)} times (lines {', '.join(map(str, nums))}); last one wins")
        if key not in template.values:
            add(WARN, key, "not in template (typo or undocumented setting?)")

    return findings


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--env", default=".env", help="env file to check (default .env)")
    parser.add_argument("--template", default=".env.example", help="template file (default .env.example)")
    parser.add_argument("--strict", action="store_true", help="treat warnings as critical")
    parser.add_argument("--json", action="store_true", help="print JSON instead of text")
    args = parser.parse_args()

    try:
        env = load(args.env)
        template = load(args.template)
    except OSError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return CRIT
    if not template.values:
        print(f"error: template {args.template} defines no keys", file=sys.stderr)
        return CRIT

    findings = validate(env, template)
    if args.strict:
        for f in findings:
            f["level"] = CRIT
    status = max((f["level"] for f in findings), default=OK)

    if args.json:
        print(json.dumps({
            "env": args.env,
            "template": args.template,
            "status": LABELS[status],
            "findings": [dict(f, level=LABELS[f["level"]]) for f in findings],
        }, indent=2))
    else:
        for f in sorted(findings, key=lambda f: (-f["level"], f["key"] or "")):
            where = f["key"] or "-"
            print(f"{LABELS[f['level']]:<5} {where:<28} {f['message']}")
        print(f"{LABELS[status]}: {args.env} checked against {args.template}, "
              f"{len(template.values)} template keys, {len(findings)} finding(s)")
    return status


if __name__ == "__main__":
    sys.exit(main())
