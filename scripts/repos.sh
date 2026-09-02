#!/usr/bin/env bash
#
# Shared library for the workspace scripts. Sourced, never executed directly.
#
# Two rules underlie everything here.
#
# The registers are the lists, and GitHub is the source of truth they are reconciled
# against (`ws.sh add`). Nothing walks repos/ to decide what exists — a directory that is
# present but unregistered, or registered but empty, is a state the tooling has to report
# rather than silently adopt.
#
# And a repository is identified by its namespace *and* its name. The middleware
# repositories are split across two GitHub organisations, and that split is permanent:
# consolidating them would have meant lowering the base permission of
# centralnicgroup-opensource from Read to No permission, which will not be done, so
# RSRMID-3022 was cancelled. There is therefore no single organisation to hardcode. Every
# query, every URL and every path under repos/ carries the namespace it belongs to.

# shellcheck shell=bash

# --- namespaces --------------------------------------------------------------
# The namespaces this workspace spans, in the order reports list them.
WS_ORGS=("centralnicgroup-opensource" "centralnicgroup")

# Whether reaching a namespace needs a credential of its own.
#
# A namespace holding nothing but public repositories is readable unauthenticated, so
# demanding a token there would be ceremony that buys nothing: a public listing is the
# same length for every caller, so it cannot come back silently short. A namespace
# holding private repositories is the opposite case — an unauthenticated or wrongly
# scoped listing there returns [], not an error — so a missing token must fail before the
# query rather than after it.
#
# This is a declaration, not a derivation, and it can go stale: if a private repository
# ever appears in centralnicgroup-opensource, a token would start to matter there and
# this line would still say false. That is caught downstream rather than here, by
# ws_assert_discovery_covers_registers — a registered repository the credential cannot
# see is fatal whatever this table claims.
declare -A WS_ORG_NEEDS_TOKEN=(
    [centralnicgroup-opensource]=false
    [centralnicgroup]=true
)

# The open-source namespace, named separately from WS_ORGS because two scripts are
# deliberately scoped to it rather than to both, and both need saying out loud:
# eol-policy.sh reads *this* organisation's Actions variables, which is where the EOL
# products are declared, and node-policy.sh has not been widened yet (RSRMID-3036).
# shellcheck disable=SC2034  # read by node-policy.sh and eol-policy.sh, which source this
WS_ORG_OPENSOURCE="centralnicgroup-opensource"

REPO_PREFIX="rtldev-middleware-"

# The workspace repository itself is in a namespace we span and matches the prefix, so
# every discovery query returns it. Excluded by name rather than by "the repo we are in":
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
# Repositories are addressed by their short name (php-sdk) everywhere a human types one,
# and by their full name (rtldev-middleware-php-sdk) everywhere git or GitHub sees one.
# The directory under repos/<org>/ keeps the FULL name on purpose: opening
# repos/<org>/<name> as its own devcontainer resolves ${localWorkspaceFolderBasename} to
# the directory name, so a short directory would silently give that container a different
# name and workspace path than the same repository cloned standalone.
ws_full_name() {
    case "$1" in
        "$REPO_PREFIX"*) printf '%s' "$1" ;;
        *) printf '%s%s' "$REPO_PREFIX" "$1" ;;
    esac
}

ws_short_name() { printf '%s' "${1#"$REPO_PREFIX"}"; }

# --- credentials -------------------------------------------------------------
# One token per namespace, resolved per call. Never `gh auth switch`: that is global,
# stateful and outlives the command that ran it, so a script that switched and then died
# would leave the next command talking to the wrong namespace.
#
# Resolution order, most explicit first:
#   1. WS_TOKEN_<NAMESPACE> in the environment. This is the CI half — a workflow maps its
#      secret onto the variable for the namespace that secret belongs to.
#   2. A file named after the namespace in WS_TOKEN_DIR, mounted from the host read-only.
#   3. Nothing, which means "use whatever gh or curl already has". Legitimate for a
#      namespace WS_ORG_NEEDS_TOKEN says needs none.
#
# The namespace-to-secret mapping lives in the workflows, and it has to, because it is not
# derivable: a secret called RTLDEV_MW_CI_TOKEN exists in *both* organisations holding a
# different PAT in each, so a workflow silently inherits whichever belongs to the
# organisation its own repository lives in. The centralnicgroup PAT is therefore exposed
# to this repository under a different name, RTLDEV_MW_CI_TOKEN_CNG. Neither token stands
# in for the other: each is strictly scoped to one resource owner.
WS_TOKEN_DIR="${WS_TOKEN_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/rtldev-middleware-workspace/tokens}"

