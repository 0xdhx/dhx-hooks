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
#   bash scripts/run-probes.sh --filter SAFE_FOR_LIVE=yes --filter LIVE_RUNTIME=no
#                                                           # hermetic tier — the pre-commit gate's default (2026-08-20)
#   bash scripts/run-probes.sh --filter SAFE_FOR_LIVE=yes --filter LIVE_RUNTIME=yes --stamp
#                                                           # live tier + version stamp; run after a gsd-core install
#
# --filter is REPEATABLE and the keys AND together. Two keys are recognised:
#   SAFE_FOR_LIVE=yes|no  — untagged probes are REFUSED (fail toward NOT running:
#                           an unclassified probe might mutate live state).
#   LIVE_RUNTIME=yes|no   — untagged probes are treated as `no` (fail toward
#                           RUNNING at commit time: an unclassified probe is
#                           assumed hermetic, so the gate keeps checking it).
# The two defaults point in opposite directions ON PURPOSE — each fails toward
# the safe side of its own question. See tests/probes/LIVE_RUNTIME.md.
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
FILTER_KEYS=()
FILTER_VALS=()
STAMP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --filter)
      shift
      _spec="${1:-}"
      case "$_spec" in
        SAFE_FOR_LIVE=*|LIVE_RUNTIME=*)
          _k="${_spec%%=*}"
          _v="${_spec#*=}"
          if [[ "$_v" != "yes" && "$_v" != "no" ]]; then
            echo "run-probes: --filter $_k expects 'yes' or 'no', got '$_v'" >&2
            exit 2
          fi
          FILTER_KEYS+=("$_k")
          FILTER_VALS+=("$_v")
          ;;
        *)
          echo "run-probes: --filter expects SAFE_FOR_LIVE=yes|no or LIVE_RUNTIME=yes|no, got '${_spec:-<empty>}'" >&2
          exit 2
          ;;
      esac
      shift
      ;;
    --stamp)
      STAMP=1
      shift
      ;;
    *)
      echo "run-probes: unknown argument '$1' (supported: --filter SAFE_FOR_LIVE=yes|no, --filter LIVE_RUNTIME=yes|no, --stamp)" >&2
      exit 2
      ;;
  esac
done

# Helper: current value requested for a filter key ("" when the key is unset).
filter_val_for() {
  local want="$1" i
  for i in "${!FILTER_KEYS[@]}"; do
    [[ "${FILTER_KEYS[$i]}" == "$want" ]] && { printf '%s' "${FILTER_VALS[$i]}"; return 0; }
  done
  printf ''
}

