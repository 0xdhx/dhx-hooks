#!/usr/bin/env bash
# probe-test-gate-phase-aware.sh
#
# Regression probe for the phase-aware skip block in dhx/dhx-test-gate.sh.
# Covers the three-condition skip gate (D-05(v) bisectable RED→GREEN
# defense-in-depth) and the fail-soft fallthrough.
#
# Scenarios:
#   1. STATE.md status:executing + PLAN.md cites RED + HEAD not GREEN → SKIP
#   2. STATE.md absent → no skip (gate runs normally)
#   3. STATE.md status:complete → no skip (only `executing` triggers eval)
#   4. STATE.md status:executing + PLAN.md without RED markers → no skip
#   5. STATE.md status:executing + PLAN.md cites RED + HEAD subject "feat: GREEN flip" → no skip (override)
#   6. STATE.md status:executing + no PLAN.md files reachable from HEAD → no skip
#   7. Fail-soft: STATE.md exists but git is broken (no commits) → no skip
#   8. Phase name extraction: PLAN.md path produces correct phase tag in skip message
#
# Backs:
#   - docs/decisions.md — 2026-05-07 phase-aware test-gate skip row
#   - reports/done/2026-05-06-dhx-execute-test-drive-review-2.md (Code Issue #4)
#
# Run: bash tests/probes/probe-test-gate-phase-aware.sh
#
# SAFE_FOR_LIVE: yes  (sandboxed via mktemp + HOME / TMPDIR / CLAUDE_PROJECT_DIR
#                      overrides; no live ~/.cache/dhx, ~/.claude, or systemd
#                      state touched. Stub pytest used as runner so the gate
#                      never actually invokes the host's pytest.)
# RUNTIME: ~3s

set -u

HOOK="/home/dhx/repos/hooks/dhx/dhx-test-gate.sh"
TMP=$(mktemp -d /tmp/probe-test-gate-phase-aware.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
HOOK_OUT=""
HOOK_EXIT=0

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

# setup_project NAME — fresh project with pyproject.toml, .pytest_cache, a stub
# python that records argv (so we can detect whether the runner was invoked),
# and an initialized git repo with a baseline commit.
setup_project() {
  local name="$1"
  local proj="$TMP/$name"
  mkdir -p "$proj/.claude/hooks/logs" "$proj/.venv/bin" "$proj/.pytest_cache"
  cat > "$proj/pyproject.toml" <<'EOF'
[tool.pytest.ini_options]
testpaths = ["tests"]
EOF
  cat > "$proj/.venv/bin/python" <<EOF
#!/usr/bin/env bash
printf '%q ' "\$0" "\$@" >> "$proj/.runner-argv.log"
printf '\n' >> "$proj/.runner-argv.log"
case "\$*" in
  *"--version"*) echo "pytest 0.0.0 (probe stub)"; exit 0 ;;
esac
echo "no tests ran"
exit 0
EOF
  chmod +x "$proj/.venv/bin/python"
  (
    cd "$proj"
    git init -q
    git config user.email "probe@example"
    git config user.name "probe"
    echo "baseline" > README
    git add README
    git -c commit.gpgsign=false commit -qm "chore: baseline"
  )
  echo "$proj"
}

# write_state PROJ STATUS_LINE — write .planning/STATE.md frontmatter.
write_state() {
  local proj="$1" status="$2"
  mkdir -p "$proj/.planning"
  cat > "$proj/.planning/STATE.md" <<EOF
---
$status
---
EOF
}

# write_plan PROJ PHASE PLAN BODY — write .planning/phases/PHASE/PLAN-PLAN.md
# with the given body, then commit it so it is HEAD-reachable.
write_plan() {
  local proj="$1" phase="$2" plan="$3" body="$4"
  local subject="${5:-feat: add ${phase} plan}"
  mkdir -p "$proj/.planning/phases/$phase"
  printf '%s\n' "$body" > "$proj/.planning/phases/$phase/${plan}-PLAN.md"
  (
    cd "$proj"
    git add ".planning/phases/$phase/${plan}-PLAN.md"
    git -c commit.gpgsign=false commit -qm "$subject"
  )
}

set_source_flag() {
  local sid="$1"
  touch "$TMP/claude-source-dirty-${sid}.flag"
}

clear_state() {
  rm -f "$TMP"/claude-source-dirty-*.flag
  rm -f "$TMP"/claude-stop-*.count
}

run_hook() {
  local proj="$1" sid="$2"
  local stdin_json
  stdin_json="{\"session_id\":\"$sid\",\"stop_hook_active\":false}"
  HOOK_EXIT=0
  HOOK_OUT=$(env \
    "HOME=$TMP" \
    "TMPDIR=$TMP" \
    "CLAUDE_PROJECT_DIR=$proj" \
    bash "$HOOK" <<< "$stdin_json" 2>&1) || HOOK_EXIT=$?
}