ws_token_env_for_org() {
    local slug="$1"
    slug="${slug//[^a-zA-Z0-9]/_}"
    printf 'WS_TOKEN_%s' "$(printf '%s' "$slug" | tr '[:lower:]' '[:upper:]')"
}

ws_org_needs_token() { [ "${WS_ORG_NEEDS_TOKEN[$1]:-false}" = "true" ]; }

# The token for a namespace, or nothing. Prints only the token, so it is safe in $( ) —
# it never dies, because "no token" is not by itself an error (see ws_assert_credentials,
# which is where that judgement is made, once, before any query runs).
ws_token_for_org() {
    local org="$1" var val file
    var="$(ws_token_env_for_org "$org")"
    val="${!var:-}"
    if [ -n "$val" ]; then
        printf '%s' "$val"
        return 0
    fi
    file="$WS_TOKEN_DIR/$org"
    if [ -r "$file" ]; then
        # First non-blank line, so an editor's trailing newline or a comment header in the
        # file does not become part of the Authorization header.
        grep -m1 -v '^[[:space:]]*\(#\|$\)' "$file" | tr -d '[:space:]'
        return 0
    fi
    return 0
}

# Where a namespace's token would come from, for an error message that can be acted on.
ws_credential_hint() {
    local org="$1"
    printf 'set %s, or put the token in %s/%s' \
        "$(ws_token_env_for_org "$org")" "$WS_TOKEN_DIR" "$org"
}

# Which of the three sources answered, for `ws.sh credentials`. Never the token itself.
ws_token_source() {
    local org="$1" var
    var="$(ws_token_env_for_org "$org")"
    if [ -n "${!var:-}" ]; then
        printf '$%s' "$var"
    elif [ -r "$WS_TOKEN_DIR/$org" ] && [ -n "$(ws_token_for_org "$org")" ]; then
        printf '%s/%s' "$WS_TOKEN_DIR" "$org"
    elif ws_org_needs_token "$org"; then
        # Not "gh", even when gh is authenticated. ws_with_token and ws_gh_api refuse to
        # send gh's token to a namespace that needs its own, so reporting it as the source
        # would answer "where does this namespace's token come from" with a token that is
        # never used — in the one command whose whole job is to explain why a namespace
        # came back empty.
        printf 'none (gh'"'"'s token is not accepted for this namespace)'
    elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        printf 'gh (not namespace-specific)'
    else
        printf 'none'
    fi
}

# Run before anything queries GitHub. A namespace that needs a token and has none must
# fail here rather than three seconds later with an empty list.
ws_assert_credentials() {
    local org missing=()
    for org in "${WS_ORGS[@]}"; do
        ws_org_needs_token "$org" || continue
        [ -n "$(ws_token_for_org "$org")" ] || missing+=("$org")
    done
    [ "${#missing[@]}" -eq 0 ] && return 0
    for org in "${missing[@]}"; do
        ws_warn "no credential for $org — $(ws_credential_hint "$org")"
    done
    ws_die "missing credential for ${#missing[@]} namespace(s): ${missing[*]}"
}

# --- GitHub reads ------------------------------------------------------------
# One page of the REST API, in the given namespace. gh is preferred where it exists;
# unauthenticated curl is the last fallback, which is what lets the workspace be set up
# against a public namespace before anyone runs `gh auth login`.
#
# A resolved token is never dropped on the way to that fallback. Falling back to an
# unauthenticated request while holding a perfectly good token would return a shorter
# list, not an error — the failure this whole layer exists to make impossible — so curl
# gets the token too, through --config on stdin rather than an -H argument, which would
# put it in the process list.
ws_gh_api() {
    local org="$1" path="$2" token
    token="$(ws_token_for_org "$org")"
    if [ -z "$token" ] && ws_org_needs_token "$org"; then
        ws_warn "no credential for $org — $(ws_credential_hint "$org")"
        return 1
    fi
    if [ -n "$token" ]; then
        if command -v gh >/dev/null 2>&1; then
            GH_TOKEN="$token" gh api "$path"
        else
            printf 'header = "Authorization: Bearer %s"\n' "$token" \
                | curl -fsSL -H 'Accept: application/vnd.github+json' \
                    --config - "https://api.github.com/$path"
        fi
    elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        gh api "$path"
    else
        curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/$path"
    fi
}

