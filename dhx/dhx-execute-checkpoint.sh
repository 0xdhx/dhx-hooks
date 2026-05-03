#!/usr/bin/env bash
# dhx-execute-checkpoint.sh — PostToolUse hook (Agent matcher)
# Patterns: HP-011
# Injects drift detection calibration when a gsd-executor agent completes.
# Advisory only — no blocking.
#
# 2026-05-03 once-per-phase gate (Tier 1 plugin token-reduction Step 2/2):
# Original Apr-6 design fired per-plan; the matcher migration preserved
# per-plan firing (per gsd-executor return). 7d corpus showed 243 firings of
# identical static text across 49 sessions — repetition adds no signal after
# the first fire of a phase. Marker keyed by (session_id, phase_number);
# new phase re-arms the calibration. Falls back to per-plan firing if either
# value cannot be derived (fail-open — preserves original behavior on error).

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then exit 0; fi

AGENT_TYPE=$(echo "$INPUT" | jq -r '.tool_input.subagent_type // empty')

# Gate: Only gsd-executor completions
[ "$AGENT_TYPE" != "gsd-executor" ] && exit 0

# Once-per-phase gate. Derive (session_id, phase_number); if both present,
# touch a marker on first fire and exit silently on subsequent fires within
# the same session+phase. If either cannot be derived, fall through to
# per-plan firing (fail-open).
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

PLANNING_DIR=""
DIR="$(pwd)"
while [ "$DIR" != "/" ]; do
  if [ -d "$DIR/.planning/phases" ]; then
    PLANNING_DIR="$DIR/.planning"
    break
  fi
  DIR="$(dirname "$DIR")"
done

PHASE=""
if [ -n "$PLANNING_DIR" ] && [ -f "$PLANNING_DIR/STATE.md" ]; then
  SIGNAL_LINES=$(grep -E '^stopped_at:|^\*\*Phase:\*\*|^\*\*Current Phase:\*\*|^\*\*Current focus:\*\*|^\*\*Last Activity Description:\*\*|^\*\*Last activity description:\*\*' "$PLANNING_DIR/STATE.md" 2>/dev/null)
  STATE_NUM=$({
    printf '%s\n' "$SIGNAL_LINES" | grep -oE '[Pp]hase[[:space:]]+[0-9]+(\.[0-9]+)?' | sed 's/^[Pp]hase[[:space:]]*//'
    printf '%s\n' "$SIGNAL_LINES" | grep -oE '^\*\*(Current )?Phase:\*\*[[:space:]]+[0-9]+(\.[0-9]+)?' | sed -E 's/^\*\*[^*]+\*\*[[:space:]]*//'
  } | grep -v '^$' | head -1)
  if [ -n "$STATE_NUM" ]; then
    PHASE=$(echo "$STATE_NUM" | sed -E 's/^0*([0-9])/\1/')
  fi
fi

if [ -n "$SESSION_ID" ] && [ -n "$PHASE" ]; then
  MARKER="/tmp/dhx-checkpoint-${SESSION_ID}-phase-${PHASE}"
  [ -e "$MARKER" ] && exit 0
  touch "$MARKER" 2>/dev/null
fi

cat << 'ENDJSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "EXECUTION CHECKPOINT — Executor plan completed. Before proceeding to the next plan or ending the session, verify:\n1. Do committed changes match CONTEXT.md decisions? Check for silent descoping or scope creep.\n2. Were any CONTEXT.md decisions modified during implementation without recording the deviation?\n3. Are there deferred items from implementation that need /dhx:capture?\nIf drift is detected, flag it now — don't wait for end-of-session review."
  }
}
ENDJSON
