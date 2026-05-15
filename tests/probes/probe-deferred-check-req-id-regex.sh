#!/usr/bin/env bash
# probe-deferred-check-req-id-regex.sh
#
# Regression probe for the auto-silence REQ-ID regex consumed by
# dhx/dhx-deferred-check.sh.
#
# Invariant: the requirement-ID regex used to decide whether a deferred
# item "has a durable home" must match real requirement IDs (≥2-char
# leading alpha prefix) while rejecting GSD decision/question/fork
# labels (single-char prefix: D-NN, Q-NN, F-NN, A-NN). GSD labels
# appear pervasively in ROADMAP.md, REQUIREMENTS.md, milestones/, and
# backlog/ by design — if the regex matches them, any deferred item
# citing a decision gets silently silenced regardless of whether it
# has a real durable home.
#
# Source-of-truth: as of the 2026-05-02 cross-repo extraction, the regex
# lives in `auto_silence_deferred_lines` inside the canonical classifier
# at ~/.claude/dhx-tools/dhx-classify-deferred.sh (skills-repo authority).
# The hook sources that script and calls the helper; this probe extracts
# the regex from the canonical source rather than the hook so the
# invariant tracks the live definition.
#
# extended by the 2026-05-02 auto-silence-extraction row.
#
# Run: bash tests/probes/probe-deferred-check-req-id-regex.sh

# SAFE_FOR_LIVE: yes   (regex-equality static check against canonical script; no writes)
set -uo pipefail

CLASSIFIER="${DHX_TOOLS:-$HOME/.claude/dhx-tools}/dhx-classify-deferred.sh"

if [[ ! -r "$CLASSIFIER" ]]; then
  echo "FAIL canonical classifier not readable: $CLASSIFIER"
  exit 1
fi

# Extract the live regex from the `req_ids=` assignment inside
# auto_silence_deferred_lines. Anchoring the probe to the source (rather
# than a hard-coded copy) makes regressions loud: if the assignment moves
# or changes, the probe breaks visibly rather than validating a stale copy.
REGEX=$(grep -E '^[[:space:]]*req_ids=' "$CLASSIFIER" | head -1 | grep -oE "'[^']+'" | tr -d "'")

if [[ -z "$REGEX" ]]; then
  echo "FAIL could not extract req_ids regex from $CLASSIFIER"
  exit 1
fi

echo "Regex under test: $REGEX"
echo

PASS=0
FAIL=0

# --- Rejection cases: single-char prefix labels must NOT match ---
# These are GSD decision (D-NN), question (Q-NN), fork (F-NN), and
# generic single-letter (A-NN, B-NN) tokens. When the regex matches
# these, the auto-silence loop treats them as requirement IDs and
# silences the item if the token appears anywhere in planning files —
# which it always does for D-NN (discuss-finalize decisions summary).
for token in "D-19" "D-01" "D-42" "Q-03" "Q-17" "F-02" "F-09" "A-01" "B-05"; do
  match=$(echo "$token" | grep -oE "$REGEX" | head -1)
  if [[ -z "$match" ]]; then
    echo "OK   rejects $token (single-char prefix — GSD label)"
    PASS=$((PASS+1))
  else
    echo "FAIL $token matched (got '$match') — should reject"
    FAIL=$((FAIL+1))
  fi
done

# --- Acceptance cases: real requirement IDs must match in full ---
# Includes standard REQ prefixes, domain prefixes (DATA, STEL, QUAL,
# BACK), hook's own pattern IDs (HP), and short 2-char prefixes (UI, AI).
for token in "REQ-V2-004" "REQ-FEAT-12" "DATA-F01" "STEL-02" "QUAL-01" "BACK-01" "HP-001" "HP-002" "UI-03" "AI-07"; do
  match=$(echo "$token" | grep -oE "$REGEX" | head -1)
  if [[ "$match" == "$token" ]]; then
    echo "OK   matches $token (real requirement ID)"
    PASS=$((PASS+1))
  else
    echo "FAIL $token did not match (got '$match') — should match in full"
    FAIL=$((FAIL+1))
  fi
done

# --- Realistic item strings ---
# Full CONTEXT.md-style lines to catch edge cases in mixed-content extraction.

# Item citing only a D-NN label → no IDs → auto-silence skipped → surfaces
line1='Wider inline-vs-exit carve-out (see D-19 in ROADMAP)'
ids1=$(echo "$line1" | grep -oE "$REGEX" | head -3 | tr '\n' ' ' | sed 's/ *$//')
if [[ -z "$ids1" ]]; then
  echo "OK   item citing D-19 alone extracts no IDs (deferral surfaces to user)"
  PASS=$((PASS+1))
else
  echo "FAIL item citing D-19 alone extracted: '$ids1' — expected empty"
  FAIL=$((FAIL+1))
fi

# Item citing both a real REQ-ID and a D-NN → extract only the REQ-ID
line2='MCP elicitation rollback path — REQ-V2-004 (tracked under D-01)'
ids2=$(echo "$line2" | grep -oE "$REGEX" | head -3 | tr '\n' ' ' | sed 's/ *$//')
if [[ "$ids2" == *"REQ-V2-004"* && "$ids2" != *"D-01"* && "$ids2" != *"D-0"* ]]; then
  echo "OK   mixed line extracts REQ-V2-004, skips D-01: '$ids2'"
  PASS=$((PASS+1))
else
  echo "FAIL mixed line extracted '$ids2' — expected REQ-V2-004 only"
  FAIL=$((FAIL+1))
fi

# Item with multiple real IDs → all extracted (up to head -3 in hook)
line3='Cross-ref: DATA-F01 and QUAL-01 both gate STEL-02'
ids3=$(echo "$line3" | grep -oE "$REGEX" | head -3 | tr '\n' ' ' | sed 's/ *$//')
if [[ "$ids3" == *"DATA-F01"* && "$ids3" == *"QUAL-01"* && "$ids3" == *"STEL-02"* ]]; then
  echo "OK   multi-ID line extracts all three: '$ids3'"
  PASS=$((PASS+1))
else
  echo "FAIL multi-ID line extracted '$ids3' — expected DATA-F01 + QUAL-01 + STEL-02"
  FAIL=$((FAIL+1))
fi

# Prose with incidental single-letter-dash tokens (e.g., "A-team") must not match
line4='The A-team considered option B-1 before picking REQ-FEAT-12'
ids4=$(echo "$line4" | grep -oE "$REGEX" | head -3 | tr '\n' ' ' | sed 's/ *$//')
if [[ "$ids4" == *"REQ-FEAT-12"* && "$ids4" != *"A-team"* && "$ids4" != *"B-1"* ]]; then
  echo "OK   prose with A-team/B-1 noise extracts only REQ-FEAT-12: '$ids4'"
  PASS=$((PASS+1))
else
  echo "FAIL prose extraction returned '$ids4' — expected REQ-FEAT-12 only"
  FAIL=$((FAIL+1))
fi

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]
