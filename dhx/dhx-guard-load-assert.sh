#!/usr/bin/env bash
# dhx-guard-load-assert.sh — SessionStart + UserPromptSubmit, CROSS-CHANNEL plugin-load assertion.
# Patterns: HP-046 (hookSpecificOutput.additionalContext reaches the model),
#           HP-055 (systemMessage RENDERS to the operator on UserPromptSubmit),
#           HP-012 (settings.json registration DOES hot-reload, at user scope),
#           HP-020 (the PLUGIN MANIFEST does not passively hot-reload),
#           HP-015 (SessionStart fires on startup/resume/clear/compact -- and, per its
#                   2026-09-24 correction, NOT for a fork's id or a continuation-mint's id)
#
# ONE WARNING per session invocation when the dhx plugin channel left no trace of having run
# for this session -- which means every dhx PreToolUse guard is absent from the running
# process. Never blocks. Silent on the happy path.
#
# --- Why this hook is registered in settings.json and NOT in the plugin manifest ---
# THIS IS THE WHOLE POINT, and it is the one thing about this file that must never be
# "tidied up" by moving it into the manifest with its siblings. A hook cannot report that
# its own registration channel failed to load: if the channel is dead, so is the reporter.
# An observer has to live in a DIFFERENT channel from the thing it observes. There are
# exactly two on this machine -- the plugin manifest and the live settings file resolved
# through $CLAUDE_CONFIG_DIR -- so the observer of the manifest goes in settings, and the
# repo's "plugin manifest is the registration path" rule yields here for that reason.
# (Raised by an external reviewer, 2026-09-20, against an earlier design that put the
# assertion in the manifest alongside the guards it was meant to vouch for.)
# It is registered TWICE in settings.json, both entries this one file: on SessionStart it
# writes a birth stamp and exits silent; on UserPromptSubmit it asserts.
#
# --- What it observes, and why that is evidence ---
# Two plugin-channel writers leave records under <cache>/<leg>/<sha256-16 of session id>/:
#   session-start/  the manifest's SessionStart dispatcher, as its FIRST action (the "beat")
#   prompt/         dhx-session-registry-prompt.sh, on every UserPromptSubmit
# A record from either is proof the manifest channel loaded AND CC routed an event into it.
# Disk state is not proof of that and never was -- correct symlinks, a correct manifest and a
# green scripts/verify-hooks.sh are all compatible with a registry CC quietly declined
# (precedent: CC 2.1.272 silently rejected the marketplace heal's output while every
# jq-level check read green).
# The settings channel's OWN SessionStart entry writes <cache>/guard-load-assert-state/<key>/
# birth (epoch ms). That stamp is what scopes the evidence to THIS invocation: a --resume of an
# old id keeps the old invocation's beat on disk, so "any record ever" would mask a plugin that
# died between the two invocations (external reviewer, 2026-09-24 -- the hole predates this
# design; keying on the beat alone had it too).
#
# --- What it does NOT prove (stated here so nobody reads it as more than it is) ---
# A record proves the CHANNEL loaded. It does not prove CC routes PreToolUse to each
# individual guard, and no SessionStart- or prompt-time signal can: routing is per-event and
# per-matcher. A guard that is registered, present and never invoked looks identical from
# here. Only firing a guard and observing the refusal proves that, which is a behavioural
# probe's job, not this hook's. NECESSARY, NOT SUFFICIENT -- do not let a green assertion here
# retire a behavioural check.
#
# --- Five states every registry-level check reads as identical, and which of them warn ---
# Correct symlinks, a correct manifest and a green verify-hooks.sh hold in all five. Only the
# channel records and this hook's own stamps tell them apart -- which is why it reads those.
#   1. loaded                  -> beat (or prompt record) from this invocation -> SILENT.
#   2. registry rejected       -> SessionStart fired (birth stamp) but the plugin wrote nothing
#                                 for this invocation -> WARN at the FIRST prompt. The guards
#                                 are genuinely not in the running process.
#   3. manifest edited mid-session -> beat PRESENT -> SILENT. HP-020: registration does not
#      hot-reload, so a hook added to the manifest just now legitimately will not fire until
#      a reload -- but the dispatcher already ran at SessionStart and its beat is already on
#      disk. Keying on channel records rather than on manifest freshness is what keeps this
#      hook quiet through every hook-development session in this repo, which is the failure
#      mode that would get it disabled within a day.
#   4. born without SessionStart, channel live (2026-09-24) -> no birth stamp, no beat, but
#      plugin prompt records -> SILENT. CC fires NO SessionStart, in either channel, for a
#      fork's id, a continuation-mint on /exit-resume, or some /compact continuations. Keying
#      on the beat alone false-alarmed on every one of them: 7 of 7 warnings on this host up
#      to 2026-09-24 were false (5 this shape; 2 from 2fd26c1c's QW_CELL early exit, which
#      skipped the beat for 22 minutes). Zero genuine catches.
#   5. born without SessionStart, channel dead -> no birth, no beat, no prompt record from an
#      EARLIER prompt -> WARN at the SECOND prompt, NO LATER. The first prompt cannot decide:
#      hooks on one event run concurrently and that prompt's own record landed 31 ms AFTER
#      this hook ran in the fork that surfaced the defect. So prompt 1 plants a `pending`
#      stamp and stays silent; prompt N+1 sees prompt N's writer finished. The witness is
#      weaker here (no SessionStart ever fired), so this warning's text says "appears".
#
# --- Before ANY warning: a bounded wait for the concurrent witness ---
# The plugin's prompt writer runs concurrently on the same prompt. Before warning, poll up to
# 2 s (DHX_GUARD_LOAD_ASSERT_WAIT_MS) for a prompt record from this invocation. So a warning
# needs two independent misses, never one silent write failure; and a session idle past the
# schedule GC's 7-day retention (which deletes session-start/ and prompt/ records but never
# this hook's own tree) is rescued by its current prompt's record instead of by a copied
# retention constant. Costs a stall ONLY on the about-to-warn path; healthy sessions never
# reach it. The wait is a second chance, not the primary evidence: state 5's verdict is
# pinned to the earlier prompt, and the probe proves it without the same-prompt record.
#
# --- Residuals, stated so nobody mistakes them for coverage ---
#   * A single-prompt session born without SessionStart is never warned (no prompt 2).
#   * QW_CELL=1 or a non-empty agent_id: dhx-session-registry-prompt.sh writes NOTHING by
#     design, so in state 5 the witness cannot testify and this hook stays SILENT rather than
#     warn on every healthy such session (the prompt writer's own eligibility parity). The
#     shape is theoretical today: quota cells always start with SessionStart and subagents
#     fire no UserPromptSubmit. States 1-2 still apply to them.
#   * A --resume within 10 s of the previous invocation's last beat can inherit that beat
#     (BEAT_SKEW_MS, below).
#   * The converse, a false alarm on a LIVE channel: in state 5 a plugin whose prompt writer
#     fails on two consecutive prompts (disk full, a permissions fault) is warned about while
#     its guards still run. The warning text says "two independent misses, not proof" for
#     exactly this reason (close review, 2026-09-24).
#
# --- Digest chain must match the dispatcher's byte for byte ---
# `printf '%s'` (never echo -- the trailing newline would be hashed), sha256sum then shasum,
# cut -c1-16. Same chain as the dispatcher's _dhx_digest16. If neither tool exists, the
# dispatcher writes no beat AND this hook computes no key, so both sides fail together and
# this exits silent rather than crying wolf. That symmetry is deliberate.
#
# Kill switch: DHX_GUARD_LOAD_ASSERT=0.
# Fixture hooks (probe-only): DHX_HOOKS_CACHE_DIR, DHX_PLUGIN_MANIFEST,
#   DHX_GUARD_LOAD_ASSERT_WAIT_MS.

