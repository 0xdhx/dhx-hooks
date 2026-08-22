#!/usr/bin/env bash
# dhx-schedule-context.sh — SessionStart chain script for the /dhx:schedule context leg.
# Patterns: HP-015
#
# OUTPUT CONTRACT: PLAIN TEXT ONLY, NEVER JSON. This is a dispatcher child, and
# session-start.sh concatenates its children's plain stdout — a JSON child corrupts the
# WHOLE payload, not merely its own part (see dhx/dhx-vitals-banner.sh's header).
#
# Thin dispatcher-called shim: drains the stdin envelope (HP-015 — stdin must be drained to
# avoid SIGPIPE upstream), then delegates. Clean path = EMPTY stdout (zero context tokens).
# NEVER blocks session start.
#
# THE RENDERER'S session-start MODE LANDS IN A LATER CROSS-REPO PLAN. Until that plan merges,
# the renderer answers an unknown mode with exit 0 and no output, so this child correctly
# emits nothing — which is ALSO its clean-path behaviour. That is a DESIGNED graceful absence,
# not a gap: wiring it now means the leg starts working the moment its mode lands, with no
# second hooks-repo change.
#
# Suppression: DHX_SKIP_SCHEDULE_CONTEXT=1
# Source-of-truth: ~/repos/hooks/dhx/dhx-schedule-context.sh
# Symlinked to:    ~/.claude/hooks/dhx-schedule-context.sh
set -uo pipefail

if [ "${DHX_SKIP_SCHEDULE_CONTEXT:-0}" = "1" ]; then
  exit 0
fi

INPUT=$(cat 2>/dev/null || true)

SESSION_ID=""
if command -v jq >/dev/null 2>&1 && [ -n "$INPUT" ]; then
  SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
fi

CACHE_DIR="${DHX_SCHEDULE_CACHE_DIR:-$HOME/.cache/dhx/schedule}"
export DHX_SCHEDULE_CACHE_DIR="$CACHE_DIR"

RENDERER="${DHX_SCHEDULE_RENDERER:-$HOME/.claude/dhx-tools/dhx-schedule-render.cjs}"
# Graceful no-op when the symlink is not provisioned yet (the dispatcher's own dhx-tools
# guard shape). A bare `node <absent-path>` would exit non-zero and print to stderr.
[ -e "$RENDERER" ] || exit 0
command -v node >/dev/null 2>&1 || exit 0

node "$RENDERER" session-start --session-id "$SESSION_ID" 2>/dev/null </dev/null || true
exit 0
