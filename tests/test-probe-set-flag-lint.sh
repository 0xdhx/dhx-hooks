#!/usr/bin/env bash
# test-probe-set-flag-lint.sh — Regression tests for the probe `set +e`
# discipline lint hosted in scripts/verify-hook-patterns.sh (CAL-POLISH-05 /
# D-07 / D-10 / D-12).
#
# SAFE_FOR_LIVE-irrelevant: this is a test-* harness, NOT a probe-* (run-probes.sh
# globs probe-*.{js,sh} only — it never auto-runs this file). Every case runs in
# an isolated `mktemp -d` throwaway git repo; nothing here touches the live
# ~/.cache, ~/.claude, or the real working tree.
#
# Run: bash tests/test-probe-set-flag-lint.sh
# Exit: 0 = all pass, 1 = any failure
#
# D-12 (test-harness seam): verify-hook-patterns.sh does `cd "$GIT_TOPLEVEL"`
# (line 37) and expects repo-local paths, so this harness CANNOT just run the
# whole gate against a mktemp fixture repo. Instead it SOURCES the extracted
# `lint_probe_set_flags` function from verify-hook-patterns.sh and calls it
# directly against fixture-staged content inside each mktemp git repo. The
# DHX_SKIP_SET_FLAG_LINT_TESTS=1 guard (set below) prevents recursion: when
# the host gate later runs `bash tests/test-probe-set-flag-lint.sh`, sourcing
# verify-hook-patterns.sh must NOT re-enter the gate's own checks or re-invoke
# this harness.

set -uo pipefail

# Pre-commit env-leak scrub (sibling of run-probes.sh row 190, 2026-04-28).
# check 7c (verify-hook-patterns.sh:298-300) runs this harness from INSIDE the
# `git commit` pre-commit hook, where git exports GIT_DIR/GIT_INDEX_FILE/
# GIT_WORK_TREE/GIT_PREFIX. Those leak into the per-case `mktemp` fixture
# subshells below — `git init`/`add`/`commit` then operate on the REAL repo
# index instead of the throwaway fixture, so Cases 1/2/3/6 false-fail (clean
# env 8/8 → leaked env 4/8) and block every `dhx/*.sh` commit. run-probes.sh's
# prelude doesn't cover us: it globs `probe-*` only, never this `test-*` file.
# Explicit list (not `env -i`, not dynamic `env|grep ^GIT_`) — survives HP-028
# and documents which vars interfere; mirrors run-probes.sh verbatim. Scrubbing
# once at process top suffices: this child can't mutate the parent commit's env,
# and the harness itself needs no GIT_* (every git call runs inside a fixture).
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
      GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
      GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE \
      GIT_PREFIX GIT_INTERNAL_GETTEXT_SH_SCHEME GIT_REFLOG_ACTION

# Recursion guard (D-12): sourcing verify-hook-patterns.sh below must only
# define the function, not execute the full gate, and the gate's own test
# wiring is skipped when this flag is set.
export DHX_SKIP_SET_FLAG_LINT_TESTS=1

# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

# Resolve the gate script absolutely so the source survives the per-case cd.
GATE_SCRIPT="$(cd "$(dirname "$0")/../scripts" && pwd)/verify-hook-patterns.sh"

# D-12 seam: source the gate to import the extracted lint function. The
# DHX_SKIP_SET_FLAG_LINT_TESTS guard above keeps the script from running its
# own checks at source time (it returns early before any candidate scan).
# shellcheck source=scripts/verify-hook-patterns.sh
source "$GATE_SCRIPT"

if ! declare -F lint_probe_set_flags >/dev/null 2>&1; then
  echo "FATAL: lint_probe_set_flags not defined after sourcing $GATE_SCRIPT" >&2
  echo "       (Task 2 must extract the lint into a callable function — D-12)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Fixture helper — build an isolated mktemp git repo, run a setup callback that
# stages the scenario, then invoke lint_probe_set_flags and capture its rc.
# Echoes the rc on stdout so the caller can assert pass(0)/fail(1).
# ---------------------------------------------------------------------------

run_lint_in_fixture() {
  # $1 = setup function name (runs with PWD inside the fixture repo)
  # remaining args: passed through to the setup function
  local setup_fn="$1"; shift
  local repo rc
  repo=$(mktemp -d)
  (
    cd "$repo" || exit 99
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    mkdir -p tests/probes docs
    "$setup_fn" "$@"
    # FAIL is the shared accumulator the function increments; reset per case so
    # the function's own `[ "$FAIL" -ne 0 ]` semantics are observable in isolation.
    FAIL=0
    lint_probe_set_flags >/dev/null 2>&1
    # The function returns nonzero when it found a violation (FAIL incremented).
    echo "$FAIL"
  )
  rc=$?
  rm -rf "$repo"
  if [ "$rc" -ne 0 ]; then
    echo "FIXTURE-ERROR-rc-$rc"
  fi
}

