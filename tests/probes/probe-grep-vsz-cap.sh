#!/usr/bin/env bash
# probe-grep-vsz-cap.sh
#
# Regression probe for dhx/dhx-grep-vsz-cap.sh — the PreToolUse:Bash address-space
# cap that contains the ugrep interval-quantifier blowup (2026-08-11 incident:
# ~19.4 GB RSS from a compile-time DFA explosion, host at 86% memory).
#
# Covers:
#   - the BROAD predicate (every grep-family head is capped, no pattern analysis)
#   - the four refusal branches, each of which must be a NO-OP
#   - idempotence, including re-feeding the hook its own rewrite
#   - budget grammar as an injection boundary + the measured MIN floor
#   - REWRITE FIDELITY — the property that ruled out the cgroup mechanism: the
#     rewrite must still reach a shell FUNCTION named grep (the CC ugrep wrapper),
#     asserted against a stub plus a `bash -c` negative control
#   - live containment: the reproducer dies bounded instead of eating the host
#
# Backs:
#   - docs/decisions.md — DHX-8 grep address-space cap row
#   - docs/hook-patterns.md — HP-041 (updatedInput rewrite), HP-052 (subshells
#     inherit shell functions; `bash -c` does not)
#
# Run: bash tests/probes/probe-grep-vsz-cap.sh
#
# SAFE_FOR_LIVE: yes  (reads only; the one allocating scenario is bounded by the
#                       very ulimit under test and peaks under 1 GiB of ADDRESS
#                       SPACE, most of it never faulted in. No config is written,
#                       no systemd unit is created, no session state is touched.)
# RUNTIME: ~10s        (scenario 31 deliberately runs the real blowup to exhaustion)

set -u

HOOK="/home/dhx/repos/hooks/dhx/dhx-grep-vsz-cap.sh"
PASS=0
FAIL=0

# Feed a command string to the hook; echo the rewritten command, or NOOP.
rw() {  # CMD [ENV=VAL ...]
  local cmd="$1"; shift
  local json
  json=$(jq -cn --arg c "$cmd" '{tool_input:{command:$c}}')
  printf '%s' "$json" \
    | env "$@" bash "$HOOK" 2>/dev/null \
    | jq -r '.hookSpecificOutput.updatedInput.command // "NOOP"' 2>/dev/null
}

assert_rewritten() {  # CMD LABEL
  local out; out=$(rw "$1")
  if [ "$out" != "NOOP" ] && [ -n "$out" ]; then
    echo "OK   $2"; PASS=$((PASS + 1))
  else
    echo "FAIL $2 (expected a rewrite, got NOOP)"; FAIL=$((FAIL + 1))
  fi
}

assert_noop() {  # CMD LABEL
  local out; out=$(rw "$1")
  if [ "$out" = "NOOP" ]; then
    echo "OK   $2"; PASS=$((PASS + 1))
  else
    echo "FAIL $2 (expected NOOP, got rewrite)"; FAIL=$((FAIL + 1))
    echo "     rewrite: $out"
  fi
}

assert_contains() {  # HAYSTACK NEEDLE LABEL
  case "$1" in
    *"$2"*) echo "OK   $3"; PASS=$((PASS + 1)) ;;
    *)      echo "FAIL $3 (missing '$2')"; FAIL=$((FAIL + 1)); echo "     got: $1" ;;
  esac
}

# ----------------------------------------------------------------------------
# Predicate — BROAD by design. Any grep-family head is capped, whatever the
# pattern. The narrow "only dangerous-looking regexes" alternative was refuted by
# measurement (`-P` is safe, `[a-z]{0,90}` is not) — see the hook header.
# ----------------------------------------------------------------------------
assert_rewritten "grep -E '.{0,90}a.{0,90}' /dev/null"  "[1] the incident reproducer is capped"
assert_rewritten "grep -rn foo ~/repos"                 "[2] an ordinary recursive grep is capped too (broad predicate)"
assert_rewritten "ugrep -E 'x' f"                       "[3] 'ugrep' head is capped"
assert_rewritten "ug -E 'x' f"                          "[4] 'ug' head is capped"
assert_rewritten "\\grep -E 'x' f"                      "[5] '\\grep' is capped (backslash blocks ALIASes, not FUNCTIONs)"
assert_rewritten "FOO=1 BAR=2 grep -E 'x' f"            "[6] env-assignment prefix still resolves the head"
assert_rewritten "cat f | grep -E 'x'"                  "[7] grep at a non-leading segment head is capped"
assert_rewritten "grep -E 'a|b' f"                      "[8] a quoted '|' in the pattern does not defeat the match"

