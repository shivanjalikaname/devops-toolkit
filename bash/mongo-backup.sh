#!/usr/bin/env bash
#
# mongo-backup.sh - Encrypted MongoDB backups with checksums, retention and off-site copy.
#
# Usage:
#   ./mongo-backup.sh -c CONFIG_FILE [-d DATABASE] [-o OUTPUT_DIR] [-k KEEP] [-r AGE_RECIPIENTS] [-R rclone:remote/path]
#
# CONFIG_FILE is a mongodump --config YAML holding the connection string, e.g.
#   uri: mongodb://backup:REDACTED@db.internal:27017/?authSource=admin
# so the password never shows up in `ps` or shell history. Keep it chmod 600.
#
# With -r the dump is streamed straight into `age`, so the host only needs the
# public key: it can create backups but cannot read them. Each file gets a
# .sha256 sidecar; with -R it is copied off-site and the copy is verified.
#
# Examples:
#   ./mongo-backup.sh -c /etc/mongo-backup.yaml -d orders
#   ./mongo-backup.sh -c /etc/mongo-backup.yaml -r /etc/backup.age.pub -R b2:acme-backups/mongo -k 48
#
# Cron (hourly, wrapped for locking and alerting):
#   0 * * * * /opt/devops-toolkit/bash/cron-wrap.sh -n mongo-backup -- /opt/devops-toolkit/bash/mongo-backup.sh -c /etc/mongo-backup.yaml -r /etc/backup.age.pub

set -euo pipefail

CONFIG=""
DB=""
OUTPUT_DIR="/var/backups/mongo"
KEEP=24
RECIPIENTS=""
REMOTE=""
MIN_BYTES=1024

log() { printf '%s [mongo-backup] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

usage() {
  sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

while getopts ":c:d:o:k:r:R:h" opt; do
  case "$opt" in
    c) CONFIG="$OPTARG" ;;
    d) DB="$OPTARG" ;;
    o) OUTPUT_DIR="$OPTARG" ;;
    k) KEEP="$OPTARG" ;;
    r) RECIPIENTS="$OPTARG" ;;
    R) REMOTE="${OPTARG%/}" ;;
    *) usage ;;
  esac
done

[[ -n "$CONFIG" ]] || usage
[[ -r "$CONFIG" ]] || die "config file not readable: $CONFIG"
[[ "$KEEP" =~ ^[0-9]+$ && "$KEEP" -ge 1 ]] || die "-k must be a positive integer"
command -v mongodump >/dev/null || die "mongodump not found (install mongodb-database-tools)"
if [[ -n "$RECIPIENTS" ]]; then
  command -v age >/dev/null || die "age not found but -r was given"
  [[ -r "$RECIPIENTS" ]] || die "recipients file not readable: $RECIPIENTS"
fi
[[ -z "$REMOTE" ]] || command -v rclone >/dev/null || die "rclone not found but -R was given"

# Warn if the credentials file is readable by others
perm=$(stat -c '%a' "$CONFIG" 2>/dev/null || echo 600)
if (( (8#$perm & 8#077) != 0 )); then
  log "WARNING: $CONFIG is readable by group/others; chmod 600 it"
fi

mkdir -p "$OUTPUT_DIR"
umask 077

stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
name="mongo-${DB:-all}-${stamp}.archive.gz"
[[ -n "$RECIPIENTS" ]] && name="${name}.age"
target="$OUTPUT_DIR/$name"
partial="$target.partial"

cleanup() { rm -f "$partial"; }
trap cleanup EXIT

dump_args=(--config="$CONFIG" --archive --gzip --quiet)
[[ -n "$DB" ]] && dump_args+=(--db="$DB")

log "dumping ${DB:-all databases} to $target"
start=$SECONDS
if [[ -n "$RECIPIENTS" ]]; then
  mongodump "${dump_args[@]}" | age --encrypt -R "$RECIPIENTS" -o "$partial"
else
  mongodump "${dump_args[@]}" > "$partial"
fi

size=$(stat -c '%s' "$partial")
(( size >= MIN_BYTES )) || die "backup is only $size bytes - refusing to keep a suspiciously small dump"

# Unencrypted dumps can be checked for gzip integrity; age has its own MAC
[[ -n "$RECIPIENTS" ]] || gzip -t "$partial" || die "gzip integrity check failed"

mv "$partial" "$target"
(cd "$OUTPUT_DIR" && sha256sum "$name" > "$name.sha256")
log "wrote $name ($size bytes) in $((SECONDS - start))s"

if [[ -n "$REMOTE" ]]; then
  log "copying to $REMOTE"
  rclone copyto "$target" "$REMOTE/$name"
  rclone copyto "$target.sha256" "$REMOTE/$name.sha256"
  remote_sum=$(rclone cat "$REMOTE/$name" | sha256sum | cut -d' ' -f1)
  local_sum=$(cut -d' ' -f1 "$target.sha256")
  [[ "$remote_sum" == "$local_sum" ]] || die "off-site checksum mismatch for $name"
  log "off-site copy verified"
fi

# Retention: keep the newest $KEEP backups for this database
mapfile -t old < <(find "$OUTPUT_DIR" -maxdepth 1 -type f -name "mongo-${DB:-all}-*.archive.gz*" ! -name '*.sha256' -printf '%T@ %p\n' \
  | sort -rn | tail -n +$((KEEP + 1)) | cut -d' ' -f2-)
for f in "${old[@]}"; do
  rm -f -- "$f" "$f.sha256"
  log "pruned $(basename "$f")"
done

log "done"
