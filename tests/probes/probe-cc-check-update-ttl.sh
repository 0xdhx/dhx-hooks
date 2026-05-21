#!/bin/bash
# SAFE_FOR_LIVE: yes   (mktemp cache dir; CC_CHECK_UPDATE_CACHE env-override injects a fixture cache; never reads or writes live ~/.cache/cc)
#
# Exercises the NET-NEW TTL freshness gate in dhx/cc-check-update.js (RAT-06,
# STATUSLINE-RAT-06). gsd-check-update.js has NO TTL — it spawns the worker on
# every SessionStart; the RAT-06 parent must skip the spawn when the cache's
# checked_at is fresh (< ~6h). This probe asserts that gate across four
# scenarios: fresh -> skip, stale -> spawn, missing/malformed -> spawn,
# future checked_at -> spawn (WR-01 negative-age / clock-skew guard).
#
# Backs Plan 17-02 Task 3 + decision D-11 (SAFE_FOR_LIVE + env-override path
# injection) and D-17 (the parent ships a dedicated CC_CHECK_UPDATE_CACHE
# cache-path seam; this probe consumes that seam — it does not add one).
#
# Run: bash tests/probes/probe-cc-check-update-ttl.sh
#
# Strategy: the probe never invokes the real worker (which does a network
# `npm view`). It copies dhx/cc-check-update.js into a tmpdir alongside a STUB
# `cc-check-update-worker.js` that writes a sentinel file. Because the parent
# resolves the worker via path.join(__dirname, 'cc-check-update-worker.js'),
# running the tmpdir copy of the parent resolves the STUB worker — so
# "sentinel file exists after invocation" == "the parent spawned the worker".
# The worker is detached; the probe `wait`s on the node process then polls
# briefly for the detached child's sentinel write. Fully offline.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PARENT_SRC="$REPO_ROOT/dhx/cc-check-update.js"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0

# --- Build the offline harness: parent copy + stub worker --------------------
HOOKDIR="$TMPDIR/hooks"
mkdir -p "$HOOKDIR"
cp "$PARENT_SRC" "$HOOKDIR/cc-check-update.js"
# Stub worker: writes a sentinel so spawn is observable; does NO network call.
cat > "$HOOKDIR/cc-check-update-worker.js" <<'STUB'
'use strict';
const fs = require('fs');
// Sentinel path handed via env by the probe; presence == "parent spawned us".
const sentinel = process.env.CC_PROBE_SENTINEL;
if (sentinel) { try { fs.writeFileSync(sentinel, 'spawned'); } catch (e) {} }
STUB

# invoke_parent <cache-file> <sentinel-file>
# Runs the tmpdir parent copy with the D-17 CC_CHECK_UPDATE_CACHE seam pointed
# at <cache-file>. Returns after the detached worker's sentinel settles.
invoke_parent() {
  local cache="$1" sentinel="$2"
  rm -f "$sentinel"
  CC_CHECK_UPDATE_CACHE="$cache" CC_PROBE_SENTINEL="$sentinel" \
    node "$HOOKDIR/cc-check-update.js" < /dev/null >/dev/null 2>&1
  # The worker is detached; give it a deterministic, bounded settle window.
  # No `sleep`-as-timing-control of fixture state (D-21) — this is only a
  # poll for an async child, not mtime control.
  local i=0
  while [ $i -lt 50 ]; do
    [ -f "$sentinel" ] && return 0
    i=$((i + 1))
    sleep 0.02
  done
  return 1
}

