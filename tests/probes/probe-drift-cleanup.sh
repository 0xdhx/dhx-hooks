#!/bin/bash
# Probes the orphan-drift-snapshot sweep in dhx-health-check.sh. Exercises:
#   A. Orphan detection: filename ticks not in live-CC set → deleted (when
#      mtime >1h)
#   B. Grace window: orphan ticks with mtime <1h → survive (defensive for
#      newly-starting CC processes whose snapshot hasn't aged into the sweep)
#   C. Legacy format (no -p<ticks> suffix): only the 30d sweep prunes — <30d
#      survives, >30d deleted
#   D. Live tick survives (when a real CC process is running; skipped on CI
#      where pgrep returns empty)
#   E. Session-scoped clear unchanged: this session's snapshots deleted
#      regardless of age via the glob at L126
#
# Fake HOME isolates the cache — no live snapshots touched. /proc is real
# (can't cheaply stub); live-tick case samples the current system.
#
# Backs: docs/decisions.md 2026-04-19 drift-cache orphan-sweep row.

set -u

HOOK="$(cd "$(dirname "$0")/../.." && pwd)/dhx/dhx-health-check.sh"
[[ -x "$HOOK" ]] || { echo "FAIL: hook not found/executable at $HOOK"; exit 1; }

TMPHOME=$(mktemp -d)
trap 'rm -rf "$TMPHOME"' EXIT

CACHE="$TMPHOME/.cache/dhx"
mkdir -p "$CACHE"

# Known-orphan ticks: use tiny values that can't plausibly match a live
# multi-month-uptime CC process (real ticks on this machine are 8-digit).
ORPHAN_TICK_OLD=11
ORPHAN_TICK_NEW=22
ORPHAN_TICK_30D_LEGACY=33
NOW=$(date +%s)

# Find a LIVE CC tick if any CC process is running. On CI or a clean box this
# will be empty; skip the live-survival case in that scenario.
LIVE_TICK=$(for pid in $(pgrep -f 'bin/claude' 2>/dev/null); do
  awk '{print $22}' /proc/"$pid"/stat 2>/dev/null
done | sort -u | head -1)

# Fabricate files with specific mtimes via touch -d
mk() {
  local name="$1" age_sec="$2"
  local f="$CACHE/$name"
  echo '{}' > "$f"
  touch -d "@$((NOW - age_sec))" "$f"
  echo "$f"
}

# --- Fixtures ---
F_ORPHAN_OLD=$(mk "drift-snapshot-aaaa1111-2222-3333-4444-555566667777-p${ORPHAN_TICK_OLD}.json" $((2 * 3600)))   # 2h old — should delete
F_ORPHAN_GRACE=$(mk "drift-snapshot-bbbb1111-2222-3333-4444-555566667777-p${ORPHAN_TICK_NEW}.json" 1800)           # 30min old — grace survives
F_LEGACY_YOUNG=$(mk "drift-snapshot-cccc1111-2222-3333-4444-555566667777.json" $((5 * 86400)))                     # 5d old, no -p suffix — survives (no sweep covers it)
F_LEGACY_OLD=$(mk "drift-snapshot-dddd1111-2222-3333-4444-555566667777.json" $((35 * 86400)))                      # 35d old, no -p suffix — 30d sweep deletes
F_TICKS_OLD_BUT_30D=$(mk "drift-snapshot-eeee1111-2222-3333-4444-555566667777-p${ORPHAN_TICK_30D_LEGACY}.json" $((35 * 86400)))  # 35d old WITH -p suffix — orphan sweep OR 30d sweep delete

# Live-tick survival fixture (only if we found a live CC)
F_LIVE=""
if [[ -n "$LIVE_TICK" ]]; then
  F_LIVE=$(mk "drift-snapshot-ffff1111-2222-3333-4444-555566667777-p${LIVE_TICK}.json" $((2 * 3600)))              # 2h old with LIVE tick — must survive
fi

# Malformed filename (no recognizable tick suffix format) — defensive
F_MALFORMED=$(mk "drift-snapshot-garbage-pno-digits.json" $((2 * 3600)))                                           # survives (regex won't match)

# --- Invoke hook under fake HOME ---
# session_id absent from stdin so the session-scoped clear at L126 is a no-op
# for THIS probe (we want to isolate the orphan-sweep path). Use empty JSON.
echo '{}' | HOME="$TMPHOME" bash "$HOOK"

# --- Assertions ---
PASS=0
FAIL=0
assert_exists() {
  local f="$1" name="$2"
  if [[ -f "$f" ]]; then
    printf '  \u2713 %s — survived\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  \u2717 %s — unexpectedly deleted\n' "$name"
    FAIL=$((FAIL + 1))
  fi
}
assert_gone() {
  local f="$1" name="$2"
  if [[ ! -f "$f" ]]; then
    printf '  \u2713 %s — deleted\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  \u2717 %s — unexpectedly survived\n' "$name"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== A. Orphan sweep (live_ticks cross-check) ==="
assert_gone   "$F_ORPHAN_OLD"         "orphan ticks, 2h old"

echo "=== B. Grace window ==="
assert_exists "$F_ORPHAN_GRACE"       "orphan ticks, 30min old (within 1h grace)"

echo "=== C. Legacy no-suffix format (30d sweep only) ==="
assert_exists "$F_LEGACY_YOUNG"       "no -p suffix, 5d old"
assert_gone   "$F_LEGACY_OLD"         "no -p suffix, 35d old"
assert_gone   "$F_TICKS_OLD_BUT_30D"  "orphan ticks, 35d old — one of two sweeps gets it"

echo "=== D. Live-tick survival (skipped when no CC running) ==="
if [[ -n "$F_LIVE" ]]; then
  assert_exists "$F_LIVE" "live CC tick $LIVE_TICK, 2h old"
else
  printf '  -- skip -- no live CC process available on this host\n'
fi

echo "=== E. Malformed filename (defensive — regex no-match) ==="
assert_exists "$F_MALFORMED"          "drift-snapshot-garbage-pno-digits.json (no tick suffix matched)"

echo ""
echo "PASS: $PASS  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
