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
#      on stdout, and a signature file under $_DHX_CF_DIR/<label>
#   3. the SAME failure again → nothing on stdout (signature unchanged)
#   4. a DIFFERENT message for the same label → surfaces again
#   5. rc 0 → signature file removed; a later identical failure surfaces again
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
check "signature file written under _DHX_CF_DIR/<label>" "$( [ -s "$_DHX_CF_DIR/heal" ] && echo ok )"
SIG1=$(cat "$_DHX_CF_DIR/heal")
check "signature is a 16-hex digest" "$( [[ "$SIG1" =~ ^[0-9a-f]{16}$ ]] && echo ok )" "got: $SIG1"

# 3. same failure → silent
run heal child_fail
check "identical failure again prints nothing" "$( [ ! -s "$OUT" ] && echo ok )" "got: $(cat "$OUT")"
check "signature unchanged" "$( [ "$(cat "$_DHX_CF_DIR/heal")" = "$SIG1" ] && echo ok )"

# 4. different message → surfaces again
run heal child_fail2
check "changed message surfaces again" "$( grep -q '^⚠ session-start child heal failed (rc=1): boom: a different message$' "$OUT" && echo ok )" "got: $(cat "$OUT")"
check "signature updated" "$( [ "$(cat "$_DHX_CF_DIR/heal")" != "$SIG1" ] && echo ok )"

# 5. success clears; then the old failure surfaces again
run heal child_ok
check "rc 0 removes the signature file" "$( [ ! -e "$_DHX_CF_DIR/heal" ] && echo ok )"
run heal child_fail
check "after a success the same failure surfaces again (first sight resets)" "$( grep -q '^⚠ session-start child heal failed (rc=1)' "$OUT" && echo ok )"

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
check "without sha256sum/shasum: nothing written" "$( [ ! -e "$_DHX_CF_DIR/nodigest" ] && echo ok )"

echo "---"
echo "PASS: $PASS  FAIL: $FAIL"
exit $FAIL
