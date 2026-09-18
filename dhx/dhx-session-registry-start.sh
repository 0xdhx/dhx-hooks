#!/usr/bin/env bash
# ============================================================================
# RETIRED FROM MANIFEST (2026-06-09). The SessionStart entry that ran this hook
# was removed from dhx-plugin/plugins/dhx/hooks/hooks.json — birth capture was
# falsified in production (one logical CC session wears many transcript uuids,
# and the uuid SessionStart registered was routinely NOT the uuid held on exit).
# The live start-row producer is dhx/dhx-session-registry-prompt.sh, a
# UserPromptSubmit self-backfill writing this SAME 9-field row, idempotent per
# uuid. See docs/decisions.md 2026-06-09 row.
#
# DO NOT DELETE. This file is kept deliberately on two counts: it is the
# archived row-shape source that tests/probes/probe-session-registry.sh loads
# ($S, line ~59), and its header below is the canonical statement of the
# LITERAL-$HOME/.claude rationale that dhx-session-registry-end.sh points at by
# name. Removing it reds the probe and orphans that cross-reference.
#
# NOTHING BELOW THIS BANNER DESCRIBES A REGISTERED HOOK. Read the body as the
# archived row schema, never as live behaviour — on 2026-09-18 a session read
# the old "SessionStart hook" header as current, concluded from its
# `startup|resume|clear|compact` matcher that a resume must write a start row,
# and landed a wrong paragraph in docs/decisions.md on that basis. That is the
# failure this banner exists to prevent.
# ============================================================================
# dhx-session-registry-start.sh — SessionStart hook (RETIRED — see banner above)
# Patterns: HP-015 (SessionStart provides session_id/transcript_path/cwd/source), HP-017 (plugin manifest)
#
# Appends one `start` row to the shared session registry at session birth, so
# crash recovery (skills /dhx:history alive) can find held-open (idle) sessions
# that the mtime-keyed `/dhx:history crashed` mode structurally misses. Identity
# is known exactly and for free at birth — every save-time reconstruction approach
# was falsified by the 2026-06-08 spike (see the contract brief).
#
# Contract (authoritative — do NOT diverge from the row schema):
#   ~/repos/cross-repo/.planning/backlog/2026-06-08-alive-session-recovery-registry.md
# Producer brief: ~/repos/hooks/.planning/backlog/2026-06-08-session-pane-registry-hook.md
#
# Registry path is LITERAL $HOME/.claude — NOT $CLAUDE_CONFIG_DIR. Under CCS the
# latter is per-instance (a|b|c) and would fragment the registry into three files;
# the whole point is ONE shared event log across all instances.
#
# Row (9-field TSV):
#   <iso_ts>\tstart\t<uuid>\t<instance>\t<slug>\t<repo>\t<tmux_session>\t<tmux_window>\t<pane_id>
#
# Fail-open contract: SessionStart gates the session. Any error => exit 0 silently;
# never block or slow startup. No $TMUX => empty tmux fields (not an error). ONE
# tmux call max (combined display-message), never per-field/loops — mind the
# 2026-04-26 capture-pane IPC-wedge class. The tmux call is `timeout`-bounded so a
# wedged tmux server can't hang session startup.
#
# Atomicity: `printf >> file` is an atomic O_APPEND for rows < PIPE_BUF (4096 B);
# concurrent session starts cannot interleave. No flock required (per contract).
set -uo pipefail

REGISTRY="$HOME/.claude/dhx-session-registry.tsv"

INPUT=$(cat)

# Silent exit on unparseable JSON — SessionStart must never fail.
echo "$INPUT" | jq -e . >/dev/null 2>&1 || exit 0

UUID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
CWD=$(echo "$INPUT" | jq -r '.workspace.current_dir // .cwd // empty' 2>/dev/null)

# uuid fallback: basename of transcript_path sans .jsonl (per contract).
if [ -z "$UUID" ] && [ -n "$TRANSCRIPT" ]; then
  UUID=$(basename "$TRANSCRIPT" .jsonl)
fi
[ -n "$UUID" ] || exit 0
[ -n "$CWD" ] || CWD="$PWD"

# instance <- CLAUDE_CONFIG_DIR matched against .../instances/<x>/ ; else raw.
INSTANCE=$(printf '%s' "${CLAUDE_CONFIG_DIR:-}" | sed -n 's|.*/instances/\([a-z]\)\(/.*\)\?$|\1|p')
[ -n "$INSTANCE" ] || INSTANCE=raw

# slug <- cwd with /->- (matches CC's projects-dir encoding) ; repo <- cwd basename.
SLUG=$(printf '%s' "$CWD" | sed 's|/|-|g')
REPO=$(basename "$CWD")

# tmux fields: empty unless under tmux. ONE combined display-message call, bounded
# by `timeout` so a hung tmux server fails open instead of wedging startup.
TMUX_SESSION=""
TMUX_WINDOW=""
PANE_ID=""
if [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then
  fmt=$'#{session_name}\t#{window_index}\t#{pane_id}'
  info=$(timeout 2 tmux display-message -p -t "$TMUX_PANE" "$fmt" 2>/dev/null) || info=""
  IFS=$'\t' read -r TMUX_SESSION TMUX_WINDOW PANE_ID <<<"$info"
  PANE_ID="${PANE_ID:-$TMUX_PANE}"
fi

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$TS" start "$UUID" "$INSTANCE" "$SLUG" "$REPO" \
  "$TMUX_SESSION" "$TMUX_WINDOW" "$PANE_ID" >> "$REGISTRY"

exit 0
