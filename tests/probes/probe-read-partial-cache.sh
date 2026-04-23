#!/usr/bin/env bash
# probe-read-partial-cache.sh — verify dhx-read-partial-cache.sh writes partial:true entries.
#
# Backs the 2026-04-22 decisions.md row "dhx-read-partial-cache.sh: plugin-manifest
# registration closes the 260415-3tz global-cache plan's dead partial branch".
# Asserts the hook emits {"path":<abs>,"ts":<unix>,"partial":true} on partial
# Reads (offset or limit present), matching the entry shape dhx-read-guard.js:109
# consumes for the PARTIAL-READ NOTE three-state branch.
#
# INVARIANT: full reads are owned by ~/.claude/read-once/hook.sh. This hook
# must NOT write on full reads — doing so would produce duplicate entries in
# reads.jsonl. The fast-exit at dhx-read-partial-cache.sh:21-24 enforces this.
#
# Run directly:
#   bash tests/probes/probe-read-partial-cache.sh
# Exit code 0 = pass. Nonzero with a [FAIL] line = test failure.

set -uo pipefail

HOOK="/home/dhx/repos/hooks/dhx/dhx-read-partial-cache.sh"
TMPHOME=$(mktemp -d)
TMPFILE=$(mktemp)
trap 'rm -rf "$TMPHOME" "$TMPFILE"' EXIT

cleanup_fail() {
  echo "[FAIL] $1" >&2
  exit 1
}

GLOBAL_CACHE="$TMPHOME/.claude/read-once/reads.jsonl"
mkdir -p "$TMPHOME/.claude/read-once"

# Test 1: Read with offset populates global + session cache with partial:true
INPUT=$(printf '{"tool_name":"Read","session_id":"probe-session-1","tool_input":{"file_path":"%s","offset":10,"limit":5}}' "$TMPFILE")
echo "$INPUT" | HOME="$TMPHOME" bash "$HOOK"
RC=$?
[ "$RC" -eq 0 ] || cleanup_fail "offset Read exited nonzero ($RC)"

[ -f "$GLOBAL_CACHE" ] || cleanup_fail "Partial Read did not create global cache $GLOBAL_CACHE"
LINE=$(tail -1 "$GLOBAL_CACHE")
echo "$LINE" | jq -e --arg p "$TMPFILE" '.path == $p and (.ts | type == "number") and .partial == true' >/dev/null \
  || cleanup_fail "Global cache entry missing partial:true or malformed: $LINE"

# Session cache also populated (hash of session_id)
SESSION_HASH=$(echo -n "probe-session-1" | sha256sum | cut -c1-16)
SESSION_CACHE="$TMPHOME/.claude/read-once/session-${SESSION_HASH}.jsonl"
[ -f "$SESSION_CACHE" ] || cleanup_fail "Session cache not created at $SESSION_CACHE"
SLINE=$(tail -1 "$SESSION_CACHE")
echo "$SLINE" | jq -e '.partial == true' >/dev/null \
  || cleanup_fail "Session cache entry missing partial:true: $SLINE"

# Test 2: Read with limit (no offset) also populates partial:true
INPUT=$(printf '{"tool_name":"Read","session_id":"probe-session-1","tool_input":{"file_path":"%s","limit":20}}' "$TMPFILE")
echo "$INPUT" | HOME="$TMPHOME" bash "$HOOK"
[ "$(wc -l < "$GLOBAL_CACHE")" -eq 2 ] || cleanup_fail "limit-only Read did not append second partial entry"

# Test 3: Full Read (no offset/limit) is a NO-OP — owned by read-once/hook.sh.
# Writing here would duplicate entries in reads.jsonl.
INPUT=$(printf '{"tool_name":"Read","session_id":"probe-session-1","tool_input":{"file_path":"%s"}}' "$TMPFILE")
echo "$INPUT" | HOME="$TMPHOME" bash "$HOOK"
[ "$(wc -l < "$GLOBAL_CACHE")" -eq 2 ] || cleanup_fail "Full Read incorrectly wrote to global cache (duplicates hook.sh)"

