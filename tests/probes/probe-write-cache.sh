#!/usr/bin/env bash
# probe-write-cache.sh — verify dhx-write-cache.sh appends correctly.
#
# Asserts dhx-write-cache.sh PostToolUse
# cache populator for read-guard false-positive fix" + the v1.1 Phase 1
# Option B atomic-commit row (D-08 source field, D-11 in-place modify).
# Asserts that the hook emits {"path":<abs>,"ts":<unix>,"source":"write"}
# at the new XDG cache path ~/.cache/dhx/read-cache.jsonl, matching the
# D-08 schema parity invariant in dhx-read-guard.js header.
#
# V-WRITE-XDG-PATH: cache file at $TMPHOME/.cache/dhx/read-cache.jsonl
# V-WRITE-SOURCE-FIELD: every appended entry has source:"write"
#
# Run directly:
#   bash tests/probes/probe-write-cache.sh
# Exit code 0 = pass. Nonzero with a [FAIL] line = test failure.

set -uo pipefail

HOOK="/home/dhx/repos/hooks/dhx/dhx-write-cache.sh"
TMPHOME=$(mktemp -d)
TMPFILE=$(mktemp)
trap 'rm -rf "$TMPHOME" "$TMPFILE"' EXIT

cleanup_fail() {
  echo "[FAIL] $1" >&2
  exit 1
}

# Test 1: Write tool input populates cache
INPUT=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$TMPFILE")
echo "$INPUT" | HOME="$TMPHOME" bash "$HOOK"
RC=$?
[ "$RC" -eq 0 ] || cleanup_fail "Write hook exited nonzero ($RC)"

CACHE="$TMPHOME/.cache/dhx/read-cache.jsonl"
[ -f "$CACHE" ] || cleanup_fail "Write did not create cache file at $CACHE"

LINE=$(tail -1 "$CACHE")
echo "$LINE" | jq -e --arg p "$TMPFILE" '.path == $p and (.ts | type == "number") and .source == "write"' >/dev/null \
  || cleanup_fail "V-WRITE-SOURCE-FIELD: Write cache entry malformed or missing source:write: $LINE"

# Test 2: Edit tool input also populates cache
INPUT=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$TMPFILE")
echo "$INPUT" | HOME="$TMPHOME" bash "$HOOK"
[ "$(wc -l < "$CACHE")" -eq 2 ] || cleanup_fail "Edit did not append a second cache entry"

# Test 3: non-Write/Edit tools are ignored
INPUT=$(printf '{"tool_name":"Bash","tool_input":{"file_path":"%s"}}' "$TMPFILE")
echo "$INPUT" | HOME="$TMPHOME" bash "$HOOK"
[ "$(wc -l < "$CACHE")" -eq 2 ] || cleanup_fail "Bash invocation should not have written to cache"

# Test 4: missing file_path is ignored without crashing
INPUT='{"tool_name":"Write","tool_input":{}}'
echo "$INPUT" | HOME="$TMPHOME" bash "$HOOK"
RC=$?
[ "$RC" -eq 0 ] || cleanup_fail "Missing file_path crashed hook (rc=$RC)"
[ "$(wc -l < "$CACHE")" -eq 2 ] || cleanup_fail "Missing file_path silently appended cache entry"

# Test 5: emitted path is absolute (realpath-resolved when possible)
RELDIR=$(mktemp -d)
RELFILE="$RELDIR/relfile.md"
touch "$RELFILE"
INPUT=$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$RELFILE")
echo "$INPUT" | HOME="$TMPHOME" bash "$HOOK"
LAST=$(tail -1 "$CACHE")
EMITTED=$(echo "$LAST" | jq -r '.path')
[ "${EMITTED:0:1}" = "/" ] || cleanup_fail "Emitted path is not absolute: $EMITTED"
rm -rf "$RELDIR"

# Test 6 (V-WRITE-XDG-PATH): cache file is at the new XDG path, NOT legacy read-once
LEGACY="$TMPHOME/.claude/read-once/reads.jsonl"
[ ! -f "$LEGACY" ] || cleanup_fail "V-WRITE-XDG-PATH: writer regressed to legacy path $LEGACY"
[ -f "$CACHE" ] || cleanup_fail "V-WRITE-XDG-PATH: cache not at new XDG path $CACHE"

# Test 7 (V-WRITE-SOURCE-FIELD): every entry has source:"write"
ENTRIES_WITH_SOURCE=$(jq -c 'select(.source == "write")' "$CACHE" 2>/dev/null | wc -l)
TOTAL_ENTRIES=$(wc -l < "$CACHE")
[ "$ENTRIES_WITH_SOURCE" -eq "$TOTAL_ENTRIES" ] || cleanup_fail "V-WRITE-SOURCE-FIELD: $ENTRIES_WITH_SOURCE/$TOTAL_ENTRIES entries have source:write"

# Test 8 (D-17 V-PARTIAL-WRITE-INVARIANT): NO entry has both partial:true and source:write
FORBIDDEN_COMBO=$(jq -c 'select(.source == "write" and .partial == true)' "$CACHE" 2>/dev/null | wc -l)
[ "$FORBIDDEN_COMBO" -eq 0 ] || cleanup_fail "D-17 V-PARTIAL-WRITE-INVARIANT: $FORBIDDEN_COMBO entries have partial:true + source:write (writer regression)"

echo "[PASS] dhx-write-cache.sh: 8/8 assertions (incl. V-WRITE-XDG-PATH + V-WRITE-SOURCE-FIELD + D-17 V-PARTIAL-WRITE-INVARIANT)"
