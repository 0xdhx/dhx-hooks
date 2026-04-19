#!/usr/bin/env bash
# probe-write-cache.sh — verify dhx-write-cache.sh appends correctly.
#
# Backs the 2026-04-19 decisions.md row "dhx-write-cache.sh: PostToolUse
# cache populator for read-guard false-positive fix". Asserts that the
# hook emits a {"path":<abs>,"ts":<unix>} entry matching the schema
# dhx-read-guard.js:14 expects (INVARIANT in dhx-write-cache.sh header).
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

CACHE="$TMPHOME/.claude/read-once/reads.jsonl"
[ -f "$CACHE" ] || cleanup_fail "Write did not create cache file at $CACHE"

LINE=$(tail -1 "$CACHE")
echo "$LINE" | jq -e --arg p "$TMPFILE" '.path == $p and (.ts | type == "number")' >/dev/null \
  || cleanup_fail "Write cache entry malformed: $LINE"

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

echo "[PASS] dhx-write-cache.sh: 5/5 assertions"
