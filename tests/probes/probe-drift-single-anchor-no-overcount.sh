#!/bin/bash
# probe-drift-single-anchor-no-overcount.sh — Phase 16 (REQ-DRIFT-ACTION-05).
#
# Backs REQ-DRIFT-ACTION-05 (negative case). Asserts the SessionStart drift block
# (dhx/dhx-gsd-drift-surface.sh) renders EXACTLY 1 file entry when only 1 path is
# diverging — no phantom over-reporting. Over-counting is the common regression
# class for new surface emitters (off-by-one in the file-line loop, a stray
# duplicate cp line, a header that always pluralizes). This probe is the
# anti-regression guard paired with probe-drift-multi-anchor-distinct-surfacing.sh.
#
# Backs: 16-SPEC.md REQ-DRIFT-ACTION-05 negative case + 16-VALIDATION.md
#        Nyquist anti-mask coverage (single-anchor no-overcount row).
# Run: bash tests/probes/probe-drift-single-anchor-no-overcount.sh
#
# Strategy: fixture a single-entry gsd-drift-first-seen.json under mktemp -d,
# invoke the emitter via DHX_DRIFT_CACHE override. The live dhx drift cache is
# never read or written.

# SAFE_FOR_LIVE: yes   (mktemp + env-override DHX_DRIFT_CACHE; never touches the live dhx drift cache)
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EMITTER="$REPO_ROOT/dhx/dhx-gsd-drift-surface.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0

# // INVARIANT: assert() keeps the OK/FAIL prefix and the accumulator in lockstep.
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

ENV=$(jq -n --arg sid "probe-test" '{session_id: $sid, source: "startup"}')

echo "=== drift single-anchor no-overcount (tmpdir-isolated) ==="

# ---- Fixture: EXACTLY 1 diverging file ----
CACHE="$TMPDIR/gsd-drift-first-seen.json"
cat > "$CACHE" <<'EOF'
{"workflows/execute-phase.md": "2026-05-15T06:08:00Z"}
EOF

OUTPUT=$(printf '%s' "$ENV" | DHX_DRIFT_CACHE="$CACHE" bash "$EMITTER" 2>&1)

# // INVARIANT: with exactly 1 cache entry the block renders exactly 1 file line.
# // Anything other than 1 is phantom over-reporting (or silent under-reporting).
FILE_LINE_COUNT=$(echo "$OUTPUT" | grep -cE 'first seen [0-9]{4}-[0-9]{2}-[0-9]{2}')
assert "exactly 1 file entry (no over-reporting)" \
  bash -c '[ "$1" -eq 1 ]' _ "$FILE_LINE_COUNT"

# Header reports N=1 (D-05 phrasing keeps the parenthesized plural marker `file(s)`).
assert "header reports 1 file(s) diverged" \
  bash -c 'echo "$1" | grep -qF "1 file(s) diverged"' _ "$OUTPUT"

# Exactly 1 cp line — one per rendered file line.
CP_COUNT=$(echo "$OUTPUT" | grep -cE '^  cp .*get-shit-done/workflows/')
assert "exactly 1 cp line emitted" \
  bash -c '[ "$1" -eq 1 ]' _ "$CP_COUNT"

# The single rendered path is the one in the fixture (no phantom path).
assert "rendered path matches fixture (execute-phase.md)" \
  bash -c 'echo "$1" | grep -qF "workflows/execute-phase.md"' _ "$OUTPUT"

# No truncation footer should appear for a single-entry cache.
assert "no truncation footer for single anchor" \
  bash -c '! echo "$1" | grep -qF "+0 more"' _ "$OUTPUT"

# ---- Cache-survival sub-test: re-invoke after a (no-op) session-snapshot delete ----
rm -f "$TMPDIR/per-session-snapshot.json" 2>/dev/null || true
OUTPUT2=$(printf '%s' "$ENV" | DHX_DRIFT_CACHE="$CACHE" bash "$EMITTER" 2>&1)
assert "cache survives simulated session restart" \
  bash -c 'echo "$1" | grep -qF "2026-05-15"' _ "$OUTPUT2"
FILE_LINE_COUNT2=$(echo "$OUTPUT2" | grep -cE 'first seen [0-9]{4}-[0-9]{2}-[0-9]{2}')
assert "still exactly 1 file entry after restart" \
  bash -c '[ "$1" -eq 1 ]' _ "$FILE_LINE_COUNT2"

echo "---"
echo "$PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
