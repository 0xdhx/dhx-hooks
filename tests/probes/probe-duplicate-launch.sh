#!/usr/bin/env bash
# SAFE_FOR_LIVE: yes  (every seam the hook reads is redirected into a mktemp tree: jobs root
#   DHX_BG_JOBS_ROOT, transcript dir DHX_DUP_LAUNCH_TX_DIR, marker dir DHX_DUP_LAUNCH_CACHE_DIR,
#   clock DHX_DUP_LAUNCH_NOW/DHX_BG_JOBS_NOW, and `cwd` in the stdin payload is a throwaway git
#   repo; the live helper under ~/repos/skills/scripts/dhx-history/ is executed READ-ONLY against
#   those fixtures; nothing under ~/.ccs, ~/.cache/dhx or the live repo is read or written)
#
# Exercises dhx/dhx-duplicate-launch.sh — the UserPromptSubmit advisory that fires ONE line when
# the typed prompt names a docs/prompts/…\.md handoff another session is already executing.
# Ruling: ~/repos/skills/docs/decisions/2026-09-19-duplicate-prompt-launch-surface-never-gate.md
# (§ Decision item 4). Backs docs/decisions.md 2026-09-19 "duplicate-launch advisory line" row.
#
# Sections (each behavioural cell carries a positive control — the same fixture, one field moved):
#   A. wiring        — file, # Patterns:, hooks.json registration (timeout 5), reads .prompt
#   B. guards        — no-path prompt is silent and fast (best-of-10 ≤ 10 ms, measured); bad JSON,
#                      agent_id, kill switch, helper absent, helper exit 3, vet-shaped prompt
#   C. bg jobs       — dup fires naming lane/job + 91m; same-minute fan-out silent; stopped job,
#                      vet-intent job, self-by-sessionId, self-by-CLAUDE_JOB_DIR all silent;
#                      primary is the EARLIEST across lanes
#   D. interactive   — dup fires naming session <uuid8>; a path present ONLY in a hook-injected
#                      `attachment` row + an isMeta row is silent (the naive-grep refutation);
#                      vet command opener, self transcript, outside the mtime window all silent;
#                      a transcript that is also a bg job's is counted once, as the job
#   E. channels      — systemMessage + additionalContext on one object; trailer clause present
#                      with a fixture commit carrying the session's Claude-Session trailer,
#                      absent without
#   F. marker        — second turn naming the same path in the same session is silent; another
#                      session is not
#   G. both sources  — earliest start wins across job + interactive
#
# NEGATIVE CONTROLS RUN 2026-09-19 (mutant copies of the hook via DHX_PROBE_HOOK; section A reads
# the real file so it stays green under every mutant; each mutant reds exactly the cells named):
#   gap rule inverted (`-ge` → `-lt`)         15 red: B0 C1 C2 C7 D1 D2+ D6 E1 E3 E5 F0 F2 F3 G1 G2
#                                             (C2 is the fan-out control FIRING — the tooth)
#   vet exclusion on the signal deleted        2 red: C4 D3
#   SEEN_TX dedupe deleted                     2 red: D6 D6b — only after D6's fixture put the
#                                             transcript's first row BEFORE the job's createdAt;
#                                             with equal starts the job won on a sort tiebreak
#                                             and the cell was hollow (README § two layers)
# The attachment-row filter is the helper's own; D2+ is D2's positive control (same pre-rows,
# path moved into the prose opener → fires), which is what makes D2's silence an assertion.
#
# Run: bash tests/probes/probe-duplicate-launch.sh

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${DHX_PROBE_HOOK:-$REPO_ROOT/dhx/dhx-duplicate-launch.sh}"
HOOKS_JSON="$REPO_ROOT/dhx-plugin/plugins/dhx/hooks/hooks.json"
HELPER="$HOME/repos/skills/scripts/dhx-history/enumerate-bg-jobs.sh"

