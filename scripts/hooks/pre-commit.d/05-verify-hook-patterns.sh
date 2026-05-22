#!/usr/bin/env bash
# scripts/hooks/pre-commit.d/05-verify-hook-patterns.sh
#
# Thin wrapper that folds the hooks repo's established 8-check hook-pattern gate
# (scripts/verify-hook-patterns.sh) INTO the backlog-frontmatter-gate convention's
# run-parts dispatcher (scripts/hooks/pre-commit).
#
# WHY a wrapper, not a copy:
#   scripts/verify-hook-patterns.sh remains the SINGLE SOURCE OF TRUTH for the
#   8-check logic (Patterns-header, HP-NNN resolution, SIGPIPE+pipefail lint,
#   probe-set-flag lint, probe-suite run, etc). This file MUST NOT re-implement
#   or duplicate any of it — it only `exec`s the canonical script so a single
#   edit to that script stays authoritative.
#
# ORDERING (05- < 10-):
#   The dispatcher iterates pre-commit.d/* in glob order. The `05-` prefix orders
#   this established gate BEFORE the convention's `10-backlog-frontmatter.sh`, so
#   the long-standing hook-pattern checks fire first (preserves prior behavior:
#   the foreign .git/hooks/pre-commit symlink used to point straight at
#   verify-hook-patterns.sh).
#
# ESCAPE HATCHES PRESERVED:
#   - DHX_RED_COMMIT=1 (skips only verify-hook-patterns check #8, read INSIDE that
#     script) is inherited across the `exec` — env survives exec.
#   - `git commit --no-verify` is git-native and never invokes this dispatcher at
#     all, so it bypasses every leaf including this wrapper.
#
# Exit code: `exec` replaces this process with verify-hook-patterns.sh, so that
# script's own exit code (0 pass / 1 block) propagates directly to the dispatcher.

set -uo pipefail

REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
exec bash "$REPO/scripts/verify-hook-patterns.sh"
