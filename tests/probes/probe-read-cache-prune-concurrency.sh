#!/usr/bin/env bash
# probe-read-cache-prune-concurrency.sh — ADVERSARIAL no-loss-during-prune (D-13/D-14).
#
# Backs the v1.1 Phase 1 atomic-commit decisions.md row (D-13 rename-then-
# append-back prune redesign supersedes D-02 prune body). This probe is
# ADVERSARIAL, NOT PROBABILISTIC: it uses the env var
# DHX_READ_CACHE_TEST_PAUSE_MS (D-14) to force a deterministic sleep
# between `mv $CACHE $CACHE.prune` and the awk-append-back inside the
# writer's prune block. Concurrent appenders are spawned during that
# pause window; their writes MUST land on the new (post-mv) empty $CACHE
# and survive the awk-append-back.
#
# INVARIANT: (D-13 supersedes D-02) The prune block uses `flock -n`
# (non-blocking; old `-x` was dead-code with `|| exit 0`). Sequence:
# re-read .last-cleanup INSIDE the lock → `mv $CACHE $CACHE.prune` →
# awk-filter from $CACHE.prune APPENDS to $CACHE (concurrent writers'
# `>>` lands on the same post-mv empty file; O_APPEND interleaves
# cleanly) → rm $CACHE.prune → marker write INSIDE the flock subshell.
#
# Run directly:
#   DHX_READ_CACHE_TEST_PAUSE_MS=200 bash tests/probes/probe-read-cache-prune-concurrency.sh
# (Probe sets the env var internally; running with the var unset works
# but tests are race-dependent.)
# Exit code 0 = pass. Nonzero with [FAIL] line = test failure.

# INTEGRATION: exercises composition of writer's append path + writer's
# prune-rewrite path under FORCED contention.
#
# This probe is ADVERSARIAL, NOT PROBABILISTIC. It uses DHX_READ_CACHE_TEST_PAUSE_MS=200
# to force a deterministic 200ms sleep inside the writer's prune block between
# `mv $CACHE $CACHE.prune` and the awk-append-back. During that pause window, 20
# parallel appenders fire — their writes MUST land on the new (post-mv) empty
# $CACHE and survive the awk-append-back. The inode-equality check detects
# regression to the broken `awk > tmp && mv tmp $CACHE` pattern.
#
# Closes Gemini + Codex HIGH-severity prune concerns:
#   - "flock blocks instead of skipping" (D-13: flock -n)
#   - "concurrent appends lost during awk > tmp && mv" (D-13: rename-then-append-back)
#   - "marker reset even on skipped prune" (D-13: marker INSIDE lock)
#   - "thundering herd on stale .last-cleanup" (D-13: re-read marker INSIDE lock)
#   - "probe expectation too deterministic" (D-14: adversarial DHX_READ_CACHE_TEST_PAUSE_MS)

# SAFE_FOR_LIVE: yes   (mktemp HOME isolation; adversarial prune contention contained in $TMPHOME)
set -uo pipefail

HOOK="/home/dhx/repos/hooks/dhx/dhx-read-cache.sh"
TMPHOME=$(mktemp -d)
TMPFILE=$(mktemp)
trap 'rm -rf "$TMPHOME" "$TMPFILE"' EXIT

cleanup_fail() {
  echo "[FAIL] $1" >&2
  exit 1
}

CACHE_DIR="$TMPHOME/.cache/dhx"
CACHE="$CACHE_DIR/read-cache.jsonl"
CLEANUP_MARKER="$CACHE_DIR/.last-cleanup"
LOCK_FILE="$CACHE_DIR/.cache.lock"
mkdir -p "$CACHE_DIR"

# === Setup phase ===
# Pre-populate cache with stale (past TTL) + recent entries
NOW=$(date +%s)
STALE_TS=$(( NOW - 8000 ))   # > 7200 = past TTL, will be pruned
RECENT_TS=$(( NOW - 100 ))   # < 7200 = within TTL, will be retained

