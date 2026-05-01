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
#   bash scripts/run-probes.sh                              # bare — all non-supersession probes
#   bash scripts/run-probes.sh --filter SAFE_FOR_LIVE=yes   # health.sh delegate (D-26)
#   bash scripts/run-probes.sh --filter SAFE_FOR_LIVE=no    # sandbox-only (D-26+D-27)
# Exit code 0 = all probes passed. Nonzero = at least one probe failed
# or timed out (124). Exit 2 = invalid flag value or D-27 PWD+CONFIG_DIR
# refusal under --filter SAFE_FOR_LIVE=no when cwd or CONFIG_DIR resolves
# under live ~/.ccs.

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

# ----- D-26: --filter SAFE_FOR_LIVE=yes|no flag (Phase 4 Plan 02) -----
# Composition rule: SUPERSESSION_WATCHDOGS skip applies first; --filter applies
# to the REMAINING set. Bare invocation (no --filter) preserves backward compat
# for verify-hook-patterns.sh check #8 + sync-public-mirror.sh:413 consumers.
FILTER_KEY=""
FILTER_VAL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --filter)
      shift
      if [[ "${1:-}" == SAFE_FOR_LIVE=* ]]; then
        FILTER_KEY="SAFE_FOR_LIVE"
        FILTER_VAL="${1#SAFE_FOR_LIVE=}"
        if [[ "$FILTER_VAL" != "yes" && "$FILTER_VAL" != "no" ]]; then
          echo "run-probes: --filter SAFE_FOR_LIVE expects 'yes' or 'no', got '$FILTER_VAL'" >&2
          exit 2
        fi
      else
        echo "run-probes: --filter expects SAFE_FOR_LIVE=yes|no, got '${1:-<empty>}'" >&2
        exit 2
      fi
      shift
      ;;
    *)
      echo "run-probes: unknown argument '$1' (supported: --filter SAFE_FOR_LIVE=yes|no)" >&2
      exit 2
      ;;
  esac
done

# ----- D-27: PWD+CONFIG_DIR refusal gate (fires ONLY on --filter SAFE_FOR_LIVE=no) -----
# Closes T-04-07 — refuses to invoke live-state-mutating probes when cwd OR
# CLAUDE_CONFIG_DIR resolves under live ~/.ccs tree (covers shared + instances/*/).
if [[ "$FILTER_KEY" == "SAFE_FOR_LIVE" && "$FILTER_VAL" == "no" ]]; then
  cwd_resolved=$(realpath "$PWD" 2>/dev/null || true)
  curr=$(realpath "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null || true)
  live=$(realpath "$HOME/.ccs" 2>/dev/null || true)
  if [[ -n "$live" ]] && { [[ "$cwd_resolved" == "$live"* ]] || [[ "$curr" == "$live"* ]]; }; then
    echo "ERROR: --filter SAFE_FOR_LIVE=no refuses — cwd ($cwd_resolved) or CONFIG_DIR ($curr) resolves under live $live (~/.ccs). Run from a sandbox cwd with sandbox CLAUDE_CONFIG_DIR." >&2
    exit 2
  fi
fi

REPO="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0
PASS=0
TIMEOUT=0
SKIPPED=0

# Supersession-watchdog probes (D-12) are operator-invoked manually with
# specific environment requirements (e.g. ANTHROPIC_API_KEY for --bare cells).
# They emit Convention A exit codes (0/1/2) that don't map to suite pass/fail
# semantics. Skip them here; they're run on-demand per phase 03 plan 03.
SUPERSESSION_WATCHDOGS=(
  "probe-installed-plugins-no-natural-heal.sh"
)

is_supersession_watchdog() {
  local base="$1"
  for s in "${SUPERSESSION_WATCHDOGS[@]}"; do
    [ "$base" = "$s" ] && return 0
  done
  return 1
}

# D-26: filter check — returns 0 (run) if filter passes, 1 (skip) if filter excludes.
# Composition: caller invokes is_supersession_watchdog FIRST; only on miss does it call this.
matches_filter() {
  local file="$1"
  [[ -z "$FILTER_KEY" ]] && return 0   # bare invocation — no filter
  # Look for `# SAFE_FOR_LIVE: <val>` (sh) or `// SAFE_FOR_LIVE: <val>` (js)
  if grep -qE "^(# |// )SAFE_FOR_LIVE: ${FILTER_VAL}\b" "$file"; then
    return 0
  fi
  # Untagged probes always skipped under --filter (refuse to assume safety)
  if ! grep -qE "^(# |// )SAFE_FOR_LIVE: (yes|no)\b" "$file"; then
    echo "[SKIP] $(basename "$file") — refusing: missing SAFE_FOR_LIVE tag"
    SKIPPED=$((SKIPPED+1))
    return 1
  fi
  echo "[SKIP] $(basename "$file") — SAFE_FOR_LIVE filter (looking for $FILTER_VAL)"
  SKIPPED=$((SKIPPED+1))
  return 1
}

for p in "$REPO"/tests/probes/probe-*.{js,sh}; do
  [ -e "$p" ] || continue
  if is_supersession_watchdog "$(basename "$p")"; then
    echo "[SKIPPED] $(basename "$p") — supersession-watchdog probe, run manually with required env"
    SKIPPED=$((SKIPPED+1))
    echo "---"
    continue
  fi
  if ! matches_filter "$p"; then
    echo "---"
    continue
  fi
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
echo "Probes: $PASS passed, $FAIL failed (incl. $TIMEOUT timed out, $SKIPPED skipped)"
[ "$FAIL" -eq 0 ]