# Any command, with the given namespace's token in GH_TOKEN for the length of that one
# command. This is the whole of "per-call GH_TOKEN rather than gh auth switch": a switch
# is global and stateful, so a script that switched and then died would leave the next
# command in the session talking to the wrong namespace.
ws_with_token() {
    local org="$1" token
    shift
    token="$(ws_token_for_org "$org")"
    if [ -n "$token" ]; then
        GH_TOKEN="$token" "$@"
        return $?
    fi
    # No token of its own. Running the command anyway, on whatever gh happens to hold, is
    # the precise mistake this layer exists to prevent for a namespace that needs one: a
    # PAT owned by another organisation answers 404 or [], and the caller reads that as
    # absence. So refuse and name the missing credential. For a namespace that needs
    # none — everything in it public — gh's token is a perfectly good answer.
    if ws_org_needs_token "$org"; then
        ws_warn "no credential for $org — $(ws_credential_hint "$org")"
        return 1
    fi
    "$@"
}

# gh with the right namespace's token, for the callers that need --paginate or --jq.
# gh only, no curl fallback: every one of them is authenticated-only anyway.
ws_gh() {
    local org="$1"
    shift
    ws_with_token "$org" gh "$@"
}

# git, with the per-namespace credential helper in force for this one invocation.
#
# Injected through GIT_CONFIG_COUNT rather than read from .git/config, so a fetch or a
# push picks the right namespace's token whether or not anyone has run
# `ws.sh credentials --install` — and so that CI, which has no .git/config of its own to
# install into, needs nothing but the two secrets in the environment.
#
# The empty credential.helper is the load-bearing part. Helpers accumulate across the
# system, global and local files and are consulted in that order, so without a reset the
# helper VS Code installs globally answers first and answers for both namespaces with one
# token. GIT_CONFIG_* entries are applied after every file, so the reset lands last.
#
# WS_NO_CREDENTIAL_HELPER=1 falls back to whatever git is already configured with, for the
# case where that is genuinely the right answer and this is in the way.
ws_git() {
    if [ -n "${WS_NO_CREDENTIAL_HELPER:-}" ]; then
        git "$@"
        return $?
    fi
    # GIT_TERMINAL_PROMPT=0 so a namespace with no usable credential fails immediately
    # with a named error instead of stopping on a username prompt. That matters here more
    # than it would anywhere else: these commands run in a loop over every registered
    # repository, and one prompt part-way through a nineteen-repository sync blocks the
    # whole run on a question nobody is watching for.
    GIT_TERMINAL_PROMPT=0 \
        GIT_CONFIG_COUNT=3 \
        GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0='' \
        GIT_CONFIG_KEY_1=credential.https://github.com.useHttpPath GIT_CONFIG_VALUE_1=true \
        GIT_CONFIG_KEY_2=credential.https://github.com.helper \
        GIT_CONFIG_VALUE_2="$WS_ROOT/scripts/git-credential-ws.sh" \
        git "$@"
}

ws_url() {
    local full org
    full="$(ws_full_name "$1")"
    org="${2:-$(ws_org_of "$full")}"
    printf 'https://github.com/%s/%s.git' "$org" "$full"
}

# --- the submodule register --------------------------------------------------
# Read from .gitmodules rather than `git submodule status`, because this must also answer
# correctly for entries that exist in the register but not yet in the index.
#
# The path carries the namespace: repos/<org>/<full-name>. So .gitmodules needs no
# namespace column of its own — it already has one, in the path and in the url.
ws_registered_paths() {
    git -C "$WS_ROOT" config --file .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null \
        | awk '{print $2}' | sort
}

ws_registered() { ws_registered_paths | sed 's|.*/||' | sort; }

