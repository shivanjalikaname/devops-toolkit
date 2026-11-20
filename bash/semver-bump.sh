#!/usr/bin/env bash
#
# semver-bump.sh - Work out the next semantic version from Conventional Commits and optionally tag it.
#
# Looks at commits since the latest stable tag (vX.Y.Z by default) and picks the
# bump: breaking change -> major, feat -> minor, fix/perf -> patch. Anything else
# (chore, docs, ci, ...) is not releasable on its own. While the major version is 0,
# breaking changes bump minor unless -S is given, which matches how most teams treat
# pre-1.0 APIs. Prints the version and a grouped changelog; nothing is written to the
# repo unless -t is passed.
#
# Usage:
#   semver-bump.sh [-C DIR] [-p PREFIX] [-f LEVEL] [-r ID] [-q] [-t] [-P REMOTE] [-n]
#
#   -C DIR     repository to operate on (default: current directory)
#   -p PREFIX  tag prefix (default: v; use -p '' for bare 1.2.3 tags)
#   -f LEVEL   force the bump level: major, minor or patch
#   -r ID      cut a pre-release, e.g. -r rc gives v1.4.0-rc.1, then rc.2 on the next run
#   -S         strict: breaking changes bump major even while on 0.x
#   -q         quiet: print only the next version (for CI: VERSION=$(semver-bump.sh -q))
#   -t         create an annotated tag on HEAD with the changelog as its message
#   -P REMOTE  push the new tag to REMOTE (implies -t)
#   -n         dry run: show what -t/-P would do without doing it
#
# Examples:
#   semver-bump.sh                      # what would the next release be, and why?
#   semver-bump.sh -q                   # just "v1.4.0"
#   semver-bump.sh -r rc -t -P origin   # tag and push the next release candidate
#   semver-bump.sh -f patch -t          # hotfix release even with only chore commits
#
# Exit codes: 0 next version computed (and tagged if asked), 1 no releasable commits,
#             2 bad usage, not a repo, or tagging failed.

set -euo pipefail

REPO="."
PREFIX="v"
FORCE=""
PRE_ID=""
STRICT=0
QUIET=0
TAG=0
PUSH_REMOTE=""
DRY_RUN=0

usage() {
  sed -n '3,33p' "$0" | sed 's/^# \{0,1\}//'
}

die() { echo "semver-bump: $*" >&2; exit 2; }
log() { [[ $QUIET -eq 1 ]] || echo "$@"; }

while getopts ":C:p:f:r:SqtP:nh" opt; do
  case $opt in
    C) REPO=$OPTARG ;;
    p) PREFIX=$OPTARG ;;
    f) FORCE=$OPTARG ;;
    r) PRE_ID=$OPTARG ;;
    S) STRICT=1 ;;
    q) QUIET=1 ;;
    t) TAG=1 ;;
    P) PUSH_REMOTE=$OPTARG; TAG=1 ;;
    n) DRY_RUN=1 ;;
    h) usage; exit 0 ;;
    :) die "option -$OPTARG needs an argument (see -h)" ;;
    *) die "unknown option -$OPTARG (see -h)" ;;
  esac
done
shift $((OPTIND - 1))
[[ $# -eq 0 ]] || die "unexpected argument: $1"

case $FORCE in ""|major|minor|patch) ;; *) die "-f must be major, minor or patch" ;; esac
[[ -z $PRE_ID || $PRE_ID =~ ^[0-9A-Za-z-]+$ ]] || die "pre-release id must be alphanumeric, got '$PRE_ID'"

cd "$REPO" 2>/dev/null || die "cannot cd to $REPO"
git rev-parse --git-dir >/dev/null 2>&1 || die "$REPO is not a git repository"
git rev-parse --verify -q HEAD >/dev/null || die "repository has no commits"

# Escape the prefix for use in a regex; tags like "api/v" are common in monorepos.
prefix_re=$(printf '%s' "$PREFIX" | sed 's/[][\.*^$/+?(){}|]/\\&/g')
stable_re="^${prefix_re}(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"

# Latest stable tag reachable from HEAD. Pre-release tags are ignored as a base so
# that v1.4.0-rc.2 -> v1.4.0 works and the changelog covers the whole release.
last_tag=""
while IFS= read -r t; do
  if [[ $t =~ $stable_re ]]; then last_tag=$t; break; fi
done < <(git tag --merged HEAD --list "${PREFIX}*" --sort=-v:refname)

