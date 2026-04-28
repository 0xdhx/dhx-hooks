#!/usr/bin/env bash
# dhx-restart-plugins-marker.sh — UserPromptSubmit hook
# Patterns: HP-008
# Writes a marker file when the user runs /restart-plugins or
# /reload-plugins so the statusline drift detector can rebaseline its
# plugins-tree snapshot on the next refresh — clearing the stale
# `⚠ restart plugins` warning without requiring a session restart.
#
# Marker path: ~/.cache/dhx/plugins-rebaseline-${session_id}.marker
# Consumer: dhx/statusline-wrapper.js::checkDrift() (single-shot — deletes
# after read).
#
# Silent on happy path; exits 0 unconditionally so a parse / write failure
# never blocks the user's prompt.
set -euo pipefail

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then exit 0; fi

PROMPT=$(echo "$INPUT" | jq -r '.prompt // ""' 2>/dev/null || echo "")
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""' 2>/dev/null || echo "")

# Sanitize session_id — reject path separators / .. so a malicious id
# can't escape ~/.cache/dhx via the marker basename.
case "$SESSION_ID" in
  *[/\\]*|*..*) exit 0 ;;
  '') exit 0 ;;
esac

# Match /restart-plugins or /reload-plugins anchored at ^ with a word
# boundary — `/restart-plugins-foo` and quoted occurrences in prose
# don't trigger.
if [[ "$PROMPT" =~ ^/(restart-plugins|reload-plugins)([[:space:]]|$) ]]; then
  CACHE_DIR="${HOME}/.cache/dhx"
  mkdir -p "$CACHE_DIR" 2>/dev/null || exit 0
  MARKER="${CACHE_DIR}/plugins-rebaseline-${SESSION_ID}.marker"
  date +%s%3N > "$MARKER" 2>/dev/null || true
fi

exit 0