# Test 4: offset with null value is treated as absent (belt-and-suspenders check at hook line 33)
INPUT=$(printf '{"tool_name":"Read","session_id":"probe-session-1","tool_input":{"file_path":"%s","offset":null,"limit":null}}' "$TMPFILE")
echo "$INPUT" | HOME="$TMPHOME" bash "$HOOK"
[ "$(wc -l < "$GLOBAL_CACHE")" -eq 2 ] || cleanup_fail "null offset/limit incorrectly wrote to cache"

# Test 5: Missing session_id is ignored without crashing
INPUT=$(printf '{"tool_name":"Read","tool_input":{"file_path":"%s","offset":5}}' "$TMPFILE")
echo "$INPUT" | HOME="$TMPHOME" bash "$HOOK"
RC=$?
[ "$RC" -eq 0 ] || cleanup_fail "Missing session_id crashed hook (rc=$RC)"
[ "$(wc -l < "$GLOBAL_CACHE")" -eq 2 ] || cleanup_fail "Missing session_id silently wrote to cache"

# Test 6: Missing file_path is ignored without crashing
INPUT='{"tool_name":"Read","session_id":"probe-session-1","tool_input":{"offset":5}}'
echo "$INPUT" | HOME="$TMPHOME" bash "$HOOK"
RC=$?
[ "$RC" -eq 0 ] || cleanup_fail "Missing file_path crashed hook (rc=$RC)"
[ "$(wc -l < "$GLOBAL_CACHE")" -eq 2 ] || cleanup_fail "Missing file_path silently wrote to cache"

# Test 7: Emitted path is absolute (realpath-resolved)
RELDIR=$(mktemp -d)
RELFILE="$RELDIR/relfile.md"
touch "$RELFILE"
INPUT=$(printf '{"tool_name":"Read","session_id":"probe-session-1","tool_input":{"file_path":"%s","offset":1}}' "$RELFILE")
echo "$INPUT" | HOME="$TMPHOME" bash "$HOOK"
LAST=$(tail -1 "$GLOBAL_CACHE")
EMITTED=$(echo "$LAST" | jq -r '.path')
[ "${EMITTED:0:1}" = "/" ] || cleanup_fail "Emitted path is not absolute: $EMITTED"
rm -rf "$RELDIR"

# Test 8: dhx-read-guard.js three-state consumes partial:true correctly.
# INVARIANT: partial branch in dhx-read-guard.js:109-113 is not dead code after this registration.
GUARD="/home/dhx/repos/hooks/dhx/dhx-read-guard.js"
# Seed the REAL global cache (guard reads $HOME/.claude/read-once/reads.jsonl, not a configurable path)
REAL_CACHE="$TMPHOME/.claude/read-once/reads.jsonl"
NOW=$(date +%s)
echo "{\"path\":\"$TMPFILE\",\"ts\":$NOW,\"partial\":true}" > "$REAL_CACHE"
GUARD_INPUT=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$TMPFILE")
OUTPUT=$(echo "$GUARD_INPUT" | HOME="$TMPHOME" node "$GUARD")
echo "$OUTPUT" | jq -e '.hookSpecificOutput.additionalContext | test("PARTIAL-READ NOTE")' >/dev/null \
  || cleanup_fail "dhx-read-guard.js did not emit PARTIAL-READ NOTE for partial:true entry: $OUTPUT"

# Test 9: Full-read entry suppresses advisory entirely
echo "{\"path\":\"$TMPFILE\",\"ts\":$NOW}" > "$REAL_CACHE"
OUTPUT=$(echo "$GUARD_INPUT" | HOME="$TMPHOME" node "$GUARD")
[ -z "$OUTPUT" ] || cleanup_fail "Full-read entry should suppress advisory (got: $OUTPUT)"

echo "[PASS] dhx-read-partial-cache.sh: 9/9 assertions"
