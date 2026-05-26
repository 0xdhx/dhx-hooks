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
#   bash scripts/run-probes.sh                              # bare — defaults to --filter SAFE_FOR_LIVE=yes (D-14)
#   bash scripts/run-probes.sh --filter SAFE_FOR_LIVE=yes   # explicit health.sh delegate (D-26)
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
# Bare invocation defaults to SAFE_FOR_LIVE=yes — supersession-watchdog probes
# (and any other SAFE_FOR_LIVE=no) are skipped via header-tag match through the
# existing matches_filter() loop, not via a hardcoded array. (D-14; backlog
# 2026-05-01-retire-supersession-watchdogs-hardcoded-list-via-filter-flag.md
# trigger fired Phase 6 C1 — 3 new SAFE_FOR_LIVE=no probes shipped.)
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
# SUPERSESSION bucket (Convention-A FAIL gating, brief
# .planning/backlog/2026-05-13-run-probes-convention-a-recognition.md): a
# Convention A probe (exit_0_means_v1_2_work_warranted) that correctly exits 1|2
# observing a supersession is NOT a test failure. Such observations land HERE,
# never silently in PASS, so the summary surfaces them distinctly.
SUPERSESSION=0

# active_cc single-source-of-truth (hoisted above the loop). The loop's
# Convention-A gate (below) AND the D-21 multi-cc-results validator (after the
# loop) both need the active CC version to resolve per-probe outcome JSON paths
# under tests/probes/.results/v1.3-multi-cc-ver/<active_cc>/. Derive it ONCE here
# with the dotted-triple grep + "unknown" fallback; both consumers reuse it.
# `|| true` keeps `set -uo pipefail` from errexiting when `claude` is absent.
cc_full=$(claude --version 2>/dev/null || true)
active_cc=$(printf '%s' "$cc_full" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
[[ -n "$active_cc" ]] || active_cc="unknown"

# D-14 default-injection (Phase 6 C4): bare invocation defaults to
# SAFE_FOR_LIVE=yes — supersession-watchdog probes (and any other
# SAFE_FOR_LIVE=no) are skipped via header-tag match through the existing
# matches_filter() loop, not via a hardcoded array. (D-14; backlog
# 2026-05-01-retire-supersession-watchdogs-hardcoded-list-via-filter-flag.md)
if [[ -z "$FILTER_KEY" ]]; then FILTER_KEY="SAFE_FOR_LIVE"; FILTER_VAL="yes"; fi

# D-26: filter check — returns 0 (run) if filter passes, 1 (skip) if filter excludes.
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
    # ----- Convention-A-aware FAIL gating -----
    # Brief: .planning/backlog/2026-05-13-run-probes-convention-a-recognition.md
    # A non-zero, non-124 RC is NOT automatically a failure. Supersession-watchdog
    # probes use Convention A (exit_0_means_v1_2_work_warranted) where exit 1 =
    # supersession FOUND (the VALUE signal), exit 0 = premise still holds. Resolve
    # the probe's freshly-written outcome JSON (exit_code_convention + conclusion)
    # to decide. Convention B (exit_0_means_pass, or field absent) keeps the
    # original "any non-zero → FAIL" semantics. Anything that can't be resolved
    # (jq absent / JSON missing / unparseable) FAILS SAFE → Convention B → FAIL.
    probe_base="$(basename "$p")"
    case "$probe_base" in
      *.sh) probe_stem="${probe_base%.sh}" ;;
      *.js) probe_stem="${probe_base%.js}" ;;
      *)    probe_stem="$probe_base" ;;
    esac
    outcome_json="$REPO/tests/probes/.results/v1.3-multi-cc-ver/$active_cc/${probe_stem}.json"
    convention=""
    conclusion=""
    if command -v jq >/dev/null 2>&1 && [ -f "$outcome_json" ] && jq -e . "$outcome_json" >/dev/null 2>&1; then
      convention=$(jq -r '.exit_code_convention // ""' "$outcome_json" 2>/dev/null || echo "")
      conclusion=$(jq -r '.conclusion // ""' "$outcome_json" 2>/dev/null || echo "")
    fi
    if [ "$convention" = "exit_0_means_v1_2_work_warranted" ]; then
      # Convention A. RC>=3 is a truly unexpected exit → FAIL regardless of conclusion.
      if [ "$RC" -ge 3 ]; then
        echo "[FAIL] $probe_base — Convention A probe exited $RC (>=3, unexpected) — counted FAIL"
        FAIL=$((FAIL+1))
      elif [ "$conclusion" = "error" ] || [ "$conclusion" = "ambiguous" ]; then
        echo "[FAIL] $probe_base — Convention A conclusion=$conclusion (exit $RC) — counted FAIL"
        FAIL=$((FAIL+1))
      else
        # conclusion=supersession_found_* (or any benign conclusion) at RC 1|2:
        # a legitimate supersession observation, NOT a failure.
        echo "[SUPERSESSION OBSERVED] $probe_base — conclusion=$conclusion exit=$RC (Convention A — informational, not FAIL)"
        SUPERSESSION=$((SUPERSESSION+1))
      fi
    else
      # Convention B / field absent / unparseable / jq missing → fail SAFE.
      FAIL=$((FAIL+1))
    fi
  fi
  echo "---"
done
echo "Probes: $PASS passed, $FAIL failed (incl. $TIMEOUT timed out, $SKIPPED skipped), $SUPERSESSION supersession-observed"

# D-21 (Phase 15 MULTI-CC-VER): defensive validation of the supersession-watchdog
# cross-version result corpus. Non-blocking on absent v1.3-multi-cc-ver/<active-cc>/ dir
# so ad-hoc / sandbox-only sweeps (e.g., --filter SAFE_FOR_LIVE=yes) stay clean — the
# validator is only meaningful after a real watchdog re-run has populated the dir.
# Reuses the hoisted active_cc (single source of truth — derived once above the
# loop, shared with the Convention-A gate). The "unknown" fallback is treated as
# absent here: the guards below require a real dotted-triple version AND an
# existing results_dir, so an "unknown" active_cc simply skips the validator.
results_dir="$REPO/tests/probes/.results/v1.3-multi-cc-ver/$active_cc"
if [[ -n "$active_cc" ]] && [[ "$active_cc" != "unknown" ]] && [[ -d "$results_dir" ]] && [[ -x "$REPO/scripts/verify-multi-cc-results.sh" ]]; then
  echo "Running multi-cc-results validator against $results_dir..."
  bash "$REPO/scripts/verify-multi-cc-results.sh" || FAIL=$((FAIL+1))
  echo "---"
fi

[ "$FAIL" -eq 0 ]
