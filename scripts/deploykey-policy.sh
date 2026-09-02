#!/usr/bin/env bash
#
# Report every rtldev-middleware-* repository whose releases-via-deploykey trait in
# .github/repo-settings/_register.tsv disagrees with what the repository itself does.
#
#   scripts/deploykey-policy.sh                  # check everywhere
#   scripts/deploykey-policy.sh whmcs php-sdk    # restrict to named repositories
#   scripts/deploykey-policy.sh --verbose        # also print the repositories that are clean
#
# WHY THIS EXISTS
#
# Nothing derived the trait from a repository's actual release configuration, so the
# register could be entirely self-consistent and still wrong — "internally consistent but
# incomplete", which is the failure the central settings model exists to prevent.
# RSRMID-3025 was six days of broken releases from exactly that: a repository whose
# release pushes commits to its own default branch, under a ruleset naming no bypass
# actor. The trait is what puts the bypass there; a missing trait is not a missing
# annotation, it is a broken release nobody finds until the next one is due.
#
# THE RULE
#
#   (release config OR write deploy key)  implies  the trait
#   the trait                             implies  exactly one write deploy key
#
# Two signals, because neither alone is sufficient.
#
#   Release config is the CAUSE. @semantic-release/git in a repository's own plugins
#   array means its release commits the version bump and the changelog and pushes them
#   straight to the release branch. For a distribution arrangement the cause lives in
#   another repository and is readable from that one's release-products.json, whose
#   .targets.*.distributionRepo.url names the target in SSH form.
#
#   A write-enabled deploy key is the MECHANISM. It is what catches the case where the
#   cause is not readable at all: rtldev-middleware-whmcs is the distribution repository
#   — built zips and release.json, no source and no .releaserc.json — so a config-only
#   check would hand it a clean bill of health while its releases depend on the bypass.
#
#   One key per trait repository is _profile-releases-via-deploykey.conf's own invariant.
#   GitHub grants the bypass to deploy keys as a class — the API requires actor_id null
#   for actor_type DeployKey — so a second write-enabled key silently widens the bypass
#   from "the release push" to "anything holding any write key here". That profile says
#   to verify it by hand with `gh repo deploy-key list`; this is that verification, run
#   every week instead of whenever someone remembers.
#
# TWO TRAPS THIS IS BUILT AROUND
#
#   1. @semantic-release/git is a PREFIX of @semantic-release/github. A grep-based check
#      false-positives on every repository that publishes a GitHub release: the first
#      pass of the manual sweep reported semantic-release-plugins as a gap, when it uses
#      @semantic-release/npm and @semantic-release/github, pushes nothing to the branch,
#      and correctly carries no trait. So the plugins array is parsed and its entries are
#      compared with string equality. Nothing here greps a config file.
#
#   2. Enumerate from GitHub, not from repos/. `ws.sh status` reports whmcs and dnscontrol
#      as empty — whmcs deliberately, at 2 GB — so a check reading working trees would
#      silently skip 2 of the 15 checked-out repositories, whmcs among them, and whmcs is
#      the one repository the deploy-key signal exists for.
#
# SCOPE: GITHUB *AND* THE REGISTER
#
# Every active repository in the organisation is checked, so one that nobody added to the
# register is still covered — that is how a repository grows a write deploy key and gets
# noticed. Every name in the register is checked too, even one the organisation listing
# did not return, and such a name fails as unverifiable rather than passing quietly. That
# second half is what makes this useful against a cross-namespace repository: the source
# side of a distribution arrangement can live in an organisation this token cannot read,
# and when its register row lands (RSRMID-3027) the row is checked from the moment it
# exists rather than from the moment the token is widened.
#
# WHAT "COULD NOT TELL" MEANS HERE
#
# Every read that fails is a failure, never a pass. An unreadable deploy-key listing that
# fell through as "no keys" would clear the very repository it could not see. A release
# config in a form this cannot parse over the contents API — YAML, JavaScript, or an
# `extends` that moves the plugins into a shareable config — is reported rather than
# treated as absent.
#
# Read-only, with no write mode at all, deliberately. The fix for a repository that fires
# a signal is either a register row here or a deploy key removed there, and which of the
# two it is takes a person deciding.
#
# Exit status: 0 clean, 1 drift, 2 could not run.

