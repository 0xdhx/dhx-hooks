#!/usr/bin/env bash
# tests/test-multi-cc-ver-corpus.sh — Nyquist regression test for Phase 15 (multi-cc-version probe matrix).
#
# Backs REQ MULTI-CC-VER-02..07 by asserting the cross-version corpus state
# committed in 10ef2f7 doesn't silently regress. The Phase 15 validator
# (scripts/verify-multi-cc-results.sh) already enforces JSON-shape invariants
# inside the corpus; this wrapper additionally checks the structural artifacts
# the validator does not touch (README mini-matrix, REQUIREMENTS checkbox
# state, decisions.md row counts, and the conditional promotion threshold).
#
# Run: bash tests/test-multi-cc-ver-corpus.sh
# Exit: 0 = all pass, 1 = any failure

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

VALIDATOR="$REPO_ROOT/scripts/verify-multi-cc-results.sh"
CORPUS_DIR="$REPO_ROOT/tests/probes/.results/v1.3-multi-cc-ver"
README="$REPO_ROOT/tests/probes/README.md"
# MULTI-CC-VER-* are v1.3-milestone REQs (Phase 15) — at v1.3 milestone close their
# rows were archived out of the active .planning/REQUIREMENTS.md (now the v1.4 set,
# no MULTI-CC-VER section) into .planning/milestones/v1.3-REQUIREMENTS.md. Test 5
# reads whichever file actually carries the rows: prefer the archived v1.3 file,
# fall back to the active file for any pre-archival checkout (2026-05-26: Test 5 was
# orphaned by the v1.3 archival until this repoint).
REQS="$REPO_ROOT/.planning/milestones/v1.3-REQUIREMENTS.md"
[[ -f "$REQS" ]] || REQS="$REPO_ROOT/.planning/REQUIREMENTS.md"
DECISIONS="$REPO_ROOT/docs/decisions.md"

[[ -r "$VALIDATOR" ]] || { echo "FATAL: validator not found at $VALIDATOR"; exit 1; }
[[ -d "$CORPUS_DIR" ]] || { echo "FATAL: corpus dir not found at $CORPUS_DIR"; exit 1; }

# ----- Test 1: MULTI-CC-VER-02..05 — validator green against committed corpus
test_01_validator_green() {
  echo "Test 1: validator exits 0 against the committed corpus (all 3 modes)"
  local rc
  bash "$VALIDATOR" >/dev/null 2>&1; rc=$?
  if [[ "$rc" -eq 0 ]]; then PASS=$((PASS+1)); echo "  PASS: 1a: default mode exit 0"; else FAIL=$((FAIL+1)); echo "  FAIL: 1a: default mode rc=$rc"; fi
  bash "$VALIDATOR" 2.1.140 >/dev/null 2>&1; rc=$?
  if [[ "$rc" -eq 0 ]]; then PASS=$((PASS+1)); echo "  PASS: 1b: explicit-version mode exit 0"; else FAIL=$((FAIL+1)); echo "  FAIL: 1b: explicit-version mode rc=$rc"; fi
  bash "$VALIDATOR" --all >/dev/null 2>&1; rc=$?
  if [[ "$rc" -eq 0 ]]; then PASS=$((PASS+1)); echo "  PASS: 1c: --all mode exit 0"; else FAIL=$((FAIL+1)); echo "  FAIL: 1c: --all mode rc=$rc"; fi
}

# ----- Test 2: MULTI-CC-VER-02/03 — 5 outcome JSONs at 2.1.140 path
test_02_corpus_count() {
  echo "Test 2: 5 outcome JSONs at v1.3-multi-cc-ver/2.1.140/"
  local count
  count=$(find "$CORPUS_DIR/2.1.140" -maxdepth 1 -name '*.json' -type f 2>/dev/null | wc -l)
  if [[ "$count" -eq 5 ]]; then PASS=$((PASS+1)); echo "  PASS: 2a: found 5 outcome JSONs"; else FAIL=$((FAIL+1)); echo "  FAIL: 2a: expected 5, got $count"; fi
}

