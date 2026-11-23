#!/usr/bin/env bash
#
# kube-switch.sh - Switch kubectl context and namespace, with a guard for production.
#
# Contexts can be matched by unique substring, "-" jumps back to the previous one,
# and namespaces are checked against the cluster before being set. Contexts that
# match PROD_PATTERN print a loud banner and, with -c, need typed confirmation.
#
# By default the switch is written to your kubeconfig, which affects every shell.
# With -s it instead writes a minified, single-context kubeconfig and prints an
# export line, so one terminal can sit on prod while another stays on staging:
#
#   eval "$(kube-switch.sh -s prod-eu)"
#
# Usage:
#   kube-switch.sh                       list contexts (current one marked)
#   kube-switch.sh CONTEXT [NAMESPACE]   switch context, optionally namespace
#   kube-switch.sh -                     back to the previous context/namespace
#   kube-switch.sh -n NAMESPACE          change namespace in the current context
#   kube-switch.sh -N                    list namespaces in the current context
#
# Options:
#   -s        per-shell mode: print 'export KUBECONFIG=...' instead of editing kubeconfig
#   -c        require typing the context name before switching to a prod context
#   -f        skip the namespace existence check (no API access, or RBAC can't list)
#   -h        show this help
#
# Environment:
#   PROD_PATTERN        extended regex for production contexts (default: 'prod|prd|live')
#   KUBE_SWITCH_STATE   state directory (default: ~/.kube/kube-switch)
#
# Examples:
#   kube-switch.sh stag monitoring       # "staging-eu-1" if it is the only match
#   kube-switch.sh -c prod-eu-1 payments
#   eval "$(kube-switch.sh -s -c prod-eu-1)"
#
# Exit codes: 0 switched/listed, 1 no match/ambiguous/declined, 2 usage or missing kubectl

set -euo pipefail

PROD_PATTERN="${PROD_PATTERN:-prod|prd|live}"
STATE_DIR="${KUBE_SWITCH_STATE:-$HOME/.kube/kube-switch}"
PREV_FILE="$STATE_DIR/previous"

SHELL_MODE=false
CONFIRM=false
CHECK_NS=true
NS_ONLY=""
LIST_NS=false

usage() { sed -n '3,37p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
die()   { echo "kube-switch: $*" >&2; exit 1; }
# In -s mode stdout is eval'd by the caller, so everything human-facing goes to stderr.
say()   { echo "$*" >&2; }

while getopts ":n:Nscfh" opt; do
  case "$opt" in
    n) NS_ONLY="$OPTARG" ;;
    N) LIST_NS=true ;;
    s) SHELL_MODE=true ;;
    c) CONFIRM=true ;;
    f) CHECK_NS=false ;;
    h) usage 0 ;;
    :) echo "kube-switch: -$OPTARG needs a value" >&2; usage 2 ;;
    *) echo "kube-switch: unknown option -$OPTARG" >&2; usage 2 ;;
  esac
done
shift $((OPTIND - 1))

command -v kubectl >/dev/null || { echo "kube-switch: kubectl not found" >&2; exit 2; }

current_ctx() { kubectl config current-context 2>/dev/null || true; }

ns_of() {
  local ns
  ns=$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$1\")].context.namespace}" 2>/dev/null || true)
  echo "${ns:-default}"
}

is_prod() { [[ "$1" =~ $PROD_PATTERN ]]; }

list_contexts() {
  local cur ctx mark tag
  cur=$(current_ctx)
  while IFS= read -r ctx; do
    [[ -z "$ctx" ]] && continue
    mark=" "; [[ "$ctx" == "$cur" ]] && mark="*"
    tag="";   is_prod "$ctx" && tag="  [PROD]"
    printf '%s %-45s ns=%s%s\n' "$mark" "$ctx" "$(ns_of "$ctx")" "$tag"
  done < <(kubectl config get-contexts -o name)
}

