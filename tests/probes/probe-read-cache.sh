#!/usr/bin/env bash
# probe-read-cache.sh — verify dhx-read-cache.sh + dhx-read-guard.js dual-path stack.
#
# Backs the v1.1 Phase 1 atomic-commit decisions.md row (Option B retire
# ~/.claude/read-once/, own the read-tracking stack). Asserts:
#   - Writer schema: {"path":<abs>,"ts":<num>,"source":"read","partial":true?}
#   - Cache file at $HOME/.cache/dhx/read-cache.jsonl (XDG, D-04)
#   - Guard 3-state branching against full/partial/no-read entries
#   - Guard reads BOTH primary (XDG) AND legacy (~/.claude/read-once/reads.jsonl)
#     paths during migration window (D-01)
#   - Guard treats absent `source` field as "read" (D-07 null-safety)
#   - TTL expiry: entries with ts < NOW-7200 produce READ-BEFORE-EDIT (D-15, V-TTL-EXPIRY)
#
# INVARIANT: writer is the SOLE PreToolUse:Read writer post-Phase 1
# (D-05 collapses Boucle hook.sh + dhx-read-partial-cache.sh into one).
# Cache lives at XDG location, NOT ~/.claude/read-once/. Guard's read-both
# loop is monotonic (no dedupe needed) per V-DUAL-PATH-NOOP.
#
# Run directly:
#   bash tests/probes/probe-read-cache.sh
# Exit code 0 = pass. Nonzero with [FAIL] line = test failure.

# SAFE_FOR_LIVE: yes   (mktemp HOME isolation; XDG cache writes contained in $TMPHOME/.cache/dhx)
set -uo pipefail

HOOK="/home/dhx/repos/hooks/dhx/dhx-read-cache.sh"
TMPHOME=$(mktemp -d)
TMPFILE=$(mktemp)
trap 'rm -rf "$TMPHOME" "$TMPFILE"' EXIT

cleanup_fail() {
  echo "[FAIL] $1" >&2
  exit 1
}

CACHE="$TMPHOME/.cache/dhx/read-cache.jsonl"

# Test 1 (V-WRITER-FULL): Full Read (no offset/limit) emits source:"read", no partial
INPUT=$(printf '{"tool_name":"Read","session_id":"probe-1","tool_input":{"file_path":"%s"}}' "$TMPFILE")
echo "$INPUT" | HOME="$TMPHOME" bash "$HOOK"
RC=$?
[ "$RC" -eq 0 ] || cleanup_fail "Full Read exited nonzero ($RC)"
[ -f "$CACHE" ] || cleanup_fail "V-XDG-CACHE-PATH: cache not created at $CACHE"
LINE=$(tail -1 "$CACHE")
echo "$LINE" | jq -e --arg p "$TMPFILE" '.path == $p and (.ts | type == "number") and .source == "read" and (.partial == null)' >/dev/null \
  || cleanup_fail "V-WRITER-FULL: full Read entry malformed: $LINE"

# Test 2 (V-WRITER-PARTIAL-OFFSET): Read with offset:10 → partial:true
INPUT=$(printf '{"tool_name":"Read","session_id":"probe-1","tool_input":{"file_path":"%s","offset":10,"limit":5}}' "$TMPFILE")
echo "$INPUT" | HOME="$TMPHOME" bash "$HOOK"
LINE=$(tail -1 "$CACHE")
echo "$LINE" | jq -e '.source == "read" and .partial == true' >/dev/null \
  || cleanup_fail "V-WRITER-PARTIAL-OFFSET: offset Read missing partial:true: $LINE"

# Test 3 (V-WRITER-PARTIAL-LIMIT): Read with limit:20 (no offset) → partial:true
INPUT=$(printf '{"tool_name":"Read","session_id":"probe-1","tool_input":{"file_path":"%s","limit":20}}' "$TMPFILE")
echo "$INPUT" | HOME="$TMPHOME" bash "$HOOK"
LINE=$(tail -1 "$CACHE")
echo "$LINE" | jq -e '.source == "read" and .partial == true' >/dev/null \
  || cleanup_fail "V-WRITER-PARTIAL-LIMIT: limit-only Read missing partial:true: $LINE"

