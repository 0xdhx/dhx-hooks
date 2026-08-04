#!/usr/bin/env bash
# probe-worktree-bash-guard.sh
#
# Regression probe for dhx/dhx-worktree-bash-guard.sh (PreToolUse:Bash).
#
# Invariant: blocks Bash tool calls that include a write-verb targeting a
# main-repo absolute path when cwd is inside a CC-managed worktree.
# Silent (allow) on: reads, write-verbs scoped to worktree, cwd outside any
# worktree, missing inputs.
#
# Backs: docs/decisions.md 2026-04-19 worktree-bash-guard row (co-row with
# dhx-stale-worktree-sweep).
#
# Companion: probe-worktree-write-guard.sh (Edit|Write|MultiEdit matcher).
#
# Run: bash tests/probes/probe-worktree-bash-guard.sh

# SAFE_FOR_LIVE: yes   (hook subshell test with synthetic stdin; no real writes (write-attempt strings are blocked by hook before execution))
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$REPO/dhx/dhx-worktree-bash-guard.sh"

if [[ ! -x "$HOOK" ]]; then
  echo "FAIL hook not found or not executable: $HOOK"
  exit 1
fi

PASSED=0
FAILED=0

WT_CWD="/home/dhx/repos/forgefinder/.claude/worktrees/agent-test/"
WT_PATH="/home/dhx/repos/forgefinder/.claude/worktrees/agent-test/scripts/hub.js"
MAIN_PATH="/home/dhx/repos/forgefinder/scripts/hub.js"
MAIN_CWD="/home/dhx/repos/forgefinder"

# Run hook and capture rc + stdout
_run() {
  local cwd="$1" cmd="$2"
  local input
  input=$(jq -cn --arg c "$cwd" --arg x "$cmd" '{cwd:$c,tool_input:{command:$x}}')
  OUT=$(echo "$input" | bash "$HOOK" 2>&1)
  RC=$?
}

