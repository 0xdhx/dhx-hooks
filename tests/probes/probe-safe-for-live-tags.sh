#!/bin/bash
# Probe: every probe file under tests/probes/ carries an explicit
# `# SAFE_FOR_LIVE: yes|no` (or `// SAFE_FOR_LIVE: yes|no` for .js)
# header tag, AND every probe is recorded in tests/probes/SAFE_FOR_LIVE.md.
#
# Backs decisions.md 2026-05-01 row "SAFE_FOR_LIVE audit (D-11/D-12)".
# Without this probe, classification rot accumulates as new probes ship.
# Closes the D-29 forward-reference: after Task 3 lands, row count in
# SAFE_FOR_LIVE.md must equal probe file count.
# Run: bash tests/probes/probe-safe-for-live-tags.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AUDIT="$REPO/tests/probes/SAFE_FOR_LIVE.md"
pass=0; fail=0

if [[ ! -f "$AUDIT" ]]; then
  echo "FAIL audit artifact missing: $AUDIT"
  exit 1
fi

shopt -s nullglob
# 1. Every probe has a tag
for p in "$REPO"/tests/probes/probe-*.sh "$REPO"/tests/probes/probe-*.js; do
  base=$(basename "$p")
  if grep -qE '^(# |// )SAFE_FOR_LIVE: (yes|no)\b' "$p"; then
    echo "OK   $base has SAFE_FOR_LIVE tag"
    pass=$((pass+1))
  else
    echo "FAIL $base missing SAFE_FOR_LIVE tag"
    fail=$((fail+1))
  fi
done

# 2. Every probe is in the audit table
for p in "$REPO"/tests/probes/probe-*.sh "$REPO"/tests/probes/probe-*.js; do
  base=$(basename "$p")
  if grep -qE "^\| \`${base}\` \|" "$AUDIT"; then
    :
  else
    echo "FAIL $base not in SAFE_FOR_LIVE.md"
    fail=$((fail+1))
  fi
done

# 3. Every audit row corresponds to an actual file
while IFS= read -r line; do
  [[ "$line" =~ ^\|[[:space:]]*\`(probe-[^[:space:]]+)\`[[:space:]]*\| ]] || continue
  probe="${BASH_REMATCH[1]}"
  if [[ ! -f "$REPO/tests/probes/$probe" ]]; then
    echo "FAIL audit row references missing file: $probe"
    fail=$((fail+1))
  fi
done < "$AUDIT"

# 4. D-29 closure: row count == file count exactly
file_count=$(ls "$REPO"/tests/probes/probe-*.sh "$REPO"/tests/probes/probe-*.js 2>/dev/null | wc -l)
row_count=$(grep -cE '^\| `probe-[^|]+` \| (yes|no) \|' "$AUDIT")
if [[ "$file_count" -eq "$row_count" ]]; then
  echo "OK   D-29 row count ($row_count) == file count ($file_count)"
  pass=$((pass+1))
else
  echo "FAIL D-29 row count ($row_count) != file count ($file_count)"
  fail=$((fail+1))
fi

echo
echo "$pass passed, $fail failed"
exit $fail