set -uo pipefail

# shellcheck source=scripts/repos.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/repos.sh"

TRAIT="releases-via-deploykey"

# The plugin whose presence means "this release pushes commits to the release branch".
# Compared with string equality — see trap 1 in the header.
GIT_PLUGIN="@semantic-release/git"

RELEASERC=".releaserc.json"
PRODUCTS="release-products.json"

# The semantic-release configuration forms this cannot read over the contents API.
# Finding one is a failure, not an absent config: "we could not tell" must never report
# the same as "this repository has no release config".
UNPARSEABLE_CONFIGS=".releaserc .releaserc.yaml .releaserc.yml .releaserc.js .releaserc.cjs .releaserc.mjs release.config.js release.config.cjs release.config.mjs release.config.ts"

# Distinguishes "the API said no keys" from "the API did not answer". Both are an empty
# string otherwise, and only one of them is a clean result.
SENTINEL_UNREADABLE=$'\001unreadable'

VERBOSE=0
SELECTED=()

DRIFTED=()
FAILED=()
DRIFT=()
CLEAN=0
SKIPPED_ARCHIVED=0
SKIPPED_EXCLUDED=0

# Counted so a run can be compared against the manual sweep recorded in RSRMID-3026
# without reading the per-repository lines.
N_TRAIT=0
N_CONFIG=0
N_WRITEKEY=0

declare -A ROOT_ENTRIES=()
declare -A DIST_SOURCE=()

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

ws_need gh "needed to read deploy keys and release configuration"
ws_need jq "needed to read the GitHub API"

# --- GitHub reads -------------------------------------------------------------
# Which namespace each repository is in, so that every read below goes out with that
# namespace's token and against that namespace's path. A repository whose namespace is
# unknown reads as unreadable and is reported as a failure per repository, which is the
# same outcome as any other read that did not happen.
declare -A REPO_ORG=()

repo_org() { printf '%s' "${REPO_ORG[$1]:-}"; }
repo_nwo() { printf '%s/%s' "$(repo_org "$1")" "$1"; }

root_entries() {
  [ -n "$(repo_org "$1")" ] || return 0
  ws_gh "$(repo_org "$1")" api "repos/$(repo_nwo "$1")/contents" --jq '.[].name' 2>/dev/null
}

file_content() {
  [ -n "$(repo_org "$1")" ] || return 0
  ws_gh "$(repo_org "$1")" api "repos/$(repo_nwo "$1")/contents/$2" --jq '.content' 2>/dev/null \
    | base64 -d 2>/dev/null
}

# Write-enabled deploy keys, one title per line — or the sentinel when the listing could
# not be read. Returning empty on a failed read would clear the repository on the very
# signal the read exists to gather.
#
# This is also the call that needs the most from a credential: listing deploy keys is
# administration:read, not public read. A token scoped to the wrong namespace fails it
# even on a public repository, which is why it is the one probe worth trusting about
# cross-namespace reach.
write_deploy_keys() {
  local out org
  org="$(repo_org "$1")"
  if [ -z "$org" ] || ! out="$(ws_gh "$org" api --paginate "repos/$(repo_nwo "$1")/keys" 2>/dev/null \
    | jq -r '.[] | select(.read_only == false) | .title')"; then
    printf '%s' "$SENTINEL_UNREADABLE"
    return
  fi
  printf '%s' "$out"
}

has_entry() { printf '%s\n' "$1" | grep -qxF "$2"; }

# --- release configuration ----------------------------------------------------