# Exact name wins; otherwise the substring must match exactly one context.
resolve_context() {
  local want="$1" ctx
  local -a hits=()
  while IFS= read -r ctx; do
    [[ "$ctx" == "$want" ]] && { echo "$ctx"; return 0; }
    [[ "$ctx" == *"$want"* ]] && hits+=("$ctx")
  done < <(kubectl config get-contexts -o name)

  case ${#hits[@]} in
    0) die "no context matches '$want'" ;;
    1) echo "${hits[0]}" ;;
    *) say "kube-switch: '$want' is ambiguous:"; printf '  %s\n' "${hits[@]}" >&2; exit 1 ;;
  esac
}

check_namespace() {
  local ctx="$1" ns="$2"
  $CHECK_NS || return 0
  kubectl --context "$ctx" --request-timeout=5s get namespace "$ns" >/dev/null 2>&1 \
    || die "namespace '$ns' not found in $ctx (or not readable; use -f to skip the check)"
}

prod_gate() {
  local ctx="$1" answer
  is_prod "$ctx" || return 0
  say ""
  say "  !!  PRODUCTION CONTEXT: $ctx  !!"
  say ""
  if $CONFIRM; then
    [[ -t 0 ]] || die "refusing prod switch without a terminal to confirm on"
    read -r -p "Type the context name to continue: " answer </dev/tty
    [[ "$answer" == "$ctx" ]] || die "confirmation did not match, staying put"
  fi
}

save_previous() {
  local ctx
  ctx=$(current_ctx)
  [[ -z "$ctx" ]] && return 0
  mkdir -p "$STATE_DIR"
  printf '%s\t%s\n' "$ctx" "$(ns_of "$ctx")" > "$PREV_FILE"
}

switch_global() {
  local ctx="$1" ns="$2"
  save_previous
  kubectl config use-context "$ctx" >/dev/null
  [[ -n "$ns" ]] && kubectl config set-context --current --namespace "$ns" >/dev/null
  say "Switched to $ctx (ns=$(ns_of "$ctx"))"
}

# Minified kubeconfig holding only this context, so later switches elsewhere
# don't move this shell. One file per context+namespace so two terminals on the
# same cluster don't fight over it. Credentials are copied, hence the umask.
switch_shell() {
  local ctx="$1" ns="$2" file
  file="$STATE_DIR/sessions/$(printf '%s' "$ctx${ns:+__$ns}" | tr -c 'A-Za-z0-9._-' '_').yaml"
  mkdir -p "$STATE_DIR/sessions"
  (umask 077; kubectl config view --minify --flatten --context "$ctx" > "$file")
  [[ -n "$ns" ]] && KUBECONFIG="$file" kubectl config set-context --current --namespace "$ns" >/dev/null
  say "This shell now uses $ctx (ns=$(KUBECONFIG="$file" kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null || echo default))"
  printf 'export KUBECONFIG=%q\n' "$file"
}

do_switch() {
  local ctx="$1" ns="${2:-}"
  [[ -n "$ns" ]] && check_namespace "$ctx" "$ns"
  prod_gate "$ctx"
  if $SHELL_MODE; then switch_shell "$ctx" "$ns"; else switch_global "$ctx" "$ns"; fi
}

if $LIST_NS; then
  ctx=$(current_ctx); [[ -n "$ctx" ]] || die "no current context"
  kubectl --context "$ctx" get namespaces -o name | sed 's#^namespace/##'
  exit 0
fi

if [[ -n "$NS_ONLY" ]]; then
  ctx=$(current_ctx); [[ -n "$ctx" ]] || die "no current context"
  do_switch "$ctx" "$NS_ONLY"
  exit 0
fi

case $# in
  0) list_contexts ;;
  1|2)
    if [[ "$1" == "-" ]]; then
      [[ -s "$PREV_FILE" ]] || die "no previous context recorded yet"
      IFS=$'\t' read -r prev_ctx prev_ns < "$PREV_FILE"
      CHECK_NS=false   # it was valid when we left it
      do_switch "$prev_ctx" "$prev_ns"
    else
      target=$(resolve_context "$1")   # separate assignment so set -e sees a failed match
      do_switch "$target" "${2:-}"
    fi
    ;;
  *) usage 2 ;;
esac
