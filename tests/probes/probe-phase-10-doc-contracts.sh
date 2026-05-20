#!/bin/bash
# probe-phase-10-doc-contracts.sh
#
# SAFE_FOR_LIVE: yes   (read-only token-presence checks against committed docs;
#                       no subprocesses, no mutation, no sandbox needed)
#
# # Patterns: HP-025
#
# INVARIANT: HP-025 § Remediation hook block (docs/hook-patterns.md) and the
# Phase 10 GREEN+RED decisions.md rows (docs/decisions.md) carry the cross-AI
# hardening contract — 4 detector states (incl. STALE:dhx-local-installLocation),
# D-14 BADJSON WARN literal, Phase 10.1 cache-staleness backlog pointer, G-01
# probe-count single source of truth (8 → 13, never 8 → 12, never
# ${SCENARIO_COUNT} template residue), and the Plan 2 GREEN / Plan 1 RED
# bisectable audit pair with full D-12..D-14 + G-01..G-07 enumeration. This
# probe protects against doc-drift in either file silently regressing the
# Phase 10 contract that VERIFICATION.md (2026-05-13 passed) attested to.
#
# Backs:
#   - .planning/phases/10-heal-hook-km-path-hardening-heal-07/10-VERIFICATION.md
#     (HEAL-07-06 + HEAL-07-07 documentation deliverables — closed Nyquist gaps)
#   - docs/hook-patterns.md HP-025 § Remediation (lines 1464-1555 at landing)
#   - docs/decisions.md 2026-05-13 Plan 2 GREEN + Plan 1 RED scaffolding rows
#
# Run: bash tests/probes/probe-phase-10-doc-contracts.sh
set -uo pipefail

PROBE_REPO_ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || echo "/home/dhx/repos/hooks")
HP_FILE="$PROBE_REPO_ROOT/docs/hook-patterns.md"
DEC_FILE="$PROBE_REPO_ROOT/docs/decisions.md"
REQ_FILE="$PROBE_REPO_ROOT/.planning/REQUIREMENTS.md"

PASS=0
FAIL=0

# ----------------------------------------------------------------------------
# Pre-flight: every probed file must exist (catches accidental relocations).
# ----------------------------------------------------------------------------
# HP_FILE and DEC_FILE are permanent project docs — must exist.
for f in "$HP_FILE" "$DEC_FILE"; do
  if [[ -f "$f" ]]; then
    echo "OK   file-exists: $f"
    PASS=$((PASS+1))
  else
    echo "FAIL file-exists: $f missing"
    FAIL=$((FAIL+1))
  fi
done

# REQ_FILE is a milestone artifact (archived at v1.3 close, cfa5997).
# If present, exercise the regression sentinel below; if absent, skip cleanly.
REQ_FILE_PRESENT=false
if [[ -f "$REQ_FILE" ]]; then
  REQ_FILE_PRESENT=true
  echo "OK   file-exists: $REQ_FILE"
  PASS=$((PASS+1))
else
  echo "SKIP file-exists: $REQ_FILE absent (archived at v1.3 milestone close, cfa5997)"
fi

# ============================================================================
# HEAL-07-06 — HP-025 § Remediation hook rewrite (docs/hook-patterns.md)
# ============================================================================

# Detector state #4 literal — accept either canonical spelling (state-token
# form `STALE:dhx-local-installLocation` per gap spec primary OR identifier
# form `STALE_INSTALLLOCATION` as fallback per gap spec OR clause).
state4_count=$(grep -cF 'STALE:dhx-local-installLocation' "$HP_FILE")
state4_alt_count=$(grep -cF 'STALE_INSTALLLOCATION' "$HP_FILE")
if [[ "$state4_count" -ge 1 || "$state4_alt_count" -ge 1 ]]; then
  echo "OK   HEAL-07-06 detector-state-4-literal: STALE:dhx-local-installLocation=$state4_count STALE_INSTALLLOCATION=$state4_alt_count"
  PASS=$((PASS+1))
else
  echo "FAIL HEAL-07-06 detector-state-4-literal: neither STALE:dhx-local-installLocation nor STALE_INSTALLLOCATION present in $HP_FILE"
  FAIL=$((FAIL+1))
fi

# D-14 BADJSON WARN signalling literal.
badjson_count=$(grep -cF 'WARN: BADJSON recovery' "$HP_FILE")
if [[ "$badjson_count" -ge 1 ]]; then
  echo "OK   HEAL-07-06 d14-badjson-warn-literal: count=$badjson_count"
  PASS=$((PASS+1))
else
  echo "FAIL HEAL-07-06 d14-badjson-warn-literal: 'WARN: BADJSON recovery' missing from $HP_FILE"
  FAIL=$((FAIL+1))
fi

# Phase 10.1 cache-staleness backlog pointer (out-of-scope linkage for HEAL-07-08).
cache_brief_count=$(grep -cF 'plugin-cache-hooks-json-staleness-detector' "$HP_FILE")
if [[ "$cache_brief_count" -ge 1 ]]; then
  echo "OK   HEAL-07-06 phase-10.1-cache-brief-pointer: count=$cache_brief_count"
  PASS=$((PASS+1))
else
  echo "FAIL HEAL-07-06 phase-10.1-cache-brief-pointer: 'plugin-cache-hooks-json-staleness-detector' missing from $HP_FILE"
  FAIL=$((FAIL+1))
fi

# G-01 probe-count single source of truth: must be `8 → 13`, never `8 → 12`,
# never ${SCENARIO_COUNT} template residue. All three checks fire together.
scenario_count=$(grep -cF '8 → 13 scenarios' "$HP_FILE")
if [[ "$scenario_count" -ge 1 ]]; then
  echo "OK   HEAL-07-06 g01-probe-count-13: count=$scenario_count"
  PASS=$((PASS+1))