set -uo pipefail

[ "${DHX_GUARD_LOAD_ASSERT:-1}" = "0" ] && exit 0

INPUT=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# One jq call. A missing hook_event_name reads as UserPromptSubmit: that is the only event
# this hook was registered on before 2026-09-24, and a payload without the field must keep
# meaning what it always meant.
# Unit separator, NOT @tsv: TAB is IFS whitespace, so `read` collapses an EMPTY leading field
# and a payload without session_id would shift the event name into SID. \x1f is not
# whitespace, so every empty field survives in position.
FIELDS=$(jq -r '[(.session_id // ""), (.hook_event_name // "UserPromptSubmit"), (.agent_id // "")]
                | map(tostring | gsub("[\u001f\n]"; " ")) | join("\u001f")' \
           <<<"$INPUT" 2>/dev/null) || exit 0
IFS=$'\x1f' read -r SID EVENT AGENT <<<"$FIELDS"
[ -n "${SID:-}" ] || exit 0
[ "$SID" = "unknown" ] && exit 0

_digest16() {
  if command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum 2>/dev/null | cut -c1-16
  elif command -v shasum    >/dev/null 2>&1; then printf '%s' "$1" | shasum -a 256 2>/dev/null | cut -c1-16
  fi
}
KEY=$(_digest16 "$SID") || KEY=""
[ -n "$KEY" ] || exit 0

CACHE_ROOT="${DHX_HOOKS_CACHE_DIR:-$HOME/.cache/dhx/hooks}"
BEAT_DIR="$CACHE_ROOT/session-start/$KEY"
PROMPT_DIR="$CACHE_ROOT/prompt/$KEY"
STATE_ROOT="$CACHE_ROOT/guard-load-assert-state"
STATE_DIR="$STATE_ROOT/$KEY"

# Epoch ms, the same way the record writers name their files. BSD date prints %3N literally.
_now_ms() {
  local ms; ms=$(date +%s%3N 2>/dev/null)
  case "$ms" in ''|*[!0-9]*) ms="$(date +%s)000" ;; esac
  printf '%s' "$ms"
}

