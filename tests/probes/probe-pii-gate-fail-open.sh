#!/usr/bin/env bash
# probe-pii-gate-fail-open.sh — BEHAVIOURAL assertion that every PII sanitizer
# gate in tests/probes/ actually refuses a large PII payload.
#
# SAFE_FOR_LIVE: yes   (reads in-repo probe files; executes each extracted guard
#                       region in a subshell against mktemp payloads. The region
#                       ends at its closing `fi` and never includes the guarded
#                       `jq -n > "$OUT_FILE"` write, so nothing is written.)
# RUNTIME: ~3s
#
# WHY THIS IS BEHAVIOURAL AND NOT A GREP. `tests/probes/README.md` § "A guard has
# two layers, and either can be a spelling" records three guard assertions in this
# repo found hollow on one day, every one green with a passing positive control.
# Its rule — "would an INVERTED guard pass this, not just a deleted one?" — kills
# the obvious static lint: a gate re-spelled as a pipeline keeps every token a
# grep would look for. So this probe asserts the BEHAVIOUR the guard produces:
# feed it PII, require the refusal.
#
# THE DEFECT GUARDED. The gate is
#     if grep -qE "(/home/|/Users/|$HOST)" <<<"$OBSERVATIONS"; then refuse; fi
# and its `echo "$OBSERVATIONS" | grep -qE ...` form (HP-028) FAILS OPEN under the
# probes' `set -o pipefail`: grep -q exits at the first complete matching line, echo
# takes SIGPIPE, the pipeline goes non-zero, the `if` reads FALSE, the refusal is
# SKIPPED and the write proceeds carrying the PII. Inverted — most likely to be
# bypassed when PII IS present and the payload is large. Two necessary legs, both
# measured 2026-09-17: SHAPE (the match must COMPLETE on an early line; a match
# inside one huge line forces a full drain and never fires) and SIZE (onset
# ~70-100 KB on this box, well past the 64 KiB pipe buffer, because grep reads in
# large chunks). See HP-028 and the 2026-09-17 docs/decisions.md rows.
#
# THREE CELLS PER GATE, and cell 1 is the point:
#   1. INSTRUMENT CONTROL — re-pipeline the live region and require it to FAIL
#      OPEN. This asserts, every run, that the payload is still firing-shaped at
#      this size on this machine. Without it a future grep/bash whose onset moved
#      would make cells 2-3 pass while testing nothing — which is exactly the
#      2026-09-17 failure (`~/repos/cross-repo/docs/research/2026-09-17-a-positive-
#      control-proves-the-instrument-not-the-aim.md`): a genuine positive control
#      proved the instrument worked and still cleared a live defect, because it
#      was aimed at the non-firing half of a discriminator nobody had named.
#   2. THE GATE REFUSES the same PII payload.
#   3. NO REGRESSION — a clean payload of the same size still passes.
#
# THE NET IS FAIL-CLOSED AND DOUBLE-ROUTED. Gates are discovered twice — by the
# refusal message and by the PII regex — and any disagreement is RED, so a gate
# re-spelled out of one route is caught by the other rather than becoming
# invisible. A candidate whose guard region cannot be resolved is RED, never a
# silent pass. This is the "net is a spelling" failure that let 46 exposed sites
# accumulate inside tests/probes/ while probe-sigpipe-pipefail-shapes.sh reported
# the HP-028 audit closed with an empty allowlist — its scan covers dhx/ only.
#
# Backs:
#   - docs/decisions.md — 2026-09-17 row (three fail-open PII sanitizer gates)
#   - docs/hook-patterns.md — HP-028
#
# Run: bash tests/probes/probe-pii-gate-fail-open.sh
# Exit 0 = every gate refuses, 1 = one or more failures.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROBE_DIR="$REPO_ROOT/tests/probes"
PASS=0; FAIL=0

