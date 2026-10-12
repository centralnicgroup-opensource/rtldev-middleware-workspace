#!/usr/bin/env bash
#
# Report every repository whose copy of the jira-conventions Claude Code skill differs from
# what .github/jira-skill.tsv says it should be.
#
#   scripts/jira-skill-policy.sh                   # check every row, reading GitHub
#   scripts/jira-skill-policy.sh php-sdk node-sdk  # restrict to named repositories
#   scripts/jira-skill-policy.sh --local           # read the local checkouts instead
#   scripts/jira-skill-policy.sh --render whmcs    # print one repository's expected file
#   scripts/jira-skill-policy.sh --verbose         # also print the repositories that are clean
#
# WHY THIS EXISTS
#
# The skill is one body, copied into every repository so it loads where the work happens.
# Copies drift unless something compares them. The shared body lives in
# rtldev-middleware-template; the only part that differs per repository is the block
# between the jira-conventions:repository markers, and that is rendered from one row of
# .github/jira-skill.tsv. A repository's expected file is therefore the template with its
# block replaced, and the check is a byte comparison against that — no field list to forget.
#
# --render is the only way a file is produced, and it prints to stdout. This script never
# writes a file: a skill change lands as a commit in the repository that holds the copy.
#
# The workspace row is the one special block: it also lists every other row, because the
# skill tells a reader whose fix lands in another repository to look that repository up here.
#
# WHAT IS CHECKED, AND WHAT IS NOT
#
#   - The template is the source, so it is never compared with itself — but its markers are
#     verified (exactly one begin, one end), since a damaged template would otherwise make
#     every expected file wrong at once. A rendered template row reproduces the template.
#   - Every registered repository needs a row, and a row naming a repository that is neither
#     registered nor this workspace is stale. Both are drift.
#   - The workspace's own copy is read from the working tree (CI checks it out), never the API.
#
# A CREDENTIAL PROBLEM MUST NEVER LOOK LIKE AN ABSENCE
#
# A 404 on the skill path is "no skill" only once the repository itself has been read with
# the same token. A token for the wrong namespace answers 404 for everything, which would
# otherwise report every repository as missing its skill. Unreadable is FAILED, never drift.
#
# Read-only. Exit status: 0 clean, 1 drift, 2 could not run.

set -uo pipefail

# shellcheck source=scripts/repos.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/repos.sh"

TSV="$WS_ROOT/.github/jira-skill.tsv"
SKILL_PATH=".claude/skills/jira-conventions/SKILL.md"
BEGIN_MARK="<!-- jira-conventions:repository:begin -->"
END_MARK="<!-- jira-conventions:repository:end -->"
TEMPLATE_REPO="${REPO_PREFIX}template"

VERBOSE=0
LOCAL=0
RENDER=""
SELECTED=()

DRIFTED=()
FAILED=()
CLEAN=0
SKIPPED=0

# Rows, in TSV order, plus a name -> index map.
ROW_REPO=()
ROW_PREFIX=()
ROW_ID=()
ROW_COMPONENT=()
ROW_NOTE=()
declare -A ROW_AT=()

fatal() {
    printf 'error: %s\n' "$*" >&2
    exit 2
}

# --- arguments ---------------------------------------------------------------

while [ "$#" -gt 0 ]; do
    case "$1" in
        -v | --verbose) VERBOSE=1 ;;
        --local) LOCAL=1 ;;
        --render)
            [ "$#" -gt 1 ] || fatal "--render needs a repository"
            RENDER="$(ws_full_name "$2")"
            shift
            ;;
        -h | --help)
            grep '^#' "$0" | grep -v '^#!' | cut -c 3-
            exit 0
            ;;
        -*) fatal "unknown option '$1' (try --help)" ;;
        *) SELECTED+=("$(ws_full_name "$1")") ;;
    esac
    shift
done

# ws_need dies with 1, which this script reserves for drift; a missing tool is "could not run".
(ws_need awk "needed to render the expected file") || exit 2
(ws_need diff "needed to show what differs") || exit 2
[ "$LOCAL" -eq 1 ] || (ws_need gh "needed to read the skill from every repository") || exit 2
[ -f "$TSV" ] || fatal "no register at $TSV"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
GH_ERR="$TMP/gh.err"
TEMPLATE_FILE="$TMP/template"

# --- the register ------------------------------------------------------------

