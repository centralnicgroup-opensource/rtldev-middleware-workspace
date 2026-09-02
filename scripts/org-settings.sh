#!/usr/bin/env bash
#
# Reconcile the GitHub settings of every rtldev-middleware-* repository against the
# layered configuration in .github/repo-settings/.
#
#   scripts/org-settings.sh                  # report drift everywhere, change nothing
#   scripts/org-settings.sh --apply          # make GitHub match, everywhere
#   scripts/org-settings.sh php-sdk whmcs    # restrict to named repositories
#   scripts/org-settings.sh --resolve whmcs  # print the effective config, run nothing
#
# The settings themselves are applied by scripts/repo-settings.sh, which this drives
# once per repository. That split is deliberate: repo-settings.sh is the single-repository
# engine and is the same file the template ships, so it stays comparable with the copy in
# any repository that still carries one. Everything that turns *many* repositories into
# settings — the layering, the discovery check, the apply loop — lives here and only here.
# Reading the register itself is in repos.sh, because deploykey-policy.sh reads the same
# rows to answer a different question.
#
# Configuration is resolved in three layers, concatenated and sourced as shell so that a
# later assignment simply wins:
#
#   _baseline.conf  ->  _profile-<profile>.conf  ->  <repository-name>.conf
#
# Exit status: 0 clean, 1 drift or an unregistered repository, 2 could not run.

set -uo pipefail

# shellcheck source=scripts/repos.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/repos.sh"

SETTINGS_DIR="$WS_ROOT/.github/repo-settings"
REGISTER="$WS_REGISTER"
ENGINE="$WS_ROOT/scripts/repo-settings.sh"

MODE=check
RESOLVE_ONLY=0
SELECTED=()

DRIFTED=()
FAILED=()
CLEAN=0
SKIPPED=0

# --- arguments ---------------------------------------------------------------

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) MODE=apply ;;
    --check) MODE=check ;;
    --resolve) RESOLVE_ONLY=1 ;;
    -h | --help)
      grep '^#' "$0" | grep -v '^#!' | cut -c 3-
      exit 0
      ;;
    -*) ws_die "unknown option '$1' (try --help)" ;;
    *) SELECTED+=("$(ws_full_name "$1")") ;;
  esac
  shift
done

ws_need gh "needed to read and write repository settings"
ws_need jq "needed to read the GitHub API"
[ -f "$REGISTER" ] || ws_die "no register at $REGISTER"
[ -x "$ENGINE" ] || ws_die "no engine at $ENGINE"

# --- discovery ---------------------------------------------------------------
# Every rtldev-middleware-* repository in the organisation, whatever its visibility or
# archived state — "<name>\t<archived>" per line. This deliberately differs from
# ws_discover in repos.sh, which answers a different question: that one lists what can
# be a submodule (public, non-archived, not the workspace itself), while settings
# management has to cover the internal, the private, the archived and this repository.
discover() {
  gh api --paginate "orgs/$ORG/repos?type=all&per_page=100" 2>/dev/null \
    | jq -r --arg p "$REPO_PREFIX" '
        .[] | select(.name | startswith($p)) | [.name, (.archived | tostring)] | @tsv
      '
}

# --- layer resolution --------------------------------------------------------
# Concatenation, not merging. The engine sources the result, so precedence is just the
# order the files appear in — no rules to remember and no way to half-override a value.
#
# The profile column may name more than one profile, comma-separated, for traits that
# cut across the audience split — "this repository's release pushes commits to its
# default branch" is true of both customer-facing and internal repositories, and stating
# it once beats repeating the same override in ten files. Profiles are applied left to
# right, so the rightmost wins where two of them set the same value.
resolve_config() {
  local name="$1" profiles="$2" out="$3" p
  local -a plist
  IFS=',' read -r -a plist <<<"$profiles"
  {
    printf '# resolved for %s (profiles: %s) — generated, do not edit\n' "$name" "$profiles"
    cat "$SETTINGS_DIR/_baseline.conf"
    for p in "${plist[@]}"; do
      printf '\n# --- profile: %s ---\n' "$p"
      cat "$SETTINGS_DIR/_profile-${p}.conf"
    done
    if [ -f "$SETTINGS_DIR/${name}.conf" ]; then
      printf '\n# --- repository override ---\n'
      cat "$SETTINGS_DIR/${name}.conf"
    fi
  } >"$out"
}

# A profile named in the register with no file behind it is fatal, not skipped. A typo
# that silently drops a layer would apply the baseline as if the exception had been
# declared — the settings equivalent of narrowing a bulk operation to all but one repo.
check_profiles() {
  local name="$1" profiles="$2" p
  local -a plist
  IFS=',' read -r -a plist <<<"$profiles"
  for p in "${plist[@]}"; do
    [ -f "$SETTINGS_DIR/_profile-${p}.conf" ] ||
      ws_die "$name names profile '$p', but $SETTINGS_DIR/_profile-${p}.conf does not exist"
  done
}

