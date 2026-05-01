#!/usr/bin/env bash
# probe-execute-stop-review.sh
#
# Regression probe for dhx/dhx-execute-stop-review.sh transcript-scanning gates
# (lines 39 + 53). Both gates were originally `echo "$TRANSCRIPT" | grep -q…`
# pipelines on a `.transcript` JSON field that can exceed the 64 KiB Linux pipe
# buffer. Under `set -o pipefail`, the broken shape silently drops the match
# (HP-028: grep -q exits early → echo SIGPIPEs → pipeline returns 141 →
# pipefail propagates → if-condition flips). Round 2 of the HP-028 sweep
# (2026-04-28) replaced both with here-string `grep -q PAT <<< "$VAR"`, which
# keeps the LHS out of the pipefail-watched pipeline.
#
# Scenarios:
#   [1] small transcript with execute markers → review fires (block JSON)
#   [2] execute markers + 256 KiB post-match line → review STILL fires under
#       enforced pipefail. Differentiates broken-vs-fixed for line 39: under
#       the broken `echo … | grep -q` shape, pipefail+SIGPIPE on the LHS would
#       flip the `! if` and skip review (output empty); under the fixed
#       here-string, line 39 falls through and the block-JSON is emitted.
#   [3] already-reviewed markers + 256 KiB padding → review SKIPS. Positive
#       assertion that the fixed line 53 correctly recognizes the
#       already-reviewed transcript at overflow size. Note: the line-39 bug
#       masks the line-53 bug under broken pipefail (line 39 SIGPIPEs first
#       and exits 0 before line 53 runs), so scenario [3] does not by itself
#       differentiate broken-vs-fixed on line 53. It still asserts the fixed
#       behavior is correct, which round 2's commit message commits us to.
#
# The probe enforces pipefail via `bash -o pipefail HOOK` so the regression
# mechanism reproduces deterministically even though the hook's own shebang
# does not set pipefail today. This protects against a future change adding
# `set -o pipefail` to the hook re-introducing the broken behavior.
#
# Backs:
#   - docs/decisions.md — 2026-04-28 SIGPIPE+pipefail audit sweep round 2 row
#   - docs/hook-patterns.md — HP-028 (round-2 fixed list)
#
# Run: bash tests/probes/probe-execute-stop-review.sh

# SAFE_FOR_LIVE: yes   (mktemp + isolated subprocess invocation of hook with HOME=$TMP; no live writes)
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$REPO_ROOT/dhx/dhx-execute-stop-review.sh"

if [ ! -r "$HOOK" ]; then
  echo "FAIL hook not readable: $HOOK"
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL jq required but not installed"
  exit 1
fi

TMP=$(mktemp -d /tmp/probe-execute-stop-review.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

# --- Fixture setup ---
# .planning/phases/27-foo/{27-VERIFICATION.md, 27-SUMMARY.md} both freshly
# touched so the -mmin gates pass. STATE.md intentionally absent so the
# allowlist check (line 79+) is skipped — we want to drive the test through
# the line-39 / line-53 paths only.
PHASE_DIR="$TMP/.planning/phases/27-test-phase"
mkdir -p "$PHASE_DIR"
touch "$PHASE_DIR/27-VERIFICATION.md" "$PHASE_DIR/27-SUMMARY.md"

# Build a 256 KiB padding line — guarantees SIGPIPE on the broken shape under
# pipefail (mirrors probe-restart-plugins-stop-hook.sh scenario [12]).
BIG_LINE=$(printf 'x%.0s' {1..262144})

# Marker that triggers line 39's "is this an execute session?" check.
EXEC_MARKER='Agent dispatched: gsd-executor for phase 27'

# Marker that triggers line 53's "already reviewed" check.
REVIEWED_MARKER='Performed plan-to-execution fidelity check; verified context-to-code fidelity.'

run_hook_pipefail() {
  local payload="$1"
  bash -o pipefail "$HOOK" <<< "$payload"
}

build_payload() {
  local transcript="$1"
  local tfile="$TMP/transcript.txt"
  printf '%s' "$transcript" > "$tfile"
  # --rawfile reads the file as a literal string and JSON-escapes it, avoiding
  # the ARG_MAX limit that --arg hits with 256 KiB inputs.
  jq -n \
    --rawfile t "$tfile" \
    --arg c "$TMP" \
    '{transcript:$t, cwd:$c, stop_hook_active:false}'
}

# Refresh fixture mtimes between scenarios so -mmin -15 / -mmin -30 hold.
refresh_fixtures() {
  touch "$PHASE_DIR/27-VERIFICATION.md" "$PHASE_DIR/27-SUMMARY.md"
}

assert_blocks() {
  local label="$1" output="$2"
  if grep -q '"decision": *"block"' <<< "$output" \
     && grep -q 'EXECUTION REVIEW NOT COMPLETED' <<< "$output"; then
    echo "OK   $label (block JSON emitted)"
    PASS=$((PASS + 1))
  else
    echo "FAIL $label — expected block JSON, got: $(printf '%s' "$output" | head -c 200)"
    FAIL=$((FAIL + 1))
  fi
}

assert_silent() {
  local label="$1" output="$2"
  if [ -z "$output" ]; then
    echo "OK   $label (no output — review skipped as expected)"
    PASS=$((PASS + 1))
  else
    echo "FAIL $label — expected no output, got: $(printf '%s' "$output" | head -c 200)"
    FAIL=$((FAIL + 1))
  fi
}

# --- Scenario [1]: small transcript with execute markers → review fires ---
refresh_fixtures
TRANSCRIPT_1="user prompt: run /dhx:execute 27
$EXEC_MARKER
done."
PAYLOAD_1=$(build_payload "$TRANSCRIPT_1")
OUTPUT_1=$(run_hook_pipefail "$PAYLOAD_1")
assert_blocks "[1] small transcript + execute markers → review fires" "$OUTPUT_1"

# --- Scenario [2]: execute markers + 256 KiB padding → review STILL fires ---
# Under the broken `echo "$TRANSCRIPT" | grep -qiE EXEC_PAT` shape with
# pipefail enforced, SIGPIPE would flip the `if !` and silently exit 0 at
# line 39 (skipping review). The here-string fix preserves correct behavior.
refresh_fixtures
TRANSCRIPT_2="$EXEC_MARKER
$BIG_LINE
trailing tail content"
PAYLOAD_2=$(build_payload "$TRANSCRIPT_2")
OUTPUT_2=$(run_hook_pipefail "$PAYLOAD_2")
assert_blocks "[2] execute markers + 256 KiB padding (pipefail) → review STILL fires (line 39 regression)" "$OUTPUT_2"

# --- Scenario [3]: already-reviewed markers + 256 KiB padding → review SKIPS ---
# Positive assertion of line-53 correctness at overflow size. See header note
# on broken-vs-fixed differentiation.
refresh_fixtures
TRANSCRIPT_3="$EXEC_MARKER
$REVIEWED_MARKER
$BIG_LINE
trailing tail content"
PAYLOAD_3=$(build_payload "$TRANSCRIPT_3")
OUTPUT_3=$(run_hook_pipefail "$PAYLOAD_3")
assert_silent "[3] already-reviewed markers + 256 KiB padding (pipefail) → review SKIPS (line 53)" "$OUTPUT_3"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