# ----- D-27: PWD+CONFIG_DIR refusal gate (fires ONLY on --filter SAFE_FOR_LIVE=no) -----
# Closes T-04-07 — refuses to invoke live-state-mutating probes when cwd OR
# CLAUDE_CONFIG_DIR resolves under live ~/.ccs tree (covers shared + instances/*/).
if [[ "$(filter_val_for SAFE_FOR_LIVE)" == "no" ]]; then
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
# Basenames of probes that FAILED this run. Consumed by the --stamp writer so the
# pre-commit gate can name which live differentials are red without re-running them.
FAILED_NAMES=()
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
# NOTE: the default is SAFE_FOR_LIVE=yes ONLY. LIVE_RUNTIME is deliberately NOT
# defaulted — a bare invocation (health.sh --probes, sync-public-mirror.sh, a
# direct operator run) keeps running the WHOLE suite including the live tier, so
# the 2026-08-20 tier split subtracts coverage from exactly one caller: the
# pre-commit gate, which opts in explicitly. Adding a default here would silently
# remove the live differentials from every other surface.
if [[ ${#FILTER_KEYS[@]} -eq 0 ]]; then FILTER_KEYS=("SAFE_FOR_LIVE"); FILTER_VALS=("yes"); fi

# D-26 (+2026-08-20 multi-key): filter check — returns 0 (run) if EVERY requested
# filter passes, 1 (skip) if any excludes. Keys AND together.
#
# The two keys fail in OPPOSITE directions, and that asymmetry is load-bearing:
#   SAFE_FOR_LIVE — untagged is REFUSED. The question is "may this touch live
#                   state?", and an unclassified probe must not be assumed safe.
#   LIVE_RUNTIME  — untagged reads as `no`. The question is "is this probe's
#                   verdict flippable by an upstream install?", and an
#                   unclassified probe must be assumed hermetic so the
#                   pre-commit gate keeps running it. A new live probe that
#                   forgets its tag therefore lands in the tier that runs MORE
#                   often, never the one that runs less. probe-live-runtime-tier.sh
#                   asserts the tag/roster parity that catches the omission.
matches_filter() {
  local file="$1" i key val tagged
  for i in "${!FILTER_KEYS[@]}"; do
    key="${FILTER_KEYS[$i]}"
    val="${FILTER_VALS[$i]}"
    if grep -qE "^(# |// )${key}: ${val}\b" "$file"; then
      continue
    fi
    if grep -qE "^(# |// )${key}: (yes|no)\b" "$file"; then
      tagged=yes
    else
      tagged=no
    fi
    if [[ "$tagged" == "no" ]]; then
      if [[ "$key" == "LIVE_RUNTIME" ]]; then
        # Untagged == LIVE_RUNTIME: no. Run it when `no` was asked for.
        [[ "$val" == "no" ]] && continue
      else
        echo "[SKIP] $(basename "$file") — refusing: missing ${key} tag"
        SKIPPED=$((SKIPPED+1))
        return 1
      fi
    fi
    echo "[SKIP] $(basename "$file") — ${key} filter (looking for $val)"
    SKIPPED=$((SKIPPED+1))
    return 1
  done
  return 0
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
    FAILED_NAMES+=("$(basename "$p")")
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
        FAILED_NAMES+=("$probe_base")
      elif [ "$conclusion" = "error" ] || [ "$conclusion" = "ambiguous" ]; then
        echo "[FAIL] $probe_base — Convention A conclusion=$conclusion (exit $RC) — counted FAIL"
        FAIL=$((FAIL+1))
        FAILED_NAMES+=("$probe_base")
      else
        # conclusion=supersession_found_* (or any benign conclusion) at RC 1|2:
        # a legitimate supersession observation, NOT a failure.
        echo "[SUPERSESSION OBSERVED] $probe_base — conclusion=$conclusion exit=$RC (Convention A — informational, not FAIL)"
        SUPERSESSION=$((SUPERSESSION+1))
      fi
    else
      # Convention B / field absent / unparseable / jq missing → fail SAFE.
      #
      # Announce the name. This branch used to bump the counters SILENTLY, so a
      # red tier reported "N failed" with no roster and the operator had to
      # re-derive which probes those were by eye from thousands of lines of
      # per-assertion output. On 2026-08-23 that cost: the tier had been red for
      # four days, the failing set was reported by guess, and the commit that
      # tripped it reached for DHX_RED_COMMIT=1 rather than a diagnosis. A gate
      # that cannot name what it caught does not get acted on.
      echo "[FAIL] $probe_base — exited $RC (Convention B: exit 0 means pass)"
      FAIL=$((FAIL+1))
      FAILED_NAMES+=("$probe_base")
    fi
  fi
  echo "---"
done
echo "Probes: $PASS passed, $FAIL failed (incl. $TIMEOUT timed out, $SKIPPED skipped), $SUPERSESSION supersession-observed"
# Roster after the count, unconditionally. `--stamp` also records this set in
# status.json, but the stamp is written only for the live tier — the hermetic
# tier (pre-commit check #8a) never passes --stamp, which is exactly the run
# whose operator most needs the names. Printed to stdout with the summary so
# it survives the `|| { echo FAILED...; exit 1; }` fence in check #8a.
if [ "${#FAILED_NAMES[@]}" -gt 0 ]; then
  printf '  red: %s\n' "${FAILED_NAMES[@]}"
fi

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

# ----- 2026-08-20: --stamp — record that the live tier RAN against this gsd-core -----
# Written on PASS *and* on FAIL, deliberately. The stamp answers "was the live tier
# executed against the currently-installed gsd-core?", NOT "did it pass". Gating the
# write on success would deadlock the repo exactly as the pre-tier gate did: a slow
# live red (statemd mirror re-derivation) would leave the stamp stale forever, so the
# freshness check in verify-hook-patterns.sh check #8c would block every commit until
# the multi-hour fix landed — reinstating the blast radius this split exists to remove.
# Instead the stamp records the failures by name, 8c blocks only commits that stage a
# failing probe's declared LIVE_SUBJECT, and everything else flows.
if [ "$STAMP" -eq 1 ]; then
  stamp_dir="$REPO/tests/probes/.results/live-tier"
  mkdir -p "$stamp_dir"
  gsd_version="absent"
  [ -r "$HOME/.claude/gsd-core/VERSION" ] && gsd_version="$(tr -d '[:space:]' < "$HOME/.claude/gsd-core/VERSION")"
  {
    printf '{\n'
    printf '  "gsd_version": "%s",\n' "$gsd_version"
    printf '  "ran_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  "passed": %s,\n' "$PASS"
    printf '  "failing": ['
    for i in "${!FAILED_NAMES[@]}"; do
      [ "$i" -gt 0 ] && printf ', '
      printf '"%s"' "${FAILED_NAMES[$i]}"
    done
    printf ']\n}\n'
  } > "$stamp_dir/status.json"
  echo "Live-tier stamp written: gsd-core $gsd_version, $PASS passed, ${#FAILED_NAMES[@]} failing → ${stamp_dir#$REPO/}/status.json"
fi

[ "$FAIL" -eq 0 ]
