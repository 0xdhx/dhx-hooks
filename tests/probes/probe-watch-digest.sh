#!/usr/bin/env bash
# probe-watch-digest.sh — probe for dhx-watch-digest.sh
# Test groups: S (surface logic), R (render), T (system signal)

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SURFACER="$REPO/dhx/dhx-watch-digest.sh"
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

mktemp_state() {
  local d
  d=$(mktemp -d -t watch-digest-probe-XXXXXX)
  TEMP_DIRS+=("$d")
  echo "$d"
}

# Test cases appended here as the surfacer implementation grows.

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
