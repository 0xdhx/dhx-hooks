#!/usr/bin/env bash
# dhx-worktree-write-guard.sh — PreToolUse hook (Edit|Write|MultiEdit matcher)
# Patterns: HP-003, HP-007, HP-009
#
# Blocks Edit/Write/MultiEdit calls whose absolute file_path escapes the
# enclosing Claude Code managed worktree when cwd is inside one. Protects
# against the silent-write-to-main-repo class of issue anthropics/claude-code
# #36182.
#
# ════════════════════════════════════════════════════════════════════════════
# SCOPE (HP-003 reframe, 2026-04-21): fires for parent AND subagent writes.
# ════════════════════════════════════════════════════════════════════════════
# PreToolUse:Write and PreToolUse:Edit propagate from Agent subprocesses to
# parent-registered hooks — subagent tool calls carry `agent_id`/`agent_type`
# in stdin and the subagent's worktree as `cwd`. The subagent leak vector
# reported in #36182 (Edit calls inside an isolation="worktree" agent writing
# to main-repo absolute paths) is therefore CAUGHT by this hook for Write and
# Edit. MultiEdit propagation is still unverified (HP-003 table) — the
# matcher includes it, and if propagation extends the hook covers it too.
#
# Audit decision 2026-04-21: parent+subagent uniform enforcement — a subagent
# write that escapes its worktree is the same violation as a top-level one.
# Neither context gets a relaxation; the hook does NOT branch on agent_id.
#
# Companion hooks retain independent value:
#   dhx/dhx-agent-leak-snapshot.sh  (PreToolUse:Agent, HP-011) — snapshots
#   dhx/dhx-agent-leak-check.sh     (PostToolUse:Agent, HP-011) — diffs
#   dhx/dhx-worktree-bash-guard.sh  (PreToolUse:Bash) — shell-fallback vector
# They cover tool classes outside Write|Edit|MultiEdit (Bash shell fallback,
# cp/mv/rsync, etc.) that this hook's matcher cannot see.
#
# This hook catches:
#   - user's own top-level Edit/Write/MultiEdit with cwd inside a worktree
#   - inline Skill (e.g. gsd-fast) writes that escape the worktree
#   - subagent Edit/Write inside isolation="worktree" dispatches (#36182)
#   - subagent MultiEdit (if HP-003 propagation extends to that matcher)
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

# INVARIANT: fires for parent AND subagent Write|Edit calls (HP-003 verified
# 2026-04-21). Uniform enforcement intended — a subagent escape is the same
# violation as a top-level escape. Do NOT add an agent_id short-circuit.
# File outside worktree → BLOCK
echo "BLOCKED: file_path escapes worktree boundary (issue #36182)"
echo "  cwd:       $CWD"
echo "  file_path: $FILE"
echo "  worktree:  $WT_ROOT"
echo ""
echo "Use a worktree-rooted absolute path, or use a cwd-relative path."
exit 2