PASS=0; FAIL=0
ok(){ echo "OK   $1"; PASS=$((PASS+1)); }
bad(){ echo "FAIL $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }
chk(){ if [ "$2" = ok ]; then ok "$1"; else bad "$1" "${3:-}"; fi; }

command -v jq >/dev/null 2>&1 || { echo "PROBE ERROR: jq missing"; exit 2; }
[ -f "$HELPER" ] || { echo "PROBE ERROR: helper missing at $HELPER (skills repo not checked out)"; exit 2; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
NOW=$(date +%s)
JOBS="$TMP/jobs"; TXD="$TMP/tx"; CACHE="$TMP/cache"; CWD="$TMP/repo"
mkdir -p "$JOBS" "$TXD" "$CACHE" "$CWD"
KEY="docs/prompts/2026-09-19-fixture-handoff-prompt.md"
KEY2="docs/prompts/2026-09-19-other-handoff-prompt.md"
SELF="11111111-1111-4111-8111-111111111111"
SELF_TX="$TXD/$SELF.jsonl"
SURL="claude.ai/code/session_01FIXTUREAAAABBBBCCCCDDDD"

iso(){ date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z; }

# --- fixture builders ----------------------------------------------------------------------
# mk_job <lane> <id> <created_epoch> <intent> [sessionId] [state] [linkScanPath]
mk_job(){
  local d="$JOBS/$1/jobs/$2"; mkdir -p "$d"
  jq -n --arg st "${6:-working}" --arg c "$(iso "$3")" --arg u "$(iso "$NOW")" --arg i "$4" \
        --arg sid "${5:-$2-0000-4000-8000-000000000000}" --arg l "${7:-}" \
        '{state:$st, tempo:"active", intent:$i, createdAt:$c, updatedAt:$u, sessionId:$sid,
          cwd:"/fixture", name:"fx"} + (if $l != "" then {linkScanPath:$l} else {} end)' > "$d/state.json"
}
# mk_tx <path> <first_epoch> <opener_content> [pre_rows_file]  — a transcript whose first
# timestamped row is a user prose turn; optional pre-rows (attachment / isMeta) inserted before it.
mk_tx(){
  local p="$1" t="$2" c="$3" pre="${4:-}"
  { printf '%s\n' '{"type":"last-prompt","sessionId":"x"}' '{"type":"mode","sessionId":"x"}'
    [ -n "$pre" ] && cat "$pre"
    jq -nc --arg ts "$(iso "$t")" --arg c "$c" '{type:"user",timestamp:$ts,isMeta:null,message:{role:"user",content:$c}}'
    jq -nc --arg ts "$(iso "$((t+5))")" '{type:"assistant",timestamp:$ts,message:{role:"assistant",content:[{type:"text",text:"ok"}]}}'
  } > "$p"
}
# mk_tx_cmd <path> <first_epoch> <cmd> <args>  — opener is a slash-command row (no prose turn)
mk_tx_cmd(){
  local c; c=$(printf '<command-message>%s</command-message>\n<command-name>%s</command-name>\n<command-args>%s</command-args>' "${3#/}" "$3" "$4")
  mk_tx "$1" "$2" "$c"
}
reset_fixtures(){ rm -rf "$JOBS" "$TXD" "$CACHE"; mkdir -p "$JOBS" "$TXD" "$CACHE"; }

# fire <prompt> [session_id] [extra jq object]  → stdout of the hook; sets RC
fire(){
  local sid="${2:-$SELF}" extra="${3:-{\}}"
  local payload; payload=$(jq -nc --arg p "$1" --arg s "$sid" --arg t "$TXD/$sid.jsonl" --arg c "$CWD" --argjson x "$extra" \
    '{prompt:$p, session_id:$s, transcript_path:$t, cwd:$c} + $x')
  OUT=$(printf '%s' "$payload" | env -u CLAUDE_JOB_DIR DHX_BG_JOBS_ROOT="$JOBS" DHX_BG_JOBS_NOW="$NOW" \
        DHX_DUP_LAUNCH_NOW="$NOW" DHX_DUP_LAUNCH_TX_DIR="$TXD" DHX_DUP_LAUNCH_CACHE_DIR="$CACHE" \
        ${FIRE_ENV:-} bash "$HOOK" 2>/dev/null); RC=$?
}
msg(){ printf '%s' "$OUT" | jq -r '.systemMessage // ""' 2>/dev/null; }
# silent <label>: rc 0 and empty stdout
silent(){ if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "$1"; else bad "$1" "rc=$RC out=${OUT:0:80}"; fi; }
# fires <label> <substring...>: rc 0, systemMessage contains every substring
fires(){ local l="$1"; shift; local m; m=$(msg)
  if [ "$RC" -ne 0 ] || [ -z "$m" ]; then bad "$l" "rc=$RC out=${OUT:0:80}"; return; fi
  for s in "$@"; do case "$m" in *"$s"*) ;; *) bad "$l" "missing '$s' in: $m"; return ;; esac; done; ok "$l"; }