ok()   { echo "OK   $*"; PASS=$((PASS+1)); }
bad()  { echo "FAIL $*"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Payloads. 200,015 bytes: measured 8/8 firing; 70,015 measured 0/1, so do NOT
# shrink this toward the 64 KiB pipe-buffer figure — a fixture built there does
# not fire and would enshrine a dead test.
# Firing SHAPE = a short match that COMPLETES on line 1, then multi-line bulk.
# ---------------------------------------------------------------------------
{ printf '/home/probe-fixture-leak\n'; for _ in $(seq 1 2500); do printf '%079d\n' 0; done; } > "$WORK/pii.txt"
{ printf 'no-sensitive-token-here\n';  for _ in $(seq 1 2500); do printf '%079d\n' 0; done; } > "$WORK/clean.txt"

# ---------------------------------------------------------------------------
# Discovery — two INDEPENDENT routes over tests/probes/*.sh, cross-checked.
# Route A keys on the refusal's own message; route B on the PII regex. A gate
# cannot be written without both, so a re-spelling that escapes one is caught by
# the other. Disagreement is RED.
# Process substitution, never a pipe: this probe must not trip the defect it guards.
# ---------------------------------------------------------------------------
mapfile -t ROUTE_A < <(grep -rl 'FATAL: observations contain PII' "$PROBE_DIR" --include='*.sh' 2>/dev/null | grep -v 'probe-pii-gate-fail-open.sh' | sort)
mapfile -t ROUTE_B < <(grep -rlE 'grep -qE "\(/home/\|/Users/' "$PROBE_DIR" --include='*.sh' 2>/dev/null | grep -v 'probe-pii-gate-fail-open.sh' | sort)

echo "### 1. Discovery net — two routes must agree (fail-closed)"
if [[ "${ROUTE_A[*]}" == "${ROUTE_B[*]}" ]]; then
  ok "discovery routes agree: ${#ROUTE_A[@]} PII gate(s) found"
else
  bad "discovery routes DISAGREE — a gate is invisible to one route"
  printf '     route A (refusal message): %s\n' "${ROUTE_A[@]#$REPO_ROOT/}"
  printf '     route B (PII regex):       %s\n' "${ROUTE_B[@]#$REPO_ROOT/}"
fi
if [[ "${#ROUTE_A[@]}" -eq 0 ]]; then
  bad "discovery found ZERO gates — the net is broken, not the population empty"
  echo; echo "$PASS passed, $FAIL failed"; exit 1
fi

# ---------------------------------------------------------------------------
# Extract one gate's region VERBATIM: the nearest preceding `HOST=` line through
# the closing `fi`. Verbatim matters — a transcribed copy would test this probe's
# idea of the gate rather than the shipped text.
# ---------------------------------------------------------------------------
extract_region() {
  local f="$1" gl sl el
  gl=$(grep -nE '^if (echo "\$OBSERVATIONS" \| )?grep -qE "\(/home/' "$f" | cut -d: -f1)
  [[ $(printf '%s' "$gl" | wc -w) -eq 1 ]] || return 1
  sl=$(awk -v g="$gl" 'NR<g && /^HOST=/{n=NR} END{print n+0}' "$f")
  [[ "$sl" -gt 0 ]] || return 1
  el=$(awk -v g="$gl" 'NR>=g && /^fi$/{print NR; exit}' "$f")
  [[ -n "$el" ]] || return 1
  sed -n "${sl},${el}p" "$f"
}

# Drive a region with a payload. Echoes REFUSED | ALLOWED | UNKNOWN.
drive() {
  local region="$1" payload="$2" runner="$WORK/run.sh" out
  { echo 'set -uo pipefail'
    echo 'OBSERVATIONS=$(cat "$1")'
    cat "$region"
    echo 'echo "WRITE-PROCEEDED"'
  } > "$runner"
  out=$(bash "$runner" "$payload" 2>&1)
  if   grep -qF 'FATAL: observations contain PII' <<<"$out"; then echo REFUSED
  elif grep -qF 'WRITE-PROCEEDED'                 <<<"$out"; then echo ALLOWED
  else echo "UNKNOWN"; fi
}

echo
echo "### 2. Behavioural cells — instrument control, refusal, no regression"
for f in "${ROUTE_A[@]}"; do
  rel="${f#$REPO_ROOT/}"

  if ! extract_region "$f" > "$WORK/region.txt"; then
    bad "$rel — guard region UNRESOLVABLE (fail-closed: triage by hand, never a silent pass)"
    continue
  fi

  # Cell 1 — INSTRUMENT CONTROL. Re-pipeline the live region; it must fail open.
  # `<<<` is spelled BOTH ways in this repo (`<<<"$X"` and `<<< "$X"`), so the
  # pattern tolerates the gap. It is not optional care: on this probe's first run
  # the no-gap-only pattern silently matched nothing on the one site spelled with
  # a space, and the "control" then drove the UNMODIFIED herestring region —
  # a green-looking cell asserting nothing. Hence the substitution-took check
  # below, which is why a failure to construct the control is reported as such
  # instead of being misattributed to the payload.
  # HP-028 EXEMPT — this replacement deliberately CONSTRUCTS the pipeline form that
  # HP-028 forbids, because re-pipelining the live guard IS this probe's instrument
  # control. A sweep that "fixes" it disarms the control silently. Do not convert.
  RE_PIPE='s|^if grep -qE "([^"]*)" <<< *"\$OBSERVATIONS"; then$|if echo "$OBSERVATIONS" \| grep -qE "\1"; then|'  # HP-028
  sed -E "$RE_PIPE" "$WORK/region.txt" > "$WORK/region-piped.txt"
  if cmp -s "$WORK/region.txt" "$WORK/region-piped.txt"; then
    if grep -qF '| grep -qE' "$WORK/region.txt"; then  # HP-028 (pattern names the forbidden shape)
      ok "$rel — already the pipeline form; it IS the control (cell 2 below is the verdict)"
    else
      bad "$rel — could NOT construct the instrument control: the guard is neither the herestring form this probe can re-pipeline nor the pipeline form itself. Cells below assert nothing for this file. Re-spelled guard — extend the substitution, do not read the greens."
    fi
  else
    ctl=$(drive "$WORK/region-piped.txt" "$WORK/pii.txt")
    if [[ "$ctl" == "ALLOWED" ]]; then
      ok "$rel — instrument control: pipelined form fails OPEN, so the payload is firing-shaped here"
    else
      bad "$rel — instrument control got '$ctl', expected ALLOWED. The payload no longer fires on this machine (grep/bash onset moved?) — cells below are testing NOTHING. Do not read them as green."
    fi
  fi

  # Cell 2 — the shipped gate must refuse the same payload.
  got=$(drive "$WORK/region.txt" "$WORK/pii.txt")
  if [[ "$got" == "REFUSED" ]]; then
    ok "$rel — refuses 200 KB PII payload"
  else
    bad "$rel — FAILS OPEN on 200 KB PII payload (got '$got'). The sanitizer would write the PII it exists to block."
  fi

  # Cell 3 — no regression: a clean payload of the same size still passes.
  got=$(drive "$WORK/region.txt" "$WORK/clean.txt")
  if [[ "$got" == "ALLOWED" ]]; then
    ok "$rel — clean 200 KB payload still allowed"
  else
    bad "$rel — clean payload got '$got', expected ALLOWED (gate now always-matches: green and worse than useless)"
  fi
done

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
