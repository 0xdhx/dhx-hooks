#!/usr/bin/env bash
# dhx-execute-stop-review.sh — Stop hook
# Patterns: HP-001, HP-002, HP-003, HP-004, HP-005, HP-006, HP-009, HP-028
# Safety net for execution pipelines. If a phase execution completed
# (VERIFICATION.md + SUMMARY.md evidence) but the /dhx:execute review
# wasn't performed, blocks with review prompt.
#
# Pairs with dhx-routing.sh (UserPromptSubmit) which primes calibration
# at session start. This catches the case where Claude didn't follow
# through on the review before ending.
#
# Why Stop and not PostToolUse:Agent? Hooks do not propagate into Agent
# boundaries — no PreToolUse, PostToolUse, or SubagentStop events fire
# for tool calls inside spawned agents. Stop is the only reliable
# post-execution hook point.

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then exit 0; fi

# Loop prevention — Claude Code sets this after first block
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then exit 0; fi

CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
if [ -z "$CWD" ]; then exit 0; fi

# Gate: GSD project
if [ ! -d "$CWD/.planning/phases" ]; then exit 0; fi

# Gate: Session must contain execution evidence — positive signal that this
# session actually ran a GSD execution, not just happened to be in a project
# with recent phase artifacts. Without this, research/quick-fix/ad-hoc sessions
# false-positive whenever -mmin gates pass (especially on WSL2 where mtime is
# unreliable). Transcript includes user prompts, hook outputs, and Agent tool
# calls from the parent level (HP-003: hooks don't propagate INTO agents, but
# Agent spawn calls are visible in the parent transcript).
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript // ""' 2>/dev/null)
if ! grep -qiE 'gsd-execute-phase|gsd:execute-phase|dhx:execute|gsd-executor|gsd-verifier' <<< "$TRANSCRIPT"; then
  exit 0  # Not an execution session — no review needed
fi

# Gate: Recent execution evidence — VERIFICATION.md in last 15 min
RECENT_VERIF=$(find "$CWD/.planning/phases" -name "*-VERIFICATION.md" -mmin -15 2>/dev/null | head -1)
[ -z "$RECENT_VERIF" ] && exit 0

# Gate: Execution context — recent SUMMARY.md in same phase dir
PHASE_DIR=$(dirname "$RECENT_VERIF")
RECENT_SUMMARY=$(find "$PHASE_DIR" -name "*-SUMMARY.md" -mmin -30 2>/dev/null | head -1)
[ -z "$RECENT_SUMMARY" ] && exit 0

# Gate: Check if review was already performed (reuses TRANSCRIPT from above)
if grep -qi 'plan-to-execution fidelity\|execution-to-plan fidelity\|context-to-code fidelity\|silent descoping.*check\|EXECUTION REVIEW' <<< "$TRANSCRIPT"; then
  exit 0  # Review already done
fi

# Extract phase number
PHASE=$(basename "$RECENT_VERIF" | grep -oP '^\d+(\.\d+)?' | head -1)
[ -z "$PHASE" ] && exit 0

# Gate: STATE.md cross-reference — the detected phase must correspond to
# phases STATE.md says Claude is actively working on (or just finished).
# Kills bulk-restore false positives where `git checkout <sha> -- .planning/`
# gives historical phase files fresh mtimes that trip -mmin gates.
#
# Allowlist is built from:
#   1. Frontmatter `stopped_at:` (session-end + phase-complete marker, free-form)
#   2. Body fields **Phase:**, **Current Phase:**, **Current focus:**,
#      **Last Activity Description:** (handles format variation across
#      projects and GSD versions — gsd-tools CJS and gsd-sdk)
#   3. For each Phase N found: also include N-1 to cover the case where
#      `gsd-sdk query phase.complete X` has already advanced Current Phase to
#      X+1 by the time this Stop hook fires (see HP-006).
#
# Fail closed (preserve old behavior) if STATE.md missing or yields no
# phase numbers — missing STATE.md is rare and we don't want to regress
# the review prompt for projects in unexpected state.
STATE_FILE="$CWD/.planning/STATE.md"
if [ -f "$STATE_FILE" ]; then
  SIGNAL_LINES=$(grep -E '^stopped_at:|^\*\*Phase:\*\*|^\*\*Current Phase:\*\*|^\*\*Current focus:\*\*|^\*\*Last Activity Description:\*\*|^\*\*Last activity description:\*\*' "$STATE_FILE" 2>/dev/null)
  STATE_NUMS=$({
    printf '%s\n' "$SIGNAL_LINES" | grep -oE '[Pp]hase[[:space:]]+[0-9]+(\.[0-9]+)?' | sed 's/^[Pp]hase[[:space:]]*//'
    printf '%s\n' "$SIGNAL_LINES" | grep -oE '^\*\*(Current )?Phase:\*\*[[:space:]]+[0-9]+(\.[0-9]+)?' | sed -E 's/^\*\*[^*]+\*\*[[:space:]]*//'
  } | sort -u | grep -v '^$')

  if [ -n "$STATE_NUMS" ]; then
    PHASE_ALLOWLIST=""
    for n in $STATE_NUMS; do
      n_int=$(echo "$n" | grep -oE '^[0-9]+' | sed 's/^0*//')
      [ -z "$n_int" ] && n_int="0"
      PHASE_ALLOWLIST="${PHASE_ALLOWLIST} ${n_int}"
      if [ "$n_int" -gt 0 ]; then
        PHASE_ALLOWLIST="${PHASE_ALLOWLIST} $((n_int - 1))"
      fi
    done
    PHASE_ALLOWLIST=$(echo "$PHASE_ALLOWLIST" | tr ' ' '\n' | sort -u | grep -v '^$')

    PHASE_INT=$(echo "$PHASE" | grep -oE '^[0-9]+' | sed 's/^0*//')
    [ -z "$PHASE_INT" ] && PHASE_INT="0"

    if ! grep -qFx "$PHASE_INT" <<< "$PHASE_ALLOWLIST"; then
      exit 0  # Detected phase unrelated to STATE.md — likely bulk restore
    fi
  fi
fi

MSG="EXECUTION REVIEW NOT COMPLETED — Phase ${PHASE} execution finished but the /dhx:execute review was not performed.

Apply before session ends:
1. PLAN-TO-EXECUTION FIDELITY: Compare each completed task against its plan description. Were any tasks simplified during implementation without flagging?
2. CONTEXT-TO-CODE FIDELITY: Do committed changes align with CONTEXT.md decisions? Or was a different interpretation quietly built?
3. SILENT DESCOPING: Were any plan tasks dropped or partially implemented without recording the deviation?
4. DEFERRED ITEMS: Scan for TODOs or noted limitations that need /dhx:capture.
5. BACKLOG SYNC: Run /dhx:backlog audit to check for uncaptured items.
6. NYQUIST: Run /dhx:test nyquist to validate test coverage for this phase."

jq -n --arg msg "$MSG" \
  '{"decision": "block", "reason": $msg}'

exit 0
