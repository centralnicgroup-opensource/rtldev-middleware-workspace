#!/usr/bin/env bash
#
# ws — one operation, every repository.
#
# The workspace exists so that a change which touches every repository is one command
# instead of one per repository, and so that the state of all of them is one table
# instead of a `git status` run each. Everything here is a thin, auditable wrapper
# over git and gh: nothing is cached, no state is kept outside the submodules
# themselves, and every subcommand prints the repositories it acted on.
#
# Three properties are deliberate throughout:
#
#   * Nothing writes to a remote unless the subcommand's name says so (push, pr).
#     status, sync, pull, foreach and grep are safe to run at any time.
#   * A subcommand never partially applies without saying which repositories failed —
#     the per-repository exit status is collected and reported in a trailer.
#   * A dirty or diverged repository is skipped with a reason, never forced. Bulk
#     tooling that resolves conflicts on your behalf is how work gets lost.
#
# Usage: ./scripts/ws.sh <command> [options] [repo...]
#        ./scripts/ws.sh help

set -uo pipefail

# shellcheck source=scripts/repos.sh
. "$(dirname "${BASH_SOURCE[0]}")/repos.sh"

cd "$WS_ROOT" || exit 1

JOBS="${WS_JOBS:-8}"

# --- presentation ------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GRN=$'\033[32m'
  C_YEL=$'\033[33m'
  C_BLD=$'\033[1m'
  C_OFF=$'\033[0m'
else
  C_DIM='' C_RED='' C_GRN='' C_YEL='' C_BLD='' C_OFF=''
fi

ws_banner() { printf '%s=== %s%s\n' "$C_BLD" "$1" "$C_OFF"; }

# Collected per-repository failures, reported once at the end. A bulk command that
# exits non-zero without naming the repository that failed is unusable at this scale.
FAILED=()

ws_report_failures() {
  [ "${#FAILED[@]}" -eq 0 ] && return 0
  printf '\n%s%d repo(s) failed:%s %s\n' "$C_RED" "${#FAILED[@]}" "$C_OFF" "${FAILED[*]}" >&2
  return 1
}

# --- helpers -----------------------------------------------------------------
# The branch a repository is tracked against. Recorded per submodule in .gitmodules
# because it is genuinely not uniform here: the older repositories are on `master` and
# the newer ones on `main`, and hardcoding either breaks half the workspace.
ws_tracked_branch() {
  local full="$1" b
  b="$(git config --file .gitmodules --get "submodule.$(ws_path "$full").branch" 2>/dev/null)"
  printf '%s' "${b:-main}"
}

ws_repo_dirty() {
  [ -n "$(git -C "$1" status --porcelain 2>/dev/null)" ]
}

# --- status ------------------------------------------------------------------
# Grouped by namespace rather than carrying it as a sixth column: the organisation names
# are 26 characters wide, and repeating one down every row would push the table past any
# terminal while saying the same thing fifteen times.
cmd_status() {
  local selection org full seen unplaced
  selection="$(ws_select "$@")" || exit 1

  printf '%s%-42s %-9s %-22s %-7s %s%s\n' "$C_BLD" "REPOSITORY" "STATE" "BRANCH" "DIRTY" "VS UPSTREAM" "$C_OFF"
  for org in "${WS_ORGS[@]}"; do
    seen=0
    while IFS= read -r full; do
      [ -n "$full" ] || continue
      [ "$(ws_org_of "$full")" = "$org" ] || continue
      if [ "$seen" -eq 0 ]; then
        printf '%s%s%s\n' "$C_DIM" "$org" "$C_OFF"
        seen=1
      fi
      ws_status_row "$full"
    done <<<"$selection"
  done

  # A submodule registered under a directory that is not one of the namespaces this
  # workspace spans. Reported rather than dropped: silently omitting it is how a bulk
  # operation ends up covering one repository fewer than the table said it would.
  unplaced=0
  while IFS= read -r full; do
    [ -n "$full" ] || continue
    printf '%s\n' "${WS_ORGS[@]}" | grep -qxF "$(ws_org_of "$full")" && continue
    if [ "$unplaced" -eq 0 ]; then
      printf '%s%s%s\n' "$C_RED" "outside every known namespace" "$C_OFF"
      unplaced=1
    fi
    ws_status_row "$full"
  done <<<"$selection"
  [ "$unplaced" -eq 0 ] || ws_warn "registered under an unknown namespace — see WS_ORGS in scripts/repos.sh"
}

