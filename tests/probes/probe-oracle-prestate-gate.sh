#!/usr/bin/env bash
# probe-oracle-prestate-gate.sh — regression probe for dhx/dhx-oracle-prestate-gate.sh
# SAFE_FOR_LIVE: yes
# RUNTIME: ~5s
#
# Invariant exercised: the dispatch station of the oracle pre-state gate runs the
# tool once per distinct plan named in a `gsd-executor` dispatch prompt, labels
# every record `station=dispatch`, measures against the dispatch tree's HEAD, and
# is REPORT-ONLY — it surfaces VIOLATED and never exits 2, never sets a
# permissionDecision, and never fabricates a record when it found no plan.
#
# Backs: docs/decisions.md 2026-09-02 "oracle pre-state gate — dispatch station"
#        row; skills DEC-2026-09-02-oracle-prestate-gate-report-only-execute-item-f
#        Amendment 1 ruling (1) "two stations, both run, labelled".
#
# Run: bash tests/probes/probe-oracle-prestate-gate.sh
#
# Isolation: every case runs inside a mktemp root. HOME and CLAUDE_CONFIG_DIR are
# both redirected there, so the hook's tool lookup ($HOME/.claude/dhx-tools/) and
# the tool's own defaultAuditDir ($CLAUDE_CONFIG_DIR/dhx-state/oracle-audit/)
# resolve inside the fixture. The real tool is reached by symlink — never copied,
# so the probe measures the shipping tool. Nothing reads or writes live state.
#
# MUTATION PROOF (§3.7 of the initiating prompt — run by hand before commit,
# results recorded in the decisions.md row):
#   1. drop `--station dispatch` from the hook's argv  -> case [2c] reds
#      (record carries the tool's default station=prechain, not dispatch)
#   2. change the VIOLATED arm's `exit 0` to `exit 2`  -> case [4a] reds
#      (report-only disposition broken; a dispatch would be blocked)
#   3. revert the on-disk disambiguation (make the `/*` arm containment-only)
#      -> cases [11b] and [12b] red; [13] stays green, proving the two
#      properties are independent and the fix did not just widen the guard

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/dhx/dhx-oracle-prestate-gate.sh"
TOOL="$HOME/.claude/dhx-tools/oracle-prestate-check.cjs"
PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf 'OK   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1 (expected $3, got $2)"; fi; }
contains(){ case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (missing '$3' in: $(printf '%s' "$2" | head -c 200))" ;; esac; }

if [ ! -e "$TOOL" ]; then
  printf 'SKIP oracle-prestate-check.cjs not provisioned at %s — nothing to measure\n' "$TOOL"
  printf '\n0 passed, 0 failed\n'
  exit 0
fi
command -v jq   >/dev/null 2>&1 || { printf 'SKIP jq unavailable\n\n0 passed, 0 failed\n'; exit 0; }
command -v node >/dev/null 2>&1 || { printf 'SKIP node unavailable\n\n0 passed, 0 failed\n'; exit 0; }

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

FIX_HOME="$TMPROOT/home"
FIX_CFG="$TMPROOT/cfg"
REPO="$TMPROOT/repo"
AUDIT="$FIX_CFG/dhx-state/oracle-audit/repo.jsonl"

mkdir -p "$FIX_HOME/.claude/dhx-tools" "$FIX_CFG"
ln -s "$(readlink -f "$TOOL")" "$FIX_HOME/.claude/dhx-tools/oracle-prestate-check.cjs"

# --- fixture repo: a GSD project with one grep-able source file ---------------
mkdir -p "$REPO/.planning/phases/01-x" "$REPO/.planning/quick"
printf 'alpha\nbeta\n' > "$REPO/f.py"
printf '{}\n' > "$REPO/.planning/config.json"
git -C "$REPO" init -q
git -C "$REPO" add -A
git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm init
HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)

# A guard clause on a token ABSENT from the tree measures 0 -> HONOURED.
cat > "$REPO/.planning/phases/01-x/01-01-PLAN.md" <<'PLAN'
<acceptance_criteria>
    - no zzz leaks in: `grep -cF "zzz" f.py` returns 0 [pre-state: guard]
</acceptance_criteria>
PLAN

# A guard clause on a token PRESENT in the tree measures 1 -> VIOLATED.
cat > "$REPO/.planning/phases/01-x/01-02-PLAN.md" <<'PLAN'
<acceptance_criteria>
    - no alpha leaks in: `grep -cF "alpha" f.py` returns 0 [pre-state: guard]
</acceptance_criteria>
PLAN

cat > "$REPO/.planning/quick/99-01-PLAN.md" <<'PLAN'
<acceptance_criteria>
    - no zzz leaks in: `grep -cF "zzz" f.py` returns 0 [pre-state: guard]
</acceptance_criteria>
PLAN

