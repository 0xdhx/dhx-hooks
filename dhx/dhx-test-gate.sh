#!/usr/bin/env bash
# dhx-test-gate.sh — Stop hook
# Blocks task completion if tests fail. Dual-guard prevents infinite loops.
#
# Guard 1: stop_hook_active boolean (official API — true on second+ firing)
# Guard 2: file-based counter keyed by session_id (handles edge cases where
#          stop_hook_active resets unexpectedly: compaction, crashes, #9602)
#
# Companion: dhx-source-write-flag.sh (PostToolUse) sets a dirty flag when
# source files are written. No flag = no source changes = skip tests.
#
# Test runner detection: 9-step cascade (pytest → unittest → cargo → go →
# npm → make). Fails open if no runner found.

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

# --- Detect test runner (9-step cascade) ---
cd "$PROJECT_DIR" || exit 0

if [ -f "pytest.ini" ] || [ -f "pytest.toml" ] || [ -f ".pytest.toml" ]; then
  TEST_CMD="$PYTHON -m pytest --tb=short -q"
elif [ -f "pyproject.toml" ] && grep -qE '^\[tool\.pytest' pyproject.toml 2>/dev/null; then
  TEST_CMD="$PYTHON -m pytest --tb=short -q"
elif [ -f "setup.cfg" ] && grep -q '^\[tool:pytest\]' setup.cfg 2>/dev/null; then
  TEST_CMD="$PYTHON -m pytest --tb=short -q"
elif $PYTHON -m pytest --version &>/dev/null 2>&1; then
  TEST_CMD="$PYTHON -m pytest --tb=short -q"
elif ls tests/test_*.py &>/dev/null 2>&1 || ls test_*.py &>/dev/null 2>&1; then
  TEST_CMD="$PYTHON -m unittest discover -v"
elif [ -f "Cargo.toml" ]; then
  TEST_CMD="cargo test"
elif [ -f "go.mod" ]; then
  TEST_CMD="go test ./..."
elif [ -f "package.json" ] && grep -q '"test"' package.json 2>/dev/null; then
  TEST_CMD="npm test"
elif [ -f "Makefile" ] && grep -q '^test:' Makefile 2>/dev/null; then
  TEST_CMD="make test"
else
  log "No test runner detected → allowing stop (fail open)"
  rm -f "$COUNTER_FILE"
  exit 0
fi

# --- Optimization: try --last-failed before full suite ---
if [[ "$TEST_CMD" == *"pytest"* ]] && [ -d ".pytest_cache" ]; then
  LF_CMD="$TEST_CMD --last-failed --last-failed-no-failures none"
  log "Trying last-failed first: $LF_CMD"
  LF_EXIT=0
  LF_OUTPUT=$(eval "$LF_CMD" 2>&1) || LF_EXIT=$?

  if [ "$LF_EXIT" -eq 0 ]; then
    if echo "$LF_OUTPUT" | grep -q "no tests ran"; then
      log "No previously-failed tests (suite was clean) → skipping full suite"
      rm -f "$COUNTER_FILE"
      exit 0
    else
      log "Previously-failed tests now pass → allowing stop"
      rm -f "$COUNTER_FILE"
      exit 0
    fi
  else
    log "Last-failed tests still failing (exit $LF_EXIT) → blocking stop"
    TRUNCATED=$(echo "$LF_OUTPUT" | tail -n 60)
    echo "Test suite failed. Fix these failures before completing:
$TRUNCATED" >&2
    exit 2
  fi
fi

# --- Full suite (-x: stop on first failure for faster feedback) ---
FULL_CMD="$TEST_CMD -x"
log "Running: $FULL_CMD"

TEST_EXIT=0
TEST_OUTPUT=$(eval "$FULL_CMD" 2>&1) || TEST_EXIT=$?

if [ "$TEST_EXIT" -eq 0 ]; then
  log "Tests passed → allowing stop"
  rm -f "$COUNTER_FILE"
  exit 0
elif [ "$TEST_EXIT" -eq 5 ] && [[ "$TEST_CMD" == *"pytest"* ]]; then
  # pytest exit 5 = no tests collected. Not a failure — repo has no tests.
  log "No tests collected (pytest exit 5) → allowing stop"
  rm -f "$COUNTER_FILE"
  exit 0
else
  TRUNCATED=$(echo "$TEST_OUTPUT" | tail -n 60)
  log "Tests FAILED (exit $TEST_EXIT) → blocking stop"
  echo "Test suite failed. Fix these failures before completing:
$TRUNCATED" >&2
  exit 2
fi
