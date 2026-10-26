#!/usr/bin/env bash
#
# pg-backup.sh - Compressed PostgreSQL backups with retention and optional S3 upload.
#
# Usage:
#   ./pg-backup.sh -d DATABASE [-o OUTPUT_DIR] [-k KEEP_DAYS] [-s s3://bucket/prefix]
#
# Connection settings come from the standard libpq environment variables
# (PGHOST, PGPORT, PGUSER, PGPASSWORD) or ~/.pgpass, so no secrets on the command line.
#
# Examples:
#   PGHOST=db.internal PGUSER=backup ./pg-backup.sh -d orders
#   ./pg-backup.sh -d orders -o /var/backups/pg -k 14 -s s3://acme-backups/postgres
#
# Cron (daily at 02:30):
#   30 2 * * * /opt/devops-toolkit/bash/pg-backup.sh -d orders >> /var/log/pg-backup.log 2>&1

set -euo pipefail

OUTPUT_DIR="/var/backups/postgres"
KEEP_DAYS=7
S3_URI=""
DB=""

log() { printf '%s [pg-backup] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

usage() {
  sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

while getopts ":d:o:k:s:h" opt; do
  case "$opt" in
    d) DB="$OPTARG" ;;
    o) OUTPUT_DIR="$OPTARG" ;;
    k) KEEP_DAYS="$OPTARG" ;;
    s) S3_URI="${OPTARG%/}" ;;
    *) usage ;;
  esac
done

[[ -n "$DB" ]] || usage
command -v pg_dump >/dev/null || die "pg_dump not found in PATH"
[[ -z "$S3_URI" ]] || command -v aws >/dev/null || die "aws CLI required for S3 upload"

mkdir -p "$OUTPUT_DIR"
stamp="$(date '+%Y%m%d-%H%M%S')"
file="$OUTPUT_DIR/${DB}-${stamp}.dump"
tmp="${file}.partial"

# Never leave a half-written dump behind that retention logic might treat as valid
trap 'rm -f "$tmp"' EXIT

log "Starting backup of '$DB' -> $file"
start=$(date +%s)
# Custom format (-Fc) is compressed and allows selective restore with pg_restore
pg_dump --format=custom --compress=6 --no-owner --dbname="$DB" --file="$tmp"
mv "$tmp" "$file"
size=$(du -h "$file" | cut -f1)
log "Backup finished in $(( $(date +%s) - start ))s, size=$size"

# Quick integrity check: pg_restore can read the table of contents
pg_restore --list "$file" >/dev/null || die "Backup file failed integrity check: $file"

if [[ -n "$S3_URI" ]]; then
  log "Uploading to $S3_URI/"
  aws s3 cp "$file" "$S3_URI/$(basename "$file")" --only-show-errors
fi

log "Removing local backups older than $KEEP_DAYS days"
find "$OUTPUT_DIR" -maxdepth 1 -name "${DB}-*.dump" -type f -mtime "+$KEEP_DAYS" -print -delete

log "Done"
