#!/usr/bin/env bash
# dhx-agent-leak-check.sh — PostToolUse hook (Agent matcher)
# Patterns: HP-009, HP-011
#
# Compares current main-repo `git status --porcelain` against the pre-dispatch
# baseline captured by dhx-agent-leak-snapshot.sh. Warns when new entries
# appear — the signature of anthropics/claude-code #36182 (subagent Edit/Write
# calls leaking to main-repo absolute paths despite isolation="worktree").
#
# Advisory only — PostToolUse cannot undo writes already on disk. The value
# is surfacing the leak before the user proceeds and compounds the corrupted
# state. Output goes to stdout (Claude sees) so the next assistant turn can
# propose the recovery sequence automatically.
#
# Silent on happy path. No baseline → silent (paired snapshot hook didn't fire
# for this agent, e.g. isolation != worktree, git missing, or race).
#
# Cost: one `git status` (~20ms) + one diff + one jq. Tens of tokens on
# violation; zero on clean. Fires at most once per Agent dispatch.

set -euo pipefail

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then exit 0; fi

ISOLATION=$(jq -r '.tool_input.isolation // empty' <<<"$INPUT" 2>/dev/null)
[[ "$ISOLATION" == "worktree" ]] || exit 0

CWD=$(jq -r '.cwd // empty' <<<"$INPUT" 2>/dev/null)
[[ -n "$CWD" ]] || exit 0
[[ -d "$CWD/.git" || -f "$CWD/.git" ]] || exit 0

SESSION=$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null)
if [[ -z "$SESSION" ]]; then
  SESSION=$(echo -n "$CWD" | sha256sum | cut -c1-16)
fi

CACHE="$HOME/.cache/dhx"
PRE="$CACHE/agent-leak-${SESSION}.pre"
[[ -f "$PRE" ]] || exit 0

POST_STATUS=$(git -C "$CWD" status --porcelain 2>/dev/null || echo "")
PRE_STATUS=$(cat "$PRE")

# Always clean up baseline, even when no diff
rm -f "$PRE"

# New entries in POST not in PRE = suspect leaks. `diff` exits non-zero on
# differences (expected path); `grep` exits non-zero on no match (also valid).
# Both interact badly with set -euo pipefail, so swallow the pipeline's exit.
NEW=$(diff <(echo "$PRE_STATUS") <(echo "$POST_STATUS") 2>/dev/null | grep '^>' | sed 's/^> //' | head -15 || true)

[[ -z "$NEW" ]] && exit 0

SUBAGENT=$(jq -r '.tool_input.subagent_type // "unknown"' <<<"$INPUT" 2>/dev/null)

cat <<WARNING
⚠ WORKTREE LEAK SUSPECTED — main repo modified while subagent (${SUBAGENT}) with isolation=worktree ran.

New entries in main repo working tree (not present before dispatch):
${NEW}

Known Claude Code bug: https://github.com/anthropics/claude-code/issues/36182
Edit/Write calls inside the subagent can resolve to main-repo absolute paths
instead of worktree-rooted ones, silently leaking writes.

If unexpected, recover before proceeding:
  git stash push -u -m "leak-\$(date -Iseconds)"
  git merge worktree-agent-<id> --no-ff
  # verify with probes / tests, drop stash after

If expected (agent intentionally wrote to shared state), no action needed.
WARNING

exit 0
