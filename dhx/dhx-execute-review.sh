#!/usr/bin/env bash
# dhx-execute-review.sh — SubagentStop hook
# Patterns: HP-011, HP-021
# Injects execution fidelity review when a gsd-verifier agent completes
# during an active phase execution. Catches plan-to-execution drift at
# the moment verification completes, before the session ends.
# Advisory only — no blocking.
#
# 2026-05-07 event migration: PostToolUse:Agent → SubagentStop. PostToolUse:Agent
# fires AT DISPATCH for run_in_background=true (HP-011 addendum); the review
# would arrive against work that hadn't run yet. SubagentStop fires on actual
# subagent completion (HP-021, CC 2.1.112). Stdin shape changes:
# `tool_input.subagent_type` → `agent_type`. Old-shape fallback retained for
# the transition window per HP-012 (stale-snapshot safety).
#
# 2026-05-03 consolidation: absorbed dhx-post-execute-review.sh — both fired
# lockstep on gsd-verifier completion (47/49 firings/7d). Phase number is
# derived from STATE.md (mirrors dhx-deferred-check.sh:62-81) and merged into
# the message preamble; pointer to /dhx:execute review skill appended.

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then exit 0; fi

AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // .tool_input.subagent_type // empty')

# Gate: Only gsd-verifier completions
[ "$AGENT_TYPE" != "gsd-verifier" ] && exit 0

# Gate: Only during phase execution (recent SUMMARY.md = execution evidence)
PLANNING_DIR=""
DIR="$(pwd)"
while [ "$DIR" != "/" ]; do
  if [ -d "$DIR/.planning/phases" ]; then
    PLANNING_DIR="$DIR/.planning"
    break
  fi
  DIR="$(dirname "$DIR")"
done

[ -z "$PLANNING_DIR" ] && exit 0

SUMMARY_COUNT=$(find "$PLANNING_DIR/phases" -name "*-SUMMARY.md" -mmin -30 2>/dev/null | wc -l)
[ "$SUMMARY_COUNT" -eq 0 ] && exit 0

# Derive phase number from STATE.md (mirrors dhx-deferred-check.sh:62-81).
# Degrade gracefully — if unparseable, fall through with empty PHASE.
STATE_FILE="$PLANNING_DIR/STATE.md"
PHASE=""
if [ -f "$STATE_FILE" ]; then
  SIGNAL_LINES=$(grep -E '^stopped_at:|^\*\*Phase:\*\*|^\*\*Current Phase:\*\*|^\*\*Current focus:\*\*|^\*\*Last Activity Description:\*\*|^\*\*Last activity description:\*\*' "$STATE_FILE" 2>/dev/null)
  STATE_NUM=$({
    printf '%s\n' "$SIGNAL_LINES" | grep -oE '[Pp]hase[[:space:]]+[0-9]+(\.[0-9]+)?' | sed 's/^[Pp]hase[[:space:]]*//'
    printf '%s\n' "$SIGNAL_LINES" | grep -oE '^\*\*(Current )?Phase:\*\*[[:space:]]+[0-9]+(\.[0-9]+)?' | sed -E 's/^\*\*[^*]+\*\*[[:space:]]*//'
  } | grep -v '^$' | head -1)
  if [ -n "$STATE_NUM" ]; then
    PHASE=$(echo "$STATE_NUM" | sed -E 's/^0*([0-9])/\1/')
  fi
fi

if [ -n "$PHASE" ]; then
  PREAMBLE="EXECUTION REVIEW — Phase ${PHASE} verifier completed. Phase execution is complete."
else
  PREAMBLE="EXECUTION REVIEW — Verifier completed. Phase execution is complete."
fi

CTX="${PREAMBLE} Before the session ends, run a fidelity review (plan-to-execution, context-to-code, silent descoping). Run /dhx:execute (no args) for the full checklist."

jq -n --arg ctx "$CTX" '{systemMessage: $ctx}'
