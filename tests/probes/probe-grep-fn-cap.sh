#!/usr/bin/env bash
# probe-grep-fn-cap.sh
#
# Regression probe for dhx/dhx-grep-fn-cap.sh — the SessionStart hook that
# installs a FUNCTION-LEVEL address-space cap on `grep` by appending a wrapper
# to $CLAUDE_ENV_FILE (sourced into the Bash tool shell after the snapshot).
# Successor to the retired PreToolUse:Bash rewriter dhx-grep-vsz-cap.sh: the
# cap now travels with the function itself, so pattern text can never un-cap
# it (the two 2026-08-18 verified bypasses) and non-grep commands that merely
# MENTION grep in quoted text can never be over-capped (the 2026-08-23
# false-positive that OOM-aborted a nested `claude -p` at 1 GiB).
#
# Covers:
#   - hook no-ops silently when CLAUDE_ENV_FILE is unset
#   - appends the wrapper exactly once (idempotent across invocations)
#   - sourced wrapper renames a pre-existing grep FUNCTION to __dhx_orig_grep
#     and interposes; args, stdout, and exit status pass through
#   - the cap is real: subshell ulimit -v is 1048576 KiB inside the wrapper,
#     the caller's own ulimit -v is untouched, and a 2 GiB allocation dies
#   - pattern text cannot un-cap: 'ulimit -v' and 'x| cd y' as PATTERNS are
#     capped like the plain control (2026-08-18 bypass brief acceptance)
#   - negative control: with NO grep function in scope the wrapper does NOT
#     install (GNU grep must never be wrapped — HP-052's premise inverted)
#   - fail-loud: when ulimit cannot be set the call aborts with exit 125 and
#     a stderr message (user-decided 2026-08-23; supersedes the old fail-open)
#   - DHX_GREP_CAP_VSZ_KB override honored; junk and below-floor values fall
#     back to the 1 GiB default (floor 524288 KiB — the claude-binary floor)
#
# Backs:
#   - docs/decisions.md — DHX-8b function-level grep cap row (2026-08-23)
#   - docs/hook-patterns.md — HP-057 (CLAUDE_ENV_FILE is sourced post-snapshot;
#     function definitions survive and override the snapshot shim), HP-052
#
# Run: bash tests/probes/probe-grep-fn-cap.sh
#
# SAFE_FOR_LIVE: yes  (tmpdir-only; never touches a real session env file. The
#                       one allocating scenario is bounded by the ulimit under
#                       test — ~1 GiB of ADDRESS SPACE, mostly never faulted.)
# LIVE_RUNTIME: no
# RUNTIME: ~3s

#
# CC-STDERR-EXEMPT: spawns no Claude Code child, so there is no settings lint to
#   inherit. Every cell runs `bash "$HOOK"` with CLAUDE_ENV_FILE set; the only
#   `claude -p` in this file is prose in the header paragraph. Measured 2026-09-18:
#   `grep -nE 'claude -p|claude --print' ` returns line 11 only, a comment.
#   Convention: tests/probes/README.md § "A classifier's INPUT is a surface too".
#

set -u

HOOK="/home/dhx/repos/hooks/dhx/dhx-grep-fn-cap.sh"
PASS=0
FAIL=0

T=$(mktemp -d /tmp/probe-grep-fn-cap.XXXXXX)
trap 'rm -rf "$T"' EXIT

ok()   { echo "OK   $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1${2:+ ($2)}"; FAIL=$((FAIL + 1)); }

# Run a bash snippet in a shell that FIRST defines a stub `grep` function
# (standing in for the CC snapshot ugrep shim), THEN sources the env file the
# hook wrote, THEN runs the assertion snippet. Mirrors the tool-shell order.
in_wrapped_shell() {  # ENVFILE SNIPPET
  bash -c '
    grep() { echo "STUB:$*"; return 7; }
    source "$1"
    '"$2"'
  ' _ "$1"
}

# ── [1] unset CLAUDE_ENV_FILE → silent no-op, exit 0 ─────────────────────────
out=$(env -u CLAUDE_ENV_FILE bash "$HOOK" </dev/null 2>&1); rc=$?
if [ $rc -eq 0 ] && [ -z "$out" ]; then ok "[1] no CLAUDE_ENV_FILE: silent exit 0"
else fail "[1] no CLAUDE_ENV_FILE: silent exit 0" "rc=$rc out=$out"; fi

# ── [2] with CLAUDE_ENV_FILE → wrapper appended, hook silent ─────────────────
ENVF="$T/env1"
out=$(CLAUDE_ENV_FILE="$ENVF" bash "$HOOK" </dev/null 2>&1); rc=$?
if [ $rc -eq 0 ] && [ -z "$out" ] && command grep -q '__dhx_orig_grep' "$ENVF"; then
  ok "[2] wrapper appended to CLAUDE_ENV_FILE, hook silent"
else fail "[2] wrapper appended to CLAUDE_ENV_FILE, hook silent" "rc=$rc"; fi

# ── [3] second invocation is idempotent (exactly one wrapper block) ──────────
CLAUDE_ENV_FILE="$ENVF" bash "$HOOK" </dev/null >/dev/null 2>&1
n=$(command grep -c 'dhx-grep-fn-cap: begin' "$ENVF")
if [ "$n" = "1" ]; then ok "[3] re-invocation appends nothing (1 wrapper block)"
else fail "[3] re-invocation appends nothing" "blocks=$n"; fi

# ── [4] pre-existing content in the env file survives the append ─────────────
ENVF2="$T/env2"; printf 'PEER_VAR=kept\n' > "$ENVF2"
CLAUDE_ENV_FILE="$ENVF2" bash "$HOOK" </dev/null >/dev/null 2>&1
if command grep -q '^PEER_VAR=kept$' "$ENVF2" && command grep -q '__dhx_orig_grep' "$ENVF2"; then
  ok "[4] append-only: a peer hook's earlier lines survive"