# Atomic stamp write: tmp + rename, the record writers' idiom. Content = epoch ms.
_stamp() { # $1 name
  mkdir -p "$STATE_DIR" 2>/dev/null || return 1
  printf '%s\n' "$(_now_ms)" > "$STATE_DIR/$1.tmp.$$" 2>/dev/null \
    && mv -f "$STATE_DIR/$1.tmp.$$" "$STATE_DIR/$1" 2>/dev/null && return 0
  rm -f "$STATE_DIR/$1.tmp.$$" 2>/dev/null
  return 1
}
_read_stamp() { # $1 name -> epoch ms, or empty
  local v=""
  [ -r "$STATE_DIR/$1" ] && read -r v < "$STATE_DIR/$1" 2>/dev/null
  case "$v" in ''|*[!0-9]*) v="" ;; esac
  printf '%s' "$v"
}

# Newest record in a leg directory, by the fired_ms the writers put in the file NAME:
# <event16|none>.<fired_ms>.<pid>.<nonce>.json. Pure bash -- no find, no stat -- so a missing
# directory is just an empty glob (the pipefail trap the 2026-09-20 version hit with
# `find | wc -l || echo 0` cannot arise). In-flight `.json.tmp.<pid>` files never match.
_newest_ms() { # $1 dir -> max fired_ms, 0 if none
  local f b ms max=0
  for f in "$1"/*.json; do
    [ -f "$f" ] || continue
    b=${f##*/}; b=${b#*.}; ms=${b%%.*}
    case "$ms" in ''|*[!0-9]*) continue ;; esac
    [ "$ms" -gt "$max" ] && max=$ms
  done
  printf '%s' "$max"
}

