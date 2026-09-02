#!/usr/bin/env bash
#
# Reconcile the GitHub settings of every rtldev-middleware-* repository, in every
# namespace this workspace spans, against the layered configuration in
# .github/repo-settings/.
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
# Each repository is reconciled with its own namespace's token, set for that one engine
# invocation. There is no global "current organisation" to get wrong, and no `gh auth
# switch` left behind by a run that died half way.
#
# Exit status: 0 clean, 1 drift or an unregistered repository, 2 could not run.

set -uo pipefail

# shellcheck source=scripts/repos.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/repos.sh"

# "Not in the register" is the wrong thing to say about a repository that is in the
# *other* register. There are two now, they answer different questions, and a person who
# has just been told a name is unknown will go and add it to the one this script reads —
# which is precisely the decision repos-exclude.tsv exists to have already made.
no_such_row() {
  local name="$1" org
  for org in "${WS_ORGS[@]}"; do
    if ws_is_excluded "$org" "$name"; then
      ws_die "$org/$name is declared out of this workspace in $(basename "$WS_EXCLUDE") — it has no settings configuration here, and adding a row for it would undo that decision"
    fi
  done
  ws_die "not in $(basename "$WS_REGISTER"): $name"
}

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
    profile="$(ws_register_profile "$name")" || no_such_row "$name"
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

# ws_die exits 1, and this script reserves 1 for "there is drift". A precondition that
# fails is "could not run", so the aborting checks are called in a subshell whose exit is
# remapped to 2 — otherwise a broken register would report as ordinary drift, and the
# person reading the summary would go looking for a settings difference.
must() { ("$@") || exit 2; }

must ws_register_check

ws_info "Discovering ${REPO_PREFIX}* repositories in ${WS_ORGS[*]} ..."
# Whatever the visibility and whatever the archived state. This deliberately differs from
# the submodule register's question, which is what can be *checked out* — settings
# management has to cover the archived and this repository too, and neither register is
# derivable from the other.
DISCOVERED="$(ws_discover_all)" || exit 2

# The credential self-test, before any judgement is made about coverage. A register row
# the token cannot see used to be a warning here, on the reasoning that it might have
# been renamed; that reading is no longer available. With two namespaces and one token
# per namespace, "not visible to this token" is the likeliest cause and the most
# dangerous one — a repository whose settings this workspace owns silently stops being
# reconciled, and the report still says clean.
must ws_assert_discovery_covers_registers "$DISCOVERED"

# Coverage is asked of the active repositories only. A retired repository is archived,
# and GitHub rejects settings writes on an archived repository — so demanding a register
# entry for one would demand an edit that can never be acted on. Archived repositories
# are filtered out of the coverage question here rather than out of discovery, so that a
# register which still names one is skipped by name further down instead of being handed
# to the engine.
#
# repos-exclude.tsv comes out too. A repository declared not to be part of this workspace
# at all is not a settings gap; demanding a row for it here would mean recording the same
# decision in two files, and the drift job failing until both had it.
ACTIVE="$(
  printf '%s\n' "$DISCOVERED" | awk -F'\t' '$5 == "false" { print $1 "\t" $2 }' \
    | while IFS=$'\t' read -r o n; do
      ws_is_excluded "$o" "$n" || printf '%s\n' "$n"
    done | sort
)"

UNREGISTERED="$(comm -23 <(printf '%s\n' "$ACTIVE") <(ws_register_names))"

if [ -n "$UNREGISTERED" ]; then
  ws_warn "not in $REGISTER:"
  while IFS= read -r name; do ws_warn "  $name"; done <<<"$UNREGISTERED"
fi

# Archived repositories are looked up rather than listed in the register: GitHub rejects
# settings writes on them, so archiving one must not require an edit here to stay
# correct.
is_archived() {
  printf '%s\n' "$DISCOVERED" | awk -F'\t' -v n="$1" '$2 == n { print $5 }' | grep -qx true
}

# --- reconcile ---------------------------------------------------------------

if [ "${#SELECTED[@]}" -gt 0 ]; then
  TARGETS=("${SELECTED[@]}")
  for name in "${TARGETS[@]}"; do
    ws_register_profile "$name" >/dev/null || no_such_row "$name"
  done
else
  mapfile -t TARGETS < <(ws_register_names)
fi

TMPDIR_RESOLVED="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_RESOLVED"' EXIT

for name in "${TARGETS[@]}"; do
  profile="$(ws_register_profile "$name")"
  org="$(ws_register_org "$name")"

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

  printf '\n==> %s/%s (%s)\n' "$org" "$name" "$profile"
  # Never exit from inside the loop: one unreachable repository must not decide that
  # every other repository goes unchecked.
  ws_with_token "$org" "$ENGINE" "--$MODE" --repo "$org/$name" --config "$conf"
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
