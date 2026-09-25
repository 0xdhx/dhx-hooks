#!/usr/bin/env bash
# probe-worktree-write-guard.sh
#
# Regression probe for dhx/dhx-worktree-write-guard.sh.
#
# Invariant: PreToolUse:Edit|Write|MultiEdit emits a structured
#   permissionDecision:"deny" on stdout with exit 0 (D-03; fail-closed to exit 2
#   if the emit fails) when
#   (a) cwd is inside a Claude Code managed worktree (.claude/worktrees/),
#   (b) tool_input.file_path is absolute, and
#   (c) file_path is outside the enclosing worktree prefix.
# All other paths exit 0 + silent (allow).
#
# Backs: docs/decisions.md 2026-04-19 worktree-write-guard row.
# Companion: probe-agent-leak-check.sh covers the subagent-side detector.
#
# Run: bash tests/probes/probe-worktree-write-guard.sh

# SAFE_FOR_LIVE: yes   (hook subshell test with synthetic stdin; assertions on hook exit code only)
set -uo pipefail

HOOK="${DHX_PROBE_HOOK:-$(cd "$(dirname "$0")/../.." && pwd)/dhx/dhx-worktree-write-guard.sh}"

if [[ ! -x "$HOOK" ]]; then
  echo "FAIL hook not found or not executable: $HOOK"
  exit 1
fi

PASS=0
FAIL=0

run() {
  local name="$1" input="$2" kind="$3"
  # kind=deny → D-03 contract: exit 0 + permissionDecision:"deny" on stdout.
  # kind=allow → exit 0 + silent. (The fail-closed exit-2 fallback is the D-09
  # emit-failure path, exercised in the adversarial node:test, not here.)
  local code=0 out
  out=$(echo "$input" | "$HOOK" 2>/dev/null) || code=$?
  case "$kind" in
    deny)
      if [[ "$code" == "0" ]] && [[ "$out" == *'"permissionDecision":"deny"'* ]]; then
        echo "OK   $name (deny: exit 0 + permissionDecision:deny)"; PASS=$((PASS+1))
      else
        echo "FAIL $name (expected exit 0 + deny-JSON, got exit=$code out=$out)"; FAIL=$((FAIL+1))
      fi ;;
    allow)
      if [[ "$code" == "0" ]] && [[ -z "$out" ]]; then
        echo "OK   $name (allow: exit 0 + silent)"; PASS=$((PASS+1))
      else
        echo "FAIL $name (expected exit 0 + silent, got exit=$code out=$out)"; FAIL=$((FAIL+1))
      fi ;;
    *) echo "FAIL $name (probe bug: unknown kind '$kind')"; FAIL=$((FAIL+1)) ;;
  esac
}

# --- Scenarios ---

# [1] Not in any worktree → allow
run "[1] cwd=main-repo, file=main-repo → allow" \
  '{"cwd":"/home/dhx/repos/hooks","tool_input":{"file_path":"/home/dhx/repos/hooks/dhx/x.sh"}}' \
  allow

# [2] In worktree, file inside same worktree → allow
run "[2] cwd=worktree, file=worktree → allow" \
  '{"cwd":"/home/dhx/repos/hooks/.claude/worktrees/agent-aaa","tool_input":{"file_path":"/home/dhx/repos/hooks/.claude/worktrees/agent-aaa/dhx/x.sh"}}' \
  allow

# [3] In worktree, file in main repo → BLOCK (primary leak signature)
run "[3] cwd=worktree, file=main-repo → BLOCK" \
  '{"cwd":"/home/dhx/repos/hooks/.claude/worktrees/agent-aaa","tool_input":{"file_path":"/home/dhx/repos/hooks/dhx/x.sh"}}' \
  deny

# [4] In worktree, relative file_path → allow (CC resolves against cwd)
run "[4] cwd=worktree, file=relative → allow" \
  '{"cwd":"/home/dhx/repos/hooks/.claude/worktrees/agent-aaa","tool_input":{"file_path":"dhx/x.sh"}}' \
  allow

# [5] cwd is worktree subdir, file is in worktree's docs dir → allow
run "[5] cwd=worktree/subdir, file=worktree root → allow" \
  '{"cwd":"/home/dhx/repos/hooks/.claude/worktrees/agent-aaa/dhx","tool_input":{"file_path":"/home/dhx/repos/hooks/.claude/worktrees/agent-aaa/docs/x.md"}}' \
  allow