ws_status_row() {
  local full="$1" short dir state branch dirty ahead behind upstream counts
  short="$(ws_short_name "$full")"
  dir="$(ws_path "$full")"

  if ! ws_is_populated "$full"; then
    printf '%-42s %s%-9s%s %-22s %-7s %s\n' "$short" "$C_DIM" "empty" "$C_OFF" "-" "-" "-"
    return
  fi

  branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [ "$branch" = "HEAD" ] && branch="(detached)"

  if ws_repo_dirty "$dir"; then
    dirty="${C_YEL}yes${C_OFF}"
  else
    dirty="${C_DIM}no${C_OFF}"
  fi

  # '+' from `git submodule status` means the checkout is at a different commit than the
  # superproject records — expected while working, worth surfacing before a superproject
  # commit that would either pin the new commit or silently revert it.
  case "$(git submodule status -- "$dir" 2>/dev/null)" in
    +*) state="${C_YEL}moved${C_OFF}" ;;
    U*) state="${C_RED}conflict${C_OFF}" ;;
    *) state="${C_GRN}ok${C_OFF}" ;;
  esac

  upstream="-"
  if git -C "$dir" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
    counts="$(git -C "$dir" rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null)"
    behind="${counts%%[[:space:]]*}"
    ahead="${counts##*[[:space:]]}"
    if [ "$ahead" = "0" ] && [ "$behind" = "0" ]; then
      upstream="${C_DIM}in sync${C_OFF}"
    else
      upstream="${C_YEL}+${ahead}/-${behind}${C_OFF}"
    fi
  fi

  # The %-Ns padding is computed against the colour codes too, so the columns would skew;
  # printing the padded plain value and the coloured value separately is the simplest
  # thing that keeps the table aligned.
  printf '%-42s %-9b %-22s %-7b %b\n' "$short" "$state" "$branch" "$dirty" "$upstream"
}

# --- sync --------------------------------------------------------------------
# Populates (or restores) checkouts at the commit the superproject pins.
#
# Blobless by default (--filter=blob:none): the full set is ~2.4 GB, most of it file
# contents from history nobody in a workspace context reads. A blobless clone keeps
# every commit and tree — so log, blame, diff and checkout all work — and fetches file
# contents on demand. Pass --full for a conventional clone when you need the whole
# history offline.
cmd_sync() {
  local filter=(--filter=blob:none) paths=() full
  local args=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --full) filter=() ;;
      --) ;;
      *) args+=("$1") ;;
    esac
    shift
  done

  while IFS= read -r full; do
    paths+=("$(ws_path "$full")")
  done < <(ws_select "${args[@]+"${args[@]}"}")

  [ "${#paths[@]}" -eq 0 ] && ws_die "nothing to sync"

  ws_info "syncing ${#paths[@]} repo(s) with ${JOBS} parallel jobs${filter:+ (blobless)}"
  ws_git submodule update --init --jobs "$JOBS" "${filter[@]+"${filter[@]}"}" -- "${paths[@]}"
}

