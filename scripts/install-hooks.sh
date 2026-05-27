#!/usr/bin/env bash
set -euo pipefail
# install-hooks.sh — idempotently install cross-repo's [XR] tracked git hooks.
#
# Ported verbatim from ~/repos/skills/scripts/install-hooks.sh (D-10) with one
# documented self-heal-glob decision (see "Self-heal note" below).
#
# Installs:
#   .git/hooks/pre-commit -> scripts/hooks/pre-commit   (symlink, worktree-safe)
#
# scripts/hooks/pre-commit is a run-parts dispatcher over scripts/hooks/
# pre-commit.d/. New checks are added there — this installer only wires the
# symlink, so it needs to run just once per clone or worktree.
#
# Behavior:
#   - Symlink already points at the dispatcher  -> exit 0 silently.
#   - No pre-commit hook present                -> create the symlink.
#   - A foreign pre-commit hook is present      -> refuse + guidance, exit 1.
#   - Stale symlink into a removed worktree     -> self-heal (remove, reinstall).
#
# Worktree-safe (D-10, empirically verified): `git rev-parse --git-path hooks`
# resolves the COMMON .git/hooks even from a linked worktree, and an ABSOLUTE
# symlink target ($GIT_TOPLEVEL/scripts/hooks/pre-commit) fires for the primary
# checkout AND every linked worktree. core.hooksPath is NOT used.
#
# Self-heal note (Pitfall 3, Phase 06 provenance correction #2):
#   skills' self-heal below matches `*/.worktrees/*`. cross-repo's worktree
#   conventions are `.claude/worktrees/` (harness) and `../cross-repo-<branch>`
#   (sibling, per CLAUDE.md) — neither matches `*/.worktrees/*`. The verbatim
#   port is KEPT intentionally: an unrecognized stale symlink falls through to
#   the refuse-to-clobber branch, the correct conservative default under the
#   shared-tree invariant (better to refuse than to clobber a symlink that may
#   belong to a live concurrent session). Widening the glob is optional and
#   deferred — refuse-to-clobber is the safe fallthrough either way.
#
# NOTE (Phase 06 Plan 01 scope): this installer is PORTED here but is NOT run
# against cross-repo's own .git/hooks by this plan. Self-install (writing the
# shared .git/hooks/pre-commit symlink, which activates the gate for all
# concurrent sessions — D-14) is Plan 04's gated checkpoint (MVP-05).
#
# Safe to re-run. Escape hatch for the installed hook: `git commit --no-verify`.

if ! GIT_TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null); then
  echo "install-hooks: not in a git repository" >&2
  exit 1
fi
cd "$GIT_TOPLEVEL"

DISPATCHER="scripts/hooks/pre-commit"
if [ ! -f "$DISPATCHER" ]; then
  echo "install-hooks: $DISPATCHER not found — refusing to install" >&2
  exit 1
fi
[ -x "$DISPATCHER" ] || chmod +x "$DISPATCHER"

# run-parts requires the checks themselves to be executable.
if [ -d "scripts/hooks/pre-commit.d" ]; then
  find scripts/hooks/pre-commit.d -maxdepth 1 -type f ! -perm -u+x \
    -exec chmod +x {} +
fi

# Resolve the real git hooks dir (handles worktrees: .git is a file).
HOOKS_DIR=$(git rev-parse --git-path hooks 2>/dev/null || true)
if [ -z "$HOOKS_DIR" ]; then
  echo "install-hooks: could not resolve git hooks dir" >&2
  exit 1
fi
mkdir -p "$HOOKS_DIR"

TARGET="$HOOKS_DIR/pre-commit"
# Absolute path is worktree-safe — a relative symlink would break from the
# deeper .git/worktrees/<name>/hooks/ directory.
DISPATCHER_ABS="$GIT_TOPLEVEL/scripts/hooks/pre-commit"

if [ -L "$TARGET" ]; then
  CURRENT=$(readlink "$TARGET")
  case "$CURRENT" in
    /*) RESOLVED="$CURRENT" ;;
    *)  RESOLVED="$HOOKS_DIR/$CURRENT" ;;
  esac
  if [ "$(readlink -f "$RESOLVED" 2>/dev/null || true)" \
     = "$(readlink -f "$DISPATCHER_ABS" 2>/dev/null || true)" ]; then
    exit 0   # already installed and pointing at our dispatcher
  fi
  # Self-heal: symlink into a now-removed .worktrees/ checkout — safe to clobber.
  # (See "Self-heal note" in the header: this glob does not match cross-repo's
  # worktree conventions, so cross-repo stale symlinks fall through to the
  # refuse-to-clobber branch — the intended conservative default.)
  if [[ "$CURRENT" == *"/.worktrees/"* ]] && [ ! -e "$RESOLVED" ]; then
    echo "install-hooks: removing stale worktree symlink (target: $CURRENT)"
    rm "$TARGET"
  else
    echo "install-hooks: $TARGET is a symlink pointing at '$CURRENT' (not our dispatcher)." >&2
    echo "  Refusing to clobber. Inspect and remove it manually, then re-run." >&2
    exit 1
  fi
fi

if [ -e "$TARGET" ]; then
  echo "install-hooks: $TARGET already exists and is not our dispatcher." >&2
  echo "  Refusing to clobber. Inspect and remove it manually, then re-run." >&2
  exit 1
fi

ln -s "$DISPATCHER_ABS" "$TARGET"
echo "install-hooks: installed $TARGET -> $DISPATCHER_ABS"
exit 0
