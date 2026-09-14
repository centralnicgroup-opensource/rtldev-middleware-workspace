#!/usr/bin/env bash
#
# Report every rtldev-middleware-* repository whose devcontainer does not use the shared
# devbase Feature, at the current major, with none of the hand-maintained frame it
# replaces still committed.
#
#   scripts/devbase-policy.sh                  # report drift everywhere
#   scripts/devbase-policy.sh php-sdk node-sdk  # restrict to named repositories
#   scripts/devbase-policy.sh --verbose         # also print the repositories that are clean
#
# WHY THIS EXISTS
#
# Nothing checked this before RSRMID-3073, and RSRMID-3019 is what that cost: five
# repositories carried a commit titled "build(devcontainer): migrate onto the shared
# devbase Feature" that added exactly two files (.dockerignore, env-info.conf) and
# declared the Feature in neither of them. It went unnoticed for two weeks and was found
# by reading repositories one at a time by hand. A commit subject is not evidence its diff
# did what it says — that is precisely what a drift job is for.
#
# WHY THIS READS GITHUB RATHER THAN repos/
#
# The same reason node-policy.sh and deploykey-policy.sh do: the checkouts are frequently
# unpopulated — whmcs deliberately, at 2 GB — so a working-tree read reports "no
# devcontainer" for a repository that has one. Worse here than it sounds: while drafting
# this check, the local checkout of go-sdk showed no devbase declaration at all, which
# would have been reported as the RSRMID-3019 failure on a repository that may since have
# migrated on GitHub — the local pin is simply behind. Enumerating from the organisation
# and reading over the contents API is the only way to get the same answer from a laptop
# and from CI, and it needs no register: a repository is covered the moment it exists.
#
# THE THREE CATEGORIES, AND WHY THEY ARE KEPT SEPARATE
#
#   no .devcontainer/devcontainer.json at all   counted, never a failure. blesta, whmcs
#     and shareable-workflows do not carry a devcontainer today, and that is a fact about
#     those repositories, not drift — there is nothing here for this policy to have an
#     opinion about.
#
#   drift   a devcontainer.json exists and disagrees with the policy: no devbase
#     declaration, the wrong major, a declaration this cannot resolve to a major at all
#     (no tag, or pinned by digest — see "TAGLESS AND DIGEST-PINNED DECLARATIONS" below),
#     or leftover frame files still committed. This is the one category a commit in that
#     repository can fix, and the one RSRMID-3019 needed.
#
#   failed   the read itself did not succeed — the repository root, the directory listing
#     or the file content — OR the repository uses a devcontainer.json layout this cannot
#     verify at all: a root .devcontainer.json, or the multi-configuration layout
#     (.devcontainer/<folder>/devcontainer.json). "We could not tell" must never report
#     the same as "there is nothing there" or "this is clean": an unreadable .devcontainer
#     would otherwise silently clear the very repository the read could not see, which is
#     the same mistake an unread deploy-key listing would be in deploykey-policy.sh, and a
#     layout this does not parse is not evidence the repository has no devbase opinion —
#     it is evidence this script cannot currently read it.
#
# THE LEFTOVER CHECK IS THE ONE THAT WOULD ACTUALLY HAVE CAUGHT RSRMID-3019
#
# A repository can declare devbase and still keep the .zshrc, .czrc, .p10k.zsh and
# p10k-instant-prompt-vscode.zsh the Feature now supplies, or a Dockerfile that still
# clones powerlevel10k or zsh-autosuggestions itself — a *half*-migrated repository, which
# is exactly what the five RSRMID-3019 repositories were not (they had not even declared
# the Feature) but what a partial follow-up easily could be. Declaring the Feature is not
# evidence of having removed what it replaces, so this is checked independently and drives
# its file list from .github/devbase-policy.conf rather than hardcoding it here.
#
# THE VERSION-TOKEN TRAP
#
# `grep -c 'devbase:1'` also matches `devbase:10` — the same class of bug documented in
# deploykey-policy.sh for `@semantic-release/git` being a prefix of `@semantic-release/github`.
# The whole token after `devbase:` is captured to the end of the string and compared for
# exact equality against POLICY_DEVBASE_MAJOR; nothing here greps a version substring.
#
# THE FEATURE PATH NAMES ITS OWN PUBLISHING NAMESPACE
#
# The Feature reference is matched in full, including which namespace published it —
# ghcr.io/<WS_ORG_OPENSOURCE>/rtldev-middleware-devcontainer-features/devbase — built from
# repos.sh's WS_ORG_OPENSOURCE rather than a literal organisation name, because CLAUDE.md
# forbids writing one into a path. Without the namespace in the match,
# ghcr.io/somebody-else/rtldev-middleware-devcontainer-features/devbase:2 would satisfy it
# too: a devbase Feature by that name published by anyone, anywhere, is not the one this
# policy can vouch for.
#
# TAGLESS AND DIGEST-PINNED DECLARATIONS ARE NOT "NO DECLARATION"
#
# ghcr.io/.../devbase with no tag, and ghcr.io/.../devbase@sha256:... pinned by digest,
# both wire the Feature in — devcontainer.json does reference devbase, so reporting them
# with the RSRMID-3019 wording ("a migration commit that never wires the Feature in")
# would be false: this migration commit did. Both are still drift — a bare reference
# floats onto the newest release on every rebuild, and a digest pin never resolves to
# POLICY_DEVBASE_MAJOR at all — so each gets its own message saying what is actually wrong.
#
# devcontainer.json IS JSONC
#
# jq cannot parse it directly, and every repository's comments mention "devbase" in prose
# constantly — the workspace's own devcontainer.json alone says "devbase" two times before
# ever reaching the "features" key (five in the whole file). Whole-line comments (every
# repository here writes comments on their own line, never trailing after code) are
# stripped with a plain `grep -v '^[[:space:]]*//'` before anything is parsed, so a
# commented-out or merely-discussed reference is never read as a declaration. Trailing
# commas are not handled beyond that: nothing in this organisation's devcontainer.json
# files uses them, and a repository that starts would fail to parse and report as a
# failure, which is the right answer for "unverified" rather than a silent pass.
#
# WHAT COUNTS AS A COMMITTED LEFTOVER, AND WHERE IT IS LOOKED FOR
#
# Anywhere under .devcontainer/, at any depth, matched on the last path segment.
#
# This was very nearly the top level only, on the reasoning that the hand-maintained
# frame always sat beside devcontainer.json. That reasoning was wrong, and it was wrong
# about precisely the repositories this check exists for: go-sdk and java-sdk kept theirs
# in .devcontainer/configurations/, node-sdk and python-sdk in
# .devcontainer/supporting_files/configuration/. A flat listing would have passed all
# four of the RSRMID-3019 repositories as clean.
#
# The depth costs nothing anyway, because the tree is read in one recursive call per
# repository rather than one listing per directory — see read_devcontainer_dir.
#
# THE DOCKERFILE LEFTOVER-CLONE CHECK IS RECURSIVE TOO
#
# The same mistake was made a second time, in the one place the fix above was supposed to
# have already ruled it out: the Dockerfile content check matched only .devcontainer/Dockerfile
# exactly, so a .devcontainer/configurations/Dockerfile still cloning powerlevel10k read as
# clean — the exact half-migrated case this section exists for, and the same repositories
# (go-sdk, java-sdk) that motivated the fix above. It is now matched the same way: any file
# under .devcontainer/ whose last path segment is "Dockerfile" or starts with "Dockerfile."
# (so Dockerfile.dev counts too), at any depth, reported by its full path rather than its
# basename. A repository with no Dockerfile anywhere under .devcontainer/ at all — a
# compose frame, or a prebuilt `image` — has nothing for this half of the check to look at;
# --verbose says so explicitly, so "not checked" is never printed identically to "checked
# and clean".
#
# Content patterns are matched after stripping whole-line `#` comments, the same way
# devcontainer.json's `//` comments are stripped below — a migration commit's own comment
# announcing "powerlevel10k and zsh-autosuggestions now come from devbase" must not itself
# be reported as the clone it is describing the removal of.
#
# THE LOCK FILE IS A WARNING, NEVER A FAILURE
#
# Without a committed devcontainer-lock.json, `devbase:2` re-resolves to the newest 2.x on
# every rebuild — worth surfacing. But a lock file can only be produced by an actual
# container rebuild, which CI cannot do, so failing on it would make this job permanently
# red for work nobody can perform from CI. Reported prominently; exit status ignores it.
#
# Read-only, like every policy script here. It never writes to GitHub and never edits a
# devcontainer.json; bringing a repository into line is a commit someone makes there,
# because a devcontainer.json edit is a rebuild only that repository's own review can vet.
#
# A CREDENTIAL PROBLEM MUST NEVER LOOK LIKE AN ABSENCE
#
# centralnicgroup-opensource has WS_ORG_NEEDS_TOKEN=false, because everything in it used
# to be public. If RTLDEV_MW_CI_TOKEN is ever rotated out, gh falls back to the workflow's
# own GITHUB_TOKEN, which can still read *public* repositories in any organisation —
# ws_discover_org would still get a non-empty page back, and ws_discover_all's
# per-namespace emptiness check would pass, while every private and internal repository in
# that namespace silently never appeared in the run. So this runs both of the guards
# org-settings.sh runs: ws_register_check before discovery (a malformed register is "could
# not run", not drift), and ws_assert_discovery_covers_registers right after it — the
# documented catch for WS_ORG_NEEDS_TOKEN going stale, which works here because the
# registers name private repositories that a public-only token cannot return.
#
# deploykey-policy.sh deliberately skips the second guard, and says why in its own
# comment: its checks run per register row directly, using that row's own namespace, so a
# row discovery missed is still examined and fails on its own as unreadable. This script
# has no such per-row fallback — its whole scope *is* the discovery result, so a namespace
# missing its private repositories is invisible here rather than reported per repository.
# That difference, not an oversight, is why this one needs the whole-run guard and its
# sibling does not.
#
# THE TREE READ IS SCOPED TO .devcontainer/, NOT THE WHOLE REPOSITORY
#
# read_devcontainer_dir asks GitHub for the tree at "$branch:.devcontainer" rather than the
# repository root, for two reasons. First, a repository root this size cannot truncate, but
# reading the whole tree to throw most of it away invited exactly that. Second, asking for
# a path that does not exist gets a clean 404 back — which is precisely the "no
# .devcontainer at all" case, distinguished from every other failure by grepping the
# response for it rather than merging gh's stderr into the JSON (a stray notice on an
# otherwise *successful* call used to corrupt every repository's result at once; stdout and
# stderr are now captured separately). The `.truncated` guard stays regardless, as
# belt-and-braces — it should no longer be reachable at this scope, and if it ever is
# reached again that is itself worth knowing.
#
# NON-CANONICAL LAYOUTS FAIL CLOSED, THEY DO NOT JOIN "NO DEVCONTAINER"
#
# A root .devcontainer.json and the multi-configuration layout
# (.devcontainer/<folder>/devcontainer.json) are both real, supported devcontainer.json
# layouts that this script does not read — it only ever reads .devcontainer/devcontainer.json
# directly. Counting either one as "no devcontainer" would claim a fact about the
# repository ("it has no opinion about devbase") that is simply untrue; both report as
# FAILED instead, naming the layout, because "we do not support reading this" is honest and
# "there is nothing here" is not.
#
# Exit status: 0 clean, 1 drift, 2 could not run.

