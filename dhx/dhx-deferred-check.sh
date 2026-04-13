#!/usr/bin/env bash
# dhx-deferred-check.sh — Stop hook
# Patterns: HP-001, HP-002, HP-004, HP-005, HP-006, HP-009
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

# Build STATE.md phase allowlist — same logic as dhx-execute-stop-review.sh.
# Restricts CONTEXT.md discovery to phases STATE.md says Claude is actively
# working on. Kills bulk-restore false positives where historical CONTEXT.md
# files get fresh mtimes via `git checkout <sha> -- .planning/` and `ls -t`
# then picks an ancient phase's deferred items.
#
# See dhx-execute-stop-review.sh:49-93 for the rationale behind N-1 fallback
# and the field list below.
STATE_FILE="$CWD/.planning/STATE.md"
PHASE_ALLOWLIST=""
if [ -f "$STATE_FILE" ]; then
  SIGNAL_LINES=$(grep -E '^stopped_at:|^\*\*Phase:\*\*|^\*\*Current Phase:\*\*|^\*\*Current focus:\*\*|^\*\*Last Activity Description:\*\*|^\*\*Last activity description:\*\*' "$STATE_FILE" 2>/dev/null)
  STATE_NUMS=$({
    printf '%s\n' "$SIGNAL_LINES" | grep -oE '[Pp]hase[[:space:]]+[0-9]+(\.[0-9]+)?' | sed 's/^[Pp]hase[[:space:]]*//'
    printf '%s\n' "$SIGNAL_LINES" | grep -oE '^\*\*(Current )?Phase:\*\*[[:space:]]+[0-9]+(\.[0-9]+)?' | sed -E 's/^\*\*[^*]+\*\*[[:space:]]*//'
  } | sort -u | grep -v '^$')

  if [ -n "$STATE_NUMS" ]; then
    for n in $STATE_NUMS; do
      n_int=$(echo "$n" | grep -oE '^[0-9]+' | sed 's/^0*//')
      [ -z "$n_int" ] && n_int="0"
      PHASE_ALLOWLIST="${PHASE_ALLOWLIST} ${n_int}"
      if [ "$n_int" -gt 0 ]; then
        PHASE_ALLOWLIST="${PHASE_ALLOWLIST} $((n_int - 1))"
      fi
    done
    PHASE_ALLOWLIST=$(echo "$PHASE_ALLOWLIST" | tr ' ' '\n' | sort -u | grep -v '^$')
  fi
fi

# Find most recent CONTEXT.md — filtered to allowlisted phases if available,
# otherwise fall back to unfiltered (preserves old behavior when STATE.md
# is missing or unparseable).
LATEST=""
if [ -n "$PHASE_ALLOWLIST" ]; then
  while IFS= read -r candidate; do
    [ -z "$candidate" ] && continue
    dir_name=$(basename "$(dirname "$candidate")")
    phase_from_dir=$(echo "$dir_name" | grep -oE '^[0-9]+' | sed 's/^0*//')
    [ -z "$phase_from_dir" ] && phase_from_dir="0"
    if echo "$PHASE_ALLOWLIST" | grep -qFx "$phase_from_dir"; then
      LATEST="$candidate"
      break
    fi
  done <<< "$(ls -t "$CWD"/.planning/phases/*/*-CONTEXT.md 2>/dev/null)"
  # If allowlist exists but nothing matched, there's nothing relevant to
  # review — skip the hook rather than falling back to an unrelated phase.
  [ -z "$LATEST" ] && exit 0
else
  LATEST=$(ls -t "$CWD"/.planning/phases/*/*-CONTEXT.md 2>/dev/null | head -1)
fi
if [ -z "$LATEST" ]; then exit 0; fi

# Extract deferred section.
# Line-anchored patterns prevent body-prose mentions of `<deferred>` (e.g.
# "(See `<deferred>` below)" inside a decision) from shifting the sed range
# start into the middle of the document. The discuss template always places
# <deferred>/</deferred> tags alone on their own line — see
# ~/.claude/dhx/references/discuss-templates.md. Reported 2026-04-11,
# reports/2026-04-11-deferred-check-sed-tag-collision.md.
#
# When tag extraction returns empty, a secondary fallback checks for deferred
# items under markdown headers (## Deferred / ## Deferred Ideas). This catches
# content placed outside the tagged section — see Gap 1 in
# reports/2026-04-12-context-tag-corpus-analysis.md.
#
# Header-fallback: when the <deferred> tag section is missing OR present but
# empty (no bullets), check for deferred items under markdown headers
# (## Deferred / ## Deferred Ideas). This catches Edge Cases 1 and 2 from
# the corpus analysis. The fallback fires from two branches: (a) empty sed
# extraction and (b) non-empty extraction but zero bullet items after filtering.
check_header_fallback() {
  local file="$1"
  MD_DEFERRED=$(sed -n '/^##.*[Dd]eferred/,/^##[^#]/p' "$file" 2>/dev/null \
    | grep -E '^\s*- ')
  if [ -n "$MD_DEFERRED" ]; then
    COUNT=$(echo "$MD_DEFERRED" | wc -l | tr -d ' ')
    jq -n --arg msg "WARNING: ${COUNT} deferred item(s) found under markdown headers in ${file} but the <deferred> section is empty or missing. Items may not be tracked. Run /dhx:defer-review to inspect." \
      '{"decision": "block", "reason": $msg}'
    exit 0
  fi
  exit 0
}

DEFERRED=$(sed -n '/^[[:space:]]*<deferred>[[:space:]]*$/,/^[[:space:]]*<\/deferred>[[:space:]]*$/p' "$LATEST" 2>/dev/null)
if [ -z "$DEFERRED" ]; then
  check_header_fallback "$LATEST"
fi

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
if [ -z "$RAW_ITEMS" ]; then check_header_fallback "$LATEST"; fi

# Auto-silence: skip items that already have durable homes
UNCAPTURED=""
while IFS= read -r item; do
  HAS_HOME=false

  # Check 1: requirement IDs (DATA-F01, QUAL-01, REQ-V2-004, etc.)
  # Regex captures multi-segment IDs — the old [A-Z]+-[A-Z]?[0-9]+ pattern
  # truncated `REQ-V2-004` to `REQ-V2` and dropped the numeric suffix.
  REQ_IDS=$(echo "$item" | grep -oE '[A-Z]+(-[A-Z0-9]+)+' | head -3)
  for rid in $REQ_IDS; do
    # Current-milestone requirements
    if grep -q "$rid" "$CWD/.planning/REQUIREMENTS.md" 2>/dev/null; then
      HAS_HOME=true
      break
    fi
    # Active roadmap — catches requirements parked for future milestones
    # (e.g., REQ-V2-004 pre-scoped in v1.1 under a v2.0 section)
    if grep -q "$rid" "$CWD/.planning/ROADMAP.md" 2>/dev/null; then
      HAS_HOME=true
      break
    fi
    # Milestone-scoped requirements files (v1.1-REQUIREMENTS.md etc.)
    if grep -rq "$rid" "$CWD/.planning/milestones/" --include='*REQUIREMENTS*.md' 2>/dev/null; then
      HAS_HOME=true
      break
    fi
    # Backlog
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

MSG="DEFERRED ITEM REVIEW — ${COUNT} unassessed item(s) in ${LATEST}.

Invoke /dhx:defer-review ${LATEST} to resolve before session end."

jq -n --arg msg "$MSG" \
  '{"decision": "block", "reason": $msg}'

exit 0
