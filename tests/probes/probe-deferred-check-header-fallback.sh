#!/usr/bin/env bash
# probe-deferred-check-header-fallback.sh
#
# Regression probe for dhx/dhx-deferred-check.sh check_header_fallback() sed range.
#
# Invariant: the header-fallback sed start pattern must anchor to exactly-two-`#`
# headers (`## Deferred Ideas`), NOT to three-or-more-`#` subheaders that happen
# to contain the word "deferred" (`### Theme N: ... (deferred)`). The end pattern
# already enforces `^##[^#]`; the start pattern must match. When the start is
# under-anchored (`^##.*[Dd]eferred`), a `###` subheader anchors the sed range
# and sweeps every `-` bullet up to the next top-level `##` section into the
# fallback — producing spurious "N deferred item(s)" warnings on session-end.
#
# Parity: tests/lib.sh header_fallback_filtered() must use the byte-identical
# sed pattern. Drift between the hook and the test helper has caused prior
# regressions (production-parity is load-bearing).
#
# Backs: docs/decisions.md 2026-04-23 header-fallback h3 overmatch row.
# Parent report: reports/done/2026-04-23-deferred-check-header-fallback-matches-h3.md
#
# Run: bash tests/probes/probe-deferred-check-header-fallback.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$REPO_ROOT/dhx/dhx-deferred-check.sh"
LIB="$REPO_ROOT/tests/lib.sh"
FIXTURE="$REPO_ROOT/tests/fixtures/h3-deferred-annotation.md"

for f in "$HOOK" "$LIB" "$FIXTURE"; do
  if [[ ! -r "$f" ]]; then
    echo "FAIL required file not readable: $f"
    exit 1
  fi
done

# Extract the live sed -n range from the hook (first occurrence in
# check_header_fallback). Anchoring the probe to the source — not a hard-coded
# copy — makes regressions loud: if the pattern changes or the line moves,
# the probe breaks visibly rather than validating a stale copy.
HOOK_SED=$(grep -E "sed -n '/\^##" "$HOOK" | head -1 | grep -oE "'/\^[^']+/p'" | tr -d "'")
LIB_SED=$(grep -E "sed -n '/\^##" "$LIB" | head -1 | grep -oE "'/\^[^']+/p'" | tr -d "'")

if [[ -z "$HOOK_SED" ]]; then
  echo "FAIL could not extract sed range from $HOOK"
  exit 1
fi
if [[ -z "$LIB_SED" ]]; then
  echo "FAIL could not extract sed range from $LIB"
  exit 1
fi

echo "Hook sed range: $HOOK_SED"
echo "Lib  sed range: $LIB_SED"
echo

PASS=0
FAIL=0

check() {
  local label="$1"
  local ok="$2"
  if [[ "$ok" == "1" ]]; then
    echo "OK   $label"
    PASS=$((PASS+1))
  else
    echo "FAIL $label"
    FAIL=$((FAIL+1))
  fi
}

# --- Source-level invariants ---

# 1. Hook start pattern anchors to exactly-two-`#` via `[^#]`.
#    Guards against reverting to the under-anchored `^##.*[Dd]eferred` shape.
if [[ "$HOOK_SED" == *"^##[^#]"*"[Dd]eferred"* ]]; then
  check "hook start pattern contains '^##[^#]' anchor before '[Dd]eferred'" 1
else
  check "hook start pattern contains '^##[^#]' anchor before '[Dd]eferred'" 0
fi

# 2. Production parity: hook and test helper use byte-identical sed ranges.
#    Drift here has caused prior regressions.
if [[ "$HOOK_SED" == "$LIB_SED" ]]; then
  check "hook and tests/lib.sh sed ranges are byte-identical (production parity)" 1
else
  check "hook and tests/lib.sh sed ranges diverge — hook='$HOOK_SED' lib='$LIB_SED'" 0
fi

# --- Behavioral invariants against the fixture ---

# Mirror of the hook's filter chain (check_header_fallback body).
# INVARIANT: this chain must stay in sync with dhx-deferred-check.sh:110-116
# and tests/lib.sh:42-48. Chain divergence is caught by the parity check above
# for sed; the grep filters below are stable across the three prior revisions.
run_fallback() {
  local range="$1"
  local file="$2"
  eval "sed -n $range \"\$file\"" 2>/dev/null \
    | grep -E '^\s*- ' \
    | grep -v '\[captured' \
    | grep -v '\[existing' \
    | grep -v '\[assessed' \
    | grep -v '\[tracked' \
    | grep -v '^\s*-\s*~~'
}

# 3. Live pattern against fixture: exactly one bullet survives the filter chain.
RESULT=$(run_fallback "'$HOOK_SED'" "$FIXTURE")
LINE_COUNT=$(echo "$RESULT" | sed '/^$/d' | wc -l | tr -d ' ')
if [[ "$LINE_COUNT" == "1" ]]; then
  check "fixture produces exactly 1 bullet after filter chain (live pattern)" 1
else
  check "fixture produced $LINE_COUNT bullets (expected 1) — result: $RESULT" 0
fi

# 4. The surviving bullet is the real deferred item from the <deferred> section.
if echo "$RESULT" | grep -q "Real deferred item that SHOULD be caught"; then
  check "surviving bullet is the real '## Deferred Ideas' item" 1
else
  check "real deferred item missing from result: $RESULT" 0
fi

# 5-7. None of the three theme body bullets (D-11, D-12, D-13) under the
# `### Theme N` subheaders leak into the result. These are decisions, not
# deferrals — overmatch sweeps them in when the start pattern is under-anchored.
for needle in \
  "Theme body bullet should not appear" \
  "Another theme body bullet that belongs to decisions" \
  "Yet another theme body bullet not meant for the deferred review"; do
  if echo "$RESULT" | grep -qF "$needle"; then
    check "theme body bullet NOT swept: '$needle'" 0
  else
    check "theme body bullet NOT swept: '${needle:0:40}...'" 1
  fi
done

# --- Start-pattern anchor check (positive + negative) ---

# 8. Positive: `## Deferred Ideas` matches the start pattern (fallback still
#    fires on legitimate h2 headers — the whole point of the fallback path).
START_PAT=$(echo "$HOOK_SED" | grep -oE "/\^[^/]+/" | head -1 | sed 's|^/||;s|/$||')
if echo "## Deferred Ideas" | grep -qE "$START_PAT"; then
  check "start pattern matches '## Deferred Ideas' (positive case — fallback still fires)" 1
else
  check "start pattern did NOT match '## Deferred Ideas' — fallback broken" 0
fi

# 9. Negative: `### Theme 6: Cat-4 ephemeral signals (deferred)` must NOT match.
#    This is the exact line from forgefinder Phase 26 CONTEXT.md that triggered
#    the 19-phantom-items warning before the fix.
if echo "### Theme 6: Cat-4 ephemeral signals (deferred)" | grep -qE "$START_PAT"; then
  check "start pattern rejects '### ...(deferred)' subheader (the reported bug)" 0
else
  check "start pattern rejects '### ...(deferred)' subheader (the reported bug)" 1
fi

# 10. Negative: `#### (deferred)` h4 also rejected (defense in depth — same class).
if echo "#### Something deferred" | grep -qE "$START_PAT"; then
  check "start pattern rejects '#### ... deferred' h4 subheader" 0
else
  check "start pattern rejects '#### ... deferred' h4 subheader" 1
fi

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]
