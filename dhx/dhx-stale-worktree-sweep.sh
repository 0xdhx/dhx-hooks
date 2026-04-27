#!/usr/bin/env bash
# dhx-stale-worktree-sweep.sh — SessionStart hook
# Patterns: HP-009, HP-015
# Scans .git/worktrees/*/locked in the current repo. Removes a locked worktree
# only if ALL three safety gates pass:
#   (1) locked-file PID is not alive (kill -0 fails)
#   (2) working tree has no uncommitted/untracked changes (git status --porcelain empty)
#   (3) worktree's branch HEAD is ancestor of dev, main, or master
# If any gate fails, emits a one-line warning with the reason and skips. Never
# silent data loss — worst case is a noisy warning that resolves on next session.
#
# Context: anthropics/claude-code#36182 plus observed CC behavior where the
# 'locked' file keeps the outer session's PID, so `git worktree remove --force`
# refuses removal until either unlock or session exit. Stale locked worktrees
# then accumulate on disk indefinitely (gh#36182 worktree-leak class).
#
# Suppression: DHX_SKIP_STALE_WORKTREE_SWEEP=1

set -uo pipefail

INPUT=$(cat)

# Suppression
if [ "${DHX_SKIP_STALE_WORKTREE_SWEEP:-}" = "1" ]; then
  exit 0
fi

CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
if [ -z "$CWD" ]; then
  CWD="${CLAUDE_PROJECT_DIR:-$PWD}"
fi

# Must be a git repo
if ! git -C "$CWD" rev-parse --is-inside-work-tree &>/dev/null; then
  exit 0
fi

# Find git common dir (where .git/worktrees lives); may be relative
COMMON_DIR=$(git -C "$CWD" rev-parse --git-common-dir 2>/dev/null)
[ -z "$COMMON_DIR" ] && exit 0
case "$COMMON_DIR" in
  /*) ;;
  *) COMMON_DIR="$CWD/$COMMON_DIR" ;;
esac

WORKTREES_DIR="$COMMON_DIR/worktrees"
[ -d "$WORKTREES_DIR" ] || exit 0

shopt -s nullglob
WT_METAS=("$WORKTREES_DIR"/*/)
shopt -u nullglob
[ "${#WT_METAS[@]}" -eq 0 ] && exit 0

SWEPT=0
SKIPPED=0
SKIP_REASONS=()

