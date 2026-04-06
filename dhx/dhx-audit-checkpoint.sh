#!/usr/bin/env bash
# dhx-audit-checkpoint.sh — PostToolUse hook (Write matcher)
# Injects audit calibration when VERIFICATION.md is written.
# Counteracts optimistic completion bias at the moment verification
# results are being recorded. Advisory only — no blocking.

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
    "additionalContext": "AUDIT CHECKPOINT — Verification written. Apply anti-optimism review:\n1. Does 'verified' mean 'tested and confirmed working' or 'code exists that should work'? Only the former counts.\n2. Are acceptance criteria evaluated individually, or summarized as 'all met'? Check each one.\n3. Were any criteria silently dropped or weakened from the original CONTEXT.md?\n4. If this completes the milestone, run /dhx:audit before archiving.\n5. Run /dhx:nyquist to validate test coverage for this phase before proceeding to the next phase."
  }
}
ENDJSON