# --- --resolve ---------------------------------------------------------------

if [ "$RESOLVE_ONLY" -eq 1 ]; then
  [ "${#SELECTED[@]}" -gt 0 ] || ws_die "--resolve needs a repository name"
  for name in "${SELECTED[@]}"; do
    profile="$(ws_register_profile "$name")" || ws_die "not in the register: $name"
    if [ "$profile" = "exclude" ]; then
      ws_info "$name is excluded by the register — no configuration is resolved for it"
      continue
    fi
    check_profiles "$name" "$profile"
    resolve_config "$name" "$profile" /dev/stdout
  done
  exit 0
fi

# --- register vs GitHub ------------------------------------------------------
# Run before any reconciliation, so a report always states its own coverage. A register
# that is internally consistent but incomplete is the failure this whole mechanism
# exists to prevent: every subsequent "apply to all our repositories" silently covers
# one repository fewer, and nothing says so.

ws_info "Discovering ${REPO_PREFIX}* repositories in $ORG ..."
DISCOVERED="$(discover)"
[ -n "$DISCOVERED" ] || ws_die "discovery returned nothing — refusing to read that as 'no repositories'"

# Coverage is asked of the active repositories only. A retired repository is archived,
# and GitHub rejects settings writes on an archived repository — so demanding a register
# entry for one would demand an edit that can never be acted on. Archived repositories
# are filtered out of the coverage question here rather than out of discovery, so that a
# register which still names one is skipped by name further down instead of being handed
# to the engine.
ACTIVE="$(printf '%s\n' "$DISCOVERED" | awk -F'\t' '$2 == "false" { print $1 }' | sort)"

UNREGISTERED="$(comm -23 <(printf '%s\n' "$ACTIVE") <(ws_register_names))"
VANISHED="$(comm -13 <(printf '%s\n' "$DISCOVERED" | cut -f1 | sort) <(ws_register_names))"

if [ -n "$UNREGISTERED" ]; then
  ws_warn "not in $REGISTER:"
  while IFS= read -r name; do ws_warn "  $name"; done <<<"$UNREGISTERED"
fi
if [ -n "$VANISHED" ]; then
  ws_warn "registered but not found on GitHub (renamed, deleted, or not visible to this token):"
  while IFS= read -r name; do ws_warn "  $name"; done <<<"$VANISHED"
fi

# Archived repositories are looked up rather than listed in the register: GitHub rejects
# settings writes on them, so archiving one must not require an edit here to stay
# correct.
is_archived() {
  printf '%s\n' "$DISCOVERED" | awk -F'\t' -v n="$1" '$1 == n { print $2 }' | grep -qx true
}

# --- reconcile ---------------------------------------------------------------

if [ "${#SELECTED[@]}" -gt 0 ]; then
  TARGETS=("${SELECTED[@]}")
  for name in "${TARGETS[@]}"; do
    ws_register_profile "$name" >/dev/null || ws_die "not in the register: $name"
  done
else
  mapfile -t TARGETS < <(ws_register_names)
fi

TMPDIR_RESOLVED="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_RESOLVED"' EXIT

for name in "${TARGETS[@]}"; do
  profile="$(ws_register_profile "$name")"

  if [ "$profile" = "exclude" ]; then
    ws_info "skip $name — excluded by the register"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  if is_archived "$name"; then
    ws_info "skip $name — archived, GitHub rejects settings writes"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  check_profiles "$name" "$profile"
  conf="$TMPDIR_RESOLVED/${name}.conf"
  resolve_config "$name" "$profile" "$conf"

  printf '\n==> %s (%s)\n' "$name" "$profile"
  # Never exit from inside the loop: one unreachable repository must not decide that
  # every other repository goes unchecked.
  "$ENGINE" "--$MODE" --repo "$ORG/$name" --config "$conf"
  case "$?" in
    0) CLEAN=$((CLEAN + 1)) ;;
    1) DRIFTED+=("$name") ;;
    *) FAILED+=("$name") ;;
  esac
done

# --- summary -----------------------------------------------------------------

printf '\n===============================================================\n'
printf 'clean: %d   drifted: %d   failed: %d   skipped: %d\n' \
  "$CLEAN" "${#DRIFTED[@]}" "${#FAILED[@]}" "$SKIPPED"

[ "${#DRIFTED[@]}" -eq 0 ] || printf 'drifted: %s\n' "${DRIFTED[*]}"
[ "${#FAILED[@]}" -eq 0 ] || printf 'failed:  %s\n' "${FAILED[*]}"

if [ -n "$UNREGISTERED" ]; then
  printf 'unregistered: %s\n' "$(printf '%s' "$UNREGISTERED" | tr '\n' ' ')"
  exit 1
fi
[ "${#FAILED[@]}" -eq 0 ] || exit 2
[ "${#DRIFTED[@]}" -eq 0 ] || exit 1
exit 0
