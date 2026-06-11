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
# Gate-3-fail reasons are classified: commits reachable from another local branch
# (e.g. a GSD phase lane gsd/phase-N-<slug>) are flagged "safe to remove" and name
# the containing branch; commits on no other branch are "real unmerged work".
# Auto-removal stays mainline-only — phase-lane merge is advisory, not a sweep trigger.
# The skip report groups safe-to-remove items first, then review items, and the
# header tally adapts to the set (all-review / all-safe / mixed) so an all-safe
# set never reads as "needs manual review".
#
# Context: anthropics/claude-code#36182 plus observed CC behavior where the
# 'locked' file keeps the outer session's PID, so `git worktree remove --force`
# refuses removal until either unlock or session exit. Stale locked worktrees
# then accumulate on disk indefinitely. See reports/2026-04-19-worktree-leak-gh-36182-third-incident.md.
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
# Two skip categories drive the adaptive header below: SAFE_REASONS = the hook
# chose not to act but the work is preserved on another branch (human can remove
# by hand); REVIEW_REASONS = everything else (data at risk, or broken metadata).
SAFE_REASONS=()
REVIEW_REASONS=()

for WT_META in "${WT_METAS[@]}"; do
  WT_NAME=$(basename "$WT_META")
  LOCK_FILE="$WT_META/locked"
  GITDIR_FILE="$WT_META/gitdir"

  # Only act on LOCKED worktrees — unlocked orphans are handled by `git worktree prune`
  [ -f "$LOCK_FILE" ] || continue

  # Resolve the working-tree path via the gitdir file (content: path to <worktree>/.git)
  if [ ! -f "$GITDIR_FILE" ]; then
    REVIEW_REASONS+=("$WT_NAME: no gitdir metadata file")
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
    REVIEW_REASONS+=("$WT_NAME: lock has no parseable PID — manual review")
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
      REVIEW_REASONS+=("$WT_NAME: $BLOCKING uncommitted/untracked file(s) — manual review")
      continue
    fi
  fi

  # --- Gate 3: worktree HEAD is ancestor of dev, main, or master ---
  WT_HEAD=$(git -C "$WT_PATH" rev-parse HEAD 2>/dev/null)
  if [ -z "$WT_HEAD" ]; then
    REVIEW_REASONS+=("$WT_NAME: unreadable HEAD — manual review")
    continue
  fi
  # Resolve the worktree's own branch up front — needed by both the Gate-3-fail
  # classification (to exclude self from the containing-branch scan) and the
  # all-gates-passed cleanup below.
  WT_BRANCH=$(git -C "$WT_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null)

  # Build the verified-base list ONCE — only mainline refs that actually exist.
  # `git rev-list <HEAD> --not dev main master` dies `fatal: ambiguous argument`
  # → exit 128 → empty stdout (swallowed by 2>/dev/null) → wc -l = 0 (a FALSE
  # zero) the instant any of dev/main/master is absent — e.g. cross-repo, where
  # `dev` was folded into `main`. Verify each base before using it as a --not arg.
  VERIFIED_BASES=()
  for BASE in dev main master; do
    git -C "$CWD" rev-parse --verify "$BASE" &>/dev/null && VERIFIED_BASES+=("$BASE")
  done

  MERGED_OK=0
  for BASE in "${VERIFIED_BASES[@]:-}"; do
    [ -z "$BASE" ] && continue
    if git -C "$CWD" merge-base --is-ancestor "$WT_HEAD" "$BASE" 2>/dev/null; then
      MERGED_OK=1
      break
    fi
  done

  if [ "$MERGED_OK" -ne 1 ]; then
    # Count commits present on worktree HEAD but not on any EXISTING mainline base.
    # Empty base list → nothing is a known-safe base → treat all history as unmerged.
    if [ "${#VERIFIED_BASES[@]}" -gt 0 ]; then
      UNMERGED=$(git -C "$CWD" rev-list "$WT_HEAD" --not "${VERIFIED_BASES[@]}" 2>/dev/null | wc -l | tr -d ' ')
    else
      UNMERGED=$(git -C "$CWD" rev-list "$WT_HEAD" 2>/dev/null | wc -l | tr -d ' ')
    fi

    # Phase-lane awareness: under GSD's worktree-per-plan model, agent worktrees
    # fold into the phase lane (gsd/phase-N-<slug>), NOT main — so a dead-pid
    # orphan whose work is fully on the lane fails this mainline-only gate every
    # session until the phase merges to main. Classify WHERE the commits live so
    # the reviewer gets the one fact they need. Auto-removal stays mainline-only
    # (a phase branch can still be discarded), so this is message accuracy only —
    # the worktree is skipped either way.
    CONTAINING=$(git -C "$CWD" branch --format='%(refname:short)' --contains "$WT_HEAD" 2>/dev/null \
                 | grep -v -x "$WT_BRANCH" | head -3 | paste -sd, -)
    if [ -n "$CONTAINING" ]; then
      SAFE_REASONS+=("$WT_NAME: $UNMERGED commit(s), all on $CONTAINING (not yet on main) — safe to remove")
    else
      REVIEW_REASONS+=("$WT_NAME: $UNMERGED commit(s) on NO other branch — real unmerged work, manual review")
    fi
    continue
  fi

  # --- All 3 gates passed — clean it up ---
  if git -C "$CWD" worktree unlock "$WT_PATH" 2>/dev/null \
     && git -C "$CWD" worktree remove "$WT_PATH" --force 2>/dev/null; then
    if [ -n "$WT_BRANCH" ] && [ "$WT_BRANCH" != "HEAD" ]; then
      git -C "$CWD" branch -D "$WT_BRANCH" 2>/dev/null || true
    fi
    SWEPT=$((SWEPT + 1))
  else
    REVIEW_REASONS+=("$WT_NAME: unlock/remove failed")
  fi
done

# Report only when there's something to say
if [ "$SWEPT" -gt 0 ]; then
  echo "DHX: swept $SWEPT stale worktree(s)"
fi
SAFE_N=${#SAFE_REASONS[@]}
REVIEW_N=${#REVIEW_REASONS[@]}
TOTAL_SKIPPED=$((SAFE_N + REVIEW_N))

if [ "$TOTAL_SKIPPED" -gt 0 ]; then
  # Adaptive header — the actionability tally sits at the summary position
  # (terminal patterns-status "Aggregate Summary Line"), and the wording matches
  # the set's composition so an all-safe set never reads as "needs manual review".
  if [ "$SAFE_N" -eq 0 ]; then
    echo "⚠ DHX: $REVIEW_N stale worktree(s) need manual review:"
  elif [ "$REVIEW_N" -eq 0 ]; then
    echo "⚠ DHX: $SAFE_N stale worktree(s) — safe to remove (work preserved on another branch):"
  else
    echo "⚠ DHX: $TOTAL_SKIPPED stale worktree(s) skipped · $SAFE_N safe to remove · $REVIEW_N need review"
  fi
  # Safe-to-remove items first (grouped), then review items. Each line carries its
  # own verdict suffix, so grouping is ordering — not load-bearing structure.
  for R in "${SAFE_REASONS[@]:-}"; do
    [ -z "$R" ] && continue
    echo "  - $R"
  done
  for R in "${REVIEW_REASONS[@]:-}"; do
    [ -z "$R" ] && continue
    echo "  - $R"
  done
fi

exit 0
