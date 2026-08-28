#!/usr/bin/env bash
#
# Report every rtldev-middleware-* repository whose Node toolchain declaration does not
# match .github/node-policy.conf.
#
#   scripts/node-policy.sh                   # report drift everywhere
#   scripts/node-policy.sh php-sdk node-sdk  # restrict to named repositories
#   scripts/node-policy.sh --verbose         # also print the repositories that are clean
#
# We use pnpm, not npm, and every repository is supposed to say the same thing about
# which Node, which npm floor and which pnpm it expects. Nothing checked that, and six
# different spellings of engines.node accumulated without anyone noticing — the kind of
# drift that costs nothing until the day a release runs on a toolchain nobody chose.
#
# Read-only. It never writes to GitHub and never edits a manifest; bringing a repository
# into line is a commit someone makes, because a manifest edit belongs in that
# repository's own history and review.
#
# WHY THIS READS GITHUB RATHER THAN repos/
#
# A check that walked the checkouts would be wrong, not merely incomplete. template,
# whmcs and dnscontrol are registered submodules that are usually unpopulated, so they
# read as "no package.json" when two of them have one; and workspace, domain-ideas and
# gh-actions-endoflife have no submodule entry at all. Enumerating from the organisation
# and reading package.json over the contents API is the only way to get the same answer
# from a laptop and from CI.
#
# It also means coverage needs no register. Every repository in the organisation is in
# scope from the moment it exists, and one with no package.json is reported and counted
# rather than skipped in silence — so this cannot develop the failure mode
# repo-settings-drift.yml has to guard against by hand, where a repository nobody added
# to a list is a repository nobody checks.
#
# Exit status: 0 clean, 1 drift, 2 could not run.

set -uo pipefail

# shellcheck source=scripts/repos.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/repos.sh"

POLICY_FILE="$WS_ROOT/.github/node-policy.conf"

VERBOSE=0
SELECTED=()

DRIFTED=()
FAILED=()
DRIFT=()
CLEAN=0
NOT_NODE=0
EXCLUDED=0
ARCHIVED=0

# --- arguments ---------------------------------------------------------------

while [ "$#" -gt 0 ]; do
  case "$1" in
    -v | --verbose) VERBOSE=1 ;;
    -h | --help)
      grep '^#' "$0" | grep -v '^#!' | cut -c 3-
      exit 0
      ;;
    -*) ws_die "unknown option '$1' (try --help)" ;;
    *) SELECTED+=("$(ws_full_name "$1")") ;;
  esac
  shift
done

ws_need gh "needed to read package.json from every repository"
ws_need jq "needed to read the GitHub API"
[ -f "$POLICY_FILE" ] || ws_die "no policy at $POLICY_FILE"

# shellcheck source=.github/node-policy.conf
. "$POLICY_FILE"

for var in POLICY_ENGINES_NODE POLICY_ENGINES_NPM POLICY_DEV_ENGINES_PACKAGE_MANAGER POLICY_LOCKFILE; do
  [ -n "${!var:-}" ] || ws_die "$POLICY_FILE does not set $var"
done

# --- discovery ---------------------------------------------------------------
# type=all, because the policy covers the private and internal repositories too — the
# Node toolchain of a repository nobody outside the company can see still decides what
# our own CI runs on.
discover() {
  gh api --paginate "orgs/$ORG/repos?type=all&per_page=100" 2>/dev/null \
    | jq -r --arg p "$REPO_PREFIX" '
        .[] | select(.name | startswith($p)) | [.name, (.archived | tostring)] | @tsv
      '
}

is_excluded() {
  local name
  for name in ${POLICY_EXCLUDE:-}; do
    [ "$name" = "$1" ] && return 0
  done
  return 1
}

# --- per-repository checks ---------------------------------------------------
# Both API reads are per repository and neither is cached, so this costs two requests
# per repository. That is well inside the authenticated rate limit for an organisation
# this size, and it keeps the check stateless.

# Root listing, one name per line. A repository with no default branch (freshly created,
# never pushed) returns 404 here, which is a failure to report rather than a clean pass.
root_entries() {
  gh api "repos/$ORG/$1/contents" --jq '.[].name' 2>/dev/null
}

manifest() {
  gh api "repos/$ORG/$1/contents/package.json" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null
}

# Compares one field and appends to DRIFT when it differs. Literal string comparison:
# see the note in node-policy.conf about why nothing here evaluates semver.
compare() {
  local label="$1" actual="$2" want="$3"
  if [ "$actual" != "$want" ]; then
    DRIFT+=("$label: $(fmt_value "$actual") — want $(fmt_value "$want")")
  fi
}

# An absent field and a field set to the empty string are different problems, and the
# report has to be able to say which.
fmt_value() {
  case "$1" in
    "$SENTINEL_ABSENT") printf '(absent)' ;;
    "") printf "(empty)" ;;
    *) printf "'%s'" "$1" ;;
  esac
}

SENTINEL_ABSENT=$'\001absent'