# WR-02 honest-return runner (Phase 20 code-review follow-up): POISON the shared
# FAIL accumulator BEFORE the call, run the function over a NO-VIOLATION fixture,
# and echo the function's OWN return code ($?), not global FAIL. With the WR-02
# fix the function returns 0 (it found nothing) even though FAIL was already 1;
# the pre-fix code returned nonzero because it read the global FAIL for its verdict.
run_lint_rc_poisoned_fail() {
  local setup_fn="$1"; shift
  local repo rc
  repo=$(mktemp -d)
  (
    cd "$repo" || exit 99
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    mkdir -p tests/probes docs
    "$setup_fn" "$@"
    FAIL=1                              # poison: unrelated earlier check failed
    lint_probe_set_flags >/dev/null 2>&1
    echo "$?"                           # the function's OWN return, not global FAIL
  )
  rc=$?
  rm -rf "$repo"
  if [ "$rc" -ne 0 ]; then
    echo "FIXTURE-ERROR-rc-$rc"
  fi
}

# A probe body that DOES enable errexit (legitimate save/restore pair).
ERREXIT_BODY='#!/bin/bash
set -euo pipefail
echo "guarded probe"'

# A probe body with errexit + a newly-added set +e (legit save/restore).
ERREXIT_PLUS_SETPLUSE_BODY='#!/bin/bash
set -euo pipefail
set +e
risky_command || true
set -e
echo "restored"'

# A probe body with NO errexit and a bare set +e (the WR-04 no-op anti-pattern).
NOEXIT_SETPLUSE_BODY='#!/bin/bash
set -uo pipefail
set +e
echo "no-op set +e"'

# A probe body with `set -ue` (e-not-first) + set +e — D-10 hardened-regex case.
SETUE_SETPLUSE_BODY='#!/bin/bash
set -ue
set +e
risky || true'

# ---------------------------------------------------------------------------
# Case 1: NEW probe file added with a bare `set +e` and NO `set -e` → lint FAILS
# ---------------------------------------------------------------------------

setup_case1_new_add() {
  printf '%s\n' "$NOEXIT_SETPLUSE_BODY" > tests/probes/probe-new-noop.sh
  git add tests/probes/probe-new-noop.sh
}

test_case1_new_add_fails() {
  echo "Case 1: NEW probe file with bare set +e (no set -e) → lint FAILS"
  local out
  out=$(run_lint_in_fixture setup_case1_new_add)
  if [ "$out" = "1" ]; then
    PASS=$((PASS + 1)); echo "  PASS: 1: new-file add of bare set +e is blocked"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: 1: expected FAIL=1, got '$out'"
  fi
}

# ---------------------------------------------------------------------------
# Case 2: MODIFIED existing probe with a newly-added `set +e`, no `set -e` → FAILS
# ---------------------------------------------------------------------------

setup_case2_modified_add() {
  # Commit a clean probe first (no set +e), then add set +e and stage the mod.
  printf '%s\n' '#!/bin/bash' 'set -uo pipefail' 'echo "clean"' \
    > tests/probes/probe-existing.sh
  git add tests/probes/probe-existing.sh
  git commit -qm "seed clean probe"
  printf '%s\n' '#!/bin/bash' 'set -uo pipefail' 'set +e' 'echo "added no-op"' \
    > tests/probes/probe-existing.sh
  git add tests/probes/probe-existing.sh
}

test_case2_modified_add_fails() {
  echo "Case 2: MODIFIED probe newly adds set +e (no set -e) → lint FAILS"
  local out
  out=$(run_lint_in_fixture setup_case2_modified_add)
  if [ "$out" = "1" ]; then
    PASS=$((PASS + 1)); echo "  PASS: 2: modified-file add of set +e is blocked"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: 2: expected FAIL=1, got '$out'"
  fi
}

# ---------------------------------------------------------------------------
# Case 3: pre-existing `set +e` in an UNMODIFIED probe (not staged) → PASSES
#         (staged-diff scoped — proves the 20× baseline is unaffected)
# ---------------------------------------------------------------------------

setup_case3_preexisting_unmodified() {
  # Commit a probe that ALREADY carries set +e (no set -e), then stage an
  # UNRELATED change. The pre-existing set +e is not in the staged diff.
  printf '%s\n' "$NOEXIT_SETPLUSE_BODY" > tests/probes/probe-baseline.sh
  git add tests/probes/probe-baseline.sh
  git commit -qm "seed baseline probe with pre-existing set +e"
  # Stage an unrelated docs change — no tests/probes/ candidate.
  printf '%s\n' "doc edit" > docs/note.md
  git add docs/note.md
}

test_case3_preexisting_passes() {
  echo "Case 3: pre-existing set +e in UNMODIFIED probe → lint PASSES (staged-diff scoped)"
  local out
  out=$(run_lint_in_fixture setup_case3_preexisting_unmodified)
  if [ "$out" = "0" ]; then
    PASS=$((PASS + 1)); echo "  PASS: 3: pre-existing baseline set +e not retroactively blocked"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: 3: expected FAIL=0, got '$out'"
  fi
}

# ---------------------------------------------------------------------------
# Case 4: probe with BOTH `set -e` AND a newly-added `set +e` → PASSES
#         (full-content errexit gate skips legitimate save/restore — the
#         load-bearing false-positive guard)
# ---------------------------------------------------------------------------

