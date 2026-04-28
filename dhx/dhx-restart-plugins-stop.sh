#!/usr/bin/env bash
# dhx-restart-plugins-stop.sh — Stop hook
# Patterns: HP-020 (Stop event reliability), HP-026 (marker semantics),
#           HP-027 (CLI slash commands bypass UserPromptSubmit),
#           HP-028 (SIGPIPE+pipefail breaks `cmd | grep -q` on overflow).
#
# When the user runs `/reload-plugins` or `/restart-plugins` (CLI slash
# commands), `UserPromptSubmit` does NOT fire (HP-027). `Stop` fires
# reliably at every turn-end. This hook scans the recent transcript for
# such an invocation and writes the rebaseline marker that the statusline
# wrapper consumes to clear the `⚠ restart plugins` drift warning.
#
# Marker path: ~/.cache/dhx/plugins-rebaseline-${session_id}.marker
# Consumer:   dhx/statusline-wrapper.js::checkDrift() (single-shot — deletes
#             the marker after read).
#
# Latency: warning clears at the next statusline refresh after the user's
# next turn ends — i.e., within 1 turn of /reload-plugins.
#
# Idempotent: re-firing the marker on subsequent Stops is harmless. The
# wrapper consumes + unlinks; the snapshot rebaselines to the live state
# on each refresh, which is a no-op once already in sync.
#
# Silent on happy path; exits 0 unconditionally so a parse / write failure
# never blocks the user's turn.
#
# IMPORTANT: the trigger detection must NOT use `tail | grep -q` directly
# under `set -o pipefail`. `grep -q` exits on first match → `tail` is killed
# with SIGPIPE → pipefail propagates non-zero → `if` evaluates false even
# when matches exist. Process substitution sidesteps the pipefail-watched
# pipeline (tail runs in a subshell whose exit code doesn't propagate).
# Probe scenario [12] regression-tests this for transcripts large enough
# to fill the pipe buffer before grep reaches a match.
set -euo pipefail

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then exit 0; fi

TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null || echo "")
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""' 2>/dev/null || echo "")

# Sanitize session_id — reject path separators / .. so a malicious id
# can't escape ~/.cache/dhx via the marker basename.
case "$SESSION_ID" in
  *[/\\]*|*..*) exit 0 ;;
  '') exit 0 ;;
esac

[[ -n "$TRANSCRIPT" && -r "$TRANSCRIPT" ]] || exit 0

# Scan last 50 transcript JSONL entries for a CLI slash invocation of
# /reload-plugins or /restart-plugins. CC records CLI slash commands as
# `<command-name>/X</command-name>` inside the user-message content (see
# HP-027 for the verification probe). Anchor on the exact tag form so
# unrelated mentions in tool results / prose don't false-match.
if grep -q '<command-name>/\(reload-plugins\|restart-plugins\)</command-name>' \
       <(tail -n 50 "$TRANSCRIPT" 2>/dev/null); then
  CACHE_DIR="${HOME}/.cache/dhx"
  mkdir -p "$CACHE_DIR" 2>/dev/null || exit 0
  MARKER="${CACHE_DIR}/plugins-rebaseline-${SESSION_ID}.marker"
  date +%s%3N > "$MARKER" 2>/dev/null || true
fi

exit 0