# One jq run per document, emitting "ok", then "extends" or "-", then one field per
# plugin. The leading literal marks the parse as having succeeded: an empty result would
# otherwise be indistinguishable from jq having refused the document.
#
# A plugin entry is either a name or a [name, options] pair, so the pair is reduced to
# its first element. Nothing is lowercased, trimmed or matched loosely — the comparison
# downstream is equality, and it has to stay that way.
parse_plugins() {
  jq -r '
    [ "ok",
      (if has("extends") then "extends" else "-" end),
      ( (.plugins // [])[] | if type == "array" then (.[0] | tostring) else tostring end )
    ] | @tsv
  ' 2>/dev/null
}

# The signal: is @semantic-release/git one of these plugins? Equality against each entry,
# never a substring or a pattern — @semantic-release/github starts with the same 21
# characters and pushes nothing to the branch.
lists_git_plugin() {
  local p
  for p in "$@"; do
    [ "$p" = "$GIT_PLUGIN" ] && return 0
  done
  return 1
}

# The bare repository name out of a distributionRepo.url, in either the SSH form
# (git@github.com:owner/name.git) or the HTTPS one. Bare, because that is how the
# register spells a repository.
url_repo_name() {
  local u="${1%.git}"
  printf '%s' "${u##*/}"
}

# --- pass 1: root listings, and the distribution map --------------------------
# The map has to be built before any repository is judged: whether whmcs has a readable
# cause depends on a file in a *different* repository, so a single pass in name order
# would decide whmcs before reading the repository that explains it.
collect() {
  local name="$1" entries products url target
  entries="$(root_entries "$name")"
  if [ -z "$entries" ]; then
    ROOT_ENTRIES["$name"]="$SENTINEL_UNREADABLE"
    return
  fi
  ROOT_ENTRIES["$name"]="$entries"

  has_entry "$entries" "$PRODUCTS" || return
  products="$(file_content "$name" "$PRODUCTS")"
  if [ -z "$products" ]; then
    # Recorded against the source repository, which is the one that can be fixed.
    FAILED+=("$name")
    printf '%-46s %s is listed but could not be read — its distribution targets are unverified\n' \
      "$name" "$PRODUCTS"
    return
  fi
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    target="$(url_repo_name "$url")"
    DIST_SOURCE["$target"]="$name"
  done < <(printf '%s' "$products" | jq -r '[.targets // {} | .[] | .distributionRepo.url // empty] | .[]' 2>/dev/null)
}

# --- pass 2: one repository ----------------------------------------------------

check_repo() {
  local name="$1" profile="$2" entries keys parsed
  local -a fields=() plugins=()
  local cause="" mechanism=0 nkeys=0 trait=0 f
  DRIFT=()

  ws_profile_has "$profile" "$TRAIT" && trait=1
  [ "$trait" -eq 1 ] && N_TRAIT=$((N_TRAIT + 1))

  # Defaulted rather than read bare: under `set -u` a name that pass 1 never visited
  # would abort the whole run here, and "we never looked at it" has to report as the
  # failure it is, one repository at a time.
  entries="${ROOT_ENTRIES["$name"]:-$SENTINEL_UNREADABLE}"
  if [ "$entries" = "$SENTINEL_UNREADABLE" ]; then
    FAILED+=("$name")
    printf '%-46s could not read the repository root\n' "$name"
    return
  fi

  # --- signal: the cause, in this repository's own configuration
  for f in $UNPARSEABLE_CONFIGS; do
    if has_entry "$entries" "$f"; then
      FAILED+=("$name")
      DRIFT+=("$f is a release config this cannot parse — the plugins array is unverified, which is not the same as absent")
    fi
  done

  if has_entry "$entries" "$RELEASERC"; then
    parsed="$(file_content "$name" "$RELEASERC" | parse_plugins)"
    IFS=$'\t' read -r -a fields <<<"$parsed"
    if [ "${fields[0]:-}" != "ok" ]; then
      FAILED+=("$name")
      DRIFT+=("$RELEASERC is listed but is not readable JSON — the plugins array is unverified")
    elif [ "${fields[1]}" = "extends" ]; then
      FAILED+=("$name")
      DRIFT+=("$RELEASERC has an 'extends' — the plugins may come from the shareable config and cannot be read here")
    else
      plugins=("${fields[@]:2}")
      lists_git_plugin "${plugins[@]}" && cause="$RELEASERC lists $GIT_PLUGIN"
    fi
  fi

  # --- signal: the cause, in another repository's distribution configuration
  if [ -z "$cause" ] && [ -n "${DIST_SOURCE["$name"]:-}" ]; then
    cause="${DIST_SOURCE["$name"]} names it as a distributionRepo in $PRODUCTS"
  fi
  [ -n "$cause" ] && N_CONFIG=$((N_CONFIG + 1))

  # --- signal: the mechanism
  keys="$(write_deploy_keys "$name")"
  if [ "$keys" = "$SENTINEL_UNREADABLE" ]; then
    FAILED+=("$name")
    DRIFT+=("the deploy-key listing could not be read — an unread listing is not an empty one")
  else
    [ -n "$keys" ] && nkeys="$(printf '%s\n' "$keys" | grep -c .)"
    # Summed as keys, not as repositories: the one-key invariant makes the two numbers
    # equal only while nothing has drifted, and the summary has to be able to say so.
    N_WRITEKEY=$((N_WRITEKEY + nkeys))
    [ "$nkeys" -gt 0 ] && mechanism=1
  fi

  # --- the rule
  if [ "$trait" -eq 0 ]; then
    [ -n "$cause" ] &&
      DRIFT+=("release config says it pushes to the release branch ($cause), but the register does not give it $TRAIT")
    [ "$mechanism" -eq 1 ] &&
      DRIFT+=("has $nkeys write-enabled deploy key(s) ($(printf '%s' "$keys" | tr '\n' ' ')), but the register does not give it $TRAIT")
    if [ -n "$cause" ] || [ "$mechanism" -eq 1 ]; then
      DRIFT+=("applying settings to it as it stands would set bypass_actors to [] and break its release — this is the RSRMID-3025 failure")
    fi
  else
    # The trait is only as safe as the "exactly one" it promises. Zero is a trait with no
    # mechanism behind it — the bypass is granted to a class with no member, so the push
    # it exists to allow would be rejected.
    if [ "$keys" != "$SENTINEL_UNREADABLE" ] && [ "$nkeys" -ne 1 ]; then
      if [ "$nkeys" -eq 0 ]; then
        DRIFT+=("carries $TRAIT but has no write-enabled deploy key — the bypass names a class with no member")
      else
        DRIFT+=("carries $TRAIT with $nkeys write-enabled deploy keys ($(printf '%s' "$keys" | tr '\n' ' ')) — the bypass is granted to deploy keys as a class, so every one of them can push past the ruleset")
      fi
    fi
  fi

  if [ "${#DRIFT[@]}" -eq 0 ]; then
    CLEAN=$((CLEAN + 1))
    if [ "$VERBOSE" -eq 1 ]; then
      if [ "$trait" -eq 1 ]; then
        printf '%-46s ok — %s, 1 write key\n' "$name" "${cause:-no readable cause, key only}"
      else
        printf '%-46s ok — no trait, no signal\n' "$name"
      fi
    fi
    return
  fi

  DRIFTED+=("$name")
  printf '%s\n' "$name"
  local d
  for d in "${DRIFT[@]}"; do printf '    %s\n' "$d"; done
}

# --- run ----------------------------------------------------------------------

# ws_die exits 1, which this script reserves for "there is drift". A malformed register
# is "could not run", so it is checked in a subshell whose exit is remapped to 2.
(ws_register_check) || exit 2

# Every namespace, and every visibility. The trait is about how a repository releases,
# which is as true of a private or internal repository as of a public one — and the
# repository the trait matters most for, whmcs-src, is private and in the other namespace.
ws_info "Discovering ${REPO_PREFIX}* repositories in ${WS_ORGS[*]} ..."
DISCOVERED="$(ws_discover_all)" || exit 2

REGISTERED="$(ws_register_names)"
[ -n "$REGISTERED" ] || ws_die "$WS_REGISTER lists no repositories — refusing to read that as 'nothing to check'"

ARCHIVED_NAMES="$(printf '%s\n' "$DISCOVERED" | awk -F'\t' '$5 == "true" { print $2 }' | sort)"
ACTIVE_NAMES="$(printf '%s\n' "$DISCOVERED" | awk -F'\t' '$5 == "false" { print $2 }' | sort)"

while IFS=$'\t' read -r org name _; do
  [ -n "$name" ] || continue
  REPO_ORG["$name"]="$org"
done < <(printf '%s\n' "$DISCOVERED")

# Deliberately no ws_assert_discovery_covers_registers here, unlike org-settings.sh. A
# register row the listing did not return has to be *checked and fail*, one repository at
# a time, rather than aborting the run: the row lands before the credential that can read
# it does, and the report on every other repository is worth having in the meantime. So
# the namespace for such a name comes from its register row, and the read below fails as
# unreadable — which is what the rule wants, since an unread deploy-key listing is not an
# empty one.
while IFS= read -r name; do
  [ -n "$name" ] || continue
  [ -n "${REPO_ORG[$name]:-}" ] && continue
  REPO_ORG["$name"]="$(ws_register_org "$name")"
done <<<"$REGISTERED"

is_archived() { printf '%s\n' "$ARCHIVED_NAMES" | grep -qxF "$1"; }

if [ "${#SELECTED[@]}" -gt 0 ]; then
  TARGETS=("${SELECTED[@]}")
  for name in "${TARGETS[@]}"; do
    printf '%s\n' "$ACTIVE_NAMES" | grep -qxF "$name" && continue
    printf '%s\n' "$REGISTERED" | grep -qxF "$name" && continue
    ws_die "neither active in ${WS_ORGS[*]} nor named in $(basename "$WS_REGISTER"): $name"
  done
else
  # The union, so that neither list can narrow the other's coverage: a repository absent
  # from the register is still checked, and a register row the organisation listing did
  # not return is still checked — and fails below as unreadable rather than vanishing.
  mapfile -t TARGETS < <(printf '%s\n%s\n' "$ACTIVE_NAMES" "$REGISTERED" | sort -u | grep -v '^$')
fi

ws_info "Checking ${#TARGETS[@]} repositories against the $TRAIT trait ..."

ws_info "Reading root listings and distribution targets ..."
for name in "${TARGETS[@]}"; do
  is_archived "$name" && continue
  collect "$name"
done

printf '\n'

for name in "${TARGETS[@]}"; do
  # Archived first. A retired repository takes no settings writes and makes no releases,
  # and the register says archived rows belong out of the file — so reporting on one
  # would be noise nobody can act on.
  if is_archived "$name"; then
    SKIPPED_ARCHIVED=$((SKIPPED_ARCHIVED + 1))
    [ "$VERBOSE" -eq 1 ] && printf '%-46s archived\n' "$name"
    continue
  fi

  PROFILE="$(ws_register_profile "$name")" || PROFILE=""

  # An excluded repository takes no settings from here at all, so it has no bypass to
  # lose and no trait to be missing. dnscontrol is a fork of someone else's project.
  if [ "$PROFILE" = "exclude" ]; then
    SKIPPED_EXCLUDED=$((SKIPPED_EXCLUDED + 1))
    [ "$VERBOSE" -eq 1 ] && printf '%-46s excluded by the register\n' "$name"
    continue
  fi

  # Never exit from inside the loop: one unreachable repository must not decide that
  # every other repository goes unchecked.
  check_repo "$name" "$PROFILE"
done

# --- summary -------------------------------------------------------------------

printf '\n===============================================================\n'
printf 'clean: %d   drifted: %d   failed: %d   archived: %d   excluded: %d\n' \
  "$CLEAN" "${#DRIFTED[@]}" "${#FAILED[@]}" "$SKIPPED_ARCHIVED" "$SKIPPED_EXCLUDED"
printf 'trait rows: %d   with a readable release cause: %d   write deploy keys: %d\n' \
  "$N_TRAIT" "$N_CONFIG" "$N_WRITEKEY"

[ "${#DRIFTED[@]}" -eq 0 ] || printf 'drifted: %s\n' "${DRIFTED[*]}"
[ "${#FAILED[@]}" -eq 0 ] || printf 'failed:  %s\n' "${FAILED[*]}"

[ "${#FAILED[@]}" -eq 0 ] || exit 2
[ "${#DRIFTED[@]}" -eq 0 ] || exit 1
exit 0