assert_exit() {
  local expected="$1" label="$2"
  if [ "$HOOK_EXIT" -eq "$expected" ]; then
    echo "OK   $label (exit $HOOK_EXIT)"
    PASS=$((PASS + 1))
  else
    echo "FAIL $label (expected exit $expected, got $HOOK_EXIT)"
    echo "     output: $(printf '%s' "$HOOK_OUT" | tail -n 5)"
    FAIL=$((FAIL + 1))
  fi
}

assert_stdout_contains() {
  local pattern="$1" label="$2"
  if grep -qF -- "$pattern" <<< "$HOOK_OUT"; then
    echo "OK   $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL $label (pattern '$pattern' not in stdout)"
    echo "     output: $HOOK_OUT"
    FAIL=$((FAIL + 1))
  fi
}

assert_stdout_not_contains() {
  local pattern="$1" label="$2"
  if grep -qF -- "$pattern" <<< "$HOOK_OUT"; then
    echo "FAIL $label (unexpected pattern '$pattern' present)"
    echo "     output: $HOOK_OUT"
    FAIL=$((FAIL + 1))
  else
    echo "OK   $label"
    PASS=$((PASS + 1))
  fi
}

assert_runner_invoked() {
  local proj="$1" label="$2"
  if [ -f "$proj/.runner-argv.log" ]; then
    echo "OK   $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL $label (runner argv log missing — gate skipped runner)"
    FAIL=$((FAIL + 1))
  fi
}

assert_runner_not_invoked() {
  local proj="$1" label="$2"
  if [ -f "$proj/.runner-argv.log" ]; then
    echo "FAIL $label (runner argv log present — runner was invoked)"
    echo "     argv: $(cat "$proj/.runner-argv.log")"
    FAIL=$((FAIL + 1))
  else
    echo "OK   $label"
    PASS=$((PASS + 1))
  fi
}

assert_log_contains() {
  local proj="$1" pattern="$2" label="$3"
  if grep -qF -- "$pattern" "$proj/.claude/hooks/logs/test-gate.log" 2>/dev/null; then
    echo "OK   $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL $label (pattern '$pattern' not in test-gate.log)"
    FAIL=$((FAIL + 1))
  fi
}

# Body fixtures.
PLAN_BODY_RED='---
must_haves:
  decisions_implemented:
    - "D-05(v): bisectable RED→GREEN — Wave 1 RED commit"
---
# Plan body
'

PLAN_BODY_NO_RED='---
must_haves:
  decisions_implemented:
    - "D-99: ordinary refactor"
---
# Plan body
'

# ----------------------------------------------------------------------------
# Scenario 1 — All three conditions hold → skip with structured stdout.
# ----------------------------------------------------------------------------
clear_state
PROJ=$(setup_project s1)
write_state "$PROJ" "status: executing"
write_plan "$PROJ" "31.1-test-drive" "01-red" "$PLAN_BODY_RED"
set_source_flag "s1"
run_hook "$PROJ" "s1"
assert_exit 0 "[1] all conditions hold → exit 0 (skip)"
assert_stdout_contains '"systemMessage"' "[1] stdout carries Stop systemMessage advisory"
assert_stdout_not_contains '"hookSpecificOutput"' "[1] stdout MUST NOT carry hookSpecificOutput (Stop schema rejects)"
# Schema-shape sanity: every top-level key must be in CC's Stop output allowlist.
# Schema source: validator output captured at heat-check session JSONL
# (`attachment.hookErrors[0]` of system event `subtype: stop_hook_summary`).
# Allowlist below mirrors the validator's enumerated top-level keys.
if jq -e 'keys | all(. as $k | ["continue","suppressOutput","stopReason","decision","reason","systemMessage","permissionDecision","hookSpecificOutput"] | index($k))' <<< "$HOOK_OUT" >/dev/null 2>&1; then
  echo "OK   [1] stdout keys all in Stop schema top-level allowlist"
  PASS=$((PASS + 1))
else
  echo "FAIL [1] stdout has keys outside Stop schema allowlist (Stop rejects unknown top-level keys)"
  echo "     output: $HOOK_OUT"
  FAIL=$((FAIL + 1))
fi
assert_stdout_contains "Skipping test-gate: phase contracts intentional RED" "[1] stdout names the skip reason"
assert_stdout_contains "/dhx:test 31.1-test-drive" "[1] stdout cites phase tag from PLAN.md path"
assert_runner_not_invoked "$PROJ" "[1] phase-aware skip prevented runner invocation"
assert_log_contains "$PROJ" "Phase-aware skip:" "[1] log records skip branch"

