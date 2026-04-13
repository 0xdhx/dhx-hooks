#!/usr/bin/env bash
# dhx-citation-check.sh — Stop hook
# Patterns: HP-001, HP-002, HP-009
# Heuristic citation enforcement for conversational responses.
# Scans last_assistant_message for factual claims (dates, statistics,
# attributions) that lack a nearby URL. Command-type — zero API cost.
#
# Design: advisory block via JSON stdout. Does NOT use prompt-type
# evaluation (unreliable blocking per probe 2026-04-13). Trades
# precision for reliability — false positives are preferable to
# a hook that silently fails.
#
# Context: reports/2026-04-12-qual-stop-hook-citation-enforcement.md
# Satisfies: QUAL-01 (detect uncited claims), QUAL-02 (block/revise),
#            QUAL-03 (false-positive tuning via exclusion rules)

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then exit 0; fi

# --- HP-002: Loop prevention ---
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then exit 0; fi

# --- HP-001: Extract last_assistant_message ---
MSG=$(echo "$INPUT" | jq -r '.last_assistant_message // empty')
if [ -z "$MSG" ]; then exit 0; fi

# --- Gate: Skip short responses (< 80 chars) — greetings, confirmations ---
if [ "${#MSG}" -lt 80 ]; then exit 0; fi

# --- Gate: Skip responses that are predominantly code ---
# Count code fence lines vs total lines
TOTAL_LINES=$(echo "$MSG" | wc -l)
CODE_FENCE_COUNT=$(echo "$MSG" | grep -c '^```')
if [ "$CODE_FENCE_COUNT" -ge 2 ]; then
  # Estimate lines inside code blocks (rough: fences come in pairs)
  CODE_PAIRS=$((CODE_FENCE_COUNT / 2))
  # If more than 60% of response is likely code, skip
  if [ "$CODE_PAIRS" -ge 1 ] && [ "$TOTAL_LINES" -lt 20 ]; then
    exit 0
  fi
fi

# --- Strip code blocks before analysis ---
# Remove everything between ``` markers to avoid false positives on code
MSG_NO_CODE=$(echo "$MSG" | awk '/^```/{skip=!skip; next} !skip{print}')
if [ -z "$MSG_NO_CODE" ]; then exit 0; fi

# --- Detect factual claims ---
# Each pattern looks for a claim indicator WITHOUT a URL on the same line
# or within 2 lines (context window for inline citations)

CLAIMS=""

# Pattern 1: Year references (e.g., "in 2024", "since 1998", "founded 2015")
# Exclude: "v2.1.91", "HTTP/2", code-like patterns, line numbers
YEAR_CLAIMS=$(echo "$MSG_NO_CODE" | grep -nP '\b(in|since|founded|launched|released|published|created|established|circa|around)\s+\d{4}\b' | grep -vP 'https?://' | grep -vP 'v\d+\.' | grep -vP '^\s*#' | head -5)
if [ -n "$YEAR_CLAIMS" ]; then
  CLAIMS="${CLAIMS}${YEAR_CLAIMS}\n"
fi

# Pattern 2: Statistics (e.g., "42%", "3.5 million", "$2.4 billion")
# Note: \b after % is wrong — % is non-word so \b requires a word char boundary.
# Use (?!\w) for word-based units and no trailing boundary for % itself.
STAT_CLAIMS=$(echo "$MSG_NO_CODE" | grep -nP '\b\d+(\.\d+)?\s*%|\b\d+(\.\d+)?\s*(percent|million|billion|trillion|thousand)(?!\w)|\$\d+(\.\d+)?\s*(million|billion|trillion|M|B|T|k)(?!\w)' | grep -vP 'https?://' | grep -vP '^\s*[-*]?\s*(Exit|Return|Error|Status|Code)' | head -5)
if [ -n "$STAT_CLAIMS" ]; then
  CLAIMS="${CLAIMS}${STAT_CLAIMS}\n"
fi

# Pattern 3: Attribution phrases without URLs (case-insensitive — "According to" = "according to")
ATTR_CLAIMS=$(echo "$MSG_NO_CODE" | grep -niP '\b(according to|research (shows|suggests|indicates|found)|studies (show|suggest|indicate|found)|data (shows|suggests|indicates)|survey (found|shows|reveals))\b' | grep -viP 'https?://' | head -5)
if [ -n "$ATTR_CLAIMS" ]; then
  CLAIMS="${CLAIMS}${ATTR_CLAIMS}\n"
fi

# Pattern 4: Specific named studies/papers/reports without URLs (case-insensitive — "The DORA report" matches)
# Self-reference exclusion must match "this/that" immediately before the report noun (not anywhere on line)
NAMED_CLAIMS=$(echo "$MSG_NO_CODE" | grep -niP '\b(the\s+\w+\s+(report|study|paper|survey|analysis|review)\b)' | grep -viP 'https?://' | grep -viP '\b(this|that)\s+(report|study|paper|survey|analysis|review|investigation|probe|test|code)\b' | head -3)
if [ -n "$NAMED_CLAIMS" ]; then
  CLAIMS="${CLAIMS}${NAMED_CLAIMS}\n"
fi

# --- No claims found → allow stop ---
if [ -z "$CLAIMS" ]; then exit 0; fi

# --- Check if response already has citations ---
# If the response contains URLs, it's at least partially cited
URL_COUNT=$(echo "$MSG_NO_CODE" | grep -cP 'https?://')
CLAIM_COUNT=$(echo -e "$CLAIMS" | grep -c .)

# If there are more URLs than claims, likely well-cited
if [ "$URL_COUNT" -ge "$CLAIM_COUNT" ]; then exit 0; fi

# --- Format claim summary ---
CLAIM_SUMMARY=$(echo -e "$CLAIMS" | head -5 | sed 's/^/  /')

# --- Block with advisory ---
jq -n \
  --arg reason "$(printf 'Uncited factual claims detected (%d claims, %d citations):\n%s\n\nPlease add sources for these claims, or qualify them ("approximately", "I believe", "based on my training data").' "$CLAIM_COUNT" "$URL_COUNT" "$CLAIM_SUMMARY")" \
  '{"decision": "block", "reason": $reason}'

exit 0
