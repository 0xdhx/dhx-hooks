#!/usr/bin/env bash
# dhx-main-branch-warning.sh — UserPromptSubmit hook
# Patterns: HP-008
# Warns once per boot when user is working directly on main/master.
# Debounced via /tmp marker keyed to repo path. Non-blocking (exit 0).

# Not a git repo — silent
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

# Not on main/master — silent
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
case "$BRANCH" in
  main|master) ;;
  *) exit 0 ;;
esac

# Debounce: one warning per repo per boot
MARKER="/tmp/dhx-main-warn-$(echo "$REPO_ROOT" | md5sum | cut -d' ' -f1)"
if [ -f "$MARKER" ]; then exit 0; fi
touch "$MARKER"

cat << 'ENDJSON'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "You are on the main branch. Consider switching to a dev branch:\n  git checkout -b dev   (or: git checkout dev)\nWorking directly on main increases worktree divergence risk."
  }
}
ENDJSON
