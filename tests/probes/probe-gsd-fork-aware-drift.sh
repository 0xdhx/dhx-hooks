#!/bin/bash
# Exercises the fork-aware suppression filter on the gsd drift trigger
# (isGsdDriftFromForkSync in dhx/statusline-wrapper.js).
#
# Asserts fork-aware gsd drift suppression. The
# helper sits between the gsd mtime branch firing in checkDrift() and the
# trigger being pushed onto `triggers[]`: when every newer-than-snapshot
# live file is byte-equal to its canonical at
# ~/.claude/gsd-local-patches/get-shit-done/, the gsd trigger is suppressed
# and the snapshot is re-baselined. Otherwise the trigger fires as today.
#
# Run: bash tests/probes/probe-gsd-fork-aware-drift.sh
#
# Strategy: each scenario stands up an isolated (live, fork) pair under
# mktemp -d, then calls the helper directly via `node -e require(wrapper)`
# with explicit liveRoot/forkRoot args (the helper signature accepts them
# for fixture injection — production callers pass only `snapshot`). Live
# ~/.claude/get-shit-done/ and ~/.claude/gsd-local-patches/ are never read.
#
# Note: the "count branch fires (deletion) → unconditional fire" rule lives
# in checkDrift()'s wiring (helper is not invoked when current.gsd_count <
# snapshot.gsd_count). Not exercised here; helper is the unit under test.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WRAPPER="$REPO_ROOT/dhx/statusline-wrapper.js"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0

run_case() {
  local name="$1" live="$2" fork="$3" snap_mtime="$4" want="$5"
  local got
  got=$(node -e "
    const m = require('$WRAPPER');
    const r = m.isGsdDriftFromForkSync({gsd_mtime: $snap_mtime}, '$live', '$fork');
    process.stdout.write(String(r));
  " 2>/dev/null || echo "<error>")
  if [ "$got" = "$want" ]; then
    echo "OK   $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL $name (got=$got want=$want)"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== gsd fork-aware drift suppression (tmpdir-isolated) ==="

# ---- [1] Suppression: live byte-equal to canonical ----
mkdir -p "$TMPDIR/c1/live/workflows" "$TMPDIR/c1/fork/workflows"
echo "patched content" > "$TMPDIR/c1/live/workflows/execute-phase.md"
echo "patched content" > "$TMPDIR/c1/fork/workflows/execute-phase.md"
SNAP=$(($(date +%s%3N) - 60000))
run_case "[1] suppress: live==canonical" \
  "$TMPDIR/c1/live" "$TMPDIR/c1/fork" "$SNAP" "true"

# ---- [2] Fire: newer-than-snapshot file has NO canonical counterpart ----
mkdir -p "$TMPDIR/c2/live/workflows" "$TMPDIR/c2/fork/workflows"
echo "real upstream" > "$TMPDIR/c2/live/workflows/upstream-only.md"
SNAP=$(($(date +%s%3N) - 60000))
run_case "[2] fire: no canonical counterpart" \
  "$TMPDIR/c2/live" "$TMPDIR/c2/fork" "$SNAP" "false"

# ---- [3] Fire: canonical exists but bytes differ ----
mkdir -p "$TMPDIR/c3/live/workflows" "$TMPDIR/c3/fork/workflows"
echo "live content A" > "$TMPDIR/c3/live/workflows/execute-phase.md"
echo "canonical content B" > "$TMPDIR/c3/fork/workflows/execute-phase.md"
SNAP=$(($(date +%s%3N) - 60000))
run_case "[3] fire: bytes differ" \
  "$TMPDIR/c3/live" "$TMPDIR/c3/fork" "$SNAP" "false"

# ---- [4] Missing canonical tree → fire (fail-open) ----
mkdir -p "$TMPDIR/c4/live/workflows"
echo "modified" > "$TMPDIR/c4/live/workflows/execute-phase.md"
SNAP=$(($(date +%s%3N) - 60000))
run_case "[4] fire: fork tree missing" \
  "$TMPDIR/c4/live" "$TMPDIR/c4/fork-does-not-exist" "$SNAP" "false"

# ---- [5] Vacuous suppress: no files newer than snapshot ----
mkdir -p "$TMPDIR/c5/live/workflows" "$TMPDIR/c5/fork"
echo "old" > "$TMPDIR/c5/live/workflows/execute-phase.md"
SNAP=$(($(date +%s%3N) + 60000))
run_case "[5] vacuous: no files newer than snapshot" \
  "$TMPDIR/c5/live" "$TMPDIR/c5/fork" "$SNAP" "true"

# ---- [6] Mixed: one matched canonical + one upstream-only → fire ----
mkdir -p "$TMPDIR/c6/live/workflows" "$TMPDIR/c6/fork/workflows"
echo "matched" > "$TMPDIR/c6/live/workflows/execute-phase.md"
echo "matched" > "$TMPDIR/c6/fork/workflows/execute-phase.md"
echo "no canonical" > "$TMPDIR/c6/live/workflows/upstream-only.md"
SNAP=$(($(date +%s%3N) - 60000))
run_case "[6] fire: mixed (one good + one upstream-only)" \
  "$TMPDIR/c6/live" "$TMPDIR/c6/fork" "$SNAP" "false"

echo "---"
echo "$PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
