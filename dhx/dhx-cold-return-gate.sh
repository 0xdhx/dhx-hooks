#!/usr/bin/env bash
# dhx-cold-return-gate.sh — UserPromptSubmit hook (matchless)
# Patterns: HP-008, HP-009, HP-012, HP-017, HP-019, HP-027
#
# Cold-return advisory gate. Blocks exactly ONE prompt (exit 2) when the
# session is about to pay a full cold-cache prefix rewrite, names the cost
# fork in stderr, stages the erased prompt to disk, and lets the immediate
# resend through untouched.
#
# Why exit 2 and not an advisory: exit 2 on UserPromptSubmit blocks BEFORE any
# API call — zero tokens burn, nothing lands in the transcript, and Claude never
# sees the turn. A non-blocking advisory forfeits exactly that property, which
# is the whole point: the send this gate intercepts costs ~2x the context in
# base-input-token equivalents (1h cache write = 2.0x, warm read = 0.1x).
#
# Fire condition (ALL must hold):
#   (a) cache anchor age > TTL          — the warm prefix is gone
#   (b) context estimate >= arm level   — the rewrite is expensive enough to flag
#   (c) anchor state is unambiguous     — see "fail open" below
#   (d) no cooldown / no live marker    — at most one block per cooldown window
#
# Fail open (load-bearing). Blocking erases the operator's prompt (CC-documented
# exit-2 semantics), so an uncertain read must never block. Every ambiguity —
# absent/unreadable transcript, no anchor candidate in the tail window, JSONL
# timestamp disorder (HP-019 addendum: file order is NOT timestamp order after a
# suspend/resume), future-dated anchor, unparseable context — exits 0 silently.
# Blocking requires POSITIVE confidence, never the absence of contrary evidence.
#
# Anchor (HP-019). Newest MAIN-CHAIN (isSidechain != true) assistant entry BY
# TIMESTAMP carrying either a positive cache_read OR a substantial cache_creation.
# The read-only predicate used by dhx/statusline-wrapper.js::readCacheAnchor is
# deliberately NOT copied: it is the source of that reader's known one-turn lag
# (a completed cold write means the server just wrote a warm prefix, so it IS an
# anchor). A blocking gate cannot afford a one-turn-stale anchor.
#
# TTL source. Read from the actual cache-write bucket in the newest main-chain
# usage entry (cache_creation.ephemeral_1h_input_tokens vs ephemeral_5m_...);
# fall back to 3600 with the message saying so explicitly. Never silently assume
# warm: billed-overage flips the account to a 5m TTL, and no local signal detects
# that flip, so an assumed 1h is a floor-confidence input, not a fact.
#
# Anchor invalidation (HP-027). /model and /login destroy the whole cache key
# while the age clock still reads warm — and CLI slash commands bypass
# UserPromptSubmit entirely, so they can only ever be OBSERVED from the
# transcript, never intercepted here. A `<command-name>/model|/login` user entry
# newer than the anchor therefore invalidates the anchor and this gate FAILS OPEN
# (accepting a false negative). Rationale: the operator who just typed /model has
# already committed to the rewrite, and we have no confident anchor left to
# reason from — the confidence gate outranks the extra warning.
#
# Marker (one-shot override). Keyed {session_id, short expiry}, NEVER repo-wide —
# a repo-wide one-shot lets a concurrent session consume another session's
# bypass. Atomic create (mktemp + rename) and atomic consume (rename-then-remove).
# The prompt hash is recorded for provenance but is deliberately NOT part of the
# match: the marker records "the operator saw the advisory and chose to proceed",
# and hash-strict matching would re-block a resend the operator lightly edited —
# precisely the paste-repair path the stage file exists to protect.
#
# Stage file. mode 0600, holds the exact `.prompt` bytes, path named in the
# stderr message, removed when the marker is consumed. Exit 2 ERASES the
# submitted prompt, so a multiline paste would otherwise be unrecoverable.
#
# Cost: one jq parse of a bounded transcript tail per user turn (not per tool
# call). Silent on the happy path.
#
# Env seams (also the probe seams — keep them working):
#   DHX_COLD_RETURN_DISABLE=1      kill switch, exit 0 immediately
#   DHX_COLD_RETURN_CACHE_DIR      marker/stage/state dir (default ~/.cache/dhx)
#   DHX_COLD_RETURN_CONTEXT_MIN    context threshold in tokens (default 150000)
#   DHX_COLD_RETURN_TTL            TTL override in seconds (skips bucket read)
#   DHX_COLD_RETURN_COOLDOWN       seconds between blocks (default 900)
#   DHX_COLD_RETURN_NOW            epoch override for deterministic tests
#   DHX_COLD_RETURN_WINDOW         transcript tail bytes (default 262144)

