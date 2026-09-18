#!/bin/bash
# probe-conclusion-taxonomy.sh
#
# SAFE_FOR_LIVE: yes  (fully mktemp-isolated; copies run-probes.sh +
#                      verify-multi-cc-results.sh into throwaway REPO-shaped
#                      trees; never touches the live repo or ~/.claude)
# RUNTIME: ~5s
#
# INVARIANT: ONE conclusion taxonomy is shared by all three consumers — the
# watchdog probes that WRITE a conclusion, run-probes.sh's Convention-A gate
# that ROUTES it, and verify-multi-cc-results.sh that VALIDATES it. A token
# admitted by one consumer and unknown to another is the defect class this
# probe exists to prevent; it has now cost two repo-wide commit blocks
# (2026-07-09, 2026-08-23).
#
#   decisive positive : supersession_found_*            -> SUPERSESSION, exit 0
#   decisive negative : validated_stable|v1_2_work_warranted (exit 0 -> PASS)
#   no observation    : skipped                         -> SKIPPED, exit 0
#   indeterminate     : ambiguous, ambiguous_*          -> FAIL
#   malfunction       : error                           -> FAIL
#   BROKEN DEPENDENCY : regression_found_*              -> FAIL (Conv-B token;
#                       under Conv-A it lands on `*)` and fail-SAFEs, asserted below)
#   UNKNOWN TOKEN     : anything else                   -> FAIL (fail SAFE)
#
# `regression_found_*` was added 2026-09-18 with the inverted
# probe-effort-level-stdin-absent.sh. It is the set's only DECISIVE NEGATIVE
# about OUR shipped code rather than about upstream's: a runtime dependency we
# already depend on has broken. The validator must ACCEPT it (Part 2) and the
# runner must never route it anywhere informational (Part 1).
#
# The last row is the load-bearing one. Before this fix the runner's Convention-A
# branch routed EVERY non-error/non-exact-`ambiguous` token to SUPERSESSION, so a
# probe that self-skipped for a missing API key was reported as an OBSERVED
# SUPERSESSION and the run exited 0 — a materially false scientific verdict, and
# one that predates this change (reproduced at HEAD a074657, 2026-08-23).
#
# Backs:
#   - docs/backlog.md row `natural-heal-probes-write-forbidden-conclusion`
#   - .planning/backlog/2026-08-23-run-probes-folds-unrelated-validator-into-tier-exit.md
#     (acceptance criterion 3 — the producer/validator half)
#
# Run: bash tests/probes/probe-conclusion-taxonomy.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
PASS=0
FAIL=0
TMPS=()
cleanup() { local t; for t in "${TMPS[@]:-}"; do [ -n "$t" ] && rm -rf "$t"; done; }
trap cleanup EXIT

assert() {
  local name="$1" cond="$2"
  if [[ "$cond" == "true" ]]; then echo "OK   $name"; PASS=$((PASS+1))
  else echo "FAIL $name"; FAIL=$((FAIL+1)); fi
}

VER="9.9.9"   # explicit-version mode everywhere — no `claude --version` dependency

# ============================================================================
# Part 1 — the RUNNER's Convention-A routing, per token
# ============================================================================
# route_token <conclusion> -> sets R_RC, R_OUT for a fixture probe exiting 2
# with that conclusion. The fixture JSON is written into BOTH the resolved
# active-cc dir and `unknown`, so the loop finds it whichever way it resolves.
R_RC=0; R_OUT=""
route_token() {
  local conc="$1" t d
  t=$(mktemp -d); TMPS+=("$t")
  mkdir -p "$t/scripts" "$t/tests/probes"
  cp "$REPO/scripts/run-probes.sh" "$t/scripts/"
  printf '#!/bin/bash\n# SAFE_FOR_LIVE: yes\n# LIVE_RUNTIME: no\nexit 2\n' \
    > "$t/tests/probes/probe-fixture-taxonomy.sh"
  chmod +x "$t/tests/probes/probe-fixture-taxonomy.sh"
  local cc; cc=$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
  for d in "$cc" unknown; do
    [[ -n "$d" ]] || continue
    mkdir -p "$t/tests/probes/.results/v1.3-multi-cc-ver/$d"
    printf '{"probe_id":"probe-fixture-taxonomy","exit_code":2,"exit_code_convention":"exit_0_means_v1_2_work_warranted","conclusion":"%s"}\n' \
      "$conc" > "$t/tests/probes/.results/v1.3-multi-cc-ver/$d/probe-fixture-taxonomy.json"
  done
  R_OUT=$(cd "$t" && bash scripts/run-probes.sh --filter SAFE_FOR_LIVE=yes --filter LIVE_RUNTIME=no 2>&1)
  R_RC=$?
}

echo "=== Part 1: runner Convention-A routing ==="

route_token supersession_found_drop_heal
assert "supersession_found_* -> SUPERSESSION, exit 0" \
  "$([[ "$R_RC" -eq 0 ]] && grep -q '\[SUPERSESSION OBSERVED\]' < <(printf '%s' "$R_OUT") && echo true || echo false)"

route_token skipped
assert "skipped -> NOT counted as a supersession" \
  "$(grep -q '\[SUPERSESSION OBSERVED\]' < <(printf '%s' "$R_OUT") && echo false || echo true)"
assert "skipped -> NOT counted as a failure (exit 0)" \
  "$([[ "$R_RC" -eq 0 ]] && echo true || echo false)"
