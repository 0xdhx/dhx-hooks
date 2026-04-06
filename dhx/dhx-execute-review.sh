#!/usr/bin/env bash
# dhx-execute-review.sh — PostToolUse hook (Write matcher)
# Injects execution fidelity review when VERIFICATION.md is written.
# Catches plan-to-execution drift at the moment verification results
# are recorded, before the session ends. Advisory only — no blocking.

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then exit 0; fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Gate: Only *-VERIFICATION.md in .planning/phases/ (not suffixed variants like *-VERIFICATION-BROWSER-VERIFICATION.md)
BASENAME=$(basename "$FILE_PATH" 2>/dev/null)
case "$FILE_PATH" in
  */.planning/phases/*-VERIFICATION.md|*\\.planning\\phases\\*-VERIFICATION.md) ;;
  *) exit 0 ;;
esac
# Reject suffixed variants (e.g. 09-VERIFICATION-BROWSER-VERIFICATION.md)
case "$BASENAME" in
  *-VERIFICATION-*) exit 0 ;;
esac

cat << 'ENDJSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "EXECUTION REVIEW — Verification written. Phase execution is complete. Apply fidelity review before session ends:\n1. PLAN-TO-EXECUTION FIDELITY: Compare each completed task against its plan description, not just the task title. Were any tasks simplified during implementation without flagging?\n2. CONTEXT-TO-CODE FIDELITY: Do committed changes align with CONTEXT.md decisions? Or was a different interpretation quietly built? Diff the intent against the result.\n3. SILENT DESCOPING: Were any plan tasks dropped or partially implemented without recording the deviation? Check for tasks that disappeared between plan and execution summary.\nIf drift is detected on any of these, flag it now with specific evidence — don't let it compound into downstream phases."
  }
}
ENDJSON
