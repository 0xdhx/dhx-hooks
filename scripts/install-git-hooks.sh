#!/usr/bin/env bash
set -euo pipefail
# install-git-hooks.sh — idempotently install repo-local git hooks.
#
# Currently installs:
#   .git/hooks/pre-commit -> ../../scripts/verify-hook-patterns.sh
#
# Behavior:
#   - If the symlink already points at the gate, exit 0 silently.
#   - If no pre-commit hook exists, create the symlink.
#   - If a stale, non-gate pre-commit hook exists, refuse and print
#     instructions rather than clobbering anything.
#
# Safe to re-run.

GATE_REL="../../scripts/verify-hook-patterns.sh"
GATE_ABS_FROM_HOOKS_DIR=".git/hooks/../../scripts/verify-hook-patterns.sh"

if ! GIT_TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null); then
  echo "install-git-hooks: not in a git repository" >&2
  exit 1
fi
cd "$GIT_TOPLEVEL"

if [ ! -f "scripts/verify-hook-patterns.sh" ]; then
  echo "install-git-hooks: scripts/verify-hook-patterns.sh not found — refusing to install" >&2
  exit 1
fi

if [ ! -x "scripts/verify-hook-patterns.sh" ]; then
  chmod +x scripts/verify-hook-patterns.sh
fi

# Resolve the actual git hooks dir (handles worktrees: .git is a file pointing at gitdir)
HOOKS_DIR=$(git rev-parse --git-path hooks 2>/dev/null)
if [ -z "$HOOKS_DIR" ]; then
  echo "install-git-hooks: could not resolve git hooks dir" >&2
  exit 1
fi
mkdir -p "$HOOKS_DIR"

TARGET="$HOOKS_DIR/pre-commit"

# Compute the relative path from $HOOKS_DIR to scripts/verify-hook-patterns.sh
# In a normal repo: .git/hooks → ../../scripts/verify-hook-patterns.sh
# In a worktree: .git/worktrees/<name>/hooks → ../../../../scripts/verify-hook-patterns.sh
# We use an absolute path for worktree safety; symlink works either way.
GATE_ABS="$GIT_TOPLEVEL/scripts/verify-hook-patterns.sh"

if [ -L "$TARGET" ]; then
  CURRENT=$(readlink "$TARGET")
  # Resolve the link target (relative or absolute) to compare against the gate
  case "$CURRENT" in
    /*) RESOLVED="$CURRENT" ;;
    *)  RESOLVED="$HOOKS_DIR/$CURRENT" ;;
  esac
  if [ "$(readlink -f "$RESOLVED" 2>/dev/null || true)" = "$(readlink -f "$GATE_ABS" 2>/dev/null || true)" ]; then
    # Already installed and pointing at our gate — nothing to do
    exit 0
  fi
  echo "install-git-hooks: $TARGET is a symlink pointing at '$CURRENT' (not our gate)." >&2
  echo "  Refusing to clobber. Inspect and remove it manually, then re-run." >&2
  exit 1
fi

if [ -e "$TARGET" ]; then
  echo "install-git-hooks: $TARGET already exists and is not our gate." >&2
  echo "  Refusing to clobber. Inspect and remove it manually, then re-run." >&2
  exit 1
fi

ln -s "$GATE_ABS" "$TARGET"
echo "install-git-hooks: installed $TARGET -> $GATE_ABS"
exit 0
