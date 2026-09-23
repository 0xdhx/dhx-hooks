#!/usr/bin/env bash
# dhx-vitals-banner.sh — SessionStart user-visible cross-repo vitals banner.
# Patterns: HP-009, HP-015
#
# Emits a JSON {"systemMessage": "..."} (forgefinder pattern,
# ~/repos/forgefinder/hooks/session-start.sh) so the USER sees the GLOBAL
# cross-repo vitals at session start — watch overdue/health + sym + crashes +
# STATE drift/stall across ~/repos/*. The badge (📥 N) is delivered SEPARATELY by
# a shell precmd (cross-repo dotfiles/dhx-vitals-badge.sh); a CC hook CANNOT render
# an OSC badge — hook stdout is captured as model context, /dev/tty was removed from
# hooks in CC 2.1.139, and OSC 1337 is off the terminalSequence allowlist. See
# cross-repo docs/research/2026-06-04-hook-cannot-emit-osc-badge.md.
#
# OUTPUT CONTRACT: ONLY the {"systemMessage":...} JSON (banner), or NOTHING when the
# count is 0 (→ CC renders no banner). This MUST be a SEPARATE SessionStart hook,
# NOT a child of the plain-text session-start.sh dispatcher — the dispatcher
# concatenates children's plain stdout, which would corrupt this JSON.
#
# HP-015: SessionStart hook (startup|resume|clear|compact). HP-009: exit 0,
# advisory-only — never blocks a session. dhx-tools indirection + [ -e ]
# graceful-skip + fail-open: a bare `node <absent-symlink>` exits non-zero, so guard
# on existence (the same shape as the dispatcher's dhx-watch-health.cjs recompute).
# The actionable computation is cross-repo's scripts/dhx-dashboard.cjs `notify`.
#
# Source-of-truth: ~/repos/hooks/dhx/dhx-vitals-banner.sh
# Symlinked to:    ~/.claude/hooks/dhx-vitals-banner.sh
# Registered:      dhx-plugin/.../hooks.json SessionStart (frozen until the plugin
#                  cache is refreshed — see the staged-unblock prompt).

set -uo pipefail

# QW_CELL=1: a measured quota cell's client (qw-call.sh, 2026-09-23, N9 B R-B12) — no banner.
# Its `ran Nh ago` ages per hour; the systemMessage renders to the operator, not the model
# (HP-055), so this is hygiene for a headless session no one reads, not a prefix fix.
[ "${QW_CELL:-}" = "1" ] && exit 0

TOOL="$HOME/.claude/dhx-tools/dhx-dashboard.cjs"
[ -e "$TOOL" ] && node "$TOOL" notify </dev/null 2>/dev/null || true
exit 0