load_rows() {
    local line repo prefix id component note n=0
    while IFS= read -r line; do
        case "$line" in '' | '#'*) continue ;; esac
        n=$((n + 1))
        # Exactly five non-empty tab-separated fields. `read` would swallow an empty field
        # (tab is IFS whitespace) and shift the rest left, so this is counted first.
        printf '%s\n' "$line" | awk -F'\t' 'NF != 5 { exit 1 } { for (i = 1; i <= NF; i++) if ($i == "") exit 1 }' ||
            fatal "$TSV: entry $n does not have exactly 5 non-empty tab-separated fields"
        IFS=$'\t' read -r repo prefix id component note <<<"$line"
        [ -z "${ROW_AT[$repo]:-}" ] || fatal "$TSV: duplicate row for $repo"
        ROW_AT[$repo]="${#ROW_REPO[@]}"
        ROW_REPO+=("$repo")
        ROW_PREFIX+=("$prefix")
        ROW_ID+=("$id")
        ROW_COMPONENT+=("$component")
        ROW_NOTE+=("$note")
    done <"$TSV"
    [ "${#ROW_REPO[@]}" -gt 0 ] || fatal "$TSV has no rows"
}

# --- rendering ---------------------------------------------------------------

# The workspace's "All Repositories" subsection: every row but the template's, in TSV order.
all_repositories_list() {
    local i short out="### All Repositories"$'\n'
    for i in "${!ROW_REPO[@]}"; do
        [ "${ROW_REPO[$i]}" != "$TEMPLATE_REPO" ] || continue
        short="$(ws_short_name "${ROW_REPO[$i]}")"
        if [ "${ROW_PREFIX[$i]}" = "@skip" ]; then
            out+=$'\n'"- \`$short\` — no skill: ${ROW_NOTE[$i]}"
            continue
        fi
        out+=$'\n'"- \`$short\` — \`[${ROW_PREFIX[$i]}]\`, ${ROW_COMPONENT[$i]} (\`${ROW_ID[$i]}\`)"
        if [ "${ROW_NOTE[$i]}" != "-" ] && [ "${ROW_REPO[$i]}" != "$SELF_REPO" ]; then
            out+=" — ${ROW_NOTE[$i]}"
        fi
    done
    printf '%s' "$out"
}

# The template with its block replaced by the one rendered from row $1. Values go in through
# the environment and are substituted by literal index/substr, never as a regex or an awk
# -v assignment: they contain `|`, `(`, backticks, `/` and backslashes.
render() {
    local i="${ROW_AT[$1]}" extra=""
    [ "$1" != "$SELF_REPO" ] || extra="$(all_repositories_list)"
    JIRA_P="${ROW_PREFIX[$i]}" JIRA_ID="${ROW_ID[$i]}" JIRA_C="${ROW_COMPONENT[$i]}" \
        JIRA_N="${ROW_NOTE[$i]}" JIRA_X="$extra" JIRA_B="$BEGIN_MARK" JIRA_E="$END_MARK" \
        awk '
        function rep(s, tok, val,   out, k) {
            out = ""
            while ((k = index(s, tok)) > 0) {
                out = out substr(s, 1, k - 1) val
                s = substr(s, k + length(tok))
            }
            return out s
        }
        $0 == ENVIRON["JIRA_B"] { inblock = 1; print; next }
        $0 == ENVIRON["JIRA_E"] { inblock = 0; print; next }
        inblock && index($0, "{{JIRA_NOTE}}") {
            if (ENVIRON["JIRA_N"] != "-") print rep($0, "{{JIRA_NOTE}}", ENVIRON["JIRA_N"])
            if (ENVIRON["JIRA_X"] != "") { print ""; print ENVIRON["JIRA_X"] }
            next
        }
        inblock {
            line = rep($0, "{{JIRA_PREFIX}}", ENVIRON["JIRA_P"])
            line = rep(line, "{{JIRA_COMPONENT_ID}}", ENVIRON["JIRA_ID"])
            print rep(line, "{{JIRA_COMPONENT}}", ENVIRON["JIRA_C"])
            next
        }
        { print }
    ' "$TEMPLATE_FILE"
}

# render, plus the guard that no placeholder survives. Every row but the template's own is
# fully rendered, so a leftover {{JIRA_ means a placeholder the renderer does not know (a
# renamed or new token in the template): every expected file would then be wrong in the same
# way. Returns 1 and says so; the caller decides whether that is fatal (--render) or one
# repository's failure (check mode, where it must not stop the others being checked).
render_checked() {
    local name="$1" dest="$2"
    render "$name" >"$dest"
    [ "$name" = "$TEMPLATE_REPO" ] || ! grep -q '{{JIRA_' "$dest" || return 1
}

# --- reading -----------------------------------------------------------------

