#!/bin/bash
# Probe: 3-way parity between scripts/lib/tiers.json, scripts/lib/tiers.sh,
# and dhx/statusline-wrapper.js handler tables (CRITICAL_PREFIX + ADVISORY_HANDLERS).
#
# Phase 4 Plan 02 shipped tiers.json as the canonical source of truth (D-02);
# tiers.sh derives bash arrays from it via jq; Phase 5 migrated statusline-wrapper.js
# to consume it via `require('../scripts/lib/tiers.json')` (wrapped in try/catch with
# iterable default per D-08) with handler tables for the heterogeneous per-field
# comparators. This probe enforces post-migration parity: every JSON field has a
# corresponding handler-table entry INSIDE the literal `const CRITICAL_PREFIX = { … }`
# or `const ADVISORY_HANDLERS = { … }` brace block (D-11 awk-based brace scoping —
# eliminates false matches on comments / unrelated objects), and the require()
# call is present (single source of truth lock).
#
# Backs decisions.md 2026-05-01 row "tiers.json as source of truth (D-02)" +
# Phase 5 D-07 (statusline migration to require()) + D-08 (try/catch fallback) +
# D-10 (runtime guards) + D-11 (brace-bound regex).
# Run: bash tests/probes/probe-tiers-parity.sh
# SAFE_FOR_LIVE: yes  (read-only awk + grep + jq parse over repo files; no live mutation)
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

# 3. statusline-wrapper.js consumes tiers.json via require() (single source of truth lock)
if grep -qF "require('../scripts/lib/tiers.json')" "$JS"; then
  echo "OK   statusline-wrapper.js requires scripts/lib/tiers.json"
  pass=$((pass+1))
else
  echo "FAIL statusline-wrapper.js missing require('../scripts/lib/tiers.json')"
  fail=$((fail+1))
fi

# Helper: extract the body (between the outermost `{` and matching `}`) of a
# JS const-object declaration. Tracks brace depth via awk so we ignore code
# outside the table (comments, unrelated objects, etc).
# Usage: extract_const_block <const-name> <file>
extract_const_block() {
  local name="$1"
  local file="$2"
  awk -v name="$name" '
    # Match `const <name> = {` (allow whitespace; ignore export/let prefix variants)
    !in_block && $0 ~ ("const[ \t]+" name "[ \t]*=[ \t]*\\{") {
      in_block = 1
      depth = 0
      # Count braces on the matching line itself
      for (i = 1; i <= length($0); i++) {
        ch = substr($0, i, 1)
        if (ch == "{") depth++
        else if (ch == "}") depth--
      }
      print $0
      if (depth == 0) { in_block = 0; exit }
      next
    }
    in_block {
      for (i = 1; i <= length($0); i++) {
        ch = substr($0, i, 1)
        if (ch == "{") depth++
        else if (ch == "}") depth--
      }
      print $0
      if (depth == 0) { in_block = 0; exit }
    }
  ' "$file"
}

CRITICAL_BLOCK=$(extract_const_block CRITICAL_PREFIX "$JS")
ADVISORY_BLOCK=$(extract_const_block ADVISORY_HANDLERS "$JS")

# 4. Each tiers.json::critical[] field has a CRITICAL_PREFIX[<field>]:'<prefix>' entry
#    INSIDE the brace block (D-11 — eliminates false matches on comments / unrelated objects)
for k in $critical_json; do
  # Match `<field>:` followed by a quoted string literal (single or double quote)
  # within the extracted CRITICAL_PREFIX brace block
  if echo "$CRITICAL_BLOCK" | grep -qE "^[[:space:]]*${k}:[[:space:]]*['\"]"; then
    echo "OK   CRITICAL_PREFIX has ${k}"
    pass=$((pass+1))
  else
    echo "FAIL CRITICAL_PREFIX missing ${k}"
    fail=$((fail+1))
  fi
done

# 5. Each tiers.json::advisory[] field has an ADVISORY_HANDLERS[<field>]: (v) entry
#    INSIDE the brace block (D-11 — same scoping discipline as critical)
for k in $advisory_json; do
  # Match `<field>:` followed by `(v)` (arrow-function handler signature)
  # within the extracted ADVISORY_HANDLERS brace block
  if echo "$ADVISORY_BLOCK" | grep -qE "^[[:space:]]*${k}:[[:space:]]*\(v\)"; then
    echo "OK   ADVISORY_HANDLERS has ${k}"
    pass=$((pass+1))
  else
    echo "FAIL ADVISORY_HANDLERS missing ${k}"
    fail=$((fail+1))
  fi
done

echo
echo "$pass passed, $fail failed"
exit $fail
