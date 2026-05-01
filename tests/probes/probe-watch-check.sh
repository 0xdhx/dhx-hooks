#!/usr/bin/env bash
# probe-watch-check.sh — probe for dhx-watch-check.sh
# Test groups: C (cadence), F (filter), H (hint classifier), E (errors), A (atomicity)

# SAFE_FOR_LIVE: yes   (per-test mktemp_state registry with trap cleanup; no live writes)
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CHECKER="$HOME/repos/cross-repo/watch/bin/dhx-watch-check.sh"  # external to this repo
FIXTURES="$REPO/tests/fixtures/watch"
PASS=0
FAIL=0

ok() { echo "OK   $1: $2"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1: $2"; FAIL=$((FAIL + 1)); }

# Temp-dir registry for trap-based cleanup
TEMP_DIRS=()
cleanup() {
  for d in "${TEMP_DIRS[@]}"; do
    [ -d "$d" ] && rm -rf "$d"
  done
}
trap cleanup EXIT

# Create an isolated state dir per test case to avoid pollution
mktemp_state() {
  local d
  d=$(mktemp -d -t watch-check-probe-XXXXXX)
  TEMP_DIRS+=("$d")
  echo '{"schema_version":1,"items":[]}' > "$d/watchlist.json"
  echo "$d"
}

# Test cases appended here as the checker implementation grows.

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
