#!/usr/bin/env bash
# dhx-session-registry-prompt.sh — UserPromptSubmit hook
# Patterns: HP-008 (UserPromptSubmit provides session_id/cwd + flat transcript_path), HP-017 (plugin manifest)
#
# Self-backfill producer for the alive-session recovery registry. Replaces the
# retired SessionStart `dhx-session-registry-start.sh` (birth capture). On each
# user turn, if the CURRENT session_id has no `start` row yet, append one — the
# SAME 9-field row registry-start wrote, with instance/slug/repo/tmux derived
# identically. Idempotent (grep-then-append; one row per uuid; a no-op after the
# first turn of a session).
#
# WHY first-turn instead of birth (2026-06-08 design falsified in production):
# one logical CC session wears MANY transcript uuids over its life, and the uuid
# SessionStart registered was routinely NOT the uuid the operator held on exit /
# would resume (continuation-mint on /exit-resume fires no SessionStart for the
# new uuid — non-deterministic, live at 2.1.170). Binding registration to the
# uuid that is current WHEN A HUMAN TYPES captures the uuid that actually
# accumulates the conversation and that CC reports on exit. "No turn → no row"
# also excludes RC bridge-ghost / summary files (#29205) for free.
#   Research: ~/repos/cross-repo/docs/research/2026-06-09-cc-session-uuid-identity-registry-unreliability.md
#   Findings: ~/repos/forgefinder/research/cc-session-identity/2026-06-09-cc-session-identity.md
#   Contract (row schema — do NOT diverge): ~/repos/cross-repo/.planning/backlog/2026-06-08-alive-session-recovery-registry.md
#
# Registry path is LITERAL $HOME/.claude — NOT $CLAUDE_CONFIG_DIR. Under CCS the
# latter is per-instance (a|b|c) and would fragment the registry into three
# files; the whole point is ONE shared event log across all instances.
#
# Row (9-field TSV — identical to the retired registry-start):
#   <iso_ts>\tstart\t<uuid>\t<instance>\t<slug>\t<repo>\t<tmux_session>\t<tmux_window>\t<pane_id>
#
# Fail-open contract: UserPromptSubmit must NEVER block or slow a prompt. Any
# error => exit 0 silently. No $TMUX => empty tmux fields (not an error). ONE
# tmux call max (combined display-message), bounded by `timeout` so a wedged
# tmux server can't hang the turn — mind the 2026-04-26 capture-pane IPC-wedge
# class. Atomicity: `printf >> file` is an atomic O_APPEND for rows < PIPE_BUF
# (4096 B); concurrent appends from other sessions cannot interleave. A given
# session fires UserPromptSubmit serially (one turn at a time), so a uuid never
# races itself; the consumer keys by uuid, so a worst-case cross-session dup is
# harmless. No flock (per contract).
#
# Subagent defense-in-depth (optional per research — a Task subagent fired ZERO
# UserPromptSubmit at 2.1.170, so this is belt-and-suspenders): skip any payload
# whose transcript_path sits under a /subagents/ dir. Cheap case-glob, no extra
# payload parsing.
set -uo pipefail

REGISTRY="$HOME/.claude/dhx-session-registry.tsv"

INPUT=$(cat)

# Silent exit on unparseable JSON — a prompt hook must never fail.
echo "$INPUT" | jq -e . >/dev/null 2>&1 || exit 0

UUID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
# UserPromptSubmit carries FLAT `.cwd` (NOT `.workspace.current_dir`) —
# live-probed 2026-06-09. PWD fallback mirrors registry-start.
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)

# uuid fallback: basename of transcript_path sans .jsonl (parity with registry-start).
if [ -z "$UUID" ] && [ -n "$TRANSCRIPT" ]; then
  UUID=$(basename "$TRANSCRIPT" .jsonl)
fi
[ -n "$UUID" ] || exit 0
[ -n "$CWD" ] || CWD="$PWD"

# Subagent guard (optional defense-in-depth): a subagent transcript lives under
# .../subagents/...; never register a subagent uuid as a session.
case "$TRANSCRIPT" in
  */subagents/*) exit 0 ;;
esac

# Idempotency: one `start` row per uuid. The trailing tab pins the match to the
# WHOLE uuid field (field 3, always followed by the instance field's tab), so
# `uuid-AAA` cannot match `uuid-AAAB`. grep -F treats the embedded tabs as
# literals; a missing registry file => grep non-zero => fall through to append
# (the printf creates it). Already-registered => silent no-op.
MATCH=$(printf '\tstart\t%s\t' "$UUID")
if grep -qF -- "$MATCH" "$REGISTRY" 2>/dev/null; then
  exit 0
fi

# --- derivation lifted verbatim from registry-start ---

# instance <- CLAUDE_CONFIG_DIR matched against .../instances/<x>/ ; else raw.
INSTANCE=$(printf '%s' "${CLAUDE_CONFIG_DIR:-}" | sed -n 's|.*/instances/\([a-z]\)\(/.*\)\?$|\1|p')
[ -n "$INSTANCE" ] || INSTANCE=raw

# slug <- cwd with /->- (matches CC's projects-dir encoding) ; repo <- cwd basename.
SLUG=$(printf '%s' "$CWD" | sed 's|/|-|g')
REPO=$(basename "$CWD")

# tmux fields: empty unless under tmux. ONE combined display-message call, bounded
# by `timeout` so a hung tmux server fails open instead of wedging the turn.
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
