#!/usr/bin/env bash
# dhx-execute-review.sh — PostToolUse hook (Agent matcher)
# Patterns: HP-011  (vestigial, pending anthropics/claude-code#6305)
# Injects execution fidelity review when a gsd-verifier agent completes
# during an active phase execution. Catches plan-to-execution drift at
# the moment verification completes, before the session ends.
# Advisory only — no blocking.

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then exit 0; fi

AGENT_TYPE=$(echo "$INPUT" | jq -r '.tool_input.subagent_type // empty')

# Gate: Only gsd-verifier completions
[ "$AGENT_TYPE" != "gsd-verifier" ] && exit 0

# Gate: Only during phase execution (recent SUMMARY.md = execution evidence)
PLANNING_DIR=""
DIR="$(pwd)"
while [ "$DIR" != "/" ]; do
  if [ -d "$DIR/.planning/phases" ]; then
    PLANNING_DIR="$DIR/.planning"
    break
  fi
  DIR="$(dirname "$DIR")"
done

[ -z "$PLANNING_DIR" ] && exit 0

SUMMARY_COUNT=$(find "$PLANNING_DIR/phases" -name "*-SUMMARY.md" -mmin -30 2>/dev/null | wc -l)
[ "$SUMMARY_COUNT" -eq 0 ] && exit 0

cat << 'ENDJSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "EXECUTION REVIEW — Verifier completed. Phase execution is complete. Apply fidelity review before session ends:\n1. PLAN-TO-EXECUTION FIDELITY: Compare each completed task against its plan description, not just the task title. Were any tasks simplified during implementation without flagging?\n2. CONTEXT-TO-CODE FIDELITY: Do committed changes align with CONTEXT.md decisions? Or was a different interpretation quietly built? Diff the intent against the result.\n3. SILENT DESCOPING: Were any plan tasks dropped or partially implemented without recording the deviation? Check for tasks that disappeared between plan and execution summary.\nIf drift is detected on any of these, flag it now with specific evidence — don't let it compound into downstream phases."
  }
}
ENDJSON
