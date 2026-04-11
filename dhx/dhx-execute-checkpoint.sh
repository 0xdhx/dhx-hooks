#!/usr/bin/env bash
# dhx-execute-checkpoint.sh — PostToolUse hook (Agent matcher)
# Patterns: HP-003
# Injects drift detection calibration when a gsd-executor agent completes.
# Fires per-plan for early drift catching.
# Advisory only — no blocking.

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then exit 0; fi

AGENT_TYPE=$(echo "$INPUT" | jq -r '.tool_input.subagent_type // empty')

# Gate: Only gsd-executor completions
[ "$AGENT_TYPE" != "gsd-executor" ] && exit 0

cat << 'ENDJSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "EXECUTION CHECKPOINT — Executor plan completed. Before proceeding to the next plan or ending the session, verify:\n1. Do committed changes match CONTEXT.md decisions? Check for silent descoping or scope creep.\n2. Were any CONTEXT.md decisions modified during implementation without recording the deviation?\n3. Are there deferred items from implementation that need /dhx:capture?\nIf drift is detected, flag it now — don't wait for end-of-session review."
  }
}
ENDJSON
