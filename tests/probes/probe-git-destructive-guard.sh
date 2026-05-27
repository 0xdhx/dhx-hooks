#!/usr/bin/env bash
# probe-git-destructive-guard.sh
#
# Regression probe for dhx/dhx-git-destructive-guard.sh (PreToolUse:Bash).
#
# Invariant: blocks (exit 2) git push invocations that the existing
# `Bash(git push --force *)` / `Bash(git push -f *)` deny strings cannot
# catch — namely the two syntactic bypasses verified to slip the live CC
# 2.1.150 matcher in
# `cross-repo/reports/done/2026-05-25-git-force-push-deny-rule-bypass-vectors.md`:
#
#   1. Refspec with leading `+` — `git push <remote> +<ref>` and
#      `git push <remote> <src>:+<dst>`. Force-ness lives in the refspec
#      argument, not a flag.
#   2. Leading-token redirection — `git -C <path> push --force`,
#      `git --git-dir=<path> push --force`, `git -c <k>=<v> push --force`.
#      The leading token is no longer `git push`, so the prefix-glob deny
#      never matches.
#
# Also covers the bundled short-flag cluster `-fu` / `-uf` and chained
# segments (force-push as 2nd command in `cd x && git push --force`).
#
# Explicitly ALLOWS the GIT-SAFE-07 safe variants `--force-with-lease`
# (with or without `=ref`) and `--force-if-includes`; ordinary `git push`;
# `git fetch <remote> +ref` (fetch `+` is normal); `git pull --force`
# (does not force-push to remote — out of scope); reads (`git log`,
# `git status`); and non-git commands.
#
# Backs: docs/decisions.md 2026-05-25 dhx-git-destructive-guard row (NEW)
#         + HP-037 (the why-this-scope anchor: bare `--force`/`-f` are
#         already caught by the existing deny strings, so this hook
#         exists ONLY for the syntactic bypasses deny-strings structurally
#         cannot see).
# Companion: probe-worktree-bash-guard.sh (orthogonal Bash guard;
#         worktree-leak detection vs git-destructive ops — kept in
#         separate hooks per the same-trip wire-or-retire decision).
#
# Run: bash tests/probes/probe-git-destructive-guard.sh
#
# SAFE_FOR_LIVE: yes   (hook subshell test with synthetic stdin; no real
#                       git invocations — force-push command strings are
#                       blocked by the hook before any shell execution.)

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$REPO/dhx/dhx-git-destructive-guard.sh"

if [[ ! -x "$HOOK" ]]; then
  echo "FAIL hook not found or not executable: $HOOK"
  exit 1
fi

PASSED=0
FAILED=0

# Run hook and capture rc + stdout/stderr merged
_run() {
  local cwd="$1" cmd="$2"
  local input
  input=$(jq -cn --arg c "$cwd" --arg x "$cmd" '{cwd:$c,tool_input:{command:$x}}')
  OUT=$(echo "$input" | bash "$HOOK" 2>&1)
  RC=$?
}

# Same as _run but adds an agent_id (simulates HP-003 v2 subagent propagation)
_run_subagent() {
  local cwd="$1" cmd="$2"
  local input
  input=$(jq -cn --arg c "$cwd" --arg x "$cmd" \
    '{cwd:$c,tool_input:{command:$x},agent_id:"agent-test-123",agent_type:"general-purpose"}')
  OUT=$(echo "$input" | bash "$HOOK" 2>&1)
  RC=$?
}

_assert_block() {
  local name="$1"
  if [[ "$RC" == "2" ]] && [[ "$OUT" == *"BLOCKED"* ]]; then
    echo "OK   $name"; PASSED=$((PASSED + 1))
  else
    echo "FAIL $name — expected exit 2 + BLOCKED, got rc=$RC"
    echo "     output: $OUT"
    FAILED=$((FAILED + 1))
  fi
}

_assert_allow() {
  local name="$1"
  if [[ "$RC" == "0" ]] && [[ -z "$OUT" ]]; then
    echo "OK   $name"; PASSED=$((PASSED + 1))
  else
    echo "FAIL $name — expected exit 0 + silent, got rc=$RC"
    echo "     output: $OUT"
    FAILED=$((FAILED + 1))
  fi
}

