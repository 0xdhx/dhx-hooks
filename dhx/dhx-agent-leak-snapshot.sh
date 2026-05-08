#!/usr/bin/env bash
# dhx-agent-leak-snapshot.sh — PreToolUse hook (Agent matcher)
# Patterns: HP-009, HP-011, HP-021
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

# D-03 timestamp keying + D-02 sidecar schema + D-04(c) both-or-none atomicity.
# WR-01: TIMESTAMP_NS (nanosecond from `date +%s%N`) is the CANONICAL FIFO KEY
# consumed by check.sh. The schema's `dispatched_at` field (second resolution)
# is presentation-only metadata for forensics — it ties on bursts within the
# same wall-clock second and must NOT be used as the FIFO ordering key.
# Do NOT drop the ns suffix from the filename; check.sh's fifo_key() helper
# parses it directly via parameter expansion.
TIMESTAMP_NS=$(date +%s%N)
PRE="$CACHE/agent-leak-${SESSION}-${TIMESTAMP_NS}.pre"
META="$CACHE/agent-leak-${SESSION}-${TIMESTAMP_NS}.meta.json"
META_TMP="${META}.tmp"

# Write baseline FIRST. On error, exit 0 silently (preserve current behavior).
git -C "$CWD" status --porcelain 2>/dev/null > "$PRE" || {
  rm -f "$PRE" 2>/dev/null
  exit 0
}

# Read subagent_type for sidecar payload (still available at PreToolUse:Agent).
SUBAGENT_TYPE=$(jq -r '.tool_input.subagent_type // empty' <<<"$INPUT" 2>/dev/null)

# Write sidecar SECOND via .tmp + mv. On any failure, roll back baseline (both-or-none).
if jq -n \
    --arg cwd "$CWD" \
    --arg iso "$ISOLATION" \
    --arg sa "$SUBAGENT_TYPE" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema_version: 1, cwd: $cwd, isolation: $iso, subagent_type: $sa, dispatched_at: $ts}' \
    > "$META_TMP" 2>/dev/null && mv "$META_TMP" "$META" 2>/dev/null; then
  : # success — both files in place
else
  rm -f "$PRE" "$META_TMP" "$META" 2>/dev/null
fi
exit 0
