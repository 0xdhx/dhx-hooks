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
#   Research: the cross-repo knowledge base
#   Findings: ~/repos/acme-app/research/cc-session-identity/2026-06-09-cc-session-identity.md
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
# session. Warning sign that this got moved: a session's record directory never holds more
# than one file however many prompts it takes.
# One ~200-byte write; no lock, no directory scan; every failure path silent.
# Root honours DHX_HOOKS_CACHE_DIR (the Node reader's HOOKS_CACHE_ENV) so a probe can drive
# this into a fixture tree; the literal default is the reader's default, byte for byte.
_SCH_HB_DIR="${DHX_HOOKS_CACHE_DIR:-$HOME/.cache/dhx/hooks}/prompt"
# ELIGIBILITY PARITY with dhx/dhx-schedule-prompt.sh: that shim exits on a non-empty
# `.agent_id` and on an empty `.session_id` before it writes anything. Per-occurrence counting
# would turn ONE such asymmetric fire into a reference record with no schedule counterpart —
# DEAD for an otherwise healthy session — so this writer applies the SAME predicate, from the
# SAME jq extraction, before writing. The session key is therefore digested from `.session_id`
# alone (never the transcript-basename fallback $UUID carries), exactly as the shim keys it.
# The block still sits ABOVE the `case "$TRANSCRIPT"` subagent guard and the idempotency exit
# below: only the predicate moved here; the position did not and must not.
# NUL-framed, NOT `@tsv` + `IFS=$'\t' read`: TAB is IFS whitespace, so an EMPTY session_id
# collapsed and the agent id became the session key — a record written for a key that must
# not exist (docs/decisions.md 2026-09-25 row). A field carrying NUL makes jq error -> both
# empty -> no beat, the shim's own outcome for that payload.
{ IFS= read -r -d '' _SCH_SID; IFS= read -r -d '' _SCH_AGENT; } < <(printf '%s' "$INPUT" | jq -j '
  def f: (. // "") | tostring | if (explode | index(0)) != null then error("NUL in field") else . end;
  (.session_id | f), "\u0000", (.agent_id | f), "\u0000"' 2>/dev/null) || { _SCH_SID=""; _SCH_AGENT=""; }
# printf '%s', never echo — echo appends a newline, the hasher hashes it, and this digest
# would then never equal the Node side's for the same session.
# Digest chain: sha256sum, then shasum -a 256 (macOS) — the dhx/poll-guard.sh SESSION_HASH
# precedent. Inlined (no sourced lib) so this file stays a single self-contained unit. Both
# the SESSION key and the EVENT key go through it; neither tool present -> empty -> the
# guarded beat block below skips, fail-open, exactly as an empty key always did.
_dhx_digest16() {
  if command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum 2>/dev/null | cut -c1-16
  elif command -v shasum >/dev/null 2>&1; then printf '%s' "$1" | shasum -a 256 2>/dev/null | cut -c1-16
  fi
}
_SCH_HB_KEY=""
# QW_CELL=1 (a measured quota cell's client, 2026-09-23): the shim exits silent on it, so the
# reference beat is skipped on it too — the same parity, one more term.
if [ -z "${_SCH_AGENT:-}" ] && [ -n "${_SCH_SID:-}" ] && [ "${QW_CELL:-}" != "1" ]; then
  _SCH_HB_KEY=$(_dhx_digest16 "$_SCH_SID") || _SCH_HB_KEY=""
fi
# The EVENT digest: the RAW payload this hook already holds. `$(cat)` above already stripped
# trailing newlines — that is the canonicalisation, and the Node side strips identically. The
# two sides therefore agree WITHOUT any inter-hook communication, which the execution model
# forbids. Never compare beat timestamps: hooks on one event run concurrently, so a healthy
# leg's beat can legitimately be older than this one.
_SCH_EV_KEY=$(_dhx_digest16 "$INPUT") || _SCH_EV_KEY=""
# RECORD LAYOUT (schema_version 2 — cross-repo docs/research/2026-08-23-dhx-schedule-beat-record-
# layout-and-gc-design.md §1-§2): one directory per session, one IMMUTABLE file per occurrence,
#   <root>/prompt/<session16>/<event16|none>.<fired_ms>.<pid>.<nonce>.json
# Never overwritten, no `count` field — "how many" is the cardinality of the directory, and
# repeated byte-identical prompts are MEANT to produce N files sharing one <event16>. The name
# is for uniqueness only; dating is the record's `fired_at`. Field names/types must pass the
# Node side's `validateRecord` exactly (the schedule-only `result`/`due_hash` fields are
# deliberately absent on a reference record).
#
# _dhx_sch_record IS the whole transaction: mkdir -p the session dir, printf to a `.tmp.$$`
# sibling, rename (atomic, per this hook's own atomicity note). It is called a second time on
# failure because the schedule driver's GC quarantines an idle session directory by RENAMING
# it away — a writer that had already opened its temp file inside then loses the rename
# target; re-running the three steps recreates the directory, and the orphaned temp dies with
# the quarantine. That retry is what makes the GC's directory removal lossless.
_dhx_sch_record() {
  mkdir -p "$_SCH_REC_DIR" 2>/dev/null || return 1
  printf '{"schema_version":2,"kind":"%s","leg":"%s","fired_at":"%s","event_hash":%s,"session_hash_stdin":"%s","session_hash_env":"%s"}\n' \
    "$_SCH_KIND" "$_SCH_LEG" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_SCH_EV_JSON" "$_SCH_HB_KEY" "$_SCH_ENV_KEY" \
    > "$_SCH_REC_F.tmp.$$" 2>/dev/null \
    && mv -f "$_SCH_REC_F.tmp.$$" "$_SCH_REC_F" 2>/dev/null && return 0
  rm -f "$_SCH_REC_F.tmp.$$" 2>/dev/null
  return 1
}
if [ -n "$_SCH_HB_KEY" ]; then
  _SCH_LEG=prompt
  # D-28: BOTH identities — the one from stdin and the one visible in this process's
  # environment — so a later plan can OBSERVE whether they agree instead of assuming it.
  _SCH_ENV_KEY=$(_dhx_digest16 "${CLAUDE_CODE_SESSION_ID:-}") || _SCH_ENV_KEY=""
  # `kind:"undigested"` (event_hash null, file part `none`) keeps the printf total. In
  # practice the session key and the event key share one digest chain, so an empty event
  # key with a non-empty session key does not occur — the arm exists so no shape is unwritable.
  if [ -n "$_SCH_EV_KEY" ]; then
    _SCH_KIND=event; _SCH_EV_JSON='"'"$_SCH_EV_KEY"'"'; _SCH_EV_NAME="$_SCH_EV_KEY"
  else
    _SCH_KIND=undigested; _SCH_EV_JSON=null; _SCH_EV_NAME=none
  fi
  # Epoch ms for the file name; BSD date prints `%3N` literally, so anything not all-digits
  # falls back to whole seconds padded with 000. Nonce $RANDOM covers pid reuse.
  _SCH_MS=$(date +%s%3N 2>/dev/null)
  case "$_SCH_MS" in ''|*[!0-9]*) _SCH_MS="$(date +%s)000" ;; esac
  _SCH_REC_DIR="$_SCH_HB_DIR/$_SCH_HB_KEY"
  _SCH_REC_F="$_SCH_REC_DIR/$_SCH_EV_NAME.$_SCH_MS.$$.$RANDOM.json"
  _dhx_sch_record || _dhx_sch_record || true
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
  # Split on the TAB itself (`mapfile -d`), NOT `IFS=$'\t' read`: TAB is IFS whitespace, so read
  # collapses an empty field and shifts the rest left (docs/decisions.md 2026-09-25 row).
  mapfile -t -d $'\t' _tm <<<"$info"; _tm[-1]=${_tm[-1]%$'\n'}
  TMUX_SESSION=${_tm[0]-} TMUX_WINDOW=${_tm[1]-} PANE_ID=${_tm[2]-}
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