set -uo pipefail

[ "${DHX_COLD_RETURN_DISABLE:-0}" = "1" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)
[ -n "$INPUT" ] || exit 0

# Field extraction. session_id / transcript_path / agent_id cannot contain a
# newline, so @tsv is safe for them (docs/decisions.md 2026-08-03 @tsv defect
# row). `.prompt` CAN contain newlines and is never read through @tsv — it is
# streamed straight to the stage file by jq below.
FIELDS=$(printf '%s' "$INPUT" | jq -r '[(.session_id // ""), (.transcript_path // ""), (.agent_id // "")] | @tsv' 2>/dev/null) || exit 0
IFS=$'\t' read -r SESSION_ID TRANSCRIPT AGENT_ID <<<"$FIELDS"

# Defense in depth: subagents fire no UserPromptSubmit (HP-008 decommissioning
# cross-check: 0 of 1,185 fires carried agent_id). Never block a subagent turn.
[ -n "${AGENT_ID:-}" ] && exit 0
[ -n "${SESSION_ID:-}" ] || exit 0

# Sanitize the session id before it reaches a path (V5 input-validation
# discipline) — a payload-controlled `..` or `/` must not escape the cache dir.
SID=${SESSION_ID//[^A-Za-z0-9_-]/}
[ -n "$SID" ] || exit 0

CACHE_DIR="${DHX_COLD_RETURN_CACHE_DIR:-$HOME/.cache/dhx}"
MARKER="$CACHE_DIR/cold-return-marker-$SID.json"
STATE="$CACHE_DIR/cold-return-state-$SID.json"
NOW="${DHX_COLD_RETURN_NOW:-$(printf '%(%s)T' -1)}"

# --- Step 1: marker consume (the one-shot override) -------------------------
# Present + unexpired => this is the operator's resend. Consume atomically and
# let it through. Present + expired => stale; clean up and keep evaluating.
if [ -f "$MARKER" ]; then
  M_EXP=$(jq -r '.expires_at_epoch // 0' "$MARKER" 2>/dev/null) || M_EXP=0
  M_STAGE=$(jq -r '.stage_path // ""' "$MARKER" 2>/dev/null) || M_STAGE=""
  case "$M_EXP" in ''|*[!0-9]*) M_EXP=0 ;; esac
  # rename-then-remove: whoever wins the rename owns the consume. A given
  # session submits prompts serially, so this only guards against a stray
  # concurrent reader, never a real race.
  CLAIM="$MARKER.consumed.$$"
  if mv -f "$MARKER" "$CLAIM" 2>/dev/null; then
    rm -f "$CLAIM" 2>/dev/null
    [ -n "$M_STAGE" ] && rm -f "$M_STAGE" 2>/dev/null
  fi
  if [ "$M_EXP" -gt "$NOW" ] 2>/dev/null; then
    exit 0   # operator acknowledged the advisory — pass untouched
  fi
fi

# --- Step 2: cooldown -------------------------------------------------------
# Bounds worst-case friction to one block per window even if the resend never
# reaches the API (aborted send, error turn) and the anchor therefore never moves.
COOLDOWN="${DHX_COLD_RETURN_COOLDOWN:-900}"
if [ -f "$STATE" ]; then
  LAST=$(jq -r '.blocked_at_epoch // 0' "$STATE" 2>/dev/null) || LAST=0
  case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
  if [ "$LAST" -gt 0 ] && [ $((NOW - LAST)) -lt "$COOLDOWN" ] && [ $((NOW - LAST)) -ge 0 ]; then
    exit 0
  fi
fi

# --- Step 3: transcript tail read ------------------------------------------
[ -n "${TRANSCRIPT:-}" ] || exit 0
[ -r "$TRANSCRIPT" ] || exit 0

WINDOW="${DHX_COLD_RETURN_WINDOW:-262144}"
CRT_MIN=10000   # "substantial" cold write; the fleet-warm base sits near ~20k