_assert_block() {
  local name="$1"
  # D-03 contract: a block now emits structured permissionDecision:"deny" on stdout
  # with exit 0 (was: bare "BLOCKED" text + exit 2). The fail-closed fallback is
  # exit 2, exercised separately by the D-09 emit-failure test, not here.
  if [[ "$RC" == "0" ]] && [[ "$OUT" == *'"permissionDecision":"deny"'* ]]; then
    echo "OK   $name"; PASSED=$((PASSED + 1))
  else
    echo "FAIL $name — expected exit 0 + permissionDecision:deny, got rc=$RC"
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

# ── Leak vectors: MUST BLOCK ────────────────────────────────────────────────
_run "$WT_CWD" "sed -i s/foo/bar/ $MAIN_PATH"
_assert_block "1: sed -i on main path from worktree cwd"

_run "$WT_CWD" "echo hi | tee $MAIN_PATH"
_assert_block "2: tee to main path"

_run "$WT_CWD" "echo hi | tee -a $MAIN_PATH"
_assert_block "3: tee -a to main path"

_run "$WT_CWD" "echo test >> $MAIN_PATH"
_assert_block "4: >> redirect to main path"

_run "$WT_CWD" "printf 'x\\n' > $MAIN_PATH"
_assert_block "5: printf > to main path"

_run "$WT_CWD" "python3 -c \"open('$MAIN_PATH','w').write('y')\""
_assert_block "6: python3 -c writing main path"

_run "$WT_CWD" "python -c \"open('$MAIN_PATH','w').write('y')\""
_assert_block "7: python -c (no 3) writing main path"

_run "$WT_CWD" "dd if=/dev/zero of=$MAIN_PATH bs=1 count=1"
_assert_block "8: dd of= to main path"

_run "$WT_CWD" "install -m 644 /tmp/x $MAIN_PATH"
_assert_block "9: install to main path"

_run "$WT_CWD" "cat <<EOF > $MAIN_PATH
content
EOF"
_assert_block "10: heredoc > main path"

# ── Safe operations: MUST ALLOW (silent) ────────────────────────────────────
_run "$WT_CWD" "sed -i s/foo/bar/ $WT_PATH"
_assert_allow "11: sed -i on worktree path (scoped correctly)"

_run "$WT_CWD" "echo hi > $WT_PATH"
_assert_allow "12: > redirect to worktree path"

_run "$WT_CWD" "cat $MAIN_PATH"
_assert_allow "13: cat (read) main path"

_run "$WT_CWD" "git -C $MAIN_CWD log"
_assert_allow "14: git log referencing main path (no write verb)"

_run "$WT_CWD" "grep -r foo $MAIN_CWD"
_assert_allow "15: grep (read) main repo"

_run "$WT_CWD" "ls $MAIN_CWD/scripts/"
_assert_allow "16: ls main repo (read)"

# cwd outside any worktree → silent
_run "$MAIN_CWD" "sed -i s/foo/bar/ $MAIN_PATH"
_assert_allow "17: sed -i on main path with cwd in main (no worktree context)"

_run "/tmp" "sed -i s/foo/bar/ /tmp/x"
_assert_allow "18: cwd entirely unrelated to worktrees"

# Worktree cwd, write-verb, but no main path reference → silent
_run "$WT_CWD" "sed -i s/foo/bar/ /tmp/unrelated.txt"
_assert_allow "19: sed -i on unrelated /tmp path (no main-repo hit)"

# ── Malformed input: silent (never crash) ────────────────────────────────
OUT=$(echo "not json" | bash "$HOOK" 2>&1); RC=$?
_assert_allow "20: malformed JSON — silent 0"

OUT=$(echo '{}' | bash "$HOOK" 2>&1); RC=$?
_assert_allow "21: empty object — silent 0"

OUT=$(echo '{"cwd":""}' | bash "$HOOK" 2>&1); RC=$?
_assert_allow "22: empty cwd — silent 0"

OUT=$(echo "{\"cwd\":\"$WT_CWD\",\"tool_input\":{}}" | bash "$HOOK" 2>&1); RC=$?
_assert_allow "23: worktree cwd + missing command — silent 0"

# ── Edge cases ───────────────────────────────────────────────────────────
# Command substring includes sed without -i → no write verb, allow
_run "$WT_CWD" "sed s/foo/bar/ $MAIN_PATH | cat"
_assert_allow "24: sed without -i is read-only → allow"

# Legitimate redirect to /dev/null should not panic the hook
_run "$WT_CWD" "git -C $MAIN_CWD log > /dev/null"
_assert_allow "25: redirect to /dev/null → allow"

# ── Stdin-parse shape arms (2026-08-03) ──────────────────────────────────
# The write-verb detector was correct; the INPUT PATH was starving it. The old
# `jq … | @tsv` + `read` parse escaped a real newline/tab into `\`+`n` / `\`+`t`, so the
# character preceding a line-start write verb was the ALNUM letter `n`/`t` and the
# `(^|[^[:alnum:]_])` anchors could never fire — `tee`, `sed -i` and `python3 -c` at the
# start of a continuation line ALL escaped this guard silently. Same defect and same commit
# as dhx-plugin/…/pre-tool-use-gh-issue-write.sh (probe arms [74]-[80] there).
# Assert the SHAPE, not the verb: one shape across three verbs beats one multi-line arm per
# verb. BITE-TESTED — 26/27/28 each measured SILENT against the pre-fix @tsv parse.
#
# PAYLOAD NOTE — the leading fixture line is `export D=/tmp`, not the errexit-DISABLE directive.
# verify-hook-patterns.sh's probe set-flag discipline lint greps ADDED LINES for that directive and
# cannot tell a shell directive from a quoted fixture payload (it would flag this comment for
# naming it, hence the description rather than the token). Its only exemption is a line-anchored
# errexit ENABLE, which a probe must not carry — errexit would abort the suite on the first failing
# assertion. Only the SHAPE is under test: a line, then the verb at line-start. Do NOT reintroduce
# the disable directive as fixture data, and do NOT add an errexit enable to silence the lint.
# Same note in probe-gh-issue-write.sh.
NL=$'\n'; TAB=$'\t'
_run "$WT_CWD" "export D=/tmp${NL}tee $MAIN_PATH"
_assert_block "26: BITE — tee at START of line 2 → block"

_run "$WT_CWD" "cd /tmp${NL}${TAB}sed -i s/foo/bar/ $MAIN_PATH"
_assert_block "27: BITE — sed -i on line 2, TAB-indented → block"

_run "$WT_CWD" "export D=/tmp${NL}python3 -c \"open('$MAIN_PATH','w').write('y')\""
_assert_block "28: BITE — python3 -c at START of line 2 → block"

# NON-VACUITY / CHARACTERIZATION, not a bite test: already blocked pre-fix. Pins the real
# predicate — the ESCAPED WHITESPACE CHARACTER before the verb, not "multi-line". A
# space-indented line-2 call always matched, because @tsv leaves a real space alone.
_run "$WT_CWD" "export D=/tmp${NL}  tee $MAIN_PATH"
_assert_block "29: CHAR (pre-existing) — tee line 2, SPACE-indented → block"

# The fix must not over-fire: a worktree-local write stays allowed on a multi-line command.
_run "$WT_CWD" "export D=/tmp${NL}tee $WT_PATH"
_assert_allow "30: worktree-local tee at START of line 2 → allow (scoping survives)"

# ── Summary ──────────────────────────────────────────────────────────────
echo ""
echo "$PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]] && exit 0 || exit 1