# Test 4 (V-WRITER-NULL-FIELDS): offset:null,limit:null → treated as full
INPUT=$(printf '{"tool_name":"Read","session_id":"probe-1","tool_input":{"file_path":"%s","offset":null,"limit":null}}' "$TMPFILE")
echo "$INPUT" | HOME="$TMPHOME" bash "$HOOK"
LINE=$(tail -1 "$CACHE")
echo "$LINE" | jq -e '.source == "read" and (.partial == null)' >/dev/null \
  || cleanup_fail "V-WRITER-NULL-FIELDS: null offset/limit not treated as full: $LINE"

# Test 5a (V-WRITER-MISSING-FIELDS): missing file_path → rc=0, no cache write
PRE_COUNT=$(wc -l < "$CACHE")
INPUT='{"tool_name":"Read","session_id":"probe-1","tool_input":{}}'
echo "$INPUT" | HOME="$TMPHOME" bash "$HOOK"
RC=$?
[ "$RC" -eq 0 ] || cleanup_fail "V-WRITER-MISSING-FIELDS: missing file_path crashed (rc=$RC)"
POST_COUNT=$(wc -l < "$CACHE")
[ "$PRE_COUNT" -eq "$POST_COUNT" ] || cleanup_fail "V-WRITER-MISSING-FIELDS: missing file_path silently wrote"

# Test 5b (V-WRITER-MISSING-FIELDS): missing session_id → rc=0, cache write OK (D-04 abandons session keying)
INPUT=$(printf '{"tool_name":"Read","tool_input":{"file_path":"%s"}}' "$TMPFILE")
echo "$INPUT" | HOME="$TMPHOME" bash "$HOOK"
RC=$?
[ "$RC" -eq 0 ] || cleanup_fail "V-WRITER-MISSING-FIELDS: missing session_id crashed (rc=$RC)"
POST_COUNT2=$(wc -l < "$CACHE")
[ "$POST_COUNT2" -eq "$((POST_COUNT + 1))" ] || cleanup_fail "V-WRITER-MISSING-FIELDS: missing session_id should still write (D-04)"

# Test 6 (V-WRITER-REALPATH): relative path → emitted absolute
RELDIR=$(mktemp -d)
RELFILE="$RELDIR/relfile.md"
touch "$RELFILE"
INPUT=$(printf '{"tool_name":"Read","tool_input":{"file_path":"%s"}}' "$RELFILE")
echo "$INPUT" | HOME="$TMPHOME" bash "$HOOK"
LAST=$(tail -1 "$CACHE")
EMITTED=$(echo "$LAST" | jq -r '.path')
[ "${EMITTED:0:1}" = "/" ] || cleanup_fail "V-WRITER-REALPATH: emitted path not absolute: $EMITTED"
rm -rf "$RELDIR"

# Test 7 (V-COMPACT-SCOPE-NO-REGRESSION): no session-*.jsonl created (D-04 pure global TTL)
SESSION_FILES=$(find "$TMPHOME/.claude/read-once" -name 'session-*.jsonl' 2>/dev/null | wc -l)
[ "$SESSION_FILES" -eq 0 ] || cleanup_fail "V-COMPACT-SCOPE-NO-REGRESSION: writer created session-*.jsonl (regression of D-04 abandonment)"

# ====== GUARD INTEGRATION ASSERTIONS (V-GUARD-* invariants) ======
GUARD="/home/dhx/repos/hooks/dhx/dhx-read-guard.js"

# Reset cache for clean guard tests
> "$CACHE"
NOW=$(date +%s)

# Test 8 (V-GUARD-FULL-SUPPRESS): full-read entry → guard suppresses advisory
echo "{\"path\":\"$TMPFILE\",\"ts\":$NOW,\"source\":\"read\"}" >> "$CACHE"
GUARD_INPUT=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$TMPFILE")
OUTPUT=$(echo "$GUARD_INPUT" | HOME="$TMPHOME" node "$GUARD")
[ -z "$OUTPUT" ] || cleanup_fail "V-GUARD-FULL-SUPPRESS: full-read entry should suppress advisory (got: $OUTPUT)"

