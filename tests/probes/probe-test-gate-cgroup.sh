#!/usr/bin/env bash
# probe-test-gate-cgroup.sh
#
# Regression probe for dhx/dhx-test-gate.sh. Covers:
#   - cgroup wrap (Q1) — MemoryMax + MemorySwapMax=0 → exit 137; RuntimeMaxSec → exit 143
#   - fail-open exit codes (Q3) — 137 / 143 / 124
#   - per-project config (Q4) — .claude/test-gate.json target/memory_max/runtime_max_sec
#   - opt-out cascade — env / sentinel / JSON disabled
#   - graceful host fallback — no systemd-run / no active user-systemd → bare invocation
#   - HP-028 SIGPIPE regression — here-string preserves "no tests ran" detection on >64 KiB output
#   - dual-guard — primary (stop_hook_active) + secondary (counter ≥ 2)
#   - dropped dead `pytest -x` full-suite fallback
#
# Backs:
#   - docs/decisions.md — 2026-05-03 cgroup-bound test-gate row
#   - reports/2026-05-03-test-gate-collection-cost.md (design memo)
#   - docs/hook-patterns.md — HP-001, HP-002, HP-009, HP-020, HP-028
#
# Run: bash tests/probes/probe-test-gate-cgroup.sh
#
# SAFE_FOR_LIVE: no   (uses systemd-run --user --scope to enforce real cgroup
#                       limits on real subprocesses; isolated via per-scenario
#                       mktemp + HOME / TMPDIR / CLAUDE_PROJECT_DIR overrides
#                       so the probe does NOT touch live ~/.cache/dhx,
#                       ~/.claude, or any user-level systemd state.)
# RUNTIME: ~25s

set -u

HOOK="/home/dhx/repos/hooks/dhx/dhx-test-gate.sh"
TMP=$(mktemp -d /tmp/probe-test-gate-cgroup.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
HOOK_OUT=""
HOOK_EXIT=0

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

# setup_project NAME — creates a fresh project layout under $TMP/$NAME and
# echoes its absolute path. Always includes pyproject.toml so the runner
# cascade settles on pytest unless overridden.
setup_project() {
  local name="$1"
  local proj="$TMP/$name"
  mkdir -p "$proj/.claude/hooks/logs" "$proj/.venv/bin" "$proj/.pytest_cache"
  cat > "$proj/pyproject.toml" <<'EOF'
[tool.pytest.ini_options]
testpaths = ["tests"]
EOF
  echo "$proj"
}

# stub_pytest PROJ EXIT_CODE OUTPUT_BODY — installs $PROJ/.venv/bin/python as
# a bash stub that responds to `python -m pytest …` invocations:
#   --version          → echoes "pytest <stub>" and exits 0 (cascade probe)
#   --last-failed …    → echoes OUTPUT_BODY and exits EXIT_CODE
#   anything else      → echoes OUTPUT_BODY and exits EXIT_CODE
# Records the full argv to $PROJ/.runner-argv.log on every call so probes
# can assert what the gate actually invoked.
stub_pytest() {
  local proj="$1" exit_code="$2"
  local body="${3:-}"
  cat > "$proj/.venv/bin/python" <<EOF
#!/usr/bin/env bash
printf '%q ' "\$0" "\$@" >> "$proj/.runner-argv.log"
printf '\n' >> "$proj/.runner-argv.log"
case "\$*" in
  *"--version"*)
    echo "pytest 0.0.0 (probe stub)"
    exit 0
    ;;
esac
cat <<'BODY'
$body
BODY
exit $exit_code
EOF
  chmod +x "$proj/.venv/bin/python"
}

# Run the hook with sandboxed env. Captures HOOK_OUT and HOOK_EXIT globals.
# Args: PROJ SESSION_ID STOP_HOOK_ACTIVE [extra env KEY=VAL ...]
run_hook() {
  local proj="$1" sid="$2" stop_active="${3:-false}"
  local extra_env=()
  if [ "$#" -gt 3 ]; then
    shift 3
    extra_env=("$@")
  fi
  local stdin_json
  stdin_json="{\"session_id\":\"$sid\",\"stop_hook_active\":$stop_active}"
  HOOK_EXIT=0
  HOOK_OUT=$(env \
    "HOME=$TMP" \
    "TMPDIR=$TMP" \
    "CLAUDE_PROJECT_DIR=$proj" \
    "${extra_env[@]}" \
    bash "$HOOK" <<< "$stdin_json" 2>&1) || HOOK_EXIT=$?
}

