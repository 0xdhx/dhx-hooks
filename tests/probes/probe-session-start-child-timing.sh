#!/usr/bin/env bash
# SAFE_FOR_LIVE: yes  (extracts _dhx_digest16, _dhx_child_budget_ms, _dhx_child_sample,
#   _dhx_child_slow_check and _dhx_child from the in-repo dispatcher by sed and sources
#   them with _DHX_CF_DIR + _DHX_TM_DIR pointed at a mktemp root; children are stub
#   functions; samples are injected as text. Never runs the dispatcher, never touches
#   live ~/.cache/dhx or ~/.claude)
#
# Exercises the SessionStart dispatcher's child wall-time samples + slow-child median
# surface (dhx-plugin/plugins/dhx/hooks/session-start.sh, 2026-09-19). It exists because
# nothing recorded any child's wall time, so the 2026-09-14 watch-digest regression (a
# growth-driven 9-12 s) sat for months indistinguishable from the day before. Contract:
#   1. every _dhx_child run appends one `<epoch-seconds> <ms>` sample to <label>.log; the
#      ms is the child's wall time (a 100 ms sleep samples in [90, 400) ms)
#   2. the log is bounded: past 40 lines it is trimmed to the last 20
#   3. fewer than 10 samples → no verdict, whatever the values
#   4. a budgeted label whose median of the last 10 samples >= budget prints the two-line
#      ⚠ surface ONCE (marker directory <label>.slow claimed by mkdir); a second check with
#      the same samples prints nothing
#   5. one loaded outlier among fast samples does not move the median: no print, and an
#      existing marker is cleared (the surface RE-ARMS)
#   6. after re-arming, a real slow median prints again
#   7. a label with no declared budget never prints, however slow
#   8. only watch-digest carries a budget today, and it is 1000 ms
#   9. $EPOCHREALTIME with a comma decimal mark (locale) still samples correctly
#  10. fail-open: an unwritable sample dir → the child still runs, stdout untouched, rc 0;
#      _dhx_child sourced WITHOUT the sampler (the failure-surface probe's shape) still runs
#      the child with no error text
#  11. WIRING: the dispatcher calls _dhx_child_slow_check after the last _dhx_child
#
# Backs docs/decisions.md 2026-09-19 watch-digest residuals row (R2).
# Run: bash tests/probes/probe-session-start-child-timing.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DISPATCHER="$REPO_ROOT/dhx-plugin/plugins/dhx/hooks/session-start.sh"
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0
ok()   { printf '  ✓ %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { if [ "$2" = ok ]; then ok "$1"; else bad "$1${3:+ — $3}"; fi; }

echo "=== session-start child wall-time samples + slow-child median surface ==="

FUNCS="$TMPROOT/funcs.sh"
{
  sed -n '/^_dhx_digest16() {/,/^}/p' "$DISPATCHER"
  sed -n '/^_dhx_child_budget_ms() {/,/^}/p' "$DISPATCHER"
  sed -n '/^_dhx_child_sample() {/,/^}/p' "$DISPATCHER"
  sed -n '/^_dhx_child_slow_check() {/,/^}/p' "$DISPATCHER"
  sed -n '/^_dhx_child() {/,/^}/p' "$DISPATCHER"
} > "$FUNCS"
for f in _dhx_digest16 _dhx_child_budget_ms _dhx_child_sample _dhx_child_slow_check _dhx_child; do
  grep -q "^$f() {" "$FUNCS" || { bad "could not extract $f from $DISPATCHER"; echo "PASS: $PASS  FAIL: $FAIL"; exit 1; }
done
ok "extracted the five functions from the dispatcher"

_DHX_CF_DIR="$TMPROOT/cf"
_DHX_TM_DIR="$TMPROOT/tm"
_DHX_TM_WINDOW=10
# shellcheck disable=SC1090
source "$FUNCS"

slow_samples() { printf '1 1100\n2 1500\n3 1200\n4 1300\n5 1400\n6 1900\n7 1300\n8 1350\n9 1250\n10 2000\n'; }   # upper median 1350
fast_with_outlier() { printf '1 50\n2 60\n3 55\n4 9000\n5 52\n6 58\n7 61\n8 49\n9 57\n10 53\n'; }             # upper median 58

# ---- 1. sample shape + plausible ms ----
napper() { sleep 0.1; echo napped; }
OUT=$(_dhx_child napper napper)
check "1. child stdout passes through" "$( [ "$OUT" = napped ] && echo ok )" "got: $OUT"
SAMPLE=$(tail -n1 "$_DHX_TM_DIR/napper.log" 2>/dev/null)
S_EPOCH=${SAMPLE%% *}; S_MS=${SAMPLE##* }
check "1. one sample appended, shape <epoch> <ms>" \
  "$( [[ "$S_EPOCH" =~ ^[0-9]{9,}$ && "$S_MS" =~ ^[0-9]+$ ]] && echo ok )" "got: '$SAMPLE'"
check "1. ms is the child's wall time (100 ms sleep → [90, 400))" \
  "$( [ "${S_MS:-0}" -ge 90 ] && [ "${S_MS:-9999}" -lt 400 ] && echo ok )" "got: ${S_MS:-?} ms"

# ---- 2. bounded log ----
noop() { :; }
for _ in $(seq 45); do _dhx_child bounded noop >/dev/null; done
N=$(wc -l < "$_DHX_TM_DIR/bounded.log")
check "2. 45 runs → log trimmed to the last 20 once it passes 40 (got $N, expect 20 < n <= 40)" \
  "$( [ "$N" -gt 20 ] && [ "$N" -le 40 ] && echo ok )"

# ---- 3. fewer than 10 samples: no verdict ----
slow_samples | head -9 > "$_DHX_TM_DIR/watch-digest.log"
OUT=$(_dhx_child_slow_check)
check "3. 9 slow samples → no verdict, no marker" \
  "$( [ -z "$OUT" ] && [ ! -d "$_DHX_TM_DIR/watch-digest.slow" ] && echo ok )" "got: $OUT"

# ---- 4. budgeted label over budget: prints once ----
slow_samples > "$_DHX_TM_DIR/watch-digest.log"
OUT=$(_dhx_child_slow_check)
L1=$(printf '%s\n' "$OUT" | sed -n 1p); L2=$(printf '%s\n' "$OUT" | sed -n 2p); NL=$(printf '%s\n' "$OUT" | grep -c .)
check "4. first sight: line 1 names label, median, window, budget" \
  "$( [ "$L1" = "⚠ session-start child watch-digest slow: median 1.3 s over the last 10 sessions, budget 1.0 s" ] && echo ok )" "got: $L1"
check "4. first sight: line 2 is the › hint naming the samples file" \
  "$( [[ "$L2" == "  › stays silent until the median drops back under budget; samples in $_DHX_TM_DIR/watch-digest.log" ]] && echo ok )" "got: $L2"
check "4. exactly two lines" "$( [ "$NL" = 2 ] && echo ok )" "got $NL"
check "4. marker directory claimed" "$( [ -d "$_DHX_TM_DIR/watch-digest.slow" ] && echo ok )"
OUT=$(_dhx_child_slow_check)
check "4. same samples again → silent" "$( [ -z "$OUT" ] && echo ok )" "got: $OUT"

# ---- 5. one outlier does not move the median; marker cleared ----
fast_with_outlier > "$_DHX_TM_DIR/watch-digest.log"
OUT=$(_dhx_child_slow_check)
check "5. nine fast + one 9 s outlier → median under budget: no print" "$( [ -z "$OUT" ] && echo ok )" "got: $OUT"
check "5. marker cleared (surface re-armed)" "$( [ ! -d "$_DHX_TM_DIR/watch-digest.slow" ] && echo ok )"

# ---- 6. re-armed: slow again prints again ----
slow_samples > "$_DHX_TM_DIR/watch-digest.log"
OUT=$(_dhx_child_slow_check)
check "6. slow median after a re-arm prints again" \
  "$( [ "$(printf '%s\n' "$OUT" | sed -n 1p)" = "⚠ session-start child watch-digest slow: median 1.3 s over the last 10 sessions, budget 1.0 s" ] && echo ok )" "got: $OUT"

# ---- 7. unbudgeted label never prints ----
rm -rf "$_DHX_TM_DIR/watch-digest.slow" "$_DHX_TM_DIR/watch-digest.log"
for i in $(seq 10); do printf '%s 9000\n' "$i"; done > "$_DHX_TM_DIR/health-check.log"
OUT=$(_dhx_child_slow_check)
check "7. a label with no budget stays silent at a 9 s median" \
  "$( [ -z "$OUT" ] && [ ! -d "$_DHX_TM_DIR/health-check.slow" ] && echo ok )" "got: $OUT"

# ---- 8. the budget table ----
check "8. watch-digest budget is 1000 ms" "$( [ "$(_dhx_child_budget_ms watch-digest)" = 1000 ] && echo ok )"
check "8. an unknown label has no budget" "$( [ -z "$(_dhx_child_budget_ms nope)" ] && echo ok )"

# ---- 9. comma decimal mark ----
_dhx_child_sample comma "1789806346,080293" "1789806347,180293"
check "9. comma-locale EPOCHREALTIME samples 1100 ms" \
  "$( [ "$(tail -n1 "$_DHX_TM_DIR/comma.log")" = "1789806347 1100" ] && echo ok )" "got: $(tail -n1 "$_DHX_TM_DIR/comma.log")"

# ---- 10. fail-open ----
OUT=$( _DHX_TM_DIR=/proc/dhx-no-such-dir _dhx_child failopen napper 2>"$TMPROOT/err" ); RC=$?
check "10. unwritable sample dir: child ran, stdout intact, rc 0" \
  "$( [ "$OUT" = napped ] && [ "$RC" = 0 ] && echo ok )" "out=$OUT rc=$RC"
# _dhx_child alone (no sampler defined) — the failure-surface probe's sourcing shape
BARE="$TMPROOT/bare.sh"
{ sed -n '/^_dhx_digest16() {/,/^}/p' "$DISPATCHER"; sed -n '/^_dhx_child() {/,/^}/p' "$DISPATCHER"; } > "$BARE"
OUT=$( bash -c "set -uo pipefail; _DHX_CF_DIR='$TMPROOT/cf2'; source '$BARE'; c() { echo bare; }; _dhx_child bare c" 2>"$TMPROOT/err2" ); RC=$?
check "10. _dhx_child sourced without the sampler: child runs, no error text, rc 0" \
  "$( [ "$OUT" = bare ] && [ "$RC" = 0 ] && [ ! -s "$TMPROOT/err2" ] && echo ok )" "out=$OUT rc=$RC err=$(head -c 120 "$TMPROOT/err2")"

# ---- 11. wiring ----
LAST_CHILD=$(grep -n '^[^#]*_dhx_child [a-z]' "$DISPATCHER" | tail -n1 | cut -d: -f1)
CHECK_LINE=$(grep -n '^_dhx_child_slow_check$' "$DISPATCHER" | tail -n1 | cut -d: -f1)
check "11. _dhx_child_slow_check is called once, after the last _dhx_child dispatch" \
  "$( [ -n "$CHECK_LINE" ] && [ "$(grep -c '^_dhx_child_slow_check$' "$DISPATCHER")" = 1 ] && [ "$CHECK_LINE" -gt "${LAST_CHILD:-0}" ] && echo ok )" "check@${CHECK_LINE:-none} last-child@${LAST_CHILD:-none}"

echo "---"
echo "PASS: $PASS  FAIL: $FAIL"
exit $FAIL
