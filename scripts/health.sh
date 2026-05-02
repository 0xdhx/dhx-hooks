#!/usr/bin/env bash
# scripts/health.sh — pure composer over the 6 SCRIPT-07 leaf tools.
#
# NO inline check logic; delegates to verify-hooks.sh + 4 probes + `git diff`.
# Tiered exits per D-18 (critical wins over advisory).
# NDJSON output per D-08/D-19. Per-check timeout 30s per D-09/D-10.
# Pre-flight sweep per D-20.
# D-26: --probes / --probes-unsafe are TRUE delegates to run-probes.sh --filter
#       SAFE_FOR_LIVE=yes|no (no inline runner — that lived in earlier draft).
# D-27: PWD+CONFIG_DIR refusal gate for --filter SAFE_FOR_LIVE=no lives in
#       run-probes.sh's filter wrapper (NOT here).
# D-30: NDJSON aggregate arrays built via `jq -n '$ARGS.positional' --args` to
#       avoid the printf-pipeline `[""]` bug for empty arrays.
# Tier definitions sourced from scripts/lib/tiers.sh (D-02, D-21).
#
# NOTE: 'set -uo pipefail' intentionally omits -e — this composer must collect
# ALL check exit codes (D-08, D-18). Per-check `timeout 30 bash -c "$cmd"`
# returns 124 on SIGTERM; under -e the first non-zero would terminate the
# script before the tier verdict could be computed.
#
# Run directly:
#   bash scripts/health.sh                # human-readable summary; tiered exit
#   bash scripts/health.sh --json         # NDJSON, aggregate last line
#   bash scripts/health.sh --probes       # delegate to run-probes.sh --filter SAFE_FOR_LIVE=yes
#   bash scripts/health.sh --full         # alias for --probes
#   bash scripts/health.sh --probes-unsafe  # delegate to run-probes.sh --filter SAFE_FOR_LIVE=no
#
# Exit codes: 0 = all ok; 1 = any critical fails (wins over advisory);
# 2 = only advisory fails.
#
# Env vars:
#   DHX_HEALTH_TIMEOUT=<positive-int>  per-check timeout in seconds (default 30).
#                                       Strict refusal on invalid values (exit 1).
#                                       Intended primarily for probe-suite ergonomics
#                                       (see G-04-01, Phase 4 Plan 04).
#   DHX_HEALTH_REPO_ROOT=<path>        override repo path (test-only).
#
# Usage:
#   bash scripts/health.sh
#   bash scripts/health.sh --json | tail -n1 | jq .
set -uo pipefail

REPO="${DHX_HEALTH_REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# shellcheck source=lib/tiers.sh
source "$REPO/scripts/lib/tiers.sh" || {
  echo "health: failed to source $REPO/scripts/lib/tiers.sh" >&2
  exit 1
}

# G-04-01 (Phase 4 Plan 04): per-check timeout parameterized via DHX_HEALTH_TIMEOUT.
# Default 30 (preserves D-10 + pre-G-04-01 behavior — semantically identical when
# unset, per D-36). Override allows probe-suite ergonomics — probe-health-sh-tiering.sh
# sets DHX_HEALTH_TIMEOUT=2 to keep its timeout-case scenario inside run-probes.sh's
# D-16 30s budget. Strict positive-integer validation (PLANNER DISCRETION CALL):
# invalid value → exit 1 with diagnostic (matches D-20 pre-flight format).
#
# IMPORTANT (D-32): use ${DHX_HEALTH_TIMEOUT-30} (NO COLON), not ${DHX_HEALTH_TIMEOUT:-30}.
# The colon form treats empty-string as unset and silently falls back to 30, defeating
# the strict-refusal contract for empty values. The no-colon form passes empty through
# to the regex check, which correctly refuses it.
#
# Placement: BEFORE the mode-parsing block as interface-wide strict env validation
# (D-39 — uniform refusal regardless of mode).
TIMEOUT_S="${DHX_HEALTH_TIMEOUT-30}"
if ! [[ $TIMEOUT_S =~ ^[1-9][0-9]*$ ]]; then
  echo "health: invalid DHX_HEALTH_TIMEOUT='$TIMEOUT_S' (must be positive integer)" >&2
  exit 1
fi

# Per <interfaces> in 04-02-PLAN.md — each leaf tool maps to exactly one
# tiers.json key. The mapping is the join between two cohorts (D-28):
# health.sh check name (kebab-case, left col) → statusline health field
# (snake_case, middle col).
#
# Format: "<name>|<tier_key>|<command>"
CHECKS=(
  "verify-hooks|hooks_wiring|bash $REPO/scripts/verify-hooks.sh"
  "plugin-keys|plugin_keys|bash $REPO/tests/probes/probe-plugin-keys.sh"
  "bashrc-wrapper-heal|plugin_registry|bash $REPO/tests/probes/probe-bashrc-wrapper-heal.sh"
  "settings-path-invariant|settings_chain|bash $REPO/tests/probes/probe-settings-path-invariant.sh"
  "hooks-wiring-probe|hooks_wiring|bash $REPO/tests/probes/probe-hooks-wiring.sh"
  "settings-drift|worktree_patches|git -C $REPO diff --quiet config/settings.json"
)