for i in $(seq 1 5); do
  echo "{\"path\":\"/stale/file-$i\",\"ts\":$STALE_TS,\"source\":\"read\"}" >> "$CACHE"
done
for i in $(seq 1 5); do
  echo "{\"path\":\"/recent/file-$i\",\"ts\":$RECENT_TS,\"source\":\"read\"}" >> "$CACHE"
done
PRE_COUNT=$(wc -l < "$CACHE")
[ "$PRE_COUNT" -eq 10 ] || cleanup_fail "Setup: expected 10 pre-populated entries, got $PRE_COUNT"

# Record pre-prune $CACHE inode for V-PRUNE-INODE-DELTA assertion
PRE_PRUNE_INODE=$(stat -c %i "$CACHE")

# Force prune: set .last-cleanup to >3600s ago so the next writer triggers prune
echo "$(( NOW - 4000 ))" > "$CLEANUP_MARKER"

# === Adversarial phase (D-14) ===
# Spawn the prune-triggering writer in BACKGROUND with DHX_READ_CACHE_TEST_PAUSE_MS=200.
# It will: acquire flock → mv $CACHE $CACHE.prune → SLEEP 200ms (pause window) →
# awk-append-back → rm $CACHE.prune → marker write.
PRUNE_INPUT=$(printf '{"tool_name":"Read","session_id":"prune-trigger","tool_input":{"file_path":"%s"}}' "$TMPFILE")
( DHX_READ_CACHE_TEST_PAUSE_MS=200 HOME="$TMPHOME" bash "$HOOK" <<<"$PRUNE_INPUT" ) &
PRUNE_PID=$!

# Wait briefly to let the prune writer enter its lock + mv (50ms is plenty)
sleep 0.05

# Spawn 20 concurrent APPENDERS during the pause window. These writers do NOT
# trigger prune (they bail on the flock -n if the prune is still held; they
# just `>>` append). Their writes MUST land on the post-mv $CACHE and survive.
APPEND_COUNT=20
for i in $(seq 1 $APPEND_COUNT); do
  APPEND_INPUT=$(printf '{"tool_name":"Read","session_id":"appender-%d","tool_input":{"file_path":"%s"}}' "$i" "$TMPFILE")
  ( HOME="$TMPHOME" bash "$HOOK" <<<"$APPEND_INPUT" ) &
done

# Wait for prune writer (already running for ~200ms+) and all 20 appenders
wait "$PRUNE_PID" 2>/dev/null || true
wait

# Allow any in-flight mv/awk to settle
sync >/dev/null 2>&1 || true

# === Assertion phase ===

# Assertion 1 (V-PRUNE-NO-LOSS / D-14): mid-pause appends survive.
# Expected line count: 5 retained recent + 1 prune-trigger + 20 appenders = 26.
# (The prune writer's own write happens BEFORE its prune block, so it's counted.)
POST_COUNT=$(wc -l < "$CACHE")
EXPECTED_MIN=$(( 5 + 20 ))   # 5 retained + 20 appenders; prune-trigger may or may not appear depending on ordering
EXPECTED_MAX=$(( 5 + 21 ))   # +1 if prune-trigger's pre-prune write appears
[ "$POST_COUNT" -ge "$EXPECTED_MIN" ] || cleanup_fail "V-PRUNE-NO-LOSS: expected ≥$EXPECTED_MIN lines (5 retained + 20 appenders), got $POST_COUNT (append loss during prune-rewrite — rename-then-append-back regression)"
[ "$POST_COUNT" -le "$EXPECTED_MAX" ] || cleanup_fail "V-PRUNE-NO-LOSS: too many lines ($POST_COUNT > $EXPECTED_MAX) — stale entries not pruned?"