# stdin_json <subagent_type> <prompt>
stdin_json() {
  jq -n --arg t "$1" --arg p "$2" --arg c "$REPO" \
    '{hook_event_name:"PreToolUse", tool_name:"Agent", cwd:$c,
      tool_input:{subagent_type:$t, prompt:$p}}'
}

# run_hook <subagent_type> <prompt>  -> sets RC / OUT / ERR
run_hook() {
  local in; in=$(stdin_json "$1" "$2")
  set +e
  OUT=$(printf '%s' "$in" | env HOME="$FIX_HOME" CLAUDE_CONFIG_DIR="$FIX_CFG" \
        bash "$HOOK" 2>"$TMPROOT/err")
  RC=$?
  set -e
  ERR=$(cat "$TMPROOT/err")
}

records() { [ -f "$AUDIT" ] && wc -l < "$AUDIT" | tr -d ' ' || echo 0; }
reset_audit() { rm -f "$AUDIT"; }

# --- [1] non-executor subagent is not our business ---------------------------
reset_audit
run_hook gsd-verifier 'run .planning/phases/01-x/01-01-PLAN.md now'
check '[1a] gsd-verifier dispatch -> exit 0' "$RC" 0
check '[1b] ...and emits nothing on stdout' "$([ -n "$OUT" ] && echo noisy || echo empty)" empty
check '[1c] ...and writes no audit record' "$(records)" 0

# --- [2] the happy path: one plan, clean, labelled, at the dispatch tree ------
reset_audit
run_hook gsd-executor 'Execute .planning/phases/01-x/01-01-PLAN.md in a worktree.'
check '[2a] clean executor dispatch -> exit 0' "$RC" 0
contains '[2b] additionalContext reports the scope-honest phrase' "$OUT" 'declared pre-state matched'
check '[2c] exactly one record, station=dispatch' \
  "$(jq -r 'select(.station=="dispatch")|.station' "$AUDIT" 2>/dev/null | wc -l | tr -d ' ')" 1
check '[2d] record carries the derived phase' "$(jq -r '.phase' "$AUDIT")" 1
check '[2e] record tree_sha == dispatch tree HEAD' "$(jq -r '.tree_sha' "$AUDIT")" "$HEAD_SHA"
contains '[2f] additionalContext echoes tree_sha for base-SHA comparison' "$OUT" "$HEAD_SHA"
check '[2g] output is a PreToolUse hookSpecificOutput envelope' \
  "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName')" PreToolUse
check '[2h] ...and sets no permissionDecision (report-only)' \
  "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // "none"')" none

# --- [3] no plan path in the prompt: fail-VISIBLE, and no fabricated record ---
reset_audit
run_hook gsd-executor 'Go execute the next wave, you know the one.'
check '[3a] no plan path -> exit 0' "$RC" 0
contains '[3b] additionalContext says the station did not run' "$OUT" 'no plan path found'
contains '[3c] stderr carries the same line' "$ERR" 'no plan path found'
check '[3d] no record is fabricated (would poison the firing rate)' "$(records)" 0

# --- [4] VIOLATED is surfaced and NEVER blocks -------------------------------
reset_audit
run_hook gsd-executor 'Execute .planning/phases/01-x/01-02-PLAN.md now.'
check '[4a] VIOLATED dispatch -> exit 0, never 2' "$RC" 0
contains '[4b] additionalContext carries the marker' "$OUT" 'ORACLE_PRESTATE_VIOLATED'
contains '[4c] ...and states the disposition' "$OUT" 'report-only'
check '[4d] record counts one violation' "$(jq -r '.counts.violated' "$AUDIT")" 1
check '[4e] ...still labelled dispatch' "$(jq -r '.station' "$AUDIT")" dispatch
check '[4f] VIOLATED path still sets no permissionDecision' \
  "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // "none"')" none

# --- [5] tool absent: existence-gated, zero change ---------------------------
reset_audit
BARE_HOME="$TMPROOT/barehome"; mkdir -p "$BARE_HOME"
set +e
OUT=$(stdin_json gsd-executor 'Execute .planning/phases/01-x/01-01-PLAN.md now.' \
      | env HOME="$BARE_HOME" CLAUDE_CONFIG_DIR="$FIX_CFG" bash "$HOOK" 2>/dev/null)
RC=$?
set -e
check '[5a] no dhx-tools -> exit 0' "$RC" 0
check '[5b] ...and emits nothing' "$([ -n "$OUT" ] && echo noisy || echo empty)" empty
check '[5c] ...and writes no record' "$(records)" 0

# --- [6] dedupe: one record per distinct plan, repeats collapse --------------
reset_audit
run_hook gsd-executor 'Execute .planning/phases/01-x/01-01-PLAN.md.
Re-read .planning/phases/01-x/01-01-PLAN.md before starting.
Then .planning/quick/99-01-PLAN.md.'
check '[6a] repeated + multi-plan dispatch -> exit 0' "$RC" 0
check '[6b] one record for the whole dispatch' "$(records)" 1
check '[6c] both distinct plans measured (2 honoured clauses, not 3)' \
  "$(jq -r '.counts.honoured' "$AUDIT")" 2

