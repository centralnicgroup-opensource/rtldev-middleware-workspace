#!/usr/bin/env bash
#
# Report every organisation-wide CI version variable that has reached end of life, or
# that a newer supported release cycle has moved past.
#
#   scripts/eol-policy.sh                             # check every variable in the policy
#   scripts/eol-policy.sh RTLDEV_MW_CI_PHP_MATRIX     # restrict to named variables
#   scripts/eol-policy.sh --verbose                   # also print the variables that are clean
#   scripts/eol-policy.sh --from-api                  # read the values from GitHub, not the environment
#
# WHERE THE VALUES COME FROM
#
# From the environment, one variable per name in .github/eol-policy.conf. That is not a
# convenience: it is how the scheduled workflow supplies them, out of the Actions vars
# context, which needs no token scope at all. Fetching them here instead would have made
# the job depend on a credential that reads organisation variables, and a fine-grained PAT
# can only do that when its resource owner is the organisation itself.
#
# --from-api exists for running this from a laptop without copying values by hand. It
# needs that organisation-owned credential, so it is the exception rather than the path
# the job takes.
#
# An unset or empty variable is a failure, never a pass. A variable renamed or removed at
# the organisation level would otherwise arrive as a blank string and read as "nothing to
# check" — the same silent-pass hazard the register exists to prevent, reached through the
# environment instead.
#
# WHAT COUNTS AS DRIFT
#
# Three things, all of them inherited from rtldev-middleware-gh-actions-endoflife, whose
# src/main.js this replaces. Reporting only the first would miss most of the value:
#
#   invalid   the configured cycle does not exist for that product, or falls outside the
#             MIN/MAX window in the policy. A typo or a stale bound, not a version problem.
#   eol       the configured cycle has reached end of life, reported with the date.
#   newer     a supported cycle inside the window that the variable does not name. For a
#             matrix every missing cycle is listed; for a single version it is reported
#             only when the missing cycle is newer, so deliberately sitting on an older
#             but still supported release is not flagged for ever.
#
# The literal value "latest" always passes without an API call, as it did before.
#
# Read-only. It never writes to GitHub and never edits a variable; changing a version is a
# decision someone makes in the organisation settings and in the repositories that follow.
#
# Exit status: 0 clean, 1 drift, 2 could not run.

set -uo pipefail

# shellcheck source=scripts/repos.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/repos.sh"

POLICY_FILE="$WS_ROOT/.github/eol-policy.conf"

VERBOSE=0
FROM_API=0
SELECTED=()

DRIFTED=()
FAILED=()
CLEAN=0

# --- arguments ---------------------------------------------------------------

while [ "$#" -gt 0 ]; do
  case "$1" in
    -v | --verbose) VERBOSE=1 ;;
    --from-api) FROM_API=1 ;;
    -h | --help)
      grep '^#' "$0" | grep -v '^#!' | cut -c 3-
      exit 0
      ;;
    -*) ws_die "unknown option '$1' (try --help)" ;;
    *) SELECTED+=("$1") ;;
  esac
  shift
done

ws_need jq "needed to read the endoflife.date API"
ws_need curl "needed to read the endoflife.date API"
[ "$FROM_API" -eq 1 ] && ws_need gh "needed by --from-api to read the organisation variables"
[ -f "$POLICY_FILE" ] || ws_die "no policy at $POLICY_FILE"

# shellcheck source=.github/eol-policy.conf
. "$POLICY_FILE"

[ -n "${POLICY_CHECKS:-}" ] || ws_die "$POLICY_FILE does not set POLICY_CHECKS"
[ -n "${POLICY_API_BASE:-}" ] || ws_die "$POLICY_FILE does not set POLICY_API_BASE"

# --- values ------------------------------------------------------------------
# --from-api populates the environment from the organisation, so that everything below
# reads values the same way whichever source they came from.

if [ "$FROM_API" -eq 1 ]; then
  ws_info "Reading the organisation variables of $ORG ..."
  API_VARS="$(gh api --paginate "orgs/$ORG/actions/variables?per_page=100" --jq '.variables[] | "\(.name)=\(.value)"' 2>&1)" || {
    ws_info "$API_VARS"
    ws_die "could not read the organisation variables of $ORG.
  This needs a fine-grained PAT whose resource owner is the organisation, with
  Organization permissions -> Variables: Read. A token owned by a personal account
  cannot reach organisation variables however much repository access it holds.
  Run without --from-api and let the workflow supply the values instead."
  }
  [ -n "$API_VARS" ] || ws_die "the organisation variable listing was empty — refusing to read that as 'nothing to check'"
  while IFS='=' read -r api_name api_value; do
    [ -n "$api_name" ] || continue
    export "$api_name=$api_value"
  done <<<"$API_VARS"