set -uo pipefail

# shellcheck source=scripts/repos.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/repos.sh"

POLICY_FILE="$WS_ROOT/.github/devbase-policy.conf"

DEVCONTAINER_DIR=".devcontainer"
DEVCONTAINER_JSON="$DEVCONTAINER_DIR/devcontainer.json"
DEVCONTAINER_LOCK="devcontainer-lock.json"

# The non-canonical layout this script cannot read at all — see "NON-CANONICAL LAYOUTS
# FAIL CLOSED" above. Checked only when .devcontainer/ itself is absent (read_devcontainer_dir's
# "absent" case), one contents probe per such repository.
ROOT_DEVCONTAINER_JSON=".devcontainer.json"

# The feature reference every repository is meant to carry, up to the version it pins —
# built from WS_ORG_OPENSOURCE (repos.sh) rather than a literal organisation name, per
# CLAUDE.md, and matched in full including that namespace. Matched as a shell glob against
# each key of .features, never as a grep over the raw text — see "THE VERSION-TOKEN TRAP"
# and "THE FEATURE PATH NAMES ITS OWN PUBLISHING NAMESPACE" above.
FEATURE_BASE="ghcr.io/$WS_ORG_OPENSOURCE/rtldev-middleware-devcontainer-features/devbase"

VERBOSE=0
SELECTED=()

