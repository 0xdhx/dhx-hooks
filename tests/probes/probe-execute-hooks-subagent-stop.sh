#!/usr/bin/env bash
# probe-execute-hooks-subagent-stop.sh
#
# Regression probe for the 2026-05-07 PostToolUse:Agent → SubagentStop
# migration of the three checkpoint/review hooks:
#   - dhx-execute-checkpoint.sh (gsd-executor)
#   - dhx-execute-review.sh     (gsd-verifier, mid-execute)
#   - dhx-audit-checkpoint.sh   (gsd-verifier)
#
# Scenarios:
#   1. SubagentStop stdin (agent_type:gsd-executor) → checkpoint fires;
#      output uses top-level `systemMessage` (advisory-only schema)
#   2. SubagentStop stdin (agent_type:gsd-verifier, mid-execute fixture)
#      → execute-review fires with phase preamble in `systemMessage`
#   3. SubagentStop stdin (agent_type:gsd-verifier) → audit-checkpoint fires
#      with audit message in `systemMessage`
#   4. SubagentStop stdin (agent_type:general-purpose) → all three silent
#   5. Backward-compat: old PostToolUse:Agent shape (.tool_input.subagent_type)
#      → hooks still parse via fallback
#   6. Once-per-phase gate (execute-checkpoint): second fire same session+phase
#      → silent
#   7. execute-review without recent SUMMARY.md → silent (mid-execute gate)
#
# Each emit-scenario (1, 2, 3) calls assert_stop_schema from
# tests/probes/lib/assert-stop-schema.sh — three sub-assertions per call:
# valid JSON, no hookSpecificOutput key, all top-level keys in advisory-event
# allowlist. Catches regressions to the pre-2026-05-08 wrapped shape.
#
# Backs:
#   - docs/decisions.md — 2026-05-07 SubagentStop migration row (event class)
#                       — 2026-05-08 supersession row (output channel reshape)
#   - docs/hook-patterns.md — HP-021 SubagentStop, HP-011 addendum
#   - docs/hook-dev-guide.md — "Output JSON Schema (advisory-only events)"
#   - reports/done/2026-05-06-dhx-execute-test-drive-review-2.md (Code Issue #5)
#   - reports/2026-05-08-subagentstop-hookspecificoutput-schema-audit.md
#
# Run: bash tests/probes/probe-execute-hooks-subagent-stop.sh
#
# SAFE_FOR_LIVE: yes  (per-test mktemp HOME / TMPDIR overrides; cwd argument
#                      passed via stdin payload (HP-001 cwd field) so hooks
#                      read .planning fixtures from the sandbox dir; no live
#                      ~/.cache/dhx, ~/.claude, or git state touched.)
# RUNTIME: ~1s

set -u