# "<org>\t<name>" for one registered path, or a failure. A path of the wrong shape fails
# rather than being parsed as best it can: repos/<name> is the pre-RSRMID-3027 two-segment
# layout, and taking its last-but-one segment as the namespace would yield the repository
# name — a value that looks like an answer and is not one.
ws_split_path() {
    local rest
    case "$1" in
        repos/*/*) rest="${1#repos/}" ;;
        *) return 1 ;;
    esac
    # Exactly two segments left, so exactly three in the path.
    case "$rest" in
        */*/*) return 1 ;;
    esac
    # Newline-terminated, because a caller reading this with `read` gets EOF-without-newline
    # otherwise — which returns non-zero even though it assigned both variables, so a
    # `if ! read ...` guard would reject every well-formed path.
    printf '%s\t%s\n' "${rest%/*}" "${rest#*/}"
}

# The namespace a registered repository is in. Fails rather than guessing: a caller that
# does not know where a repository lives must not be handed a plausible-looking path.
ws_org_of() {
    local want p split
    want="$(ws_full_name "$1")"
    while IFS= read -r p; do
        [ "${p##*/}" = "$want" ] || continue
        split="$(ws_split_path "$p")" || {
            ws_warn "submodule path is not repos/<namespace>/<name>: $p"
            return 1
        }
        printf '%s' "${split%%$'\t'*}"
        return 0
    done < <(ws_registered_paths)
    return 1
}

ws_path() {
    local full org
    full="$(ws_full_name "$1")"
    org="${2:-}"
    if [ -z "$org" ]; then
        org="$(ws_org_of "$full")" || {
            ws_warn "not a registered repository, so its namespace is unknown: $full"
            return 1
        }
    fi
    printf 'repos/%s/%s' "$org" "$full"
}

ws_is_registered() {
    local want
    want="$(ws_full_name "$1")"
    ws_registered | grep -qxF "$want"
}

# Populated == the submodule's worktree actually has a .git. A directory that exists but
# is empty is what `git submodule update` has not run for yet, and is the single most
# common cause of "my bulk edit skipped three repos".
ws_is_populated() {
    local p
    p="$WS_ROOT/$(ws_path "$1")" || return 1
    [ -e "$p/.git" ]
}

# Resolves the repository arguments a subcommand was given into full names, one per line.
# No arguments means every registered repository — the workspace default, since "do this
# everywhere" is the reason the workspace exists.
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

# Same, restricted to repositories that are actually checked out. Subcommands that run a
# command *inside* a repository use this and report the skipped ones, rather than failing
# on the first empty directory.
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

# --- the exclusion register ---------------------------------------------------
# Curated non-registration, declared with a reason. Without it, "this repository is not a
# submodule here" and "nobody has got round to registering it" are the same state, and
# the drift job can only be made to stop complaining by turning it off.
#
# Tab-separated: <org>\t<repository>\t<reason>. A row for a namespace outside WS_ORGS is
# inert rather than an error — it is declared ahead of that namespace going live, and the
# only question ever asked of this file is "is <repository> in <org> excluded".
WS_EXCLUDE="$WS_ROOT/.github/repos-exclude.tsv"

ws_exclude_rows() {
    [ -f "$WS_EXCLUDE" ] || return 0
    grep -v '^[[:space:]]*#' "$WS_EXCLUDE" | grep -v '^[[:space:]]*$'
}

ws_is_excluded() {
    local org="$1" name="$2" o n
    while IFS=$'\t' read -r o n _; do
        [ "$o" = "$org" ] && [ "$n" = "$name" ] && return 0
    done < <(ws_exclude_rows)
    return 1
}

# --- the settings register ----------------------------------------------------
# The *other* register. .gitmodules (above) lists what is checked out for bulk code
# edits — non-archived, excluding this repository and whatever repos-exclude.tsv names.
# This one lists what the workspace manages the GitHub *settings* of, which has to cover
# the archived and this repository too. Neither is derivable from the other.
#
# Tab-separated: <org>\t<repository>\t<profile>\t<note>. The namespace column is the one
# thing that made a whmcs-src row inexpressible before RSRMID-3027: the engine is invoked
# as `--repo <org>/<name>`, and with a single hardcoded organisation a row for the other
# namespace resolved to a repository that does not exist.
#
# These live here rather than in org-settings.sh because there is now more than one
# reader: org-settings.sh resolves a row's profile column into settings, and
# deploykey-policy.sh checks one trait from that column against the repositories
# themselves. Two parsers of one file would eventually disagree about what a row says.
WS_REGISTER="$WS_ROOT/.github/repo-settings/_register.tsv"

