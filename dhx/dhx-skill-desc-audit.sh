#!/usr/bin/env bash
# dhx-skill-desc-audit.sh — SessionStart chain script for the skill-description delta auditor.
# Patterns: HP-015
#
# Thin dispatcher-called shim: consumes the stdin envelope (HP-015 — worker needs no fields,
# but stdin must be drained to avoid SIGPIPE upstream), then delegates to the node worker
# (dhx-skill-desc-audit.cjs), which owns collector invocation, warn-state machinery, and the
# fail-open + consecutive_failures contract (SPEC §4.5/§4.6 — see the worker header).
# Clean path = EMPTY stdout (zero context tokens). NEVER blocks session start.
#
# Suppression: DHX_SKIP_SKILL_DESC_AUDIT=1
# Source-of-truth: ~/repos/hooks/dhx/dhx-skill-desc-audit.sh
# Symlinked to:   ~/.claude/hooks/dhx-skill-desc-audit.sh
set -uo pipefail

if [ "${DHX_SKIP_SKILL_DESC_AUDIT:-0}" = "1" ]; then
  exit 0
fi

INPUT=$(cat 2>/dev/null || true)

WORKER="${DHX_SKILL_DESC_WORKER:-$HOME/.claude/hooks/dhx-skill-desc-audit.cjs}"
# Graceful no-op when the symlink isn't provisioned yet (same shape as the dispatcher's
# dhx-tools guards); the worker itself fail-opens on a missing COLLECTOR.
[ -e "$WORKER" ] || exit 0

node "$WORKER" audit 2>/dev/null || true
exit 0
