#!/usr/bin/env bash
# probe-session-start-matcher-shape.sh
#
# Asserts every SessionStart matcher block in the dhx plugin manifest contains
# at most one hook entry. Multi-entry SessionStart matcher blocks silently fail
# to load on CC 2.1.121 — the entire matcher block is dropped at session-init,
# no hooks fire, no parse error surfaces. Empirical regression: commit `617d024`
# (2026-05-03) added a 2nd entry to the existing block; zero `.current-session.id`
# stamps written across multiple fresh sessions; dispatcher (`/tmp/dhx-plugin-probe.log`)
# stopped firing entirely; root cause was diagnosed via the `ce5acba` probe.
#
# Backs: docs/decisions.md 2026-05-03 SessionStart split-block row,
#        docs/hook-patterns.md HP-029.
# Run  : bash tests/probes/probe-session-start-matcher-shape.sh
#
# SAFE_FOR_LIVE: yes   (read-only jq queries against in-repo manifest; no FS writes)

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
MANIFEST="$REPO/dhx-plugin/plugins/dhx/hooks/hooks.json"

PASS=0
FAIL=0

assert() {
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    echo "OK   $desc (got=$actual)"
    PASS=$((PASS + 1))
  else
    echo "FAIL $desc (got=$actual, expected=$expected)"
    FAIL=$((FAIL + 1))
  fi
}

# Setup
[ -f "$MANIFEST" ] || { echo "FAIL manifest not found: $MANIFEST"; exit 1; }
jq empty "$MANIFEST" 2>/dev/null || { echo "FAIL manifest is not valid JSON: $MANIFEST"; exit 1; }

# Assertion 1: SessionStart key exists
HAS_SS=$(jq 'if .hooks.SessionStart then "yes" else "no" end' "$MANIFEST")
assert "SessionStart key exists in manifest" "$HAS_SS" '"yes"'

# Assertion 2: every SessionStart matcher block has exactly one hook entry (HP-029)
MAX_PER_BLOCK=$(jq '[.hooks.SessionStart[] | (.hooks | length)] | max // 0' "$MANIFEST")
assert "max hooks per SessionStart block ≤ 1 (HP-029)" "$MAX_PER_BLOCK" "1"

# Assertion 3: every SessionStart matcher block has at least one hook entry (no empty blocks)
MIN_PER_BLOCK=$(jq '[.hooks.SessionStart[] | (.hooks | length)] | min // 0' "$MANIFEST")
assert "min hooks per SessionStart block ≥ 1 (no empty blocks)" "$MIN_PER_BLOCK" "1"

# Assertion 4: total SessionStart hook entries equals the number of SessionStart blocks
TOTAL_HOOKS=$(jq '[.hooks.SessionStart[].hooks[]] | length' "$MANIFEST")
TOTAL_BLOCKS=$(jq '.hooks.SessionStart | length' "$MANIFEST")
assert "block count == hook entry count (one-per-block invariant)" "$TOTAL_HOOKS" "$TOTAL_BLOCKS"

# Assertion 5: every SessionStart block carries an explicit matcher field
#   (defensive: prevents accidental matcher-less blocks that would fire on every
#   source value; HP-015 enumerates startup|resume|clear|compact only.)
NO_MATCHER=$(jq '[.hooks.SessionStart[] | select(.matcher == null)] | length' "$MANIFEST")
assert "every SessionStart block declares a matcher" "$NO_MATCHER" "0"

# Assertion 6: contrast — other event matcher blocks ARE allowed multi-entry
#   (asserts the constraint is SessionStart-specific, not a global rule).
PRETOOL_MAX=$(jq '[.hooks.PreToolUse[]?.hooks | length] | max // 0' "$MANIFEST")
[ "$PRETOOL_MAX" -ge 1 ] && {
  echo "OK   PreToolUse multi-entry blocks are unrestricted (max=$PRETOOL_MAX)"
  PASS=$((PASS + 1))
} || {
  echo "FAIL PreToolUse should allow multi-entry blocks (max=$PRETOOL_MAX)"
  FAIL=$((FAIL + 1))
}

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