CWD="/tmp"

# ── Vector #1: refspec with leading `+` — MUST BLOCK ─────────────────────
_run "$CWD" "git push origin +main"
_assert_block "1: +ref at start of refspec (git push origin +main)"

_run "$CWD" "git push origin +HEAD:main"
_assert_block "2: +HEAD shorthand (git push origin +HEAD:main)"

_run "$CWD" "git push origin main:+refs/heads/x"
_assert_block "3: + after : in src:dst pair"

_run "$CWD" "git push origin +refs/heads/main:refs/heads/main"
_assert_block "4: +refs/heads/... long-form"

# ── Vector #2: leading-token redirection — MUST BLOCK ────────────────────
_run "$CWD" "git -C /tmp push --force"
_assert_block "5: -C path redirection with --force"

_run "$CWD" "git -C /tmp push -f origin main"
_assert_block "6: -C path redirection with -f"

_run "$CWD" "git --git-dir=/tmp/.git push --force"
_assert_block "7: --git-dir= redirection"

_run "$CWD" "git --git-dir /tmp/.git push --force"
_assert_block "8: --git-dir (space) redirection"

_run "$CWD" "git --work-tree=/tmp --git-dir=/tmp/.git push --force"
_assert_block "9: --work-tree + --git-dir combo"

_run "$CWD" "git -c http.proxy=foo push --force"
_assert_block "10: -c k=v (space form)"

_run "$CWD" "git -chttp.proxy=foo push --force"
_assert_block "11: -c<k=v> bundled form"

_run "$CWD" "git --no-pager push --force"
_assert_block "12: --no-pager (no-arg global) + --force"

_run "$CWD" "git -p push --force"
_assert_block "13: -p (paginate) + --force"

# ── Bundled short-flag cluster — MUST BLOCK ──────────────────────────────
_run "$CWD" "git push -fu origin main"
_assert_block "14: -fu bundled short cluster (force + set-upstream)"

_run "$CWD" "git push -uf origin main"
_assert_block "15: -uf bundled short cluster (set-upstream + force)"

# ── Bare forms — MUST BLOCK (defense-in-depth; deny rules also catch) ────
_run "$CWD" "git push --force"
_assert_block "16: bare --force (defense-in-depth)"

_run "$CWD" "git push -f origin main"
_assert_block "17: bare -f (defense-in-depth)"

# ── Chained segments — MUST BLOCK (force-push as 2nd segment) ────────────
_run "$CWD" "cd /tmp && git push --force"
_assert_block "18: && chained (force-push as 2nd segment)"

_run "$CWD" "echo hi; git push origin +main"
_assert_block "19: ; chained with +ref"

_run "$CWD" "false || git push origin +main"
_assert_block "20: || chained with +ref"

_run "$CWD" "git status | tee /tmp/x; git push --force"
_assert_block "21: pipe + ; chained (force-push in final segment)"

# ── Safe variants — MUST ALLOW (silent) ──────────────────────────────────
_run "$CWD" "git push --force-with-lease"
_assert_allow "22: --force-with-lease (GIT-SAFE-07 safe variant)"

_run "$CWD" "git push --force-with-lease=refs/heads/main"
_assert_allow "23: --force-with-lease=ref (with explicit ref)"

_run "$CWD" "git push origin main --force-with-lease"
_assert_allow "24: --force-with-lease at end of arg list"

_run "$CWD" "git push --force-if-includes"
_assert_allow "25: --force-if-includes (GIT-SAFE-07 safe variant)"

_run "$CWD" "git push --force-with-lease --force-if-includes origin main"
_assert_allow "26: combined safe variants"

_run "$CWD" "git -C /tmp push --force-with-lease"
_assert_allow "27: -C redirection + --force-with-lease (no force flag)"

# ── Normal pushes — MUST ALLOW ───────────────────────────────────────────
_run "$CWD" "git push origin main"
_assert_allow "28: ordinary git push origin main"

_run "$CWD" "git push"
_assert_allow "29: git push (no args)"

_run "$CWD" "git push origin HEAD:main"
_assert_allow "30: git push src:dst without +"

