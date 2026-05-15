#!/usr/bin/env bash
# probe-read-cache-lock-sh-race.sh — DETERMINISTIC writer-pruner race reproducer.
#
# Backs the 2026-05-08 LOCK_SH precision-narrowing decision (D-25), which
# closes the pre-mv-open + post-awk-EOF write race that caused the
# 2026-05-08 probe-read-cache-concurrency.sh 49/50 flake under heavy
# parallel load (reports/done/2026-05-08-v-append-50-read-cache-concurrency-flake.md).
#
# REQ READ-06's O_APPEND atomicity invariant is preserved (writer-writer
# non-contention via LOCK_SH — multiple shared holders run in parallel);
# the LOCK_SH closes the writer-pruner coordination gap (D-13's
# `flock -n 200` was scope-disjoint from the per-write `>>` path).
#
# INVARIANT: per-write `>>` acquires LOCK_SH on $LOCK BEFORE open(). Pruner's
# LOCK_EX (`flock -n 200`) skips when any LOCK_SH holder is active,
# eliminating the race where a writer's open() lands pre-mv but write()
# lands post-awk-EOF (orphan inode I1, unlinked by `rm -f $CACHE.prune`).
#
# Race timeline (pre-fix, deterministic with DHX_READ_CACHE_TEST_OPEN_TO_WRITE_MS):
#   T=0   : writer A enters hook with OPEN_TO_WRITE_MS=300 → exec 9>>$CACHE
#           → FD on inode I1 → sleep 300ms.
#   T=50ms: writer B (regular) enters hook → jq fork → write to I1 → outer
#           gate passes (marker stale) → flock -n 200 → mv I1→$CACHE.prune →
#           awk reads I1 (sees B's write only; A hasn't written) → appends
#           to new I2 → rm -f $CACHE.prune (I1 unlinked from filesystem).
#   T=300ms: writer A wakes → jq write to FD 9 (orphan I1) → close FD → I1 freed.
#   Result: A's write LOST. wc -l = 4 (3 recent + B's write).
#
# Race timeline (post-fix, deterministic):
#   T=0   : writer A acquires LOCK_SH → exec 9 → sleep 300ms.
#   T=50ms: writer B acquires LOCK_SH (shared, multi-holder OK) → write to
#           I1 → release LOCK_SH.
#   T=52ms: writer B's flock -n 200 (exclusive) → FAILS (A holds LOCK_SH) →
#           prune block exits, marker NOT updated.
#   T=300ms: writer A wakes → jq write to FD 9 (still on I1, no mv) → close
#            FD → release LOCK_SH.
#   T=300+: writer A's outer gate passes (marker still stale) → flock -n 200
#           acquires LOCK_EX → mv → awk → rm-f. All writes preserved.
#   Result: wc -l = 5 (3 recent + A's write + B's write).
#
# Run directly:
#   bash tests/probes/probe-read-cache-lock-sh-race.sh
# Exit code 0 = pass. Nonzero with [FAIL] = test failure.

# SAFE_FOR_LIVE: yes   (mktemp HOME isolation; race contained in $TMPHOME)
set -uo pipefail

HOOK="/home/dhx/repos/hooks/dhx/dhx-read-cache.sh"
TMPHOME=$(mktemp -d)
TMPFILE_A=$(mktemp)
TMPFILE_B=$(mktemp)
trap 'rm -rf "$TMPHOME" "$TMPFILE_A" "$TMPFILE_B"' EXIT

cleanup_fail() {
  echo "[FAIL] $1" >&2
  exit 1
}

CACHE_DIR="$TMPHOME/.cache/dhx"
CACHE="$CACHE_DIR/read-cache.jsonl"
CLEANUP_MARKER="$CACHE_DIR/.last-cleanup"
mkdir -p "$CACHE_DIR"

# === Setup ===
# Pre-populate cache with recent entries (prune retains them as TS > NOW-7200).
# Force prune by setting .last-cleanup stale (>3600s ago).
NOW=$(date +%s)
RECENT_TS=$(( NOW - 100 ))
for i in $(seq 1 3); do
  echo "{\"path\":\"/recent/file-$i\",\"ts\":$RECENT_TS,\"source\":\"read\"}" >> "$CACHE"