else fail "[4] append-only: a peer hook's earlier lines survive"; fi

# ── [5] sourced with a grep FUNCTION in scope: interposed, both defined ──────
out=$(in_wrapped_shell "$ENVF" 'echo "$(type -t grep):$(type -t __dhx_orig_grep)"')
if [ "$out" = "function:function" ]; then ok "[5] wrapper installs: grep + __dhx_orig_grep are functions"
else fail "[5] wrapper installs" "got=$out"; fi

# ── [6] args, stdout, and exit status pass through to the original ───────────
out=$(in_wrapped_shell "$ENVF" 'grep -E "a|b" /dev/null; echo "rc=$?"')
if [ "$out" = "STUB:-E a|b /dev/null
rc=7" ]; then ok "[6] args + stdout + exit status pass through"
else fail "[6] args + stdout + exit status pass through" "got=$out"; fi

# ── [7] the cap is set inside the wrapper subshell (1048576 KiB) ─────────────
out=$(bash -c '
  grep() { ulimit -v; }
  source "$1"
  grep anything
' _ "$ENVF")
if [ "$out" = "1048576" ]; then ok "[7] subshell ulimit -v is 1048576 KiB inside the wrapper"
else fail "[7] subshell ulimit -v is 1048576 KiB" "got=$out"; fi

# ── [8] the caller's own ulimit -v is untouched after a capped call ──────────
out=$(bash -c '
  grep() { :; }
  source "$1"
  grep anything >/dev/null 2>&1
  ulimit -v
' _ "$ENVF")
if [ "$out" = "unlimited" ]; then ok "[8] caller ulimit -v unchanged (unlimited) after a capped call"
else fail "[8] caller ulimit -v unchanged" "got=$out"; fi

# ── [9]-[11] pattern text can NEVER un-cap (bypass-brief acceptance) ─────────
for spec in \
  '9:plain control pattern:foo' \
  '10:the ulimit -v idempotence-token pattern:ulimit -v' \
  '11:the quote-blind splitter pattern:x| cd y' ; do
  num=${spec%%:*}; rest=${spec#*:}; label=${rest%%:*}; pat=${rest#*:}
  out=$(bash -c '
    grep() { ulimit -v; }
    source "$1"
    grep -E "$2" /dev/null
  ' _ "$ENVF" "$pat")
  if [ "$out" = "1048576" ]; then ok "[$num] capped with $label"
  else fail "[$num] capped with $label" "got=$out"; fi
done

# ── [12] negative control: no grep function → wrapper must NOT install ───────
out=$(bash -c '
  source "$1"
  echo "$(type -t grep):$(type -t __dhx_orig_grep || echo absent)"
' _ "$ENVF")
if [ "$out" = "file:" ] || [ "$out" = "file:absent" ]; then
  ok "[12] no grep function in scope: GNU grep left unwrapped"
else fail "[12] no grep function in scope: GNU grep left unwrapped" "got=$out"; fi

# ── [13] fail-loud: ulimit failure aborts with 125 + stderr message ──────────
out=$(bash -c '
  grep() { echo REACHED; }
  source "$1"
  ulimit() { return 1; }
  grep anything 2>"$2"; echo "rc=$?"
' _ "$ENVF" "$T/stderr13")
if [ "$out" = "rc=125" ] && command grep -q 'dhx-grep-fn-cap' "$T/stderr13" \
   && ! command grep -q 'REACHED' <<<"$out"; then
  ok "[13] fail-loud: exit 125 + stderr, original never runs"
else fail "[13] fail-loud: exit 125 + stderr" "out=$out stderr=$(cat "$T/stderr13" 2>/dev/null)"; fi

# ── [14] DHX_GREP_CAP_VSZ_KB override honored at call time ───────────────────
out=$(bash -c '
  grep() { ulimit -v; }
  source "$1"
  DHX_GREP_CAP_VSZ_KB=2097152 grep anything
' _ "$ENVF")
if [ "$out" = "2097152" ]; then ok "[14] env override 2097152 KiB honored"
else fail "[14] env override honored" "got=$out"; fi

# ── [15] below-floor override falls back to the default ──────────────────────
out=$(bash -c '
  grep() { ulimit -v; }
  source "$1"
  DHX_GREP_CAP_VSZ_KB=1000 grep anything
' _ "$ENVF")
if [ "$out" = "1048576" ]; then ok "[15] below-floor override (1000) falls back to 1048576"
else fail "[15] below-floor override falls back" "got=$out"; fi

# ── [16] junk override falls back to the default ─────────────────────────────
out=$(bash -c '
  grep() { ulimit -v; }
  source "$1"
  DHX_GREP_CAP_VSZ_KB="1048576; rm -rf /" grep anything
' _ "$ENVF")
if [ "$out" = "1048576" ]; then ok "[16] junk override falls back to 1048576 (injection boundary)"
else fail "[16] junk override falls back" "got=$out"; fi

# ── [17] containment is real: a 2 GiB allocation dies under the cap ──────────
out=$(timeout 20 bash -c '
  grep() { python3 -c "b = bytearray(2 << 30)" 2>/dev/null; echo "alloc-rc=$?"; }
  source "$1"
  grep anything
' _ "$ENVF")
case "$out" in
  alloc-rc=0|"") fail "[17] 2 GiB allocation contained under the cap" "got=$out" ;;
  alloc-rc=*)    ok "[17] 2 GiB allocation contained under the cap ($out)" ;;
  *)             fail "[17] 2 GiB allocation contained under the cap" "got=$out" ;;
esac

echo
echo "$PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
