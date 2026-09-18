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
assert "CASE A: [SUPERSESSION OBSERVED] line present" "$(grep -q '\[SUPERSESSION OBSERVED\]' < <(printf '%s' "$RUN_OUT") && echo true || echo false)"
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

# ─────────────────────────────────────────────────────────────────────────────
# SUITE_TIMEOUT per-probe time budget (added 2026-09-18)
#
# Same contract as the cells above — how run-probes.sh assigns a verdict to one
# probe — on its other FAIL path: `[TIMED OUT]` increments FAIL just as a bad RC
# does. Filed here rather than as its own probe for that reason.
#
# The budget replaced a hardcoded `timeout 30`. Two probes are structurally over
# it and cannot be made faster (probe-sync-mirror-publish-gate.sh, O(commits) git
# filter-repo; probe-agent-registry-session-start-cached.sh, two real `claude -p`
# children at 39s) — the second died at 30s on EVERY run under
# --filter SAFE_FOR_LIVE=no.
#
# The parser is SOURCED OUT OF THE LIVE SCRIPT, never transcribed. A copied
# regex passes while the shipped one is wrong, which is the failure these cells
# exist to catch.

BUDGET_FN=$(mktemp)
sed -n '/^probe_budget() {/,/^}/p' "$REAL_RUN_PROBES" > "$BUDGET_FN"
assert "budget parser extracted from the live run-probes.sh" \
  "$([[ -s "$BUDGET_FN" ]] && grep -q 'MALFORMED' "$BUDGET_FN" && echo true || echo false)"

# bt <tag-line> -> echoes "<rc>|<stdout>".
# The rc rides on STDOUT deliberately: `bt` is called inside $( ), which is a
# SUBSHELL, so a variable it sets is discarded at the boundary while stdout
# crosses it. An earlier cut set BT_RC in the function and read it in the parent,
# where under `set -u` it was simply unbound — the same shape as the documented
# `arr+=()` inside $( ) trap.
bt() {
  local tagline="$1" f; f=$(mktemp)
  { echo '#!/usr/bin/env bash'; [[ -n "$tagline" ]] && echo "$tagline"; echo 'echo hi'; } > "$f"
  local out rc
  out=$(bash -c 'BUDGET_DEFAULT=30; source "$1"; probe_budget "$2"' _ "$BUDGET_FN" "$f"); rc=$?
  rm -f "$f"; echo "${rc}|${out}"
}
bt_out() { bt "$1" | cut -d'|' -f2-; }
bt_rc()  { bt "$1" | cut -d'|' -f1; }

assert "untagged probe gets exactly the 30s default (asserted, not assumed)" \
  "$([[ "$(bt_out '')" == "30" ]] && echo true || echo false)"
assert "a declared budget is honoured verbatim (120)" \
  "$([[ "$(bt_out '# SUITE_TIMEOUT: 120')" == "120" ]] && echo true || echo false)"
assert "the // comment form is read too (JS probes)" \
  "$([[ "$(bt_out '// SUITE_TIMEOUT: 90')" == "90" ]] && echo true || echo false)"
assert "upper bound 900 accepted" \
  "$([[ "$(bt_out '# SUITE_TIMEOUT: 900')" == "900" ]] && echo true || echo false)"
for bad in 'banana' '-5' '901' '0'; do
  _o=$(bt_out "# SUITE_TIMEOUT: $bad"); _r=$(bt_rc "# SUITE_TIMEOUT: $bad")
  assert "malformed budget '$bad' REFUSES (rc!=0), never silently falls back to 30" \
    "$([[ "$_r" -ne 0 && "$_o" != "30" ]] && echo true || echo false)"
done
rm -f "$BUDGET_FN"

# End-to-end: the budget must actually reach `timeout`. A parser that returns the
# right number while the loop still passes 30 to `timeout` satisfies every cell above.
# bsleep <case> <tagline> <sleep-secs> -> tmp REPO root
bsleep() {
  local name="$1" tagline="$2" secs="$3" tmp; tmp=$(mktemp -d)
  mkdir -p "$tmp/scripts" "$tmp/tests/probes"
  cp "$REAL_RUN_PROBES" "$tmp/scripts/run-probes.sh"
  { echo '#!/usr/bin/env bash'
    echo '# SAFE_FOR_LIVE: yes'
    [[ -n "$tagline" ]] && echo "$tagline"
    echo "touch \"$tmp/RAN\""
    echo "sleep $secs"
    echo 'echo "1 passed, 0 failed"'
  } > "$tmp/tests/probes/probe-fixture-$name.sh"
  echo "$tmp"
}

T=$(bsleep budget-tiny '# SUITE_TIMEOUT: 1' 3)
OUT=$(bash "$T/scripts/run-probes.sh" 2>&1 || true)
assert "tiny budget actually reaches timeout — probe is killed and named" \
  "$(grep -q 'TIMED OUT.*probe-fixture-budget-tiny.*exceeded 1s' <<<"$OUT" && echo true || echo false)"
rm -rf "$T"

# The mutation PAIR: identical body, only the tag differs, opposite outcome.
T=$(bsleep budget-generous '# SUITE_TIMEOUT: 60' 3)
OUT=$(bash "$T/scripts/run-probes.sh" 2>&1 || true)
assert "same 3s body under a 60s budget completes — the pair proves the tag is causal" \
  "$(! grep -q 'TIMED OUT' <<<"$OUT" && grep -q '1 passed, 0 failed' <<<"$OUT" && echo true || echo false)"
assert "an explicitly budgeted probe ALWAYS reports elapsed-vs-budget" \
  "$(grep -qE '\[BUDGET\] probe-fixture-budget-generous\.sh — [0-9]+s of 60s' <<<"$OUT" && echo true || echo false)"
rm -rf "$T"

# A malformed tag must REFUSE THE RUN, not run it under the default. If the probe
# executes, its marker file appears — that is the discriminator a message-only
# assertion would miss.
T=$(bsleep budget-bad '# SUITE_TIMEOUT: banana' 0)
OUT=$(bash "$T/scripts/run-probes.sh" 2>&1 || true)
assert "malformed budget is reported as a FAIL, not skipped silently" \
  "$(grep -q 'FAIL.*probe-fixture-budget-bad.*malformed SUITE_TIMEOUT' <<<"$OUT" && echo true || echo false)"
assert "...and the probe did NOT execute under a fallback budget" \
  "$([[ ! -f "$T/RAN" ]] && echo true || echo false)"
rm -rf "$T"

# An untagged fast probe must stay quiet, or a 150-probe run drowns in [BUDGET].
T=$(bsleep budget-quiet '' 0)
OUT=$(bash "$T/scripts/run-probes.sh" 2>&1 || true)
assert "untagged fast probe emits no [BUDGET] line (the suite stays readable)" \
  "$(! grep -q '\[BUDGET\] probe-fixture-budget-quiet' <<<"$OUT" && echo true || echo false)"
rm -rf "$T"

echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