# ============================== SessionStart: birth stamp ==============================
if [ "$EVENT" = "SessionStart" ]; then
  _stamp birth || true
  # Prune state dirs untouched for 14 days. Pruning is safe in every direction: a resume
  # re-stamps birth, and a pruned born-without-SessionStart session re-enters state 4/5 with
  # the witness wait to rescue it. Directory mtime moves on every stamp (rename into it).
  # Name-pinned to a 16-char key so nothing else under the root can be reached.
  find "$STATE_ROOT" -mindepth 1 -maxdepth 1 -type d -name '????????????????' -mtime +14 \
    -exec rm -rf {} + 2>/dev/null || true
  exit 0
fi

# ============================== UserPromptSubmit: assert ===============================
# The prompt writer skips its record under these, so its silence is not evidence there.
WITNESS_OK=1
{ [ -n "${AGENT:-}" ] || [ "${QW_CELL:-}" = "1" ]; } && WITNESS_OK=0

WAIT_MS="${DHX_GUARD_LOAD_ASSERT_WAIT_MS:-2000}"
case "$WAIT_MS" in ''|*[!0-9]*) WAIT_MS=2000 ;; esac

# 0 when a prompt record at or after $1 (epoch ms) lands within WAIT_MS.
_witness_wait() {
  local floor=$1 waited=0
  [ "$WITNESS_OK" = "1" ] || return 1
  while :; do
    [ "$(_newest_ms "$PROMPT_DIR")" -ge "$floor" ] && return 0
    [ "$waited" -ge "$WAIT_MS" ] && return 1
    sleep 0.1 2>/dev/null || return 1
    waited=$((waited + 100))
  done
}

# The beat and the birth stamp come from ONE SessionStart event, written by two hooks running
# concurrently, so the beat may predate the stamp by that skew. 10 s is generous for hook
# start-up skew; overshooting it costs only a false alarm that the witness wait then absorbs.
BEAT_SKEW_MS=10000
BIRTH_MS=$(_read_stamp birth)
STATE=""

if [ -n "$BIRTH_MS" ]; then
  # --- SessionStart fired for this invocation (settings channel saw it): states 1-3 ---
  VERIFIED_MS=$(_read_stamp verified)
  # Fast path for every prompt after the first healthy one: two small reads.
  [ -n "$VERIFIED_MS" ] && [ "$VERIFIED_MS" -ge "$BIRTH_MS" ] && exit 0
  # Prompt records need no skew: every prompt of this invocation follows its SessionStart.
  if [ "$(_newest_ms "$BEAT_DIR")" -ge $((BIRTH_MS - BEAT_SKEW_MS)) ] \
     || [ "$(_newest_ms "$PROMPT_DIR")" -ge "$BIRTH_MS" ]; then
    _stamp verified || true
    exit 0
  fi
  if _witness_wait "$BIRTH_MS"; then _stamp verified || true; exit 0; fi
  STATE=sessionstart
  MARK="$BIRTH_MS"
else
  # --- No SessionStart seen for this id: states 4-5, or a session older than the birth
  # registration. Any record at all is the channel running for this id: nothing else can mint
  # a second invocation of it without a SessionStart that would have stamped birth. ---
  [ "$(_newest_ms "$BEAT_DIR")" -gt 0 ] && exit 0
  [ "$(_newest_ms "$PROMPT_DIR")" -gt 0 ] && exit 0
  [ "$WITNESS_OK" = "1" ] || exit 0
  if [ -z "$(_read_stamp pending)" ]; then
    # First prompt without a witness: undecidable (the 31 ms race). Defer to the next prompt.
    _stamp pending || true
    exit 0
  fi
  if _witness_wait 1; then exit 0; fi
  STATE=nosessionstart
  MARK=nosessionstart
fi

