#!/usr/bin/env bash
# dhx-dirty-tree.sh — SessionStart hook
# Patterns: HP-009
# Reports uncommitted changes at session start. Read-only, non-blocking.
# Fires once per session. Silent on clean trees.
#
# Suppression: DHX_SKIP_DIRTY_CHECK=1

set -uo pipefail

# Parse cwd from stdin (graceful — degrades to env var / pwd)
INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
if [ -z "$CWD" ]; then
  CWD="${CLAUDE_PROJECT_DIR:-.}"
fi

# Must be a git repo
if ! git -C "$CWD" rev-parse --is-inside-work-tree &>/dev/null; then
  exit 0
fi

# Suppression via env var
if [ "${DHX_SKIP_DIRTY_CHECK:-}" = "1" ]; then
  exit 0
fi

# Count changes
STATUS=$(git -C "$CWD" status --porcelain 2>/dev/null)
if [ -z "$STATUS" ]; then
  exit 0
fi

TOTAL=$(echo "$STATUS" | wc -l | tr -d ' ')
UNTRACKED=$(echo "$STATUS" | grep -c '^??' || true)
MODIFIED=$((TOTAL - UNTRACKED))

echo "Working tree has $TOTAL uncommitted changes ($MODIFIED modified, $UNTRACKED untracked)"
exit 0
