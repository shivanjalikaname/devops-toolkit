#!/usr/bin/env bash
#
# git-branch-cleanup.sh - Find and delete merged or stale Git branches, locally or on a remote.
#
# Reports by default; nothing is deleted unless you pass -x. Protected branches
# (main, master, develop, release/*, hotfix/*, the base branch and the current
# branch) are never touched. Squash- and rebase-merged branches are detected with
# -s, which is what most GitHub/GitLab repos actually need.
#
# Usage:
#   git-branch-cleanup.sh [-C DIR] [-b BASE] [-r REMOTE] [-d DAYS] [-p PATTERN]... [-s] [-x]
#
#   -C DIR      repository to operate on (default: current directory)
#   -b BASE     branch that counts as "merged into" (default: remote HEAD, else main)
#   -r REMOTE   clean branches on this remote instead of local ones, e.g. origin
#   -d DAYS     also list unmerged branches with no commits in DAYS days (report only)
#   -p PATTERN  extra protected glob, repeatable, e.g. -p 'env/*'
#   -s          detect squash/rebase merges (slower: one check per branch)
#   -x          actually delete; without it this is a dry run
#
# Examples:
#   git-branch-cleanup.sh                         # what local branches are merged?
#   git-branch-cleanup.sh -s -x                   # delete merged + squash-merged local branches
#   git-branch-cleanup.sh -r origin -d 90         # remote report, plus branches idle 90+ days
#   git-branch-cleanup.sh -r origin -p 'env/*' -x # prune the remote
#
# Exit codes: 0 OK, 1 at least one deletion failed, 2 bad usage or not a repo.

set -euo pipefail

REPO="."
BASE=""
REMOTE=""
STALE_DAYS=""
SQUASH=0
EXECUTE=0
PROTECTED=(main master develop trunk 'release/*' 'hotfix/*')

usage() {
  sed -n '3,28p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

die() { echo "error: $*" >&2; exit 2; }

while getopts ":C:b:r:d:p:sxh" opt; do
  case "$opt" in
    C) REPO="$OPTARG" ;;
    b) BASE="$OPTARG" ;;
    r) REMOTE="$OPTARG" ;;
    d) STALE_DAYS="$OPTARG" ;;
    p) PROTECTED+=("$OPTARG") ;;
    s) SQUASH=1 ;;
    x) EXECUTE=1 ;;
    h) usage ;;
    :) die "-$OPTARG needs a value" ;;
    *) die "unknown option -$OPTARG (see -h)" ;;
  esac
done
shift $((OPTIND - 1))
[[ $# -eq 0 ]] || die "unexpected argument: $1"
[[ -z "$STALE_DAYS" || "$STALE_DAYS" =~ ^[0-9]+$ ]] || die "-d expects a number of days"

g() { git -C "$REPO" "$@"; }

g rev-parse --git-dir >/dev/null 2>&1 || die "$REPO is not a git repository"

if [[ -n "$REMOTE" ]]; then
  g remote get-url "$REMOTE" >/dev/null 2>&1 || die "no such remote: $REMOTE"
  echo "Fetching $REMOTE ..." >&2
  g fetch --prune --quiet "$REMOTE" || die "fetch from $REMOTE failed"
fi

if [[ -z "$BASE" ]]; then
  head_remote="${REMOTE:-origin}"
  BASE=$(g symbolic-ref --quiet --short "refs/remotes/$head_remote/HEAD" 2>/dev/null || true)
  BASE="${BASE#"$head_remote"/}"
  BASE="${BASE:-main}"
fi

# Compare against the remote copy of the base when cleaning a remote, so a stale
# local main doesn't make merged branches look unmerged.
if [[ -n "$REMOTE" ]]; then
  base_ref="refs/remotes/$REMOTE/$BASE"
  ref_prefix="refs/remotes/$REMOTE/"
else
  base_ref="refs/heads/$BASE"
  ref_prefix="refs/heads/"
fi
g rev-parse --verify --quiet "$base_ref" >/dev/null || die "base branch not found: $base_ref"

current=$(g symbolic-ref --quiet --short HEAD 2>/dev/null || true)

is_protected() {
  local b="$1" p
  [[ "$b" == "$BASE" || "$b" == HEAD ]] && return 0
  [[ -z "$REMOTE" && "$b" == "$current" ]] && return 0
  for p in "${PROTECTED[@]}"; do
    # shellcheck disable=SC2053  # glob match is intended
    [[ "$b" == $p ]] && return 0
  done
  return 1
}

# A squash merge leaves no shared commits, so build a throwaway commit with the
# branch's tree on top of the merge base and ask git cherry whether an
# equivalent patch already exists in base. Writes an unreferenced object only.
squash_merged() {
  local ref="$1" mb tmp
  mb=$(g merge-base "$base_ref" "$ref" 2>/dev/null) || return 1
  tmp=$(g commit-tree "$ref^{tree}" -p "$mb" -m cleanup-probe) || return 1
  [[ $(g cherry "$base_ref" "$tmp" 2>/dev/null) == "-"* ]]
}

merged=()
squashed=()
stale=()
now=$(date +%s)

while IFS=$'\t' read -r ref ts; do
  name="${ref#"$ref_prefix"}"
  is_protected "$name" && continue

  if g merge-base --is-ancestor "$ref" "$base_ref"; then
    merged+=("$name")
  elif (( SQUASH )) && squash_merged "$ref"; then
    squashed+=("$name")
  elif [[ -n "$STALE_DAYS" ]] && (( (now - ts) / 86400 >= STALE_DAYS )); then
    stale+=("$name|$(( (now - ts) / 86400 ))")
  fi
done < <(g for-each-ref --format='%(refname)%09%(committerdate:unix)' "$ref_prefix")

where="${REMOTE:-local}"
echo "Repository: $(g rev-parse --show-toplevel)  scope: $where  base: $BASE"

print_list() {
  local title="$1"; shift
  (( $# )) || return 0
  echo
  echo "$title ($#):"
  printf '  %s\n' "$@"
}

print_list "Merged into $BASE" "${merged[@]+"${merged[@]}"}"
print_list "Squash/rebase merged into $BASE" "${squashed[@]+"${squashed[@]}"}"
if (( ${#stale[@]} )); then
  echo
  echo "Unmerged, no commits in ${STALE_DAYS}+ days (${#stale[@]}) - review by hand, not deleted:"
  for s in "${stale[@]}"; do
    printf '  %-50s %s days\n' "${s%|*}" "${s##*|}"
  done
fi

targets=()
(( ${#merged[@]} )) && targets+=("${merged[@]}")
(( ${#squashed[@]} )) && targets+=("${squashed[@]}")

if (( ${#targets[@]} == 0 )); then
  echo
  echo "Nothing to delete."
  exit 0
fi

if (( ! EXECUTE )); then
  echo
  echo "Dry run: ${#targets[@]} branch(es) would be deleted. Re-run with -x to delete."
  exit 0
fi

failed=0
echo
for b in "${targets[@]}"; do
  if [[ -n "$REMOTE" ]]; then
    if g push --quiet "$REMOTE" --delete "$b"; then echo "deleted $REMOTE/$b"; else echo "FAILED  $REMOTE/$b" >&2; failed=1; fi
  else
    # -D because squash-merged branches are "unmerged" as far as git branch -d knows.
    if g branch --quiet -D "$b"; then echo "deleted $b"; else echo "FAILED  $b" >&2; failed=1; fi
  fi
done

exit "$failed"
