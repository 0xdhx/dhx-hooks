#!/usr/bin/env bash
# dhx-test-gate.sh — Stop hook
# Patterns: HP-001, HP-002, HP-009, HP-020, HP-028
# Blocks task completion if tests fail. Dual-guard prevents infinite loops.
#
# Cgroup wrap (2026-05-03): when systemd-run + active user@.service are
# present, the test runner is wrapped in `systemd-run --user --scope` with
# MemoryMax + MemorySwapMax=0 (cgroup OOM SIGKILL → exit 137) and
# RuntimeMaxSec (SIGTERM at runtime cap → exit 143). Both fail open via the
# exit-code cascade so resource-exhausted gates don't block Stop. Falls back
# to bare invocation when host preconditions are absent. Plugin manifest's
# timeout: 300 stays as defense-in-depth.
#
# Per-project config: .claude/test-gate.json (all keys optional):
#   { "enabled": true,
#     "target": "tests/test_unit",
#     "memory_max": "4G",
#     "runtime_max_sec": 60 }
#
# Opt-out cascade (highest precedence first):
#   1. DHX_SKIP_TEST_GATE=1 env
#   2. .claude/skip-test-gate sentinel
#   3. .claude/test-gate.json {"enabled": false}
#
# Phase-aware skip (post-source-flag, pre-runner): defers the gate when the
# project's .planning/STATE.md shows mid-execute AND a HEAD-reachable PLAN.md
# contracts intentional RED commits AND HEAD is not the GREEN-flip commit.
# Fail-soft: any check error → run the gate normally.
#
# Guard 1: stop_hook_active boolean (official API — true on second+ firing)
# Guard 2: file-based counter keyed by session_id (handles edge cases where
#          stop_hook_active resets unexpectedly: compaction, crashes, #9602)
#
# Companion: dhx-source-write-flag.sh (PostToolUse) sets a dirty flag when
# source files are written. No flag = no source changes = skip tests.
#
# Test runner detection: 9-step cascade. Config files → project type
# indicators → ambient tools → generic fallbacks. Fails open if no runner
# found. Produces a TEST_RUNNER_ARGV array (no `eval`) that run_runner()
# composes with the cgroup prefix + optional target + extra args.

set -uo pipefail

# --- Logging (optional — only if project has .claude/hooks/logs/) ---
LOG_DIR="${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/logs"
if [ -d "$LOG_DIR" ]; then
  LOG_FILE="$LOG_DIR/test-gate.log"
  log() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $1" >> "$LOG_FILE"; }
else
  log() { :; }
fi

# --- Resolve Python (venv-aware, cross-platform) ---
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
if [ -x "$PROJECT_DIR/.venv/Scripts/python.exe" ]; then
  PYTHON="$PROJECT_DIR/.venv/Scripts/python.exe"
elif [ -x "$PROJECT_DIR/.venv/bin/python" ]; then
  PYTHON="$PROJECT_DIR/.venv/bin/python"
else
  PYTHON="python"
fi

# --- Parse input ---
INPUT=$(cat)

if ! command -v jq &>/dev/null; then
  log "WARN: jq not found, allowing stop (fail open)"
  exit 0
fi

STOP_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')

# --- Temp directory (Windows-portable) ---
_TMPDIR="${TMPDIR:-${TEMP:-/tmp}}"
COUNTER_FILE="$_TMPDIR/claude-stop-${SESSION_ID}.count"

log "Stop hook fired. session=$SESSION_ID stop_hook_active=$STOP_ACTIVE"

# --- Opt-out cascade (env → sentinel → JSON config) ---
if [ "${DHX_SKIP_TEST_GATE:-}" = "1" ]; then
  log "DHX_SKIP_TEST_GATE=1 → allowing stop"
  rm -f "$COUNTER_FILE"
  exit 0
fi

if [ -f "$PROJECT_DIR/.claude/skip-test-gate" ]; then
  log ".claude/skip-test-gate sentinel present → allowing stop"
  rm -f "$COUNTER_FILE"
  exit 0
fi

