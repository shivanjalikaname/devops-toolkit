#!/usr/bin/env bash
#
# log-cleanup.sh - Compress and expire application logs that logrotate doesn't manage.
#
# Usage:
#   ./log-cleanup.sh [-c COMPRESS_DAYS] [-r RETAIN_DAYS] [-p PATTERN] [-n] DIR [DIR...]
#
#   -c DAYS     gzip logs not modified for DAYS days (default: 1)
#   -r DAYS     delete logs (compressed or not) older than DAYS days (default: 30)
#   -p PATTERN  file name pattern to match (default: *.log*)
#   -n          dry run
#
# Examples:
#   ./log-cleanup.sh /var/log/myapp
#   ./log-cleanup.sh -c 2 -r 14 -p '*.out' /opt/tomcat/logs /opt/jobs/logs

set -euo pipefail

COMPRESS_DAYS=1
RETAIN_DAYS=30
PATTERN='*.log*'
DRY_RUN=false

usage() {
  sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

while getopts ":c:r:p:nh" opt; do
  case "$opt" in
    c) COMPRESS_DAYS="$OPTARG" ;;
    r) RETAIN_DAYS="$OPTARG" ;;
    p) PATTERN="$OPTARG" ;;
    n) DRY_RUN=true ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))
[[ $# -ge 1 ]] || usage

before_kb=0; after_kb=0
for dir in "$@"; do
  [[ -d "$dir" ]] || { echo "skip: $dir is not a directory" >&2; continue; }
  before_kb=$((before_kb + $(du -sk "$dir" | cut -f1)))

  # Delete expired files first so we don't waste time compressing them
  while IFS= read -r -d '' f; do
    echo "delete   $f"
    $DRY_RUN || rm -f -- "$f"
  done < <(find "$dir" -type f -name "$PATTERN" -mtime "+$RETAIN_DAYS" -print0)

  # Compress older plain logs; skip files still held open by a process
  while IFS= read -r -d '' f; do
    if command -v fuser >/dev/null && fuser -s "$f" 2>/dev/null; then
      echo "in-use   $f (skipped)"
      continue
    fi
    echo "compress $f"
    $DRY_RUN || gzip -9 -- "$f"
  done < <(find "$dir" -type f -name "$PATTERN" ! -name '*.gz' \
    -mtime "+$((COMPRESS_DAYS - 1))" ! -mtime "+$RETAIN_DAYS" -print0)

  after_kb=$((after_kb + $(du -sk "$dir" | cut -f1)))
done

if ! $DRY_RUN; then
  echo "---"
  echo "freed $(( (before_kb - after_kb) / 1024 )) MB"
fi