# The repository's default branch, or nothing. Reading the repository itself first is what
# separates "unreadable" from "no skill" — see the header.
default_branch_of() {
    local org="$1" name="$2" branch
    branch="$(ws_gh "$org" api "repos/$org/$name" --jq .default_branch 2>"$GH_ERR")" || return 1
    [ -n "$branch" ] || return 1
    printf '%s' "$branch"
}

# The skill file's raw bytes into $4. Returns 0, 44 for a 404, 1 for anything else.
fetch_skill() {
    local org="$1" name="$2" branch="$3" dest="$4"
    if ws_gh "$org" api -H 'Accept: application/vnd.github.raw+json' \
        "repos/$org/$name/contents/$SKILL_PATH?ref=$branch" >"$dest" 2>"$GH_ERR"; then
        return 0
    fi
    grep -q '404' "$GH_ERR" && return 44
    return 1
}

load_template() {
    local org branch
    if [ "$LOCAL" -eq 1 ]; then
        local src
        src="$WS_ROOT/$(ws_path "$TEMPLATE_REPO")/$SKILL_PATH" || fatal "template is not registered"
        [ -f "$src" ] || fatal "no local template at $src"
        cp "$src" "$TEMPLATE_FILE"
    else
        org="$(ws_org_of "$TEMPLATE_REPO")" || fatal "template is not registered"
        branch="$(default_branch_of "$org" "$TEMPLATE_REPO")" || fatal "cannot read $TEMPLATE_REPO"
        fetch_skill "$org" "$TEMPLATE_REPO" "$branch" "$TEMPLATE_FILE" ||
            fatal "cannot read $SKILL_PATH from $TEMPLATE_REPO"
    fi
    [ "$(grep -cxF "$BEGIN_MARK" "$TEMPLATE_FILE")" -eq 1 ] &&
        [ "$(grep -cxF "$END_MARK" "$TEMPLATE_FILE")" -eq 1 ] ||
        fatal "the template must contain exactly one begin and one end marker"
    [ "$(grep -nxF "$BEGIN_MARK" "$TEMPLATE_FILE" | cut -d: -f1)" -lt "$(grep -nxF "$END_MARK" "$TEMPLATE_FILE" | cut -d: -f1)" ] ||
        fatal "the template's begin marker must come before its end marker"
}

# --- per-repository check ----------------------------------------------------

report_drift() {
    DRIFTED+=("$1")
    printf '%s\n' "$1"
    shift
    local d
    for d in "$@"; do printf '    %s\n' "$d"; done
}

# The first line of the captured gh stderr, so the actionable cause (a "no credential for ..."
# warning, a rate limit) reaches the log. gh's stderr never carries the token.
gh_cause() {
    local line=""
    [ -s "$GH_ERR" ] && IFS= read -r line <"$GH_ERR"
    [ -z "$line" ] || printf ' [%s]' "$line"
}

report_failed() {
    FAILED+=("$1")
    printf '%-46s %s\n' "$1" "$2"
}

# A 404 on the skill path only means "absent" if the token can read contents at all: a token
# with Metadata:read but no Contents:read reads the repository and then 404s every file.
# Listing the root needs Contents read, so it is the positive control. Returns 0 when it works.
contents_readable() {
    local org="$1" name="$2" branch="$3"
    ws_gh "$org" api "repos/$org/$name/contents/?ref=$branch" >/dev/null 2>"$GH_ERR"
}

