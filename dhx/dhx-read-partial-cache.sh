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

# INVARIANT: full reads are owned by ~/.claude/read-once/hook.sh (which writes
# entries without a `partial` field). This hook must exit without writing on
# full reads — a second writer would duplicate entries in reads.jsonl and
# double-count TTL matches in dhx-read-guard.js. Guarded by
# tests/probes/probe-read-partial-cache.sh Test 3.
#
# Fast path: if no offset/limit in the JSON, exit before any jq work.
# Full reads are the common case (~95%+); this avoids 4 jq forks per Read.
case "$INPUT" in
  *'"offset"'*|*'"limit"'*) ;;
  *) exit 0 ;;
esac

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
OFFSET=$(echo "$INPUT" | jq -r '.tool_input.offset // empty' 2>/dev/null)
LIMIT=$(echo "$INPUT" | jq -r '.tool_input.limit // empty' 2>/dev/null)

# Belt-and-suspenders: case match above catches the common path,
# but jq may return empty if the fields are null rather than absent
if [ -z "$OFFSET" ] && [ -z "$LIMIT" ]; then exit 0; fi
if [ -z "$FILE_PATH" ] || [ -z "$SESSION_ID" ]; then exit 0; fi

HASH=$(echo -n "$SESSION_ID" | sha256sum | cut -c1-16)
CACHE_FILE="${HOME}/.claude/read-once/session-${HASH}.jsonl"

RESOLVED=$(realpath "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")
echo "{\"path\":\"$RESOLVED\",\"ts\":$(date +%s),\"partial\":true}" >> "$CACHE_FILE"

# Also append to global cache for cross-session/CCS lookup by dhx-read-guard.js
GLOBAL_CACHE="${HOME}/.claude/read-once/reads.jsonl"
echo "{\"path\":\"$RESOLVED\",\"ts\":$(date +%s),\"partial\":true}" >> "$GLOBAL_CACHE"

exit 0
