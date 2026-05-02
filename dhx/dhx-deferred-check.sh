#!/usr/bin/env bash
# dhx-deferred-check.sh — Stop hook
# Patterns: HP-001, HP-002, HP-004, HP-005, HP-006, HP-009, HP-028
# Surfaces UNASSESSED deferred items from CONTEXT.md before context clears.
# Batch presents all items with brief recommendations, then walks through
# each via AskUserQuestion. 'discuss' option gives deeper reasoning.
#
# Marker protocol — any of these silence the hook for an item. Recognized as
# prefix OR end-of-bullet bracketed token:
#   [captured]  or [captured: ticket]  — captured to backlog/todo via /dhx:capture
#   [existing]  or [existing: path]    — already has a durable home
#   [assessed]  or [assessed: reason]  — user confirmed: intentionally not captured
#   [tracked: REQ-ID]                  — tracked against a requirement
#   [note]      or [note: detail]      — non-actionable decision-trail commentary
#   ~~item~~                           — strikethrough (legacy compat)
#
# Filter logic is canonical at ~/.claude/dhx-tools/dhx-classify-deferred.sh —
# this hook sources that script and calls classify_deferred_lines on the
# deferred block. Drift between this hook and the skills-repo consumers
# (/dhx:defer-review, /dhx:backlog audit, /dhx:capture) is enforced by
# ~/repos/skills/tests/probe-classifier-cross-repo.sh.
#
# CRITICAL: [assessed] requires EXPLICIT USER APPROVAL. The agent must present
# the item, give its assessment, and WAIT for the user to confirm. The
# dhx-assessed-guard.sh PreToolUse hook enforces this mechanically.

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then exit 0; fi

# Source the canonical deferred-item classifier. Single source of truth shared
# with the skills repo. If the symlink is missing (dhx-tools not installed in
# this environment), fall back to no-op exit rather than blocking session-end.
# Path expression duplicated rather than indirected through a variable so the
# skills-repo cross-repo drift probe (probe-classifier-cross-repo.sh) can
# statically assert the source target.
if [ ! -f "${DHX_TOOLS:-$HOME/.claude/dhx-tools}/dhx-classify-deferred.sh" ]; then exit 0; fi
# shellcheck source=/dev/null
. "${DHX_TOOLS:-$HOME/.claude/dhx-tools}/dhx-classify-deferred.sh"

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
    if grep -qFx "$phase_from_dir" <<< "$PHASE_ALLOWLIST"; then
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
# reports/done/2026-04-11-deferred-check-sed-tag-collision.md.
#
# When tag extraction returns empty, a secondary fallback checks for deferred
# items under markdown headers (## Deferred / ## Deferred Ideas). This catches
# content placed outside the tagged section — see Gap 1 in
# reports/done/2026-04-12-context-tag-corpus-analysis.md.
#
# Header-fallback: when the <deferred> tag section is missing OR present but
# empty (no bullets), check for deferred items under markdown headers
# (## Deferred / ## Deferred Ideas). This catches Edge Cases 1 and 2 from
# the corpus analysis. The fallback fires from two branches: (a) empty sed
# extraction and (b) non-empty extraction but zero bullet items after filtering.
check_header_fallback() {
  local file="$1"
  MD_DEFERRED=$(sed -n '/^##[^#].*[Dd]eferred/,/^##[^#]/p' "$file" 2>/dev/null \
    | classify_deferred_lines)
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
if grep -qE '^\s*-?\s*[Nn]one(\s*$|\s+—)' <<< "$DEFERRED"; then exit 0; fi

# Find unassessed items via the canonical classifier (sourced above), then
# drop items that already have a durable home. Both filters live in the
# canonical script — single source of truth so hook count and skill count
# (/dhx:defer-review) cannot diverge. See
# ~/.claude/dhx-tools/dhx-classify-deferred.sh `auto_silence_deferred_lines`
# header for the REQ-ID + dated-filename regex set and the leading-{2,}
# INVARIANT that rejects D-NN/Q-NN/F-NN GSD labels (backed by
# tests/probes/probe-deferred-check-req-id-regex.sh).
CLASSIFIED=$(printf '%s\n' "$DEFERRED" | classify_deferred_lines)
if [ -z "$CLASSIFIED" ]; then check_header_fallback "$LATEST"; fi

UNCAPTURED=$(printf '%s\n' "$CLASSIFIED" | auto_silence_deferred_lines "$LATEST")
if [ -z "$UNCAPTURED" ]; then exit 0; fi

# Count
COUNT=$(echo "$UNCAPTURED" | wc -l | tr -d ' ')

# Signal that deferred review is active (assessed-guard checks this)
REVIEW_MARKER="/tmp/dhx-deferred-review-$(echo "$CWD" | md5sum | cut -d' ' -f1 2>/dev/null || echo "default")"
touch "$REVIEW_MARKER"

# Multi-line block message exposes the inline marker contract so trivial
# cases can resolve via Edit without invoking /dhx:defer-review. Marker
# syntax is canonical at ~/.claude/dhx-tools/dhx-classify-deferred.sh
# (CLASSIFY_DEFERRED_MARKERS) and mirrored in this hook's header (lines 9-15).
MSG="DEFERRED ITEM REVIEW — ${COUNT} unassessed item(s) in ${LATEST}.

Resolve via /dhx:defer-review ${LATEST}, OR mark inline:
  [captured: <ref>]    item filed to backlog/todo
  [existing: <path>]   item already tracked elsewhere
  [assessed: <reason>] intentionally not captured (requires user approval)
  [tracked: REQ-ID]    tracked against a requirement
  [note: <detail>]     non-actionable decision-trail commentary"

jq -n --arg msg "$MSG" \
  '{"decision": "block", "reason": $msg}'

exit 0
