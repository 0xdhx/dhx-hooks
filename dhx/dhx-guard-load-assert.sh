#!/usr/bin/env bash
# dhx-guard-load-assert.sh — UserPromptSubmit, CROSS-CHANNEL plugin-load assertion.
# Patterns: HP-046 (hookSpecificOutput.additionalContext reaches the model),
#           HP-055 (systemMessage RENDERS to the operator on UserPromptSubmit),
#           HP-012 (settings.json registration DOES hot-reload, at user scope),
#           HP-020 (the PLUGIN MANIFEST does not passively hot-reload)
#
# ONE WARNING, once per session, when the dhx plugin's SessionStart dispatcher did not run
# for this session -- which means the plugin channel did not load, which means every dhx
# PreToolUse guard is absent from the running process. Never blocks. Silent on the happy path.
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
#
# --- What it observes, and why that is evidence ---
# The manifest's SessionStart dispatcher writes a /dhx:schedule reference beat as the FIRST
# thing it does: one record under <cache>/session-start/<sha256-16 of session id>/. That
# record existing for THIS session is proof the manifest channel loaded and CC actually
# routed an event into it. Disk state is not proof of that and never was -- correct
# symlinks, a correct manifest and a green scripts/verify-hooks.sh are all compatible with
# a registry CC quietly declined (precedent: CC 2.1.272 silently rejected the marketplace
# heal's output while every jq-level check read green).
#
# --- What it does NOT prove (stated here so nobody reads it as more than it is) ---
# The beat proves the CHANNEL loaded. It does not prove CC routes PreToolUse to each
# individual guard, and no SessionStart-time signal can: routing is per-event and per-
# matcher. A guard that is registered, present and never invoked looks identical from here.
# Only firing a guard and observing the refusal proves that, which is a behavioural probe's
# job, not this hook's. NECESSARY, NOT SUFFICIENT -- do not let a green assertion here
# retire a behavioural check.
#
# --- Three disk-identical states, and why only one of them warns ---
#   1. loaded             -> beat present  -> SILENT.
#   2. registry rejected  -> beat absent   -> WARN. The guards are genuinely not in the
#                                             running process.
#   3. manifest edited mid-session -> beat PRESENT -> SILENT. HP-020: registration does not
#      hot-reload, so a hook added to the manifest just now legitimately will not fire until
#      a reload -- but the dispatcher already ran at SessionStart and its beat is already on
#      disk. Keying on the beat rather than on manifest freshness is what keeps this hook
#      quiet through every hook-development session in this repo, which is the failure mode
#      that would get it disabled within a day.
#
# --- Digest chain must match the dispatcher's byte for byte ---
# `printf '%s'` (never echo -- the trailing newline would be hashed), sha256sum then shasum,
# cut -c1-16. Same chain as the dispatcher's _dhx_digest16. If neither tool exists, the
# dispatcher writes no beat AND this hook computes no key, so both sides fail together and
# this exits silent rather than crying wolf. That symmetry is deliberate.
#
# Kill switch: DHX_GUARD_LOAD_ASSERT=0.
# Fixture hooks (probe-only): DHX_HOOKS_CACHE_DIR, DHX_PLUGIN_MANIFEST.

set -uo pipefail

[ "${DHX_GUARD_LOAD_ASSERT:-1}" = "0" ] && exit 0

INPUT=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || exit 0

SID=$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null || true)
[ -n "$SID" ] || exit 0
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

# Any record at all is the signal. `find -name '*.json'` rather than a glob so an empty
# directory is an empty result instead of a literal unmatched pattern.
# The -d test is not redundant with find's own failure: `set -o pipefail` is on, so a find
# that errors on a missing directory poisons the pipeline's status, and a `|| echo 0`
# fallback then APPENDS to wc's output instead of replacing it -- yielding the two-line
# value "0\n0", which `[ -gt ]` rejects with "integer expression expected" on stderr.
# Measured while smoke-testing this file, not theorised. Guard the directory, not the pipe.
BEAT_COUNT=0
if [ -d "$BEAT_DIR" ]; then
  BEAT_COUNT=$(find "$BEAT_DIR" -maxdepth 1 -name '*.json' -type f 2>/dev/null | wc -l)
fi
case "$BEAT_COUNT" in ''|*[!0-9]*) BEAT_COUNT=0 ;; esac
[ "$BEAT_COUNT" -gt 0 ] && exit 0

# --- Beat absent: the manifest channel did not run for this session ---
# FIRST-SIGHT via mkdir, which is atomic test-and-set on every filesystem this runs on --
# the same idiom the dispatcher uses for child-failure first-sight. Speaking on every prompt
# of a broken session would be noise, and noise is how a real warning gets ignored.
NOTICE_DIR="$CACHE_ROOT/guard-load-assert/$KEY"
mkdir -p "$(dirname "$NOTICE_DIR")" 2>/dev/null || exit 0
mkdir "$NOTICE_DIR" 2>/dev/null || exit 0

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

MSG="SECURITY: the dhx plugin did not load this session -- its SessionStart dispatcher left no beat record. Every dhx PreToolUse guard is absent from this process. Run '/reload-plugins' or restart, then 'bash ~/repos/hooks/scripts/verify-hooks.sh'."
CTX="The dhx plugin channel did not load for this session: no SessionStart beat record exists under $BEAT_DIR, and that record is written as the first action of the manifest's SessionStart dispatcher. Consequence: the following PreToolUse guards are NOT running, and tool calls they would normally refuse will now succeed silently -- $GUARDS. This is a channel-level assertion only; it does not speak to whether any individual guard's tool routing works. Treat destructive, credential-reading and outbound-write operations as UNGUARDED until a reload is confirmed. Warned once per session."

if OUT=$(jq -cn --arg m "$MSG" --arg c "$CTX" \
      '{systemMessage:$m, hookSpecificOutput:{hookEventName:"UserPromptSubmit", additionalContext:$c}}' 2>/dev/null) \
   && printf '%s\n' "$OUT"; then
  exit 0
fi
# Structured emit failed -> still say something, on the operator channel.
echo "SECURITY: dhx plugin did not load this session; its PreToolUse guards are absent." >&2
exit 0