# [6] Two different worktrees → BLOCK (cross-worktree write)
run "[6] cwd=worktree-A, file=worktree-B → BLOCK" \
  '{"cwd":"/home/dhx/repos/hooks/.claude/worktrees/agent-aaa","tool_input":{"file_path":"/home/dhx/repos/hooks/.claude/worktrees/agent-bbb/x.md"}}' \
  deny

# [7] Malformed JSON → allow (defensive, never crash)
run "[7] malformed JSON → allow" \
  'not valid json' \
  allow

# [8] Missing file_path key → allow
run "[8] missing file_path → allow" \
  '{"cwd":"/home/dhx/repos/hooks/.claude/worktrees/agent-aaa","tool_input":{}}' \
  allow

# [9] Empty cwd → allow
run "[9] empty cwd → allow" \
  '{"cwd":"","tool_input":{"file_path":"/anywhere/x.sh"}}' \
  allow

# [10] Writing to /tmp from worktree → ALLOW. FLIPPED 2026-09-25 (was BLOCK): /tmp is a
# sanctioned scratch root by operator ruling — 136 of this guard's 141 false denies in 90 days
# were scratch writes (reports/2026-09-25-guard-false-positive-census.md fix 3). The scratch
# allowance canonicalizes first; [15]-[25] below pin what it must still refuse.
run "[10] cwd=worktree, file=/tmp → allow (scratch root)" \
  '{"cwd":"/home/dhx/repos/hooks/.claude/worktrees/agent-aaa","tool_input":{"file_path":"/tmp/scratch.txt"}}' \
  allow

# [11] Nested worktree directory with trailing slash variation
run "[11] cwd=worktree no trailing slash, file=worktree nested → allow" \
  '{"cwd":"/home/dhx/repos/hooks/.claude/worktrees/agent-aaa","tool_input":{"file_path":"/home/dhx/repos/hooks/.claude/worktrees/agent-aaa/deep/nested/file.md"}}' \
  allow

# [12]-[14] the 2026-09-25 NUL-framed parse (docs/decisions.md 2026-09-25 row). ALL THREE ARE
# CHARACTERIZATION — green against the c76e949b `@tsv` copy too, measured, and never teeth.
# The old parse's collapse fired only on an EMPTY cwd, and with no cwd this guard has nothing
# to anchor a deny on, so the shifted fields reached the same `allow` (verdict-neutral over a
# 7-payload pre/post matrix). They pin the new parse's contract: positions hold, exact bytes
# survive, and a NUL inside a field keeps the old verdict. [14] is the exception to "never teeth"
# against the INTERMEDIATE draft: a reject-NUL parse emptied both fields and ALLOWED it.
run "[12] empty cwd, file path inside a worktree → allow (no cwd, no anchor)" \
  '{"cwd":"","tool_input":{"file_path":"/home/dhx/repos/hooks/.claude/worktrees/agent-aaa/x.sh"}}' \
  allow
run "[13] cwd=worktree, newline-bearing file path outside → BLOCK (exact bytes, no @tsv escape)" \
  '{"cwd":"/home/dhx/repos/hooks/.claude/worktrees/agent-aaa","tool_input":{"file_path":"/etc/a\nb"}}' \
  deny
run "[14] NUL inside a worktree cwd → BLOCK, as the @tsv parse did (a guard never loosens)" \
  '{"cwd":"/home/dhx/repos/hooks/.claude/worktrees/agent-aaa\u0000x","tool_input":{"file_path":"/etc/x"}}' \
  deny