# ----------------------------------------------------------------------------
# Refusals — every one MUST be a no-op. A refusal here means the command runs
# exactly as it did before this hook existed; it must never block or corrupt.
# ----------------------------------------------------------------------------
assert_noop "command grep -E 'x' f"   "[9]  'command grep' → NOOP (bypasses the wrapper, reaches GNU grep)"
assert_noop "/bin/grep -E 'x' f"      "[10] absolute-path grep → NOOP (GNU grep has no such defect)"
assert_noop "./grep -E 'x' f"         "[11] path-prefixed grep → NOOP"
assert_noop "cd /tmp && grep foo bar" "[12] a 'cd' segment → NOOP (the subshell would swallow the cd)"
assert_noop "export X=1; grep foo f"  "[13] an 'export' segment → NOOP (side effect would be lost)"
assert_noop "pytest | grep FAILED"    "[14] pytest present → NOOP (yields to dhx-pytest-cgroup-cap.sh)"
assert_noop "uv run pytest -k grep"   "[15] 'uv run pytest' → NOOP (same yield)"
assert_noop "echo grep"               "[16] 'grep' as an ARGUMENT is not a head → NOOP"
assert_noop "git commit -m 'fix grep'" "[17] 'grep' inside a commit message → NOOP"

# ----------------------------------------------------------------------------
# Idempotence — the strong form: feed the hook its OWN output.
# ----------------------------------------------------------------------------
ONCE=$(rw "grep -rn foo ~/repos")
TWICE=$(rw "$ONCE")
if [ "$TWICE" = "NOOP" ]; then
  echo "OK   [18] re-feeding the hook its own rewrite → NOOP (no double-wrap)"
  PASS=$((PASS + 1))
else
  echo "FAIL [18] the hook rewrote its own rewrite"; FAIL=$((FAIL + 1))
  echo "     twice: $TWICE"
fi
assert_contains "$ONCE" "ulimit -v 1048576" "[19] rewrite carries the 1 GiB default"
assert_contains "$ONCE" "ulimit -c 0" "[19b] rewrite clamps core dumps (a segfault at 1 GiB would dump ~1 GiB)"

# ----------------------------------------------------------------------------
# Rewrite is VALID SHELL. The trailing-comment case is why the rewrite is
# newline-separated rather than `;`-separated: a `; )` terminator would be
# swallowed by the comment, leaving an unterminated subshell.
# ----------------------------------------------------------------------------
CMT=$(rw "grep -c 'x' f  # why this grep")
if printf '%s\n' "$CMT" | bash -n 2>/dev/null; then
  echo "OK   [20] rewrite of a comment-terminated command parses as valid shell"
  PASS=$((PASS + 1))
else
  echo "FAIL [20] rewrite of a comment-terminated command is a shell syntax error"; FAIL=$((FAIL + 1))
  echo "     rewrite: $CMT"
fi

# ----------------------------------------------------------------------------
# Budget grammar. The value is interpolated into a command STRING, so the grammar
# is this hook's injection boundary — not a nicety.
# ----------------------------------------------------------------------------
assert_contains "$(rw "grep x f" "DHX_GREP_CAP_VSZ_KB=2097152")" \
  "ulimit -v 2097152" "[21] a valid env override is honored"
assert_contains "$(rw "grep x f" "DHX_GREP_CAP_VSZ_KB=1000")" \
  "ulimit -v 1048576" "[22] below the measured 512 MiB floor → default (a too-low cap is a grep OUTAGE)"
assert_contains "$(rw "grep x f" "DHX_GREP_CAP_VSZ_KB=1048576; rm -rf /tmp/x")" \
  "ulimit -v 1048576" "[23] shell metacharacters in the override → default (no injection)"
assert_contains "$(rw "grep x f" "DHX_GREP_CAP_VSZ_KB=99999999999999999999")" \
  "ulimit -v 1048576" "[24] an over-int64 override → default (bash WRAPS oversized literals at parse)"
assert_contains "$(rw "grep x f" "DHX_GREP_CAP_VSZ_KB=")" \
  "ulimit -v 1048576" "[25] an empty override → default"

# ----------------------------------------------------------------------------
# Malformed input — fail open, never block.
# ----------------------------------------------------------------------------
for bad in '{"tool_input":{}}' '{}' 'not json at all' ''; do
  out=$(printf '%s' "$bad" | bash "$HOOK" 2>/dev/null)
  if [ "$out" = "{}" ]; then
    echo "OK   [26] malformed stdin fails open: $(printf '%.20s' "${bad:-<empty>}")"
    PASS=$((PASS + 1))
  else
    echo "FAIL [26] malformed stdin did not emit {}: '$out'"; FAIL=$((FAIL + 1))
  fi
done