done
echo "$(( NOW - 4000 ))" > "$CLEANUP_MARKER"

# === Race trigger ===
# Writer A: slow per-write (DHX_READ_CACHE_TEST_OPEN_TO_WRITE_MS=300 splits
# open() from write() — A's FD lands on the original $CACHE inode, then A
# sleeps 300ms before writing. Pre-fix: no LOCK_SH means A's FD-open is
# unprotected. Post-fix: LOCK_SH-wrapped, blocks pruner's LOCK_EX.
A_INPUT=$(printf '{"tool_name":"Read","tool_input":{"file_path":"%s"}}' "$TMPFILE_A")
( DHX_READ_CACHE_TEST_OPEN_TO_WRITE_MS=300 HOME="$TMPHOME" bash "$HOOK" <<<"$A_INPUT" ) &
A_PID=$!

# Wait for A to enter its slow-write phase (open FD, start sleeping).
# 50ms is plenty: A's hook startup (cat stdin + 1 jq fork + mkdir + realpath
# + TS) is ~3-5ms on tmpfs.
sleep 0.05

# Writer B: regular per-write. Triggers prune (outer gate stale).
# Pre-fix: B's prune mvs/rms inode I1 while A's FD is still open on it.
# Post-fix: B's flock -n 200 fails (A holds LOCK_SH); prune skipped.
B_INPUT=$(printf '{"tool_name":"Read","tool_input":{"file_path":"%s"}}' "$TMPFILE_B")
( HOME="$TMPHOME" bash "$HOOK" <<<"$B_INPUT" ) &
B_PID=$!

wait "$A_PID" 2>/dev/null || true
wait "$B_PID" 2>/dev/null || true

# === Assertions ===

# Assertion 1 (V-LOCK-SH-RACE): writer A's write is present.
# Pre-fix: A's write lost (orphan inode unlinked by B's rm -f).
# Post-fix: A's write preserved (LOCK_SH blocked B's prune; A wrote to live $CACHE).
A_PRESENT=$(grep "\"path\":\"$TMPFILE_A\"" "$CACHE" 2>/dev/null | wc -l)
[ "$A_PRESENT" -eq 1 ] || cleanup_fail "V-LOCK-SH-RACE: writer A's write missing from \$CACHE (got $A_PRESENT, expected 1) — pre-mv-open + post-awk-EOF race fired (LOCK_SH coordination gap between writer's per-write and pruner's mv→awk→rm)"

# Assertion 2: writer B's write is present.
B_PRESENT=$(grep "\"path\":\"$TMPFILE_B\"" "$CACHE" 2>/dev/null | wc -l)
[ "$B_PRESENT" -eq 1 ] || cleanup_fail "V-LOCK-SH-RACE: writer B's write missing (got $B_PRESENT, expected 1)"

# Assertion 3: pre-existing recent entries retained (prune awk preserved them).
RECENT_PRESENT=$(grep "\"path\":\"/recent/" "$CACHE" 2>/dev/null | wc -l)
[ "$RECENT_PRESENT" -eq 3 ] || cleanup_fail "V-LOCK-SH-RACE: pre-existing recent entries missing (got $RECENT_PRESENT, expected 3)"

# Assertion 4: line count is exactly 5 (3 recent + A + B).
LINE_COUNT=$(wc -l < "$CACHE")
[ "$LINE_COUNT" -eq 5 ] || cleanup_fail "V-LOCK-SH-RACE: expected 5 lines (3 recent + A + B), got $LINE_COUNT"

# Assertion 5: every line is well-formed JSON.
MALFORMED=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  echo "$line" | jq -c . >/dev/null 2>&1 || MALFORMED=$((MALFORMED + 1))
done < "$CACHE"
[ "$MALFORMED" -eq 0 ] || cleanup_fail "V-LOCK-SH-RACE: $MALFORMED malformed lines"

echo "[PASS] dhx-read-cache.sh LOCK_SH writer-pruner coordination: 5/5 assertions (V-LOCK-SH-RACE D-25)"
exit 0