DRIFTED=()
FAILED=()
DRIFT=()
CLEAN=0
NO_DEVCONTAINER=0
NO_DEVCONTAINER_NAMES=()
ARCHIVED=0
EXCLUDED=0
LOCK_MISSING=()

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

ws_need gh "needed to read devcontainer.json from every repository"
ws_need jq "needed to read the GitHub API"
[ -f "$POLICY_FILE" ] || ws_die "no policy at $POLICY_FILE"

# shellcheck source=.github/devbase-policy.conf
. "$POLICY_FILE"

for var in POLICY_DEVBASE_MAJOR POLICY_LEFTOVER_FILES POLICY_LEFTOVER_DOCKERFILE_PATTERNS; do
    [ -n "${!var:-}" ] || ws_die "$POLICY_FILE does not set $var"
done

is_excluded_conf() {
    local name
    for name in ${POLICY_EXCLUDE:-}; do
        [ "$name" = "$1" ] && return 0
    done
    return 1
}

# --- reading one repository's .devcontainer --------------------------------
# Sets DIR_ENTRIES and DIR_STATUS to "ok", "absent" or "unreadable". DIR_ENTRIES holds
# every blob path *under* .devcontainer/, one per line, relative to it — so
# "devcontainer.json" and "supporting_files/configuration/.zshrc" both appear.
#
# RECURSIVE, AND THAT IS THE WHOLE POINT
#
# The first version of this listed .devcontainer/ one level deep, on the reasoning that
# every leftover found so far sat there directly. That reasoning was simply wrong, and
# checking it is what caught it: not one of the four repositories RSRMID-3019 migrated
# kept its frame at the top level. go-sdk and java-sdk had .devcontainer/configurations/,
# node-sdk and python-sdk had .devcontainer/supporting_files/configuration/. A flat
# listing would have reported all four as clean — the exact repositories this check was
# written for, passing it. A check that cannot see the case it exists for is worse than
# no check, because it also stops anyone looking by hand.
#
# SCOPED TO .devcontainer/ ITSELF, NOT THE REPOSITORY ROOT
#
# The tree is asked for at "$branch:$DEVCONTAINER_DIR" rather than "$branch" — one recursive
# call per repository either way, so the depth still costs nothing, but scoped to the
# subtree it actually needs. Two things follow from that. It cannot truncate at anything
# like this repository's size, which makes the `.truncated` guard below belt-and-braces
# rather than load-bearing — kept anyway, because "should be unreachable" is not the same
# claim as "is". And asking for a path that is not there gets a clean, ordinary 404 back,
# which is exactly the "no .devcontainer at all" case — distinguished below from every
# other failure by reading gh's stderr, not by an empty result after the fact.
#
# A repository the API refuses outright — a bad credential, a rate limit, a transport
# failure — must not collapse into "this repository has no devcontainer" either, because
# that is exactly how an unreadable repository gets reported as clean. So a 404 is
# "absent"; anything else that fails is "unreadable".
#
# STDOUT AND STDERR ARE NEVER MERGED
#
# The previous version read `out="$(... 2>&1)"`, so any notice gh printed on a *successful*
# call landed prepended to the JSON body, jq then failed to parse it, and every repository
# in the run reported unreadable at once from one stray line. stderr now goes to its own
# file — one mktemp, made once, removed by the trap below — so a clean response stays clean
# JSON while a failed one can still be classified by what actually went wrong.
DIR_ENTRIES=""
DIR_STATUS=""