# ----------------------------------------------------------------------------
# Scenario 2 — STATE.md absent → no skip; runner runs normally.
# ----------------------------------------------------------------------------
clear_state
PROJ=$(setup_project s2)
write_plan "$PROJ" "07-some-phase" "01-plan" "$PLAN_BODY_RED"
set_source_flag "s2"
run_hook "$PROJ" "s2"
assert_exit 0 "[2] STATE.md absent → exit 0 (gate ran)"
assert_stdout_not_contains "Skipping test-gate" "[2] no skip message emitted"
assert_runner_invoked "$PROJ" "[2] runner was invoked"

# ----------------------------------------------------------------------------
# Scenario 3 — STATE.md status:complete → no skip eval (only `executing` triggers).
# ----------------------------------------------------------------------------
clear_state
PROJ=$(setup_project s3)
write_state "$PROJ" "status: complete"
write_plan "$PROJ" "07-some-phase" "01-plan" "$PLAN_BODY_RED"
set_source_flag "s3"
run_hook "$PROJ" "s3"
assert_exit 0 "[3] status:complete → exit 0 (gate ran)"
assert_stdout_not_contains "Skipping test-gate" "[3] no skip message emitted"
assert_runner_invoked "$PROJ" "[3] runner was invoked"

# ----------------------------------------------------------------------------
# Scenario 4 — Mid-execute but PLAN.md lacks RED markers → no skip.
# ----------------------------------------------------------------------------
clear_state
PROJ=$(setup_project s4)
write_state "$PROJ" "status: executing"
write_plan "$PROJ" "08-no-red-phase" "01-plan" "$PLAN_BODY_NO_RED"
set_source_flag "s4"
run_hook "$PROJ" "s4"
assert_exit 0 "[4] no RED in PLAN → exit 0 (gate ran)"
assert_stdout_not_contains "Skipping test-gate" "[4] no skip message emitted"
assert_runner_invoked "$PROJ" "[4] runner was invoked"

# ----------------------------------------------------------------------------
# Scenario 5 — Mid-execute + RED PLAN, but HEAD subject names GREEN → override
# (the GREEN flip just landed; user wants the gate to run and verify it).
# ----------------------------------------------------------------------------
clear_state
PROJ=$(setup_project s5)
write_state "$PROJ" "status: executing"
write_plan "$PROJ" "31.1-test-drive" "01-red" "$PLAN_BODY_RED" "feat(green): flip RED → GREEN"
set_source_flag "s5"
run_hook "$PROJ" "s5"
assert_exit 0 "[5] HEAD names GREEN/flip → exit 0 (override fires)"
assert_stdout_not_contains "Skipping test-gate" "[5] override prevented skip emission"
assert_runner_invoked "$PROJ" "[5] runner was invoked under GREEN-flip override"
assert_log_contains "$PROJ" "Phase-aware: HEAD subject names GREEN/flip" "[5] log records override branch"

# ----------------------------------------------------------------------------
# Scenario 6 — Mid-execute but no PLAN.md reachable from HEAD → no skip.
# ----------------------------------------------------------------------------
clear_state
PROJ=$(setup_project s6)
write_state "$PROJ" "status: executing"
# No write_plan call — there are no PLAN.md files at all.
set_source_flag "s6"
run_hook "$PROJ" "s6"
assert_exit 0 "[6] no PLAN.md reachable → exit 0 (gate ran)"
assert_stdout_not_contains "Skipping test-gate" "[6] no skip message emitted"
assert_runner_invoked "$PROJ" "[6] runner was invoked"

# ----------------------------------------------------------------------------
# Scenario 7 — Fail-soft: STATE.md exists but project has NO git directory →
# git commands fail → empty PLAN_FILES → no skip → gate runs.
# ----------------------------------------------------------------------------
clear_state
PROJ=$(setup_project s7)
write_state "$PROJ" "status: executing"
rm -rf "$PROJ/.git"
set_source_flag "s7"
run_hook "$PROJ" "s7"
assert_exit 0 "[7] fail-soft on git failure → exit 0 (gate ran)"
assert_stdout_not_contains "Skipping test-gate" "[7] no skip emitted on git failure"
assert_runner_invoked "$PROJ" "[7] runner was invoked"

# ----------------------------------------------------------------------------
# Scenario 8 — Phase name extraction. PLAN path
# `.planning/phases/12-some-phase/02-followup-PLAN.md` → phase=`12-some-phase`.
# ----------------------------------------------------------------------------
clear_state
PROJ=$(setup_project s8)
write_state "$PROJ" "status: executing"
write_plan "$PROJ" "12-some-phase" "02-followup" "$PLAN_BODY_RED"
set_source_flag "s8"
run_hook "$PROJ" "s8"
assert_exit 0 "[8] phase extraction → exit 0 (skip)"
assert_stdout_contains "/dhx:test 12-some-phase" "[8] stdout names exact phase from PLAN.md path"
assert_stdout_contains ".planning/phases/12-some-phase/02-followup-PLAN.md" "[8] stdout names the citing PLAN file"

# ----------------------------------------------------------------------------
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
