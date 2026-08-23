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
# THE RENDERER'S MODE TOKEN IS `context` — the LEG is named session-start, the argv MODE is not.
# cross-repo's dhx-schedule-render.cjs freezes MODES = ['prompt','context','banner'] and answers any
# other token with exit 0 and no output; its test suite pins `session-start` as exactly such an
# UNKNOWN mode. This shim shipped (7f502e0) invoking `session-start`, copied from a cross-repo
# handoff written before plan 40-04 chose the spelling, so the leg was silently inert — corrected
# 2026-08-22 by the /dhx:test 40 security audit. Until ~/.claude/dhx-tools/dhx-schedule-render.cjs
# is provisioned (cross-repo's install-dhx-tools.sh from the primary, post-merge) the guard below
# still returns silently — that absence is designed; a wrong mode token is not.
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

# THE EVENT DIGEST IS FORWARDED BY THE PARENT, NOT RECOMPUTED HERE — and that asymmetry with
# dhx-schedule-prompt.sh is deliberate. The prompt leg's two sides are two INDEPENDENTLY
# REGISTERED hooks, so they genuinely cannot talk and each must hash the payload itself. This
# leg is different: session-start.sh computes the reference digest and then invokes this shim
# as its own CHILD, in the same process, so the value is already in hand and parent-to-child
# environment is not the forbidden inter-hook channel. Recomputing it here would buy nothing
# and would add a second canonicalisation that could drift from the first.
#
# VALIDATED, NEVER TRUSTED: the parent is the only expected source, but this reads an
# environment variable, so anything could set it. Only a 16-char lowercase-hex digest is
# forwarded; anything else becomes empty and the Node side's isDigestKey() records null —
# exactly the state this leg had before the forwarding existed, which is the safe floor.
EVENT_HASH="${DHX_SCHEDULE_EVENT_HASH:-}"
if [ "${#EVENT_HASH}" -ne 16 ] || [ -n "${EVENT_HASH//[0-9a-f]/}" ]; then
  EVENT_HASH=""
fi

RENDERER="${DHX_SCHEDULE_RENDERER:-$HOME/.claude/dhx-tools/dhx-schedule-render.cjs}"
# Graceful no-op when the symlink is not provisioned yet (the dispatcher's own dhx-tools
# guard shape). A bare `node <absent-path>` would exit non-zero and print to stderr.
[ -e "$RENDERER" ] || exit 0
command -v node >/dev/null 2>&1 || exit 0

node "$RENDERER" context --session-id "$SESSION_ID" --event-hash "$EVENT_HASH" 2>/dev/null </dev/null || true
exit 0
