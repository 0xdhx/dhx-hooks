#!/usr/bin/env bash
# dhx-vet-closures.sh — SessionStart chain script for the pending `/dhx:vet` closure surfacer.
# Patterns: HP-015
#
# Thin dispatcher-called shim: consumes the stdin envelope (HP-015 — the worker needs no
# fields, but stdin must be drained to avoid SIGPIPE upstream), then delegates to
# dhx-vet-closures-render.sh, which owns the flock'd ledger read, the self-heal-on-read
# contract, and the rendering. Clean path = EMPTY stdout (zero context tokens) — and the
# clean path is the overwhelmingly common case, since a residual row only exists when a
# session went stale mid-question. NEVER blocks session start.
#
# The shim exists to guarantee the fail-silent contract structurally: whatever the worker
# does, this wrapper swallows it and exits 0.
#
# Suppression: DHX_SKIP_VET_CLOSURES=1
# Source-of-truth: ~/repos/hooks/dhx/dhx-vet-closures.sh
# Symlinked to:   ~/.claude/hooks/dhx-vet-closures.sh
set -uo pipefail

if [ "${DHX_SKIP_VET_CLOSURES:-0}" = "1" ]; then
  exit 0
fi

INPUT=$(cat 2>/dev/null || true)

WORKER="${DHX_VET_CLOSURES_WORKER:-$HOME/.claude/hooks/dhx-vet-closures-render.sh}"
# Graceful no-op when the symlink isn't provisioned yet (same shape as the dispatcher's
# dhx-tools guards); the worker itself fail-opens on a missing/absent ledger.
[ -e "$WORKER" ] || exit 0

bash "$WORKER" 2>/dev/null || true
exit 0