assert "skipped -> announced as a self-skip" \
  "$(grep -q '\[SELF-SKIPPED\]' < <(printf '%s' "$R_OUT") && echo true || echo false)"

route_token ambiguous
assert "ambiguous -> FAIL" \
  "$([[ "$R_RC" -ne 0 ]] && grep -q '\[FAIL\]' < <(printf '%s' "$R_OUT") && echo true || echo false)"

route_token ambiguous_pre_state_abnormal
assert "ambiguous_pre_state_abnormal -> FAIL (anchored 'ambiguous' never covered it)" \
  "$([[ "$R_RC" -ne 0 ]] && grep -q '\[FAIL\]' < <(printf '%s' "$R_OUT") && echo true || echo false)"

route_token error
assert "error -> FAIL" \
  "$([[ "$R_RC" -ne 0 ]] && grep -q '\[FAIL\]' < <(printf '%s' "$R_OUT") && echo true || echo false)"

route_token regression_found_effort_level_unrenderable
assert "regression_found_* -> FAIL, never SUPERSESSION (a broken dependency must reach a human)" \
  "$([[ "$R_RC" -ne 0 ]] && grep -q '\[SUPERSESSION OBSERVED\]' < <(printf '%s' "$R_OUT") && echo false || \
     { [[ "$R_RC" -ne 0 ]] && echo true || echo false; })"

route_token totally_unknown_token
assert "an UNKNOWN token -> FAIL, never SUPERSESSION (fail SAFE)" \
  "$([[ "$R_RC" -ne 0 ]] && grep -q '\[SUPERSESSION OBSERVED\]' < <(printf '%s' "$R_OUT") && echo false || \
     { [[ "$R_RC" -ne 0 ]] && echo true || echo false; })"

# ============================================================================
# Part 2 — the VALIDATOR's accepted token set
# ============================================================================
# validate_token <conclusion> -> sets V_RC, V_OUT
V_RC=0; V_OUT=""
validate_token() {
  local conc="$1" t
  t=$(mktemp -d); TMPS+=("$t")
  mkdir -p "$t/scripts" "$t/docs" "$t/tests/probes/.results/v1.3-multi-cc-ver/$VER"
  cp "$REPO/scripts/verify-multi-cc-results.sh" "$t/scripts/"
  chmod +x "$t/scripts/verify-multi-cc-results.sh"
  : > "$t/docs/decisions.md"
  printf '{"probe_id":"probe-known-marketplaces-natural-heal","cc_version":"%s","cc_version_match":true,"conclusion":"%s"}\n' \
    "$VER" "$conc" > "$t/tests/probes/.results/v1.3-multi-cc-ver/$VER/probe-known-marketplaces-natural-heal.json"
  V_OUT=$(bash "$t/scripts/verify-multi-cc-results.sh" "$VER" 2>&1); V_RC=$?
}

echo
echo "=== Part 2: validator accepted token set ==="

for tok in validated_stable v1_2_work_warranted ambiguous supersession_found_drop_heal \
           skipped ambiguous_pre_state_abnormal regression_found_effort_level_unrenderable; do
  validate_token "$tok"
  assert "validator ACCEPTS '$tok'" "$([[ "$V_RC" -eq 0 ]] && echo true || echo false)"
done

validate_token totally_unknown_token
assert "validator REJECTS an unknown token" "$([[ "$V_RC" -ne 0 ]] && echo true || echo false)"

# ============================================================================
# Part 3 — assertion 5 covers EVERY non-decisive conclusion, not just exact
#          `ambiguous`. A cell with no decisive verdict must never be cited in
#          a "Validated stable" decisions.md row.
# ============================================================================
echo
echo "=== Part 3: assertion 5 spans all non-decisive conclusions ==="

cite_check() {
  local conc="$1" t
  t=$(mktemp -d); TMPS+=("$t")
  mkdir -p "$t/scripts" "$t/docs" "$t/tests/probes/.results/v1.3-multi-cc-ver/$VER"
  cp "$REPO/scripts/verify-multi-cc-results.sh" "$t/scripts/"
  chmod +x "$t/scripts/verify-multi-cc-results.sh"
  printf '| 2026-01-01 | x | Validated stable — v1.3-multi-cc-ver/%s/probe-known-marketplaces-natural-heal | y |\n' \
    "$VER" > "$t/docs/decisions.md"
  printf '{"probe_id":"probe-known-marketplaces-natural-heal","cc_version":"%s","cc_version_match":true,"conclusion":"%s"}\n' \
    "$VER" "$conc" > "$t/tests/probes/.results/v1.3-multi-cc-ver/$VER/probe-known-marketplaces-natural-heal.json"
  V_OUT=$(bash "$t/scripts/verify-multi-cc-results.sh" "$VER" 2>&1); V_RC=$?
}

cite_check ambiguous
assert "an 'ambiguous' cell cited as Validated stable is REJECTED" \
  "$([[ "$V_RC" -ne 0 ]] && echo true || echo false)"

cite_check ambiguous_pre_state_abnormal
assert "an 'ambiguous_pre_state_abnormal' cell cited as Validated stable is REJECTED" \
  "$([[ "$V_RC" -ne 0 ]] && echo true || echo false)"

cite_check skipped
assert "a 'skipped' cell cited as Validated stable is REJECTED" \
  "$([[ "$V_RC" -ne 0 ]] && echo true || echo false)"

cite_check validated_stable
assert "a decisive 'validated_stable' cell cited as Validated stable is ALLOWED" \
  "$([[ "$V_RC" -eq 0 ]] && echo true || echo false)"

echo "---"
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
