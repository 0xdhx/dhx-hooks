#!/usr/bin/env bash
# probe-read-cache-cross-session.sh — verify CCS-swap regression (global TTL).
#
# Asserts (REQ READ-03,
# READ-11) that the
# guard's cache lookup is purely TTL-based (NOT session-scoped) so that
# session_id changes from CCS instance swaps don't trigger false-positive
# READ-BEFORE-EDIT advisories.
#
# INVARIANT: cache TTL=7200s, $HOME-invariant XDG path, no session_id
# branching. Writer with session_id="aaa" feeds cache; guard with same/
# different/absent session_id all suppress when the entry is within TTL.
#
# Run directly:
#   bash tests/probes/probe-read-cache-cross-session.sh
# Exit code 0 = pass. Nonzero with [FAIL] line = test failure.

# INTEGRATION: exercises composition of writer + guard across simulated
# session_id changes. Per tests/probes/README.md § Integration probes.

# SAFE_FOR_LIVE: yes   (mktemp HOME isolation; CCS-swap simulation contained in $TMPHOME)
set -uo pipefail

HOOK="/home/dhx/repos/hooks/dhx/dhx-read-cache.sh"
GUARD="/home/dhx/repos/hooks/dhx/dhx-read-guard.js"
TMPHOME=$(mktemp -d)
TMPFILE=$(mktemp)
trap 'rm -rf "$TMPHOME" "$TMPFILE"' EXIT

cleanup_fail() {
  echo "[FAIL] $1" >&2
  exit 1
}

CACHE="$TMPHOME/.cache/dhx/read-cache.jsonl"
mkdir -p "$TMPHOME/.cache/dhx"

# V-CCS-SWAP (REQ READ-03, READ-11): the global TTL design must NOT regress
# to session-scoped behavior. Backed by reports/done/2026-04-15-read-guard-
# session-scoping-false-positives.md — the load-bearing citation for this
# decision. CCS instance swap = different session_id; the guard MUST suppress
# regardless of session_id.

# Step 1: writer with session_id="aaa" populates the cache
INPUT=$(printf '{"tool_name":"Read","session_id":"aaa","tool_input":{"file_path":"%s"}}' "$TMPFILE")
echo "$INPUT" | HOME="$TMPHOME" bash "$HOOK"
[ -f "$CACHE" ] || cleanup_fail "Writer did not create cache for session_id=aaa"

# Step 2: guard with SAME session_id="aaa" → suppress
GUARD_INPUT_SAME=$(printf '{"tool_name":"Edit","session_id":"aaa","tool_input":{"file_path":"%s"}}' "$TMPFILE")
OUTPUT=$(echo "$GUARD_INPUT_SAME" | HOME="$TMPHOME" node "$GUARD")
[ -z "$OUTPUT" ] || cleanup_fail "V-CCS-SWAP: guard with same session_id should suppress: $OUTPUT"

# Step 3: guard with DIFFERENT session_id="bbb" → suppress (proves global TTL, not session-keyed)
GUARD_INPUT_DIFF=$(printf '{"tool_name":"Edit","session_id":"bbb","tool_input":{"file_path":"%s"}}' "$TMPFILE")
OUTPUT=$(echo "$GUARD_INPUT_DIFF" | HOME="$TMPHOME" node "$GUARD")
[ -z "$OUTPUT" ] || cleanup_fail "V-CCS-SWAP: guard with different session_id MUST suppress (global TTL design — 2026-04-15 fix regression): $OUTPUT"

# Step 4: guard with ABSENT session_id → suppress (proves no session_id requirement)
GUARD_INPUT_NONE=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$TMPFILE")
OUTPUT=$(echo "$GUARD_INPUT_NONE" | HOME="$TMPHOME" node "$GUARD")
[ -z "$OUTPUT" ] || cleanup_fail "V-CCS-SWAP: guard with absent session_id MUST suppress (global TTL design): $OUTPUT"

# Step 5: NEGATIVE control — different file_path with no cache entry → READ-BEFORE-EDIT
# (Confirms the guard isn't broken-suppress-everything; only suppresses for cached paths)
OTHER_FILE=$(mktemp)
trap 'rm -rf "$TMPHOME" "$TMPFILE" "$OTHER_FILE"' EXIT
GUARD_INPUT_OTHER=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$OTHER_FILE")
OUTPUT=$(echo "$GUARD_INPUT_OTHER" | HOME="$TMPHOME" node "$GUARD")
echo "$OUTPUT" | jq -e '.hookSpecificOutput.additionalContext | test("READ-BEFORE-EDIT")' >/dev/null \
  || cleanup_fail "V-CCS-SWAP negative control: uncached file should emit READ-BEFORE-EDIT: $OUTPUT"

echo "[PASS] dhx-read-cache cross-session: 4/4 assertions (V-CCS-SWAP + negative control)"
exit 0