for WT_META in "${WT_METAS[@]}"; do
  WT_NAME=$(basename "$WT_META")
  LOCK_FILE="$WT_META/locked"
  GITDIR_FILE="$WT_META/gitdir"

  # Only act on LOCKED worktrees — unlocked orphans are handled by `git worktree prune`
  [ -f "$LOCK_FILE" ] || continue

  # Resolve the working-tree path via the gitdir file (content: path to <worktree>/.git)
  if [ ! -f "$GITDIR_FILE" ]; then
    SKIPPED=$((SKIPPED + 1))
    SKIP_REASONS+=("$WT_NAME: no gitdir metadata file")
    continue
  fi
  WT_GITDIR=$(cat "$GITDIR_FILE" 2>/dev/null)
  WT_PATH="${WT_GITDIR%/.git}"

  # --- Gate 1: locked-file PID is not alive ---
  LOCK_CONTENT=$(cat "$LOCK_FILE" 2>/dev/null)
  LOCK_PID=$(echo "$LOCK_CONTENT" | grep -oE 'pid [0-9]+' | grep -oE '[0-9]+' | head -1)
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    # PID alive — respect the lock, silent skip (not stale)
    continue
  fi
  # If no parseable PID, we can't determine liveness → skip (safe default)
  if [ -z "$LOCK_PID" ]; then
    SKIPPED=$((SKIPPED + 1))
    SKIP_REASONS+=("$WT_NAME: lock has no parseable PID — manual review")
    continue
  fi

  # Worktree working-tree path may have been manually deleted (orphan metadata)
  if [ ! -d "$WT_PATH" ]; then
    # Safe to prune — metadata without a working tree can't hold uncommitted state
    git -C "$CWD" worktree prune 2>/dev/null || true
    continue
  fi

  # --- Gate 2: working tree clean (with .claude/ untracked allowlist) ---
  # INVARIANT: Gate 2 only whitelists CC-managed .claude/ UNTRACKED entries
  # (CC issues #26725, #42596, #28041 — worktree-local .claude/ state is
  # session-generated and non-recoverable). Tracked-file modifications and
  # any untracked path outside .claude/ still block — no silent data loss.
  # Widening the allowlist requires a new decisions.md row.
  WT_STATUS=$(git -C "$WT_PATH" status --porcelain 2>/dev/null)
  if [ -n "$WT_STATUS" ]; then
    BLOCKING=0
    while IFS= read -r STATUS_LINE; do
      [ -z "$STATUS_LINE" ] && continue
      CODE="${STATUS_LINE:0:2}"
      SPATH="${STATUS_LINE:3}"
      if [ "$CODE" = "??" ]; then
        case "$SPATH" in
          .claude/*|\".claude/*) continue ;;
          *) BLOCKING=$((BLOCKING + 1)) ;;
        esac
      else
        BLOCKING=$((BLOCKING + 1))
      fi
    done <<< "$WT_STATUS"
    if [ "$BLOCKING" -gt 0 ]; then
      SKIPPED=$((SKIPPED + 1))
      SKIP_REASONS+=("$WT_NAME: $BLOCKING uncommitted/untracked file(s) — manual review")
      continue
    fi
  fi

  # --- Gate 3: worktree HEAD is ancestor of dev, main, or master ---
  WT_HEAD=$(git -C "$WT_PATH" rev-parse HEAD 2>/dev/null)
  if [ -z "$WT_HEAD" ]; then
    SKIPPED=$((SKIPPED + 1))
    SKIP_REASONS+=("$WT_NAME: unreadable HEAD — manual review")
    continue
  fi

  MERGED_OK=0
  for BASE in dev main master; do
    BASE_HASH=$(git -C "$CWD" rev-parse --verify "$BASE" 2>/dev/null) || continue
    if git -C "$CWD" merge-base --is-ancestor "$WT_HEAD" "$BASE_HASH" 2>/dev/null; then
      MERGED_OK=1
      break
    fi
  done

  if [ "$MERGED_OK" -ne 1 ]; then
    # Count commits present on worktree HEAD but not on any mainline base
    UNMERGED=$(git -C "$CWD" rev-list "$WT_HEAD" --not dev main master 2>/dev/null | wc -l | tr -d ' ')
    SKIPPED=$((SKIPPED + 1))
    SKIP_REASONS+=("$WT_NAME: $UNMERGED unmerged commit(s) — manual review")
    continue
  fi

  # --- All 3 gates passed — clean it up ---
  WT_BRANCH=$(git -C "$WT_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null)
  if git -C "$CWD" worktree unlock "$WT_PATH" 2>/dev/null \
     && git -C "$CWD" worktree remove "$WT_PATH" --force 2>/dev/null; then
    if [ -n "$WT_BRANCH" ] && [ "$WT_BRANCH" != "HEAD" ]; then
      git -C "$CWD" branch -D "$WT_BRANCH" 2>/dev/null || true
    fi
    SWEPT=$((SWEPT + 1))
  else
    SKIPPED=$((SKIPPED + 1))
    SKIP_REASONS+=("$WT_NAME: unlock/remove failed")
  fi
done

# Report only when there's something to say
if [ "$SWEPT" -gt 0 ]; then
  echo "DHX: swept $SWEPT stale worktree(s)"
fi
if [ "$SKIPPED" -gt 0 ]; then
  echo "⚠ DHX: $SKIPPED stale worktree(s) need manual review:"
  for R in "${SKIP_REASONS[@]}"; do
    echo "  - $R"
  done
fi

exit 0