else
  echo "FAIL HEAL-07-06 g01-probe-count-13: '8 → 13 scenarios' missing from $HP_FILE"
  FAIL=$((FAIL+1))
fi

stale_count_drift=$(grep -cF '8 → 12' "$HP_FILE")
if [[ "$stale_count_drift" -eq 0 ]]; then
  echo "OK   HEAL-07-06 g01-no-count-regression: '8 → 12' absent (count=0)"
  PASS=$((PASS+1))
else
  echo "FAIL HEAL-07-06 g01-no-count-regression: '8 → 12' present (count=$stale_count_drift) — G-01 count drifted backward"
  FAIL=$((FAIL+1))
fi

template_residue=$(grep -cF '${SCENARIO_COUNT}' "$HP_FILE")
if [[ "$template_residue" -eq 0 ]]; then
  echo "OK   HEAL-07-06 g01-no-template-residue: \${SCENARIO_COUNT} absent (count=0)"
  PASS=$((PASS+1))
else
  echo "FAIL HEAL-07-06 g01-no-template-residue: \${SCENARIO_COUNT} present (count=$template_residue) — G-01 sed-rewrite skipped"
  FAIL=$((FAIL+1))
fi

# Predecessor Wj() natural-heal asymmetry block preserved — surrounding
# HP-025 context that the Phase 10 § Remediation rewrite sits inside.
wj_count=$(grep -cF 'Wj()' "$HP_FILE")
if [[ "$wj_count" -ge 1 ]]; then
  echo "OK   HEAL-07-06 wj-predecessor-context: count=$wj_count"
  PASS=$((PASS+1))
else
  echo "FAIL HEAL-07-06 wj-predecessor-context: 'Wj()' missing from $HP_FILE — Natural-heal asymmetry block evicted"
  FAIL=$((FAIL+1))
fi

# Negative invariant: pre-km-rescope text drift fix (REQUIREMENTS.md must NOT
# reference 'expected cache roots' — the canonical phrasing is 'expected
# marketplace roots' per the 2026-05-03 km rescope anchor).
# Guarded by REQ_FILE_PRESENT — sentinel auto-rearms if a future milestone
# reintroduces REQUIREMENTS.md; skips cleanly while archived.
if [[ "$REQ_FILE_PRESENT" == "true" ]]; then
  req_drift=$(grep -cF 'expected cache roots' "$REQ_FILE")
  if [[ "$req_drift" -eq 0 ]]; then
    echo "OK   HEAL-07-06 req-no-pre-rescope-drift: 'expected cache roots' absent from REQUIREMENTS.md (count=0)"
    PASS=$((PASS+1))
  else
    echo "FAIL HEAL-07-06 req-no-pre-rescope-drift: 'expected cache roots' present in REQUIREMENTS.md (count=$req_drift) — km-rescope text drift fix regressed"
    FAIL=$((FAIL+1))
  fi
else
  echo "SKIP HEAL-07-06 req-no-pre-rescope-drift: REQUIREMENTS.md absent (no regression surface; sentinel re-arms if/when file returns)"
fi

# ============================================================================
# HEAL-07-07 — docs/decisions.md GREEN + RED rows (Phase 10 hardening audit)
# ============================================================================

# Plan 2 GREEN subject token (2026-05-13 GREEN row identifier).
green_count=$(grep -cF 'Plan 2 GREEN' "$DEC_FILE")
if [[ "$green_count" -ge 1 ]]; then
  echo "OK   HEAL-07-07 plan2-green-row: count=$green_count"
  PASS=$((PASS+1))
else
  echo "FAIL HEAL-07-07 plan2-green-row: 'Plan 2 GREEN' missing from $DEC_FILE"
  FAIL=$((FAIL+1))
fi

# Plan 1 RED scaffolding subject token (2026-05-13 RED row preserved).
red_count=$(grep -cF 'Plan 1 RED scaffolding' "$DEC_FILE")
if [[ "$red_count" -ge 1 ]]; then
  echo "OK   HEAL-07-07 plan1-red-scaffolding-row: count=$red_count"
  PASS=$((PASS+1))
else
  echo "FAIL HEAL-07-07 plan1-red-scaffolding-row: 'Plan 1 RED scaffolding' missing from $DEC_FILE"
  FAIL=$((FAIL+1))
fi

# Cross-AI hardening token enumeration — every D/G ID from the gap spec must
# appear at least once in decisions.md.
hardening_missing=0
for tok in D-12 D-13 D-14 G-01 G-02 G-03 G-06 G-07; do
  c=$(grep -cF "$tok" "$DEC_FILE")
  if [[ "$c" -ge 1 ]]; then
    echo "OK   HEAL-07-07 hardening-token-$tok: count=$c"
    PASS=$((PASS+1))
  else
    echo "FAIL HEAL-07-07 hardening-token-$tok: $tok missing from $DEC_FILE"
    FAIL=$((FAIL+1))
    hardening_missing=$((hardening_missing+1))
  fi
done

# Date anchor: 2026-05-13 must appear at least 2 times (GREEN row + RED row at
# minimum — gap spec asserts ≥2).
date_count=$(grep -cF '2026-05-13' "$DEC_FILE")
if [[ "$date_count" -ge 2 ]]; then
  echo "OK   HEAL-07-07 date-anchor-2026-05-13: count=$date_count (≥2 required)"
  PASS=$((PASS+1))
else
  echo "FAIL HEAL-07-07 date-anchor-2026-05-13: count=$date_count (<2) — GREEN or RED row date stripped"
  FAIL=$((FAIL+1))
fi

# ----------------------------------------------------------------------------
# Summary + exit
# ----------------------------------------------------------------------------
echo "---"
echo "PASS: $PASS FAIL: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