set_source_flag() {
  local sid="$1"
  touch "$TMP/claude-source-dirty-${sid}.flag"
}

clear_state() {
  rm -f "$TMP"/claude-source-dirty-*.flag
  rm -f "$TMP"/claude-stop-*.count
}

read_log() {
  local proj="$1"
  cat "$proj/.claude/hooks/logs/test-gate.log" 2>/dev/null || true
}

# Build a PATH bin dir that mirrors the host's binaries except systemd-run.
# Used by scenario 11 to assert the "no systemd-run" graceful fallback.
build_path_without_systemd_run() {
  local bin="$TMP/no-systemd-run-bin"
  [ -d "$bin" ] && { echo "$bin"; return; }
  mkdir -p "$bin"
  local tool resolved
  for tool in jq python3 bash sh dash cat ls grep sed awk tail head env mkdir touch rm cp mv date dirname basename which command type tr cut tee printf systemctl flock; do
    resolved=$(command -v "$tool" 2>/dev/null) || continue
    ln -sf "$resolved" "$bin/$tool"
  done
  # Deliberately not linking systemd-run.
  echo "$bin"
}

# Build a stub-systemctl bin that returns non-zero for `--user is-active …`.
# Used by scenario 12 — real systemd-run remains on PATH; the AND-chain
# breaks on the systemctl conjunct instead.
build_path_with_inactive_user_systemd() {
  local bin="$TMP/inactive-systemd-bin"
  [ -d "$bin" ] && { echo "$bin"; return; }
  mkdir -p "$bin"
  cat > "$bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "stubbed systemctl: user systemd inactive (probe scenario 12)" >&2
exit 3
EOF
  chmod +x "$bin/systemctl"
  echo "$bin"
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

assert_log_not_contains() {
  local proj="$1" pattern="$2" label="$3"
  if grep -qF -- "$pattern" "$proj/.claude/hooks/logs/test-gate.log" 2>/dev/null; then
    echo "FAIL $label (unexpected pattern '$pattern' present)"
    FAIL=$((FAIL + 1))
  else
    echo "OK   $label"
    PASS=$((PASS + 1))
  fi
}

assert_argv_contains() {
  local proj="$1" pattern="$2" label="$3"
  if grep -qF -- "$pattern" "$proj/.runner-argv.log" 2>/dev/null; then
    echo "OK   $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL $label (argv log missing pattern '$pattern')"
    [ -f "$proj/.runner-argv.log" ] && echo "     argv: $(cat "$proj/.runner-argv.log")"
    FAIL=$((FAIL + 1))
  fi
}

assert_no_argv_log() {
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

# Skip cgroup-dependent scenarios if host preconditions are missing.
HOST_HAS_CGROUP=0
if command -v systemd-run >/dev/null 2>&1 && \
   systemctl --user is-active default.target >/dev/null 2>&1; then
  HOST_HAS_CGROUP=1
fi

# ----------------------------------------------------------------------------
# Scenario 1 — Cold-cache pytest project (no .pytest_cache/) → bounded full
# suite, runner exits 0, hook exits 0.
# ----------------------------------------------------------------------------
clear_state
PROJ=$(setup_project s1)
rm -rf "$PROJ/.pytest_cache"
stub_pytest "$PROJ" 0 ""
set_source_flag "s1"
run_hook "$PROJ" "s1"
assert_exit 0 "[1] cold-cache pytest → bounded full suite, exit 0"
# Falls through to non-pytest branch (since no cache) — runner is still pytest,
# so argv should contain `pytest` but NOT `--last-failed`.
assert_argv_contains "$PROJ" " -m pytest " "[1] runner argv invokes pytest"
if grep -qF -- "--last-failed" "$PROJ/.runner-argv.log" 2>/dev/null; then
  echo "FAIL [1] cold-cache should not use --last-failed"
  FAIL=$((FAIL + 1))
else
  echo "OK   [1] cold-cache skipped --last-failed branch"
  PASS=$((PASS + 1))
fi
assert_log_contains "$PROJ" "Tests passed" "[1] log records pass"

# ----------------------------------------------------------------------------
# Scenario 2 — pytest exit 5 (no tests collected) → fail open.
# ----------------------------------------------------------------------------
clear_state
PROJ=$(setup_project s2)
stub_pytest "$PROJ" 5 ""
set_source_flag "s2"
run_hook "$PROJ" "s2"
assert_exit 0 "[2] pytest exit 5 (no tests) → fail open"
assert_log_contains "$PROJ" "No tests collected (pytest exit 5)" "[2] log records exit-5 path"

# ----------------------------------------------------------------------------
# Scenario 3 — --last-failed clean (suite was clean) → "no tests ran" detected,
# allow stop.
# ----------------------------------------------------------------------------
clear_state
PROJ=$(setup_project s3)
stub_pytest "$PROJ" 0 "============== no tests ran in 0.01s =============="
set_source_flag "s3"
run_hook "$PROJ" "s3"
assert_exit 0 "[3] --last-failed clean (no tests ran) → exit 0"
assert_log_contains "$PROJ" "No previously-failed tests" "[3] log records 'no tests ran' branch"
assert_argv_contains "$PROJ" "--last-failed" "[3] runner argv carries --last-failed"

# ----------------------------------------------------------------------------
# Scenario 4 — --last-failed failing → block (exit 2), stderr carries tail.
# ----------------------------------------------------------------------------
clear_state
PROJ=$(setup_project s4)
stub_pytest "$PROJ" 1 "FAILED tests/test_x.py::test_foo - AssertionError"
set_source_flag "s4"
run_hook "$PROJ" "s4"
assert_exit 2 "[4] --last-failed failing → exit 2 (block)"
if grep -qF -- "Test suite failed" <<< "$HOOK_OUT"; then
  echo "OK   [4] block emits 'Test suite failed' header on stderr"
  PASS=$((PASS + 1))
else
  echo "FAIL [4] block did not emit 'Test suite failed' header"
  FAIL=$((FAIL + 1))
fi
assert_log_contains "$PROJ" "Last-failed tests still failing (exit 1)" "[4] log records block branch"

# ----------------------------------------------------------------------------
# Scenario 5 — Collection blow-up → cgroup MemoryMax + MemorySwapMax=0 →
# exit 137 → fail open with budget log line.
# Faults a 256 MB allocation under DHX_TEST_GATE_MEM=128M; SwapMax=0 is what
# makes this deterministic on hosts with swap (verified in design memo).
# ----------------------------------------------------------------------------
if [ "$HOST_HAS_CGROUP" -eq 1 ]; then
  clear_state
  PROJ=$(setup_project s5)
  cat > "$PROJ/.venv/bin/python" <<EOF
#!/usr/bin/env bash
printf '%q ' "\$0" "\$@" >> "$PROJ/.runner-argv.log"
printf '\n' >> "$PROJ/.runner-argv.log"
case "\$*" in
  *"--version"*) echo "pytest 0.0.0 (probe stub)"; exit 0 ;;
esac
exec /usr/bin/python3 -c '
data = bytearray(256 * 1024 * 1024)
for i in range(0, len(data), 4096):
    data[i] = 1
'
EOF
  chmod +x "$PROJ/.venv/bin/python"
  set_source_flag "s5"
  run_hook "$PROJ" "s5" false "DHX_TEST_GATE_MEM=64M"
  # Fail-open path: 137 (cgroup OOM SIGKILL).
  assert_exit 0 "[5] cgroup OOM (exit 137) → fail open"
  assert_log_contains "$PROJ" "exceeded resource budget" "[5] log records resource-budget fail-open"
  assert_log_contains "$PROJ" "mem=64M" "[5] log cites the active memory cap"
else
  echo "SKIP [5] cgroup OOM (host lacks systemd-run + active user-systemd)"
fi

# ----------------------------------------------------------------------------
# Scenario 6 — Runtime cap → RuntimeMaxSec → SIGTERM/exit 143 → fail open.
# Stub sleeps for 30 s with DHX_TEST_GATE_RUNTIME=2 so the systemd-native
# runtime ceiling fires deterministically inside the probe budget.
# ----------------------------------------------------------------------------
if [ "$HOST_HAS_CGROUP" -eq 1 ]; then
  clear_state
  PROJ=$(setup_project s6)
  cat > "$PROJ/.venv/bin/python" <<EOF
#!/usr/bin/env bash
printf '%q ' "\$0" "\$@" >> "$PROJ/.runner-argv.log"
printf '\n' >> "$PROJ/.runner-argv.log"
case "\$*" in
  *"--version"*) echo "pytest 0.0.0 (probe stub)"; exit 0 ;;
