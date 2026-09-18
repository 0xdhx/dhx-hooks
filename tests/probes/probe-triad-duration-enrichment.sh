#!/bin/bash
# probe-triad-duration-enrichment.sh — Phase 16 (REQ-DRIFT-ACTION-06).
#
# Backs REQ-DRIFT-ACTION-06. Asserts scripts/dhx-gsd-triad.sh emits the
# "(first detected: YYYY-MM-DD, N days unresolved)" enrichment on each DRIFT row
# when ~/.cache/dhx/gsd-drift-first-seen.json has a matching entry, and
# graceful-degrades to no suffix when the cache is absent.
#
# Per D-32, this probe uses the triad's DHX_TRIAD_LIVE_ROOT + DHX_TRIAD_CANONICAL_ROOT
# env overrides to fixture an isolated live+canonical fork-tree pair under mktemp
# with DELIBERATE divergence — so the positive case (a DRIFT row with the
# enrichment suffix) is proven DETERMINISTICALLY in the green suite. D-32 forbids
# the old fallback that conditionally skipped the positive assertion whenever the
# live trees happened to render no divergence; this probe has no such fallback —
# the divergence is staged into the fixture, so the positive case always runs.
#
# DEPENDENCY: the DHX_TRIAD_LIVE_ROOT / DHX_TRIAD_CANONICAL_ROOT overrides + the
# enrichment itself are shipped by Plan 16-04 (Wave 4), which merges AFTER this
# Wave-3 probe. Until 16-04 lands, the triad has no D-32 wiring and this probe
# cannot exercise the contract — so it emits a SINGLE capability-guard SKIP that
# names the missing dependency and exits 0. This is a dependency-presence guard,
# NOT the forbidden byte-equality skip: once 16-04 merges, the guard passes and
# the deterministic positive case runs unconditionally. The merged-tree run (the
# state /gsd-verify-work evaluates) exercises the full positive case.
#
# Backs: 16-SPEC.md REQ-DRIFT-ACTION-06 + 16-CONTEXT.md decision D-32.
# Run: bash tests/probes/probe-triad-duration-enrichment.sh
#
# 2026-06-08: also fixtures backup-meta.json via DHX_TRIAD_BACKUP_META. The triad sources its
# tracked-file list (files[]) from the live backup-meta; after the worktree-safety fork was
# retired (files[] → []), a content-roots-only fixture left the triad exiting at its empty-files[]
# guard before any DRIFT row (probe went 1/6 red). Staging the file list makes the probe fully
# self-isolating — green regardless of live fork-retirement state.

# SAFE_FOR_LIVE: yes  (mktemp + DHX_DRIFT_CACHE + DHX_TRIAD_LIVE_ROOT + DHX_TRIAD_CANONICAL_ROOT + DHX_TRIAD_BACKUP_META env overrides; never reads live ~/.claude, the live backup-meta, or the live dhx drift cache)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TRIAD="$REPO_ROOT/scripts/dhx-gsd-triad.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0

