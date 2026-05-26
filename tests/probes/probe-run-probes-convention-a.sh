#!/bin/bash
# probe-run-probes-convention-a.sh
#
# SAFE_FOR_LIVE: yes  (fully mktemp-isolated; copies run-probes.sh into a tmp
#                      REPO-shaped tree; never touches the live repo, ~/.claude,
#                      or ~/.cache/dhx)
# RUNTIME: ~3s
#
# INVARIANT: scripts/run-probes.sh gates its non-zero-RC FAIL increment on the
# probe's resolved exit_code_convention (read from the per-probe outcome JSON):
#   - Convention A (exit_0_means_v1_2_work_warranted) + conclusion supersession_found_*
#     at RC 1|2 → NOT a FAIL (bucketed into the SUPERSESSION counter / line).
#   - Convention A + conclusion error|ambiguous, OR RC>=3 → FAIL.
#   - Convention B (field absent or exit_0_means_pass) + non-zero RC → FAIL (unchanged).
#   - Non-zero RC with missing/unparseable JSON (or absent jq) → fail SAFE → FAIL.
#
# Backs:
#   - .planning/backlog/2026-05-13-run-probes-convention-a-recognition.md
#   - quick task 260526-1qm (Convention-A FAIL gating in run-probes.sh)
#
# Method (black-box — exercises the REAL loop, not a copy of its logic):
#   For each case build an isolated mktemp REPO-shaped sandbox:
#     <tmp>/scripts/run-probes.sh        ← copy of the live script under test
#     <tmp>/tests/probes/probe-fixture-<case>.sh  ← fake probe (exits chosen RC)
#     <tmp>/tests/probes/.results/v1.3-multi-cc-ver/<cc>/probe-fixture-<case>.json
#   run-probes.sh derives REPO from `dirname "$0"/..` and globs
#   $REPO/tests/probes/probe-*.{js,sh}, so the copied script is confined to the
#   single fake probe in the sandbox. The outcome JSON is written into BOTH the
#   resolved active-cc dir AND the literal `unknown` dir so the case is
#   version-agnostic (the loop resolves whichever the host `claude --version`
#   yields, falling back to `unknown`).
#
# Run: bash tests/probes/probe-run-probes-convention-a.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_RUN_PROBES="$SCRIPT_DIR/../../scripts/run-probes.sh"
PASS=0
FAIL=0

assert() {
  local name="$1" cond="$2"
  if [[ "$cond" == "true" ]]; then
    echo "OK   $name"; PASS=$((PASS+1))
  else
    echo "FAIL $name"; FAIL=$((FAIL+1))
  fi
}

# Resolve the active CC version the way run-probes.sh does, so the JSON lands
# where the loop looks. Also write into `unknown` for version-agnosticism.
ACTIVE_CC=$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
[[ -n "$ACTIVE_CC" ]] || ACTIVE_CC="unknown"

# build_sandbox <case> <exit_rc> <write_json:yes|no> [jq-args for the JSON object]
# Creates the tmp tree, the fake probe, and (optionally) the outcome JSON in
# both the active-cc dir and the unknown dir. Echoes the tmp REPO path.
build_sandbox() {
  local case_name="$1" rc="$2" write_json="$3"; shift 3
  local tmp; tmp=$(mktemp -d)
  mkdir -p "$tmp/scripts" "$tmp/tests/probes"
  cp "$REAL_RUN_PROBES" "$tmp/scripts/run-probes.sh"

  local probe="$tmp/tests/probes/probe-fixture-${case_name}.sh"
  {
    echo '#!/bin/bash'
    echo "# SAFE_FOR_LIVE: yes"
    echo "exit $rc"
  } > "$probe"
  chmod +x "$probe"

  if [[ "$write_json" == "yes" ]]; then
    local obj; obj=$(jq -n "$@")
    local d
    for d in "$ACTIVE_CC" "unknown"; do
      mkdir -p "$tmp/tests/probes/.results/v1.3-multi-cc-ver/$d"
      printf '%s\n' "$obj" > "$tmp/tests/probes/.results/v1.3-multi-cc-ver/$d/probe-fixture-${case_name}.json"
    done
  fi
  echo "$tmp"
}