check_repo() {
  local name="$1" entries pj
  DRIFT=()

  entries="$(root_entries "$name")"
  if [ -z "$entries" ]; then
    FAILED+=("$name")
    printf '%-46s could not read the repository root\n' "$name"
    return
  fi

  if ! printf '%s\n' "$entries" | grep -qxF 'package.json'; then
    NOT_NODE=$((NOT_NODE + 1))
    # Still worth saying when a lockfile is lying around without a manifest — it is
    # either a leftover or a sign the manifest was deleted by accident.
    local stray=() f
    for f in $POLICY_LOCKFILE ${POLICY_FORBIDDEN_LOCKFILES:-}; do
      printf '%s\n' "$entries" | grep -qxF "$f" && stray+=("$f")
    done
    if [ "${#stray[@]}" -gt 0 ]; then
      DRIFTED+=("$name")
      printf '%-46s no package.json, but carries: %s\n' "$name" "${stray[*]}"
    elif [ "$VERBOSE" -eq 1 ]; then
      printf '%-46s not a Node repository\n' "$name"
    fi
    return
  fi

  pj="$(manifest "$name")"
  if [ -z "$pj" ]; then
    FAILED+=("$name")
    printf '%-46s package.json is listed but could not be read\n' "$name"
    return
  fi

  # One jq invocation for every field, tab separated, with the sentinel standing in for a
  # field that is absent rather than empty. The leading literal marks the parse as having
  # succeeded — an empty first field would otherwise be indistinguishable from jq having
  # refused the document.
  #
  # devEngines.packageManager is an object, so it is flattened to the same canonical
  # string node-policy.conf spells the policy in. A non-object there (the array form the
  # spec also allows) is rendered as its JSON, which cannot match and is therefore
  # reported rather than silently accepted.
  local ok node npm dep forbidden
  IFS=$'\t' read -r ok node npm dep forbidden < <(
    printf '%s' "$pj" | jq -r --arg a "$SENTINEL_ABSENT" --arg f "${POLICY_FORBIDDEN_FIELDS:-}" '
      . as $root
      | (.devEngines.packageManager) as $d
      | [ "ok",
          (.engines.node // $a),
          (.engines.npm // $a),
          ( if $d == null then $a
            elif ($d | type) == "object"
            then "\($d.name // "?")@\($d.version // "?") onFail=\($d.onFail // "?")"
            else ($d | tojson) end ),
          ( $f | split(" ") | map(. as $k | select($k != "" and ($root | has($k)))) | join(" ") )
        ] | @tsv
    ' 2>/dev/null
  )
  if [ "${ok:-}" != "ok" ]; then
    FAILED+=("$name")
    printf '%-46s package.json is not valid JSON\n' "$name"
    return
  fi

  compare 'engines.node' "$node" "$POLICY_ENGINES_NODE"
  compare 'engines.npm' "$npm" "$POLICY_ENGINES_NPM"
  compare 'devEngines.packageManager' "$dep" "$POLICY_DEV_ENGINES_PACKAGE_MANAGER"

  local field
  for field in $forbidden; do
    DRIFT+=("$field must not exist — see node-policy.conf for why it and devEngines.packageManager cannot both be right")
  done

  printf '%s\n' "$entries" | grep -qxF "$POLICY_LOCKFILE" ||
    DRIFT+=("$POLICY_LOCKFILE is missing")

  local f
  for f in ${POLICY_FORBIDDEN_LOCKFILES:-}; do
    printf '%s\n' "$entries" | grep -qxF "$f" &&
      DRIFT+=("$f must not exist — this repository installs with pnpm")
  done

  if [ "${#DRIFT[@]}" -eq 0 ]; then
    CLEAN=$((CLEAN + 1))
    [ "$VERBOSE" -eq 1 ] && printf '%-46s ok\n' "$name"
    return
  fi

  DRIFTED+=("$name")
  printf '%s\n' "$name"
  local d
  for d in "${DRIFT[@]}"; do printf '    %s\n' "$d"; done
}

# --- run ---------------------------------------------------------------------

ws_info "Discovering ${REPO_PREFIX}* repositories in $ORG ..."
DISCOVERED="$(discover)"
[ -n "$DISCOVERED" ] || ws_die "discovery returned nothing — refusing to read that as 'no repositories'"

if [ "${#SELECTED[@]}" -gt 0 ]; then
  TARGETS=("${SELECTED[@]}")
  for name in "${TARGETS[@]}"; do
    printf '%s\n' "$DISCOVERED" | cut -f1 | grep -qxF "$name" ||
      ws_die "not found in $ORG: $name"
  done
else
  mapfile -t TARGETS < <(printf '%s\n' "$DISCOVERED" | cut -f1 | sort)
fi

is_archived() {
  printf '%s\n' "$DISCOVERED" | awk -F'\t' -v n="$1" '$1 == n { print $2 }' | grep -qx true
}

ws_info "Checking ${#TARGETS[@]} repositories against $(basename "$POLICY_FILE") ..."
printf '\n'

for name in "${TARGETS[@]}"; do
  # Archived first: an archived repository cannot be brought into line without
  # unarchiving it, so reporting its drift would be noise nobody can act on.
  if is_archived "$name"; then
    ARCHIVED=$((ARCHIVED + 1))
    [ "$VERBOSE" -eq 1 ] && printf '%-46s archived\n' "$name"
    continue
  fi
  if is_excluded "$name"; then
    EXCLUDED=$((EXCLUDED + 1))
    [ "$VERBOSE" -eq 1 ] && printf '%-46s excluded by the policy\n' "$name"
    continue
  fi
  # Never exit from inside the loop: one unreachable repository must not decide that
  # every other repository goes unchecked.
  check_repo "$name"
done

# --- summary -----------------------------------------------------------------

printf '\n===============================================================\n'
printf 'clean: %d   drifted: %d   failed: %d   not a Node repo: %d   archived: %d   excluded: %d\n' \
  "$CLEAN" "${#DRIFTED[@]}" "${#FAILED[@]}" "$NOT_NODE" "$ARCHIVED" "$EXCLUDED"

[ "${#DRIFTED[@]}" -eq 0 ] || printf 'drifted: %s\n' "${DRIFTED[*]}"
[ "${#FAILED[@]}" -eq 0 ] || printf 'failed:  %s\n' "${FAILED[*]}"

[ "${#FAILED[@]}" -eq 0 ] || exit 2
[ "${#DRIFTED[@]}" -eq 0 ] || exit 1
exit 0