GH_ERR_FILE="$(mktemp)"
trap 'rm -f "$GH_ERR_FILE"' EXIT

read_devcontainer_dir() {
    local org="$1" name="$2" branch="$3" out status truncated
    DIR_ENTRIES=""
    DIR_STATUS="ok"
    out="$(ws_gh "$org" api "repos/$org/$name/git/trees/$branch:$DEVCONTAINER_DIR?recursive=1" 2>"$GH_ERR_FILE")"
    status=$?
    if [ "$status" -ne 0 ]; then
        if grep -q '404' "$GH_ERR_FILE"; then
            DIR_STATUS="absent"
        else
            DIR_STATUS="unreadable"
        fi
        return
    fi

    # Should now be unreachable — see "SCOPED TO .devcontainer/ ITSELF" above — but a
    # truncated tree is "unreadable", never "no leftovers": GitHub truncates very large
    # trees, and a missing path in a truncated answer means nothing at all.
    truncated="$(printf '%s' "$out" | jq -r '.truncated // false' 2>/dev/null)"
    if [ "$truncated" != "false" ]; then
        DIR_STATUS="unreadable"
        return
    fi

    DIR_ENTRIES="$(
        printf '%s' "$out" | jq -r '
            .tree[]
            | select(.type == "blob")
            | .path
        ' 2>/dev/null
    )"
    # Belt-and-braces: a subtree that resolved but holds nothing is the same as it not
    # existing, for every purpose this script has. Git cannot actually commit an empty
    # directory, so this should not be reachable either — but "absent" is the right label
    # if it ever is.
    [ -n "$DIR_ENTRIES" ] || DIR_STATUS="absent"
}

