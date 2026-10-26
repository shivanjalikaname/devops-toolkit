#!/usr/bin/env python3
"""Check TLS certificate expiry for a list of hosts.

Expired or soon-to-expire certificates are one of the most common causes of
avoidable outages. Run this from cron or CI and alert on a non-zero exit code.

Usage:
    ssl_expiry_check.py [--warn DAYS] [--crit DAYS] [--json] HOST[:PORT] ...
    ssl_expiry_check.py --file hosts.txt

Exit codes:
    0  all certificates OK
    1  at least one certificate within the warning window
    2  at least one certificate expired, within the critical window, or unreachable
"""

import argparse
import json
import socket
import ssl
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

OK, WARN, CRIT = 0, 1, 2
LABELS = {OK: "OK", WARN: "WARN", CRIT: "CRIT"}


def parse_target(target):
    host, _, port = target.strip().partition(":")
    return host, int(port or 443)


def check(target, warn_days, crit_days, timeout):
    host, port = parse_target(target)
    result = {"host": host, "port": port}
    try:
        ctx = ssl.create_default_context()
        with socket.create_connection((host, port), timeout=timeout) as sock:
            with ctx.wrap_socket(sock, server_hostname=host) as tls:
                cert = tls.getpeercert()
    except (OSError, ssl.SSLError) as exc:
        result.update(status=CRIT, error=str(exc))
        return result

    expires = datetime.fromtimestamp(ssl.cert_time_to_seconds(cert["notAfter"]), timezone.utc)
    days_left = (expires - datetime.now(timezone.utc)).days
    issuer = dict(x[0] for x in cert.get("issuer", ())).get("organizationName", "?")

    if days_left <= crit_days:
        status = CRIT
    elif days_left <= warn_days:
        status = WARN
    else:
        status = OK
    result.update(status=status, expires=expires.isoformat(), days_left=days_left, issuer=issuer)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("targets", nargs="*", help="host or host:port")
    parser.add_argument("--file", help="file with one host[:port] per line (# for comments)")
    parser.add_argument("--warn", type=int, default=30, help="warning threshold in days (default 30)")
    parser.add_argument("--crit", type=int, default=7, help="critical threshold in days (default 7)")
    parser.add_argument("--timeout", type=float, default=5.0, help="connect timeout in seconds")
    parser.add_argument("--json", action="store_true", help="print JSON instead of a table")
    args = parser.parse_args()

    targets = list(args.targets)
    if args.file:
        with open(args.file, encoding="utf-8") as fh:
            targets += [ln.strip() for ln in fh if ln.strip() and not ln.startswith("#")]
    if not targets:
        parser.error("no hosts given")

    with ThreadPoolExecutor(max_workers=min(16, len(targets))) as pool:
        results = list(pool.map(lambda t: check(t, args.warn, args.crit, args.timeout), targets))

    if args.json:
        print(json.dumps(results, indent=2))
    else:
        for r in sorted(results, key=lambda r: r.get("days_left", -1)):
            target = f"{r['host']}:{r['port']}"
            if "error" in r:
                print(f"[{LABELS[r['status']]:4}] {target:40} ERROR {r['error']}")
            else:
                print(f"[{LABELS[r['status']]:4}] {target:40} {r['days_left']:>4} days  "
                      f"expires {r['expires'][:10]}  issuer {r['issuer']}")

    return max(r["status"] for r in results)


if __name__ == "__main__":
    sys.exit(main())
