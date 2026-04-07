#!/usr/bin/env bash
# dhx-execute-stop-review.sh — Stop hook
# Safety net for execution pipelines. If a phase execution completed
# (VERIFICATION.md + SUMMARY.md evidence) but the /dhx:execute review
# wasn't performed, blocks with review prompt.
#
# Pairs with dhx-routing.sh (UserPromptSubmit) which primes calibration
# at session start. This catches the case where Claude didn't follow
# through on the review before ending.
#
# Why Stop and not PostToolUse:Agent? Hooks do not propagate into Agent
# boundaries — no PreToolUse, PostToolUse, or SubagentStop events fire
# for tool calls inside spawned agents. Stop is the only reliable
# post-execution hook point. See docs/hook-dev-guide.md § Propagation.

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then exit 0; fi

# Loop prevention — Claude Code sets this after first block
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then exit 0; fi

CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
if [ -z "$CWD" ]; then exit 0; fi

# Gate: GSD project
if [ ! -d "$CWD/.planning/phases" ]; then exit 0; fi

# Gate: Recent execution evidence — VERIFICATION.md in last 15 min
RECENT_VERIF=$(find "$CWD/.planning/phases" -name "*-VERIFICATION.md" -mmin -15 2>/dev/null | head -1)
[ -z "$RECENT_VERIF" ] && exit 0

# Gate: Execution context — recent SUMMARY.md in same phase dir
PHASE_DIR=$(dirname "$RECENT_VERIF")
RECENT_SUMMARY=$(find "$PHASE_DIR" -name "*-SUMMARY.md" -mmin -30 2>/dev/null | head -1)
[ -z "$RECENT_SUMMARY" ] && exit 0

# Gate: Check if review was already performed (scan transcript)
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript // ""' 2>/dev/null)
if echo "$TRANSCRIPT" | grep -qi 'plan-to-execution fidelity\|execution-to-plan fidelity\|context-to-code fidelity\|silent descoping.*check\|EXECUTION REVIEW'; then
  exit 0  # Review already done
fi

# Extract phase number
PHASE=$(basename "$RECENT_VERIF" | grep -oP '^\d+(\.\d+)?' | head -1)
[ -z "$PHASE" ] && exit 0

MSG="EXECUTION REVIEW NOT COMPLETED — Phase ${PHASE} execution finished but the /dhx:execute review was not performed.

Apply before session ends:
1. PLAN-TO-EXECUTION FIDELITY: Compare each completed task against its plan description. Were any tasks simplified during implementation without flagging?
2. CONTEXT-TO-CODE FIDELITY: Do committed changes align with CONTEXT.md decisions? Or was a different interpretation quietly built?
3. SILENT DESCOPING: Were any plan tasks dropped or partially implemented without recording the deviation?
4. DEFERRED ITEMS: Scan for TODOs or noted limitations that need /dhx:capture.
5. BACKLOG SYNC: Run /dhx:backlog audit to check for uncaptured items.
6. NYQUIST: Run /dhx:nyquist to validate test coverage for this phase."

jq -n --arg msg "$MSG" \
  '{"decision": "block", "reason": $msg}'

exit 0