# --- Warn: once per invocation ---
# FIRST-SIGHT via mkdir, which is atomic test-and-set on every filesystem this runs on -- the
# same idiom the dispatcher uses for child-failure first-sight. Per INVOCATION (the leaf is the
# birth stamp), so a --resume that finds the plugin dead again speaks again; speaking on every
# prompt of a broken invocation would be noise, and noise is how a real warning gets ignored.
NOTICE_DIR="$CACHE_ROOT/guard-load-assert/$KEY"
mkdir -p "$NOTICE_DIR" 2>/dev/null || exit 0
mkdir "$NOTICE_DIR/$MARK" 2>/dev/null || exit 0

# Name the guards that are actually absent. "The plugin did not load" is a registry state;
# "dhx-key-read-guard.js and dhx-git-destructive-guard.sh are not running" is a consequence
# the operator can act on, and the brief this closes required the consequence.
MANIFEST="${DHX_PLUGIN_MANIFEST:-$HOME/repos/hooks/dhx-plugin/plugins/dhx/hooks/hooks.json}"
GUARDS=""
if [ -r "$MANIFEST" ]; then
  GUARDS=$(jq -r '
      [ .hooks.PreToolUse // [] | .[] | .hooks[]? | .command ]
      | map(sub("^.*/";"") | sub("\"$";""))
      | unique | join(", ")' "$MANIFEST" 2>/dev/null || true)
fi
[ -n "$GUARDS" ] || GUARDS="(manifest unreadable at $MANIFEST -- cannot enumerate; treat ALL dhx PreToolUse guards as absent)"

LIMIT="This is a channel-level assertion only; it does not speak to whether any individual guard's tool routing works."
FIX="Run '/reload-plugins' or restart, then 'bash ~/repos/hooks/scripts/verify-hooks.sh'."
if [ "$STATE" = "sessionstart" ]; then
  MSG="SECURITY: the dhx plugin did not load this session -- SessionStart fired, but no dhx plugin hook has left a record since. Its PreToolUse guards are not running. $FIX"
  CTX="The dhx plugin channel did not load for this session. SessionStart fired for it (the settings channel stamped it), yet the manifest's SessionStart dispatcher left no beat record under $BEAT_DIR -- writing one is its first action -- and the plugin's prompt hook wrote nothing under $PROMPT_DIR within ${WAIT_MS} ms of this prompt. Consequence: the following PreToolUse guards are NOT running, and tool calls they would normally refuse will now succeed silently -- $GUARDS. $LIMIT Treat destructive, credential-reading and outbound-write operations as UNGUARDED until a reload is confirmed. Warned once per session."
else
  MSG="SECURITY: the dhx plugin appears not to have loaded -- no dhx plugin hook has left any record for this session over two prompts. Treat its PreToolUse guards as absent. $FIX"
  CTX="The dhx plugin channel appears not to have loaded for this session. Claude Code fired no SessionStart for this session id (the shape of a fork, a resume-mint or a continuation), so there is no SessionStart evidence either way; but the plugin's prompt hook, which records every prompt under $PROMPT_DIR, wrote nothing for the previous prompt and nothing within ${WAIT_MS} ms of this one. That is two independent misses, not proof. Likely consequence: the following PreToolUse guards are not running, and tool calls they would normally refuse would succeed silently -- $GUARDS. $LIMIT Treat destructive, credential-reading and outbound-write operations as UNGUARDED until a reload is confirmed or a guarded command is seen refused. Warned once per session."
fi

if OUT=$(jq -cn --arg m "$MSG" --arg c "$CTX" \
      '{systemMessage:$m, hookSpecificOutput:{hookEventName:"UserPromptSubmit", additionalContext:$c}}' 2>/dev/null) \
   && printf '%s\n' "$OUT"; then
  exit 0
fi
# Structured emit failed -> still say something, on the operator channel.
echo "SECURITY: dhx plugin did not load this session; its PreToolUse guards are absent." >&2
exit 0
