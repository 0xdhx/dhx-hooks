#!/bin/bash
# probe-drift-multi-anchor-distinct-surfacing.sh — Phase 16 (REQ-DRIFT-ACTION-05).
#
# Backs REQ-DRIFT-ACTION-01 + REQ-02 + REQ-05 (positive). Asserts the SessionStart
# drift block (dhx/dhx-gsd-drift-surface.sh) renders BOTH diverging files with
# their respective first-detected ISO timestamps + age labels + D-02 oldest-first
# ordering + truncation at N>5 + cache-survival across a simulated session
# restart. Closes the 2026-05-12 + 2026-05-15 6-day-mask anchor: a single masked
# anchor can no longer hide a second, distinct divergence.
#
# Backs: 16-SPEC.md REQ-DRIFT-ACTION-05 positive case + decisions D-01..D-05.
# Run: bash tests/probes/probe-drift-multi-anchor-distinct-surfacing.sh
#
# Strategy: each scenario fixtures an isolated gsd-drift-first-seen.json under
# mktemp -d, then invokes the emitter with DHX_DRIFT_CACHE pointed at the fixture
# (the emitter's documented probe-override). The live drift cache directory
# under the dhx XDG cache root is never read or written.

# SAFE_FOR_LIVE: yes   (mktemp + env-override DHX_DRIFT_CACHE; never touches the live dhx drift cache)
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EMITTER="$REPO_ROOT/dhx/dhx-gsd-drift-surface.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0

# // INVARIANT: every assertion routes through assert() so the OK/FAIL prefix
# // and the PASS/FAIL accumulator stay in lockstep — a missed accumulator bump
# // would silently exit 0 on a real regression.
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

# Stdin envelope mimics what the session-start.sh dispatcher feeds the emitter.
ENV=$(jq -n --arg sid "probe-test" '{session_id: $sid, source: "startup"}')

echo "=== drift multi-anchor distinct surfacing (tmpdir-isolated) ==="

# ---- Scenario 1: 2-file multi-anchor (the 6-day-mask anchor) ----
CACHE="$TMPDIR/gsd-drift-first-seen.json"
cat > "$CACHE" <<'EOF'
{
  "workflows/execute-plan.md":  "2026-05-12T22:40:00Z",
  "workflows/execute-phase.md": "2026-05-15T06:08:00Z"
}
EOF

OUTPUT=$(printf '%s' "$ENV" | DHX_DRIFT_CACHE="$CACHE" bash "$EMITTER" 2>&1)

assert "[1a] plan.md path present" \
  bash -c 'echo "$1" | grep -qF "workflows/execute-plan.md"' _ "$OUTPUT"
assert "[1b] phase.md path present" \
  bash -c 'echo "$1" | grep -qF "workflows/execute-phase.md"' _ "$OUTPUT"
assert "[1c] plan.md ISO date present" \
  bash -c 'echo "$1" | grep -qF "2026-05-12"' _ "$OUTPUT"
assert "[1d] phase.md ISO date present" \
  bash -c 'echo "$1" | grep -qF "2026-05-15"' _ "$OUTPUT"
assert "[1e] age label present" \
  bash -c 'echo "$1" | grep -qE "[0-9]+d unresolved"' _ "$OUTPUT"

# D-02 oldest-first: plan.md (2026-05-12) must render before phase.md (2026-05-15).
PLAN_LINE=$(echo "$OUTPUT" | grep -nF 'workflows/execute-plan.md' | head -1 | cut -d: -f1)
PHASE_LINE=$(echo "$OUTPUT" | grep -nF 'workflows/execute-phase.md' | head -1 | cut -d: -f1)
assert "[1f] D-02 oldest-first ordering (plan before phase)" \
  bash -c '[ -n "$1" ] && [ -n "$2" ] && [ "$1" -lt "$2" ]' _ "$PLAN_LINE" "$PHASE_LINE"

assert "[1g] D-05 header literal (2 file(s) diverged, oldest first)" \
  bash -c 'echo "$1" | grep -qF "⚠ GSD canonical drift — 2 file(s) diverged (oldest first)"' _ "$OUTPUT"
assert "[1h] D-01 Run to repair footer" \
  bash -c 'echo "$1" | grep -qF "Run to repair:"' _ "$OUTPUT"

CP_COUNT=$(echo "$OUTPUT" | grep -cE '^  cp .*get-shit-done/workflows/')
assert "[1i] 2 cp lines emitted" \
  bash -c '[ "$1" -eq 2 ]' _ "$CP_COUNT"

# ---- Scenario 2: 6-file truncation per D-04 ----
CACHE6="$TMPDIR/gsd-drift-6.json"
cat > "$CACHE6" <<'EOF'
{
  "workflows/execute-plan.md":     "2026-05-08T01:00:00Z",
  "workflows/execute-phase.md":    "2026-05-09T02:00:00Z",
  "workflows/diagnose-issues.md":  "2026-05-10T03:00:00Z",
  "workflows/quick.md":            "2026-05-11T04:00:00Z",
  "workflows/spec-phase.md":       "2026-05-12T05:00:00Z",
  "workflows/plan-phase.md":       "2026-05-13T06:00:00Z"
}
EOF

OUTPUT6=$(printf '%s' "$ENV" | DHX_DRIFT_CACHE="$CACHE6" bash "$EMITTER" 2>&1)

assert "[2a] header says 6 file(s) diverged" \
  bash -c 'echo "$1" | grep -qF "6 file(s) diverged"' _ "$OUTPUT6"

FILE_LINE_COUNT=$(echo "$OUTPUT6" | grep -cE 'first seen [0-9]{4}-[0-9]{2}-[0-9]{2}')
assert "[2b] exactly 5 file lines emitted (D-04 cap)" \
  bash -c '[ "$1" -eq 5 ]' _ "$FILE_LINE_COUNT"

assert "[2c] +1 more truncation indicator present" \
  bash -c 'echo "$1" | grep -qF "+1 more — run /dhx:statusline triad"' _ "$OUTPUT6"

CP_COUNT6=$(echo "$OUTPUT6" | grep -cE '^  cp .*get-shit-done/workflows/')
assert "[2d] exactly 5 cp lines emitted" \
  bash -c '[ "$1" -eq 5 ]' _ "$CP_COUNT6"

# ---- Scenario 3: cache-survival across a simulated session restart ----
# // INVARIANT: gsd-drift-first-seen.json is NOT session-scoped — it persists
# // cross-session keyed by relative path. Deleting any per-session snapshot
# // (none exists; the emitter writes none) must not affect re-invocation output.
rm -f "$TMPDIR/per-session-snapshot.json" 2>/dev/null || true
OUTPUT2=$(printf '%s' "$ENV" | DHX_DRIFT_CACHE="$CACHE" bash "$EMITTER" 2>&1)
assert "[3a] cache survives simulated session restart" \
  bash -c 'echo "$1" | grep -qF "2026-05-12"' _ "$OUTPUT2"

echo "---"
echo "$PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