fi

# --- endoflife.date ----------------------------------------------------------
# One request per product, cached for the run: nodejs, go and the rest are each named by
# two variables, and asking twice for the same answer is only a way to get two of them.

CACHE="$(mktemp -d)"
trap 'rm -rf "$CACHE"' EXIT

product_data() {
  local product="$1" file="$CACHE/$1.json" body
  if [ ! -f "$file" ]; then
    body="$(curl -fsSL -H 'Accept: application/json' "$POLICY_API_BASE/$product" 2>/dev/null)" || return 1
    printf '%s' "$body" >"$file"
  fi
  printf '%s' "$file"
}

# RTLDEV_MW_CI_OS holds a runner label such as ubuntu-24.04, while endoflife.date knows
# the product by its release cycle, 24.04. ubuntu-latest reduces to "latest" and is
# short-circuited below like any other "latest".
runner_label_to_cycle() {
  printf '%s' "${1#ubuntu-}"
}

# Turn a variable's value into a JSON array of cycles. The action accepted both a bare
# scalar and a bracketed list written with either quote style, and workflows in the
# organisation use both spellings, so both are still accepted here.
cycles_json() {
  local raw="$1"
  if [ "${raw:0:1}" = '[' ]; then
    printf '%s' "$raw" | tr "'" '"' | jq -c 'map(tostring)' 2>/dev/null && return 0
    return 1
  fi
  jq -cn --arg c "$raw" '[$c]'
}

# --- one variable ------------------------------------------------------------

