#!/usr/bin/env bash
# scripts/run-probes.sh — run all probes, aggregate exit codes
#
# Wraps the inline `for p in tests/probes/probe-*.{js,sh}; do ...` loop
# documented in tests/probes/README.md:49-57 with exit-code aggregation
# AND a per-probe `timeout 30` wrapper (D-16; POSIX coreutils `timeout`).
# Stuck probes no longer block the pre-commit gate — exit code 124 = TIMED OUT.
#
# Authored Wave 0 of v1.1 Phase 1 (Option B read-guard ownership rewrite)
# per RESEARCH.md RECONCILE #1 — referenced by D-06 atomic-commit pre-commit
# gate, by .planning/todos/pending/2026-04-26-v1-1-1-remove-legacy-path-read-fallback.md,
# and by future probe-suite-gated work.
#
# Run directly:
#   bash scripts/run-probes.sh
# Exit code 0 = all probes passed. Nonzero = at least one probe failed
# or timed out (124).

set -uo pipefail

# Clear inherited git env vars so probes that build tmpdir fixtures (git init,
# worktree-add, etc.) don't trip over the parent's index/dir/work-tree paths.
# Surfaced 2026-04-28 when verify-hook-patterns.sh check #8 first ran the
# probe suite from inside a pre-commit context: probe-stale-worktree-sweep.sh
# fixtures emitted `fatal: .git/index: index file open failed: Not a directory`
# because $GIT_INDEX_FILE leaked from the outer commit operation. Probes that
# don't run git remain unaffected. User-config vars (GIT_PAGER, GIT_EDITOR,
# GIT_TERMINAL_PROMPT, etc.) are deliberately preserved.
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
      GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
      GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE \
      GIT_PREFIX GIT_INTERNAL_GETTEXT_SH_SCHEME GIT_REFLOG_ACTION

REPO="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0
PASS=0
TIMEOUT=0
for p in "$REPO"/tests/probes/probe-*.{js,sh}; do
  [ -e "$p" ] || continue
  case "$p" in
    *.js) timeout 30 node "$p" ;;
    *.sh) timeout 30 bash "$p" ;;
  esac
  RC=$?
  if [ "$RC" -eq 124 ]; then
    echo "[TIMED OUT] $(basename "$p") — exceeded 30s (D-16)"
    TIMEOUT=$((TIMEOUT+1))
    FAIL=$((FAIL+1))
  elif [ "$RC" -eq 0 ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
  fi
  echo "---"
done
echo "Probes: $PASS passed, $FAIL failed (incl. $TIMEOUT timed out)"
[ "$FAIL" -eq 0 ]