read_file() {
    local org="$1" name="$2" path="$3"
    ws_gh "$org" api "repos/$org/$name/contents/$path" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null
}

# Whether a root .devcontainer.json exists — the layout Fix 7 in the file header refuses to
# read. Called only on read_devcontainer_dir's "absent" path (there is no .devcontainer/ to
# have found it in otherwise), so this costs one extra call for the handful of repositories
# with no .devcontainer/ at all, never for the rest.
root_devcontainer_json_exists() {
    local org="$1" name="$2"
    ws_gh "$org" api "repos/$org/$name/contents/$ROOT_DEVCONTAINER_JSON" >/dev/null 2>&1
}

# An exact path under .devcontainer/ — for the files the frame keeps at the top level
# (devcontainer.json, devcontainer-lock.json), where "somewhere in the tree" would be the
# wrong question: the policy only ever reads devcontainer.json at that one canonical path,
# so a devcontainer.json elsewhere is Fix 7's non-canonical-layout case, not a hit here.
has_entry() { printf '%s\n' "$1" | grep -qxF "$2"; }

# A basename anywhere in the tree — for the leftovers, which is the whole reason the
# listing is recursive. Emits the matching paths, so the report can name where it found
# them rather than only that it did: "supporting_files/configuration/.zshrc" is the
# sentence someone can act on, ".zshrc" is one they have to go looking for. Doubles as the
# multi-configuration-layout detector below: a nested */devcontainer.json is exactly a
# last-path-segment match on "devcontainer.json".
#
# Compared on the last path segment with awk rather than a glob, so a file *named*
# .zshrc matches at any depth while one that merely ends in it (say "my.zshrc") does not.
find_leftover() { printf '%s\n' "$1" | awk -v b="$2" -F/ '$NF == b'; }

# Every Dockerfile-shaped file anywhere under .devcontainer/ — "Dockerfile" itself, or a
# last path segment starting with "Dockerfile." (so Dockerfile.dev counts) — at any depth.
# See "THE DOCKERFILE LEFTOVER-CLONE CHECK IS RECURSIVE TOO" above: has_entry against the
# single top-level path used to miss precisely the half-migrated repositories this whole
# file exists to catch.
#
# Documentation extensions are excluded, because "Dockerfile." is a prefix of Dockerfile.md
# as much as of Dockerfile.dev. A note *about* the migration is exactly the file most
# likely to name powerlevel10k in prose, and reporting it as a surviving clone would be a
# false accusation against the commit that did the removal — the mirror image of the
# comment-stripping below.
find_dockerfiles() {
    printf '%s\n' "$1" | awk -F/ '
        $NF != "Dockerfile" && index($NF, "Dockerfile.") != 1 { next }
        $NF ~ /\.(md|markdown|txt|rst|adoc)$/ { next }
        { print }
    '
}

# --- per-repository checks ---------------------------------------------------

