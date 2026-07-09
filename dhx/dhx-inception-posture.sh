#!/usr/bin/env bash
# dhx-inception-posture.sh — UserPromptSubmit hook (matchless)
# Patterns: HP-008
#
# Fires ONLY on project/milestone inception commands (/gsd-new-project,
# /gsd-new-milestone — colon + hyphen forms). Injects a build-posture
# elicitation checklist as additionalContext so the inception flow pins
# runtime/distribution/reuse (and, where the project has a release path,
# commercial options) as FIRST-CLASS questions — same tier as the feature
# list — instead of defaulting to the dev box the agent happens to observe.
#
# Cross-project by design: this discipline must reach the NEXT new project,
# which a project-local memory (runtime-target-elicit-early) cannot. Lives in
# the global plugin manifest, not any one repo.
#
# Two of three build-posture principles land here (the third — "spend time on
# reuse, never quality" — is a global CLAUDE.md Decision-Framing bullet, since
# it is broadly relevant + benign when no reuse fork exists). See
# docs/decisions.md 2026-07-09 build-posture-codification row.
#
# NOT matched: /dhx:align. It fires mid-session for drift checks too, so
# matching it would break the silent-otherwise / zero-per-session-tax
# guarantee. Tight to the two genuine inception commands only.
#
# Silent on every non-inception prompt (~1ms case-glob, no jq on the fast
# path miss). Fail-open (exit 0) on absent jq or empty prompt.

set -uo pipefail

INPUT=$(cat)
if ! command -v jq >/dev/null 2>&1; then exit 0; fi

# HP-008: UserPromptSubmit stdin carries the submitted prompt in `.prompt`
# (NOT `.user_prompt`). stdout is injected as additional context for the turn.
PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)
if [[ -z "$PROMPT" ]]; then exit 0; fi

# Inception-command filter. Anchor on a trailing word boundary (whitespace or
# end-of-string) so /gsd-new-project-x / /gsd-new-milestone-foo do NOT match.
# Both colon (/gsd:) and hyphen (/gsd-) forms — skills use hyphens, the GSD
# native namespace uses colons.
case "$PROMPT" in
  "/gsd:new-project"|"/gsd:new-project "* \
  |"/gsd-new-project"|"/gsd-new-project "* \
  |"/gsd:new-milestone"|"/gsd:new-milestone "* \
  |"/gsd-new-milestone"|"/gsd-new-milestone "*) ;;
  *) exit 0 ;;   # not an inception command — silent
esac

read -r -d '' MSG <<'EOF' || true
BUILD-POSTURE (project/milestone inception) — pin these BEFORE scoping features; they are load-bearing architecture disguised as ship-time details, and a model defaults to the only runtime it can observe (the dev box) unless the target is stated:

1. RUNTIME / DISTRIBUTION / REUSE — Ask explicitly, same tier as the feature list: what runtime(s) will this actually ship to, and what is the reuse/extraction surface (shared kernel, other consumers)? Do NOT inherit the dev box as the target. Aim for a runtime-agnostic core + per-target packaging — don't invert one runtime assumption into another. Raise this now; don't wait for the user to volunteer it — the elicitation is the agent's job.

2. COMMERCIAL OPTIONS — ONLY if this project has a release path (skip for throwaway / personal / internal work): build to keep options open — permissive licensing, no hard dev-env dependency, end-user-runnable distribution, don't foreclose platforms.

Surface #1 (and #2 when it applies) as first-class questions before the feature scope locks.
EOF

jq -n --arg msg "$MSG" \
  '{"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": $msg}}'

exit 0