# ----- Test 3: MULTI-CC-VER-06 — README mini-matrix structure
test_03_readme_mini_matrix() {
  echo "Test 3: README cross-version mini-matrix + HP-024 threshold note"
  if grep -q '^\*\*Cross-version corpus state (per-probe × per-CC-version):\*\*$' "$README"; then
    PASS=$((PASS+1)); echo "  PASS: 3a: mini-matrix header present"
  else
    FAIL=$((FAIL+1)); echo "  FAIL: 3a: missing 'Cross-version corpus state' header"
  fi
  # 5 probe rows in the CC 2.1.140 column (table line shape: | probe-...sh | ... | ... |).
  local probes=(probe-effort-level-stdin-absent probe-installed-plugins-no-natural-heal \
                probe-installed-plugins-badjson-natural-heal probe-installed-plugins-uninstalled-dhx-natural-heal \
                probe-known-marketplaces-natural-heal)
  local p missing=0
  for p in "${probes[@]}"; do
    grep -qE "^\| \`${p}\.sh\` \|.*\|.*v1\.3-multi-cc-ver/2\.1\.140/" "$README" || { missing=$((missing+1)); echo "  (debug) row missing for $p"; }
  done
  if [[ "$missing" -eq 0 ]]; then PASS=$((PASS+1)); echo "  PASS: 3b: all 5 probe rows present with 2.1.140 anchor"; else FAIL=$((FAIL+1)); echo "  FAIL: 3b: $missing probe rows missing from mini-matrix"; fi
  if grep -q 'HP-024 promotion trigger for supersession-watchdog corpus' "$README"; then
    PASS=$((PASS+1)); echo "  PASS: 3c: HP-024 promotion threshold trigger note present"
  else
    FAIL=$((FAIL+1)); echo "  FAIL: 3c: missing HP-024 promotion threshold note"
  fi
}

# ----- Test 4: MULTI-CC-VER-04/05 — 8 decisions.md rows from 2026-05-13
test_04_decisions_rows() {
  echo "Test 4: decisions.md has Phase 15 row payload"
  local d_count
  d_count=$(grep -cE '^\| 2026-05-13 \|' "$DECISIONS")
  if [[ "$d_count" -ge 8 ]]; then PASS=$((PASS+1)); echo "  PASS: 4a: $d_count rows dated 2026-05-13 (>= 8 expected)"; else FAIL=$((FAIL+1)); echo "  FAIL: 4a: expected >= 8 rows, got $d_count"; fi
  if grep -q 'HP-024 promotion trigger for supersession-watchdog corpus' "$DECISIONS"; then
    PASS=$((PASS+1)); echo "  PASS: 4b: HP-024 trigger row present"
  else
    FAIL=$((FAIL+1)); echo "  FAIL: 4b: missing HP-024 trigger row"
  fi
  if grep -q 'REQ MULTI-CC-VER-02 wording broadened' "$DECISIONS"; then
    PASS=$((PASS+1)); echo "  PASS: 4c: REQ-02 broadening row present"
  else
    FAIL=$((FAIL+1)); echo "  FAIL: 4c: missing REQ-02 broadening row"
  fi
}

# ----- Test 5: MULTI-CC-VER-02..07 — REQUIREMENTS.md checkbox state
test_05_requirements_checkboxes() {
  echo "Test 5: REQ MULTI-CC-VER-02..07 active checkboxes flipped to [x]"
  local id missing=0
  for id in MULTI-CC-VER-02 MULTI-CC-VER-03 MULTI-CC-VER-04 MULTI-CC-VER-05 MULTI-CC-VER-06 MULTI-CC-VER-07; do
    grep -qE "^- \[x\] \*\*${id}\*\*" "$REQS" || { missing=$((missing+1)); echo "  (debug) ${id} not [x]"; }
  done
  if [[ "$missing" -eq 0 ]]; then PASS=$((PASS+1)); echo "  PASS: 5a: 6/6 active checkboxes flipped"; else FAIL=$((FAIL+1)); echo "  FAIL: 5a: $missing checkboxes still [ ]"; fi
}

# ----- Test 6: MULTI-CC-VER-07 — conditional promotion threshold (corpus < 3 → not triggered)
test_06_promotion_threshold() {
  echo "Test 6: MULTI-CC-VER-07 promotion threshold conditional state"
  # Count distinct CC-version cells per probe in v1.3-multi-cc-ver/. Threshold is 3.
  local cc_dirs
  cc_dirs=$(find "$CORPUS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
  # MULTI-CC-VER-07 is satisfied EITHER when corpus < 3 (deferred — no action required)
  # OR when corpus >= 3 AND a multi-cell HP-024 matrix exists. Test the conditional.
  if [[ "$cc_dirs" -lt 3 ]]; then
    PASS=$((PASS+1)); echo "  PASS: 6a: corpus=$cc_dirs CC version(s) < 3 — promotion not triggered (deferred-by-design)"
  else
    # When corpus >= 3, the matrix marker must exist in README.
    if grep -q 'Multi-cell matrix protocol (SCHEMA-04)' "$README"; then
      PASS=$((PASS+1)); echo "  PASS: 6a: corpus=$cc_dirs >= 3 and SCHEMA-04 matrix protocol present"
    else
      FAIL=$((FAIL+1)); echo "  FAIL: 6a: corpus=$cc_dirs >= 3 but no SCHEMA-04 matrix promoted"
    fi
  fi
}

test_01_validator_green
test_02_corpus_count
test_03_readme_mini_matrix
test_04_decisions_rows
test_05_requirements_checkboxes
test_06_promotion_threshold

echo
print_results