# --- [15]-[25]: scratch roots (2026-09-25) — /tmp and THIS session's job dir, canonicalized ---
# The job dir is derived from hook stdin, never from $CLAUDE_JOB_DIR: jobs live at
# <config>/jobs/<first 8 of session_id> (194 of 194 job dirs matched, measured 2026-09-25), and
# a variable is settable to anything ([18]). Fixtures live OUTSIDE /tmp (under ~/.cache) so the
# job-dir cells cannot pass on the /tmp rule by accident. The hardlink cell is a real attack
# here: /tmp and $HOME share one filesystem on this host (df, 2026-09-25).
WT='/home/dhx/repos/hooks/.claude/worktrees/agent-aaa'
FIX="$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/probe-wwg.XXXXXX")"
TFIX="$(mktemp -d /tmp/probe-wwg.XXXXXX)"
trap 'rm -rf "$FIX" "$TFIX"' EXIT
CFG="$FIX/cfg"; mkdir -p "$CFG/jobs/abcd1234/tmp" "$CFG/jobs/ffff0000/tmp" "$FIX/fakebin"
SID='abcd1234-0000-4000-8000-000000000000'
ln -s /home/dhx/repos/hooks "$TFIX/main-alias"
printf 'x' > "$TFIX/linked"; ln "$TFIX/linked" "$TFIX/linked2"
printf '#!/bin/sh\nexit 1\n' > "$FIX/fakebin/realpath"; chmod +x "$FIX/fakebin/realpath"
_p() { jq -nc --arg c "$WT" --arg f "$1" --arg s "${2-}" \
  'if $s == "" then {cwd:$c,tool_input:{file_path:$f}} else {session_id:$s,cwd:$c,tool_input:{file_path:$f}} end'; }
run_env() { # $1 env assignment(s) as one string, then run's args
  local envs="$1"; shift
  local name="$1" input="$2" kind="$3" code=0 out
  out=$(echo "$input" | env $envs "$HOOK" 2>/dev/null) || code=$?
  case "$kind" in
    deny)  if [[ "$code" == "0" && "$out" == *'"permissionDecision":"deny"'* ]]; then echo "OK   $name"; PASS=$((PASS+1));
           else echo "FAIL $name (expected deny, got exit=$code out=$out)"; FAIL=$((FAIL+1)); fi ;;
    allow) if [[ "$code" == "0" && -z "$out" ]]; then echo "OK   $name"; PASS=$((PASS+1));
           else echo "FAIL $name (expected allow, got exit=$code out=$out)"; FAIL=$((FAIL+1)); fi ;;
  esac
}
run_env "CLAUDE_CONFIG_DIR=$CFG" "[15] this session's job dir → allow" \
  "$(_p "$CFG/jobs/abcd1234/tmp/x.txt" "$SID")" allow
run_env "CLAUDE_CONFIG_DIR=$CFG" "[16] ANOTHER session's job dir → BLOCK" \
  "$(_p "$CFG/jobs/ffff0000/tmp/x.txt" "$SID")" deny
run_env "CLAUDE_CONFIG_DIR=$CFG" "[17] job-dir path but no session_id on stdin → BLOCK" \
  "$(_p "$CFG/jobs/abcd1234/tmp/x.txt")" deny
run_env "CLAUDE_CONFIG_DIR=$CFG CLAUDE_JOB_DIR=/home/dhx/repos/hooks" "[18] CLAUDE_JOB_DIR aimed at main is ignored → BLOCK" \
  "$(_p "/home/dhx/repos/hooks/dhx/x.sh" "$SID")" deny
run "[19] /tmp symlink alias into the main repo → BLOCK (canonicalized)" \
  "$(_p "$TFIX/main-alias/dhx/x.sh")" deny
run "[20] /tmp/../ traversal into the main repo → BLOCK" \
  "$(_p "/tmp/../home/dhx/repos/hooks/dhx/x.sh")" deny
run "[21] existing /tmp target with a second hard link → BLOCK" \
  "$(_p "$TFIX/linked")" deny
run "[22] \$HOME dotfile → BLOCK (not a scratch root)" \
  "$(_p "/home/dhx/.bashrc")" deny
# A fixed PATH, not "$FIX/fakebin:$PATH": run_env word-splits its env string and this host's
# PATH carries "/mnt/c/Program Files/…" (WSL), which split it into a command -> exit 127.
run_env "PATH=$FIX/fakebin:/usr/local/bin:/usr/bin:/bin" "[23] realpath fails → BLOCK (structured deny, never exit 1)" \
  "$(_p "/tmp/scratch2.txt")" deny
run "[24] /tmpfoo prefix spoof → BLOCK" \
  "$(_p "/tmpfoo/x.txt")" deny
run_env "CLAUDE_CONFIG_DIR=$CFG" "[25] session with no job dir (interactive) → BLOCK" \
  "$(_p "$CFG/jobs/eeee1111/tmp/x.txt" "eeee1111-0000-4000-8000-000000000000")" deny

echo ""
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
