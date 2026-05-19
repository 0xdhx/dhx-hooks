#!/bin/bash
# Exercises the fork-aware suppression filter on the gsd drift trigger
# (isGsdDriftFromForkSync in dhx/statusline-wrapper.js).
#
# Backs quick task 260425-oeg — fork-aware gsd drift suppression. The
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

# SAFE_FOR_LIVE: yes   (mktemp + node -e require with explicit liveRoot/forkRoot args; never reads live `~/.claude`)
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

echo
echo "=== gsd diverging-files collector (tmpdir-isolated) ==="

# collector returns array of {path,kind} entries — exercise the same scenario
# space as the suppression helper but assert the structured result, not bool.
# Backs the Problem 2 implementation in dhx/statusline-wrapper.js: visible
# `⚠ restart gsd:<basename>` detail + forensic breadcrumb to ~/.cache/dhx/.

run_collector() {
  local name="$1" live="$2" fork="$3" snap_mtime="$4" want="$5"
  local got
  got=$(node -e "
    const m = require('$WRAPPER');
    const r = m.collectGsdDriftDivergingFiles({gsd_mtime: $snap_mtime}, '$live', '$fork');
    process.stdout.write(JSON.stringify(r));
  " 2>/dev/null || echo "<error>")
  if [ "$got" = "$want" ]; then
    echo "OK   $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL $name (got=$got want=$want)"
    FAIL=$((FAIL + 1))
  fi
}

# ---- [7] Empty: live byte-equal to canonical → empty diverging list ----
# Scenario [1] mirror: suppression returns true, collector returns [].
mkdir -p "$TMPDIR/c7/live/workflows" "$TMPDIR/c7/fork/workflows"
echo "patched content" > "$TMPDIR/c7/live/workflows/execute-phase.md"
echo "patched content" > "$TMPDIR/c7/fork/workflows/execute-phase.md"
SNAP=$(($(date +%s%3N) - 60000))
run_collector "[7] empty: live==canonical → []" \
  "$TMPDIR/c7/live" "$TMPDIR/c7/fork" "$SNAP" "[]"

# ---- [8] Single mismatch: canonical bytes differ ----
# Scenario [3] mirror: collector reports exactly one mismatch entry.
mkdir -p "$TMPDIR/c8/live/workflows" "$TMPDIR/c8/fork/workflows"
echo "live content A" > "$TMPDIR/c8/live/workflows/execute-phase.md"
echo "canonical content B" > "$TMPDIR/c8/fork/workflows/execute-phase.md"
SNAP=$(($(date +%s%3N) - 60000))
run_collector "[8] single mismatch: bytes differ" \
  "$TMPDIR/c8/live" "$TMPDIR/c8/fork" "$SNAP" \
  '[{"path":"workflows/execute-phase.md","kind":"mismatch"}]'

# ---- [9] No-canonical: live file has no counterpart ----
# Scenario [2] mirror: collector reports the file with kind=no-canonical.
mkdir -p "$TMPDIR/c9/live/workflows" "$TMPDIR/c9/fork/workflows"
echo "real upstream" > "$TMPDIR/c9/live/workflows/upstream-only.md"
SNAP=$(($(date +%s%3N) - 60000))
run_collector "[9] no-canonical: live without counterpart" \
  "$TMPDIR/c9/live" "$TMPDIR/c9/fork" "$SNAP" \
  '[{"path":"workflows/upstream-only.md","kind":"no-canonical"}]'

# ---- [10] Fork-tree-missing: canonical root absent → single-entry sentinel ----
# Scenario [4] mirror: collector returns one entry with no path field.
mkdir -p "$TMPDIR/c10/live/workflows"
echo "modified" > "$TMPDIR/c10/live/workflows/execute-phase.md"
SNAP=$(($(date +%s%3N) - 60000))
run_collector "[10] fork-tree-missing → sentinel entry" \
  "$TMPDIR/c10/live" "$TMPDIR/c10/fork-does-not-exist" "$SNAP" \
  '[{"kind":"fork-tree-missing"}]'

# ---- [11] Mixed: one mismatch + one no-canonical → both reported ----
# Scenario [6] mirror: collector includes BOTH divergent files (helper's
# early-return contrasts; collector walks the full tree).
mkdir -p "$TMPDIR/c11/live/workflows" "$TMPDIR/c11/fork/workflows"
echo "live differs" > "$TMPDIR/c11/live/workflows/execute-phase.md"
echo "canonical differs" > "$TMPDIR/c11/fork/workflows/execute-phase.md"
echo "no canonical" > "$TMPDIR/c11/live/workflows/upstream-only.md"
SNAP=$(($(date +%s%3N) - 60000))
# Order from readdirSync recursive walk is filesystem-dependent — accept either
# permutation. Two probes: assert each entry's presence independently.
got=$(node -e "
  const m = require('$WRAPPER');
  const r = m.collectGsdDriftDivergingFiles({gsd_mtime: $SNAP}, '$TMPDIR/c11/live', '$TMPDIR/c11/fork');
  process.stdout.write(JSON.stringify(r));
" 2>/dev/null || echo "<error>")
if echo "$got" | grep -q '"workflows/execute-phase.md","kind":"mismatch"' && \
   echo "$got" | grep -q '"workflows/upstream-only.md","kind":"no-canonical"' && \
   [ "$(echo "$got" | jq 'length' 2>/dev/null)" = "2" ]; then
  echo "OK   [11] mixed: both divergent files reported"
  PASS=$((PASS + 1))
else
  echo "FAIL [11] mixed (got=$got)"
  FAIL=$((FAIL + 1))
fi

# ---- [12] Vacuous: no files newer than snapshot → empty list ----
# Scenario [5] mirror: collector walks but accumulates nothing.
mkdir -p "$TMPDIR/c12/live/workflows" "$TMPDIR/c12/fork"
echo "old" > "$TMPDIR/c12/live/workflows/execute-phase.md"
SNAP=$(($(date +%s%3N) + 60000))
run_collector "[12] vacuous: no files newer than snapshot → []" \
  "$TMPDIR/c12/live" "$TMPDIR/c12/fork" "$SNAP" "[]"

echo "---"
echo "$PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