_run "$CWD" "git push --set-upstream origin feature"
_assert_allow "31: --set-upstream (long form, no f)"

_run "$CWD" "git push -u origin feature"
_assert_allow "32: -u (set-upstream short, no f)"

# ── Out-of-scope: fetch `+` is normal/safe ───────────────────────────────
_run "$CWD" "git fetch origin +refs/heads/main:refs/heads/upstream"
_assert_allow "33: git fetch +refspec (fetch, not push)"

_run "$CWD" "git fetch origin +main"
_assert_allow "34: git fetch +main (fetch, not push)"

# ── Out-of-scope: pull --force does not force-push to remote ─────────────
_run "$CWD" "git pull --force"
_assert_allow "35: git pull --force (no remote force-push)"

_run "$CWD" "git pull -f origin main"
_assert_allow "36: git pull -f (no remote force-push)"

# ── Reads / other subcommands — MUST ALLOW ───────────────────────────────
_run "$CWD" "git log --oneline"
_assert_allow "37: git log"

_run "$CWD" "git status"
_assert_allow "38: git status"

_run "$CWD" "git diff HEAD~1"
_assert_allow "39: git diff"

_run "$CWD" "git -C /tmp log"
_assert_allow "40: git -C log (read with redirection)"

# ── Non-git commands — MUST ALLOW ────────────────────────────────────────
_run "$CWD" "ls /tmp"
_assert_allow "41: ls (non-git)"

_run "$CWD" "echo 'git push --force'"
_assert_allow "42: echo with literal force-push string (no real invocation)"

_run "$CWD" "grep -r 'git push --force' ."
_assert_allow "43: grep searching for force-push (no real invocation)"

# ── Subagent context (HP-003 v2): same uniform enforcement ───────────────
_run_subagent "$CWD" "git push origin +main"
_assert_block "44: subagent +ref still blocked (HP-003 v2 propagation)"

_run_subagent "$CWD" "git -C /tmp push --force"
_assert_block "45: subagent -C redirection still blocked"

_run_subagent "$CWD" "git push --force-with-lease"
_assert_allow "46: subagent --force-with-lease still allowed"

# ── Malformed / edge cases — silent (never crash) ────────────────────────
OUT=$(echo "not json" | bash "$HOOK" 2>&1); RC=$?
_assert_allow "47: malformed JSON — silent 0"

OUT=$(echo '{}' | bash "$HOOK" 2>&1); RC=$?
_assert_allow "48: empty object — silent 0"

OUT=$(echo '{"tool_input":{}}' | bash "$HOOK" 2>&1); RC=$?
_assert_allow "49: missing command field — silent 0"

OUT=$(echo "{\"tool_input\":{\"command\":\"\"}}" | bash "$HOOK" 2>&1); RC=$?
_assert_allow "50: empty command — silent 0"

# Tool name not Bash? (defensive — hook is matcher-gated, but should still no-op)
OUT=$(echo "{\"tool_input\":{\"command\":\"git push --force\"}}" | bash "$HOOK" 2>&1); RC=$?
_assert_block "51: command without cwd still parsed (tool_name irrelevant — matcher gates)"

# ── Edge: avoid substring false-positive on --force-with-lease ────────────
# --force-with-lease has --force as a string prefix; whole-token match must
# not catch it.
_run "$CWD" "git push --force-with-lease origin main"
_assert_allow "52: --force-with-lease first arg (substring trap)"

_run "$CWD" "git push origin main --force-with-lease=refs/heads/main"
_assert_allow "53: --force-with-lease=ref after refspec (substring trap)"

# ── Edge: + in commit message / quoted arg should NOT trigger ────────────
# This is hard to test perfectly without full shell tokenization. The hook's
# v1 floor is whitespace-tokenized — quoted `+text` as a positional WILL
# false-positive. Documented gap; flagged here so a future tightening lands
# a real shell-tokenizer.
_run "$CWD" "git commit -m '+fixup'"
_assert_allow "54: git commit -m (not push subcommand)"

# ── Summary ──────────────────────────────────────────────────────────────
echo ""
echo "$PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]] && exit 0 || exit 1