# Test 9 (V-GUARD-PARTIAL-NOTE): partial:true entry → guard emits PARTIAL-READ NOTE
> "$CACHE"
echo "{\"path\":\"$TMPFILE\",\"ts\":$NOW,\"source\":\"read\",\"partial\":true}" >> "$CACHE"
OUTPUT=$(echo "$GUARD_INPUT" | HOME="$TMPHOME" node "$GUARD")
echo "$OUTPUT" | jq -e '.hookSpecificOutput.additionalContext | test("PARTIAL-READ NOTE")' >/dev/null \
  || cleanup_fail "V-GUARD-PARTIAL-NOTE: partial entry did not emit PARTIAL-READ NOTE: $OUTPUT"

# Test 10 (V-GUARD-NO-READ-STRONG): empty cache, file exists → READ-BEFORE-EDIT
> "$CACHE"
OUTPUT=$(echo "$GUARD_INPUT" | HOME="$TMPHOME" node "$GUARD")
echo "$OUTPUT" | jq -e '.hookSpecificOutput.additionalContext | test("READ-BEFORE-EDIT")' >/dev/null \
  || cleanup_fail "V-GUARD-NO-READ-STRONG: empty cache + existing file did not emit READ-BEFORE-EDIT: $OUTPUT"

# Test 11 (V-GUARD-LEGACY-PATH): primary cache empty, LEGACY cache has full-read → suppress (D-01)
> "$CACHE"
LEGACY_CACHE="$TMPHOME/.claude/read-once/reads.jsonl"
mkdir -p "$(dirname "$LEGACY_CACHE")"
# Legacy entry shape: no `source` field (Boucle hook.sh emits {"path","ts"})
echo "{\"path\":\"$TMPFILE\",\"ts\":$NOW}" >> "$LEGACY_CACHE"
OUTPUT=$(echo "$GUARD_INPUT" | HOME="$TMPHOME" node "$GUARD")
[ -z "$OUTPUT" ] || cleanup_fail "V-GUARD-LEGACY-PATH: legacy cache entry should suppress advisory (D-01 read-both regression): $OUTPUT"

# Test 12 (V-GUARD-NULL-SOURCE): legacy-shape entry {path,ts} without source field → treated as full read (D-07)
# (Test 11 already covered this case; explicit test here documents D-07 invariant)
> "$LEGACY_CACHE"
echo "{\"path\":\"$TMPFILE\",\"ts\":$NOW}" >> "$LEGACY_CACHE"  # legacy schema, no source
OUTPUT=$(echo "$GUARD_INPUT" | HOME="$TMPHOME" node "$GUARD")
[ -z "$OUTPUT" ] || cleanup_fail "V-GUARD-NULL-SOURCE: D-07 null-safety regression — absent source field should = full read: $OUTPUT"

# Test 13 (V-GUARD-WRITE-AS-FULL): {source:"write"} entry → treated as full read (D-08 semantics)
> "$LEGACY_CACHE"
> "$CACHE"
echo "{\"path\":\"$TMPFILE\",\"ts\":$NOW,\"source\":\"write\"}" >> "$CACHE"
OUTPUT=$(echo "$GUARD_INPUT" | HOME="$TMPHOME" node "$GUARD")
[ -z "$OUTPUT" ] || cleanup_fail "V-GUARD-WRITE-AS-FULL: source:write entry should be treated as full read (D-08): $OUTPUT"

# Test 14 (V-TTL-EXPIRY / D-15): entry with ts < NOW-7200 (past TTL) → guard emits READ-BEFORE-EDIT
# Closes the missing middle case in REQ READ-03 coverage between fresh-read-suppress
# and empty-cache-strong. Pre-populate with a stale-but-not-removed entry; the TTL
# filter inside scanCache should exclude it from the accumulator.
> "$CACHE"
> "$LEGACY_CACHE"
STALE_TS=$(( NOW - 8000 ))   # 8000s > 7200s TTL
echo "{\"path\":\"$TMPFILE\",\"ts\":$STALE_TS,\"source\":\"read\"}" >> "$CACHE"
OUTPUT=$(echo "$GUARD_INPUT" | HOME="$TMPHOME" node "$GUARD")
echo "$OUTPUT" | jq -e '.hookSpecificOutput.additionalContext | test("READ-BEFORE-EDIT")' >/dev/null \
  || cleanup_fail "V-TTL-EXPIRY (D-15): past-TTL entry (ts=NOW-8000) should NOT suppress; expected READ-BEFORE-EDIT, got: $OUTPUT"

echo "[PASS] dhx-read-cache.sh: 14/14 assertions (writer 7 + guard 6 + V-TTL-EXPIRY 1)"
exit 0
