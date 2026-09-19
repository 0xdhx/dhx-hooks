#!/usr/bin/env bash
# dhx-duplicate-launch.sh — UserPromptSubmit hook
# Patterns: HP-008 (.prompt / .session_id / .transcript_path / flat .cwd), HP-009 (advisory, exit 0),
#           HP-017 (plugin manifest), HP-046 (hookSpecificOutput.additionalContext reaches the model),
#           HP-055 (systemMessage RENDERS to the operator on UserPromptSubmit)
#
# ONE ADVISORY LINE when the typed prompt names a `docs/prompts/…\.md` handoff that ANOTHER session
# is already executing. Never blocks, never asks, never exits non-zero on a hit. Ruling:
#   ~/repos/skills/docs/decisions/2026-09-19-duplicate-prompt-launch-surface-never-gate.md
#   (§ Decision item 4; § Overturn window names what re-opens it).
# Origin: 2026-09-19, two sessions launched on one handoff 91 min apart; the second found the
# first by hand in ~10 minutes (commit trailers, a transcript mtime, a growing evidence file).
#
# COST SHAPE. Six hooks already share this seam. The prefix test on the RAW stdin bytes runs before
# any jq, so a prompt that does not mention `docs/prompts/` exits in about a millisecond —
# dhx-routing.sh's shape. The ~2s row-source call is paid only on a matching turn, and once per
# (session, path): a marker under $DHX_DUP_LAUNCH_CACHE_DIR suppresses re-evaluation, so a session
# that keeps naming its own prompt (the closeout `git mv`, a re-read) pays nothing after the first.
#
# ROW SOURCES (both PRIMARY on-disk; no process table):
#   1. Background jobs — `~/repos/skills/scripts/dhx-history/enumerate-bg-jobs.sh` (working jobs from
#      ~/.ccs/instances/<lane>/jobs/<id>/state.json; column 11 = the prompt/command the job is on).
#      CALLED, never copied (distribution-copy drift class). Absent, exit 3, or timeout → no rows.
#   2. Interactive sessions — not in that list. Covered by the transcripts beside this session's
#      own (`dirname .transcript_path` = the cwd slug dir) modified in the last
#      $DHX_DUP_LAUNCH_WINDOW_MIN minutes (120), newest 12, each read through
#      `extract-recent-signal.sh --file` — the FIRST USER-TYPED turn, which skips hook-injected
#      rows. A worktree session on the same handoff lives under a different slug and is NOT seen
#      here (bg jobs are, across every cwd). Stated residual, not a bug.
#
# WHY NOT `grep -c <path> <transcript>`: the scheduled-work hook injects prompt paths as `source:`
# lines (transcript `attachment` rows) before the user types, so every session in the repo
# "mentions" every due prompt. Measured 2026-09-19: the naive grep tagged an unrelated session.
#
# THE DUP RULE, applied here rather than read from the helper's `same_prompt` column: the primary
# is the EARLIEST-started other session on the path; the line fires only when it started
# ≥ $DHX_DUP_LAUNCH_MIN_GAP seconds (600) before now. Same constant, same semantics as the helper's
# `dup:` / `fanout:` split (7 of 9 same-prompt overlaps in a 14-day census were same-minute
# fan-outs). Re-applied locally because on the LAUNCH turn this session may not yet be in the
# helper's set (state.json linkScanPath not yet written; interactive sessions never are), so its
# own row cannot be relied on to carry the classification. Start time: a job's `createdAt`; an
# interactive transcript's first timestamped row.
#
# SELF-EXCLUSION (four layers, any one suffices): a row whose uuid or transcript is this
# session's; a job whose dir is $CLAUDE_JOB_DIR; a job whose state.json sessionId is this
# session's; and the gap rule itself (a self row on the launch turn started seconds ago).
# A `/dhx:vet …` opener is a READER — excluded as a candidate, and a vet-shaped typed prompt
# exits before any lookup.
#
# THE LINE (one line; HP-055 renders systemMessage as a single attributed line):
#   ⚠ docs/prompts/<file> is already running: job a/220bf73e started 91m ago, active 2m ago
#     (last commit 3e2b879 by that session) — continue anyway, or stop and check /dhx:history alive
# The trailer clause resolves the other session's `claude.ai/code/session_…` id from the head of
# its transcript and matches it against `Claude-Session:` trailers on this cwd's last 20 commits;
# absent either, the clause is dropped. Emitted on BOTH channels of one JSON object: systemMessage
# (the operator decides whether to stop) and additionalContext (the model would otherwise re-merge).
#
# OUTPUT CONTRACT: exactly one JSON object on stdout, or nothing. Every error path exits 0 silently.
# A probe asserts what this EMITS; that CC RENDERS it is HP-055's observation, not this file's.
#
# TEST SEAMS (hermetic; production sets none):
#   DHX_SKIP_DUPLICATE_LAUNCH=1   kill switch
#   DHX_DUP_LAUNCH_HELPER=<path>  row-source helper (default ~/repos/skills/scripts/dhx-history/enumerate-bg-jobs.sh;
#                                 extract-recent-signal.sh is resolved beside it)
#   DHX_BG_JOBS_ROOT / DHX_BG_JOBS_NOW   pass through to the helper (fixture jobs root / clock)
#   DHX_DUP_LAUNCH_NOW=<epoch>    this hook's clock for the gap (default DHX_BG_JOBS_NOW, then date)
#   DHX_DUP_LAUNCH_TX_DIR=<dir>   interactive transcript dir (default dirname of .transcript_path)
#   DHX_DUP_LAUNCH_WINDOW_MIN / DHX_DUP_LAUNCH_MIN_GAP / DHX_DUP_LAUNCH_CACHE_DIR
#
# Source-of-truth: ~/repos/hooks/dhx/dhx-duplicate-launch.sh
# Symlinked to:    ~/.claude/hooks/dhx-duplicate-launch.sh
set -uo pipefail

