#!/usr/bin/env bash
#
# A git credential helper that picks the token by namespace.
#
# .gitmodules stays uniformly HTTPS — one URL scheme for every submodule, whichever
# organisation it belongs to — which means git itself has to choose between two tokens on
# every fetch and every push. Nothing in git's own configuration can express that: a
# `credential.<url>` section matches a path only if it matches it *exactly*, so scoping by
# namespace that way would mean one section per repository, regenerated on every
# registration. A helper reads the path instead and answers for the whole namespace.
#
# Install it with `./scripts/ws.sh credentials --install`, which writes to this
# repository's own .git/config — never to a committed file, and never a token.
#
# The path arrives here only because that install sets `useHttpPath = true`. Without it
# git sends protocol and host alone, every namespace looks identical, and this helper
# would answer every request with whichever token came first.

set -uo pipefail

# shellcheck source=scripts/repos.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/repos.sh"

# Only `get` has an answer. `store` and `erase` are the helper being told about a
# credential it did not supply and does not keep, so they succeed silently — returning an
# error there would fail the git command that triggered them.
[ "${1:-}" = "get" ] || exit 0

# The request, as key=value lines terminated by a blank line or EOF. Read into named
# variables rather than eval'd: the values come from a URL, and one containing a shell
# metacharacter must stay a string.
req_host=""
req_path=""
req_protocol=""
while IFS='=' read -r key value; do
    [ -n "$key" ] || break
    case "$key" in
        protocol) req_protocol="$value" ;;
        host) req_host="$value" ;;
        path) req_path="$value" ;;
        *) ;;
    esac
done

[ "$req_protocol" = "https" ] || exit 0
[ "$req_host" = "github.com" ] || exit 0

# First path segment: the namespace. Empty for a request git made without a path, which
# is the misconfiguration this helper cannot work around — say so rather than answering
# with an arbitrary namespace's token.
org="${req_path%%/*}"
if [ -z "$org" ]; then
    ws_warn "git asked for github.com credentials without a path; run ./scripts/ws.sh credentials --install"
    exit 0
fi

token="$(ws_token_for_org "$org")"

# A namespace with no token of its own falls back to gh's, which is what makes the public
# namespace work with nothing configured — and what keeps this helper a superset of the
# gh credential helper it replaces in this repository's config, rather than a narrowing
# of it. A namespace WS_ORG_NEEDS_TOKEN calls out is not given that fallback: gh's token
# has one resource owner, and using it there is how a 404 gets read as "no such branch".
if [ -z "$token" ]; then
    if ws_org_needs_token "$org"; then
        ws_warn "no credential for the $org namespace — $(ws_credential_hint "$org")"
        exit 0
    fi
    command -v gh >/dev/null 2>&1 || exit 0
    token="$(gh auth token 2>/dev/null)" || exit 0
    [ -n "$token" ] || exit 0
fi

printf 'username=x-access-token\n'
printf 'password=%s\n' "$token"