check_repo() {
    local org="$1" name="$2" branch="$3" raw stripped
    DRIFT=()

    read_devcontainer_dir "$org" "$name" "$branch"
    case "$DIR_STATUS" in
        unreadable)
            FAILED+=("$name")
            printf '%-46s could not read %s\n' "$name" "$DEVCONTAINER_DIR"
            return
            ;;
        absent)
            # Fix 7: the repository may still carry a root .devcontainer.json — a real
            # layout, just not one this script reads. Costs one call, only ever taken here.
            if root_devcontainer_json_exists "$org" "$name"; then
                FAILED+=("$name")
                printf '%-46s uses a root %s — this policy only reads %s; unverified\n' \
                    "$name" "$ROOT_DEVCONTAINER_JSON" "$DEVCONTAINER_JSON"
                return
            fi
            NO_DEVCONTAINER=$((NO_DEVCONTAINER + 1))
            NO_DEVCONTAINER_NAMES+=("$name")
            [ "$VERBOSE" -eq 1 ] && printf '%-46s no %s\n' "$name" "$DEVCONTAINER_DIR"
            return
            ;;
    esac

    if ! has_entry "$DIR_ENTRIES" "devcontainer.json"; then
        # Fix 7: the multi-configuration layout — devcontainer.json nested under
        # .devcontainer/<folder>/ rather than at the canonical path — is not "no
        # devcontainer" either; find_leftover doubles as the last-path-segment finder here.
        local nested
        nested="$(find_leftover "$DIR_ENTRIES" "devcontainer.json")"
        if [ -n "$nested" ]; then
            FAILED+=("$name")
            printf '%-46s uses the multi-configuration layout (%s) — this policy only reads %s; unverified\n' \
                "$name" "$(printf '%s' "$nested" | tr '\n' ' ')" "$DEVCONTAINER_JSON"
            return
        fi
        NO_DEVCONTAINER=$((NO_DEVCONTAINER + 1))
        NO_DEVCONTAINER_NAMES+=("$name")
        [ "$VERBOSE" -eq 1 ] && printf '%-46s %s has no devcontainer.json\n' "$name" "$DEVCONTAINER_DIR"
        return
    fi

    raw="$(read_file "$org" "$name" "$DEVCONTAINER_JSON")"
    if [ -z "$raw" ]; then
        FAILED+=("$name")
        printf '%-46s devcontainer.json is listed but could not be read\n' "$name"
        return
    fi

    # Whole-line comments only — see "devcontainer.json IS JSONC" in the file header.
    stripped="$(printf '%s\n' "$raw" | grep -v '^[[:space:]]*//')"

    # One jq run, emitting "ok" then every key of .features joined on \x01 (a tab-safe
    # separator distinct from the @tsv column separator). The leading literal marks the
    # parse as having succeeded — an empty second column is otherwise indistinguishable
    # between "no features declared" and "jq refused the document".
    local ok features_joined
    IFS=$'\t' read -r ok features_joined < <(
        printf '%s' "$stripped" | jq -r '
            ["ok", ((.features // {}) | keys | join("\u0001"))] | @tsv
        ' 2>/dev/null
    )
    if [ "${ok:-}" != "ok" ]; then
        FAILED+=("$name")
        printf '%-46s devcontainer.json is not valid JSON once comments are stripped\n' "$name"
        return
    fi

    local -a feature_keys=()
    [ -n "$features_joined" ] && IFS=$'\001' read -r -a feature_keys <<<"$features_joined"

    # Matched against FEATURE_BASE, which already carries the publishing namespace — see
    # "THE FEATURE PATH NAMES ITS OWN PUBLISHING NAMESPACE" above — and against all three
    # shapes a reference to it can take: a major tag (the only one that resolves to a
    # major), no tag at all, or pinned by digest. Both of the latter two do wire the
    # Feature in, so they get their own message rather than the RSRMID-3019 wording, which
    # is only true of a repository that never referenced FEATURE_BASE at all.
    local declared="" tagless=0 digest=0 key
    for key in "${feature_keys[@]}"; do
        case "$key" in
            "$FEATURE_BASE")
                tagless=1
                break
                ;;
            "$FEATURE_BASE":*)
                declared="${key#"$FEATURE_BASE":}"
                break
                ;;
            "$FEATURE_BASE"@*)
                digest=1
                break
                ;;
        esac
    done

    if [ "$tagless" -eq 1 ]; then
        DRIFT+=("declares the devbase Feature with no tag — it floats onto the newest release on every rebuild rather than resolving to devbase:$POLICY_DEVBASE_MAJOR")
    elif [ "$digest" -eq 1 ]; then
        DRIFT+=("declares the devbase Feature pinned by digest rather than by the devbase:$POLICY_DEVBASE_MAJOR major tag")
    elif [ -z "$declared" ]; then
        DRIFT+=("devcontainer.json declares no devbase Feature — the RSRMID-3019 failure: a migration commit that never wires the Feature in")
    elif [ "$declared" != "$POLICY_DEVBASE_MAJOR" ]; then
        DRIFT+=("declares devbase:$declared — policy wants devbase:$POLICY_DEVBASE_MAJOR")
    fi

    # --- leftovers the Feature replaces ---------------------------------------
    # Matched at any depth: the four repositories RSRMID-3019 migrated kept these in
    # .devcontainer/configurations/ and .devcontainer/supporting_files/configuration/,
    # never at the top level. See read_devcontainer_dir's header.
    local f hit
    for f in $POLICY_LEFTOVER_FILES; do
        while IFS= read -r hit; do
            [ -n "$hit" ] || continue
            DRIFT+=("$DEVCONTAINER_DIR/$hit is still committed — devbase supplies this now")
        done < <(find_leftover "$DIR_ENTRIES" "$f")
    done

    # Any Dockerfile-shaped file anywhere under .devcontainer/, at any depth — see "THE
    # DOCKERFILE LEFTOVER-CLONE CHECK IS RECURSIVE TOO" in the file header. A repository
    # with none at all (a compose frame, or a prebuilt `image`) has nothing for this half
    # of the check to look at, and --verbose says so rather than looking identical to a
    # checked-and-clean repository.
    local df_path df_content df_stripped pat df_found=0
    while IFS= read -r df_path; do
        [ -n "$df_path" ] || continue
        df_found=1
        df_content="$(read_file "$org" "$name" "$DEVCONTAINER_DIR/$df_path")"
        if [ -z "$df_content" ]; then
            FAILED+=("$name")
            DRIFT+=("$DEVCONTAINER_DIR/$df_path is listed but could not be read — the leftover-clone check is unverified")
            continue
        fi
        # Fix 5: whole-line '#' comments stripped first, the same way devcontainer.json's
        # '//' comments are stripped above — a migration commit's own comment announcing
        # the removal ("powerlevel10k and zsh-autosuggestions now come from devbase") must
        # not itself be read as the clone it is describing.
        df_stripped="$(printf '%s\n' "$df_content" | grep -v '^[[:space:]]*#')"
        for pat in $POLICY_LEFTOVER_DOCKERFILE_PATTERNS; do
            printf '%s\n' "$df_stripped" | grep -qiF "$pat" &&
                DRIFT+=("$DEVCONTAINER_DIR/$df_path still clones $pat — devbase supplies this now")
        done
    done < <(find_dockerfiles "$DIR_ENTRIES")
    [ "$df_found" -eq 1 ] || [ "$VERBOSE" -ne 1 ] ||
        printf '%-46s no Dockerfile under %s — nothing to check for leftover clones\n' "$name" "$DEVCONTAINER_DIR"

    # --- the lock file: warn, never fail --------------------------------------
    has_entry "$DIR_ENTRIES" "$DEVCONTAINER_LOCK" || LOCK_MISSING+=("$name")

    if [ "${#DRIFT[@]}" -eq 0 ]; then
        CLEAN=$((CLEAN + 1))
        [ "$VERBOSE" -eq 1 ] && printf '%-46s ok (devbase:%s)\n' "$name" "$declared"
        return
    fi

    DRIFTED+=("$name")
    printf '%s\n' "$name"
    local d
    for d in "${DRIFT[@]}"; do printf '    %s\n' "$d"; done
}