# One bounded pass. Emits TSV: anchor_ts ctx ttl ttl_src disorder invalidated
#   anchor_ts   epoch seconds of the anchoring main-chain completion
#   ctx         input geometry of that completed request (input+read+creation)
#   ttl         3600 | 300 from the observed write bucket (0 = unobserved)
#   ttl_src     observed | assumed
#   disorder    1 when file order disagrees with timestamp order (HP-019)
#   invalidated 1 when /model|/login was observed after the anchor (HP-027)
# `fromjson? // empty` drops the partial first line of the tail window and any
# mid-write torn record, which is why no separate partial-line guard is needed.
SCAN=$(tail -c "$WINDOW" "$TRANSCRIPT" 2>/dev/null | jq -R -s -r '
  # jq'"'"'s fromdateiso8601 rejects fractional seconds, and every CC timestamp
  # carries milliseconds — strip them before parsing. A format change makes the
  # parse yield null, which drops the entry and fails the gate open.
  def epoch: (. // "") | sub("\\.[0-9]+(?=([Zz]|[+-][0-9]))"; "") | fromdateiso8601? // null;
  split("\n") | map(fromjson? // empty) as $all
  | ($all | map(select(.type == "assistant" and (.isSidechain != true) and (.message.usage != null))
      | {
          ts:    (.timestamp | epoch),
          read:  (.message.usage.cache_read_input_tokens // 0),
          crt:   (.message.usage.cache_creation_input_tokens // 0),
          e1h:   (.message.usage.cache_creation.ephemeral_1h_input_tokens // 0),
          e5m:   (.message.usage.cache_creation.ephemeral_5m_input_tokens // 0),
          inp:   (.message.usage.input_tokens // 0)
        }
      | select(.ts != null))) as $mains
  | ($mains
      | reduce .[] as $m ({mx: -1e18, bad: 0};
          if $m.ts < (.mx - 60) then {mx: .mx, bad: 1}
          else {mx: (if $m.ts > .mx then $m.ts else .mx end), bad: .bad} end)
      | .bad) as $disorder
  | ($mains | map(select(.read > 0 or .crt >= '"$CRT_MIN"'))) as $cands
  | (if ($cands | length) == 0 then null else ($cands | max_by(.ts)) end) as $anchor
  | ($mains | map(select((.e1h + .e5m) > 0))) as $bucketed
  | (if ($bucketed | length) == 0 then null else ($bucketed | max_by(.ts)) end) as $bkt
  | ($all | map(select(.type == "user" and (.isSidechain != true))
      | {ts: (.timestamp | epoch),
         c: ((.message.content // "") | tostring)}
      | select(.ts != null)
      | select(.c | test("<command-name>/(model|login)")))) as $invcmds
  | if $anchor == null then "NONE"
    else [
      ($anchor.ts | floor),
      (($anchor.inp + $anchor.read + $anchor.crt) | floor),
      (if $bkt == null then 0 elif $bkt.e1h >= $bkt.e5m then 3600 else 300 end),
      (if $bkt == null then "assumed" else "observed" end),
      $disorder,
      (if ($invcmds | map(select(.ts > $anchor.ts)) | length) > 0 then 1 else 0 end)
    ] | @tsv end') || exit 0

[ -n "$SCAN" ] || exit 0
[ "$SCAN" = "NONE" ] && exit 0   # no anchor candidate in window — fail open

IFS=$'\t' read -r A_TS CTX TTL TTL_SRC DISORDER INVALID <<<"$SCAN"
case "${A_TS:-}" in ''|*[!0-9]*) exit 0 ;; esac
case "${CTX:-}" in ''|*[!0-9]*) exit 0 ;; esac
[ "${DISORDER:-1}" = "0" ] || exit 0   # HP-019 file disorder — fail open
[ "${INVALID:-1}" = "0" ] || exit 0    # HP-027 model/login observed — fail open

# --- Step 4: fire condition -------------------------------------------------
if [ -n "${DHX_COLD_RETURN_TTL:-}" ]; then
  TTL="$DHX_COLD_RETURN_TTL"
  TTL_SRC="override"
elif [ "${TTL:-0}" -eq 0 ] 2>/dev/null; then
  TTL=3600
  TTL_SRC="assumed"
fi

AGE=$((NOW - A_TS))
[ "$AGE" -lt -60 ] && exit 0        # anchor dated in the future — fail open
[ "$AGE" -gt "$TTL" ] || exit 0     # cache still warm

# Deadband around the context threshold. The estimate is derived from the last
# completed request's input geometry and cannot see what the NEXT request adds
# (fresh output, thinking, attachments, hook injections), so it is arm-at-1.1x
# rather than a bare comparison: a block costs the operator a real prompt, and
# jitter at the boundary must not buy that cost. The message says "~", never a
# precise figure.
CTX_MIN="${DHX_COLD_RETURN_CONTEXT_MIN:-150000}"
ARM=$((CTX_MIN + CTX_MIN / 10))
[ "$CTX" -ge "$ARM" ] || exit 0

# --- Step 5: stage the prompt, arm the marker, block ------------------------
umask 077
mkdir -p "$CACHE_DIR" 2>/dev/null || exit 0

STAGE="$CACHE_DIR/cold-return-stage-$SID.txt"
# `jq -j`, not `-r`: -r appends a newline, and the staged copy must be the
# operator's exact bytes — this file IS the paste they cannot otherwise recover.
if ! printf '%s' "$INPUT" | jq -j '.prompt // empty' > "$STAGE" 2>/dev/null; then
  rm -f "$STAGE" 2>/dev/null
  exit 0   # cannot stage => cannot safely erase the prompt => never block
fi
chmod 600 "$STAGE" 2>/dev/null
[ -s "$STAGE" ] || { rm -f "$STAGE" 2>/dev/null; exit 0; }

P_HASH=$(sha256sum < "$STAGE" 2>/dev/null | cut -c1-16) || P_HASH=""
EXP=$((NOW + 600))

MTMP=$(mktemp "$CACHE_DIR/.cold-return-marker-$SID.XXXXXX" 2>/dev/null) || { rm -f "$STAGE"; exit 0; }
if ! jq -n --arg s "$SESSION_ID" --arg st "$STAGE" --arg h "$P_HASH" \
        --argjson e "$EXP" --argjson c "$NOW" \
        '{session_id:$s, stage_path:$st, prompt_sha256_16:$h, created_at_epoch:$c, expires_at_epoch:$e}' \
        > "$MTMP" 2>/dev/null; then
  rm -f "$MTMP" "$STAGE" 2>/dev/null
  exit 0
fi
mv -f "$MTMP" "$MARKER" 2>/dev/null || { rm -f "$MTMP" "$STAGE" 2>/dev/null; exit 0; }

STMP=$(mktemp "$CACHE_DIR/.cold-return-state-$SID.XXXXXX" 2>/dev/null)
if [ -n "${STMP:-}" ]; then
  if jq -n --argjson b "$NOW" --argjson ctx "$CTX" --argjson age "$AGE" \
        '{blocked_at_epoch:$b, context_estimate:$ctx, anchor_age_s:$age}' > "$STMP" 2>/dev/null; then
    mv -f "$STMP" "$STATE" 2>/dev/null || rm -f "$STMP" 2>/dev/null
  else
    rm -f "$STMP" 2>/dev/null
  fi
fi

# Sweep stage files orphaned by sessions that never resent. Block path only —
# never on the hot path. Bounded by the cache dir's own size.
find "$CACHE_DIR" -maxdepth 1 -name 'cold-return-stage-*.txt' -mmin +1440 -delete 2>/dev/null

# --- Step 6: the message ----------------------------------------------------
# Flush-left, <=76 cols, one status symbol from the safe set, no padded label
# gutter (a wrapped continuation returns to column 0 and would invert the
# hierarchy), no markdown headers (they flatten to bold). Summary first: an
# operator returning after an hour reads line 1 and already has the decision.
AGE_H=$((AGE / 3600))
AGE_M=$(((AGE % 3600) / 60))
if [ "$AGE_H" -gt 0 ]; then AGE_TXT=$(printf '%dh%02dm' "$AGE_H" "$AGE_M"); else AGE_TXT="${AGE_M}m"; fi
CTX_K=$(((CTX + 500) / 1000))
COLD_K=$(((CTX * 2 + 500) / 1000))
WARM_K=$(((CTX / 10 + 500) / 1000))
if [ "$TTL" -ge 3600 ]; then TTL_TXT="1h"; else TTL_TXT="$((TTL / 60))m"; fi
case "$TTL_SRC" in
  observed) TTL_NOTE="TTL ${TTL_TXT} (observed write bucket)" ;;
  override) TTL_NOTE="TTL ${TTL_TXT} (env override)" ;;
  *)        TTL_NOTE="TTL ${TTL_TXT} assumed — write bucket unreadable; 5m if in overage" ;;
esac

{
  printf '⚠ Cold cache — this send pays a full prefix rewrite.\n\n'
  printf 'Anchor %s old · %s\n' "$AGE_TXT" "$TTL_NOTE"
  printf 'Context ~%sk → ≈%sk equivalents to rewarm (~%sk if it were warm)\n\n' \
    "$CTX_K" "$COLD_K" "$WARM_K"
  printf '/clear if this arc is done · /compact if it is not (cold, keeps context)\n'
  printf 'Resend to send it anyway. Your prompt was erased on block and saved at:\n'
  printf '%s\n' "$STAGE"
} >&2

exit 2