# run_case <tmp-repo> → captures stdout into RUN_OUT, exit into RUN_RC, and
# parses the summary-line FAIL + SUPERSESSION counts into SUM_FAIL / SUM_SUP.
RUN_OUT=""; RUN_RC=0; SUM_FAIL=0; SUM_SUP=0
run_case() {
  local tmp="$1"
  RUN_OUT=$(cd "$tmp" && bash scripts/run-probes.sh 2>&1); RUN_RC=$?
  local summary; summary=$(printf '%s\n' "$RUN_OUT" | grep '^Probes:' | tail -1)
  SUM_FAIL=$(printf '%s' "$summary" | grep -oE '[0-9]+ failed' | grep -oE '^[0-9]+' || echo 0)
  SUM_SUP=$(printf '%s' "$summary" | grep -oE '[0-9]+ supersession-observed' | grep -oE '^[0-9]+' || echo 0)
  [[ -n "$SUM_FAIL" ]] || SUM_FAIL=0
  [[ -n "$SUM_SUP" ]] || SUM_SUP=0
}

# ---- CASE A: Convention A pass-through (exit 1, supersession_found_*) --------
TA=$(build_sandbox "case-a" 1 yes \
  '{probe_id:"probe-fixture-case-a", exit_code:1, exit_code_convention:"exit_0_means_v1_2_work_warranted", conclusion:"supersession_found_drop_p3"}')
run_case "$TA"
assert "CASE A: supersession_found at exit 1 → FAIL count == 0" "$([[ "$SUM_FAIL" -eq 0 ]] && echo true || echo false)"
assert "CASE A: SUPERSESSION count >= 1" "$([[ "$SUM_SUP" -ge 1 ]] && echo true || echo false)"
assert "CASE A: [SUPERSESSION OBSERVED] line present" "$(printf '%s' "$RUN_OUT" | grep -q '\[SUPERSESSION OBSERVED\]' && echo true || echo false)"
assert "CASE A: run-probes exits 0" "$([[ "$RUN_RC" -eq 0 ]] && echo true || echo false)"
rm -rf "$TA"

# ---- CASE B: Convention A ambiguous (exit 2) → FAIL -------------------------
TB=$(build_sandbox "case-b" 2 yes \
  '{probe_id:"probe-fixture-case-b", exit_code:2, exit_code_convention:"exit_0_means_v1_2_work_warranted", conclusion:"ambiguous"}')
run_case "$TB"
assert "CASE B: conclusion=ambiguous → FAIL count >= 1" "$([[ "$SUM_FAIL" -ge 1 ]] && echo true || echo false)"
assert "CASE B: run-probes exits non-zero" "$([[ "$RUN_RC" -ne 0 ]] && echo true || echo false)"
rm -rf "$TB"

# ---- CASE C: Convention A error → FAIL --------------------------------------
# WARNING (plan-checker): the fake probe MUST exit non-zero, else RC==0 routes
# to the PASS branch and the Convention-A gating block is never entered. We use
# exit 1 so the conclusion:error path is actually exercised.
TC=$(build_sandbox "case-c" 1 yes \
  '{probe_id:"probe-fixture-case-c", exit_code:1, exit_code_convention:"exit_0_means_v1_2_work_warranted", conclusion:"error"}')
run_case "$TC"
assert "CASE C: conclusion=error → FAIL count >= 1" "$([[ "$SUM_FAIL" -ge 1 ]] && echo true || echo false)"
assert "CASE C: run-probes exits non-zero" "$([[ "$RUN_RC" -ne 0 ]] && echo true || echo false)"
rm -rf "$TC"

# ---- CASE D: Convention B unchanged (exit 1, no exit_code_convention) → FAIL -
TD=$(build_sandbox "case-d" 1 yes \
  '{probe_id:"probe-fixture-case-d", exit_code:1, conclusion:"failed"}')
run_case "$TD"
assert "CASE D: Convention B non-zero → FAIL count >= 1" "$([[ "$SUM_FAIL" -ge 1 ]] && echo true || echo false)"
assert "CASE D: run-probes exits non-zero" "$([[ "$RUN_RC" -ne 0 ]] && echo true || echo false)"
rm -rf "$TD"

# ---- CASE E: fail-SAFE (exit 1, NO outcome JSON written) → FAIL -------------
TE=$(build_sandbox "case-e" 1 no)
run_case "$TE"
assert "CASE E: missing JSON fails SAFE → FAIL count >= 1" "$([[ "$SUM_FAIL" -ge 1 ]] && echo true || echo false)"
assert "CASE E: run-probes exits non-zero" "$([[ "$RUN_RC" -ne 0 ]] && echo true || echo false)"
rm -rf "$TE"

# ---- Summary ----------------------------------------------------------------
echo "---"
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