check() {
  local name="$1" cond="$2"
  if [ "$cond" = "ok" ]; then
    echo "OK   $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL $name"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== cc-check-update.js TTL freshness gate (tmpdir-isolated, offline) ==="

# Live ~/.cache/cc guard — none of the scenarios may create it. Record whether
# it exists at probe start so Scenario 1 can assert the invocation did not.
LIVE_CC_CACHE="$HOME/.cache/cc"
LIVE_EXISTED_AT_START=no
[ -d "$LIVE_CC_CACHE" ] && LIVE_EXISTED_AT_START=yes

# ---- Scenario 1: fresh cache -> worker NOT spawned, no live dir created -----
# Two coupled asserts (no spawn AND no live-dir creation) report as one
# scenario PASS so the suite prints the plan-specified "3 passed".
S1_CACHE="$TMPDIR/s1-cc-update-check.json"
S1_SENTINEL="$TMPDIR/s1-sentinel"
NOW_ISO=$(node -e 'process.stdout.write(new Date().toISOString())')
printf '{"latest":"2.1.146","checked_at":"%s"}' "$NOW_ISO" > "$S1_CACHE"
S1_CACHE_BEFORE=$(cat "$S1_CACHE")
invoke_parent "$S1_CACHE" "$S1_SENTINEL"
S1_CACHE_AFTER=$(cat "$S1_CACHE")
S1_NO_SPAWN=no
[ ! -f "$S1_SENTINEL" ] && [ "$S1_CACHE_BEFORE" = "$S1_CACHE_AFTER" ] && S1_NO_SPAWN=yes
# D-17: the fresh-cache early-return is BEFORE the mkdir — a fresh-cache run
# must not create the live ~/.cache/cc directory.
S1_NO_LIVE_DIR=yes
[ "$LIVE_EXISTED_AT_START" = "no" ] && [ -d "$LIVE_CC_CACHE" ] && S1_NO_LIVE_DIR=no
if [ "$S1_NO_SPAWN" = "yes" ] && [ "$S1_NO_LIVE_DIR" = "yes" ]; then
  check "[1] fresh cache -> worker NOT spawned, live ~/.cache/cc untouched" ok
else
  check "[1] fresh cache -> worker NOT spawned, live ~/.cache/cc untouched" \
    "fail (no_spawn=$S1_NO_SPAWN no_live_dir=$S1_NO_LIVE_DIR)"
fi

# ---- Scenario 2: stale cache -> worker spawned ------------------------------
S2_CACHE="$TMPDIR/s2-cc-update-check.json"
S2_SENTINEL="$TMPDIR/s2-sentinel"
# checked_at 12h in the past — explicit ISO-8601 string, no sleep (D-21).
STALE_ISO=$(node -e 'process.stdout.write(new Date(Date.now() - 12*60*60*1000).toISOString())')
printf '{"latest":"2.1.100","checked_at":"%s"}' "$STALE_ISO" > "$S2_CACHE"
invoke_parent "$S2_CACHE" "$S2_SENTINEL"
if [ -f "$S2_SENTINEL" ]; then
  check "[2] stale cache (12h old) -> worker spawned" ok
else
  check "[2] stale cache (12h old) -> worker spawned" "fail (no sentinel)"
fi

# ---- Scenario 3: missing AND malformed cache -> worker spawned --------------
# Two coupled asserts (missing-cache fall-through AND malformed-JSON /
# NaN-date fall-through) report as one scenario PASS.
S3_CACHE="$TMPDIR/s3-missing-cc-update-check.json"   # never created
S3_SENTINEL="$TMPDIR/s3-sentinel"
invoke_parent "$S3_CACHE" "$S3_SENTINEL"
S3_MISSING_SPAWN=no
[ -f "$S3_SENTINEL" ] && S3_MISSING_SPAWN=yes
S3B_CACHE="$TMPDIR/s3b-cc-update-check.json"
S3B_SENTINEL="$TMPDIR/s3b-sentinel"
printf '{ this is not valid json' > "$S3B_CACHE"
invoke_parent "$S3B_CACHE" "$S3B_SENTINEL"
S3_MALFORMED_SPAWN=no
[ -f "$S3B_SENTINEL" ] && S3_MALFORMED_SPAWN=yes
if [ "$S3_MISSING_SPAWN" = "yes" ] && [ "$S3_MALFORMED_SPAWN" = "yes" ]; then
  check "[3] missing + malformed-JSON cache -> worker spawned (falls through, no crash)" ok
else
  check "[3] missing + malformed-JSON cache -> worker spawned (falls through, no crash)" \
    "fail (missing=$S3_MISSING_SPAWN malformed=$S3_MALFORMED_SPAWN)"
fi

# ---- Scenario 4: future checked_at -> worker spawned (WR-01) ----------------
# A checked_at in the FUTURE (clock skew, hand-edited cache, or a write made
# while the clock was wrong) yields a negative age. Without the `age >= 0`
# guard the gate reads negative-age as `< TTL_MS` == "fresh" and the parent
# exits before the spawn on every subsequent SessionStart, so the worker never
# re-runs to overwrite the bad stamp. The fix treats negative age as stale.
S4_CACHE="$TMPDIR/s4-cc-update-check.json"
S4_SENTINEL="$TMPDIR/s4-sentinel"
# checked_at 12h in the FUTURE — explicit ISO-8601 string, no sleep (D-21).
FUTURE_ISO=$(node -e 'process.stdout.write(new Date(Date.now() + 12*60*60*1000).toISOString())')
printf '{"latest":"2.1.146","checked_at":"%s"}' "$FUTURE_ISO" > "$S4_CACHE"
invoke_parent "$S4_CACHE" "$S4_SENTINEL"
if [ -f "$S4_SENTINEL" ]; then
  check "[4] future checked_at (clock skew) -> worker spawned (WR-01)" ok
else
  check "[4] future checked_at (clock skew) -> worker spawned (WR-01)" "fail (no sentinel)"
fi

echo "---"
echo "$PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