# --- Per-project config (target, memory cap, runtime cap) ---
TEST_TARGET=""
TEST_BUDGET_MEM="${DHX_TEST_GATE_MEM:-4G}"
TEST_BUDGET_TIME="${DHX_TEST_GATE_RUNTIME:-60}"
CFG="$PROJECT_DIR/.claude/test-gate.json"
if [ -f "$CFG" ]; then
  # NOTE: read `.enabled` directly — `jq '.enabled // true'` is wrong because
  # jq's `//` operator treats `false` as null and falls through to the default.
  # We need to distinguish "absent" (default true) from "explicitly false."
  CFG_ENABLED=$(jq -r '.enabled' "$CFG" 2>/dev/null)
  if [ "$CFG_ENABLED" = "false" ]; then
    log ".claude/test-gate.json .enabled=false → allowing stop"
    rm -f "$COUNTER_FILE"
    exit 0
  fi
  CFG_TARGET=$(jq -r '.target // ""' "$CFG" 2>/dev/null)
  CFG_MEM=$(jq -r --arg fb "$TEST_BUDGET_MEM" '.memory_max // $fb' "$CFG" 2>/dev/null)
  CFG_TIME=$(jq -r --argjson fb "$TEST_BUDGET_TIME" '.runtime_max_sec // $fb' "$CFG" 2>/dev/null)
  [ -n "$CFG_TARGET" ] && TEST_TARGET="$CFG_TARGET"
  [ -n "$CFG_MEM" ]    && TEST_BUDGET_MEM="$CFG_MEM"
  [ -n "$CFG_TIME" ]   && TEST_BUDGET_TIME="$CFG_TIME"
fi

# --- Guard 1: official boolean ---
if [ "$STOP_ACTIVE" = "true" ]; then
  log "stop_hook_active=true → allowing stop (primary guard)"
  rm -f "$COUNTER_FILE"
  exit 0
fi

# --- Guard 2: file-based counter ---
COUNT=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
COUNT=$((COUNT + 1))
echo "$COUNT" > "$COUNTER_FILE"

if [ "$COUNT" -ge 2 ]; then
  log "Counter=$COUNT ≥ 2 → allowing stop (secondary guard)"
  rm -f "$COUNTER_FILE"
  exit 0
fi

# --- Skip if no source files written this turn ---
SOURCE_FLAG="$_TMPDIR/claude-source-dirty-${SESSION_ID}.flag"

if [ ! -f "$SOURCE_FLAG" ]; then
  log "No source files written this turn → skipping tests"
  rm -f "$COUNTER_FILE"
  exit 0
fi

# Flag exists → source was written. Consume it.
rm -f "$SOURCE_FLAG"
log "Source files written this turn → running tests"

# --- Phase-aware skip: defer gate during intentional-RED phase windows ---
# When a multi-plan phase is mid-execute and a HEAD-reachable PLAN.md
# contracts intentional RED commits (D-05(v) bisectable RED→GREEN), the Stop
# hook fires between Wave-1 RED and Wave-2 GREEN-flip and reports
# RED-by-design tests as failures. Skip when ALL THREE conditions hold; the
# user's `/dhx:test {phase}` is the structured verification path. Defense-in-
# depth alongside any plan-side `it.fails()`-style convention.
#
# Fail-soft: any check that errors → don't skip → run the gate normally. The
# skip path must NOT be more trusted than the alarm path.
PHASE_SKIP_REASON=""
PHASE_SKIP_PHASE=""
STATE_FILE="$PROJECT_DIR/.planning/STATE.md"
if [ -f "$STATE_FILE" ] && \
   grep -qiE '^status:[[:space:]]*executing' "$STATE_FILE" 2>/dev/null; then
  # HEAD-reachable PLAN.md walk. `git log -50` narrows search; sort -u dedupes
  # plans modified across multiple commits. Any pipeline error → empty list.
  PLAN_FILES=$(cd "$PROJECT_DIR" 2>/dev/null && \
    git log -50 --pretty=format: --name-only 2>/dev/null \
      | grep -E '^\.planning/phases/.+/.+-PLAN\.md$' | sort -u || true)
  if [ -n "$PLAN_FILES" ]; then
    while IFS= read -r plan; do
      [ -z "$plan" ] && continue
      plan_content=$(cd "$PROJECT_DIR" 2>/dev/null && git show "HEAD:$plan" 2>/dev/null) || continue
      if grep -qE '(RED|D-05\(v\)|intentional.*failure|expected.*failure|bisectable)' <<< "$plan_content" 2>/dev/null; then
        PHASE_SKIP_PHASE=$(echo "$plan" | sed -nE 's|.*/phases/([^/]+)/.*|\1|p')
        PHASE_SKIP_REASON="phase contracts intentional RED at $plan"
        break
      fi
    done <<< "$PLAN_FILES"
  fi
  # Override: if HEAD's commit subject names GREEN/flip, the user wants the
  # gate to run and verify the flip — clear the skip reason.
  if [ -n "$PHASE_SKIP_REASON" ]; then
    HEAD_MSG=$(cd "$PROJECT_DIR" 2>/dev/null && git log -1 --format=%s HEAD 2>/dev/null) || HEAD_MSG=""
    if grep -qiE '\b(green|flip)\b|\(GREEN\)' <<< "$HEAD_MSG" 2>/dev/null; then
      log "Phase-aware: HEAD subject names GREEN/flip ('$HEAD_MSG') → running gate"
      PHASE_SKIP_REASON=""
    fi
  fi
