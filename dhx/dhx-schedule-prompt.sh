#!/usr/bin/env bash
# dhx-schedule-prompt.sh — UserPromptSubmit delivery leg for /dhx:schedule.
# Patterns: HP-009 (advisory, exit 0), HP-046 (hookSpecificOutput.additionalContext),
#           HP-055 (systemMessage RENDERS to the operator on UserPromptSubmit)
#
# OUTPUT CONTRACT: EXACTLY ONE JSON object on stdout, or NOTHING. Every error path exits 0
# with no output. This shim holds NONE of that contract itself — the whole of it (the object
# shape, the per-session suppression, every error path, the length bound, both digests) lives
# in the cross-repo renderer this delegates to, which is the only reason those properties are
# testable at all. The shim's job is to be structurally unable to break a prompt.
#
# Standing caveat (from dhx/dhx-cold-return-gate.sh's own header): a probe can assert what a
# hook EMITS, never that Claude Code RENDERS it. That gap is not closable from this repository.
#
# Source-of-truth: ~/repos/hooks/dhx/dhx-schedule-prompt.sh
# Symlinked to:    ~/.claude/hooks/dhx-schedule-prompt.sh
set -uo pipefail

[ "${DHX_SKIP_SCHEDULE_PROMPT:-0}" = "1" ] && exit 0
# QW_CELL=1: a measured quota cell's client (qw-call.sh, 2026-09-23, N9 B R-B12). The due list
# changes when an item falls due (00:00 local, mid-cell), which would move the cached prefix;
# dhx-session-registry-prompt.sh skips its reference beat on the same term (eligibility parity).
[ "${QW_CELL:-}" = "1" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

# KEEP THE RAW BYTES. The event digest is computed over exactly what arrived; re-serialising
# or normalising the payload before hashing would make this leg's digest disagree with the
# reference leg's on every event, and the liveness comparison would then report this leg dead
# in every session. `$(cat)` strips trailing newlines — that IS the canonicalisation step, and
# the Node side strips identically.
INPUT=$(cat)
[ -n "$INPUT" ] || exit 0

# One parse for all three fields, NUL-framed. NOT `@tsv` + `IFS=$'\t' read`: TAB is IFS
# whitespace, so an EMPTY transcript_path collapsed and agent_id shifted into TRANSCRIPT —
# a subagent payload then read as a main session (docs/decisions.md 2026-09-25 row). The
# earlier "cannot contain a newline, so @tsv is safe" reasoning covered only @tsv's escaping
# half. A field carrying NUL makes jq error; a failed parse exits, as it always did.
{ IFS= read -r -d '' SESSION_ID; IFS= read -r -d '' TRANSCRIPT; IFS= read -r -d '' AGENT_ID; } < <(printf '%s' "$INPUT" | jq -j '
  def f: (. // "") | tostring | if (explode | index(0)) != null then error("NUL in field") else . end;
  (.session_id | f), "\u0000", (.transcript_path | f), "\u0000", (.agent_id | f), "\u0000"' 2>/dev/null) || exit 0

# Defense in depth: subagents fire no UserPromptSubmit. Never slow a subagent turn.
# NOTE — THIS GUARD IS HALF OF THE ELIGIBILITY SYMMETRY RULE. Read it before changing:
# a reference beat with no counterpart here reads as a DEAD LEG. The reference beat lives
# in dhx/dhx-session-registry-prompt.sh; see the block marked "/dhx:schedule liveness
# reference beat" there.
[ -n "${AGENT_ID:-}" ] && exit 0
[ -n "${SESSION_ID:-}" ] || exit 0

# The cache-root override is what lets the probe drive this from a fixture instead of the
# live cache. Same shape as dhx-cold-return-gate.sh's DHX_COLD_RETURN_CACHE_DIR.
CACHE_DIR="${DHX_SCHEDULE_CACHE_DIR:-$HOME/.cache/dhx/schedule}"
export DHX_SCHEDULE_CACHE_DIR="$CACHE_DIR"

# The shared event digest. printf '%s', never echo: echo appends a newline and the hasher
# hashes it, and the two legs would then silently disagree forever. This shim computes no
# session key of its own (the renderer derives that in Node from --session-id), so the event
# digest is its only chain consumer.
# Digest chain: sha256sum, then shasum -a 256 (macOS) — the dhx/poll-guard.sh SESSION_HASH
# precedent. Inlined (no sourced lib) so this file stays a single self-contained unit. Neither
# tool present -> empty, and the renderer records the pre-forwarding floor, as before.
_dhx_digest16() {
  if command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum 2>/dev/null | cut -c1-16
  elif command -v shasum >/dev/null 2>&1; then printf '%s' "$1" | shasum -a 256 2>/dev/null | cut -c1-16
  fi
}
EVENT_HASH=$(_dhx_digest16 "$INPUT") || EVENT_HASH=""

# Graceful no-op when the cross-repo installer has not provisioned the symlink yet. Without
# this the hook would emit a node error into the model's context on every prompt.
RENDERER="${DHX_SCHEDULE_RENDERER:-$HOME/.claude/dhx-tools/dhx-schedule-render.cjs}"
[ -e "$RENDERER" ] || exit 0
command -v node >/dev/null 2>&1 || exit 0

# Pass the renderer's stdout through UNMODIFIED and swallow its stderr. Anything added here —
# a newline, a prefix, a second line — would be injected into the model's context on every
# single prompt.
node "$RENDERER" prompt --session-id "$SESSION_ID" --event-hash "$EVENT_HASH" 2>/dev/null </dev/null || true
exit 0
