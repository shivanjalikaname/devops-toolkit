#!/usr/bin/env bash
#
# docker-cleanup.sh - Reclaim disk space on Docker hosts and CI runners safely.
#
# Usage:
#   ./docker-cleanup.sh [-n] [-a HOURS] [-v]
#
#   -n         Dry run: show what would be removed, change nothing
#   -a HOURS   Only remove images/containers/build cache older than HOURS (default: 72)
#   -v         Also remove unused volumes (off by default: volumes can hold data)
#
# Examples:
#   ./docker-cleanup.sh -n            # preview
#   ./docker-cleanup.sh -a 24         # aggressive cleanup on a CI runner
#
# Cron (nightly):
#   0 3 * * * /opt/devops-toolkit/bash/docker-cleanup.sh -a 48 >> /var/log/docker-cleanup.log 2>&1

set -euo pipefail

DRY_RUN=false
AGE_HOURS=72
PRUNE_VOLUMES=false

usage() {
  sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

while getopts ":na:vh" opt; do
  case "$opt" in
    n) DRY_RUN=true ;;
    a) AGE_HOURS="$OPTARG" ;;
    v) PRUNE_VOLUMES=true ;;
    *) usage ;;
  esac
done

command -v docker >/dev/null || { echo "docker not found" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "cannot reach Docker daemon" >&2; exit 1; }

filter="until=${AGE_HOURS}h"

echo "== Disk usage before =="
docker system df

if $DRY_RUN; then
  echo
  echo "== DRY RUN: stopped containers older than ${AGE_HOURS}h =="
  docker ps -a --filter status=exited --filter status=created \
    --format '{{.ID}}  {{.Image}}  {{.Status}}  {{.Names}}'
  echo
  echo "== DRY RUN: dangling images =="
  docker images --filter dangling=true --format '{{.ID}}  {{.Size}}  {{.CreatedSince}}'
  if $PRUNE_VOLUMES; then
    echo
    echo "== DRY RUN: unused volumes =="
    docker volume ls --filter dangling=true --format '{{.Name}}'
  fi
  exit 0
fi

echo
echo "== Removing stopped containers =="
docker container prune -f --filter "$filter"

echo "== Removing unused images =="
docker image prune -a -f --filter "$filter"

echo "== Removing unused networks =="
docker network prune -f --filter "$filter"

echo "== Removing build cache =="
docker builder prune -f --filter "$filter"

if $PRUNE_VOLUMES; then
  echo "== Removing unused volumes =="
  docker volume prune -f
fi

echo
echo "== Disk usage after =="
docker system df