# Comments and blank lines out, tabs preserved.
ws_register_rows() {
    [ -f "$WS_REGISTER" ] || ws_die "no register at $WS_REGISTER"
    grep -v '^[[:space:]]*#' "$WS_REGISTER" | grep -v '^[[:space:]]*$'
}

ws_register_names() { ws_register_rows | cut -f2 | sort; }

# Both registers, checked before anything acts on them. Cheap, offline, and it fails on
# the states that would otherwise turn into a wrong answer rather than an error.
#
# Repository names have to be unique across the namespaces, because that is how every
# register is keyed and how every command addresses a repository: `ws.sh status php-sdk`
# names one repository, and a duplicate would silently resolve to whichever entry came
# first. It is checked in both registers, not just the settings one — .gitmodules is
# looked up by name the same way, through ws_org_of.
ws_register_check() {
    local dupes org name

    dupes="$(ws_register_names | uniq -d)"
    [ -z "$dupes" ] || ws_die "$(basename "$WS_REGISTER") names the same repository in more than one namespace: $(printf '%s' "$dupes" | tr '\n' ' ')"

    while IFS=$'\t' read -r org name _; do
        [ -n "$org" ] && [ -n "$name" ] ||
            ws_die "$(basename "$WS_REGISTER"): a row is missing its namespace or its repository name"
        [ -n "${WS_ORG_NEEDS_TOKEN[$org]+set}" ] ||
            ws_die "$(basename "$WS_REGISTER"): $name names namespace '$org', which this workspace knows nothing about"
    done < <(ws_register_rows)

    dupes="$(ws_registered | uniq -d)"
    [ -z "$dupes" ] || ws_die ".gitmodules registers the same repository in more than one namespace: $(printf '%s' "$dupes" | tr '\n' ' ')"

    # An absent exclusion register is not "nothing is excluded" — it is a file someone
    # deleted, and reading it as an empty list would make the drift job start failing on
    # three sandboxes with no explanation of where their reasons went.
    [ -f "$WS_EXCLUDE" ] || ws_die "no exclusion register at $WS_EXCLUDE"
    local reason
    while IFS=$'\t' read -r org name reason; do
        [ -n "$org" ] && [ -n "$name" ] ||
            ws_die "$(basename "$WS_EXCLUDE"): a row is missing its namespace or its repository name"
        [ -n "${WS_ORG_NEEDS_TOKEN[$org]+set}" ] ||
            ws_die "$(basename "$WS_EXCLUDE"): $name names namespace '$org', which this workspace knows nothing about"
        # The reason is the file. A row without one records that someone decided, not what
        # they decided, and is indistinguishable from the silence it exists to replace.
        [ -n "${reason//[[:space:]]/}" ] ||
            ws_die "$(basename "$WS_EXCLUDE"): $org/$name is excluded with no reason given"
    done < <(ws_exclude_rows)
}

ws_register_field() {
    local want="$1" field="$2" org name profile note
    while IFS=$'\t' read -r org name profile note; do
        if [ "$name" = "$want" ]; then
            case "$field" in
                org) printf '%s' "$org" ;;
                profile) printf '%s' "$profile" ;;
                note) printf '%s' "$note" ;;
            esac
            return 0
        fi
    done < <(ws_register_rows)
    return 1
}

ws_register_org() { ws_register_field "$1" org; }
ws_register_profile() { ws_register_field "$1" profile; }

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
# Every rtldev-middleware-* repository in one namespace, one
#   "<org>\t<name>\t<default-branch>\t<visibility>\t<archived>"
# per line. Dies on a transport failure, so callers use it as
# `rows="$(ws_discover_org "$org")" || exit 1`.
ws_discover_org() {
    local org="$1" page=1 body count
    while :; do
        body="$(ws_gh_api "$org" "orgs/$org/repos?type=all&per_page=100&page=$page")" ||
            ws_die "GitHub API request failed for $org (page $page) — $(ws_credential_hint "$org")"
        count="$(printf '%s' "$body" | jq 'length')"
        printf '%s' "$body" | jq -r --arg org "$org" --arg prefix "$REPO_PREFIX" '
            .[]
            | select(.name | startswith($prefix))
            | [$org, .name, .default_branch, .visibility, (.archived | tostring)] | @tsv
        '
        [ "$count" -eq 100 ] || break
        page=$((page + 1))
    done | sort
}

