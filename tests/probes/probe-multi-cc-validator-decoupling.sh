#!/bin/bash
# probe-multi-cc-validator-decoupling.sh
#
# SAFE_FOR_LIVE: yes  (fully mktemp-isolated; copies run-probes.sh +
#                      verify-multi-cc-results.sh + verify-hook-patterns.sh into
#                      throwaway REPO-shaped trees and throwaway git repos;
#                      never touches the live repo, ~/.claude, or ~/.cache/dhx)
# RUNTIME: ~6s
#
# INVARIANT: the multi-cc corpus validator never shares the probe tier's FAIL
# counter, and its blocking authority lives at the event that OWNS the corpus
# invariant — staging a corpus cell — not at "an unrelated probe tier ran".
#
#   A. Green tier + an invalid UNSTAGED corpus cell  -> run-probes exits 0,
#      prints "0 failed", prints NO `red:` line, and prints an advisory NOTE
#      naming the offending file. Summary, roster and exit status AGREE.
#   B. Same under --stamp -> status.json "failing": [] AND exit 0. (Before this
#      fix the stamp recorded [] on a run that exited 1, so check #8c's
#      outstanding-failures branch stayed silent -- confirmed by execution
#      2026-08-23, the brief's "fourth consequence".)
#   C. Red tier + an invalid corpus cell -> exit 1 with the roster naming ONLY
#      the red probe. The validator must not inflate the probe FAIL count.
#   D. A commit that STAGES an invalid corpus cell is BLOCKED, and the block
#      message names the cell.
#   E. A commit that stages a VALID cell while an invalid UNSTAGED orphan sits
#      in the same directory is NOT blocked. The gate reads the INDEX, never the
#      worktree -- this is the exact shape that blocked every probe-touching
#      commit repo-wide on 2026-07-09 and again on 2026-08-23.
#
# Backs:
#   - .planning/backlog/2026-08-23-run-probes-folds-unrelated-validator-into-tier-exit.md
#   - docs/backlog.md row `natural-heal-probes-write-forbidden-conclusion` (sibling half)
#
# The planted cell uses conclusion "banana" -- deliberately NOT `skipped`. The
# companion taxonomy fix (probe-conclusion-taxonomy.sh) makes `skipped` a VALID
# token, so a `skipped` fixture here would silently stop testing anything.
#
# Run: bash tests/probes/probe-multi-cc-validator-decoupling.sh
#
# CC-STDERR-EXEMPT: the only Claude Code invocation here is
#   `claude --version 2>/dev/null` — stderr is DISCARDED at the call site, so no
#   settings-lint line can reach any classifier. Measured 2026-09-18: every
#   `claude` occurrence in this file is either that redirected call or a comment.
#   Convention: tests/probes/README.md § "A classifier's INPUT is a surface too".
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
PASS=0
FAIL=0
TMPS=()

cleanup() { local t; for t in "${TMPS[@]:-}"; do [ -n "$t" ] && rm -rf "$t"; done; }
trap cleanup EXIT

assert() {
  local name="$1" cond="$2"
  if [[ "$cond" == "true" ]]; then echo "OK   $name"; PASS=$((PASS+1))
  else echo "FAIL $name"; FAIL=$((FAIL+1)); fi
}

ACTIVE_CC=$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
if [[ -z "$ACTIVE_CC" ]]; then
  echo "SKIP probe-multi-cc-validator-decoupling: no resolvable CC version — run-probes.sh"
  echo "     skips the validator entirely when active_cc is 'unknown', so every case here"
  echo "     would pass vacuously. Not a pass; re-run where \`claude --version\` resolves."
  exit 0
fi

# cell_json <conclusion> — a corpus cell valid in every field EXCEPT (maybe) .conclusion
cell_json() {
  printf '{"probe_id":"probe-known-marketplaces-natural-heal","exit_code":2,'
  printf '"exit_code_convention":"exit_0_means_v1_2_work_warranted",'
  printf '"cc_version":"%s","cc_version_match":true,"conclusion":"%s"}\n' "$ACTIVE_CC" "$1"
}

