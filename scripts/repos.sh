#!/usr/bin/env bash
#
# Shared library for the workspace scripts. Sourced, never executed directly.
#
# One rule underlies everything here: .gitmodules is the register of what belongs to
# this workspace, and GitHub is the source of truth it is reconciled against
# (`ws.sh add`). Nothing walks repos/ to decide what exists — a directory that is
# present but unregistered, or registered but empty, is a state the tooling has to
# report rather than silently adopt.

# shellcheck shell=bash

ORG="centralnicgroup-opensource"
REPO_PREFIX="rtldev-middleware-"

# The workspace repository itself is in the org and matches the prefix, so every
# discovery query returns it. Excluded by name rather than by "the repo we are in":
# the check has to give the same answer when run from a clone under any directory name.
SELF_REPO="${REPO_PREFIX}workspace"

WS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WS_ROOT

# --- output ------------------------------------------------------------------
# stderr for everything that is not the command's result, so `ws.sh grep ... | wc -l`
# and `ws.sh status | column -t` stay pipeable.
ws_info() { printf '%s\n' "$*" >&2; }
ws_warn() { printf 'warning: %s\n' "$*" >&2; }
ws_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

ws_need() {
  command -v "$1" >/dev/null 2>&1 || ws_die "$1 is required but not installed${2:+ ($2)}"
}

# --- name handling -----------------------------------------------------------
# Repositories are addressed by their short name (php-sdk) everywhere a human types
# one, and by their full name (rtldev-middleware-php-sdk) everywhere git or GitHub
# sees one. The directory under repos/ keeps the FULL name on purpose: opening
# repos/<name> as its own devcontainer resolves ${localWorkspaceFolderBasename} to the
# directory name, so a short directory would silently give that container a different
# name and workspace path than the same repository cloned standalone.
ws_full_name() {
  case "$1" in
    "$REPO_PREFIX"*) printf '%s' "$1" ;;
    *) printf '%s%s' "$REPO_PREFIX" "$1" ;;
  esac
}

ws_short_name() { printf '%s' "${1#"$REPO_PREFIX"}"; }

ws_path() { printf 'repos/%s' "$(ws_full_name "$1")"; }

ws_url() { printf 'https://github.com/%s/%s.git' "$ORG" "$(ws_full_name "$1")"; }

# --- the register ------------------------------------------------------------
# Read from .gitmodules rather than `git submodule status`, because this must also
# answer correctly for entries that exist in the register but not yet in the index.
ws_registered() {
  git -C "$WS_ROOT" config --file .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null \
    | awk '{print $2}' | sed 's|^repos/||' | sort
}

ws_is_registered() {
  local want
  want="$(ws_full_name "$1")"
  ws_registered | grep -qxF "$want"
}

# Populated == the submodule's worktree actually has a .git. A directory that exists
# but is empty is what `git submodule update` has not run for yet, and is the single
# most common cause of "my bulk edit skipped three repos".
ws_is_populated() {
  local p
  p="$WS_ROOT/$(ws_path "$1")"
  [ -e "$p/.git" ]
}

# Resolves the repository arguments a subcommand was given into full names, one per
# line. No arguments means every registered repository — the workspace default, since
# "do this everywhere" is the reason the workspace exists.
#
# Unknown names are fatal rather than skipped: a typo that silently narrows a bulk
# operation to all but one of the registered repositories is worse than one that stops.
ws_select() {
  if [ "$#" -eq 0 ]; then
    ws_registered
    return
  fi
  local arg full
  for arg in "$@"; do
    full="$(ws_full_name "$arg")"
    ws_is_registered "$full" || ws_die "not a registered repository: $arg (see ./scripts/ws.sh status)"
    printf '%s\n' "$full"
  done
}

# Same, restricted to repositories that are actually checked out. Subcommands that run
# a command *inside* a repository use this and report the skipped ones, rather than
# failing on the first empty directory.
ws_select_populated() {
  local full skipped=()
  while IFS= read -r full; do
    if ws_is_populated "$full"; then
      printf '%s\n' "$full"
    else
      skipped+=("$(ws_short_name "$full")")
    fi
  done < <(ws_select "$@")
  if [ "${#skipped[@]}" -gt 0 ]; then
    ws_warn "skipped ${#skipped[@]} uninitialised repo(s): ${skipped[*]}"
    ws_warn "populate them with: ./scripts/ws.sh sync ${skipped[*]}"
  fi
}

# --- the settings register ----------------------------------------------------
# The *other* register. .gitmodules (above) lists what is checked out for bulk code
# edits — public, non-archived, excluding this repository. This one lists what the
# workspace manages the GitHub *settings* of, which has to cover the internal, the
# private, the archived and this repository too. Neither is derivable from the other.
#
# These live here rather than in org-settings.sh because there is now more than one
# reader: org-settings.sh resolves a row's profile column into settings, and
# deploykey-policy.sh checks one trait from that column against the repositories
# themselves. Two parsers of one file would eventually disagree about what a row says.
WS_REGISTER="$WS_ROOT/.github/repo-settings/_register.tsv"

# Comments and blank lines out, tabs preserved. Everything downstream reads
# "<repository>\t<profile>" and ignores the note column.
ws_register_rows() {
  [ -f "$WS_REGISTER" ] || ws_die "no register at $WS_REGISTER"
  grep -v '^[[:space:]]*#' "$WS_REGISTER" | grep -v '^[[:space:]]*$'
}

ws_register_names() { ws_register_rows | cut -f1 | sort; }

ws_register_profile() {
  local want="$1" name profile
  while IFS=$'\t' read -r name profile _; do
    if [ "$name" = "$want" ]; then
      printf '%s' "$profile"
      return 0
    fi
  done < <(ws_register_rows)
  return 1
}

# True when a profile column names <trait>. The column is split on commas and each field
# compared for equality — never a substring test against the whole column. A trait name
# is a prefix of any longer trait name someone adds later, and a grep would then answer
# yes for a trait the register does not carry.
ws_profile_has() {
  local profiles="$1" want="$2" p
  local -a plist
  IFS=',' read -r -a plist <<<"$profiles"
  for p in "${plist[@]}"; do
    [ "${p//[[:space:]]/}" = "$want" ] && return 0
  done
  return 1
}

# --- GitHub discovery --------------------------------------------------------
# Public, unauthenticated REST works for the whole query, so the workspace can be set
# up before anyone runs `gh auth login`. gh is preferred when it is authenticated
# purely for the rate limit (5000/h against 60/h).
ws_gh_api() {
  local path="$1"
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh api "$path"
  else
    curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/$path"
  fi
}

# Every public, non-archived rtldev-middleware-* repository in the org, one
# "<full-name>\t<default-branch>" per line. The workspace repository itself is
# filtered out — nesting it inside itself is not a thing.
ws_discover() {
  ws_need jq "needed to read the GitHub API"
  local page=1 body count
  while :; do
    body="$(ws_gh_api "orgs/$ORG/repos?type=public&per_page=100&page=$page")" || ws_die "GitHub API request failed"
    count="$(printf '%s' "$body" | jq 'length')"
    printf '%s' "$body" | jq -r --arg prefix "$REPO_PREFIX" --arg self "$SELF_REPO" '
      .[]
      | select(.archived == false and .private == false)
      | select(.name | startswith($prefix))
      | select(.name != $self)
      | [.name, .default_branch] | @tsv
    '
    [ "$count" -eq 100 ] || break
    page=$((page + 1))
  done | sort
}