[ "${DHX_SKIP_DUPLICATE_LAUNCH:-0}" = "1" ] && exit 0

INPUT=$(cat)
# Prefix gate on the RAW bytes, before jq: the seam's cost shape. Anything else exits here.
case "$INPUT" in *docs/prompts/*) ;; *) exit 0 ;; esac
command -v jq >/dev/null 2>&1 || exit 0

# One parse for the scalar fields (none can contain a newline, so @tsv is safe — the
# dhx-schedule-prompt.sh shape). The prompt is parsed separately: it CAN contain newlines.
FIELDS=$(printf '%s' "$INPUT" | jq -r '[(.session_id // ""), (.transcript_path // ""), (.cwd // ""), (.agent_id // "")] | @tsv' 2>/dev/null) || exit 0
IFS=$'\t' read -r SESSION_ID TRANSCRIPT CWD AGENT_ID <<<"$FIELDS"
# Subagents fire no UserPromptSubmit (dhx-schedule-prompt.sh, defense in depth). Never slow one.
[ -n "$AGENT_ID" ] && exit 0
PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // ""' 2>/dev/null) || exit 0

# A vet-shaped typed prompt is a reader of the handoff, not an executor.
case "$PROMPT" in /dhx:vet*) exit 0 ;; esac
# The handoff this turn names: the first docs/prompts/…\.md path form (the helper's own regex,
# widened to stop at quotes/backticks/angle brackets a prose prompt wraps a path in).
KEY=$(command grep -oE 'docs/prompts/[^[:space:]"'"'"'`<>]*\.md' <<<"$PROMPT" 2>/dev/null | head -1)
[ -n "$KEY" ] || exit 0

# Once per (session, path): the marker is written whether or not the line fires — a later
# launcher of the same handoff is the one that needs telling, and it gets its own turn.
CACHE_DIR="${DHX_DUP_LAUNCH_CACHE_DIR:-$HOME/.cache/dhx/duplicate-launch}"
KEY_HASH=$(printf '%s' "$KEY" | md5sum 2>/dev/null | cut -c1-12)
MARK="$CACHE_DIR/${SESSION_ID:-nosession}.${KEY_HASH:-nokey}"
[ -e "$MARK" ] && exit 0
mkdir -p "$CACHE_DIR" 2>/dev/null && : > "$MARK" 2>/dev/null

NOW="${DHX_DUP_LAUNCH_NOW:-${DHX_BG_JOBS_NOW:-$(date +%s)}}"
MIN_GAP="${DHX_DUP_LAUNCH_MIN_GAP:-600}"
[[ "$MIN_GAP" =~ ^[0-9]+$ ]] || MIN_GAP=600
HELPER="${DHX_DUP_LAUNCH_HELPER:-$HOME/repos/skills/scripts/dhx-history/enumerate-bg-jobs.sh}"
SIGNAL="$(dirname "$HELPER")/extract-recent-signal.sh"
JOBS_ROOT="${DHX_BG_JOBS_ROOT:-$HOME/.ccs/instances}"
SELF_JOB_DIR="${CLAUDE_JOB_DIR:-}"; SELF_JOB_DIR="${SELF_JOB_DIR%/}"

# Candidates: start_epoch <TAB> label <TAB> uuid <TAB> transcript <TAB> age_secs
CANDS=()
SEEN_TX=()

_iso_epoch() { date -d "$1" +%s 2>/dev/null; }

# --- source 1: background jobs (working only; the helper's own filter) --------------------
if [ -f "$HELPER" ]; then
  ROWS=$(timeout 4 bash "$HELPER" 2>/dev/null); RC=$?
  if [ "$RC" -eq 0 ] && [ -n "$ROWS" ]; then
    while IFS=$'\t' read -r lane job _state _tempo uuid tx age _cwd _name _src sig _sp; do
      [ -n "${job:-}" ] || continue
      [ "$uuid" = "$SESSION_ID" ] && continue
      [ -n "$TRANSCRIPT" ] && [ "$tx" = "$TRANSCRIPT" ] && continue
      case "$sig" in /dhx:vet*) continue ;; esac
      case "$sig" in *"$KEY"*) ;; *) continue ;; esac
      JOB_DIR="$JOBS_ROOT/$lane/jobs/$job"
      [ -n "$SELF_JOB_DIR" ] && [ "$JOB_DIR" = "$SELF_JOB_DIR" ] && continue
      META=$(jq -r '[(.createdAt // ""), (.sessionId // "")] | @tsv' "$JOB_DIR/state.json" 2>/dev/null) || continue
      IFS=$'\t' read -r created sid <<<"$META"
      [ -n "$created" ] || continue
      [ -n "$SESSION_ID" ] && [ "$sid" = "$SESSION_ID" ] && continue
      cepoch=$(_iso_epoch "$created") || continue
      [[ "$age" =~ ^[0-9]+$ ]] || age=""
      CANDS+=("$cepoch"$'\t'"job $lane/$job"$'\t'"$uuid"$'\t'"$tx"$'\t'"$age")
      [ "$tx" != "-" ] && SEEN_TX+=("$tx")
    done <<<"$ROWS"
  fi
fi

# --- source 2: interactive transcripts beside this session's own -------------------------
TX_DIR="${DHX_DUP_LAUNCH_TX_DIR:-}"
[ -z "$TX_DIR" ] && [ -n "$TRANSCRIPT" ] && TX_DIR=$(dirname "$TRANSCRIPT")
WINDOW="${DHX_DUP_LAUNCH_WINDOW_MIN:-120}"
[[ "$WINDOW" =~ ^[0-9]+$ ]] || WINDOW=120
if [ -n "$TX_DIR" ] && [ -d "$TX_DIR" ] && [ -f "$SIGNAL" ]; then
  while IFS= read -r tx; do
    [ -n "$tx" ] || continue
    [ -n "$TRANSCRIPT" ] && [ "$tx" = "$TRANSCRIPT" ] && continue
    uuid=$(basename "$tx" .jsonl)
    [ "$uuid" = "$SESSION_ID" ] && continue
    skip=0; for s in "${SEEN_TX[@]+"${SEEN_TX[@]}"}"; do [ "$s" = "$tx" ] && { skip=1; break; }; done
    [ "$skip" -eq 1 ] && continue
    sig=$(timeout 2 bash "$SIGNAL" --file "$tx" --max-chars 200 2>/dev/null | sed -n 's/^SIGNAL: //p' | head -1)
    case "$sig" in /dhx:vet*) continue ;; esac
    case "$sig" in *"$KEY"*) ;; *) continue ;; esac
    # Start = the first timestamped row (the leading last-prompt/mode rows carry none).
    start=$(head -n 80 "$tx" 2>/dev/null | jq -r 'select(.timestamp != null) | .timestamp' 2>/dev/null | head -1)
    [ -n "$start" ] || continue
    sepoch=$(_iso_epoch "$start") || continue
    mt=$(stat -c %Y "$tx" 2>/dev/null) || mt="$NOW"
    CANDS+=("$sepoch"$'\t'"session ${uuid:0:8}"$'\t'"$uuid"$'\t'"$tx"$'\t'"$(( NOW - mt ))")
  done < <(command find "$TX_DIR" -maxdepth 1 -name '*.jsonl' -mmin "-$WINDOW" -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -12 | cut -d' ' -f2-)
fi

[ "${#CANDS[@]}" -gt 0 ] || exit 0

# The primary is the earliest start. Fan-out (primary younger than MIN_GAP) → no line.
PRIMARY=$(printf '%s\n' "${CANDS[@]}" | LC_ALL=C sort -t$'\t' -k1,1n | head -1)
IFS=$'\t' read -r P_START P_LABEL P_UUID P_TX P_AGE <<<"$PRIMARY"
[[ "$P_START" =~ ^[0-9]+$ ]] || exit 0
GAP=$(( NOW - P_START ))
[ "$GAP" -ge "$MIN_GAP" ] || exit 0

# Minutes below two hours (the incident reads "91m"), hours+minutes above.
_fmt_age() { local s=$1; [ "$s" -lt 0 ] && s=0
  if [ "$s" -lt 7200 ]; then printf '%dm' $(( s / 60 )); else printf '%dh%02dm' $(( s / 3600 )) $(( (s % 3600) / 60 )); fi; }

ACTIVE="still active"
if [[ "${P_AGE:-}" =~ ^-?[0-9]+$ ]]; then
  [ "$P_AGE" -lt 0 ] && P_AGE=0
  if [ "$P_AGE" -lt 60 ]; then ACTIVE="active now"; else ACTIVE="active $(_fmt_age "$P_AGE") ago"; fi
fi

# Last commit carrying that session's Claude-Session trailer (skip the clause if none).
COMMIT_CLAUSE=""
if [ -n "$CWD" ] && [ -f "$P_TX" ] && [ -d "$CWD" ]; then
  SURL=$(head -c 400000 "$P_TX" 2>/dev/null | command grep -oE 'claude\.ai/code/session_[A-Za-z0-9]+' 2>/dev/null | head -1)
  if [ -n "$SURL" ]; then
    H=$(timeout 2 git -C "$CWD" log --format='%h %(trailers:key=Claude-Session,valueonly)' -20 2>/dev/null \
        | command grep -F "$SURL" 2>/dev/null | head -1 | cut -d' ' -f1)
    [ -n "$H" ] && COMMIT_CLAUSE=" (last commit $H by that session)"
  fi
fi

LINE="⚠ $KEY is already running: $P_LABEL started $(_fmt_age "$GAP") ago, $ACTIVE$COMMIT_CLAUSE — continue anyway, or stop and check /dhx:history alive"
MODEL="$LINE. Surface this to the operator before starting; do not duplicate or re-merge that session's work."

jq -nc --arg m "$LINE" --arg c "$MODEL" \
  '{systemMessage: $m, hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}' 2>/dev/null
exit 0