# ---- runner sandbox: REPO-shaped tree, one fixture probe, one planted cell ----
# build_runner_sandbox <probe_exit_rc> <conclusion>
build_runner_sandbox() {
  local rc="$1" conc="$2" t
  t=$(mktemp -d); TMPS+=("$t")
  mkdir -p "$t/scripts" "$t/tests/probes" "$t/tests/probes/.results/v1.3-multi-cc-ver/$ACTIVE_CC"
  cp "$REPO/scripts/run-probes.sh" "$t/scripts/"
  cp "$REPO/scripts/verify-multi-cc-results.sh" "$t/scripts/"
  chmod +x "$t/scripts/verify-multi-cc-results.sh"
  printf '#!/bin/bash\n# SAFE_FOR_LIVE: yes\n# LIVE_RUNTIME: no\nexit %s\n' "$rc" \
    > "$t/tests/probes/probe-fixture-decoupling.sh"
  chmod +x "$t/tests/probes/probe-fixture-decoupling.sh"
  cell_json "$conc" \
    > "$t/tests/probes/.results/v1.3-multi-cc-ver/$ACTIVE_CC/probe-known-marketplaces-natural-heal.json"
  printf '%s' "$t"
}

echo "=== A/B/C: the runner must never fold the validator into the probe FAIL counter ==="

# ---- CASE A: green tier + invalid cell -> exit 0, agreeing signals ----------
TA=$(build_runner_sandbox 0 banana)
OUT_A=$(cd "$TA" && bash scripts/run-probes.sh --filter SAFE_FOR_LIVE=yes --filter LIVE_RUNTIME=no 2>&1); RC_A=$?
assert "A: green tier + invalid corpus cell -> run-probes exits 0" \
  "$([[ "$RC_A" -eq 0 ]] && echo true || echo false)"
assert "A: summary reports 0 failed" \
  "$(grep -qE '^Probes: [0-9]+ passed, 0 failed' < <(printf '%s' "$OUT_A") && echo true || echo false)"
assert "A: no \`red:\` roster line (nothing red to name)" \
  "$(grep -q '^  red:' < <(printf '%s' "$OUT_A") && echo false || echo true)"
assert "A: an advisory NOTE is printed" \
  "$(grep -q 'NOTE: multi-cc corpus validator' < <(printf '%s' "$OUT_A") && echo true || echo false)"
assert "A: the NOTE names the offending cell file" \
  "$(grep -q 'probe-known-marketplaces-natural-heal.json' < <(printf '%s' "$OUT_A") && echo true || echo false)"
assert "A: the NOTE states the probe tier itself PASSED" \
  "$(grep -qi 'tier .*passed\|passed.*tier' < <(printf '%s' "$OUT_A") && echo true || echo false)"

# ---- CASE B: --stamp accounting agrees with the exit status -----------------
TB=$(build_runner_sandbox 0 banana)
OUT_B=$(cd "$TB" && bash scripts/run-probes.sh --filter SAFE_FOR_LIVE=yes --filter LIVE_RUNTIME=no --stamp 2>&1); RC_B=$?
STAMP_B="$TB/tests/probes/.results/live-tier/status.json"
FAILING_B=$(jq -c '.failing' "$STAMP_B" 2>/dev/null || echo '"<unreadable>"')
assert "B: --stamp run exits 0 (validator no longer bumps FAIL)" \
  "$([[ "$RC_B" -eq 0 ]] && echo true || echo false)"
assert "B: status.json failing[] is empty AND the run agrees (exit 0)" \
  "$([[ "$FAILING_B" == "[]" && "$RC_B" -eq 0 ]] && echo true || echo false)"

# ---- CASE C: red tier -> exit 1, roster names ONLY the red probe ------------
TC=$(build_runner_sandbox 1 banana)
OUT_C=$(cd "$TC" && bash scripts/run-probes.sh --filter SAFE_FOR_LIVE=yes --filter LIVE_RUNTIME=no 2>&1); RC_C=$?
SUMFAIL_C=$(printf '%s' "$OUT_C" | grep -oE '^Probes: [0-9]+ passed, [0-9]+ failed' | grep -oE '[0-9]+ failed' | grep -oE '^[0-9]+')
assert "C: red tier exits 1" "$([[ "$RC_C" -eq 1 ]] && echo true || echo false)"
assert "C: summary FAIL count is 1 — the validator did not inflate it" \
  "$([[ "${SUMFAIL_C:-0}" -eq 1 ]] && echo true || echo false)"
assert "C: roster names the red probe" \
  "$(grep -q '^  red: probe-fixture-decoupling.sh' < <(printf '%s' "$OUT_C") && echo true || echo false)"

echo
echo "=== D/E: corpus blocking authority lives at STAGING a cell, and reads the INDEX ==="

