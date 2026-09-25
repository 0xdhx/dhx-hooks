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
# The job dir is the one whose state.json names hook stdin's session_id as the job's LIVE id,
# `(.resumeSessionId // .sessionId)` — never $CLAUDE_JOB_DIR, which is settable to anything ([18]),
# and never the dir NAME: a dir is named after the BIRTH id, and 85 of 193 job dirs on this host
# had rotated away from it (2026-09-25, `resumeSessionId != sessionId` over
# ~/.ccs/instances/*/jobs/*/state.json) — [26]-[33] pin that. Fixtures live OUTSIDE /tmp (under ~/.cache) so the
# job-dir cells cannot pass on the /tmp rule by accident. The hardlink cell is a real attack
# here: /tmp and $HOME share one filesystem on this host (df, 2026-09-25).
WT='/home/dhx/repos/hooks/.claude/worktrees/agent-aaa'
FIX="$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/probe-wwg.XXXXXX")"
TFIX="$(mktemp -d /tmp/probe-wwg.XXXXXX)"
trap 'rm -rf "$FIX" "$TFIX"' EXIT
CFG="$FIX/cfg"; mkdir -p "$CFG/jobs/abcd1234/tmp" "$CFG/jobs/ffff0000/tmp" "$FIX/fakebin"
SID='abcd1234-0000-4000-8000-000000000000'
_state() { jq -nc --arg s "$2" --arg r "${3-}" 'if $r == "" then {sessionId:$s} else {sessionId:$s,resumeSessionId:$r} end' > "$1/state.json"; }
_state "$CFG/jobs/abcd1234" "$SID" "$SID"
_state "$CFG/jobs/ffff0000" 'ffff0000-0000-4000-8000-000000000000' 'ffff0000-0000-4000-8000-000000000000'
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

# --- [26]-[33]: session-id ROTATION (2026-09-25 follow-up) — the job dir is found through its
# state.json's LIVE id, not its name. A job dir is named after the BIRTH id; after /clear (or a
# resume that mints, or some /compact continuations) hook stdin carries a NEW id and CC rewrites
# `resumeSessionId` to it. The name-keyed guard looked for jobs/<new 8>, found nothing and denied
# the session its own scratch dir ([26] reds on that guard, naming the rotation; [27] reds too,
# because the name-keyed guard kept admitting the dead birth id).
ROT_BIRTH='b1b1b1b1-0000-4000-8000-000000000000'; ROT_LIVE='9999aaaa-0000-4000-8000-000000000000'
mkdir -p "$CFG/jobs/b1b1b1b1/tmp" "$CFG/jobs/f0f0f0f0" "$CFG/jobs/c0c0c0c0" "$CFG/jobs/d0d0d0d0" "$FIX/outside" "$CFG/jobs/e0e0e0e0/tmp"
_state "$CFG/jobs/b1b1b1b1" "$ROT_BIRTH" "$ROT_LIVE"
run_env "CLAUDE_CONFIG_DIR=$CFG" "[26] rotated session (/clear): live id finds its birth-named job dir → allow" \
  "$(_p "$CFG/jobs/b1b1b1b1/tmp/x.py" "$ROT_LIVE")" allow
run_env "CLAUDE_CONFIG_DIR=$CFG" "[27] rotated session's dead BIRTH id → BLOCK (live id only)" \
  "$(_p "$CFG/jobs/b1b1b1b1/tmp/x.py" "$ROT_BIRTH")" deny
# The id appears in the file, so grep's prefilter hits — only in fields that are not the job's live id.
jq -nc --arg s "$SID" '{sessionId:"f0f0f0f0-0000-4000-8000-000000000000",resumeSessionId:"f0f0f0f0-0000-4000-8000-000000000000",forkParentSessionId:$s,intent:("resume " + $s)}' > "$CFG/jobs/f0f0f0f0/state.json"
run_env "CLAUDE_CONFIG_DIR=$CFG" "[28] id only in fork-parent / intent fields → BLOCK" \
  "$(_p "$CFG/jobs/f0f0f0f0/x.txt" "$SID")" deny
jq -nc --arg s "$SID" '{sessionId:$s,resumeSessionId:$s}' > "$FIX/borrowed-state.json"
ln -s "$FIX/borrowed-state.json" "$CFG/jobs/c0c0c0c0/state.json"
run_env "CLAUDE_CONFIG_DIR=$CFG" "[29] symlinked state.json naming this session → BLOCK" \
  "$(_p "$CFG/jobs/c0c0c0c0/x.txt" "$SID")" deny
_state "$FIX/outside" "$SID" "$SID"; rmdir "$CFG/jobs/d0d0d0d0"; ln -s "$FIX/outside" "$CFG/jobs/d0d0d0d0"
run_env "CLAUDE_CONFIG_DIR=$CFG" "[30] job dir symlinked OUTSIDE <config>/jobs → BLOCK" \
  "$(_p "$CFG/jobs/d0d0d0d0/x.txt" "$SID")" deny
_state "$CFG/jobs/e0e0e0e0" 'e0e0e0e0-0000-4000-8000-000000000000'
run_env "CLAUDE_CONFIG_DIR=$CFG" "[31] legacy state.json without resumeSessionId → sessionId is the live id → allow" \
  "$(_p "$CFG/jobs/e0e0e0e0/tmp/x.txt" 'e0e0e0e0-0000-4000-8000-000000000000')" allow
# [32] the full-UUID gate is what stops an EMPTY id: `grep -F ""` matches every state file, and a
# state.json whose ids are "" would then satisfy the jq equality. (A bare 8-hex prefix is already
# refused by jq's full-string compare, so that shape is not what this arm guards.)
mkdir -p "$CFG/jobs/a0a0a0a0/tmp"
printf '{"sessionId":"","resumeSessionId":""}' > "$CFG/jobs/a0a0a0a0/state.json"
run_env "CLAUDE_CONFIG_DIR=$CFG" "[32] empty session_id vs a state.json whose ids are empty → BLOCK (full UUID required)" \
  "$(jq -nc --arg c "$WT" --arg f "$CFG/jobs/a0a0a0a0/tmp/x.txt" '{session_id:"",cwd:$c,tool_input:{file_path:$f}}')" deny
# [33] the deny names what was RESOLVED, not the rule. The 2026-09-25 false deny promised
# "$CLAUDE_JOB_DIR" — a variable the guard never reads — and so hid an empty resolution.
_deny_text() { printf '%s' "$1" | env "CLAUDE_CONFIG_DIR=$CFG" "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null; }
R1=$(_deny_text "$(_p "/home/dhx/repos/hooks/dhx/x.sh" "$ROT_LIVE")")
R2=$(_deny_text "$(_p "/home/dhx/repos/hooks/dhx/x.sh" "eeee1111-0000-4000-8000-000000000000")")
REAL_ROT=$(realpath -e -- "$CFG/jobs/b1b1b1b1")
if [[ "$R1" == *"session_id=9999aaaa"*": $REAL_ROT."* && "$R2" == *"session_id=eeee1111"*": none."* && "$R1$R2" != *'CLAUDE_JOB_DIR'* ]]; then
  echo "OK   [33] deny text names the resolved job dir (rotated → its dir; no job → none), never \$CLAUDE_JOB_DIR"; PASS=$((PASS+1))
else
  echo "FAIL [33] deny text does not name the resolution (R1=$R1 | R2=$R2)"; FAIL=$((FAIL+1))
fi

echo ""
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
