#!/usr/bin/env bash
# dhx-worktree-bash-guard.sh — PreToolUse hook (Bash matcher)
# Patterns: HP-003, HP-007, HP-009
#
# Companion to dhx-worktree-write-guard.sh. Blocks Bash tool calls that write
# to main-repo absolute paths when cwd is inside a CC-managed worktree —
# closes the shell-fallback channel of anthropics/claude-code #36182 (third
# incident class, 2026-04-19 — gh#36182 worktree-leak).
#
# The write-guard only covers Edit|Write|MultiEdit. When CC's read-before-edit
# enforcement rejects an Edit, agents fall back to `sed -i`, `tee`, `>`, etc.,
# which route through the Bash tool and bypass the write-guard entirely.
#
# ════════════════════════════════════════════════════════════════════════════
# SCOPE LIMITATION (HP-003): does NOT fire inside Agent subprocesses.
# ════════════════════════════════════════════════════════════════════════════
# Same HP-003 constraint as the write-guard. This hook catches:
#   - user's own top-level Bash writes from a worktree cwd
#   - inline Skill (e.g. gsd-fast) Bash writes that escape the worktree
# For the Agent-subprocess variant, see dhx-agent-leak-{snapshot,check}.sh.
#
# DETECTION SCOPE (deliberately narrow to avoid blocking legit reads):
#   sed -i | tee | > | >> | printf ... > | python3? -c | dd ... of= | install
# Known gaps (acceptable v1 false-negatives, widen on field-observed leaks):
#   - cp / mv / rsync with main-repo destination (too many legit uses)
#   - heredoc redirects tokenized across shell expansion
#   - node/ruby/perl -e with fs.writeFile / File.write / open(w)
# The resolver-level fix upstream is the proper solution; this is a band-aid.

set -euo pipefail

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then exit 0; fi

IFS=$'\t' read -r CWD CMD < <(jq -r '[.cwd // "", .tool_input.command // ""] | @tsv' <<<"$INPUT" 2>/dev/null || echo $'\t')

# Fast exit: not in a CC-managed worktree
[[ "$CWD" == *".claude/worktrees/"* ]] || exit 0

# Empty command — nothing to inspect
[[ -n "$CMD" ]] || exit 0

# Derive worktree root: everything up through the agent-ID segment
WT_ROOT=$(echo "$CWD" | sed -E 's|(.*\.claude/worktrees/[^/]+).*|\1|')

# Derive main-repo root: strip the trailing .claude/worktrees/<id> (3 levels up)
# <main>/.claude/worktrees/<id>  →  <main>
MAIN_ROOT=$(dirname "$(dirname "$(dirname "$WT_ROOT")")")

# --- Detect write-verb ---
# Grep is line-unfriendly for shell pipelines but fine here — CMD is a single
# command string. Anchored token matches to cut false positives (e.g., `sed`
# without `-i` is a read operation, so we require the `-i`).
HAS_WRITE_VERB=0
if echo "$CMD" | grep -qE '(^|[^[:alnum:]_])sed[[:space:]]+(-[[:alnum:]]*i|[^-][^[:space:]]*[[:space:]]+-[[:alnum:]]*i)'; then
  HAS_WRITE_VERB=1
elif echo "$CMD" | grep -qE '(^|[^[:alnum:]_])(tee|dd|install)[[:space:]]'; then
  HAS_WRITE_VERB=1
elif echo "$CMD" | grep -qE '[[:space:]]>>?[[:space:]]*[^[:space:]|&;]'; then
  # > or >> redirection targeting a path (not >| process sub or >& fd)
  HAS_WRITE_VERB=1
elif echo "$CMD" | grep -qE '(^|[^[:alnum:]_])python3?[[:space:]]+-c'; then
  HAS_WRITE_VERB=1
fi

[[ "$HAS_WRITE_VERB" == "1" ]] || exit 0

# --- Is a main-repo absolute path referenced? ---
# Escape MAIN_ROOT for regex use (dots, slashes — use fixed-string grep instead)
if ! echo "$CMD" | grep -qF "$MAIN_ROOT/"; then
  exit 0
fi

# --- Is that path actually inside the worktree (subpath of MAIN_ROOT but
#     under WT_ROOT)? If yes, allow — worktree paths are legit targets. ---
# Heuristic: if every occurrence of MAIN_ROOT/ in the command is immediately
# followed by ".claude/worktrees/", it's a worktree reference.
# Count main-root hits that DON'T continue into .claude/worktrees/.
NON_WT_HITS=$(echo "$CMD" \
  | grep -oE "$(printf '%s\n' "$MAIN_ROOT/" | sed 's|[.[\*^$/]|\\&|g')[^[:space:]\"\x27]*" \
  | grep -vcE "\.claude/worktrees/" || true)

[[ "$NON_WT_HITS" -gt 0 ]] || exit 0

echo "BLOCKED: Bash write-verb targets main-repo path from worktree cwd (issue #36182 shell variant)"
echo "  cwd:         $CWD"
echo "  worktree:    $WT_ROOT"
echo "  main-root:   $MAIN_ROOT"
echo "  command:     $CMD"
echo ""
echo "Use a worktree-rooted path, or cd into the target repo explicitly."
exit 2
