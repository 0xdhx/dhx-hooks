#!/usr/bin/env bash
# dhx-deferred-check.sh — Stop hook
# Surfaces UNASSESSED deferred items from CONTEXT.md before context clears.
# Batch presents all items with brief recommendations, then walks through
# each via AskUserQuestion. 'discuss' option gives deeper reasoning.
#
# Marker protocol — any of these silence the hook for an item:
#   [captured]  or [captured: ticket]  — captured to backlog/todo via /dhx:capture
#   [existing]  or [existing: path]    — already has a durable home
#   [assessed]  or [assessed: reason]  — user confirmed: intentionally not captured
#   [tracked: REQ-ID]                  — tracked against a requirement
#   ~~item~~                           — strikethrough (legacy compat)
#
# Matching is prefix-based: [assessed matches [assessed], [assessed: ...], etc.
#
# CRITICAL: [assessed] requires EXPLICIT USER APPROVAL. The agent must present
# the item, give its assessment, and WAIT for the user to confirm. The
# dhx-assessed-guard.sh PreToolUse hook enforces this mechanically.

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then exit 0; fi

# Loop prevention: Claude Code sets this after one block to avoid infinite loops.
# We respect it — the block message instructs the agent to complete the full
# review protocol before attempting to stop again.
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then exit 0; fi

CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
if [ -z "$CWD" ]; then exit 0; fi

# Gate: GSD project check
if [ ! -d "$CWD/.planning/phases" ]; then exit 0; fi

# Find most recent CONTEXT.md
LATEST=$(ls -t "$CWD"/.planning/phases/*/*-CONTEXT.md 2>/dev/null | head -1)
if [ -z "$LATEST" ]; then exit 0; fi

# Extract deferred section
DEFERRED=$(sed -n '/<deferred>/,/<\/deferred>/p' "$LATEST" 2>/dev/null)
if [ -z "$DEFERRED" ]; then exit 0; fi

# Check for "None" placeholder — anchored to avoid matching "none" mid-sentence
if echo "$DEFERRED" | grep -qE '^\s*-?\s*[Nn]one(\s*$|\s+—)'; then exit 0; fi

# Find unassessed items — filter out ALL recognized markers (prefix match)
RAW_ITEMS=$(echo "$DEFERRED" | grep -E '^\s*- ' \
  | grep -v '\[captured' \
  | grep -v '\[existing' \
  | grep -v '\[assessed' \
  | grep -v '\[tracked' \
  | grep -v '^\s*-\s*~~' \
  | sed 's/^\s*- //')
if [ -z "$RAW_ITEMS" ]; then exit 0; fi

# Auto-silence: skip items that already have durable homes
UNCAPTURED=""
while IFS= read -r item; do
  HAS_HOME=false

  # Check 1: requirement IDs (DATA-F01, QUAL-01, etc.)
  REQ_IDS=$(echo "$item" | grep -oE '[A-Z]+-[A-Z]?[0-9]+' | head -3)
  for rid in $REQ_IDS; do
    if grep -q "$rid" "$CWD/.planning/REQUIREMENTS.md" 2>/dev/null; then
      HAS_HOME=true
      break
    fi
    if grep -rl "$rid" "$CWD/.planning/backlog/" 2>/dev/null | head -1 | grep -q .; then
      HAS_HOME=true
      break
    fi
  done

  # Check 2: referenced .md filenames — any format (backtick, parens, bare)
  if [ "$HAS_HOME" = false ]; then
    REF_FILES=$(echo "$item" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9-]+\.md' | sort -u)
    for bf in $REF_FILES; do
      bname=$(basename "$bf")
      if [ -f "$CWD/.planning/backlog/$bname" ] || \
         find "$CWD/.planning/todos" -name "$bname" 2>/dev/null | head -1 | grep -q .; then
        HAS_HOME=true
        break
      fi
    done
  fi

  if [ "$HAS_HOME" = false ]; then
    UNCAPTURED="${UNCAPTURED}${item}
"
  fi
done <<< "$RAW_ITEMS"
UNCAPTURED=$(echo "$UNCAPTURED" | sed '/^$/d')
if [ -z "$UNCAPTURED" ]; then exit 0; fi

# Count and format
COUNT=$(echo "$UNCAPTURED" | wc -l | tr -d ' ')
ITEM_LIST=$(echo "$UNCAPTURED" | sed 's/^/  - /')

# Signal that deferred review is active (assessed-guard checks this)
REVIEW_MARKER="/tmp/dhx-deferred-review-$(echo "$CWD" | md5sum | cut -d' ' -f1 2>/dev/null || echo "default")"
touch "$REVIEW_MARKER"

MSG="DEFERRED ITEM REVIEW — ${COUNT} unassessed item(s).

${ITEM_LIST}

For each: numbered list with recommendation, then AskUserQuestion (capture/existing/assessed/discuss). 'discuss' = full assessment then re-ask. [assessed] requires explicit user selection — never self-mark. Complete all before session end.

After disposition, mark each item in ${LATEST} with its tag ([captured], [existing], [assessed]) to silence this hook."

jq -n --arg msg "$MSG" \
  '{"decision": "block", "reason": $msg}'

exit 0