esac
exec /usr/bin/python3 -c 'import time; time.sleep(30)'
EOF
  chmod +x "$PROJ/.venv/bin/python"
  set_source_flag "s6"
  run_hook "$PROJ" "s6" false "DHX_TEST_GATE_RUNTIME=2"
  assert_exit 0 "[6] RuntimeMaxSec (exit 143) → fail open"
  assert_log_contains "$PROJ" "exceeded resource budget" "[6] log records resource-budget fail-open"
  assert_log_contains "$PROJ" "runtime=2s" "[6] log cites the active runtime cap"
else
  echo "SKIP [6] RuntimeMaxSec (host lacks systemd-run + active user-systemd)"
fi

# ----------------------------------------------------------------------------
# Scenario 7 — .claude/skip-test-gate sentinel → exit 0, runner not invoked.
# ----------------------------------------------------------------------------
clear_state
PROJ=$(setup_project s7)
stub_pytest "$PROJ" 0 ""
touch "$PROJ/.claude/skip-test-gate"
set_source_flag "s7"
run_hook "$PROJ" "s7"
assert_exit 0 "[7] sentinel .claude/skip-test-gate → exit 0"
assert_no_argv_log "$PROJ" "[7] sentinel skipped runner invocation"
assert_log_contains "$PROJ" "skip-test-gate sentinel present" "[7] log records sentinel branch"

