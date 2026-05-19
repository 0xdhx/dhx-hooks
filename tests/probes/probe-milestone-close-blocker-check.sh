#!/usr/bin/env bash
# probe-milestone-close-blocker-check.sh
#
# Regression probe for dhx/dhx-milestone-close-blocker-check.sh (Phase 13
# MC-BLOCKER Shape A Stop hook).
#
# Scenarios (10+ fire-state × silent-state × invariant):
#   POSITIVE (expect block JSON):
#     [Aa]    STATE.md status=verifying + 1 row in BACKLOG.md ## Milestone Close
#             + 0 todos → block JSON, MC_BACKLOG_COUNT=1, MC_TODO_COUNT=0
#     [Ab]    STATE.md status=milestone-shipped + 0 BACKLOG rows + 2 todos with
#             urgency: milestone-close → block JSON, MC_TODO_COUNT=2 (D-04 cascade)
#     [Aa+v]  STATE.md status=verifying + 1 row under bare `## Milestone Close`
#             + 1 row under em-dash `## Milestone Close — v1.3` → TOTAL=2
#             (D-08 dual-form pattern)
#   NEGATIVE (expect silent exit + zero stderr per D-11):
#     [Ac]    status=planning + items present in both surfaces → silent
#     [Ad]    status=executing + items present in both surfaces → silent
#     [i]     status=verifying + items + stdin.stop_hook_active=true → silent
#             (HP-002 short-circuit)
#     [ii]    No STATE.md file → silent (missing-file fast-fail)
#     [iia]   STATE.md frontmatter status=planning, body prose includes
#             "current status: verifying" outside ---/--- block → silent
#             (D-16 frontmatter isolation; F9 anchor)
#     [iii]   jq excluded from PATH → silent + zero stderr (Pitfall 6)
#     [iv]    status=verifying + no BACKLOG.md + no todos dir → silent
#             (D-15 hermetic-scan validation)
#     [vi]    status=verifying + 0 pending/ + 2 in done/ + 1 in archived/
#             with urgency: milestone-close frontmatter → silent
#             (D-15 -maxdepth 1 scope-isolation)
#
# SAFE_FOR_LIVE: yes
#   - HOME=$TMP fixture isolation per scenario (mirrors probe-execute-stop-review.sh)
#   - mktemp -d + trap 'rm -rf $TMP' EXIT
#   - no live ~/.claude, ~/.cache/dhx, or git state touched
#   - no subprocess invocation of CC; no live writes anywhere
#
# Backs:
#   - docs/decisions.md — 2026-05-18 MC-BLOCKER row (compose-pair contract)
#   - docs/hook-patterns.md — HP-002, HP-009, HP-017, HP-020 (declared by hook header)
#
# Run: bash tests/probes/probe-milestone-close-blocker-check.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$REPO_ROOT/dhx/dhx-milestone-close-blocker-check.sh"

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