# Pre-flight sweep (D-20) — jq + 6 leaf tool paths. Convert opaque downstream
# failures into named-tool diagnostics before the per-check loop runs.
preflight() {
  local missing=()
  command -v jq >/dev/null 2>&1 || missing+=("jq")
  command -v git >/dev/null 2>&1 || missing+=("git")
  for entry in "${CHECKS[@]}"; do
    IFS='|' read -r name key cmd <<< "$entry"
    local path
    case "$cmd" in
      bash\ *) path=$(echo "$cmd" | awk '{print $2}') ;;
      *) continue ;;
    esac
    if [[ ! -f "$path" ]]; then
      missing+=("$path (not found)")
      continue
    fi
    [[ -x "$path" ]] || missing+=("$path (not executable)")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "health: pre-flight failures:" >&2
    printf '  - %s\n' "${missing[@]}" >&2
    exit 1
  fi
}

# Tier-membership helper — returns 0 if `key` is in the named array.
in_tier() {
  local key="$1"
  shift
  local arr=("$@")
  for k in "${arr[@]}"; do
    [[ "$k" == "$key" ]] && return 0
  done
  return 1
}

# Mode parsing + D-26 TRUE delegation. --probes / --full / --probes-unsafe
# all `exec` to run-probes.sh; the inline runner lived in an earlier draft
# and was dropped per D-26 (codex HIGH on "delegate" being reimplemented).
MODE="bare"
case "${1:-}" in
  --json)
    MODE="json"
    ;;
  --probes|--full)
    # D-26: TRUE delegate to run-probes.sh --filter SAFE_FOR_LIVE=yes
    exec bash "$REPO/scripts/run-probes.sh" --filter SAFE_FOR_LIVE=yes
    ;;
  --probes-unsafe)
    # D-26: TRUE delegate to run-probes.sh --filter SAFE_FOR_LIVE=no
    # D-27 PWD+CONFIG_DIR refusal lives in run-probes.sh's filter wrapper.
    exec bash "$REPO/scripts/run-probes.sh" --filter SAFE_FOR_LIVE=no
    ;;
  "")
    MODE="bare"
    ;;
  *)
    echo "health: unknown argument '$1' (supported: --json, --probes, --full, --probes-unsafe)" >&2
    exit 1
    ;;
esac

preflight

# Main check loop — per-check timeout 30s; exit 124 → status=timeout.
crit_failures=()
adv_failures=()

for entry in "${CHECKS[@]}"; do
  IFS='|' read -r name tier_key cmd <<< "$entry"
  tier="advisory"
  in_tier "$tier_key" "${CRITICAL[@]}" && tier="critical"

  start_ms=$(date +%s%3N 2>/dev/null || echo 0)
  # shellcheck disable=SC2086
  timeout "$TIMEOUT_S" bash -c "$cmd" >/dev/null 2>&1
  rc=$?
  end_ms=$(date +%s%3N 2>/dev/null || echo 0)
  dur=$((end_ms - start_ms))

  if [ "$rc" -eq 124 ]; then
    status="timeout"
    dur=$((TIMEOUT_S * 1000))
    if [[ "$tier" == "critical" ]]; then
      crit_failures+=("$name")
    else
      adv_failures+=("$name")
    fi
  elif [ "$rc" -eq 0 ]; then
    status="ok"
  else
    status="fail"
    if [[ "$tier" == "critical" ]]; then
      crit_failures+=("$name")
    else
      adv_failures+=("$name")
    fi
  fi

  if [[ "$MODE" == "json" ]]; then
    jq -nc --arg c "$name" --arg t "$tier" --arg s "$status" \
           --argjson rc "$rc" --argjson dur "$dur" \
           '{check:$c, tier:$t, status:$s, exit_code:$rc, duration_ms:$dur}'
  else
    case "$status" in
      ok)      printf '  OK    %s (%s)\n' "$name" "$tier" ;;
      timeout) printf '  [TIMEOUT %ds] %s (%s)\n' "$TIMEOUT_S" "$name" "$tier" ;;
      fail)    printf '  FAIL  %s (%s, exit %d)\n' "$name" "$tier" "$rc" ;;
    esac
  fi
done

# Tier verdict (D-18) — critical wins over advisory.
if [ "${#crit_failures[@]}" -gt 0 ]; then
  final_rc=1
elif [ "${#adv_failures[@]}" -gt 0 ]; then
  final_rc=2
else
  final_rc=0
fi

crit_summary="ok"
[ "${#crit_failures[@]}" -gt 0 ] && crit_summary="fail"
adv_summary="ok"
[ "${#adv_failures[@]}" -gt 0 ] && adv_summary="fail"

if [[ "$MODE" == "json" ]]; then
  # D-30: build JSON arrays via `jq -n '$ARGS.positional' --args` to avoid the
  # `[""]` bug from `printf | jq -R | jq -s` on empty arrays. Empirically
  # validated 2026-05-01: printf trailing newline produces a single empty
  # string in the array; --args version produces `[]` cleanly.
  crit_arr=$(jq -n '$ARGS.positional' --args "${crit_failures[@]}")
  adv_arr=$(jq -n '$ARGS.positional' --args "${adv_failures[@]}")
  jq -nc --arg cs "$crit_summary" --arg as "$adv_summary" \
         --argjson crit "$crit_arr" --argjson adv "$adv_arr" \
         --argjson rc "$final_rc" \
         '{check:"_aggregate", tier_summary:{critical:$cs, advisory:$as}, critical_failures:$crit, advisory_failures:$adv, exit_code:$rc}'
else
  echo
  echo "tier_summary: critical=$crit_summary advisory=$adv_summary"
  [ "${#crit_failures[@]}" -gt 0 ] && echo "  critical fails: ${crit_failures[*]}"
  [ "${#adv_failures[@]}" -gt 0 ] && echo "  advisory fails: ${adv_failures[*]}"
fi

exit $final_rc
