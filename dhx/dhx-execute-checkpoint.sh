#!/usr/bin/env bash
# dhx-execute-checkpoint.sh — PostToolUse hook (Write matcher)
# Injects drift detection calibration when SUMMARY.md is written
# during phase execution. Fires per-plan for early drift catching.
# Advisory only — no blocking.

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then exit 0; fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Gate: Only SUMMARY.md in .planning/phases/
case "$FILE_PATH" in
  */.planning/phases/*-SUMMARY.md|*\\.planning\\phases\\*-SUMMARY.md) ;;
  *) exit 0 ;;
esac

cat << 'ENDJSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "EXECUTION CHECKPOINT — Plan summary written. Before proceeding to the next plan or ending the session, verify:\n1. Do committed changes match CONTEXT.md decisions? Check for silent descoping or scope creep.\n2. Were any CONTEXT.md decisions modified during implementation without recording the deviation?\n3. Are there deferred items from implementation that need /dhx:capture?\nIf drift is detected, flag it now — don't wait for end-of-session review."
  }
}
ENDJSON