TMP=$(mktemp -d /tmp/probe-mc-blocker.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

# --- Helpers ---

# setup_fixture <scenario_name> <state_status> [backlog_content] [todo_specs...]
# Builds $TMP/<scenario>/.planning/{STATE.md,BACKLOG.md,todos/pending/*.md} tree.
# todo_specs format: "filename|urgency_value" (e.g. "todo-1.md|milestone-close")
setup_fixture() {
  local scenario="$1"
  local status="$2"
  local backlog_content="${3:-}"
  shift; shift; shift 2>/dev/null || true
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

# run_hook_with_input <fixture_dir> <stop_hook_active> [extra_env...]
# Returns: sets STDOUT_CAP, STDERR_CAP, EXIT_CAP globals.
run_hook_with_input() {
  local fixture="$1"
  local stop_hook_active="${2:-false}"
  local cwd="${fixture%/.planning}"
  local payload
  payload=$(jq -n --arg cwd "$cwd" --argjson sha "$stop_hook_active" \
                  '{cwd:$cwd, stop_hook_active:$sha}')
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

assert_block_json() {
  local label="$1"
  if echo "$STDOUT_CAP" | jq -e '.decision == "block" and (.reason | type == "string") and (.reason | length > 50)' >/dev/null 2>&1; then
    echo "[PASS] $label"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] $label — stdout did not contain valid block JSON"
    echo "       stdout: $(printf '%s' "$STDOUT_CAP" | head -c 300)"
    echo "       stderr: $(printf '%s' "$STDERR_CAP" | head -c 300)"
    echo "       exit:   $EXIT_CAP"
    FAIL=$((FAIL + 1))
  fi
}

assert_reason_contains() {
  local label="$1" needle="$2"
  if echo "$STDOUT_CAP" | jq -r '.reason' 2>/dev/null | grep -qF "$needle"; then
    echo "[PASS] $label (reason contains: $needle)"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] $label — reason did not contain: $needle"
    echo "       reason: $(echo "$STDOUT_CAP" | jq -r '.reason' 2>/dev/null | head -c 300)"
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

# --- Scenario [Aa]: verifying + 1 BACKLOG row + 0 todos → block JSON ---
FIX_AA=$(setup_fixture "Aa" "verifying" "$BACKLOG_1_ROW")
run_hook_with_input "$FIX_AA"
assert_block_json "[Aa] verifying + 1 BACKLOG row + 0 todos → block JSON"
assert_reason_contains "[Aa] reason names 1 in BACKLOG.md" "1 in BACKLOG.md"
assert_reason_contains "[Aa] reason names 0 in .planning/todos/pending/" "0 in .planning/todos/pending/"

# --- Scenario [Ab]: milestone-shipped + 0 BACKLOG + 2 todos → block JSON ---
FIX_AB=$(setup_fixture "Ab" "milestone-shipped")
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
assert_block_json "[Ab] milestone-shipped + 2 todos → block JSON (D-04 cascade)"
assert_reason_contains "[Ab] reason names 2 in .planning/todos/pending/" "2 in .planning/todos/pending/"

# --- Scenario [Aa+v]: verifying + 1 bare header + 1 em-dash header → TOTAL=2 ---
FIX_DUAL=$(setup_fixture "Aav" "verifying" "$BACKLOG_DUAL_FORM")
run_hook_with_input "$FIX_DUAL"
assert_block_json "[Aa+v] verifying + dual-form headers → block JSON (D-08)"
# 2 BACKLOG rows total via dual-form awk pattern; the 2nd `## Milestone Close — v1.3`
# header re-enters in_group state, so both rows count.
assert_reason_contains "[Aa+v] reason names 2 in BACKLOG.md (dual-form awk match)" "2 in BACKLOG.md"

# --- Scenario [Ac]: planning + items present → silent ---
FIX_AC=$(setup_fixture "Ac" "planning" "$BACKLOG_1_ROW")
cat > "$FIX_AC/todos/pending/todo-1.md" <<'EOF'
---
urgency: milestone-close
---
EOF
run_hook_with_input "$FIX_AC"
assert_silent_no_stderr "[Ac] planning + items → silent"

# --- Scenario [Ad]: executing + items present → silent ---
FIX_AD=$(setup_fixture "Ad" "executing" "$BACKLOG_1_ROW")
cat > "$FIX_AD/todos/pending/todo-1.md" <<'EOF'
---
urgency: milestone-close
---
EOF
run_hook_with_input "$FIX_AD"
assert_silent_no_stderr "[Ad] executing + items → silent"

# --- Scenario [i]: verifying + items + stop_hook_active=true → silent (HP-002) ---
FIX_I=$(setup_fixture "i" "verifying" "$BACKLOG_1_ROW")
run_hook_with_input "$FIX_I" true
assert_silent_no_stderr "[i] stop_hook_active=true → silent (HP-002)"

# --- Scenario [ii]: no STATE.md → silent (missing-file fast-fail) ---
FIX_II_DIR="$TMP/ii/.planning"
mkdir -p "$FIX_II_DIR/todos/pending"
# Deliberately do not create STATE.md
run_hook_with_input "$FIX_II_DIR"
assert_silent_no_stderr "[ii] missing STATE.md → silent"

# --- Scenario [iia]: frontmatter status=planning, body contains "verifying" → silent (D-16) ---
FIX_IIA_DIR="$TMP/iia/.planning"
mkdir -p "$FIX_IIA_DIR/todos/pending"
cat > "$FIX_IIA_DIR/STATE.md" <<'EOF'
---
status: planning
milestone: v1.3
---

# State body prose

Last activity: current status: verifying recent stuff

Notes: previous status was verifying and we noticed status: milestone-shipped happened.

## Some Section
status: verifying  appearing in body text — must NOT trigger.
EOF
printf '%s' "$BACKLOG_1_ROW" > "$FIX_IIA_DIR/BACKLOG.md"
run_hook_with_input "$FIX_IIA_DIR"
assert_silent_no_stderr "[iia] body-text false-positive avoided → silent (D-16)"

# --- Scenario [iii]: jq excluded from PATH → silent + zero stderr ---
# Build a curated $TMP/bin directory containing only the tools the hook needs
# EXCEPT jq. The hook's `command -v jq` MUST return non-zero so the hook
# exits 0 silently at the gate (Pitfall 6).
FIX_III=$(setup_fixture "iii" "verifying" "$BACKLOG_1_ROW")
JQLESS_BIN="$TMP/iii-bin"
mkdir -p "$JQLESS_BIN"
# Symlink required tools (NOT jq).
for tool in bash awk find grep cat sed; do
  tool_path=$(command -v "$tool" 2>/dev/null || true)
  if [ -n "$tool_path" ]; then
    ln -sf "$tool_path" "$JQLESS_BIN/$tool"
  fi
done
# Re-confirm jq is NOT reachable via the curated PATH.
if env -i PATH="$JQLESS_BIN" bash -c 'command -v jq' >/dev/null 2>&1; then
  echo "[FAIL] [iii] setup: jq still resolvable through curated PATH — refusing to run scenario"
  FAIL=$((FAIL + 1))
else
  cwd_iii="${FIX_III%/.planning}"
  payload_iii=$(jq -n --arg cwd "$cwd_iii" '{cwd:$cwd, stop_hook_active:false}')
  iii_stdout=$(mktemp "$TMP/iii-stdout.XXXX")
  iii_stderr=$(mktemp "$TMP/iii-stderr.XXXX")
  echo "$payload_iii" | env -i PATH="$JQLESS_BIN" HOME="$cwd_iii" \
    bash "$HOOK" >"$iii_stdout" 2>"$iii_stderr" || true
  iii_stdout_content=$(cat "$iii_stdout")
  iii_stderr_content=$(cat "$iii_stderr")
  iii_stderr_bytes=$(printf '%s' "$iii_stderr_content" | wc -c)
  rm -f "$iii_stdout" "$iii_stderr"
  if [ -z "$iii_stdout_content" ] && [ "$iii_stderr_bytes" -eq 0 ]; then
    echo "[PASS] [iii] jq absent → silent + zero stderr (Pitfall 6)"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] [iii] jq-absent path emitted output"
    echo "       stdout: $(printf '%s' "$iii_stdout_content" | head -c 200)"
    echo "       stderr: $(printf '%s' "$iii_stderr_content" | head -c 200)"
    FAIL=$((FAIL + 1))
  fi
fi

# --- Scenario [iv]: verifying + no BACKLOG + no todos dir → silent ---
FIX_IV_DIR="$TMP/iv/.planning"
mkdir -p "$FIX_IV_DIR"
cat > "$FIX_IV_DIR/STATE.md" <<'EOF'
---
status: verifying
---
EOF
# Deliberately no BACKLOG.md, no todos/pending/
run_hook_with_input "$FIX_IV_DIR"
assert_silent_no_stderr "[iv] verifying + missing surfaces → silent (D-15 hermetic)"

# --- Scenario [vi]: verifying + 0 pending + 2 done + 1 archived with urgency frontmatter → silent ---
# D-15 -maxdepth 1 + pointing at .planning/todos/pending/ specifically means
# done/ and archived/ siblings are not scanned.
FIX_VI=$(setup_fixture "vi" "verifying")
# 2 done/, 1 archived/ files with milestone-close urgency — should NOT count
for i in 1 2; do
  cat > "$FIX_VI/todos/done/done-$i.md" <<'EOF'
---
urgency: milestone-close
---
done item content
EOF
done
cat > "$FIX_VI/todos/archived/archived-1.md" <<'EOF'
---
urgency: milestone-close
---
archived item
EOF
# No BACKLOG.md, no pending/ entries — totals must be 0
run_hook_with_input "$FIX_VI"
assert_silent_no_stderr "[vi] done/archived urgency items NOT counted → silent (D-15 -maxdepth 1)"

# --- Summary ---
echo
echo "Total: $PASS pass / $FAIL fail"
[ "$FAIL" -eq 0 ]