check_one() {
  local variable="$1" product="$2" min="$3" max="$4"
  local raw cycles file analysis n_in
  local invalid outside eol missing newest input_idx newest_idx

  raw="${!variable:-}"
  if [ -z "$raw" ]; then
    FAILED+=("$variable")
    printf '%-30s %s\n' "$variable" "unset or empty — not read as 'nothing to check'"
    return
  fi

  [ "$product" = "ubuntu" ] && raw="$(runner_label_to_cycle "$raw")"

  cycles="$(cycles_json "$raw")" || {
    FAILED+=("$variable")
    printf '%-30s %s\n' "$variable" "value is not a cycle or a list of cycles: $raw"
    return
  }

  n_in="$(printf '%s' "$cycles" | jq 'length')"
  if [ "$n_in" -eq 1 ] && [ "$(printf '%s' "$cycles" | jq -r '.[0]')" = "latest" ]; then
    CLEAN=$((CLEAN + 1))
    [ "$VERBOSE" -eq 1 ] && printf '%-30s %s\n' "$variable" "latest — always current by definition"
    return
  fi

  file="$(product_data "$product")" || {
    FAILED+=("$variable")
    printf '%-30s %s\n' "$variable" "could not read $POLICY_API_BASE/$product"
    return
  }

  analysis="$(
    jq -c \
      --argjson inputs "$cycles" \
      --arg min "$([ "$min" = "-" ] && printf '' || printf '%s' "$min")" \
      --arg max "$([ "$max" = "-" ] && printf '' || printf '%s' "$max")" '
      ([.result.releases[]
        | {name: (.name | tostring), isEol: (.isEol == true), eolFrom: (.eolFrom // "")}]
        | reverse) as $rel
    | ($rel | map(.name)) as $names
    | ($rel | map({key: .name, value: .}) | from_entries) as $info
    | (if $min == "" then 0 else ($names | index($min)) end) as $minIdx
    | (if $max == "" then (($names | length) - 1) else ($names | index($max)) end) as $maxIdx
    | [$inputs[] | . as $c | select(($names | index($c)) == null)] as $unknown
    | (if ($minIdx == null or $maxIdx == null) then []
       else [$inputs[] | . as $c | ($names | index($c)) as $ci
             | select($ci != null) | select($ci < $minIdx or $ci > $maxIdx)] end) as $outside
    | (if ($minIdx == null or $maxIdx == null) then []
       else [range($minIdx; $maxIdx + 1) as $i | $names[$i] as $c
             | select(($inputs | index($c)) == null) | select($info[$c].isEol | not)
             | $c] end) as $missing
    | {
        minOk: ($minIdx != null),
        maxOk: ($maxIdx != null),
        unknown: $unknown,
        outside: $outside,
        eol: [$inputs[] | . as $c | select(($names | index($c)) != null)
              | select($info[$c].isEol)
              | "\($c) (end of life \($info[$c].eolFrom))"],
        missing: $missing,
        newest: ($missing | last),
        newestIdx: (($missing | last) as $m | if $m == null then -1 else ($names | index($m)) end),
        inputIdx: (($inputs | last) as $c | ($names | index($c)) // -1)
      }' "$file" 2>/dev/null
  )" || {
    FAILED+=("$variable")
    printf '%-30s %s\n' "$variable" "could not parse the endoflife.date payload for $product"
    return
  }

  if [ "$(jq -r '.minOk' <<<"$analysis")" != "true" ]; then
    FAILED+=("$variable")
    printf '%-30s %s\n' "$variable" "MIN_CYCLE '$min' does not exist for $product — the policy bound is stale"
    return
  fi
  if [ "$(jq -r '.maxOk' <<<"$analysis")" != "true" ]; then
    FAILED+=("$variable")
    printf '%-30s %s\n' "$variable" "MAX_CYCLE '$max' does not exist for $product — the policy bound is stale"
    return
  fi

  invalid="$(jq -r '.unknown | join(", ")' <<<"$analysis")"
  outside="$(jq -r '.outside | join(", ")' <<<"$analysis")"
  eol="$(jq -r '.eol | join("; ")' <<<"$analysis")"
  missing="$(jq -r '.missing | join(", ")' <<<"$analysis")"
  newest="$(jq -r '.newest // ""' <<<"$analysis")"
  newest_idx="$(jq -r '.newestIdx' <<<"$analysis")"
  input_idx="$(jq -r '.inputIdx' <<<"$analysis")"

  local drift=()
  [ -n "$invalid" ] && drift+=("unknown cycle for $product: $invalid")
  [ -n "$outside" ] && drift+=("outside the policy window ${min}..${max}: $outside")
  [ -n "$eol" ] && drift+=("reached end of life: $eol")
  if [ "$n_in" -gt 1 ]; then
    [ -n "$missing" ] && drift+=("matrix is missing supported cycles: $missing")
  elif [ -n "$newest" ] && [ "$newest_idx" -gt "$input_idx" ]; then
    drift+=("a newer supported cycle is available: $newest")
  fi

  if [ "${#drift[@]}" -eq 0 ]; then
    CLEAN=$((CLEAN + 1))
    [ "$VERBOSE" -eq 1 ] && printf '%-30s %s\n' "$variable" "ok ($product $raw)"
    return
  fi

  DRIFTED+=("$variable")
  printf '%-30s %s\n' "$variable" "$product $raw"
  local d
  for d in "${drift[@]}"; do printf '    %s\n' "$d"; done
}

# --- run ---------------------------------------------------------------------

CHECKS=()
while read -r c_var c_product c_min c_max; do
  [ -n "$c_var" ] || continue
  case "$c_var" in \#*) continue ;; esac
  CHECKS+=("$c_var $c_product $c_min $c_max")
done <<<"$POLICY_CHECKS"

[ "${#CHECKS[@]}" -gt 0 ] || ws_die "$POLICY_FILE declares no checks"

if [ "${#SELECTED[@]}" -gt 0 ]; then
  for name in "${SELECTED[@]}"; do
    printf '%s\n' "${CHECKS[@]}" | cut -d' ' -f1 | grep -qxF "$name" ||
      ws_die "not declared in $(basename "$POLICY_FILE"): $name"
  done
fi

ws_info "Checking ${#CHECKS[@]} CI version variables against endoflife.date ..."
printf '\n'

for check in "${CHECKS[@]}"; do
  # shellcheck disable=SC2086
  set -- $check
  if [ "${#SELECTED[@]}" -gt 0 ]; then
    printf '%s\n' "${SELECTED[@]}" | grep -qxF "$1" || continue
  fi
  # Never exit from inside the loop: one unreachable product must not decide that every
  # other variable goes unchecked.
  check_one "$1" "$2" "$3" "$4"
done

# --- summary -----------------------------------------------------------------

printf '\n===============================================================\n'
printf 'clean: %d   drifted: %d   failed: %d\n' \
  "$CLEAN" "${#DRIFTED[@]}" "${#FAILED[@]}"

[ "${#DRIFTED[@]}" -eq 0 ] || printf 'drifted: %s\n' "${DRIFTED[*]}"
[ "${#FAILED[@]}" -eq 0 ] || printf 'failed:  %s\n' "${FAILED[*]}"

[ "${#FAILED[@]}" -eq 0 ] || exit 2
[ "${#DRIFTED[@]}" -eq 0 ] || exit 1
exit 0