CHECKPOINT="/home/dhx/repos/hooks/dhx/dhx-execute-checkpoint.sh"
REVIEW="/home/dhx/repos/hooks/dhx/dhx-execute-review.sh"
AUDIT="/home/dhx/repos/hooks/dhx/dhx-audit-checkpoint.sh"
TMP=$(mktemp -d /tmp/probe-execute-hooks-subagent-stop.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
HOOK_OUT=""
HOOK_EXIT=0

# shellcheck source=lib/assert-stop-schema.sh
source "$(dirname "$0")/lib/assert-stop-schema.sh"

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

# setup_project NAME [WITH_SUMMARY] — fresh project with .planning/STATE.md
# (phase=31.1) and optionally a recent *-SUMMARY.md (mid-execute signal).
setup_project() {
  local name="$1" with_summary="${2:-yes}"
  local proj="$TMP/$name"
  mkdir -p "$proj/.planning/phases/31.1-test-drive"
  cat > "$proj/.planning/STATE.md" <<'EOF'
**Phase:** 31.1 test-drive
EOF
  if [ "$with_summary" = "yes" ]; then
    touch "$proj/.planning/phases/31.1-test-drive/01-plan-SUMMARY.md"
  fi
  echo "$proj"
}

# Run hook with sandboxed env. Captures HOOK_OUT and HOOK_EXIT globals.
# Args: HOOK PROJ STDIN_JSON
run_hook() {
  local hook="$1" proj="$2" stdin_json="$3"
  HOOK_EXIT=0
  HOOK_OUT=$(env \
    "HOME=$TMP" \
    "TMPDIR=$TMP" \
    bash -c "cd '$proj' && bash '$hook'" <<< "$stdin_json" 2>&1) || HOOK_EXIT=$?
}

assert_exit() {
  local expected="$1" label="$2"
  if [ "$HOOK_EXIT" -eq "$expected" ]; then
    echo "OK   $label (exit $HOOK_EXIT)"
    PASS=$((PASS + 1))
  else
    echo "FAIL $label (expected exit $expected, got $HOOK_EXIT)"
    echo "     output: $HOOK_OUT"
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

assert_stdout_empty() {
  local label="$1"
  if [ -z "$HOOK_OUT" ]; then
    echo "OK   $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL $label (expected empty stdout, got: $HOOK_OUT)"
    FAIL=$((FAIL + 1))
  fi
}

clear_markers() {
  rm -f /tmp/dhx-checkpoint-*
}

# ----------------------------------------------------------------------------
# Scenario 1 — checkpoint fires for gsd-executor with advisory-only schema:
# output JSON uses top-level `systemMessage` (no `hookSpecificOutput` envelope).
# 2026-05-07 migration set hookEventName="SubagentStop" inside the wrapper;
# 2026-05-08 supersession unwraps to bare `systemMessage` per schema.
# ----------------------------------------------------------------------------
clear_markers
PROJ=$(setup_project s1)
STDIN='{"agent_type":"gsd-executor","session_id":"sid-s1","cwd":"'"$PROJ"'","hook_event_name":"SubagentStop"}'
run_hook "$CHECKPOINT" "$PROJ" "$STDIN"
assert_exit 0 "[1] checkpoint SubagentStop stdin (gsd-executor) → exit 0"
assert_stdout_contains '"systemMessage"' "[1] output JSON uses top-level systemMessage channel"
assert_stop_schema "$HOOK_OUT" "[1]"
assert_stdout_contains "EXECUTION CHECKPOINT" "[1] output carries checkpoint message"

# ----------------------------------------------------------------------------
# Scenario 2 — execute-review fires with phase preamble for gsd-verifier
# during mid-execute (recent SUMMARY.md fixture present).
# ----------------------------------------------------------------------------
clear_markers
PROJ=$(setup_project s2)
STDIN='{"agent_type":"gsd-verifier","session_id":"sid-s2","cwd":"'"$PROJ"'","hook_event_name":"SubagentStop"}'
run_hook "$REVIEW" "$PROJ" "$STDIN"
assert_exit 0 "[2] execute-review SubagentStop stdin (gsd-verifier, mid-execute) → exit 0"
assert_stdout_contains '"systemMessage"' "[2] output JSON uses top-level systemMessage channel"
assert_stop_schema "$HOOK_OUT" "[2]"
assert_stdout_contains "Phase 31.1 verifier completed" "[2] phase preamble derived from STATE.md"

# ----------------------------------------------------------------------------
# Scenario 3 — audit-checkpoint fires with SubagentStop event name for
# gsd-verifier.
# ----------------------------------------------------------------------------
clear_markers
PROJ=$(setup_project s3)
STDIN='{"agent_type":"gsd-verifier","session_id":"sid-s3","cwd":"'"$PROJ"'","hook_event_name":"SubagentStop"}'
run_hook "$AUDIT" "$PROJ" "$STDIN"
assert_exit 0 "[3] audit-checkpoint SubagentStop stdin (gsd-verifier) → exit 0"
assert_stdout_contains '"systemMessage"' "[3] output JSON uses top-level systemMessage channel"
assert_stop_schema "$HOOK_OUT" "[3]"
assert_stdout_contains "AUDIT CHECKPOINT" "[3] output carries audit message"

# ----------------------------------------------------------------------------
# Scenario 4 — non-target agent_type → all three hooks silent.
# ----------------------------------------------------------------------------
clear_markers
PROJ=$(setup_project s4)
STDIN='{"agent_type":"general-purpose","session_id":"sid-s4","cwd":"'"$PROJ"'","hook_event_name":"SubagentStop"}'
run_hook "$CHECKPOINT" "$PROJ" "$STDIN"
assert_exit 0 "[4a] checkpoint general-purpose → exit 0"
assert_stdout_empty "[4a] checkpoint silent for non-executor agent"
run_hook "$REVIEW" "$PROJ" "$STDIN"
assert_exit 0 "[4b] execute-review general-purpose → exit 0"
assert_stdout_empty "[4b] execute-review silent for non-verifier agent"
run_hook "$AUDIT" "$PROJ" "$STDIN"
assert_exit 0 "[4c] audit-checkpoint general-purpose → exit 0"
assert_stdout_empty "[4c] audit-checkpoint silent for non-verifier agent"

# ----------------------------------------------------------------------------
# Scenario 5 — backward-compat: legacy PostToolUse:Agent payload shape
# (`.tool_input.subagent_type`) still parses via the jq fallback. Important
# during the transition window — stale-snapshot CC processes (HP-012) may
# still deliver the old shape until they restart.
# ----------------------------------------------------------------------------
clear_markers
PROJ=$(setup_project s5)
STDIN='{"tool_input":{"subagent_type":"gsd-executor"},"session_id":"sid-s5","cwd":"'"$PROJ"'"}'
run_hook "$CHECKPOINT" "$PROJ" "$STDIN"
assert_exit 0 "[5] checkpoint legacy PostToolUse:Agent shape → exit 0"
assert_stdout_contains "EXECUTION CHECKPOINT" "[5] checkpoint fires under legacy shape (fallback path)"

# ----------------------------------------------------------------------------
# Scenario 6 — once-per-phase gate (execute-checkpoint). First fire emits;
# second fire under same (session_id, phase) is silent.
# ----------------------------------------------------------------------------
clear_markers
PROJ=$(setup_project s6)
STDIN='{"agent_type":"gsd-executor","session_id":"sid-s6","cwd":"'"$PROJ"'","hook_event_name":"SubagentStop"}'
run_hook "$CHECKPOINT" "$PROJ" "$STDIN"
assert_stdout_contains "EXECUTION CHECKPOINT" "[6a] first fire emits checkpoint"
run_hook "$CHECKPOINT" "$PROJ" "$STDIN"
assert_exit 0 "[6b] second fire same (session,phase) → exit 0"
assert_stdout_empty "[6b] second fire silent (once-per-phase marker)"

# ----------------------------------------------------------------------------
# Scenario 7 — execute-review without recent *-SUMMARY.md → silent
# (mid-execute gate prevents firing outside execution windows).
# ----------------------------------------------------------------------------
clear_markers
PROJ=$(setup_project s7 no)
STDIN='{"agent_type":"gsd-verifier","session_id":"sid-s7","cwd":"'"$PROJ"'","hook_event_name":"SubagentStop"}'
run_hook "$REVIEW" "$PROJ" "$STDIN"
assert_exit 0 "[7] execute-review without SUMMARY.md → exit 0"
assert_stdout_empty "[7] execute-review silent without execution evidence"

# Cleanup any lingering markers from the probe.
clear_markers

# ----------------------------------------------------------------------------
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