setup_case4_errexit_pair() {
  printf '%s\n' "$ERREXIT_PLUS_SETPLUSE_BODY" > tests/probes/probe-pair.sh
  git add tests/probes/probe-pair.sh
}

test_case4_errexit_pair_passes() {
  echo "Case 4: probe with set -e + set +e (save/restore) → lint PASSES (full-content gate)"
  local out
  out=$(run_lint_in_fixture setup_case4_errexit_pair)
  if [ "$out" = "0" ]; then
    PASS=$((PASS + 1)); echo "  PASS: 4: legitimate set -e+set +e pair not blocked"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: 4: expected FAIL=0, got '$out'"
  fi
}

# ---------------------------------------------------------------------------
# Case 5: docs-only commit (no tests/probes/ staged) → PASSES AND does not
#         early-exit under errexit (D-10 — every match-nothing op carries
#         `|| true`; the regression net for the Codex-HIGH empty-match abort)
# ---------------------------------------------------------------------------

setup_case5_docs_only() {
  printf '%s\n' "docs only, no probe changes" > docs/changelog.md
  git add docs/changelog.md
}

test_case5_docs_only_passes() {
  echo "Case 5: docs-only commit (no probe candidates) → lint PASSES, no errexit early-exit (D-10)"
  local out
  out=$(run_lint_in_fixture setup_case5_docs_only)
  # A FIXTURE-ERROR-rc-* return here would mean the function aborted under the
  # host errexit on the empty candidate set — exactly the D-10 failure mode.
  if [ "$out" = "0" ]; then
    PASS=$((PASS + 1)); echo "  PASS: 5: docs-only commit clean and did not early-exit"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: 5: expected FAIL=0 (no early-exit), got '$out'"
  fi
}

# ---------------------------------------------------------------------------
# Case 6: DHX_RED_COMMIT=1 fire-through — the lint still FAILS case 1 even when
#         DHX_RED_COMMIT is set (it's a code-quality lint, placed before the
#         opt-out branch — it must NOT be skipped on TDD-RED commits)
# ---------------------------------------------------------------------------

test_case6_red_commit_fires() {
  echo "Case 6: DHX_RED_COMMIT=1 set → lint still FAILS a new bare set +e (fire-through)"
  local out
  out=$(DHX_RED_COMMIT=1 run_lint_in_fixture setup_case1_new_add)
  if [ "$out" = "1" ]; then
    PASS=$((PASS + 1)); echo "  PASS: 6: lint fires even under DHX_RED_COMMIT=1"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: 6: expected FAIL=1 under DHX_RED_COMMIT=1, got '$out'"
  fi
}

# ---------------------------------------------------------------------------
# Case 7: `set -ue` (e-not-first) + a newly-added set +e → PASSES
#         (D-10 hardened flag-order-agnostic errexit regex residual case)
# ---------------------------------------------------------------------------

setup_case7_setue_pair() {
  printf '%s\n' "$SETUE_SETPLUSE_BODY" > tests/probes/probe-setue.sh
  git add tests/probes/probe-setue.sh
}

test_case7_setue_pair_passes() {
  echo "Case 7: probe with set -ue (e-not-first) + set +e → lint PASSES (D-10 hardened regex)"
  local out
  out=$(run_lint_in_fixture setup_case7_setue_pair)
  if [ "$out" = "0" ]; then
    PASS=$((PASS + 1)); echo "  PASS: 7: set -ue errexit form recognized, pair not blocked"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: 7: expected FAIL=0, got '$out'"
  fi
}

# ---------------------------------------------------------------------------
# Case 8: WR-02 honest return — with the shared FAIL accumulator already poisoned
#         to 1 (an unrelated earlier check failed) and a NO-VIOLATION fixture,
#         the function must RETURN 0 (its own verdict). The pre-WR-02 code read
#         global FAIL for its return and would report a set+e violation it never
#         found — a false contract masked only by the `|| true` at the call site.
# ---------------------------------------------------------------------------

test_case8_honest_return() {
  echo "Case 8: WR-02 — poisoned FAIL=1 + no-violation fixture → function RETURNS 0 (own result)"
  local out
  out=$(run_lint_rc_poisoned_fail setup_case4_errexit_pair)
  if [ "$out" = "0" ]; then
    PASS=$((PASS + 1)); echo "  PASS: 8: lint returns its own clean verdict despite pre-set FAIL=1"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL: 8: expected rc 0 (honest return), got '$out' (false contract — WR-02 regressed)"
  fi
}

# ---------------------------------------------------------------------------
# Run all cases
# ---------------------------------------------------------------------------

echo "=== probe set +e discipline lint tests (CAL-POLISH-05) ==="
echo ""

test_case1_new_add_fails
echo ""
test_case2_modified_add_fails
echo ""
test_case3_preexisting_passes
echo ""
test_case4_errexit_pair_passes
echo ""
test_case5_docs_only_passes
echo ""
test_case6_red_commit_fires
echo ""
test_case7_setue_pair_passes
echo ""
test_case8_honest_return
echo ""

print_results
