#!/usr/bin/env bash
# dhx-session-registry-prompt.sh — UserPromptSubmit hook
# Patterns: HP-008 (UserPromptSubmit session_id/cwd/transcript_path), HP-017 (plugin manifest), HP-043 + HP-044 ($TMUX-absent pane resolution via /proc-ancestry → pane_pid), HP-028 (no `cmd | grep -m` under pipefail — pane map built via here-string)
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
# error => exit 0 silently. No $TMUX => resolve the pane by a /proc-ancestry
# walk (the coord-less backfill — kill-switch DHX_REGISTRY_SKIP_PANE_BACKFILL=1
# => blank fields, status-quo). ONE tmux call max PER TURN: the $TMUX-present
# (display-message) and $TMUX-absent (list-panes) branches are MUTUALLY
# EXCLUSIVE, so no turn ever makes two — each bounded by `timeout` so a wedged
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

# --- /dhx:schedule liveness reference beat (cross-repo phase 40, D-03/D-22/D-28) ----------
# ABOVE the idempotency exit below, deliberately: this must fire on EVERY prompt, not once
# per session, or the per-session comparison reports the schedule leg dead in every long
# session. Warning sign that this got moved: the beat file's `count` never exceeds 1.
# One ~200-byte write; no lock, no directory scan; every failure path silent. $UUID and
# $INPUT are both already in hand, so this needs no additional jq call.
_SCH_HB_DIR="$HOME/.cache/dhx/hooks/prompt"
# printf '%s', never echo — echo appends a newline, sha256sum hashes it, and this digest
# would then never equal the Node side's for the same session.
_SCH_HB_KEY=$(printf '%s' "$UUID" | sha256sum 2>/dev/null | cut -c1-16) || _SCH_HB_KEY=""
# The EVENT digest: the RAW payload this hook already holds. `$(cat)` above already stripped
# trailing newlines — that is the canonicalisation, and the Node side strips identically. The
# two sides therefore agree WITHOUT any inter-hook communication, which the execution model
# forbids. Never compare beat timestamps: hooks on one event run concurrently, so a healthy
# leg's beat can legitimately be older than this one.
#
# ELIGIBILITY SYMMETRY: dhx-schedule-prompt.sh exits early on a non-empty agent_id and on an
# empty session_id. This beat sits above the `case "$TRANSCRIPT"` subagent guard below, so a
# subagent event could in principle produce a reference beat with no schedule counterpart —
# that combination is KNOWN-BENIGN, not a dead leg. (Vacuous in practice: a Task subagent
# fired ZERO UserPromptSubmit at 2.1.170 per this hook's own header.) Do NOT move this below
# the idempotency exit under any circumstance.
_SCH_EV_KEY=$(printf '%s' "$INPUT" | sha256sum 2>/dev/null | cut -c1-16) || _SCH_EV_KEY=""
if [ -n "$_SCH_HB_KEY" ]; then
  mkdir -p "$_SCH_HB_DIR" 2>/dev/null
  _SCH_HB_F="$_SCH_HB_DIR/$_SCH_HB_KEY.json"
  _SCH_HB_N=0
  [ -f "$_SCH_HB_F" ] && _SCH_HB_N=$(sed -n 's/.*"count"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$_SCH_HB_F" 2>/dev/null)
  case "$_SCH_HB_N" in ''|*[!0-9]*) _SCH_HB_N=0 ;; esac
  # D-28: BOTH identities — the one from stdin and the one visible in this process's
  # environment — so a later plan can OBSERVE whether they agree instead of assuming it.
  _SCH_ENV_KEY=$(printf '%s' "${CLAUDE_CODE_SESSION_ID:-}" | sha256sum 2>/dev/null | cut -c1-16) || _SCH_ENV_KEY=""
  # printf > tmp && mv is atomic, per this hook's own atomicity note.
  printf '{"last_fire_at":"%s","count":%d,"event_hash":"%s","session_hash_stdin":"%s","session_hash_env":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$((_SCH_HB_N+1))" "$_SCH_EV_KEY" "$_SCH_HB_KEY" "$_SCH_ENV_KEY" \
    > "$_SCH_HB_F.tmp.$$" 2>/dev/null \
    && mv -f "$_SCH_HB_F.tmp.$$" "$_SCH_HB_F" 2>/dev/null \
    || rm -f "$_SCH_HB_F.tmp.$$" 2>/dev/null