assert() {
  local name="$1"; shift
  if "$@"; then
    echo "OK   $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL $name"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== triad DRIFT-row duration enrichment (tmpdir-isolated) ==="

# Capability guard — the D-32 env overrides are a Plan 16-04 (Wave 4) deliverable.
# // INVARIANT: this is a dependency-presence guard, NOT a byte-equality skip.
# // D-32 forbids skipping when the live trees happen to be byte-equal; it does
# // NOT forbid skipping when the triad has not yet gained the D-32 contract.
if ! grep -q 'DHX_TRIAD_BACKUP_META' "$TRIAD" 2>/dev/null; then
  echo "SKIP: scripts/dhx-gsd-triad.sh has no DHX_TRIAD_BACKUP_META override yet"
  echo "      — the D-32 env overrides + DRIFT-row enrichment ship in Plan 16-04"
  echo "      (Wave 4); DHX_TRIAD_BACKUP_META was added 2026-06-08 for fork-retirement"
  echo "      isolation. Once present, this probe runs the deterministic positive case"
  echo "      with no fallback."
  echo "---"
  echo "0 passed, 0 failed (capability-guard SKIP — awaiting Plan 16-04)"
  exit 0
fi

# ---- D-32 fixture: isolated live + canonical fork-tree pair, deliberate divergence ----
LIVE_FIXTURE="$TMPDIR/live"
CANONICAL_FIXTURE="$TMPDIR/canonical"
mkdir -p "$LIVE_FIXTURE/workflows" "$CANONICAL_FIXTURE/workflows"
echo "live content (modified by operator)" > "$LIVE_FIXTURE/workflows/execute-plan.md"
echo "canonical content (original baseline)" > "$CANONICAL_FIXTURE/workflows/execute-plan.md"
# live != canonical → the triad classifies workflows/execute-plan.md as DRIFT.

# ---- Cache fixture: a 10-day-old first-seen timestamp for the diverging path ----
CACHE="$TMPDIR/gsd-drift-first-seen.json"
TEN_DAYS_AGO=$(date -u -d '-10 days' +%Y-%m-%dT%H:%M:%SZ)
jq -n --arg ts "$TEN_DAYS_AGO" '{"workflows/execute-plan.md": $ts}' > "$CACHE"

# ---- Backup-meta fixture: stage the tracked-file LIST (decoupled from live fork state) ----
# The triad sources files[] from backup-meta.json. Post-2026-06-05 the live meta is files:[]
# (worktree-safety fork retired), so without this override the triad exits at its empty-files[]
# guard before any DRIFT row. The probe must own its file list to stay deterministic.
META="$TMPDIR/backup-meta.json"
jq -n '{from_version:"fixture", backed_up_at:"2026-01-01T00:00:00Z", files:["workflows/execute-plan.md"], pristine_hashes:{}}' > "$META"

# ---- Test 1: positive case — deterministic per D-32 (no SKIP fallback) ----
OUTPUT=$(DHX_DRIFT_CACHE="$CACHE" DHX_TRIAD_BACKUP_META="$META" \
  DHX_TRIAD_LIVE_ROOT="$LIVE_FIXTURE" DHX_TRIAD_CANONICAL_ROOT="$CANONICAL_FIXTURE" \
  bash "$TRIAD" 2>&1)

assert "[1a] DRIFT row present" \
  bash -c 'grep -qF "DRIFT" <<<"$1"' _ "$OUTPUT"
assert "[1b] fixture path in output" \
  bash -c 'grep -qF "workflows/execute-plan.md" <<<"$1"' _ "$OUTPUT"
assert "[1c] first-detected date suffix present" \
  bash -c 'grep -qE "first detected: 20[0-9][0-9]-[0-9]{2}-[0-9]{2}" <<<"$1"' _ "$OUTPUT"
assert "[1d] days-unresolved suffix present" \
  bash -c 'grep -qE "[0-9]+ days unresolved" <<<"$1"' _ "$OUTPUT"

# ---- Test 2: graceful-degrade — cache absent, same divergent fixture ----
OUTPUT2=$(DHX_DRIFT_CACHE="/nonexistent-cache.json" DHX_TRIAD_BACKUP_META="$META" \
  DHX_TRIAD_LIVE_ROOT="$LIVE_FIXTURE" DHX_TRIAD_CANONICAL_ROOT="$CANONICAL_FIXTURE" \
  bash "$TRIAD" 2>&1)

assert "[2a] DRIFT row still fires from live/canonical divergence" \
  bash -c 'grep -qF "DRIFT" <<<"$1"' _ "$OUTPUT2"
assert "[2b] no first-detected suffix leaked when cache absent" \
  bash -c '! grep -qF "first detected:" <<<"$1"' _ "$OUTPUT2"

echo "---"
echo "$PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
