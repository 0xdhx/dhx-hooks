#!/usr/bin/env bash
# SAFE_FOR_LIVE: yes  (extracts _dhx_digest16 + _dhx_child from the in-repo dispatcher
#   by sed and sources them into this shell with _DHX_CF_DIR pointed at a mktemp
#   root; children are stub functions; read-only grep of the dispatcher for wiring.
#   Never runs the dispatcher, never touches live ~/.cache/dhx or ~/.claude)
#
# Exercises the SessionStart dispatcher's child-failure first-sight surface
# (dhx-plugin/plugins/dhx/hooks/session-start.sh, 2026-09-14). The surface exists
# because every child is `|| true`d and stderr at exit 0 is not a surface (HP-038),
# which let dhx-plugin-registry-heal.sh REJECT on every SessionStart for four
# months unseen. Contract under test:
#   1. child stdout passes through untouched; child stderr is replayed to stderr
#   2. FIRST sight of (label, rc, first stderr line) → one ⚠ line + one › hint line
#      on stdout, and a marker DIRECTORY $_DHX_CF_DIR/<label>.<16-hex sig>
#   3. the SAME failure again → nothing on stdout (marker already claimed)
#   4. a DIFFERENT message for the same label → surfaces again (second marker);
#      the FIRST message coming back → silent (its marker still stands)
#   5. rc 0 → every marker for the label removed; a later identical failure
#      surfaces again
#   5b. RACE: N dispatchers hitting the same first sight concurrently → exactly
#      ONE ⚠ line in total (mkdir is the atomic test-and-set; the close-gate
#      reviewer measured the earlier read-compare-write shape printing twice)
#   6. rc != 0 with EMPTY stderr → surfaces with no message suffix
#   7. stdin reaches the child (pipeline form `printf … | _dhx_child …`)
#   8. WIRING: the heal is dispatched through _dhx_child; no dhx hook child is still
#      dispatched as a bare `… || true` (the pre-2026-09-14 masking shape)
#   9. no-digest-tool fail-open: with sha256sum/shasum absent the child still runs,
#      nothing is printed, nothing is written
#
# Backs docs/decisions.md 2026-09-14 "SessionStart child-failure first-sight
# surface" row.
# Run: bash tests/probes/probe-session-start-child-failure-surface.sh

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

echo "=== session-start child-failure first-sight surface ==="

# ---- extract the two functions from the live dispatcher (source-of-truth, not a copy) ----
FUNCS="$TMPROOT/funcs.sh"
{
  sed -n '/^_dhx_digest16() {/,/^}/p' "$DISPATCHER"
  sed -n '/^_dhx_child() {/,/^}/p' "$DISPATCHER"
} > "$FUNCS"
if grep -q '^_dhx_digest16() {' "$FUNCS" && grep -q '^_dhx_child() {' "$FUNCS"; then
  ok "extracted _dhx_digest16 + _dhx_child from the dispatcher"
else
  bad "could not extract both functions from $DISPATCHER"; echo "PASS: $PASS  FAIL: $FAIL"; exit 1
fi
_DHX_CF_DIR="$TMPROOT/cf"
# shellcheck disable=SC1090
source "$FUNCS"

# ---- stub children ----
child_fail()   { echo "boom: first line" >&2; echo "second line" >&2; return 1; }
child_fail2()  { echo "boom: a different message" >&2; return 1; }
child_ok()     { echo "child-stdout"; return 0; }
child_quiet()  { return 3; }
child_echo()   { cat; return 0; }

run() { # run <label> <fn> → OUT/ERR files
  OUT="$TMPROOT/out"; ERR="$TMPROOT/err"
  _dhx_child "$1" "$2" >"$OUT" 2>"$ERR"
}

# 1. stdout/stderr passthrough
run t1 child_ok
check "child stdout passes through" "$( [ "$(cat "$OUT")" = "child-stdout" ] && echo ok )"
run t1 child_fail
check "child stderr replayed verbatim (both lines)" "$( [ "$(cat "$ERR")" = $'boom: first line\nsecond line' ] && echo ok )"

# 2. first sight → surface + signature
run heal child_fail
LINE1=$(sed -n 1p "$OUT"); LINE2=$(sed -n 2p "$OUT"); NLINES=$(wc -l < "$OUT")
check "first sight prints exactly two lines" "$( [ "$NLINES" = 2 ] && echo ok )" "got $NLINES"
check "line 1 is the ⚠ failure line with label, rc and first stderr line" \
  "$( [ "$LINE1" = "⚠ session-start child heal failed (rc=1): boom: first line" ] && echo ok )" "got: $LINE1"