# ----------------------------------------------------------------------------
# FIDELITY — the assertions that RULED OUT the cgroup mechanism.
#
# In a Claude Code Bash tool shell, `grep` is a shell FUNCTION wrapping ugrep. A
# `systemd-run … -- bash -c '<cmd>'` rewrite loses that function and silently
# substitutes GNU grep — a different engine, dialect, and default flag set.
#
# THIS PROBE CANNOT SEE THE REAL WRAPPER: it runs as a plain script, and shell
# functions are not exported to child processes. An earlier draft compared wrapped
# vs unwrapped output HERE and passed — because both sides resolved to /usr/bin/grep
# and it was comparing GNU grep to GNU grep. A green result proving nothing.
#
# So the mechanism is tested directly instead, with a STUB function standing in for
# the wrapper. That is strictly better than depending on CC internals: it asserts
# the general property the design rests on, and it is deterministic.
# ----------------------------------------------------------------------------
# Run inside ( ) so the stub cannot leak into the rest of the probe.
FID=$(
  # Stand-in for the CC wrapper: a `grep` that is a FUNCTION, not a binary.
  grep() { printf 'STUB-CALLED\n'; return 3; }
  eval "$(rw "grep -q needle /etc/hostname")" 2>/dev/null
  printf 'status=%s\n' "$?"
)
case "$FID" in
  *STUB-CALLED*status=3*)
    echo "OK   [27] the rewrite reaches the shell FUNCTION (subshells inherit functions) and preserves its status"
    PASS=$((PASS + 1)) ;;
  *)
    echo "FAIL [27] the rewrite did NOT reach the function — the wrapper would be silently replaced"; FAIL=$((FAIL + 1))
    echo "     got: $(printf '%s' "$FID" | tr '\n' ' ')" ;;
esac

# NEGATIVE CONTROL — this is the measurement that rejected the cgroup design.
# The same command under `bash -c` (what a systemd-run rewrite must use) must MISS
# the function. If this ever starts passing through, the cgroup mechanism became
# viable and the design note in the hook header needs revisiting.
NEG=$(
  grep() { printf 'STUB-CALLED\n'; return 3; }
  bash -c "grep -q needle /etc/hostname" 2>/dev/null
  printf 'status=%s\n' "$?"
)
case "$NEG" in
  *STUB-CALLED*)
    echo "FAIL [28] bash -c reached the function — the cgroup-rewrite rejection premise is void"; FAIL=$((FAIL + 1)) ;;
  *)
    echo "OK   [28] bash -c does NOT inherit the function (why the cgroup rewrite was rejected)"
    PASS=$((PASS + 1)) ;;
esac

# The session shell must be untouched — `ulimit` applies to the subshell only.
# If this ever fails, every later command in the session inherits the cap.
BEFORE=$(ulimit -v)
eval "$(rw "grep -q x /etc/hostname")" >/dev/null 2>&1 || true
AFTER=$(ulimit -v)
if [ "$BEFORE" = "$AFTER" ]; then
  echo "OK   [29] caller's own ulimit -v is unchanged ($AFTER)"; PASS=$((PASS + 1))
else
  echo "FAIL [29] the rewrite leaked its limit into the caller: $BEFORE → $AFTER"; FAIL=$((FAIL + 1))
fi

# Ordinary path arguments must not trip a self-reference guard. Regression lock:
# the first cut also bypassed on the literal string "dhx-grep-vsz-cap", so grepping
# this hook's OWN file — a completely ordinary command — ran uncapped.
assert_rewritten "grep -n foo /home/dhx/repos/hooks/dhx/dhx-grep-vsz-cap.sh" \
  "[30] the hook's own filename as an ARGUMENT is still capped (no over-broad self-guard)"

# ----------------------------------------------------------------------------
# CONTAINMENT — the point of the whole hook. Runs the real reproducer against the
# real ugrep, which is reachable only through the Claude Code binary (argv[0]).
#
# Status is NOT pinned. The allocation failure surfaces as SIGSEGV (139) here, but
# a memory kill's status is not categorical on this host (HP-045), so the assertion
# is "died, bounded, and fast" — the property that actually matters. Uncapped, this
# same command reached ~19.4 GB and froze the box.
#
# Host-gated: if the CC binary is not locatable, SKIP honestly rather than passing
# on GNU grep, which does not carry the defect and would make this vacuous.
# ----------------------------------------------------------------------------
UG_BIN="${CLAUDE_CODE_EXECPATH:-$HOME/.local/bin/claude}"
if [ -x "$UG_BIN" ]; then
  C=0; T0=$(date +%s%N)
  # The inner ( ) plus `exit $?` keeps the OUTER subshell alive to report the
  # status normally; without it the reaping shell prints "Segmentation fault
  # (core dumped) <cmdline>" into otherwise-green probe output. `ulimit -c 0`
  # mirrors what the hook's own rewrite sets.
  (
    ulimit -v 1048576 2>/dev/null || true
    ulimit -c 0 2>/dev/null || true
    ( exec -a ugrep "$UG_BIN" -G --ignore-files --hidden -I -E '.{0,90}a.{0,90}' /dev/null )
    exit $?
  ) >/dev/null 2>&1 || C=$?
  T1=$(date +%s%N); MS=$(( (T1 - T0) / 1000000 ))
  if [ "$C" -ne 0 ] && [ "$MS" -lt 60000 ]; then
    echo "OK   [31] the real reproducer is contained: died (status $C) in ${MS}ms under the cap"
    PASS=$((PASS + 1))
  else
    echo "FAIL [31] the reproducer was NOT contained (status $C after ${MS}ms)"; FAIL=$((FAIL + 1))
    echo "     status 0 means the cap never fired; a long runtime means it is still growing"
  fi
else
  echo "SKIP [31] containment — Claude Code binary not found at '$UG_BIN'"
  echo "     (GNU grep does not carry the defect, so asserting against it would be vacuous)"
fi

# ----------------------------------------------------------------------------
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
