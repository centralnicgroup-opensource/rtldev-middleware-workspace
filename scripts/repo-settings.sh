#!/usr/bin/env bash
#
# Reconcile this repository's GitHub settings with .github/repo-settings.conf.
#
#   scripts/repo-settings.sh            # report drift, change nothing (default)
#   scripts/repo-settings.sh --apply    # make GitHub match the file
#
# Check mode never writes and exits 1 on drift, so it works as a scheduled CI job with
# a read-only token. Apply mode needs admin, and is deliberately not wired to
# `on: push` — a workflow with admin over its own repository can be made to apply a
# merged change to this file. Run it by hand or via workflow_dispatch.
#
# Settings the API cannot express stay manual; see TEMPLATE-SETUP.md section 8.
#
# DESCRIPTION, HOMEPAGE and TOPICS accept the value @unmanaged, meaning "hold no opinion,
# leave whatever GitHub has". That is not the same as an empty value, which is a request
# to blank the field. Nothing else accepts it: every other setting is a policy with one
# right answer, so opting out of one silently is exactly what must not be possible.
#
# Exit status: 0 clean, 1 drift, 2 could not run. Drift and failure have to be
# distinguishable, or a caller reconciling many repositories reads "cannot reach the
# API" as "settings are wrong" and vice versa.

set -euo pipefail

UNMANAGED="@unmanaged"

MODE=check
CONFIG=".github/repo-settings.conf"
REPO=""

DRIFT=0
SKIPPED=0
UNCONFIGURED=0

# --- output ------------------------------------------------------------------

info() { printf '  %s\n' "$*"; }
head2() { printf '\n%s\n' "$*"; }
die() {
    printf 'error: %s\n' "$*" >&2
    exit 2
}

# A field this configuration deliberately does not own. Reported so the output still
# accounts for every setting, but counted as neither drift nor a read failure.
unmanaged() { info "- ${1}: unmanaged here"; }

# Reports one field. In check mode it records drift; in apply mode the caller has
# already written the value, so this is just the log line.
#
# A wanted value that is still a {{TOKEN}} is a question nobody has answered, so there
# is nothing to compare it against — reported and counted separately from a real
# mismatch, and separately again from a field this token cannot read.
compare() {
    local label="$1" want="$2" got="$3"
    if [[ "$want" =~ \{\{[A-Z_]+\}\} ]]; then
        info "? ${label}: still a {{placeholder}} — not configured"
        UNCONFIGURED=$((UNCONFIGURED + 1))
    elif [[ "$got" == "unknown" ]]; then
        info "? ${label}: cannot read with this token — skipped"
        SKIPPED=$((SKIPPED + 1))
    elif [[ "$want" == "$got" ]]; then
        info "= ${label}: ${got}"
    else
        info "! ${label}: is '${got}', want '${want}'"
        DRIFT=$((DRIFT + 1))
    fi
}

# --- arguments ---------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply) MODE=apply ;;
        --check) MODE=check ;;
        --config)
            CONFIG="${2:-}"
            shift
            ;;
        --repo)
            REPO="${2:-}"
            shift
            ;;
        -h | --help)
            grep '^#' "$0" | grep -v '^#!' | cut -c 3-
            exit 0
            ;;
        *) die "unknown argument '$1' (try --help)" ;;
    esac
    shift
done

command -v gh >/dev/null 2>&1 || die "gh is required (https://cli.github.com)"
command -v jq >/dev/null 2>&1 || die "jq is required"

# Resolved before the cd so a path relative to the current directory works too. The
# ./ prefix stops `.` falling back to a PATH lookup for a slashless name.
[[ -f "$CONFIG" ]] && CONFIG=$(realpath "$CONFIG")

