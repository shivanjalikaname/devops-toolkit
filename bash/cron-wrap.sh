#!/usr/bin/env bash
#
# cron-wrap.sh - Run a cron job with locking, a timeout, logging and failure alerts.
#
# Most cron incidents are the same three problems: two copies of a job overlap,
# a job hangs forever, or a job fails and nobody notices. This wraps any command
# and handles all three.
#
# Usage:
#   cron-wrap.sh -n NAME [-t TIMEOUT] [-l LOG_DIR] [-w WEBHOOK_URL] -- COMMAND [ARGS...]
#
#   -n NAME     job name, used for the lock and log file (required)
#   -t TIMEOUT  kill the job after this long, e.g. 30m, 2h (default: 1h)
#   -l LOG_DIR  where to write NAME.log (default: /var/log/cron-wrap)
#   -w URL      Slack/Teams-compatible webhook to POST to on failure
#               (default: $CRON_WRAP_WEBHOOK if set)
#
# Example crontab entry:
#   */15 * * * * /opt/devops-toolkit/bash/cron-wrap.sh -n sync-reports -t 10m -- /opt/jobs/sync.sh --full
#
# Exit codes: the job's own exit code, 124 on timeout, 75 if the previous run is
# still going (EX_TEMPFAIL, so it isn't treated as a failure), 2 on bad usage.

set -euo pipefail

NAME=""
TIMEOUT="1h"
LOG_DIR="/var/log/cron-wrap"
WEBHOOK="${CRON_WRAP_WEBHOOK:-}"

usage() {
  sed -n '3,23p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

while getopts ":n:t:l:w:h" opt; do
  case "$opt" in
    n) NAME="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    l) LOG_DIR="$OPTARG" ;;
    w) WEBHOOK="$OPTARG" ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))
[[ "${1:-}" == "--" ]] && shift
[[ -n "$NAME" && $# -ge 1 ]] || usage
[[ "$NAME" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "job name may only contain letters, digits, . _ -" >&2; exit 2; }

mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/$NAME.log"
LOCK="${TMPDIR:-/tmp}/cron-wrap.$NAME.lock"

log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$NAME" "$*" >> "$LOG"; }

# mkdir is atomic everywhere, unlike flock which isn't on every box.
# The PID file lets us recover from a lock left behind by a killed run.
if ! mkdir "$LOCK" 2>/dev/null; then
  old_pid=$(cat "$LOCK/pid" 2>/dev/null || true)
  if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
    log "previous run (pid $old_pid) still running, skipping"
    exit 75
  fi
  log "removing stale lock from pid ${old_pid:-unknown}"
  rm -rf "$LOCK"
  mkdir "$LOCK"
fi
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

alert() {
  [[ -n "$WEBHOOK" ]] || return 0
  local text="cron job *$NAME* on $(hostname) $1. Last lines:\n\`\`\`$(tail -n 15 "$LOG" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "%s\\n", $0}')\`\`\`"
  curl -fsS -m 10 -H 'Content-Type: application/json' \
    -d "{\"text\": \"$text\"}" "$WEBHOOK" >/dev/null 2>&1 \
    || log "warning: failed to send alert"
}

log "start: $*"
start=$(date +%s)
set +e
timeout --kill-after=30s "$TIMEOUT" "$@" >> "$LOG" 2>&1
rc=$?
set -e
duration=$(( $(date +%s) - start ))

if (( rc == 0 )); then
  log "ok in ${duration}s"
elif (( rc == 124 || rc == 137 )); then
  log "TIMEOUT after $TIMEOUT"
  alert "timed out after $TIMEOUT"
  rc=124
else
  log "FAILED with exit code $rc after ${duration}s"
  alert "failed with exit code $rc"
fi

exit "$rc"