# --- [7] a plan path that does not exist on disk is not trusted --------------
reset_audit
run_hook gsd-executor 'Execute .planning/phases/01-x/01-99-PLAN.md now.'
check '[7a] phantom plan path -> exit 0' "$RC" 0
contains '[7b] reported as no plan found, not as clean' "$OUT" 'no plan path found'
check '[7c] no record' "$(records)" 0

# --- [8] quick-only dispatch omits --phase (no phases/NN segment) ------------
reset_audit
run_hook gsd-executor 'Execute .planning/quick/99-01-PLAN.md now.'
check '[8a] quick plan -> exit 0' "$RC" 0
check '[8b] record phase is null (no --phase passed)' "$(jq -r '.phase' "$AUDIT")" null

# --- [9] a non-GSD repo is out of scope --------------------------------------
reset_audit
NONGSD="$TMPROOT/plain"; mkdir -p "$NONGSD/.planning/phases/01-x"
git -C "$NONGSD" init -q 2>/dev/null
cp "$REPO/.planning/phases/01-x/01-01-PLAN.md" "$NONGSD/.planning/phases/01-x/"
set +e
OUT=$(jq -n --arg c "$NONGSD" \
        '{hook_event_name:"PreToolUse",tool_name:"Agent",cwd:$c,
          tool_input:{subagent_type:"gsd-executor",
                      prompt:"Execute .planning/phases/01-x/01-01-PLAN.md now."}}' \
      | env HOME="$FIX_HOME" CLAUDE_CONFIG_DIR="$FIX_CFG" bash "$HOOK" 2>/dev/null)
RC=$?
set -e
check '[9a] no .planning/config.json -> exit 0' "$RC" 0
check '[9b] ...and emits nothing' "$([ -n "$OUT" ] && echo noisy || echo empty)" empty

# --- [10] malformed stdin never crashes --------------------------------------
set +e
OUT=$(printf 'not json at all' | env HOME="$FIX_HOME" CLAUDE_CONFIG_DIR="$FIX_CFG" \
      bash "$HOOK" 2>/dev/null)
RC=$?
set -e
check '[10a] unparseable stdin -> exit 0' "$RC" 0
check '[10b] ...and emits nothing' "$([ -n "$OUT" ] && echo noisy || echo empty)" empty

# --- [11] the MAINLINE shape: an UNEXPANDED variable as the repo root --------
# `${PROJECT_ROOT}/.planning/...` is how the gsd-execute-phase orchestrator
# renders plan paths — measured in 9 resource-monitor transcripts across phases
# 01/02/03 (2026-09-02). The regex's prefix group captures only the `/` after
# the brace, so the hit arrives as `/.planning/...`; before the on-disk
# disambiguation this failed the containment test and EVERY such dispatch was
# dropped with "no plan path found". The station never ran on the path it was
# built for. This arm is the regression pin.
reset_audit
run_hook gsd-executor 'Execute ${PROJECT_ROOT}/.planning/phases/01-x/01-01-PLAN.md in a worktree.'
check '[11a] ${PROJECT_ROOT}-prefixed plan -> exit 0' "$RC" 0
check '[11b] ...is measured, not dropped' "$(records)" 1
contains '[11c] ...and reports a real measurement' "$OUT" 'declared pre-state matched'
check '[11d] ...with the phase still derived through the prefix' "$(jq -r '.phase' "$AUDIT")" 1

# --- [12] a tilde-rooted prefix is the same class ----------------------------
reset_audit
run_hook gsd-executor 'Execute ~/repos/whatever/.planning/phases/01-x/01-01-PLAN.md now.'
check '[12a] ~-prefixed plan -> exit 0' "$RC" 0
check '[12b] ...is measured, not dropped' "$(records)" 1

# --- [13] the containment guard SURVIVES the fix -----------------------------
# The disambiguation must not become a blanket re-root: a hit that genuinely
# RESOLVES on disk outside this repo is another repo's plan, and mapping it onto
# our same-named plan is the original hazard. It must still be dropped.
reset_audit
OTHER="$TMPROOT/otherrepo"
mkdir -p "$OTHER/.planning/phases/01-x"
cp "$REPO/.planning/phases/01-x/01-01-PLAN.md" "$OTHER/.planning/phases/01-x/01-01-PLAN.md"
run_hook gsd-executor "Execute $OTHER/.planning/phases/01-x/01-01-PLAN.md now."
check '[13a] another repo real absolute path -> exit 0' "$RC" 0
contains '[13b] ...is refused, not re-rooted onto our same-named plan' "$OUT" 'no plan path found'
check '[13c] ...and writes no record' "$(records)" 0

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