fi
# --- end /dhx:schedule beat ---------------------------------------------------------------

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

# tmux fields: resolved two MUTUALLY-EXCLUSIVE ways so "ONE tmux call max per
# turn" holds (only one branch ever runs); each is `timeout`-bounded → a hung
# tmux server fails open (blank coords) instead of wedging the turn.
#   1. $TMUX present → ONE targeted display-message (O(1), the original path).
#   2. $TMUX ABSENT  → ONE `list-panes -a` + a fork-free /proc-ancestry walk
#      from this hook ($$) up to a tmux pane_pid. CCS launchers drop $TMUX but
#      still spawn `claude` as a pane descendant, so ~65% of `start` rows land
#      here coord-less; this backfills the session/window/pane coords that
#      /dhx:history `recover`'s frozen-pane-screen join keys on (registry fields
#      7/8/9). HP-043 (/proc-ancestry primitive) + HP-008 ($$ descends from the
#      session's `claude`). Idempotency (the line-79 grep) means this runs at
#      most ONCE per session, so a genuinely pane-less session (a non-tmux bg
#      job) pays the walk once — never per turn; the row is still written with
#      blank coords (no retry loop). Kill-switch DHX_REGISTRY_SKIP_PANE_BACKFILL=1
#      disables branch 2 at runtime (→ status-quo blank coords) for a field
#      misattribution/regression the `timeout` can't catch — one var, no redeploy.
TMUX_SESSION=""
TMUX_WINDOW=""
PANE_ID=""
if [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then
  fmt=$'#{session_name}\t#{window_index}\t#{pane_id}'
  info=$(timeout 2 tmux display-message -p -t "$TMUX_PANE" "$fmt" 2>/dev/null) || info=""
  IFS=$'\t' read -r TMUX_SESSION TMUX_WINDOW PANE_ID <<<"$info"
  PANE_ID="${PANE_ID:-$TMUX_PANE}"
elif [ -z "${DHX_REGISTRY_SKIP_PANE_BACKFILL:-}" ]; then
  pane_lines=$(timeout 2 tmux list-panes -a \
    -F '#{pane_pid}|#{session_name}|#{window_index}|#{pane_id}' 2>/dev/null) || pane_lines=""
  if [ -n "$pane_lines" ]; then
    # Map pane_pid -> "session|window|pane" ONCE via a here-string read-loop —
    # in-shell (the array must survive), and HP-028-safe (NO `cmd | grep -m`:
    # under pipefail grep's early-exit SIGPIPEs the writer → 141 → a matched
    # coord would be silently dropped). The walk then does O(1) lookups, fork-free.
    declare -A _pane_by_pid
    while IFS='|' read -r _pp _ps _pw _pn; do
      [ -n "$_pp" ] && _pane_by_pid["$_pp"]="$_ps|$_pw|$_pn"
    done <<< "$pane_lines"
    walk=$$
    guard=0
    while [ -n "$walk" ] && [ "$walk" != "1" ] && [ "$walk" != "0" ] && [ "$guard" -lt 40 ]; do
      if [ -n "${_pane_by_pid[$walk]:-}" ]; then
        IFS='|' read -r TMUX_SESSION TMUX_WINDOW PANE_ID <<< "${_pane_by_pid[$walk]}"
        break
      fi
      # fork-free next-ancestor: ppid is field 2 after the last ') ' in /proc/<walk>/stat.
      line=""
      read -r line < "/proc/$walk/stat" 2>/dev/null || break
      rest="${line##*) }"   # "state ppid pgrp ..."
      rest="${rest#* }"     # drop state → "ppid pgrp ..."
      walk="${rest%% *}"    # keep ppid
      guard=$((guard+1))
    done
  fi
fi

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$TS" start "$UUID" "$INSTANCE" "$SLUG" "$REPO" \
  "$TMUX_SESSION" "$TMUX_WINDOW" "$PANE_ID" >> "$REGISTRY"

exit 0
