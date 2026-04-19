#!/usr/bin/env bash
# dhx-worktree-write-guard.sh — PreToolUse hook (Edit|Write|MultiEdit matcher)
# Patterns: HP-003, HP-007, HP-009
#
# Blocks Edit/Write/MultiEdit calls whose absolute file_path escapes the
# enclosing Claude Code managed worktree when cwd is inside one. Protects
# against the silent-write-to-main-repo class of issue anthropics/claude-code
# #36182 at top-level and inline Skill contexts.
#
# ════════════════════════════════════════════════════════════════════════════
# SCOPE LIMITATION (HP-003): this hook does NOT fire inside Agent subprocesses.
# ════════════════════════════════════════════════════════════════════════════
# Agent + worktree isolation dispatches run in subprocesses where PreToolUse
# hooks registered in settings.json do not fire. The subagent leak vector
# reported in #36182 (where Edit calls inside an isolation="worktree" agent
# write to main-repo absolute paths) is unreachable from this hook class.
# Companion observational hook for the subagent vector:
#   dhx/dhx-agent-leak-snapshot.sh  (PreToolUse:Agent, HP-011)
#   dhx/dhx-agent-leak-check.sh     (PostToolUse:Agent, HP-011)
#
# This hook catches:
#   - user's own top-level Edit/Write with cwd inside a worktree
#   - inline Skill (e.g. gsd-fast) writes that escape the worktree
#
# Prior art: @yurukusa's 2026-03-30 comment on #36182 proposed a git rev-parse
# --git-dir / --git-common-dir based detection. This implementation uses cwd
# string-prefix matching instead — ~20× faster (3ms vs 60ms) and we only care
# about CC-managed worktrees under .claude/worktrees/.

set -euo pipefail

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then exit 0; fi

# Single jq pass — tab-separated cwd + file_path
IFS=$'\t' read -r CWD FILE < <(jq -r '[.cwd // "", .tool_input.file_path // ""] | @tsv' <<<"$INPUT" 2>/dev/null || echo $'\t')

# Fast exit: not in a CC-managed worktree
[[ "$CWD" == *".claude/worktrees/"* ]] || exit 0

# No file_path (some tool variants pass different shapes) — let through
[[ -n "$FILE" ]] || exit 0

# Only guard absolute paths. Relative paths resolve against cwd correctly
# by CC's path resolver — no leak vector there.
[[ "$FILE" == /* ]] || exit 0

# Derive worktree root: everything up through the agent-ID segment
WT_ROOT=$(echo "$CWD" | sed -E 's|(.*\.claude/worktrees/[^/]+).*|\1|')

# File inside worktree → OK
[[ "$FILE" == "$WT_ROOT"/* ]] && exit 0

# File outside worktree → BLOCK
echo "BLOCKED: file_path escapes worktree boundary (issue #36182)"
echo "  cwd:       $CWD"
echo "  file_path: $FILE"
echo "  worktree:  $WT_ROOT"
echo ""
echo "Use a worktree-rooted absolute path, or use a cwd-relative path."
exit 2
