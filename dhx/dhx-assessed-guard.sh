#!/usr/bin/env bash
# dhx-assessed-guard.sh — PreToolUse hook (Write|Edit matcher)
# Patterns: HP-003, HP-007, HP-009, HP-028
# Prevents agents from marking deferred items [assessed] without user approval.
#
# [captured], [existing], [tracked] are fine — they have verifiable backing.
# [assessed] means "intentionally not captured" and requires human judgment.
#
# Exception: if a deferred review session is active (marker from Stop hook),
# the agent is presumably following the one-at-a-time protocol with the user.
# The guard allows [assessed] writes during active review.
#
# Scope (HP-003 reframe, audit 2026-04-21): fires for parent AND subagent
# Write/Edit calls. Uniform enforcement intended — a subagent self-marking
# [assessed] bypasses the same user-approval invariant as a top-level call,
# and subagents cannot run /dhx:defer-review themselves. The hook does NOT
# branch on agent_id. Review-marker cwd key is md5(cwd): for subagent calls
# this resolves to the subagent's worktree, so the marker-based exception
# will not accidentally unlock in subagent context (the marker lives under
# parent cwd's hash). Desired outcome: subagent [assessed] always blocks.

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
  if grep -q '\[assessed' <<< "$NEW" && ! grep -q '\[assessed' <<< "$OLD"; then
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
    if grep -q '\[assessed' <<< "$CONTENT"; then
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
  # Review active if marker exists and is less than 60 minutes old
  if [ -f "$REVIEW_MARKER" ] && [ "$(find "$REVIEW_MARKER" -mmin -60 2>/dev/null)" ]; then
    exit 0
  fi
fi

# INVARIANT: fires for parent AND subagent Write|Edit calls (HP-003 verified
# 2026-04-21). Uniform enforcement intended — no agent_id short-circuit.
# Block: no active review session, agent is self-marking.
# Branch the message on marker presence — if the marker exists but expired,
# `touch` is a lighter recovery than re-running the skill (which re-walks
# already-disposed items).
if [ -n "${REVIEW_MARKER:-}" ] && [ -f "$REVIEW_MARKER" ]; then
  REASON="[assessed] markers require user approval. Mid-review marker expired (>60 min). Re-touch with: touch \"$REVIEW_MARKER\" — or re-run /dhx:defer-review if you've lost context."
else
  REASON="[assessed] markers require user approval. Run /dhx:defer-review to review each deferred item with the user."
fi
jq -n --arg reason "$REASON" '{"decision": "block", "reason": $reason}'

exit 0
