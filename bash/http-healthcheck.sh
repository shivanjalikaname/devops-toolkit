#!/usr/bin/env bash
#
# http-healthcheck.sh - Check one or more HTTP endpoints with retries and timeouts.
#
# Usage:
#   ./http-healthcheck.sh [-r retries] [-t timeout] [-d delay] [-e expected_status] URL [URL...]
#
# Examples:
#   ./http-healthcheck.sh https://example.com
#   ./http-healthcheck.sh -r 5 -t 3 -e 200 https://api.example.com/health http://localhost:8080/ready
#
# Exit codes:
#   0  all endpoints healthy
#   1  at least one endpoint unhealthy
#   2  bad usage
#
# Handy as a Kubernetes/Docker readiness gate or as a post-deploy smoke test in CI.

set -euo pipefail

RETRIES=3
TIMEOUT=5
DELAY=2
EXPECTED=200

usage() {
  sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

while getopts ":r:t:d:e:h" opt; do
  case "$opt" in
    r) RETRIES="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    d) DELAY="$OPTARG" ;;
    e) EXPECTED="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))

[[ $# -ge 1 ]] || usage
command -v curl >/dev/null 2>&1 || { echo "error: curl is required" >&2; exit 2; }

check_url() {
  local url="$1" attempt status elapsed
  for ((attempt = 1; attempt <= RETRIES; attempt++)); do
    # %{http_code} is 000 when the connection itself fails
    read -r status elapsed < <(curl -s -o /dev/null -L \
      --max-time "$TIMEOUT" \
      -w '%{http_code} %{time_total}' "$url" || echo "000 0")
    if [[ "$status" == "$EXPECTED" ]]; then
      printf '[ OK ] %-50s status=%s time=%ss attempt=%d\n' "$url" "$status" "$elapsed" "$attempt"
      return 0
    fi
    printf '[WARN] %-50s status=%s attempt=%d/%d\n' "$url" "$status" "$attempt" "$RETRIES" >&2
    ((attempt < RETRIES)) && sleep "$DELAY"
  done
  printf '[FAIL] %-50s expected=%s\n' "$url" "$EXPECTED" >&2
  return 1
}

failed=0
for url in "$@"; do
  check_url "$url" || failed=$((failed + 1))
done

echo "---"
echo "checked=$# failed=$failed"
((failed == 0))