check "line 2 is the › hint line" "$( [[ "$LINE2" == "  › repeats of this exact failure stay silent"* ]] && echo ok )" "got: $LINE2"
MARKERS=$(ls -d "$_DHX_CF_DIR"/heal.* 2>/dev/null | wc -l)
check "exactly one marker directory under _DHX_CF_DIR/<label>.<sig>" "$( [ "$MARKERS" = 1 ] && echo ok )" "got $MARKERS"
SIG1=$(basename "$(ls -d "$_DHX_CF_DIR"/heal.* 2>/dev/null | head -1)"); SIG1=${SIG1#heal.}
check "marker suffix is a 16-hex digest" "$( [[ "$SIG1" =~ ^[0-9a-f]{16}$ ]] && echo ok )" "got: $SIG1"

# 3. same failure → silent
run heal child_fail
check "identical failure again prints nothing" "$( [ ! -s "$OUT" ] && echo ok )" "got: $(cat "$OUT")"
check "marker set unchanged" "$( [ "$(ls -d "$_DHX_CF_DIR"/heal.* | wc -l)" = 1 ] && echo ok )"

# 4. different message → surfaces again
run heal child_fail2
check "changed message surfaces again" "$( grep -q '^⚠ session-start child heal failed (rc=1): boom: a different message$' "$OUT" && echo ok )" "got: $(cat "$OUT")"
check "second marker claimed alongside the first" "$( [ "$(ls -d "$_DHX_CF_DIR"/heal.* | wc -l)" = 2 ] && [ -d "$_DHX_CF_DIR/heal.$SIG1" ] && echo ok )"
run heal child_fail
check "the first message coming back is silent (its marker still stands)" "$( [ ! -s "$OUT" ] && echo ok )" "got: $(cat "$OUT")"

# 5. success clears; then the old failure surfaces again
run heal child_ok
check "rc 0 removes every marker for the label" "$( [ "$(ls -d "$_DHX_CF_DIR"/heal.* 2>/dev/null | wc -l)" = 0 ] && echo ok )"
check "rc 0 leaves other labels' markers alone" "$( [ "$(ls -d "$_DHX_CF_DIR"/t1.* 2>/dev/null | wc -l)" = 1 ] && echo ok )"
run heal child_fail
check "after a success the same failure surfaces again (first sight resets)" "$( grep -q '^⚠ session-start child heal failed (rc=1)' "$OUT" && echo ok )"

# 5b. race: N concurrent first sights → exactly one ⚠ line
rm -rf "$_DHX_CF_DIR"
RACE_N=12; RACE_OUT="$TMPROOT/race"; mkdir -p "$RACE_OUT"
child_race() { echo "boom: raced" >&2; return 1; }
export -f _dhx_child _dhx_digest16 child_race; export _DHX_CF_DIR
GO="$TMPROOT/go"
for i in $(seq 1 $RACE_N); do
  ( until [ -e "$GO" ]; do :; done; _dhx_child racer child_race >"$RACE_OUT/$i" 2>/dev/null ) &
done
sleep 0.2; : > "$GO"; wait
RACE_LINES=$(cat "$RACE_OUT"/* | grep -c '^⚠ session-start child racer failed')
check "race: $RACE_N concurrent first sights print exactly one ⚠ line" "$( [ "$RACE_LINES" = 1 ] && echo ok )" "got $RACE_LINES"
check "race: exactly one marker claimed" "$( [ "$(ls -d "$_DHX_CF_DIR"/racer.* 2>/dev/null | wc -l)" = 1 ] && echo ok )"
rm -f "$GO"

# 6. non-zero with empty stderr
run quiet child_quiet
check "rc != 0 with empty stderr surfaces without a message suffix" \
  "$( [ "$(sed -n 1p "$OUT")" = "⚠ session-start child quiet failed (rc=3)" ] && echo ok )" "got: $(sed -n 1p "$OUT")"

# 7. stdin reaches the child through the pipeline form
GOT=$(printf 'payload-123' | _dhx_child echo child_echo 2>/dev/null)
check "pipeline stdin reaches the child" "$( [ "$GOT" = "payload-123" ] && echo ok )" "got: $GOT"

# 8. wiring
check "heal is dispatched through _dhx_child" \
  "$( grep -q '^_dhx_child registry-heal bash /home/dhx/.claude/hooks/dhx-plugin-registry-heal.sh < /dev/null$' "$DISPATCHER" && echo ok )"
BARE=$(grep -nE '^(printf .*\| )?(bash|node) /home/dhx/.claude/hooks/[^ ]+.* \|\| true$' "$DISPATCHER" || true)
check "no dhx hook child is still dispatched as a bare '… || true'" "$( [ -z "$BARE" ] && echo ok )" "found: $BARE"
check "_DHX_CF_DIR honours DHX_HOOKS_CACHE_DIR like the schedule beat" \
  "$( grep -q '^_DHX_CF_DIR="\${DHX_HOOKS_CACHE_DIR:-\$HOME/.cache/dhx/hooks}/session-start-child-failures"$' "$DISPATCHER" && echo ok )"

# 9. no digest tool → fail-open (child runs, nothing printed, nothing written)
NOTOOLS="$TMPROOT/notools"; mkdir -p "$NOTOOLS"
for t in bash sed head cut cat mktemp rm mv mkdir printf; do
  p=$(command -v "$t" 2>/dev/null) && ln -s "$p" "$NOTOOLS/$t"
done
rm -rf "$_DHX_CF_DIR"
GOT=$(PATH="$NOTOOLS" _dhx_child nodigest child_fail 2>/dev/null)
check "without sha256sum/shasum: child ran, nothing printed" "$( [ -z "$GOT" ] && echo ok )" "got: $GOT"
check "without sha256sum/shasum: nothing written" "$( [ "$(ls -d "$_DHX_CF_DIR"/nodigest.* 2>/dev/null | wc -l)" = 0 ] && echo ok )"

# ---- 9. a child that exits WITHOUT draining stdin must not surface anything ----
# Every child is invoked as `printf '%s' "$INPUT" | _dhx_child <label> bash <hook>`
# under the dispatcher's `set -uo pipefail`. A child that exits at a suppression
# guard before its `INPUT=$(cat)` closes the read end unread, so the printf takes
# SIGPIPE and exits 141 and pipefail makes the PIPELINE's status 141.
#
# That must stay invisible: _dhx_child captures rc from the CHILD alone, returns 0,
# and the dispatcher discards the pipeline status at statement level with no errexit.
# Nothing asserted this until 2026-09-18, when the property became load-bearing —
# probe-vet-closures.sh reports the shim's own rc precisely BECAUSE the writer's 141
# is discarded in production. If this arm ever reds, the correct fix moves from that
# probe to the shim itself (drain stdin before the guard), so read it as a routing
# signal, not a nuisance.
rm -rf "$_DHX_CF_DIR"
SKIPPER="$TMPROOT/exits-before-cat.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SKIPPER"
OUT9="$TMPROOT/out9"; ERR9="$TMPROOT/err9"
# Run it the way the DISPATCHER does: the pipeline is a bare statement with more
# script after it, so its status is discarded rather than becoming anyone's exit
# code. Wrapping it in a subshell instead makes the subshell's status BE the
# pipeline's 141 — which is a property of the wrapper, not of production. That
# mistake was made here first and caught by running the arm.
#
# The writer is delayed so the reader ALWAYS wins the race — without it this arm
# passes ~9 times in 10 by luck and proves nothing.
cat > "$TMPROOT/dispatch9.sh" <<DISPATCH9
set -uo pipefail
source "$FUNCS"
_DHX_CF_DIR="$_DHX_CF_DIR"
{ sleep 0.05; printf '%s' '{"hook_event_name":"SessionStart"}'; } \
  | _dhx_child skipper bash "$SKIPPER"
echo "REACHED_NEXT_STATEMENT"
DISPATCH9
set +e
bash "$TMPROOT/dispatch9.sh" >"$OUT9" 2>"$ERR9"
ARM9_RC=$?
set -e
check "suppressed child: the dispatcher script still exits 0" \
  "$( [ "$ARM9_RC" = 0 ] && echo ok )" "got rc=$ARM9_RC"
check "suppressed child: the statement AFTER the pipeline still runs" \
  "$( grep -qx 'REACHED_NEXT_STATEMENT' "$OUT9" && echo ok )" "got: $(cat "$OUT9")"
check "suppressed child: no failure line on the operator surface" \
  "$( [ -z "$(grep -v '^REACHED_NEXT_STATEMENT$' "$OUT9")" ] && echo ok )" "got: $(cat "$OUT9")"
check "suppressed child: no failure marker claimed" \
  "$( [ "$(ls -d "$_DHX_CF_DIR"/skipper.* 2>/dev/null | wc -l)" = 0 ] && echo ok )"

echo "---"
echo "PASS: $PASS  FAIL: $FAIL"
exit $FAIL
