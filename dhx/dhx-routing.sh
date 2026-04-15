#!/usr/bin/env bash
# dhx-routing.sh — UserPromptSubmit hook
# Patterns: HP-008
# Detects GSD commands and routes to DHX equivalents.
# Two modes: redirect (full replacement) and augment (calibration overlay).
# Matches both /gsd:command and /gsd-command formats (skills use hyphens).
# Exits silently for non-GSD prompts (~1ms).

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then exit 0; fi

USER_PROMPT=$(echo "$INPUT" | jq -r '.user_prompt // empty')

# Fast exit for non-GSD prompts — match both colon and hyphen formats
case "$USER_PROMPT" in
  /gsd:discuss-phase*|/gsd-discuss-phase*) ;;
  /gsd:plan-phase*|/gsd-plan-phase*) ;;
  /gsd:execute-phase*|/gsd-execute-phase*) ;;
  /gsd:new-milestone*|/gsd-new-milestone*) ;;
  /gsd:new-project*|/gsd-new-project*) ;;
  /gsd:audit-milestone*|/gsd-audit-milestone*) ;;
  /gsd:verify-work*|/gsd-verify-work*) ;;
  /gsd:ui-phase*|/gsd-ui-phase*) ;;
  /gsd:ui-review*|/gsd-ui-review*) ;;
  *) exit 0 ;;
esac

# Extract arguments (everything after the command) — handle both separators
ARGS=$(echo "$USER_PROMPT" | sed 's|^/gsd[:-][^ ]* *||')

# Determine routing mode and target
MSG=""
case "$USER_PROMPT" in
  /gsd:discuss-phase*|/gsd-discuss-phase*)
    MSG="ROUTING: Do NOT follow the loaded GSD discuss-phase workflow. Invoke /dhx:discuss ${ARGS} instead — it is a complete replacement that includes calibration, scout, assumptions, discussion, coherence review, and CONTEXT.md output."
    ;;
  /gsd:plan-phase*|/gsd-plan-phase*)
    MSG="CALIBRATION: Before proceeding with this GSD workflow, invoke /dhx:plan ${ARGS} to load decision calibration. Then continue with the GSD plan-phase workflow with calibration active."
    ;;
  /gsd:execute-phase*|/gsd-execute-phase*)
    MSG="CALIBRATION: Load /dhx:execute ${ARGS} calibration. Apply anti-drift checkpoints while following the GSD execute-phase workflow. Run the full /dhx:execute review before the session ends. After verification, chain to /dhx:test for coverage and verification."
    ;;
  /gsd:new-milestone*|/gsd-new-milestone*|/gsd:new-project*|/gsd-new-project*)
    MSG="CALIBRATION: Invoke /dhx:new ${ARGS} to load scope calibration before proceeding with this GSD workflow. Ensures scope ambition and requirement completeness."
    ;;
  /gsd:audit-milestone*|/gsd-audit-milestone*)
    MSG="CALIBRATION: Invoke /dhx:audit to load audit calibration before proceeding. Counteracts optimistic completion bias."
    ;;
  /gsd:verify-work*|/gsd-verify-work*)
    MSG="ROUTING: Invoke /dhx:test ${ARGS} instead — it runs coverage check, automated tests, and manual UAT in a single pipeline. Only items that genuinely require human verification will be presented."
    ;;
  /gsd:ui-phase*|/gsd-ui-phase*)
    MSG="CALIBRATION: Invoke /dhx:ui to load UI design calibration before proceeding with this GSD workflow. This loads session checkpoints (anti-slop, metaphor alignment, spec compliance), verifies z-gsdui project skill exists for subagent authority, and ensures DESIGN-VISION.md locked values are respected by the ui-researcher and ui-checker."
    ;;
  /gsd:ui-review*|/gsd-ui-review*)
    MSG="CALIBRATION: Invoke /dhx:ui to load UI design calibration before proceeding with this GSD UI review workflow."
    ;;
esac

if [ -n "$MSG" ]; then
  jq -n --arg msg "$MSG" \
    '{"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": $msg}}'
fi

exit 0
