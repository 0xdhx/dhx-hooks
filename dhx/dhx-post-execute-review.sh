#!/usr/bin/env bash
# dhx-post-execute-review.sh — PostToolUse hook (Agent matcher)
# Patterns: HP-011  (vestigial, pending anthropics/claude-code#6305)
# Triggers /dhx:execute post-execution review when a gsd-verifier agent
# completes during an active phase execution.
#
# Detection: looks for a VERIFICATION.md created in the last 5 minutes
# alongside SUMMARY.md files (execution evidence). This avoids false
# positives from standalone /gsd-verify-work invocations.

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then exit 0; fi

AGENT_TYPE=$(echo "$INPUT" | jq -r '.tool_input.subagent_type // empty')

# Gate: Only gsd-verifier completions
[ "$AGENT_TYPE" != "gsd-verifier" ] && exit 0

# Find .planning/ — walk up from cwd
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

# Find VERIFICATION.md files modified in the last 5 minutes
RECENT_VERIF=$(find "$PLANNING_DIR/phases" -name "*-VERIFICATION.md" -mmin -5 2>/dev/null | head -1)
[ -z "$RECENT_VERIF" ] && exit 0

# Extract phase directory and check for execution evidence (SUMMARY.md files)
PHASE_DIR=$(dirname "$RECENT_VERIF")
SUMMARY_COUNT=$(find "$PHASE_DIR" -name "*-SUMMARY.md" 2>/dev/null | wc -l)
[ "$SUMMARY_COUNT" -eq 0 ] && exit 0  # No summaries = not a phase execution context

# Extract phase number from the VERIFICATION.md filename (e.g., 53-VERIFICATION.md → 53)
PHASE=$(basename "$RECENT_VERIF" | grep -oP '^\d+(\.\d+)?' | head -1)
[ -z "$PHASE" ] && exit 0

cat << ENDJSON
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "POST-EXECUTION REVIEW — Phase ${PHASE} verifier completed. Run /dhx:execute (no args) to apply post-execution critique:\n1. Plan-to-execution fidelity — did implementation match plan tasks or silently descope?\n2. Context-to-code fidelity — do committed changes align with CONTEXT.md decisions?\n3. Deferred item capture — any TODOs or noted limitations that need /dhx:capture?\n4. Backlog sync — uncaptured items from execution?"
  }
}
ENDJSON
