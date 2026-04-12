#!/usr/bin/env bash
# dhx-read-partial-cache.sh — PreToolUse:Read hook
# Patterns: HP-007
#
# Companion to read-once/hook.sh, which intentionally skips partial
# reads (offset/limit) from the session cache. This hook fills that
# gap by writing a {"partial":true} marker so dhx-read-guard.js can
# distinguish "partial read happened" from "no read at all."
#
# Uses the same cache file and session-hash algorithm as read-once/hook.sh
# (sha256 of session_id, first 16 hex chars). Appends to the same JSONL.
#
# Fires: PreToolUse on Read tool
# Gate: only runs when offset or limit is present (partial read)
# Action: cache-write only, no stdout, no blocking

INPUT=$(cat)

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
OFFSET=$(echo "$INPUT" | jq -r '.tool_input.offset // empty' 2>/dev/null)
LIMIT=$(echo "$INPUT" | jq -r '.tool_input.limit // empty' 2>/dev/null)

# Only care about partial reads
if [ -z "$OFFSET" ] && [ -z "$LIMIT" ]; then exit 0; fi
if [ -z "$FILE_PATH" ] || [ -z "$SESSION_ID" ]; then exit 0; fi

HASH=$(echo -n "$SESSION_ID" | sha256sum | cut -c1-16)
CACHE_FILE="${HOME}/.claude/read-once/session-${HASH}.jsonl"

RESOLVED=$(realpath "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")
echo "{\"path\":\"$RESOLVED\",\"ts\":$(date +%s),\"partial\":true}" >> "$CACHE_FILE"

exit 0
