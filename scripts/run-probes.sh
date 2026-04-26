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
# WAVE-0 RED STATE NOTICE (D-23):
# The 4 read-cache* probes shipped in this commit are intentional Wave-0
# stubs that exit 1:
#   - tests/probes/probe-read-cache.sh
#   - tests/probes/probe-read-cache-concurrency.sh
#   - tests/probes/probe-read-cache-cross-session.sh
#   - tests/probes/probe-read-cache-prune-concurrency.sh
# This runner reports those 4 as failed until Plans 02/03 of v1.1 Phase 1
# land the actual assertions. Wave-0 red state is EXPECTED and not a
# regression. The pre-commit gate (D-06, Plan 05) only fires AFTER Plans
# 02/03 land assertions — at that point this runner goes green.
#
# Run directly:
#   bash scripts/run-probes.sh
# Exit code 0 = all probes passed. Nonzero = at least one probe failed
# or timed out (124).

set -uo pipefail

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