# ----------------------------------------------------------------------------
# Scenario 8 — .claude/test-gate.json {"enabled": false} → exit 0, runner not
# invoked.
# ----------------------------------------------------------------------------
clear_state
PROJ=$(setup_project s8)
stub_pytest "$PROJ" 0 ""
echo '{"enabled": false}' > "$PROJ/.claude/test-gate.json"
set_source_flag "s8"
run_hook "$PROJ" "s8"
assert_exit 0 "[8] test-gate.json enabled=false → exit 0"
assert_no_argv_log "$PROJ" "[8] enabled=false skipped runner invocation"
assert_log_contains "$PROJ" ".enabled=false" "[8] log records enabled=false branch"

# ----------------------------------------------------------------------------
# Scenario 9 — .claude/test-gate.json target → runner argv last positional is
# the configured target. Sub-assertion: spaces in target survive the array
# refactor (no eval).
# ----------------------------------------------------------------------------
clear_state
PROJ=$(setup_project s9)
stub_pytest "$PROJ" 0 "no tests ran"
echo '{"target": "tests/test unit"}' > "$PROJ/.claude/test-gate.json"
set_source_flag "s9"
run_hook "$PROJ" "s9"
assert_exit 0 "[9] test-gate.json target → exit 0"
# The stub records argv via printf %q; a quoted space-bearing token confirms
# the target travelled as one argv element rather than getting word-split.
if grep -qE "tests/test\\\\? unit|'tests/test unit'" "$PROJ/.runner-argv.log" 2>/dev/null; then
  echo "OK   [9] target with space arrives as single argv element"
  PASS=$((PASS + 1))
else
  echo "FAIL [9] target with space did not survive the array refactor"
  echo "     argv: $(cat "$PROJ/.runner-argv.log" 2>/dev/null)"
  FAIL=$((FAIL + 1))
fi

# ----------------------------------------------------------------------------
# Scenario 10 — DHX_SKIP_TEST_GATE=1 env → exit 0, runner not invoked.
# ----------------------------------------------------------------------------
clear_state
PROJ=$(setup_project s10)
stub_pytest "$PROJ" 0 ""
set_source_flag "s10"
run_hook "$PROJ" "s10" false "DHX_SKIP_TEST_GATE=1"
assert_exit 0 "[10] DHX_SKIP_TEST_GATE=1 → exit 0"
assert_no_argv_log "$PROJ" "[10] env opt-out skipped runner invocation"
assert_log_contains "$PROJ" "DHX_SKIP_TEST_GATE=1" "[10] log records env opt-out branch"

# ----------------------------------------------------------------------------
# Scenario 11 — Host without systemd-run on PATH → CGROUP_PREFIX=() → bare
# invocation. Use a controlled bin dir that mirrors host tools but omits
# systemd-run; assert the gate's `Running:` log line does NOT start with
# `systemd-run`.
# ----------------------------------------------------------------------------
clear_state
PROJ=$(setup_project s11)
stub_pytest "$PROJ" 0 "no tests ran"
set_source_flag "s11"
SHIM_PATH=$(build_path_without_systemd_run)
run_hook "$PROJ" "s11" false "PATH=$SHIM_PATH"
assert_exit 0 "[11] no systemd-run on PATH → exit 0"
# Runner argv recorded by the stub starts with the python path (no cgroup
# prefix in the actual runner invocation). The gate's log line shows the
# full composed argv — assert the bare shape there.
LOG_LINE=$(grep "Running:" "$PROJ/.claude/hooks/logs/test-gate.log" | tail -n 1)
if grep -qE "Running: systemd-run" <<< "$LOG_LINE"; then
  echo "FAIL [11] cgroup prefix incorrectly applied without systemd-run on PATH"
  echo "     log: $LOG_LINE"
  FAIL=$((FAIL + 1))