fi

if [ -n "$PHASE_SKIP_REASON" ]; then
  PHASE_DISPLAY="${PHASE_SKIP_PHASE:-the active phase}"
  SKIP_MSG="[stop-hook] Skipping test-gate: $PHASE_SKIP_REASON. Re-run /dhx:test $PHASE_DISPLAY for verification."
  log "Phase-aware skip: $PHASE_SKIP_REASON (phase=$PHASE_DISPLAY)"
  # Stop schema rejects hookSpecificOutput (validator allows it only for
  # Pre/PostToolUse/UserPromptSubmit/PostToolBatch). systemMessage is the
  # universal top-level advisory channel and matches the non-blocking,
  # exit-0 intent of this skip path.
  jq -nc --arg msg "$SKIP_MSG" '{systemMessage:$msg}'
  rm -f "$COUNTER_FILE"
  exit 0
fi

# --- Detect test runner (9-step cascade → TEST_RUNNER_ARGV array) ---
cd "$PROJECT_DIR" || exit 0

IS_PYTEST=0
TEST_RUNNER_ARGV=()
if [ -f "pytest.ini" ] || [ -f "pytest.toml" ] || [ -f ".pytest.toml" ]; then
  TEST_RUNNER_ARGV=("$PYTHON" -m pytest --tb=short -q)
  IS_PYTEST=1
elif [ -f "pyproject.toml" ] && grep -qE '^\[tool\.pytest' pyproject.toml 2>/dev/null; then
  TEST_RUNNER_ARGV=("$PYTHON" -m pytest --tb=short -q)
  IS_PYTEST=1
elif [ -f "setup.cfg" ] && grep -q '^\[tool:pytest\]' setup.cfg 2>/dev/null; then
  TEST_RUNNER_ARGV=("$PYTHON" -m pytest --tb=short -q)
  IS_PYTEST=1
elif [ -f "Cargo.toml" ]; then
  TEST_RUNNER_ARGV=(cargo test)
elif [ -f "go.mod" ]; then
  TEST_RUNNER_ARGV=(go test ./...)
elif [ -f "package.json" ] && grep -q '"test"' package.json 2>/dev/null && \
     ! grep -q 'no test specified' package.json 2>/dev/null; then
  TEST_RUNNER_ARGV=(npm test)
elif "$PYTHON" -m pytest --version &>/dev/null 2>&1; then
  TEST_RUNNER_ARGV=("$PYTHON" -m pytest --tb=short -q)
  IS_PYTEST=1
elif ls tests/test_*.py &>/dev/null 2>&1 || ls test_*.py &>/dev/null 2>&1; then
  TEST_RUNNER_ARGV=("$PYTHON" -m unittest discover -v)
elif [ -f "Makefile" ] && grep -q '^test:' Makefile 2>/dev/null; then
  TEST_RUNNER_ARGV=(make test)
else
  log "No test runner detected → allowing stop (fail open)"
  rm -f "$COUNTER_FILE"
  exit 0
fi