# --- run ---------------------------------------------------------------------

# ws_die exits 1, which this script reserves for "there is drift". A malformed register is
# "could not run", so it is checked in a subshell whose exit is remapped to 2 — matching
# deploykey-policy.sh and org-settings.sh.
(ws_register_check) || exit 2

# Both namespaces, unlike node-policy.sh: a devcontainer is as much in scope for a
# centralnicgroup repository as for an opensource one, and RSRMID-3036 has not yet been
# the reason to hold this one back the way it holds node-policy.sh back — there is no
# manifest-comparison drift here waiting to be discovered first, only a devcontainer.json
# that either declares the Feature or does not.
ws_info "Discovering ${REPO_PREFIX}* repositories in ${WS_ORGS[*]} ..."
DISCOVERED="$(ws_discover_all)" || exit 2

# The credential self-test. See "A CREDENTIAL PROBLEM MUST NEVER LOOK LIKE AN ABSENCE" in
# the file header for why this script needs it where deploykey-policy.sh deliberately does
# not: there is no per-row fallback here, so a namespace a stale or rotated token cannot see
# would otherwise just be missing from DISCOVERED, silently, rather than reported.
(ws_assert_discovery_covers_registers "$DISCOVERED") || exit 2

if [ "${#SELECTED[@]}" -gt 0 ]; then
    TARGETS=("${SELECTED[@]}")
    for name in "${TARGETS[@]}"; do
        printf '%s\n' "$DISCOVERED" | cut -f2 | grep -qxF "$name" ||
            ws_die "not found in ${WS_ORGS[*]}: $name"
    done
