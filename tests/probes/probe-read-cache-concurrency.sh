#!/usr/bin/env bash
# probe-read-cache-concurrency.sh — verify O_APPEND atomicity under 50-writer load.
#
# Backs the v1.1 Phase 1 atomic-commit decisions.md row (REQ READ-06,
# READ-10). Asserts that 50 concurrent dhx-read-cache.sh writers appending
# to the same ~/.cache/dhx/read-cache.jsonl produce 50 well-formed JSONL
# lines with zero corruption — the foundational invariant supporting
# REQ READ-06's "no flock for atomic appends" decision.
#
# INVARIANT: bash `>>` is one open(O_APPEND)+write() per invocation, atomic
# up to PIPE_BUF=4096 on Linux/WSL2 ext4. The 20-writer × 50-line probe of
# 2026-04-25 verified zero corruption; this probe escalates to 50 concurrent
# writers as the formal regression gate.
#
# Run directly:
#   bash tests/probes/probe-read-cache-concurrency.sh
# Exit code 0 = pass. Nonzero with [FAIL] line = test failure.

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

# V-APPEND-50: 50 concurrent writers, each appending 1 entry; assert wc -l == 50
# AND every line round-trips through jq -c .
#
# Per REQ READ-06: bash `>>` is atomic up to PIPE_BUF=4096 on Linux/WSL2 ext4.
# This probe is the formal regression gate for that invariant (escalates the
# 20-writer × 50-line probe of 2026-04-25 to 50 concurrent writers).

mkdir -p "$TMPHOME/.cache/dhx"

# Spawn 50 background subshells, each invoking the writer with a unique session_id
# but the same file_path (50 entries for one file is fine — each entry is independent)
for i in $(seq 1 50); do
  INPUT=$(printf '{"tool_name":"Read","session_id":"concurrent-%d","tool_input":{"file_path":"%s"}}' "$i" "$TMPFILE")
  ( echo "$INPUT" | HOME="$TMPHOME" bash "$HOOK" ) &
done
wait

# Assertion 1: line count is exactly 50
LINE_COUNT=$(wc -l < "$CACHE")
[ "$LINE_COUNT" -eq 50 ] || cleanup_fail "V-APPEND-50: expected 50 lines, got $LINE_COUNT (atomicity regression)"

# Assertion 2: every line is well-formed JSON (no interleaved bytes from concurrent writes)
MALFORMED=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  echo "$line" | jq -c . >/dev/null 2>&1 || MALFORMED=$((MALFORMED + 1))
done < "$CACHE"
[ "$MALFORMED" -eq 0 ] || cleanup_fail "V-APPEND-50: $MALFORMED malformed lines (PIPE_BUF=4096 violated?)"

# Assertion 3: every line has the expected schema (source:"read", path matches)
SCHEMA_ERRORS=$(jq -c "select(.source != \"read\" or .path != \"$TMPFILE\")" "$CACHE" 2>/dev/null | wc -l)
[ "$SCHEMA_ERRORS" -eq 0 ] || cleanup_fail "V-APPEND-50: $SCHEMA_ERRORS lines failed schema check"

echo "[PASS] dhx-read-cache.sh concurrency: 3/3 assertions (50 writers, 0 malformed, 0 schema errors)"
exit 0