# --- Cgroup wrap factory ---
# MemoryMax + MemorySwapMax=0 → SIGKILL/exit 137 on overrun (MemoryMax alone
# is advisory on hosts with swap available — verified empirically on this
# WSL2 host; see reports/2026-05-03-test-gate-collection-cost.md). RuntimeMaxSec
# is the systemd-native runtime ceiling (NOT TimeoutStopSec, which is the
# SIGTERM→SIGKILL grace period after stop is requested) — fires at the cap
# with SIGTERM/exit 143. Both 137 and 143 fail open via the exit-code cascade
# below. Empty array on hosts without systemd-run + active user@.service —
# graceful fallback to bare invocation. Outer `timeout` deliberately not
# layered on top: RuntimeMaxSec is the systemd-native bound; double-killing
# would obscure which surface fired. Plugin manifest's `timeout: 300` is the
# defense-in-depth layer for hosts where neither cgroup nor RuntimeMaxSec
# applies.
CGROUP_PREFIX=()
if command -v systemd-run >/dev/null 2>&1 && \
   systemctl --user is-active default.target >/dev/null 2>&1; then
  CGROUP_PREFIX=(
    systemd-run --user --scope --quiet
    -p "MemoryMax=$TEST_BUDGET_MEM"
    -p "MemorySwapMax=0"
    -p "RuntimeMaxSec=${TEST_BUDGET_TIME}s"
    --
  )
fi

# --- Helper: compose argv with cgroup prefix + runner + optional target +
# extra args; invoke directly via "${argv[@]}" — no eval, no string fragility.
run_runner() {
  local extra=("$@")
  local argv=("${CGROUP_PREFIX[@]}" "${TEST_RUNNER_ARGV[@]}")
  if [ -n "$TEST_TARGET" ]; then
    argv+=("$TEST_TARGET")
  fi
  if [ "${#extra[@]}" -gt 0 ]; then
    argv+=("${extra[@]}")
  fi
  log "Running: ${argv[*]}"
  "${argv[@]}" 2>&1
}

# --- pytest --last-failed branch (primary; no dead -x full-suite fallback) ---
if [ "$IS_PYTEST" = "1" ] && [ -d ".pytest_cache" ]; then
  LF_EXIT=0
  LF_OUTPUT=$(run_runner --last-failed --last-failed-no-failures none) || LF_EXIT=$?

  case "$LF_EXIT" in
    0)
      if grep -q "no tests ran" <<< "$LF_OUTPUT"; then
        log "No previously-failed tests (suite was clean) → allowing stop"
      else
        log "Previously-failed tests now pass → allowing stop"
      fi
      rm -f "$COUNTER_FILE"
      exit 0
      ;;
    5)
      log "No tests collected (pytest exit 5) → allowing stop"
      rm -f "$COUNTER_FILE"
      exit 0
      ;;
    137|143|124)
      log "Test runner exceeded resource budget (exit $LF_EXIT, mem=$TEST_BUDGET_MEM, runtime=${TEST_BUDGET_TIME}s) → fail open. Tune via .claude/test-gate.json."
      rm -f "$COUNTER_FILE"
      exit 0
      ;;
    *)
      log "Last-failed tests still failing (exit $LF_EXIT) → blocking stop"
      echo "Test suite failed. Fix these failures before completing:" >&2
      tail -n 60 <<< "$LF_OUTPUT" >&2
      exit 2
      ;;
  esac
fi

# --- Non-pytest fallback OR pytest with no .pytest_cache: bounded full suite ---
TEST_EXIT=0
TEST_OUTPUT=$(run_runner) || TEST_EXIT=$?

case "$TEST_EXIT" in
  0)
    log "Tests passed → allowing stop"
    rm -f "$COUNTER_FILE"
    exit 0
    ;;
  5)
    if [ "$IS_PYTEST" = "1" ]; then
      log "No tests collected (pytest exit 5) → allowing stop"
      rm -f "$COUNTER_FILE"
      exit 0
    fi
    log "Tests FAILED (exit 5) → blocking stop"
    echo "Test suite failed. Fix these failures before completing:" >&2
    tail -n 60 <<< "$TEST_OUTPUT" >&2
    exit 2
    ;;
  137|143|124)
    log "Test runner exceeded resource budget (exit $TEST_EXIT, mem=$TEST_BUDGET_MEM, runtime=${TEST_BUDGET_TIME}s) → fail open. Tune via .claude/test-gate.json."
    rm -f "$COUNTER_FILE"
    exit 0
    ;;
  *)
    log "Tests FAILED (exit $TEST_EXIT) → blocking stop"
    echo "Test suite failed. Fix these failures before completing:" >&2
    tail -n 60 <<< "$TEST_OUTPUT" >&2
    exit 2
    ;;
esac
