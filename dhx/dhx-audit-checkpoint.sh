#!/usr/bin/env bash
# dhx-audit-checkpoint.sh — PostToolUse hook (Agent matcher)
# Patterns: HP-003
# Injects audit calibration when a gsd-verifier agent completes.
# Counteracts optimistic completion bias at the moment verification
# results are returned. Advisory only — no blocking.

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then exit 0; fi

AGENT_TYPE=$(echo "$INPUT" | jq -r '.tool_input.subagent_type // empty')

# Gate: Only gsd-verifier completions
[ "$AGENT_TYPE" != "gsd-verifier" ] && exit 0

cat << 'ENDJSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "AUDIT CHECKPOINT — Verifier completed. Apply anti-optimism review:\n1. Does 'verified' mean 'tested and confirmed working' or 'code exists that should work'? Only the former counts.\n2. Are acceptance criteria evaluated individually, or summarized as 'all met'? Check each one.\n3. Were any criteria silently dropped or weakened from the original CONTEXT.md?\n4. If this completes the milestone, run /dhx:audit before archiving.\n5. Run /dhx:nyquist to validate test coverage for this phase before proceeding to the next phase."
  }
}
ENDJSON