check_repo() {
    local name="$1" i="${ROW_AT[$1]}" expected="$TMP/expected" actual="$TMP/actual" org branch rc

    if [ "${ROW_PREFIX[$i]}" = "@skip" ]; then
        SKIPPED=$((SKIPPED + 1))
        [ "$VERBOSE" -eq 1 ] && printf '%-46s skipped: %s\n' "$name" "${ROW_NOTE[$i]}"
        return
    fi
    if [ "$name" = "$TEMPLATE_REPO" ]; then
        SKIPPED=$((SKIPPED + 1))
        [ "$VERBOSE" -eq 1 ] && printf '%-46s the source of the body\n' "$name"
        return
    fi

    render_checked "$name" "$expected" || {
        report_failed "$name" "rendered file still contains a {{JIRA_ placeholder: broken template or renderer"
        return
    }

    if [ "$name" = "$SELF_REPO" ] || [ "$LOCAL" -eq 1 ]; then
        local dir="$WS_ROOT"
        if [ "$name" != "$SELF_REPO" ]; then
            ws_is_populated "$name" || {
                report_failed "$name" "no local checkout to read"
                return
            }
            dir="$WS_ROOT/$(ws_path "$name")"
        fi
        if [ ! -f "$dir/$SKILL_PATH" ]; then
            report_drift "$name" "no $SKILL_PATH"
            return
        fi
        actual="$dir/$SKILL_PATH"
    else
        org="$(ws_org_of "$name")" || {
            report_failed "$name" "namespace unknown"
            return
        }
        branch="$(default_branch_of "$org" "$name")" || {
            report_failed "$name" "could not read the repository (credential, rate limit or transport)$(gh_cause)"
            return
        }
        fetch_skill "$org" "$name" "$branch" "$actual"
        rc=$?
        if [ "$rc" -eq 44 ]; then
            contents_readable "$org" "$name" "$branch" || {
                report_failed "$name" "contents unreadable: $SKILL_PATH answered 404 but the root listing failed$(gh_cause)"
                return
            }
            report_drift "$name" "no $SKILL_PATH"
            return
        elif [ "$rc" -ne 0 ]; then
            report_failed "$name" "could not read $SKILL_PATH$(gh_cause)"
            return
        fi
    fi

    if cmp -s "$expected" "$actual"; then
        CLEAN=$((CLEAN + 1))
        [ "$VERBOSE" -eq 1 ] && printf '%-46s ok\n' "$name"
        return
    fi
    DRIFTED+=("$name")
    printf '%s\n' "$name"
    diff -u --label expected --label actual "$expected" "$actual" | head -40 | sed 's/^/    /'
}

# --- run ---------------------------------------------------------------------

# ws_die exits 1, which this script reserves for drift; a malformed register is "could not run".
(ws_register_check) || exit 2
# First of the three credential layers: a namespace that needs a token and has none fails here,
# not as a 404 per repository that would read as "no skill". --local reads no GitHub.
[ "$LOCAL" -eq 1 ] || (ws_assert_credentials) || exit 2
load_rows
load_template

if [ -n "$RENDER" ]; then
    [ -n "${ROW_AT[$RENDER]:-}" ] || fatal "no row for $RENDER in $TSV"
    [ "${ROW_PREFIX[${ROW_AT[$RENDER]}]}" != "@skip" ] || fatal "$RENDER is marked @skip: it has no skill to render"
    render_checked "$RENDER" "$TMP/rendered" ||
        fatal "rendering $RENDER left a {{JIRA_ placeholder in the output: broken template or renderer"
    render "$RENDER"
    exit 0
fi

if [ "${#SELECTED[@]}" -gt 0 ]; then
    TARGETS=("${SELECTED[@]}")
else
    TARGETS=()
    # Coverage, whole-run only: a named subset says nothing about repositories it left out.
    while IFS= read -r name; do
        [ -n "${ROW_AT[$name]:-}" ] || report_drift "$name" "no row in .github/jira-skill.tsv"
    done < <(ws_registered)
    # A stale row is reported once, here, and left out of TARGETS: checking it as well would
    # fail it ("namespace unknown") and turn drift into "could not run".
    for name in "${ROW_REPO[@]}"; do
        if [ "$name" = "$SELF_REPO" ] || ws_is_registered "$name"; then
            TARGETS+=("$name")
        else
            report_drift "$name" "stale row in .github/jira-skill.tsv: not a registered repository"
        fi
    done
fi

ws_info "Checking ${#TARGETS[@]} repositories against $(basename "$TSV") ..."
printf '\n'

for name in "${TARGETS[@]}"; do
    if [ -z "${ROW_AT[$name]:-}" ]; then
        # Only reachable for a repository named on the command line; whole-run coverage was
        # reported above.
        if ws_is_registered "$name" || [ "$name" = "$SELF_REPO" ]; then
            report_drift "$name" "no row in .github/jira-skill.tsv"
        else
            report_failed "$name" "not a registered repository"
        fi
        continue
    fi
    # Never exit from inside the loop: one unreadable repository must not leave the rest unchecked.
    check_repo "$name"
done

# --- summary -----------------------------------------------------------------

printf '\n===============================================================\n'
printf 'clean: %d   drifted: %d   failed: %d   skipped: %d\n' \
    "$CLEAN" "${#DRIFTED[@]}" "${#FAILED[@]}" "$SKIPPED"

[ "${#DRIFTED[@]}" -eq 0 ] || printf 'drifted: %s\n' "${DRIFTED[*]}"
[ "${#FAILED[@]}" -eq 0 ] || printf 'failed:  %s\n' "${FAILED[*]}"

[ "${#FAILED[@]}" -eq 0 ] || exit 2
[ "${#DRIFTED[@]}" -eq 0 ] || exit 1
exit 0