else
  echo "OK   [11] gate composed bare argv (no systemd-run prefix)"
  PASS=$((PASS + 1))
fi

# ----------------------------------------------------------------------------
# Scenario 12 — Host with systemd-run but no active user-systemd → bare
# invocation. Stubs systemctl to exit non-zero on the `--user is-active`
# probe; real systemd-run stays on PATH. Verifies the AND-chain breaks on
# the second conjunct without needing to actually stop user@.service.
# ----------------------------------------------------------------------------
clear_state
PROJ=$(setup_project s12)
stub_pytest "$PROJ" 0 "no tests ran"
set_source_flag "s12"
INACTIVE_BIN=$(build_path_with_inactive_user_systemd)
run_hook "$PROJ" "s12" false "PATH=$INACTIVE_BIN:$PATH"
assert_exit 0 "[12] inactive user-systemd → exit 0"
LOG_LINE=$(grep "Running:" "$PROJ/.claude/hooks/logs/test-gate.log" | tail -n 1)
if grep -qE "Running: systemd-run" <<< "$LOG_LINE"; then
  echo "FAIL [12] cgroup prefix applied even with inactive user-systemd"
  echo "     log: $LOG_LINE"
  FAIL=$((FAIL + 1))
else
  echo "OK   [12] gate composed bare argv (systemctl AND-conjunct broke)"
  PASS=$((PASS + 1))
fi

# ----------------------------------------------------------------------------
# Scenario 13 — HP-028 SIGPIPE regression: stub emits >64 KiB of LF_OUTPUT
# ending with "no tests ran". The here-string `<<<` form preserves detection
# of the marker even when the variable exceeds the pipe buffer. Asserts the
# gate logged the "no tests ran" branch (not a false-block).
# ----------------------------------------------------------------------------
clear_state
PROJ=$(setup_project s13)
# Build a body >64 KiB followed by the marker on the last line.
LONG_BODY=$(python3 -c '
n = 70 * 1024  # ~70 KiB of filler
import string
print(("a" * 80 + "\n") * (n // 81), end="")
print("============== no tests ran in 0.01s ==============")
')
stub_pytest "$PROJ" 0 "$LONG_BODY"
set_source_flag "s13"
run_hook "$PROJ" "s13"
assert_exit 0 "[13] >64 KiB LF_OUTPUT + 'no tests ran' (HP-028 here-string regression)"
assert_log_contains "$PROJ" "No previously-failed tests" "[13] here-string detected marker past pipe-buffer threshold"

# ----------------------------------------------------------------------------
# Scenario 14 — Dual-guard:
#   14a. stop_hook_active=true → primary guard, exit 0, runner not invoked.
#   14b. counter ≥ 2 (file-based fallback) → secondary guard, exit 0, runner
#        not invoked on the re-fire.
# ----------------------------------------------------------------------------
clear_state
PROJ=$(setup_project s14a)
stub_pytest "$PROJ" 0 ""
set_source_flag "s14a"
run_hook "$PROJ" "s14a" true   # stop_hook_active=true
assert_exit 0 "[14a] stop_hook_active=true → primary guard exit 0"
assert_no_argv_log "$PROJ" "[14a] primary guard skipped runner invocation"
assert_log_contains "$PROJ" "stop_hook_active=true" "[14a] log records primary-guard branch"

clear_state
PROJ=$(setup_project s14b)
stub_pytest "$PROJ" 1 "FAILED"
set_source_flag "s14b"
# First fire: counter increments to 1, source flag triggers runner, runner
# exits 1 → block. Re-set source flag because the gate consumes it.
run_hook "$PROJ" "s14b" false
[ "$HOOK_EXIT" -eq 2 ] || { echo "FAIL [14b] precondition: first fire should block"; FAIL=$((FAIL + 1)); }
# Counter is now at 1. Second fire: counter becomes 2 → secondary guard fires.
set_source_flag "s14b"
rm -f "$PROJ/.runner-argv.log"   # Clear so we can assert no further invocation.
run_hook "$PROJ" "s14b" false
assert_exit 0 "[14b] counter ≥ 2 → secondary guard exit 0"
assert_no_argv_log "$PROJ" "[14b] secondary guard skipped runner invocation"
assert_log_contains "$PROJ" "Counter=2 ≥ 2" "[14b] log records secondary-guard branch"

# ----------------------------------------------------------------------------
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
