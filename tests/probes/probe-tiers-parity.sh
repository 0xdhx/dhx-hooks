#!/bin/bash
# Probe: 3-way parity between scripts/lib/tiers.json, scripts/lib/tiers.sh,
# and dhx/statusline-wrapper.js literal `h.<field>` references.
#
# Phase 4 Plan 02 ships tiers.json as the canonical source of truth (D-02);
# tiers.sh derives bash arrays from it via jq; statusline-wrapper.js currently
# hardcodes the same field names in if-block predicates (lines 624-644). Until
# Phase 5 migrates the JS side to `require('../scripts/lib/tiers.json')`, this
# probe enforces lockstep between all three surfaces — drift in either
# direction is caught as a runtime invariant rather than discovered at incident
# time.
#
# Backs decisions.md 2026-05-01 row "tiers.json as source of truth (D-02)".
# Run: bash tests/probes/probe-tiers-parity.sh
# SAFE_FOR_LIVE: yes  (read-only grep + jq parse over repo files; no live mutation)
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
JSON="$REPO/scripts/lib/tiers.json"
SHFILE="$REPO/scripts/lib/tiers.sh"
JS="$REPO/dhx/statusline-wrapper.js"

pass=0; fail=0
assert_eq() {
  local name="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    echo "OK   $name"
    pass=$((pass+1))
  else
    echo "FAIL $name"
    echo "     got:  $got"
    echo "     want: $want"
    fail=$((fail+1))
  fi
}

# 1. JSON parses
if jq empty "$JSON" 2>/dev/null; then
  echo "OK   tiers.json parses"
  pass=$((pass+1))
else
  echo "FAIL tiers.json parse error"
  fail=$((fail+1))
fi

# 2. JSON → bash array round-trip
critical_json=$(jq -r '.critical | join(" ")' "$JSON")
advisory_json=$(jq -r '.advisory | join(" ")' "$JSON")
# shellcheck source=/dev/null
source "$SHFILE"
assert_eq "tiers.sh CRITICAL matches tiers.json critical" "${CRITICAL[*]}" "$critical_json"
assert_eq "tiers.sh ADVISORY matches tiers.json advisory" "${ADVISORY[*]}" "$advisory_json"

# 3. Each JSON key appears as h.<key> literal in statusline-wrapper.js
for k in $critical_json $advisory_json; do
  if grep -qE "h\.${k}\b" "$JS"; then
    echo "OK   statusline-wrapper.js references h.${k}"
    pass=$((pass+1))
  else
    echo "FAIL statusline-wrapper.js missing h.${k}"
    fail=$((fail+1))
  fi
done

echo
echo "$pass passed, $fail failed"
exit $fail