# ---- git sandbox for the staged-corpus gate --------------------------------
# build_git_sandbox — throwaway git repo carrying the gate + the two scripts it
# drives. No hooks installed: the probe invokes verify-hook-patterns.sh directly,
# which is the unit under test (git would invoke it via the dispatcher).
build_git_sandbox() {
  local t; t=$(mktemp -d); TMPS+=("$t")
  mkdir -p "$t/scripts" "$t/tests/probes" "$t/docs"
  cp "$REPO/scripts/verify-hook-patterns.sh" "$t/scripts/"
  cp "$REPO/scripts/run-probes.sh" "$t/scripts/"
  cp "$REPO/scripts/verify-multi-cc-results.sh" "$t/scripts/"
  chmod +x "$t/scripts/verify-hook-patterns.sh" "$t/scripts/verify-multi-cc-results.sh"
  : > "$t/docs/hook-patterns.md"
  : > "$t/docs/decisions.md"
  # Satisfy check #8c (live-tier freshness) so the ONLY thing that can block in
  # this fixture is the corpus gate. Without this the sandbox has no live-tier
  # stamp, #8c blocks on the installed gsd-core version, and both cases below
  # would pass for entirely the wrong reason.
  mkdir -p "$t/tests/probes/.results/live-tier"
  _gsdv="absent"
  [ -r "$HOME/.claude/gsd-core/VERSION" ] && _gsdv=$(tr -d '[:space:]' < "$HOME/.claude/gsd-core/VERSION")
  printf '{"gsd_version":"%s","ran_at":"1970-01-01T00:00:00Z","passed":0,"failing":[]}\n' \
    "$_gsdv" > "$t/tests/probes/.results/live-tier/status.json"
  git -C "$t" init -q
  git -C "$t" config user.email p@example.invalid
  git -C "$t" config user.name Probe
  git -C "$t" add -A >/dev/null 2>&1
  git -C "$t" commit -q -m "base" --no-verify >/dev/null 2>&1
  printf '%s' "$t"
}

CELLDIR="tests/probes/.results/v1.3-multi-cc-ver/$ACTIVE_CC"

# ---- CASE D: staging an INVALID cell blocks --------------------------------
TD=$(build_git_sandbox)
mkdir -p "$TD/$CELLDIR"
cell_json banana > "$TD/$CELLDIR/probe-known-marketplaces-natural-heal.json"
git -C "$TD" add -f "$CELLDIR/probe-known-marketplaces-natural-heal.json" >/dev/null 2>&1
OUT_D=$(cd "$TD" && bash scripts/verify-hook-patterns.sh 2>&1); RC_D=$?
assert "D: staging an invalid corpus cell BLOCKS the commit" \
  "$([[ "$RC_D" -ne 0 ]] && echo true || echo false)"
assert "D: it blocks on the CORPUS gate specifically, not some other check" \
  "$(grep -q 'BLOCKED: a multi-cc corpus cell staged in this commit' < <(printf '%s' "$OUT_D") && echo true || echo false)"
assert "D: the block message names the offending cell" \
  "$(grep -q 'probe-known-marketplaces-natural-heal.json' < <(printf '%s' "$OUT_D") && echo true || echo false)"

# ---- CASE E: a VALID staged cell + an INVALID UNSTAGED orphan does NOT block -
# This is the regression that cost the repo two incidents: the orphan is
# machine-local, was never staged, and carries no evidentiary weight.
TE=$(build_git_sandbox)
mkdir -p "$TE/$CELLDIR"
cell_json validated_stable > "$TE/$CELLDIR/probe-effort-level-stdin-absent.json"
git -C "$TE" add -f "$CELLDIR/probe-effort-level-stdin-absent.json" >/dev/null 2>&1
cell_json banana > "$TE/$CELLDIR/probe-known-marketplaces-natural-heal.json"   # UNSTAGED orphan
OUT_E=$(cd "$TE" && bash scripts/verify-hook-patterns.sh 2>&1); RC_E=$?
assert "E: a valid staged cell commits despite an invalid UNSTAGED orphan" \
  "$([[ "$RC_E" -eq 0 ]] && echo true || echo false)"
assert "E: nothing BLOCKED at all" \
  "$(grep -q 'BLOCKED' < <(printf '%s' "$OUT_E") && echo false || echo true)"
# The orphan IS still surfaced — as an ADVISORY NOTE from the worktree-scoped
# validator inside check #8a's tier run. That is the design: visible, never
# blocking. Asserting it is never mentioned would contradict the NOTE.
assert "E: the orphan surfaces as an advisory NOTE, not as a blocker" \
  "$(grep -q 'NOTE: multi-cc corpus validator' < <(printf '%s' "$OUT_E") && echo true || echo false)"

echo "---"
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
