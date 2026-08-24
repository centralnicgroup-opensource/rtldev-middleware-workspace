#!/usr/bin/env bash
#
# Attach-time workspace report: which submodules are populated, which are not.
#
# Populating them is NOT done here on purpose. The full set is ~2.4 GB (whmcs alone is
# 2 GB), so an automatic `git submodule update --init` would turn every first attach
# into a multi-minute download of repositories the session may never touch. Which
# repositories you want is a per-session decision, and `./scripts/ws.sh sync` is where
# you make it.
#
# bash rather than zsh — the interactive shell here is zsh, but shellcheck cannot
# parse zsh at all, so a zsh script in this repository would be unlintable rather than
# merely unlinted.
#
# Read-only and best-effort: it must never fail an attach, so every git call is guarded
# and the script always exits 0.

set -u

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 0

command -v git >/dev/null 2>&1 || exit 0
[ -f .gitmodules ] || exit 0

# `git submodule status` prefixes each line with '-' for "not initialised", '+' for
# "checked-out commit differs from the one recorded here", 'U' for a merge conflict,
# and a space for clean. Parsing that prefix is cheaper and more reliable than probing
# each directory, and it is the same source of truth `ws.sh status` uses.
total=0
ready=0
drift=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  total=$((total + 1))
  case "$line" in
    -*) ;;
    +*)
      ready=$((ready + 1))
      drift=$((drift + 1))
      ;;
    *) ready=$((ready + 1)) ;;
  esac
done < <(git submodule status 2>/dev/null)

[ "$total" -gt 0 ] || exit 0

printf '\n  Workspace: %d/%d repositories populated under repos/\n' "$ready" "$total"
if [ "$ready" -eq 0 ]; then
  printf '  Populate them with:  ./scripts/ws.sh sync            # all, blobless\n'
  printf '                       ./scripts/ws.sh sync php-sdk    # just one\n'
elif [ "$ready" -lt "$total" ]; then
  printf '  ./scripts/ws.sh status   for the full table, ./scripts/ws.sh sync to add more\n'
fi
[ "$drift" -gt 0 ] && printf '  %d checkout(s) differ from the pinned commit - ./scripts/ws.sh status\n' "$drift"
printf '\n'

exit 0
