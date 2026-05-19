#!/usr/bin/env bash
# probe-milestone-close-blocker-pretooluse.sh
#
# Regression probe for dhx/dhx-milestone-close-blocker-pretooluse.sh (Phase 13
# MC-BLOCKER Shape B PreToolUse:Skill hook). Mirrors the Plan 13-01 probe shape
# adapted for PreToolUse stdin schema (tool_input.skill=gsd-complete-milestone)
# and exit-2-with-stderr block semantics (HP-009 PreToolUse path).
#
# Scenarios (6 fire-state × silent-state × invariant):
#   POSITIVE (expect exit 2 + 5-line MILESTONE-CLOSE BLOCKERS stderr):
#     [pre.Aa]   tool_input.skill=gsd-complete-milestone + STATE.md=verifying
#                + 1 BACKLOG row → exit 2, MC_BACKLOG_COUNT=1
#     [pre.Ab]   skill match + STATE.md=milestone-shipped + 2 todos → exit 2,
#                MC_TODO_COUNT=2 (D-04 cascade)
#     [pre.dual] skill match + verifying + dual-form BACKLOG headers → exit 2,
#                count=2 (D-08 dual-form awk regression)
#   NEGATIVE (expect silent exit 0 + zero stderr per D-11):
#     [pre.skip.skill] tool_input.skill=some-other-skill + verifying + items
#                      → silent (Skill-identifier gate)
#     [pre.Ac]   skill match + status=planning + items → silent (trigger gate)
#     [pre.ii]   skill match + no STATE.md → silent (missing-file fast-fail)
#
# SAFE_FOR_LIVE: yes
#   - HOME=$TMP fixture isolation per scenario (mirrors probe-milestone-close-blocker-check.sh)
#   - mktemp -d + trap 'rm -rf $TMP' EXIT
#   - no live ~/.claude, ~/.cache/dhx, or git state touched
#
# Backs:
#   - docs/decisions.md — 2026-05-19 MC-BLOCKER-08 H1-branch ship row
#   - docs/hook-patterns.md — HP-009, HP-010, HP-017, HP-030 (declared by hook header)
#
# Run: bash tests/probes/probe-milestone-close-blocker-pretooluse.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$REPO_ROOT/dhx/dhx-milestone-close-blocker-pretooluse.sh"

if [ ! -r "$HOOK" ]; then
  echo "FAIL hook not readable: $HOOK"
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL jq required but not installed"
  exit 1
fi
for cmd in bash awk find grep; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "FAIL $cmd required but not installed"
    exit 1
  fi
done

TMP=$(mktemp -d /tmp/probe-mc-blocker-pre.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

# --- Helpers ---

# setup_fixture <scenario_name> <state_status> [backlog_content]
# Builds $TMP/<scenario>/.planning/{STATE.md,BACKLOG.md,todos/pending/}
setup_fixture() {
  local scenario="$1"
  local status="$2"
  local backlog_content="${3:-}"
  local fdir="$TMP/$scenario/.planning"
  mkdir -p "$fdir/todos/pending" "$fdir/todos/done" "$fdir/todos/archived"
  cat > "$fdir/STATE.md" <<EOF
---
status: $status
milestone: v1.3
---

# State
content
EOF
  if [ -n "$backlog_content" ]; then
    printf '%s' "$backlog_content" > "$fdir/BACKLOG.md"
  fi
  echo "$fdir"
}

# run_hook_with_input <fixture_dir> <skill_value>
# Builds PreToolUse:Skill stdin payload + invokes hook. Captures stdout/stderr/exit.
run_hook_with_input() {
  local fixture="$1"
  local skill="${2:-gsd-complete-milestone}"
  local cwd="${fixture%/.planning}"
  local payload
  payload=$(jq -n --arg cwd "$cwd" --arg skill "$skill" \
                  '{cwd:$cwd, tool_input:{skill:$skill}, hook_event_name:"PreToolUse"}')
  local stdout_file stderr_file
  stdout_file=$(mktemp "$TMP/stdout.XXXX")
  stderr_file=$(mktemp "$TMP/stderr.XXXX")
  set +e
  echo "$payload" | HOME="$cwd" bash "$HOOK" >"$stdout_file" 2>"$stderr_file"
  EXIT_CAP=$?
  set -e 2>/dev/null || true
  STDOUT_CAP=$(cat "$stdout_file")
  STDERR_CAP=$(cat "$stderr_file")
  rm -f "$stdout_file" "$stderr_file"
}

# Block-path assertion (HP-009 PreToolUse): exit code == 2 AND stderr contains
# the 5-line MILESTONE-CLOSE BLOCKERS message AND stdout is empty.
assert_block_pretooluse() {
  local label="$1"
  if [ "$EXIT_CAP" -eq 2 ] \
     && echo "$STDERR_CAP" | grep -qF "MILESTONE-CLOSE BLOCKERS" \
     && echo "$STDERR_CAP" | grep -qF "/dhx:audit" \
     && [ -z "$STDOUT_CAP" ]; then
    echo "[PASS] $label"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] $label — expected exit 2 + 5-line stderr, got:"
    echo "       stdout: $(printf '%s' "$STDOUT_CAP" | head -c 200)"
    echo "       stderr: $(printf '%s' "$STDERR_CAP" | head -c 300)"
    echo "       exit:   $EXIT_CAP"
    FAIL=$((FAIL + 1))
  fi
}

