#!/usr/bin/env bash
# probe-worktree-write-guard.sh
#
# Regression probe for dhx/dhx-worktree-write-guard.sh.
#
# Invariant: PreToolUse:Edit|Write|MultiEdit blocks (exit 2) when
#   (a) cwd is inside a Claude Code managed worktree (.claude/worktrees/),
#   (b) tool_input.file_path is absolute, and
#   (c) file_path is outside the enclosing worktree prefix.
# All other paths exit 0 (allow).
#
# Backs: docs/decisions.md 2026-04-19 worktree-write-guard row.
# Companion: probe-agent-leak-check.sh covers the subagent-side detector.
#
# Run: bash tests/probes/probe-worktree-write-guard.sh

set -uo pipefail

HOOK="$(cd "$(dirname "$0")/../.." && pwd)/dhx/dhx-worktree-write-guard.sh"

if [[ ! -x "$HOOK" ]]; then
  echo "FAIL hook not found or not executable: $HOOK"
  exit 1
fi

PASS=0
FAIL=0

run() {
  local name="$1" input="$2" expect_code="$3"
  local code=0
  echo "$input" | "$HOOK" >/dev/null 2>&1 || code=$?
  if [[ "$code" == "$expect_code" ]]; then
    echo "OK   $name (exit=$code)"
    PASS=$((PASS+1))
  else
    echo "FAIL $name (exit=$code, expected=$expect_code)"
    FAIL=$((FAIL+1))
  fi
}

# --- Scenarios ---

# [1] Not in any worktree → allow
run "[1] cwd=main-repo, file=main-repo → allow" \
  '{"cwd":"/home/dhx/repos/hooks","tool_input":{"file_path":"/home/dhx/repos/hooks/dhx/x.sh"}}' \
  0

# [2] In worktree, file inside same worktree → allow
run "[2] cwd=worktree, file=worktree → allow" \
  '{"cwd":"/home/dhx/repos/hooks/.claude/worktrees/agent-aaa","tool_input":{"file_path":"/home/dhx/repos/hooks/.claude/worktrees/agent-aaa/dhx/x.sh"}}' \
  0

# [3] In worktree, file in main repo → BLOCK (primary leak signature)
run "[3] cwd=worktree, file=main-repo → BLOCK" \
  '{"cwd":"/home/dhx/repos/hooks/.claude/worktrees/agent-aaa","tool_input":{"file_path":"/home/dhx/repos/hooks/dhx/x.sh"}}' \
  2

# [4] In worktree, relative file_path → allow (CC resolves against cwd)
run "[4] cwd=worktree, file=relative → allow" \
  '{"cwd":"/home/dhx/repos/hooks/.claude/worktrees/agent-aaa","tool_input":{"file_path":"dhx/x.sh"}}' \
  0

# [5] cwd is worktree subdir, file is in worktree's docs dir → allow
run "[5] cwd=worktree/subdir, file=worktree root → allow" \
  '{"cwd":"/home/dhx/repos/hooks/.claude/worktrees/agent-aaa/dhx","tool_input":{"file_path":"/home/dhx/repos/hooks/.claude/worktrees/agent-aaa/docs/x.md"}}' \
  0

# [6] Two different worktrees → BLOCK (cross-worktree write)
run "[6] cwd=worktree-A, file=worktree-B → BLOCK" \
  '{"cwd":"/home/dhx/repos/hooks/.claude/worktrees/agent-aaa","tool_input":{"file_path":"/home/dhx/repos/hooks/.claude/worktrees/agent-bbb/x.md"}}' \
  2

# [7] Malformed JSON → allow (defensive, never crash)
run "[7] malformed JSON → allow" \
  'not valid json' \
  0

# [8] Missing file_path key → allow
run "[8] missing file_path → allow" \
  '{"cwd":"/home/dhx/repos/hooks/.claude/worktrees/agent-aaa","tool_input":{}}' \
  0

# [9] Empty cwd → allow
run "[9] empty cwd → allow" \
  '{"cwd":"","tool_input":{"file_path":"/anywhere/x.sh"}}' \
  0

# [10] Writing to /tmp from worktree → BLOCK (out-of-tree, probably unintentional)
run "[10] cwd=worktree, file=/tmp → BLOCK" \
  '{"cwd":"/home/dhx/repos/hooks/.claude/worktrees/agent-aaa","tool_input":{"file_path":"/tmp/scratch.txt"}}' \
  2

# [11] Nested worktree directory with trailing slash variation
run "[11] cwd=worktree no trailing slash, file=worktree nested → allow" \
  '{"cwd":"/home/dhx/repos/hooks/.claude/worktrees/agent-aaa","tool_input":{"file_path":"/home/dhx/repos/hooks/.claude/worktrees/agent-aaa/deep/nested/file.md"}}' \
  0

echo ""
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