echo "=== A. Wiring ==="
[ -f "$REPO_ROOT/dhx/dhx-duplicate-launch.sh" ] && ok "A1 dhx/dhx-duplicate-launch.sh present" || bad "A1 hook present"
grep -q '^# Patterns:' "$REPO_ROOT/dhx/dhx-duplicate-launch.sh" && ok "A2 # Patterns: header" || bad "A2 # Patterns: header"
jq -e '[.hooks.UserPromptSubmit[].hooks[] | select(.command | test("dhx-duplicate-launch\\.sh")) | .timeout] == [5]' "$HOOKS_JSON" >/dev/null 2>&1 \
  && ok "A3 hooks.json registers it under UserPromptSubmit with timeout 5" || bad "A3 hooks.json registration (timeout 5)"
grep -qE "jq -r '\.prompt // \"\"'" "$REPO_ROOT/dhx/dhx-duplicate-launch.sh" && ok "A4 reads .prompt (HP-008), not .user_prompt" || bad "A4 reads .prompt"

echo "=== B. Guards ==="
reset_fixtures
fire "please summarise the last commit"; silent "B1 [pre-state: guard] prompt without a docs/prompts path is silent"
best=999999; for i in 1 2 3 4 5 6 7 8 9 10; do s=$(date +%s%N); printf '%s' '{"prompt":"hello","session_id":"x"}' | bash "$HOOK" >/dev/null 2>&1; e=$(date +%s%N); d=$(( (e-s)/1000 )); [ "$d" -lt "$best" ] && best=$d; done
[ "$best" -le 10000 ] && ok "B2 no-path exit best-of-10 = ${best}us (≤ 10 ms budget; routing hook's shape)" || bad "B2 no-path exit too slow" "best-of-10 ${best}us"
OUT=$(printf '%s' '{not json' | bash "$HOOK" 2>/dev/null); RC=$?; silent "B3 unparseable stdin is silent, exit 0"
OUT=$(printf '%s' 'docs/prompts/x.md {not json' | bash "$HOOK" 2>/dev/null); RC=$?; silent "B3b unparseable stdin that passes the prefix gate is silent, exit 0"
# a live duplicate fixture, used by the remaining guard cells as their positive control
mk_job a j1 "$((NOW-5460))" "run $KEY"
fire "run $KEY"; fires "B0 [pre-state: control] the guard fixture DOES fire without a guard" "job a/j1"
rm -rf "$CACHE"/*
fire "run $KEY" "$SELF" '{"agent_id":"agent-xyz"}'; silent "B4 agent_id payload is silent"
rm -rf "$CACHE"/*
FIRE_ENV="DHX_SKIP_DUPLICATE_LAUNCH=1" fire "run $KEY"; silent "B5 kill switch DHX_SKIP_DUPLICATE_LAUNCH=1 is silent"; FIRE_ENV=""
rm -rf "$CACHE"/*
FIRE_ENV="DHX_DUP_LAUNCH_HELPER=$TMP/nonexistent/enumerate-bg-jobs.sh" fire "run $KEY"; silent "B6 [pre-state: guard] helper absent → exit 0, no output"; FIRE_ENV=""
rm -rf "$CACHE"/*
mkdir -p "$TMP/nojobs"; FIRE_ENV="DHX_BG_JOBS_ROOT=$TMP/nojobs" fire "run $KEY"; silent "B7 [pre-state: guard] helper exit 3 (no jobs dir) → exit 0, no output"; FIRE_ENV=""
rm -rf "$CACHE"/*
fire "/dhx:vet $KEY"; silent "B8 [pre-state: control] a /dhx:vet-shaped typed prompt is a reader → silent"

echo "=== C. Background jobs ==="
reset_fixtures; mk_job a j1 "$((NOW-5460))" "run $KEY"
fire "run $KEY"; fires "C1 [pre-state: control] dup 91 min apart → line names the earlier job" "$KEY is already running" "job a/j1" "started 91m ago" "active now"
reset_fixtures; mk_job a j1 "$((NOW-20))" "run $KEY"
fire "run $KEY"; silent "C2 [pre-state: control] same fixture, primary created 20s ago → fan-out, no line"
reset_fixtures; mk_job a j1 "$((NOW-5460))" "run $KEY" "" stopped
fire "run $KEY"; silent "C3 a stopped job on the path is not a running duplicate"
reset_fixtures; mk_job a j1 "$((NOW-5460))" "/dhx:vet $KEY"
fire "run $KEY"; silent "C4 [pre-state: control] a job whose opener is /dhx:vet <path> is a reader → silent"
reset_fixtures; mk_job a j1 "$((NOW-5460))" "run $KEY" "$SELF"
fire "run $KEY"; silent "C5 a job whose state.json sessionId is this session is self → silent"
reset_fixtures; mk_job a j1 "$((NOW-5460))" "run $KEY"
FIRE_ENV="CLAUDE_JOB_DIR=$JOBS/a/jobs/j1" fire "run $KEY"; silent "C6 a job whose dir is \$CLAUDE_JOB_DIR is self → silent"; FIRE_ENV=""
reset_fixtures; mk_job a j1 "$((NOW-1800))" "run $KEY"; mk_job b j2 "$((NOW-7200))" "run ./$KEY"
fire "run $KEY"; fires "C7 primary is the EARLIEST start across lanes (b/j2 at 2h beats a/j1 at 30m)" "job b/j2" "started 2h00m ago"
reset_fixtures; mk_job a j1 "$((NOW-5460))" "run $KEY2"
fire "run $KEY"; silent "C8 a job on a DIFFERENT handoff is not a duplicate"

echo "=== D. Interactive transcripts ==="
reset_fixtures; O="22222222-2222-4222-8222-222222222222"; mk_tx "$TXD/$O.jsonl" "$((NOW-5460))" "run $KEY"
fire "run $KEY"; fires "D1 [pre-state: control] an interactive session on the path 91 min ago → line names session <uuid8>" "session 22222222" "started 91m ago" "active now"
reset_fixtures
PRE="$TMP/pre.jsonl"
{ jq -nc --arg c "SessionStart:startup hook success: Scheduled work is due (1): source: /home/x/$KEY" \
     '{type:"attachment",attachment:{type:"hook_system_message",content:$c}}'
  jq -nc --arg ts "$(iso "$((NOW-5460))")" --arg c "context: source: /home/x/$KEY" \
     '{type:"user",timestamp:$ts,isMeta:true,message:{role:"user",content:[{type:"text",text:$c}]}}'; } > "$PRE"
mk_tx "$TXD/$O.jsonl" "$((NOW-5460))" "run $KEY2" "$PRE"
fire "run $KEY"; silent "D2 [pre-state: control] path present ONLY in a hook-injected attachment row + isMeta row → silent (naive grep would tag it)"
rm -rf "$CACHE"/*; mk_tx "$TXD/$O.jsonl" "$((NOW-5460))" "run $KEY" "$PRE"
fire "run $KEY"; fires "D2+ positive control: the SAME pre-rows with the path in the prose opener → fires" "session 22222222"
reset_fixtures; mk_tx_cmd "$TXD/$O.jsonl" "$((NOW-5460))" "/dhx:vet" "$KEY"
fire "run $KEY"; silent "D3 [pre-state: control] a /dhx:vet <path> command opener in the other session → silent"
reset_fixtures; mk_tx "$SELF_TX" "$((NOW-5460))" "run $KEY"
fire "run $KEY"; silent "D4 this session's own transcript is never a candidate"
reset_fixtures; mk_tx "$TXD/$O.jsonl" "$((NOW-5460))" "run $KEY"; touch -d '3 hours ago' "$TXD/$O.jsonl"
fire "run $KEY"; silent "D5 a transcript outside the 120-min mtime window is not 'still active' → silent"
# The transcript's first row PREDATES the job's createdAt (a job resumed onto an existing
# transcript): without the dedupe the interactive candidate would be the earliest start and win
# the label — so this cell reds when the SEEN_TX dedupe is deleted, not on a sort tiebreak.
reset_fixtures; mk_tx "$TXD/$O.jsonl" "$((NOW-5500))" "run $KEY"; mk_job a j1 "$((NOW-5460))" "run $KEY" "" working "$TXD/$O.jsonl"
fire "run $KEY"; fires "D6 a transcript that is a bg job's linkScanPath is counted ONCE, as the job" "job a/j1"
if [ "$RC" -eq 0 ]; then case "$(msg)" in *"session 22222222"*) bad "D6b …and not also as an interactive session" ;; *) ok "D6b …and not also as an interactive session" ;; esac; fi

echo "=== E. Channels + trailer clause ==="
reset_fixtures; mk_tx "$TXD/$O.jsonl" "$((NOW-5460))" "run $KEY"
fire "run $KEY"
printf '%s' "$OUT" | jq -e '.systemMessage and .hookSpecificOutput.hookEventName == "UserPromptSubmit" and .hookSpecificOutput.additionalContext' >/dev/null 2>&1 \
  && ok "E1 one JSON object carrying BOTH systemMessage (operator) and additionalContext (model)" || bad "E1 both channels" "${OUT:0:120}"
m=$(msg); c=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""')
case "$c" in "$m"*) ok "E2 additionalContext opens with the operator line verbatim" ;; *) bad "E2 additionalContext prefix" ;; esac
case "$m" in "⚠ $KEY is already running:"*) ok "E3 operator line opens '⚠ <path> is already running:'" ;; *) bad "E3 line shape" "$m" ;; esac
case "$m" in *"last commit"*) bad "E4 no trailer clause when the transcript carries no session URL" "$m" ;; *) ok "E4 no trailer clause when the transcript carries no session URL" ;; esac
# fixture repo with a commit carrying that session's Claude-Session trailer, and the URL in the transcript head
( cd "$CWD" && git init -q . && git -c user.email=p@x -c user.name=p commit -q --allow-empty -m "$(printf 'fx: other session commit\n\nClaude-Session: https://%s' "$SURL")" ) 2>/dev/null
H=$(git -C "$CWD" log -1 --format=%h)
rm -rf "$CACHE"/*
{ jq -nc --arg ts "$(iso "$((NOW-5460))")" --arg c "attribution: Claude-Session: https://$SURL" \
     '{type:"user",timestamp:$ts,isMeta:true,message:{role:"user",content:[{type:"text",text:$c}]}}'; } > "$PRE"
mk_tx "$TXD/$O.jsonl" "$((NOW-5460))" "run $KEY" "$PRE"
fire "run $KEY"; fires "E5 [pre-state: control] trailer clause names the last commit carrying that session's Claude-Session trailer" "(last commit $H by that session)"

echo "=== F. Once per (session, path) ==="
reset_fixtures; mk_job a j1 "$((NOW-5460))" "run $KEY"; mk_job a j3 "$((NOW-5460))" "run $KEY2"
fire "run $KEY"; fires "F0 first turn naming the path fires" "job a/j1"
fire "git mv $KEY docs/prompts/done/"; silent "F1 a later turn in the SAME session naming the same path is silent (marker)"
fire "run $KEY2"; fires "F2 …but a different path in the same session evaluates on its own" "job a/j3"
fire "run $KEY" "33333333-3333-4333-8333-333333333333"; fires "F3 …and another session naming the first path still gets its line" "job a/j1"

echo "=== G. Both sources ==="
reset_fixtures; mk_tx "$TXD/$O.jsonl" "$((NOW-5460))" "run $KEY"; mk_job a j1 "$((NOW-1800))" "run $KEY"
fire "run $KEY"; fires "G1 interactive at 91m beats job at 30m → the earliest start is named" "session 22222222" "started 91m ago"
reset_fixtures; mk_tx "$TXD/$O.jsonl" "$((NOW-1800))" "run $KEY"; mk_job a j1 "$((NOW-5460))" "run $KEY"
fire "run $KEY"; fires "G2 …and the other way round" "job a/j1" "started 91m ago"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