if [[ -n $last_tag ]]; then
  [[ $last_tag =~ $stable_re ]]
  major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]} patch=${BASH_REMATCH[3]}
  range="${last_tag}..HEAD"
else
  major=0 minor=0 patch=0
  range="HEAD"
fi

# Commit records: hash, subject, body. \x1f between fields, \x1e between commits.
level=0   # 0 none, 1 patch, 2 minor, 3 major
total=0
declare -a breaking=() features=() fixes=() other=()

while IFS=$'\x1f' read -r -d $'\x1e' hash subject body; do
  hash=${hash#$'\n'}
  [[ -n $hash ]] || continue
  short=${hash:0:7}
  total=$((total + 1))

  # type(scope)!: description
  if [[ $subject =~ ^([a-zA-Z]+)(\(([^\)]*)\))?(!)?:\ +(.+)$ ]]; then
    type=${BASH_REMATCH[1],,} scope=${BASH_REMATCH[3]} bang=${BASH_REMATCH[4]} desc=${BASH_REMATCH[5]}
  else
    type="" scope="" bang="" desc=$subject
  fi
  line="${scope:+**$scope:** }$desc ($short)"

  # A breaking commit is listed once, under Breaking changes, whatever its type.
  if [[ -n $bang ]] || grep -qE '^BREAKING[ -]CHANGE: ' <<<"$body"; then
    breaking+=("$line"); level=3
    continue
  fi
  case $type in
    feat)            features+=("$line"); (( level < 2 )) && level=2 ;;
    fix|perf|revert) fixes+=("$line");    (( level < 1 )) && level=1 ;;
    *)               other+=("$line") ;;
  esac
done < <(git log --no-merges --format='%H%x1f%s%x1f%b%x1e' "$range")

case $FORCE in
  major) level=3 ;; minor) level=2 ;; patch) level=1 ;;
esac

if (( level == 3 && major == 0 && STRICT == 0 )) && [[ -z $FORCE ]]; then
  level=2
fi

if (( level == 0 )); then
  log "No releasable commits since ${last_tag:-the start of history} ($total commit(s) checked)."
  exit 1
fi

case $level in
  3) major=$((major + 1)); minor=0; patch=0; bump=major ;;
  2) minor=$((minor + 1)); patch=0; bump=minor ;;
  1) patch=$((patch + 1)); bump=patch ;;
esac
next="${PREFIX}${major}.${minor}.${patch}"

if [[ -n $PRE_ID ]]; then
  n=0
  pre_re="^$(printf '%s' "$next" | sed 's/[][\.*^$/+?(){}|]/\\&/g')-${PRE_ID}\.([0-9]+)$"
  while IFS= read -r t; do
    if [[ $t =~ $pre_re ]] && (( BASH_REMATCH[1] > n )); then n=${BASH_REMATCH[1]}; fi
  done < <(git tag --list "${next}-${PRE_ID}.*")
  next="${next}-${PRE_ID}.$((n + 1))"
fi

if git rev-parse -q --verify "refs/tags/$next" >/dev/null; then
  die "tag $next already exists; is HEAD already released?"
fi

section() {
  local -n items=$2
  (( ${#items[@]} )) || return 0
  printf '\n### %s\n\n' "$1"
  printf -- '- %s\n' "${items[@]}"
}

changelog() {
  echo "## $next ($(date +%Y-%m-%d))"
  section "Breaking changes" breaking
  section "Features" features
  section "Fixes" fixes
  section "Other" other
}

if [[ $QUIET -eq 1 ]]; then
  echo "$next"
else
  echo "Last release: ${last_tag:-none}"
  echo "Next version: $next ($bump${FORCE:+, forced}, $total commit(s))"
  echo
  changelog
fi

(( TAG )) || exit 0

if (( DRY_RUN )); then
  log ""
  log "[dry run] would run: git tag -a $next -F <changelog> HEAD"
  [[ -z $PUSH_REMOTE ]] || log "[dry run] would run: git push $PUSH_REMOTE refs/tags/$next"
  exit 0
fi

git tag -a "$next" -m "$(changelog)" HEAD || die "failed to create tag $next"
log ""
log "Created tag $next on $(git rev-parse --short HEAD)"

if [[ -n $PUSH_REMOTE ]]; then
  git push "$PUSH_REMOTE" "refs/tags/$next" || die "tag $next created locally but push to $PUSH_REMOTE failed"
  log "Pushed $next to $PUSH_REMOTE"
fi
