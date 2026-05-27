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

# D-4 (Phase 14): suppress the on-main nudge for cross-repo's main-pinned PRIMARY.
# The general nudge ("switch off main") would advise the very anti-pattern v1.4
# prevents. Scope: PRIMARY only (worktrees + other repos still get the nudge).
REPO_ROOT_REAL=$(realpath "$REPO_ROOT" 2>/dev/null) || REPO_ROOT_REAL=""
PRIMARY_REAL=$(realpath "$HOME/repos/cross-repo" 2>/dev/null) || PRIMARY_REAL=""
if [[ -n "$REPO_ROOT_REAL" && "$REPO_ROOT_REAL" == "$PRIMARY_REAL" ]]; then
    exit 0
fi

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
