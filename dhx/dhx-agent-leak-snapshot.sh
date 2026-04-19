#!/usr/bin/env bash
# dhx-agent-leak-snapshot.sh — PreToolUse hook (Agent matcher)
# Patterns: HP-009, HP-011
#
# Captures a baseline `git status --porcelain` of the main repo before a
# worktree-isolated agent dispatches. Paired with dhx-agent-leak-check.sh
# (PostToolUse:Agent) to detect silent writes leaked into the main repo by
# anthropics/claude-code #36182 (subagent Edit calls resolving to main-repo
# absolute paths instead of worktree-rooted ones).
#
# Only fires when tool_input.isolation == "worktree". Non-isolated agents
# write intentionally to the parent repo so a diff is expected, not a leak.
#
# Keying: session_id from stdin (HP-015 suggests it's available in hook
# contexts). Falls back to cwd-hash when session_id is absent — imperfect for
# parallel agents in the same session but catches the common case.
#
# Cost: one `git status` call (~20ms on warm FS) + one jq. Silent exit on all
# paths including error — hook is observational, must not impede dispatch.

set -euo pipefail

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then exit 0; fi

ISOLATION=$(jq -r '.tool_input.isolation // empty' <<<"$INPUT" 2>/dev/null)
[[ "$ISOLATION" == "worktree" ]] || exit 0

CWD=$(jq -r '.cwd // empty' <<<"$INPUT" 2>/dev/null)
[[ -n "$CWD" ]] || exit 0

# Must be a git worktree/repo — both .git-dir and .git-file forms are valid
[[ -d "$CWD/.git" || -f "$CWD/.git" ]] || exit 0

# Don't snapshot when dispatching FROM inside a worktree (parent is a subtree
# and main-repo state is the responsibility of the outer dispatch)
[[ "$CWD" == *".claude/worktrees/"* ]] && exit 0

SESSION=$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null)
if [[ -z "$SESSION" ]]; then
  SESSION=$(echo -n "$CWD" | sha256sum | cut -c1-16)
fi

CACHE="$HOME/.cache/dhx"
mkdir -p "$CACHE" 2>/dev/null || exit 0

# Capture baseline. On error (non-git dir, permission), exit silently.
git -C "$CWD" status --porcelain 2>/dev/null > "$CACHE/agent-leak-${SESSION}.pre" || {
  rm -f "$CACHE/agent-leak-${SESSION}.pre" 2>/dev/null
  exit 0
}

exit 0