# --- pull --------------------------------------------------------------------
# Moves each checkout to the current tip of its tracked branch — the "start of day"
# command, and the one to run before `ws.sh branch`.
#
# --ff-only, always. A bulk pull that can merge is a bulk pull that can leave a merge
# commit, or a conflicted worktree, in every repository at once, from one keystroke.
cmd_pull() {
  local full short dir branch
  while IFS= read -r full; do
    short="$(ws_short_name "$full")"
    dir="$(ws_path "$full")"
    branch="$(ws_tracked_branch "$full")"
    ws_banner "$short"

    if ws_repo_dirty "$dir"; then
      printf '%sskipped: uncommitted changes%s\n' "$C_YEL" "$C_OFF"
      continue
    fi

    if ! git -C "$dir" checkout --quiet "$branch" 2>/dev/null; then
      printf '%sskipped: no local branch %s%s\n' "$C_YEL" "$branch" "$C_OFF"
      continue
    fi

    if ! ws_git -C "$dir" pull --ff-only --quiet; then
      FAILED+=("$short")
      continue
    fi
    printf '%s %s\n' "$branch" "$(git -C "$dir" log -1 --format='%h %s' | cut -c1-72)"
  done < <(ws_select_populated "$@")
  ws_report_failures
}

# --- foreach -----------------------------------------------------------------
# Runs one shell command inside every populated repository.
#
# The command is passed to `bash -c` with $WS_REPO (full name), $WS_REPO_SHORT and
# $WS_REPO_DIR exported, so it can branch on which repository it is in — which is what
# makes a single invocation usable across a PHP, a Go and a Node repository.
#
# Output is grouped per repository, never interleaved: a dozen or more commands writing
# to the same terminal concurrently produces something nobody can read, so GNU parallel's
# --group is used when available and a plain sequential loop otherwise.
cmd_foreach() {
  local parallel_mode=0
  if [ "${1:-}" = "-j" ] || [ "${1:-}" = "--parallel" ]; then
    parallel_mode=1
    shift
  fi
  [ "$#" -gt 0 ] || ws_die "usage: ws.sh foreach [-j] <command...>   (use -- to separate repos)"

  # `ws.sh foreach <cmd> -- repo...` — the separator is required because the command
  # itself takes arbitrary words, so there is no way to guess where it ends.
  local command_parts=() repo_args=() seen_sep=0 arg
  for arg in "$@"; do
    if [ "$seen_sep" -eq 0 ] && [ "$arg" = "--" ]; then
      seen_sep=1
      continue
    fi
    if [ "$seen_sep" -eq 1 ]; then repo_args+=("$arg"); else command_parts+=("$arg"); fi
  done
  local command="${command_parts[*]}"

  local repos=() full
  while IFS= read -r full; do repos+=("$full"); done < <(ws_select_populated "${repo_args[@]+"${repo_args[@]}"}")
  [ "${#repos[@]}" -eq 0 ] && ws_die "no populated repositories selected"

  if [ "$parallel_mode" -eq 1 ] && command -v parallel >/dev/null 2>&1; then
    local paths=() full
    for full in "${repos[@]}"; do paths+=("$(ws_path "$full")"); done
    # {} is repos/<org>/<name> and {/} its last segment, so the namespace comes along
    # without parallel having to be told about it. WS_REPO_SHORT is computed here rather
    # than passed: it is the full name with the prefix stripped, and `basename` — which
    # is what stood here — returned the full name instead, so every parallel run reported
    # the wrong value for it.
    export REPO_PREFIX
    printf '%s\n' "${paths[@]}" \
      | parallel --group --jobs "$JOBS" --halt never \
        "cd '$WS_ROOT'/{} || exit 1
         WS_REPO={/}
         WS_REPO_SHORT=\${WS_REPO#\$REPO_PREFIX}
         printf '%s=== %s%s\\n' '$C_BLD' \"\$WS_REPO_SHORT\" '$C_OFF'
         export WS_REPO WS_REPO_SHORT
         export WS_REPO_DIR='$WS_ROOT'/{}
         bash -c $(printf '%q' "$command")"
    return $?
  fi

  local short
  for full in "${repos[@]}"; do
    short="$(ws_short_name "$full")"
    ws_banner "$short"
    (
      cd "$WS_ROOT/$(ws_path "$full")" || exit 1
      WS_REPO="$full" WS_REPO_SHORT="$short" WS_REPO_DIR="$PWD" bash -c "$command"
    ) || FAILED+=("$short")
  done
  ws_report_failures
}

# --- grep --------------------------------------------------------------------
# Cross-repository search. ripgrep over the selected checkouts, so .gitignore is
# honoured and node_modules/vendor never appear — the single most common reason a
# naive `grep -r` across this workspace returns thousands of useless hits.
cmd_grep() {
  ws_need rg "install ripgrep, or use ws.sh foreach 'grep ...'"
  [ "$#" -gt 0 ] || ws_die "usage: ws.sh grep <pattern> [rg options] [-- repo...]"

  local rg_args=() repo_args=() seen_sep=0 arg
  for arg in "$@"; do
    if [ "$seen_sep" -eq 0 ] && [ "$arg" = "--" ]; then
      seen_sep=1
      continue
    fi
    if [ "$seen_sep" -eq 1 ]; then repo_args+=("$arg"); else rg_args+=("$arg"); fi
  done

  local paths=() full
  while IFS= read -r full; do paths+=("$(ws_path "$full")"); done < <(ws_select_populated "${repo_args[@]+"${repo_args[@]}"}")
  [ "${#paths[@]}" -eq 0 ] && ws_die "no populated repositories selected"

  # rg exits 1 for "no matches", which is a legitimate result for a search, not a
  # failure — mapped to 0 so `ws.sh grep ... && something` behaves.
  rg --hidden --glob '!**/.git/**' "${rg_args[@]}" -- "${paths[@]}"
  local rc=$?
  [ "$rc" -eq 1 ] && return 0
  return "$rc"
}

# --- branch ------------------------------------------------------------------
# Creates the same branch in each selected repository, from a freshly updated tracked
# branch. Refuses on a dirty worktree rather than stashing: a bulk stash is a pile of
# unlabelled stashes nobody goes back for.
cmd_branch() {
  local name="${1:-}"
  shift || true
  [ -n "$name" ] || ws_die "usage: ws.sh branch <RSRMID-1234/short-description> [repo...]"

  local full short dir base
  while IFS= read -r full; do
    short="$(ws_short_name "$full")"
    dir="$(ws_path "$full")"
    base="$(ws_tracked_branch "$full")"
    ws_banner "$short"

    if ws_repo_dirty "$dir"; then
      printf '%sskipped: uncommitted changes%s\n' "$C_YEL" "$C_OFF"
      continue
    fi

    if git -C "$dir" show-ref --verify --quiet "refs/heads/$name"; then
      git -C "$dir" checkout --quiet "$name" && printf 'switched to existing %s\n' "$name"
      continue
    fi

    # Branch off the freshly pulled tracked branch, never off whatever happened to be
    # checked out — CLAUDE.md's rule, enforced here so it cannot be forgotten at scale.
    if ! git -C "$dir" checkout --quiet "$base" || ! ws_git -C "$dir" pull --ff-only --quiet; then
      FAILED+=("$short")
      printf '%scould not update %s%s\n' "$C_RED" "$base" "$C_OFF"
      continue
    fi
    if git -C "$dir" checkout --quiet -b "$name"; then
      printf 'created %s from %s\n' "$name" "$base"
    else
      FAILED+=("$short")
    fi
  done < <(ws_select_populated "$@")
  ws_report_failures
}

# --- commit ------------------------------------------------------------------
# Commits the working tree of every selected repository that has changes, with one
# shared message. Repositories with nothing to commit are reported and skipped, so the
# output doubles as the list of repositories the bulk edit actually touched.
#
# Each repository's own hooks run (husky, lint-staged): the point of committing here
# rather than with a raw `git -C ... commit` is that the per-repository quality gates
# still apply.
cmd_commit() {
  local message="${1:-}"
  shift || true
  [ -n "$message" ] || ws_die "usage: ws.sh commit '<type>(<scope>): <summary>' [repo...]"

  # Conventional Commits with a mandatory scope is the org rule, and semantic-release
  # reads these messages to pick the next version — a malformed bulk message would land
  # in every history at once. Checked, not assumed.
  if ! printf '%s' "$message" | grep -qE '^(feat|fix|ci|build|chore|docs|test|refactor|perf|style|revert)\([a-z0-9._-]+\)!?: .+'; then
    ws_die "message must be Conventional Commits with a scope: '<type>(<scope>): <summary>'"
  fi

  local full short dir
  while IFS= read -r full; do
    short="$(ws_short_name "$full")"
    dir="$(ws_path "$full")"
    if ! ws_repo_dirty "$dir"; then
      printf '%s%-40s no changes%s\n' "$C_DIM" "$short" "$C_OFF"
      continue
    fi
    ws_banner "$short"
    git -C "$dir" add -A || {
      FAILED+=("$short")
      continue
    }
    git -C "$dir" commit -m "$message" || FAILED+=("$short")
  done < <(ws_select_populated "$@")
  ws_report_failures
}

# --- push --------------------------------------------------------------------
# Pushes the current branch of every selected repository, setting upstream on first
# push. Refuses to push the tracked branch: direct pushes to main/master are what the
# branch protection rulesets exist to prevent, and a bulk tool is the last place to
# make an exception.
cmd_push() {
  local full short dir branch base
  while IFS= read -r full; do
    short="$(ws_short_name "$full")"
    dir="$(ws_path "$full")"
    branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    base="$(ws_tracked_branch "$full")"

    if [ "$branch" = "$base" ] || [ "$branch" = "HEAD" ]; then
      printf '%s%-40s skipped: on %s%s\n' "$C_DIM" "$short" "$branch" "$C_OFF"
      continue
    fi
    # Nothing to push is the normal state for repositories a bulk edit did not touch.
    if git -C "$dir" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1 \
      && [ -z "$(git -C "$dir" log '@{upstream}..HEAD' --oneline)" ]; then
      printf '%s%-40s nothing to push%s\n' "$C_DIM" "$short" "$C_OFF"
      continue
    fi
    ws_banner "$short"
    ws_git -C "$dir" push --set-upstream origin "$branch" || FAILED+=("$short")
  done < <(ws_select_populated "$@")
  ws_report_failures
}

# --- pr ----------------------------------------------------------------------
# Opens one pull request per repository that has an unmerged branch pushed.
# Requires an authenticated gh; everything up to here works without one.
cmd_pr() {
  ws_need gh
  gh auth status >/dev/null 2>&1 || ws_die "gh is not authenticated — run: gh auth login"

  local title="${1:-}"
  local body="${2:-}"
  shift 2 2>/dev/null || shift "$#"
  [ -n "$title" ] || ws_die "usage: ws.sh pr '<title>' '<body>' [repo...]"

  local full short dir branch base org nwo
  while IFS= read -r full; do
    short="$(ws_short_name "$full")"
    dir="$(ws_path "$full")"
    branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    base="$(ws_tracked_branch "$full")"
    org="$(ws_org_of "$full")"
    nwo="$org/$full"

    if [ "$branch" = "$base" ] || [ "$branch" = "HEAD" ]; then
      printf '%s%-40s skipped: on %s%s\n' "$C_DIM" "$short" "$branch" "$C_OFF"
      continue
    fi
    if ! git -C "$dir" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
      printf '%s%-40s skipped: not pushed (ws.sh push)%s\n' "$C_YEL" "$short" "$C_OFF"
      continue
    fi
    # An existing PR is reported, not duplicated — reruns of a bulk operation are
    # normal and must be idempotent.
    if ws_gh "$org" pr view --repo "$nwo" "$branch" >/dev/null 2>&1; then
      printf '%s%-40s PR exists: %s%s\n' "$C_DIM" "$short" \
        "$(ws_gh "$org" pr view --repo "$nwo" "$branch" --json url --jq .url)" "$C_OFF"
      continue
    fi
    ws_banner "$short"
    ws_gh "$org" pr create --repo "$nwo" --base "$base" --head "$branch" \
      --title "$title" --body "$body" || FAILED+=("$short")
  done < <(ws_select_populated "$@")
  ws_report_failures
}

# --- pin ---------------------------------------------------------------------
# Records the currently checked-out commits in the superproject.
#
# This is the one write to *this* repository the workflow needs, and it is separate
# from everything else on purpose: a superproject commit is a statement that "these are
# the commits the workspace points at", which is only true once the submodule commits
# are pushed. Run it after ws.sh push, not before.
cmd_pin() {
  local paths=() full
  while IFS= read -r full; do paths+=("$(ws_path "$full")"); done < <(ws_select "$@")
  git add -- "${paths[@]}"
  git -c color.status=always status --short -- "${paths[@]}"
  ws_info "staged. Commit with: git commit -m 'chore(repos): update pinned commits'"
}

# --- add ---------------------------------------------------------------------
# Reconciles the register against GitHub: reports repositories that exist there but are
# not registered here, and registered entries that no longer qualify (archived, made
# private, renamed or deleted).
#
# Registration writes the .gitmodules entry and the gitlink directly, from
# `git ls-remote` — it does NOT clone. `git submodule add` would clone the repository
# to add it, which for whmcs means 2 GB before you have decided whether you need it.
# `ws.sh sync <repo>` is the deliberate, separate step that populates a checkout.
#
# Removal is reported but never applied: dropping a submodule discards whatever is in
# its worktree, so it stays a human decision.
cmd_add() {
  local apply=0
  [ "${1:-}" = "--apply" ] && apply=1

  ws_register_check

  ws_info "querying GitHub for $REPO_PREFIX* repositories in ${#WS_ORGS[@]} namespace(s): ${WS_ORGS[*]} ..."

  # One query, three questions asked of the same answer. The coverage check needs the
  # unfiltered rows — a registered repository that has since been archived is still one
  # the credential has to be able to see — so filtering happens after it, not in the
  # query.
  local all discovered
  all="$(ws_discover_all)" || exit 1
  ws_assert_discovery_covers_registers "$all"
  discovered="$(printf '%s\n' "$all" | ws_filter_submodule_candidates)"
  [ -n "$discovered" ] || ws_die "no repository qualifies as a submodule — refusing to act on an empty result"

  local registered_paths
  registered_paths="$(ws_registered_paths)"

  local new=() gone=() org full branch path line
  while IFS=$'\t' read -r org full branch; do
    [ -n "$full" ] || continue
    printf '%s\n' "$registered_paths" | grep -qxF "repos/$org/$full" || new+=("$org	$full	$branch")
  done <<<"$discovered"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\n' "$discovered" | cut -f1,2 | tr '\t' '/' | grep -qxF "${line#repos/}" || gone+=("$line")
  done <<<"$registered_paths"

  if [ "${#gone[@]}" -gt 0 ]; then
    printf '%s%d registered repo(s) no longer qualify (archived, excluded, renamed or deleted):%s\n' \
      "$C_YEL" "${#gone[@]}" "$C_OFF"
    printf '  %s\n' "${gone[@]}"
    printf '  Remove manually: git rm <path> && git config --file .gitmodules --remove-section submodule.<path>\n'
  fi

  # An exclusion that matches nothing is a row about a repository that has been renamed or
  # deleted since someone declared it out of scope. Harmless, but it is the file's whole
  # purpose to be read, and a stale row makes the next reader doubt the rest of it.
  local stale=() xorg xname
  while IFS=$'\t' read -r xorg xname _; do
    [ -n "$xname" ] || continue
    printf '%s\n' "${WS_ORGS[@]}" | grep -qxF "$xorg" || continue
    printf '%s\n' "$all" | cut -f1,2 | grep -qxF "$xorg	$xname" || stale+=("$xorg/$xname")
  done < <(ws_exclude_rows)
  if [ "${#stale[@]}" -gt 0 ]; then
    ws_warn "$(basename "$WS_EXCLUDE") names ${#stale[@]} repo(s) that no longer exist: ${stale[*]}"
  fi

  if [ "${#new[@]}" -eq 0 ]; then
    ws_info "register is up to date: $(printf '%s\n' "$registered_paths" | grep -c .) repositories"
    return 0
  fi

  printf '%s%d repo(s) on GitHub are not registered:%s\n' "$C_BLD" "${#new[@]}" "$C_OFF"
  printf '%s\n' "${new[@]}" | awk -F'\t' '{print "  " $1 "/" $2}'
  printf '  Not wanted here? Declare it in %s with a reason instead.\n' "${WS_EXCLUDE#"$WS_ROOT"/}"

  if [ "$apply" -eq 0 ]; then
    ws_info "re-run with --apply to register them"
    return 0
  fi

  local sha url
  while IFS=$'\t' read -r org full branch; do
    [ -n "$full" ] || continue
    url="$(ws_url "$full" "$org")"
    path="$(ws_path "$full" "$org")"
    # ls-remote is a single ref-advertisement round trip: it gives the tip commit without
    # transferring a single object. It goes out over HTTPS, so the namespace's token has
    # to be reachable to git as well as to gh — which is what the credential helper
    # installed by `ws.sh credentials --install` is for.
    sha="$(ws_git ls-remote "$url" "refs/heads/$branch" | cut -f1)"
    if [ -z "$sha" ]; then
      ws_warn "could not resolve $branch of $org/$full — skipped ($(ws_credential_hint "$org"))"
      FAILED+=("$(ws_short_name "$full")")
      continue
    fi
    git config --file .gitmodules "submodule.$path.path" "$path"
    git config --file .gitmodules "submodule.$path.url" "$url"
    git config --file .gitmodules "submodule.$path.branch" "$branch"
    mkdir -p "$path"
    # mode 160000 is a gitlink: the index entry that makes this path a submodule. Writing
    # it directly is what lets registration stay clone-free.
    git update-index --add --cacheinfo "160000,$sha,$path"
    printf '  registered %-26s %-40s %s @ %s\n' "$org" "$(ws_short_name "$full")" "$branch" "${sha:0:8}"
  done < <(printf '%s\n' "${new[@]}")

  git add .gitmodules
  ws_info "staged. Populate with ./scripts/ws.sh sync, commit with: git commit -m 'feat(repos): register new repositories'"
  ws_report_failures
}

# --- credentials --------------------------------------------------------------
# What token each namespace resolves to, and where git will look for it. Prints no token
# and no prefix of one: the point is to answer "why does this namespace come back empty",
# and that question is answered by the *source*, never by the value.
cmd_credentials() {
  local install=0
  [ "${1:-}" = "--install" ] && install=1

  local helper="$WS_ROOT/scripts/git-credential-ws.sh"

  if [ "$install" -eq 1 ]; then
    [ -x "$helper" ] || ws_die "not executable: $helper"
    # The empty credential.helper resets the list git has accumulated from the system and
    # global files before this point — without it, the helper VS Code installs globally is
    # consulted first and answers for both namespaces with one token.
    git config --local --unset-all credential.helper 2>/dev/null
    git config --local credential.helper ''
    git config --local credential.https://github.com.useHttpPath true
    git config --local --unset-all credential.https://github.com.helper 2>/dev/null
    git config --local credential.https://github.com.helper "$helper"
    ws_info "installed the per-namespace credential helper in .git/config (not committed)"
  fi

  local configured
  configured="$(git config --local --get credential.https://github.com.helper 2>/dev/null)"

  printf '%s%-28s %-14s %s%s\n' "$C_BLD" "NAMESPACE" "NEEDS A TOKEN" "RESOLVES FROM" "$C_OFF"
  local org needs
  for org in "${WS_ORGS[@]}"; do
    if ws_org_needs_token "$org"; then needs="yes"; else needs="no"; fi
    printf '%-28s %-14s %s\n' "$org" "$needs" "$(ws_token_source "$org")"
  done

  printf '\ntoken directory: %s\n' "$WS_TOKEN_DIR"
  if [ "$configured" = "$helper" ]; then
    printf 'git helper:      installed\n'
  else
    printf 'git helper:      %snot installed%s — run ./scripts/ws.sh credentials --install\n' "$C_YEL" "$C_OFF"
  fi
}

# --- help --------------------------------------------------------------------
cmd_help() {
  cat <<'EOF'
ws — one operation, every repository.

Usage: ./scripts/ws.sh <command> [options] [repo...]

Repositories are named by their short name (php-sdk) or full name
(rtldev-middleware-php-sdk). With no repo arguments, a command applies to all
registered repositories.

The repositories span two GitHub namespaces and live under repos/<namespace>/,
but you never type the namespace: it is recorded per submodule in .gitmodules and
looked up. Each namespace has its own token — see `credentials`.

Reading
  status [repo...]              State, branch, dirtiness and upstream distance
  grep <pattern> [rg opts] [-- repo...]
                                ripgrep across the populated checkouts
  credentials [--install]       Which token each namespace resolves to, and where
                                from. --install writes the per-namespace git
                                credential helper into .git/config.

Checkouts
  sync [--full] [repo...]       Populate/restore at the pinned commit (blobless
                                by default; --full for a complete clone)
  pull [repo...]                Fast-forward each checkout to its tracked branch
  add [--apply]                 Reconcile the register against GitHub

Changes
  foreach [-j] <cmd...> [-- repo...]
                                Run a shell command in each checkout.
                                $WS_REPO, $WS_REPO_SHORT, $WS_REPO_DIR are set.
                                -j runs them in parallel (output stays grouped).
  branch <name> [repo...]       Create the same branch from a fresh tracked branch
  commit '<type>(<scope>): ...' [repo...]
                                Commit everything changed, one shared message
  push [repo...]                Push current branches (never the tracked branch)
  pr '<title>' '<body>' [repo...]
                                Open one PR per pushed branch (needs gh auth)
  pin [repo...]                 Stage the current submodule commits here

Environment
  WS_JOBS=8                     Parallelism for sync and foreach -j
  NO_COLOR=1                    Plain output
  WS_TOKEN_<NAMESPACE>          That namespace's GitHub token, uppercased with
                                non-alphanumerics as _ (WS_TOKEN_CENTRALNICGROUP)
  WS_TOKEN_DIR                  Where per-namespace token files are looked for
  WS_NO_CREDENTIAL_HELPER=1     Leave git's own credential configuration alone

A typical cross-repository change:
  ./scripts/ws.sh sync
  ./scripts/ws.sh pull
  ./scripts/ws.sh branch RSRMID-1234/bump-node
  ./scripts/ws.sh foreach 'sed -i s/lts.20/lts.22/ .github/workflows/*.yml'
  ./scripts/ws.sh status
  ./scripts/ws.sh commit 'ci(workflows): move to Node 22'
  ./scripts/ws.sh push
  ./scripts/ws.sh pr 'ci: move to Node 22' 'RSRMID-1234'
  ./scripts/ws.sh pin && git commit -m 'chore(repos): update pinned commits'
EOF
}

# --- dispatch ----------------------------------------------------------------
main() {
  local cmd="${1:-help}"
  shift 2>/dev/null || true
  case "$cmd" in
    status | st) cmd_status "$@" ;;
    sync) cmd_sync "$@" ;;
    pull) cmd_pull "$@" ;;
    foreach | each) cmd_foreach "$@" ;;
    grep | search) cmd_grep "$@" ;;
    branch) cmd_branch "$@" ;;
    commit) cmd_commit "$@" ;;
    push) cmd_push "$@" ;;
    pr) cmd_pr "$@" ;;
    pin) cmd_pin "$@" ;;
    add) cmd_add "$@" ;;
    credentials | creds) cmd_credentials "$@" ;;
    help | -h | --help) cmd_help ;;
    *)
      printf 'unknown command: %s\n\n' "$cmd" >&2
      cmd_help >&2
      exit 2
      ;;
  esac
}

main "$@"