# The same across every namespace this workspace spans — the raw ground truth, whatever
# the visibility and whatever the archived state. Every caller filters it for its own
# question, and the two that matter here ask genuinely different ones.
#
# An empty result for a *single* namespace is fatal, and this is the check that carries
# the most weight in the whole file. A fine-grained PAT has exactly one resource owner
# and answers a listing for any other namespace with [] rather than with an error; a
# token without private-repository scope omits exactly the repositories that need one.
# Both read as "that namespace is empty" unless something refuses to believe it.
ws_discover_all() {
    ws_need jq "needed to read the GitHub API"
    ws_assert_credentials
    local org rows
    for org in "${WS_ORGS[@]}"; do
        rows="$(ws_discover_org "$org")" || return 1
        if [ -z "$rows" ]; then
            ws_warn "$(ws_credential_hint "$org")"
            ws_die "no ${REPO_PREFIX}* repository found in $org — refusing to read an empty list as 'that namespace has none'"
        fi
        printf '%s\n' "$rows"
    done
}

# The submodule register's question: what can be a submodule here. Non-archived (a
# retired repository is archived, and archiving is how it leaves the checks), not this
# repository, and not something repos-exclude.tsv declares out of scope.
#
# A filter over ws_discover_all rather than a second query, so one invocation of `ws.sh
# add` pages the API once and both the coverage check and the candidate list are computed
# from the same answer. Reads rows on stdin, emits "<org>\t<name>\t<default-branch>".
ws_filter_submodule_candidates() {
    local org name branch archived
    while IFS=$'\t' read -r org name branch _ archived; do
        [ -n "$name" ] || continue
        [ "$archived" = "false" ] || continue
        [ "$name" != "$SELF_REPO" ] || continue
        ws_is_excluded "$org" "$name" && continue
        printf '%s\t%s\t%s\n' "$org" "$name" "$branch"
    done
}

# The credential self-test, and the reason there is only one of them.
#
# A credential that is missing, scoped to the wrong namespace, or without
# private-repository scope does not fail a listing. It returns a shorter one. So the
# question worth asking is not "did the query work" but "did it return the repositories
# we already know are there" — every repository either register names must appear in its
# namespace's result.
#
# That makes the test proven against private repositories by construction: the rows it
# can actually catch are the non-public ones, because a public repository is visible to
# any authenticated token whatever its resource owner. A self-test pointed at a public
# repository is a test that cannot fail, which is how this was got wrong once while
# establishing the field data for RSRMID-3027.
#
# A renamed or deleted repository trips this too, and that is correct: whichever of the
# three it is, continuing would mean reconciling against a list that is missing something.
ws_assert_discovery_covers_registers() {
    local discovered="$1" missing=() path org name

    while IFS= read -r path; do
        [ -n "$path" ] || continue
        if ! IFS=$'\t' read -r org name < <(ws_split_path "$path"); then
            ws_warn "submodule path is not repos/<namespace>/<name>: $path"
            missing+=("$path	.gitmodules (malformed path)")
            continue
        fi
        printf '%s\n' "$discovered" | cut -f1,2 | grep -qxF "$org	$name" ||
            missing+=("$org/$name	.gitmodules")
    done < <(ws_registered_paths)

    while IFS=$'\t' read -r org name _; do
        [ -n "$name" ] || continue
        printf '%s\n' "$discovered" | cut -f1,2 | grep -qxF "$org	$name" ||
            missing+=("$org/$name	$(basename "$WS_REGISTER")")
    done < <(ws_register_rows)

    [ "${#missing[@]}" -eq 0 ] && return 0

    ws_warn "registered repositories that discovery did not return:"
    printf '  %s\n' "${missing[@]}" >&2
    ws_warn "either the credential for that namespace cannot see them, or they have been renamed or deleted"
    ws_warn "namespaces queried, and where each token came from:"
    for org in "${WS_ORGS[@]}"; do
        ws_warn "  $org — $(ws_token_source "$org")"
    done
    ws_die "discovery is incomplete; refusing to reconcile against a list that is missing ${#missing[@]} known repositories"
}
