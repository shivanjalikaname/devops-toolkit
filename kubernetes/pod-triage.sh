#!/usr/bin/env bash
#
# pod-triage.sh - First-response view of unhealthy pods in a Kubernetes cluster.
#
# Shows pods that are not Running/Succeeded, pods with restarts above a threshold,
# and the last termination reason (OOMKilled, Error, ...) for each problem container.
#
# Usage:
#   ./pod-triage.sh [-n NAMESPACE] [-r MIN_RESTARTS] [-l]
#
#   -n NAMESPACE     limit to one namespace (default: all namespaces)
#   -r MIN_RESTARTS  restart count that counts as "flapping" (default: 3)
#   -l               also print the last 20 log lines of the previous container instance
#
# Requires: kubectl, jq

set -euo pipefail

NS_ARGS=(--all-namespaces)
MIN_RESTARTS=3
SHOW_LOGS=false

while getopts ":n:r:lh" opt; do
  case "$opt" in
    n) NS_ARGS=(-n "$OPTARG") ;;
    r) MIN_RESTARTS="$OPTARG" ;;
    l) SHOW_LOGS=true ;;
    *) sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  esac
done

for bin in kubectl jq; do
  command -v "$bin" >/dev/null || { echo "$bin is required" >&2; exit 1; }
done

echo "Context: $(kubectl config current-context)"
echo

problems=$(kubectl get pods "${NS_ARGS[@]}" -o json | jq -r --argjson min "$MIN_RESTARTS" '
  .items[]
  | . as $pod
  | (.status.containerStatuses // [])[]
  | select(
      ($pod.status.phase != "Running" and $pod.status.phase != "Succeeded")
      or (.restartCount >= $min)
      or (.ready == false and $pod.status.phase == "Running")
    )
  | [
      $pod.metadata.namespace,
      $pod.metadata.name,
      .name,
      $pod.status.phase,
      (.state | keys[0]) + (if .state.waiting then "/" + .state.waiting.reason else "" end),
      (.restartCount | tostring),
      (.lastState.terminated.reason // "-"),
      ($pod.spec.nodeName // "-")
    ]
  | @tsv')

if [[ -z "$problems" ]]; then
  echo "No unhealthy or flapping pods found."
  exit 0
fi

{
  printf 'NAMESPACE\tPOD\tCONTAINER\tPHASE\tSTATE\tRESTARTS\tLAST_TERMINATION\tNODE\n'
  printf '%s\n' "$problems"
} | column -t -s $'\t'

if $SHOW_LOGS; then
  while IFS=$'\t' read -r ns pod container _; do
    echo
    echo "===== $ns/$pod [$container] previous logs ====="
    kubectl logs -n "$ns" "$pod" -c "$container" --previous --tail=20 2>/dev/null \
      || echo "(no previous logs)"
  done <<< "$problems"
fi

exit 1