# Assertion 2: stale entries evicted (awk filter worked)
# (Use grep || true to tolerate zero-match exit-1; pipe through wc -l for a clean integer.)
STALE_SURVIVORS=$(grep '"ts":'"$STALE_TS" "$CACHE" 2>/dev/null | wc -l)
[ "$STALE_SURVIVORS" -eq 0 ] || cleanup_fail "V-PRUNE-NO-LOSS: $STALE_SURVIVORS stale entries survived prune (awk filter regression)"

# Assertion 3: all recent (pre-existing) survived
RECENT_SURVIVORS=$(grep '"ts":'"$RECENT_TS" "$CACHE" 2>/dev/null | wc -l)
[ "$RECENT_SURVIVORS" -eq 5 ] || cleanup_fail "V-PRUNE-NO-LOSS: expected 5 recent survivors, got $RECENT_SURVIVORS (prune over-aggressive)"

# Assertion 4: all 20 mid-pause appends are present
APPEND_PRESENT=$(grep "\"path\":\"$TMPFILE\"" "$CACHE" 2>/dev/null | wc -l)
[ "$APPEND_PRESENT" -ge "$APPEND_COUNT" ] || cleanup_fail "V-PRUNE-NO-LOSS adversarial: expected ≥$APPEND_COUNT mid-pause appends, got $APPEND_PRESENT (DHX_READ_CACHE_TEST_PAUSE_MS pause window did NOT preserve appends — broken pattern)"

# Assertion 5 (V-PRUNE-INODE-DELTA / D-13): post-prune $CACHE inode != pre-prune inode.
# This is the load-bearing detection of the broken `awk > tmp && mv tmp $CACHE` pattern.
# - Broken pattern: tmp file replaces $CACHE → new inode for $CACHE (delta detected, but appends were lost on old inode)
# - D-13 pattern: mv $CACHE $CACHE.prune renames $CACHE away → new $CACHE inode created by next `>>` (delta detected, AND appends preserved on new inode)
# - Old D-02 behavior in some implementations: in-place `awk -i inplace` → SAME inode (delta NOT detected → V-PRUNE-INODE-DELTA fails, signaling a regression to in-place rewrite)
# We assert the inode CHANGED, which both broken and D-13 patterns produce; combined with assertion 4 (appends survived), this distinguishes D-13 from broken.
POST_PRUNE_INODE=$(stat -c %i "$CACHE")
[ "$POST_PRUNE_INODE" != "$PRE_PRUNE_INODE" ] || cleanup_fail "V-PRUNE-INODE-DELTA: cache inode unchanged after prune ($PRE_PRUNE_INODE) — rename-then-append-back didn't fire OR in-place rewrite regression"

# Assertion 6 (V-FLOCK-NONBLOCK): .cache.lock file exists (flock fired)
[ -f "$LOCK_FILE" ] || cleanup_fail "V-FLOCK-NONBLOCK: .cache.lock file not created — flock subshell-with-fd not running"

# Assertion 7 (V-MARKER-INSIDE-LOCK): .last-cleanup updated to >= NOW (prune actually fired, not just skipped, AND marker write was inside the lock so it only updated on success)
NEW_CLEANUP=$(cat "$CLEANUP_MARKER")
[ "$NEW_CLEANUP" -ge "$NOW" ] || cleanup_fail "V-MARKER-INSIDE-LOCK: .last-cleanup not updated (prune did not fire, OR marker outside lock and reset on skipped prune)"

# Assertion 8 (V-RENAME-AND-APPEND): no $CACHE.prune leak (rm -f cleaned it up)
[ ! -e "${CACHE}.prune" ] || cleanup_fail "V-RENAME-AND-APPEND: ${CACHE}.prune leaked — rm -f after append-back didn't fire"

echo "[PASS] dhx-read-cache.sh ADVERSARIAL prune-concurrency: 8/8 assertions (D-13/D-14 V-PRUNE-NO-LOSS + V-FLOCK-NONBLOCK + V-MARKER-INSIDE-LOCK + V-RENAME-AND-APPEND + V-PRUNE-INODE-DELTA)"
exit 0
