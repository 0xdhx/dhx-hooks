#!/usr/bin/env bash
# probe-execute-stop-review-state-allowlist.sh
#
# Regression probe for the STATE.md phase allowlist in dhx/dhx-execute-stop-review.sh
# (the HP-005/HP-006 cross-reference gate, ~lines 79-104). The sibling
# probe-execute-stop-review.sh DELIBERATELY omits STATE.md to isolate the
# line-39/53 pipefail paths; this probe covers the orthogonal concern those
# scenarios skip — that the allowlist, built against the CURRENT GSD SDK
# (`gsd-sdk query phase.complete`) STATE.md output shape, still captures the
# just-completed phase.
#
# Why this exists (HP-006 drift, reverified 2026-05-21): GSD v1.42.3 moved the
# completion string off `Last Activity Description` (the deprecated CJS carrier)
# onto `stopped_at:` (frontmatter) + `Current focus:` (body), while `Current
# Phase` still advances to X+1. The parser must still allowlist the just-
# completed phase X. This probe pins that invariant against an SDK-shaped
# post-completion STATE.md so a FUTURE GSD output-shape change that breaks
# phase-X recovery fails loudly here instead of silently suppressing the
# execute-review safety net.
#
# Scenarios (STATE.md says: just completed phase 27, Current Phase now 28):
#   [A] full SDK shape (stopped_at names "Phase 27 complete" AND Current Phase
#       advanced to 28); fresh VERIFICATION+SUMMARY in phase 27 → review FIRES.
#       27 is in the allowlist via BOTH routes.
#   [B] same STATE; fresh VERIFICATION+SUMMARY in UNRELATED phase 5 → review
#       SKIPS. Negative control: proves the allowlist actually filters rather
#       than always-firing (5 not in {26,27,28}).
#   [C] N-1 route ISOLATED — stopped_at does NOT name the completed phase (as if
#       written by `state record-session`), only `Current Phase: 28` carries the
#       advance; fresh VERIFICATION+SUMMARY in phase 27 → review FIRES. Proves
#       the load-bearing invariant (Current Phase advance → N-1 union recovers
#       X) holds independent of which field carries the completion string — the
#       exact property that let the parsers survive the CJS→SDK carrier move.
#
# Backs:
#   - docs/hook-patterns.md — HP-006 (SDK completion mechanism, 2026-05-21 reverify)
#   - docs/decisions.md — 2026-05-21 HP-006 completion-mechanism drift row
#
# Run: bash tests/probes/probe-execute-stop-review-state-allowlist.sh

# SAFE_FOR_LIVE: yes  (per-scenario mktemp fixture + isolated subprocess; cwd points at $TMP via stdin payload; no live writes)
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$REPO_ROOT/dhx/dhx-execute-stop-review.sh"

if [ ! -r "$HOOK" ]; then echo "FAIL hook not readable: $HOOK"; exit 1; fi
if ! command -v jq >/dev/null 2>&1; then echo "FAIL jq required but not installed"; exit 1; fi

PASS=0
FAIL=0

# Marker that satisfies the execute-session gate (line 39).
EXEC_MARKER='Agent dispatched: gsd-executor for phase 27'

# Write an SDK-shaped STATE.md AFTER `gsd-sdk query phase.complete 27`:
# Current Phase advanced 27 -> 28; completion string lives in stopped_at +
# Current focus; Last Activity Description left STALE (the SDK does not write it
# in phase-complete). $1=dir  $2=mode (full|n1only).
write_sdk_state() {
  local dir="$1" mode="$2" stopped
  mkdir -p "$dir/.planning"
  if [ "$mode" = "n1only" ]; then
    # stopped_at as a session-end marker that does NOT name the completed phase,
    # forcing phase-27 recovery to depend solely on Current Phase=28 -> N-1.
    stopped="session ended"
  else
    stopped="Phase 27 complete (2/2) — ready to discuss Phase 28"
  fi
  cat > "$dir/.planning/STATE.md" <<EOF
---
status: ready_to_plan
milestone: v1
total_phases: 30
completed_phases: 27
total_plans: 60
completed_plans: 54
percent: 90
last_updated: 2026-05-21T00:00:00.000Z
stopped_at: $stopped
---

# Project State

**Current Phase:** 28 of 30 (next-thing)
**Status:** Ready to plan
**Current Plan:** Not started
**Current focus:** Phase 28 — next-thing
**Last Activity:** 2026-05-21
**Last Activity Description:** earlier project work recorded (stale, no phase ref)
EOF
}

# Build a fixture CWD with fresh VERIFICATION+SUMMARY in one phase dir.
# $1=phase-dir-name  $2=plan-id  $3=state-mode  -> echoes the CWD path.
build_fixture() {
  local phase_dir_name="$1" plan_id="$2" mode="$3" cwd pdir
  cwd=$(mktemp -d /tmp/probe-stop-review-allowlist.XXXXXX)
  pdir="$cwd/.planning/phases/$phase_dir_name"
  mkdir -p "$pdir"
  touch "$pdir/${plan_id}-VERIFICATION.md" "$pdir/${plan_id}-SUMMARY.md"
  write_sdk_state "$cwd" "$mode"
  echo "$cwd"
}

run_hook() {
  local cwd="$1" transcript
  transcript="user prompt: run /dhx:execute 27
$EXEC_MARKER
done."
  jq -n --arg t "$transcript" --arg c "$cwd" \
    '{transcript:$t, cwd:$c, stop_hook_active:false}' | bash "$HOOK"
}

assert_blocks() {
  local label="$1" output="$2"
  if grep -q '"decision": *"block"' <<< "$output" \
     && grep -q 'EXECUTION REVIEW NOT COMPLETED' <<< "$output"; then
    echo "OK   $label (block JSON emitted)"; PASS=$((PASS+1))
  else
    echo "FAIL $label — expected block JSON, got: $(printf '%s' "$output" | head -c 200)"; FAIL=$((FAIL+1))
  fi
}

assert_silent() {
  local label="$1" output="$2"
  if [ -z "$output" ]; then
    echo "OK   $label (no output — review skipped as expected)"; PASS=$((PASS+1))
  else
    echo "FAIL $label — expected no output, got: $(printf '%s' "$output" | head -c 200)"; FAIL=$((FAIL+1))
  fi
}

# --- [A] just-completed phase 27, full SDK shape → review FIRES ---
CWD_A=$(build_fixture "27-test-phase" "27" "full")
OUT_A=$(run_hook "$CWD_A")
assert_blocks "[A] SDK STATE (Current Phase=28); VERIFICATION in just-completed phase 27 → fires (27 in allowlist: stopped_at + N-1)" "$OUT_A"
rm -rf "$CWD_A"

# --- [B] unrelated phase 5 → review SKIPS (negative control) ---
CWD_B=$(build_fixture "05-old-phase" "05" "full")
OUT_B=$(run_hook "$CWD_B")
assert_silent "[B] same SDK STATE; VERIFICATION in unrelated phase 5 → skips (5 not in {26,27,28})" "$OUT_B"
rm -rf "$CWD_B"

# --- [C] N-1 route isolated (stopped_at silent on phase) → review FIRES ---
CWD_C=$(build_fixture "27-test-phase" "27" "n1only")
OUT_C=$(run_hook "$CWD_C")
assert_blocks "[C] stopped_at does NOT name phase; only Current Phase=28 → fires (27 recovered via N-1 union alone — load-bearing invariant)" "$OUT_C"
rm -rf "$CWD_C"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