assert_stderr_contains() {
  local label="$1" needle="$2"
  if echo "$STDERR_CAP" | grep -qF "$needle"; then
    echo "[PASS] $label (stderr contains: $needle)"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] $label — stderr did not contain: $needle"
    echo "       stderr: $(printf '%s' "$STDERR_CAP" | head -c 300)"
    FAIL=$((FAIL + 1))
  fi
}

# D-11 silent-stderr invariant: stdout AND stderr both empty, exit 0.
assert_silent_no_stderr() {
  local label="$1"
  local stderr_bytes
  stderr_bytes=$(printf '%s' "$STDERR_CAP" | wc -c)
  if [ -z "$STDOUT_CAP" ] && [ "$stderr_bytes" -eq 0 ] && [ "$EXIT_CAP" -eq 0 ]; then
    echo "[PASS] $label (silent: stdout=0, stderr=0, exit=0)"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] $label — expected silent, got:"
    echo "       stdout: $(printf '%s' "$STDOUT_CAP" | head -c 200)"
    echo "       stderr: $(printf '%s' "$STDERR_CAP" | head -c 200)"
    echo "       exit:   $EXIT_CAP"
    FAIL=$((FAIL + 1))
  fi
}

# Standard fixture content blocks
BACKLOG_1_ROW=$(cat <<'EOF'
# Backlog

## Milestone Close — v1.3
| [open] | playwright-uat-flake | reason text |

## Some Other Section
| [open] | unrelated | other |
EOF
)

BACKLOG_DUAL_FORM=$(cat <<'EOF'
# Backlog

## Milestone Close
| [open] | bare-form-row | reason |

## Milestone Close — v1.3
| [open] | em-dash-form-row | reason |

## Other
| [open] | unrelated | x |
EOF
)

# --- [pre.Aa]: skill match + verifying + 1 BACKLOG row → exit 2 ---
FIX_AA=$(setup_fixture "pre_Aa" "verifying" "$BACKLOG_1_ROW")
run_hook_with_input "$FIX_AA"
assert_block_pretooluse "[pre.Aa] skill match + verifying + 1 BACKLOG row → exit 2"
assert_stderr_contains "[pre.Aa] stderr names 1 in BACKLOG.md" "1 in BACKLOG.md"
assert_stderr_contains "[pre.Aa] stderr names 0 in .planning/todos/pending/" "0 in .planning/todos/pending/"

# --- [pre.Ab]: skill match + milestone-shipped + 2 todos → exit 2 ---
FIX_AB=$(setup_fixture "pre_Ab" "milestone-shipped")
cat > "$FIX_AB/todos/pending/todo-a.md" <<'EOF'
---
urgency: milestone-close
---
content a
EOF
cat > "$FIX_AB/todos/pending/todo-b.md" <<'EOF'
---
urgency: milestone-close
status: open
---
content b
EOF
run_hook_with_input "$FIX_AB"
assert_block_pretooluse "[pre.Ab] milestone-shipped + 2 todos → exit 2 (D-04 cascade)"
assert_stderr_contains "[pre.Ab] stderr names 2 in .planning/todos/pending/" "2 in .planning/todos/pending/"

# --- [pre.dual]: skill match + verifying + dual-form BACKLOG → count=2 ---
FIX_DUAL=$(setup_fixture "pre_dual" "verifying" "$BACKLOG_DUAL_FORM")
run_hook_with_input "$FIX_DUAL"
assert_block_pretooluse "[pre.dual] dual-form awk regression → exit 2 (D-08)"
assert_stderr_contains "[pre.dual] stderr names 2 in BACKLOG.md (dual-form awk)" "2 in BACKLOG.md"

# --- [pre.skip.skill]: wrong skill identifier → silent (Skill-identifier gate) ---
FIX_SKIP=$(setup_fixture "pre_skip" "verifying" "$BACKLOG_1_ROW")
cat > "$FIX_SKIP/todos/pending/todo-1.md" <<'EOF'
---
urgency: milestone-close
---
EOF
run_hook_with_input "$FIX_SKIP" "gsd-help"
assert_silent_no_stderr "[pre.skip.skill] wrong skill identifier → silent (gate)"

# --- [pre.Ac]: skill match + status=planning + items → silent (trigger gate) ---
FIX_AC=$(setup_fixture "pre_Ac" "planning" "$BACKLOG_1_ROW")
cat > "$FIX_AC/todos/pending/todo-1.md" <<'EOF'
---
urgency: milestone-close
---
EOF
run_hook_with_input "$FIX_AC"
assert_silent_no_stderr "[pre.Ac] planning + items → silent (trigger gate)"

# --- [pre.ii]: skill match + no STATE.md → silent (missing-file fast-fail) ---
FIX_II_DIR="$TMP/pre_ii/.planning"
mkdir -p "$FIX_II_DIR/todos/pending"
# Deliberately do not create STATE.md
run_hook_with_input "$FIX_II_DIR"
assert_silent_no_stderr "[pre.ii] missing STATE.md → silent"

# --- Summary ---
echo
echo "Total: $PASS pass / $FAIL fail"
[ "$FAIL" -eq 0 ]
