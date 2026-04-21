#!/usr/bin/env bash
# dhx-assessed-guard.sh — PreToolUse hook (Write|Edit matcher)
# Patterns: HP-007, HP-009
# Prevents agents from marking deferred items [assessed] without user approval.
#
# [captured], [existing], [tracked] are fine — they have verifiable backing.
# [assessed] means "intentionally not captured" and requires human judgment.
#
# Exception: if a deferred review session is active (marker from Stop hook),
# the agent is presumably following the one-at-a-time protocol with the user.
# The guard allows [assessed] writes during active review.

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then exit 0; fi

TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Gate: Only CONTEXT.md files in .planning/phases/
case "$FILE_PATH" in
  */.planning/phases/*-CONTEXT.md) ;;
  *) exit 0 ;;
esac

# Detect if [assessed] is being added
ADDING_ASSESSED=false

if [ "$TOOL" = "Edit" ]; then
  OLD=$(echo "$INPUT" | jq -r '.tool_input.old_string // empty')
  NEW=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
  # Adding [assessed] if it's in new but not in old
  if echo "$NEW" | grep -q '\[assessed' && ! echo "$OLD" | grep -q '\[assessed'; then
    ADDING_ASSESSED=true
  fi
fi

if [ "$TOOL" = "Write" ]; then
  CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
  # Compare assessed count: new content vs file on disk
  if [ -f "$FILE_PATH" ]; then
    OLD_COUNT=$(grep -c '\[assessed' "$FILE_PATH" 2>/dev/null || echo 0)
    NEW_COUNT=$(echo "$CONTENT" | grep -c '\[assessed' || echo 0)
    if [ "$NEW_COUNT" -gt "$OLD_COUNT" ]; then
      ADDING_ASSESSED=true
    fi
  else
    # New file with assessed markers
    if echo "$CONTENT" | grep -q '\[assessed'; then
      ADDING_ASSESSED=true
    fi
  fi
fi

if [ "$ADDING_ASSESSED" = false ]; then exit 0; fi

# Exception: if deferred review is active (Stop hook fired recently), allow it.
# The agent should be in the one-at-a-time protocol with the user present.
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
if [ -n "$CWD" ]; then
  REVIEW_MARKER="/tmp/dhx-deferred-review-$(echo "$CWD" | md5sum | cut -d' ' -f1 2>/dev/null || echo "default")"
  # Review active if marker exists and is less than 30 minutes old
  if [ -f "$REVIEW_MARKER" ] && [ "$(find "$REVIEW_MARKER" -mmin -30 2>/dev/null)" ]; then
    exit 0
  fi
fi

# Block: no active review session, agent is self-marking
jq -n '{"decision": "block", "reason": "[assessed] markers require user approval. Run /dhx:defer-review to review each deferred item with the user. If mid-review already, the 30-min approval marker expired — re-run /dhx:defer-review."}'

exit 0