else
    mapfile -t TARGETS < <(printf '%s\n' "$DISCOVERED" | cut -f2 | sort)
fi

is_archived() { printf '%s\n' "$DISCOVERED" | awk -F'\t' -v n="$1" '$2 == n { print $5 }' | grep -qx true; }
repo_org_of() { printf '%s\n' "$DISCOVERED" | awk -F'\t' -v n="$1" '$2 == n { print $1; exit }'; }

# The tree is read at the default branch discovery reported, never a hardcoded name: the
# older repositories here are on master and the newer on main, and a wrong branch would
# 404 into "unreadable" on half the fleet.
repo_branch_of() { printf '%s\n' "$DISCOVERED" | awk -F'\t' -v n="$1" '$2 == n { print $3; exit }'; }

ws_info "Checking ${#TARGETS[@]} repositories against $(basename "$POLICY_FILE") ..."
printf '\n'

for name in "${TARGETS[@]}"; do
    # Archived first: an archived repository cannot take a devcontainer commit without
    # unarchiving it, so reporting its drift would be noise nobody can act on.
    if is_archived "$name"; then
        ARCHIVED=$((ARCHIVED + 1))
        [ "$VERBOSE" -eq 1 ] && printf '%-46s archived\n' "$name"
        continue
    fi

    org="$(repo_org_of "$name")"

    if ws_is_excluded "$org" "$name" || is_excluded_conf "$name"; then
        EXCLUDED=$((EXCLUDED + 1))
        [ "$VERBOSE" -eq 1 ] && printf '%-46s excluded\n' "$name"
        continue
    fi

    # Never exit from inside the loop: one unreachable repository must not decide that
    # every other repository goes unchecked.
    check_repo "$org" "$name" "$(repo_branch_of "$name")"
done

# --- summary -----------------------------------------------------------------

printf '\n===============================================================\n'
printf 'clean: %d   drifted: %d   failed: %d   no devcontainer: %d   archived: %d   excluded: %d\n' \
    "$CLEAN" "${#DRIFTED[@]}" "${#FAILED[@]}" "$NO_DEVCONTAINER" "$ARCHIVED" "$EXCLUDED"

[ "${#NO_DEVCONTAINER_NAMES[@]}" -eq 0 ] || printf 'no devcontainer: %s\n' "${NO_DEVCONTAINER_NAMES[*]}"
[ "${#DRIFTED[@]}" -eq 0 ] || printf 'drifted: %s\n' "${DRIFTED[*]}"
[ "${#FAILED[@]}" -eq 0 ] || printf 'failed:  %s\n' "${FAILED[*]}"

if [ "${#LOCK_MISSING[@]}" -gt 0 ]; then
    printf '\nwarning: no committed %s (devbase:%s re-resolves to the newest %s.x on every rebuild) in %d repositories:\n' \
        "$DEVCONTAINER_LOCK" "$POLICY_DEVBASE_MAJOR" "$POLICY_DEVBASE_MAJOR" "${#LOCK_MISSING[@]}"
    printf '  %s\n' "${LOCK_MISSING[*]}"
fi

[ "${#FAILED[@]}" -eq 0 ] || exit 2
[ "${#DRIFTED[@]}" -eq 0 ] || exit 1
exit 0