cd "$(git rev-parse --show-toplevel)" || die "not inside a git repository"
[[ -f "$CONFIG" ]] || die "no such config: ${CONFIG}"
[[ "$CONFIG" == /* ]] || CONFIG="./${CONFIG}"

# A repository still carrying template placeholders would have its description set to
# the literal "{{DESCRIPTION}}", so apply mode refuses rather than write nonsense.
#
# Check mode does not, because rtldev-middleware-template is itself a live repository:
# its identity fields are placeholders permanently and by design, so dying here would
# mean the one repository that ships this script could never run it, and its weekly
# drift job could only ever be red. The unanswered fields are reported as unconfigured
# instead, which leaves everything else — the merge buttons, features and security
# toggles, identical for the template and for anything created from it — genuinely
# checked rather than skipped along with them.
if [[ "$MODE" == "apply" ]] && grep -qE '\{\{[A-Z_]+\}\}' "$CONFIG"; then
    die "${CONFIG} still contains {{PLACEHOLDERS}} — finish TEMPLATE-SETUP.md section 1 first"
fi

# shellcheck source=/dev/null
. "$CONFIG"

# The identity fields default to @unmanaged, not to "". A configuration that never
# mentions DESCRIPTION is one that has no opinion about it; reading that silence as
# "set it to the empty string" would erase the field on the next apply.
: "${DESCRIPTION:=$UNMANAGED}" "${HOMEPAGE:=$UNMANAGED}" "${TOPICS:=$UNMANAGED}"
: "${IS_TEMPLATE:=false}"
: "${ALLOW_SQUASH_MERGE:=false}" "${ALLOW_REBASE_MERGE:=true}" "${ALLOW_MERGE_COMMIT:=false}"
: "${ALLOW_AUTO_MERGE:=true}" "${DELETE_BRANCH_ON_MERGE:=true}"
: "${HAS_ISSUES:=true}" "${HAS_PROJECTS:=false}" "${HAS_WIKI:=false}" "${HAS_DISCUSSIONS:=false}"
: "${PRIVATE_VULNERABILITY_REPORTING:=true}" "${VULNERABILITY_ALERTS:=true}"
: "${AUTOMATED_SECURITY_FIXES:=true}"
: "${SECRET_SCANNING:=true}" "${SECRET_SCANNING_PUSH_PROTECTION:=true}"
: "${RULESET_ENABLED:=false}" "${RULESET_NAME:=default-branch-protection}"
: "${RULESET_BYPASS_ACTORS:=}"
: "${REQUIRED_APPROVALS:=1}" "${DISMISS_STALE_REVIEWS:=true}"
: "${REQUIRE_LAST_PUSH_APPROVAL:=true}" "${REQUIRE_LINEAR_HISTORY:=true}"
: "${REQUIRE_SIGNED_COMMITS:=false}"
: "${REQUIRED_CHECKS:=}" "${EXPECTED_SECRETS:=}" "${EXPECTED_VARIABLES:=}"

for name in IS_TEMPLATE ALLOW_SQUASH_MERGE ALLOW_REBASE_MERGE ALLOW_MERGE_COMMIT ALLOW_AUTO_MERGE \
    DELETE_BRANCH_ON_MERGE HAS_ISSUES HAS_PROJECTS HAS_WIKI HAS_DISCUSSIONS \
    PRIVATE_VULNERABILITY_REPORTING VULNERABILITY_ALERTS AUTOMATED_SECURITY_FIXES \
    SECRET_SCANNING SECRET_SCANNING_PUSH_PROTECTION RULESET_ENABLED \
    DISMISS_STALE_REVIEWS REQUIRE_LAST_PUSH_APPROVAL REQUIRE_LINEAR_HISTORY \
    REQUIRE_SIGNED_COMMITS; do
    case "${!name}" in
        true | false) ;;
        "$UNMANAGED")
            die "${name} cannot be ${UNMANAGED} — only DESCRIPTION, HOMEPAGE and TOPICS may opt out"
            ;;
        *) die "${name} must be true or false, got '${!name}'" ;;
    esac
done

[[ -n "$REPO" ]] || REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner) ||
    die "could not determine the repository — pass --repo OWNER/NAME"

printf 'Repository: %s\nConfig:     %s\nMode:       %s\n' "$REPO" "$CONFIG" "$MODE"

# --- core settings -----------------------------------------------------------

head2 "Core settings"

actual=$(gh api "repos/${REPO}" 2>/dev/null) || die "cannot read repos/${REPO}"

# Low-scope tokens omit the merge flags entirely, which would otherwise read as drift
# on every field at once. An absent key is therefore "unknown", while a key present as
# null is a genuinely unset value — an empty description is drift, not a read failure.
read_field() {
    local key="$1" v
    v=$(jq -r --arg k "$key" '
        if has($k) then (if .[$k] == null then "" else (.[$k] | tostring) end)
        else "unknown" end' <<<"$actual")
    printf '%s' "$v"
}

# Identity fields are added only when this configuration owns them. An @unmanaged field
# is left out of the PATCH body entirely rather than sent as "", which GitHub would
# faithfully apply — blanking twenty descriptions on the first org-wide run.
identity=$(jq -n '{}')
if [[ "$DESCRIPTION" != "$UNMANAGED" ]]; then
    identity=$(jq --arg v "$DESCRIPTION" '.description = $v' <<<"$identity")
fi
if [[ "$HOMEPAGE" != "$UNMANAGED" ]]; then
    identity=$(jq --arg v "$HOMEPAGE" '.homepage = $v' <<<"$identity")
fi

desired_core=$(jq -n \
    --argjson is_template "$IS_TEMPLATE" \
    --argjson has_issues "$HAS_ISSUES" \
    --argjson has_projects "$HAS_PROJECTS" \
    --argjson has_wiki "$HAS_WIKI" \
    --argjson has_discussions "$HAS_DISCUSSIONS" \
    --argjson allow_squash_merge "$ALLOW_SQUASH_MERGE" \
    --argjson allow_rebase_merge "$ALLOW_REBASE_MERGE" \
    --argjson allow_merge_commit "$ALLOW_MERGE_COMMIT" \
    --argjson allow_auto_merge "$ALLOW_AUTO_MERGE" \
    --argjson delete_branch_on_merge "$DELETE_BRANCH_ON_MERGE" \
    '$ARGS.named')

desired_core=$(jq -n --argjson a "$identity" --argjson b "$desired_core" '$a + $b')

if [[ "$MODE" == "apply" ]]; then
    gh api --method PATCH "repos/${REPO}" --input - <<<"$desired_core" >/dev/null ||
        die "failed to patch core settings (admin required)"
    actual=$(gh api "repos/${REPO}")
fi

if [[ "$DESCRIPTION" == "$UNMANAGED" ]]; then unmanaged "description"; fi
if [[ "$HOMEPAGE" == "$UNMANAGED" ]]; then unmanaged "homepage"; fi

while IFS=$'\t' read -r key want; do
    compare "$key" "$want" "$(read_field "$key")"
done < <(jq -r 'to_entries[] | "\(.key)\t\(.value | tostring)"' <<<"$desired_core")

# --- topics ------------------------------------------------------------------

head2 "Topics"

if [[ "$TOPICS" == "$UNMANAGED" ]]; then
    unmanaged "topics"
else
    want_topics=$(tr ' ' '\n' <<<"$TOPICS" | grep -v '^$' | sort | tr '\n' ' ' | sed 's/ $//')
    if [[ "$MODE" == "apply" ]]; then
        jq -n --arg t "$TOPICS" '{names: ($t | split(" ") | map(select(length > 0)))}' |
            gh api --method PUT "repos/${REPO}/topics" --input - >/dev/null ||
            die "failed to set topics"
    fi
    got_topics=$(gh api "repos/${REPO}/topics" --jq '.names | sort | join(" ")' 2>/dev/null || echo unknown)
    compare "topics" "$want_topics" "$got_topics"
fi

# --- security ----------------------------------------------------------------

head2 "Security"

# 204 means enabled, 404 disabled; anything else (403) means the token cannot see it.
probe_204() {
    local path="$1" err
    if err=$(gh api "$path" 2>&1 >/dev/null); then
        printf 'true'
    elif [[ "$err" == *"(HTTP 404)"* || "$err" == *"Not Found"* ]]; then
        printf 'false'
    else
        printf 'unknown'
    fi
}

probe_enabled_json() {
    local path="$1" body
    if body=$(gh api "$path" 2>/dev/null); then
        jq -r 'if has("enabled") then (.enabled | tostring) else "unknown" end' <<<"$body"
    else
        printf 'unknown'
    fi
}

toggle() { # path desired
    local path="$1" want="$2" method
    [[ "$want" == "true" ]] && method=PUT || method=DELETE
    gh api --method "$method" "$path" >/dev/null 2>&1 ||
        info "  (could not $method $path — needs admin, or the plan does not offer it)"
}

if [[ "$MODE" == "apply" ]]; then
    toggle "repos/${REPO}/vulnerability-alerts" "$VULNERABILITY_ALERTS"
    toggle "repos/${REPO}/automated-security-fixes" "$AUTOMATED_SECURITY_FIXES"
    toggle "repos/${REPO}/private-vulnerability-reporting" "$PRIVATE_VULNERABILITY_REPORTING"

    # Secret scanning rides along on the repo PATCH rather than its own endpoint, and
    # is rejected outright on plans without it — hence the tolerated failure.
    jq -n \
        --arg ss "$([[ "$SECRET_SCANNING" == true ]] && echo enabled || echo disabled)" \
        --arg pp "$([[ "$SECRET_SCANNING_PUSH_PROTECTION" == true ]] && echo enabled || echo disabled)" \
        '{security_and_analysis: {secret_scanning: {status: $ss}, secret_scanning_push_protection: {status: $pp}}}' |
        gh api --method PATCH "repos/${REPO}" --input - >/dev/null 2>&1 ||
        info "  (secret scanning not settable here — plan or permissions)"
fi

compare "vulnerability alerts" "$VULNERABILITY_ALERTS" "$(probe_204 "repos/${REPO}/vulnerability-alerts")"
compare "automated security fixes" "$AUTOMATED_SECURITY_FIXES" "$(probe_enabled_json "repos/${REPO}/automated-security-fixes")"
compare "private vulnerability reporting" "$PRIVATE_VULNERABILITY_REPORTING" "$(probe_enabled_json "repos/${REPO}/private-vulnerability-reporting")"

sa=$(gh api "repos/${REPO}" --jq '.security_and_analysis // empty' 2>/dev/null || true)
if [[ -n "$sa" ]]; then
    compare "secret scanning" "$([[ "$SECRET_SCANNING" == true ]] && echo enabled || echo disabled)" \
        "$(jq -r '.secret_scanning.status // "unknown"' <<<"$sa")"
    compare "secret scanning push protection" \
        "$([[ "$SECRET_SCANNING_PUSH_PROTECTION" == true ]] && echo enabled || echo disabled)" \
        "$(jq -r '.secret_scanning_push_protection.status // "unknown"' <<<"$sa")"
else
    compare "secret scanning" "-" "unknown"
fi

# --- branch protection -------------------------------------------------------

head2 "Branch protection"

# RULESET_BYPASS_ACTORS is "<actor_type>:<actor_id>:<bypass_mode>", comma-separated for
# more than one. actor_id is left empty for the actor types GitHub treats as a class
# rather than as one actor — DeployKey is the one that matters here: the API requires
# actor_id null, because the bypass is granted to "a deploy key of this repository", not
# to one particular key.
#
# Parsed in bash rather than in jq so a malformed entry dies with the entry quoted. A
# typo that silently produced no bypass would reject the very push the bypass exists to
# allow; one that silently produced the wrong actor would hand the bypass to someone else.
ruleset_bypass_json() {
    local spec type id mode out='[]'
    local -a specs
    IFS=',' read -r -a specs <<<"$RULESET_BYPASS_ACTORS"
    for spec in "${specs[@]}"; do
        spec="${spec//[[:space:]]/}"
        [[ -n "$spec" ]] || continue
        IFS=':' read -r type id mode <<<"$spec"
        [[ -n "$type" && -n "$mode" ]] ||
            die "RULESET_BYPASS_ACTORS: '${spec}' is not <actor_type>:<actor_id>:<bypass_mode>"
        case "$mode" in
            always | pull_request) ;;
            *) die "RULESET_BYPASS_ACTORS: '${spec}' has bypass_mode '${mode}', want always or pull_request" ;;
        esac
        [[ -z "$id" || "$id" =~ ^[0-9]+$ ]] ||
            die "RULESET_BYPASS_ACTORS: '${spec}' has a non-numeric actor_id '${id}'"
        out=$(jq --arg t "$type" --arg i "$id" --arg m "$mode" \
            '. + [{
                actor_type: $t,
                actor_id: (if $i == "" then null else ($i | tonumber) end),
                bypass_mode: $m
             }]' <<<"$out")
    done
    printf '%s' "$out"
}

# One line per actor, sorted, so the wanted and the actual list compare as strings
# regardless of the order GitHub returns them in.
ruleset_bypass_label() {
    jq -r '
        if length == 0 then "none"
        else map("\(.actor_type):\(.actor_id // ""):\(.bypass_mode)") | sort | join(" ")
        end'
}

if [[ "$RULESET_ENABLED" != "true" ]]; then
    info "- repository ruleset disabled in config; expecting an organisation ruleset"
    info "  verify: gh api orgs/OWNER/rulesets"
else
    bypass_actors=$(ruleset_bypass_json)

    ruleset_body=$(jq -n \
        --arg name "$RULESET_NAME" \
        --argjson bypass_actors "$bypass_actors" \
        --argjson approvals "$REQUIRED_APPROVALS" \
        --argjson dismiss "$DISMISS_STALE_REVIEWS" \
        --argjson last_push "$REQUIRE_LAST_PUSH_APPROVAL" \
        --argjson linear "$REQUIRE_LINEAR_HISTORY" \
        --argjson signed "$REQUIRE_SIGNED_COMMITS" \
        --arg checks "$REQUIRED_CHECKS" \
        '{
      name: $name,
      target: "branch",
      enforcement: "active",
      bypass_actors: $bypass_actors,
      conditions: { ref_name: { include: ["~DEFAULT_BRANCH"], exclude: [] } },
      rules: (
        [
          { type: "deletion" },
          { type: "non_fast_forward" },
          { type: "pull_request", parameters: {
              required_approving_review_count: $approvals,
              dismiss_stale_reviews_on_push: $dismiss,
              require_last_push_approval: $last_push,
              require_code_owner_review: false,
              required_review_thread_resolution: false
          } }
        ]
        + (if $linear then [{ type: "required_linear_history" }] else [] end)
        + (if $signed then [{ type: "required_signatures" }] else [] end)
        + (if ($checks | length) > 0 then [{
            type: "required_status_checks",
            parameters: {
              strict_required_status_checks_policy: true,
              required_status_checks: ($checks | split(",") | map({ context: (. | gsub("^ +| +$";"")) }))
            }
          }] else [] end)
      )
    }')

    # Filtered with jq rather than `gh api --jq`, which takes no --arg.
    existing=$(gh api "repos/${REPO}/rulesets" 2>/dev/null |
        jq -r --arg n "$RULESET_NAME" 'map(select(.name == $n)) | .[0].id // empty' 2>/dev/null || echo "")

    if [[ "$MODE" == "apply" ]]; then
        if [[ -n "$existing" ]]; then
            gh api --method PUT "repos/${REPO}/rulesets/${existing}" --input - <<<"$ruleset_body" >/dev/null &&
                info "= ruleset '${RULESET_NAME}' updated" ||
                info "! ruleset update failed (admin required)"
        else
            gh api --method POST "repos/${REPO}/rulesets" --input - <<<"$ruleset_body" >/dev/null &&
                info "= ruleset '${RULESET_NAME}' created" ||
                info "! ruleset creation failed (admin required)"
        fi
        info "= ruleset bypass actors: $(ruleset_bypass_label <<<"$bypass_actors")"
    else
        compare "ruleset '${RULESET_NAME}'" "present" \
            "$([[ -n "$existing" ]] && echo present || echo absent)"

        # The bypass list is what decides whether the ruleset can be walked around, so it
        # is compared rather than assumed: an actor added by hand in the web UI is drift
        # of exactly the shape that makes every other rule here decorative.
        #
        # Fetched per ruleset because the list endpoint returns a summary — bypass_actors
        # and rules appear only on GET /repos/{owner}/{repo}/rulesets/{id}.
        if [[ -n "$existing" ]]; then
            detail=$(gh api "repos/${REPO}/rulesets/${existing}" 2>/dev/null || echo "")
            if [[ -n "$detail" ]]; then
                compare "ruleset bypass actors" \
                    "$(ruleset_bypass_label <<<"$bypass_actors")" \
                    "$(jq '.bypass_actors // []' <<<"$detail" | ruleset_bypass_label)"
            else
                compare "ruleset bypass actors" "-" "unknown"
            fi
        else
            info "- ruleset bypass actors: not comparable, the ruleset itself is absent"
        fi
    fi

    if [[ -z "$REQUIRED_CHECKS" ]]; then
        info "  note: REQUIRED_CHECKS is empty — pull requests and linear history are"
        info "        enforced, but nothing gates on CI, and 'branches must be up to"
        info "        date' has no effect without at least one required check."
    fi

    # Classic branch protection and rulesets do not replace one another: both apply, and
    # the union of their restrictions is enforced. A migration that creates the ruleset
    # and leaves the classic rule in place therefore looks finished while the old rule is
    # still the thing doing the work — and still the thing to edit when it blocks someone.
    # Reported rather than deleted: removing branch protection is not something a drift
    # reconciler should decide to do on its own.
    default_branch=$(jq -r '.default_branch // empty' <<<"$actual")
    if [[ -n "$default_branch" ]] &&
        gh api "repos/${REPO}/branches/${default_branch}/protection" >/dev/null 2>&1; then
        info "! classic branch protection is ALSO present on '${default_branch}'"
        info "  both rule sets apply at once; remove the classic rule to finish the migration:"
        info "  gh api --method DELETE repos/${REPO}/branches/${default_branch}/protection"
        DRIFT=$((DRIFT + 1))
    fi
fi

# --- secrets and variables (names only, never values) ------------------------

if [[ -n "$EXPECTED_SECRETS" || -n "$EXPECTED_VARIABLES" ]]; then
    head2 "Secrets and variables"
    have_secrets=$(gh api "repos/${REPO}/actions/secrets" --jq '[.secrets[].name] | join(" ")' 2>/dev/null || echo unknown)
    have_vars=$(gh api "repos/${REPO}/actions/variables" --jq '[.variables[].name] | join(" ")' 2>/dev/null || echo unknown)
    for want in $EXPECTED_SECRETS; do
        if [[ "$have_secrets" == "unknown" ]]; then
            compare "secret ${want}" "present" "unknown"
        else
            compare "secret ${want}" "present" \
                "$([[ " $have_secrets " == *" $want "* ]] && echo present || echo absent)"
        fi
    done
    for want in $EXPECTED_VARIABLES; do
        if [[ "$have_vars" == "unknown" ]]; then
            compare "variable ${want}" "present" "unknown"
        else
            compare "variable ${want}" "present" \
                "$([[ " $have_vars " == *" $want "* ]] && echo present || echo absent)"
        fi
    done
fi

# --- summary -----------------------------------------------------------------

head2 "Summary"
info "drift: ${DRIFT}   unreadable: ${SKIPPED}   unconfigured: ${UNCONFIGURED}"

if [[ "$MODE" == "apply" ]]; then
    info "applied. Re-run without --apply to confirm."
    exit 0
fi

if [[ "$DRIFT" -gt 0 ]]; then
    info "run with --apply to reconcile"
    exit 1
fi
if [[ "$UNCONFIGURED" -gt 0 ]]; then
    info "what is configured matches; answer the {{placeholders}} to cover the rest"
    exit 0
fi
info "settings match the config"
