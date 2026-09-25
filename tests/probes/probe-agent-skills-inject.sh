#!/usr/bin/env bash
# SAFE_FOR_LIVE: yes  (fixture-only: mktemp projects + a mktemp CLAUDE_CONFIG_DIR, so the
#   hook's dhx-state log and gsd-core's global: skills base both resolve inside the fixture;
#   runs the real gsd-core resolver read-only against fixture configs; no live writes)
#
# Exercises dhx-agent-skills-inject.sh — the SubagentStart hook that injects a project's
# configured gsd agent_skills BODIES into every gsd-* subagent, including hand-written
# Agent() dispatches that gsd-core's workflow templates never reach.
#
#   A. WIRING: registered under SubagentStart with a ^gsd- matcher; `# Patterns:` header.
#   B. POSITIVE: configured type -> additionalContext carries the body, frontmatter
#      stripped, the don't-Read-again line; relative and global: refs; log `injected`.
#   C. SILENT: unconfigured gsd type -> no stdout, log `none` (liveness: the hook ran and
#      decided); non-gsd type -> no stdout AND no log line (rc checked, log size compared
#      against a literal count).
#   D. COULD-NOT-ANSWER: missing gsd-tools, a resolver printing non-JSON, a configured
#      skill that resolves to nothing -> the subagent is TOLD ("NOT the same as none"),
#      never silence; log `could-not-answer`.
#   E. PARTIAL: one of two skills unreadable -> readable body delivered + notice; `partial`.
#   F. FAIL-OPEN: malformed stdin -> rc 0, no stdout.
#
# Run: bash tests/probes/probe-agent-skills-inject.sh

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/dhx/dhx-agent-skills-inject.sh"
HOOKS_JSON="$REPO_ROOT/dhx-plugin/plugins/dhx/hooks/hooks.json"
REAL_GSD_TOOLS="$HOME/.claude/gsd-core/bin/gsd-tools.cjs"

pass=0; fail=0
ok()  { echo "OK   $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; fail=$((fail+1)); }
chk() { if [ "$2" = "0" ]; then ok "$1"; else bad "$1${3:+ — $3}"; fi; }

if [ ! -f "$HOOK" ] || [ ! -f "$REAL_GSD_TOOLS" ]; then
  echo "PROBE ERROR: hook ($HOOK) or gsd-tools ($REAL_GSD_TOOLS) missing — cannot run"; exit 2
fi

T="$(mktemp -d)"; trap 'chmod -R u+rw "$T" 2>/dev/null; rm -rf "$T"' EXIT
CCD="$T/ccd"; mkdir -p "$CCD/skills/xr-global-probe"
LOG="$CCD/dhx-state/agent-skills-inject.jsonl"

mkskill() { # dir name body-token
  mkdir -p "$1"
  printf -- '---\nname: %s\ndescription: probe fixture\n---\n\n# %s heading\n\nBODY-TOKEN %s\n' "$2" "$2" "$3" > "$1/SKILL.md"
}
mkskill "$CCD/skills/xr-global-probe" xr-global-probe GLOBAL-K7

P="$T/proj"; mkdir -p "$P/.planning" "$P/sub/dir"
mkskill "$P/skills/rel-one" rel-one REL-Q2
mkskill "$P/skills/rel-two" rel-two REL-W5
cat > "$P/.planning/config.json" <<'EOF'
{
  "agent_skills": {
    "gsd-code-reviewer": ["skills/rel-one", "global:xr-global-probe"],
    "gsd-executor": ["skills/rel-one", "skills/rel-two"],
    "gsd-verifier": ["skills/does-not-exist"]
  }
}
EOF

run() { # agent_type cwd [extra env...] -> sets OUT RC
  local at="$1" cwd="$2"; shift 2
  OUT="$(printf '{"session_id":"s","agent_id":"a1","agent_type":"%s","cwd":"%s","hook_event_name":"SubagentStart"}' "$at" "$cwd" \
        | env CLAUDE_CONFIG_DIR="$CCD" "$@" bash "$HOOK" 2>/dev/null)"; RC=$?
}
logn() { [ -f "$LOG" ] && wc -l < "$LOG" | tr -d ' ' || echo 0; }
last_outcome() { tail -n1 "$LOG" 2>/dev/null | jq -r '.outcome' 2>/dev/null; }
ctx() { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null; }

# --- A. wiring -------------------------------------------------------------------------
M="$(jq -r '.hooks.SubagentStart[]? | select(.hooks[]?.command | test("dhx-agent-skills-inject.sh")) | .matcher' "$HOOKS_JSON" 2>/dev/null)"
[ "$M" = "^gsd-" ]; chk "A1 registered under SubagentStart with matcher ^gsd-" $? "got matcher=[$M]"
grep -q '^# Patterns: .*HP-065' "$HOOK"; chk "A2 # Patterns: header declares HP-065" $?

# --- B. positive -----------------------------------------------------------------------
run gsd-code-reviewer "$P/sub/dir"
C="$(ctx)"
[ "$RC" -eq 0 ] && [ -n "$C" ]; chk "B1 reviewer from a subdir: rc 0 and non-empty additionalContext" $? "rc=$RC out=[$OUT]"
[ "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName' 2>/dev/null)" = "SubagentStart" ]; chk "B2 hookEventName is SubagentStart" $?
grep -q 'BODY-TOKEN REL-Q2' <<<"$C"; chk "B3 relative skill body injected" $?
grep -q 'BODY-TOKEN GLOBAL-K7' <<<"$C"; chk "B4 global: skill body injected (resolved via CLAUDE_CONFIG_DIR/skills)" $?
grep -q 'BODY-TOKEN REL-Q2' <<<"$C" && ! grep -q '^description: probe fixture' <<<"$C"
chk "B5 frontmatter stripped (body present AND its literal frontmatter line absent)" $?
grep -q 'do not Read their paths again' <<<"$C"; chk "B6 carries the don't-Read-again line" $?
[ "$(last_outcome)" = "injected" ]; chk "B7 log outcome injected" $? "got [$(last_outcome)]"

# --- C. silent paths -------------------------------------------------------------------
run gsd-planner "$P"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ "$(last_outcome)" = "none" ]; chk "C1 unconfigured gsd type: no stdout, log none" $? "rc=$RC out=[$OUT] outcome=[$(last_outcome)]"
before="$(logn)"
run general-purpose "$P"
after="$(logn)"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ "$after" = "$before" ] && [ "$before" = "2" ]; chk "C2 non-gsd type: rc 0, no stdout, log stays at exactly 2 lines" $? "rc=$RC out=[$OUT] log $before->$after"

# --- D. could-not-answer ---------------------------------------------------------------
run gsd-code-reviewer "$P" DHX_AGENT_SKILLS_GSD_TOOLS="$T/nope.cjs"
grep -q 'NOT the same as none' <<<"$(ctx)"; chk "D1 missing gsd-tools -> subagent told could-not-answer" $? "out=[$OUT]"
[ "$(last_outcome)" = "could-not-answer" ]; chk "D2 log outcome could-not-answer" $?
printf 'console.log("not json")\n' > "$T/garbage.cjs"
run gsd-code-reviewer "$P" DHX_AGENT_SKILLS_GSD_TOOLS="$T/garbage.cjs"
grep -q 'no JSON object' <<<"$(ctx)"; chk "D3 resolver printing non-JSON -> could-not-answer, not none" $? "out=[$OUT]"
run gsd-verifier "$P"
# gsd-core reports skills_count 1 here with an empty block — the hook must not trust the count.
C="$(ctx)"
grep -q 'NOT the same as none' <<<"$C" && grep -q 'Skill not found at' <<<"$C"
chk "D4 configured skill resolving to nothing -> could-not-answer carrying gsd's warning" $? "out=[$OUT]"

# --- E. partial ------------------------------------------------------------------------
chmod 000 "$P/skills/rel-two/SKILL.md"
run gsd-executor "$P"
chmod 644 "$P/skills/rel-two/SKILL.md"
C="$(ctx)"
grep -q 'BODY-TOKEN REL-Q2' <<<"$C" && grep -q 'could NOT be loaded (unreadable: skills/rel-two/SKILL.md)' <<<"$C"
chk "E1 one unreadable of two: readable body delivered + named notice" $? "out=[$OUT]"
[ "$(last_outcome)" = "partial" ]; chk "E2 log outcome partial" $?

# --- F. fail-open ----------------------------------------------------------------------
OUT="$(printf 'not json at all' | env CLAUDE_CONFIG_DIR="$CCD" bash "$HOOK" 2>/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ]; chk "F1 malformed stdin: rc 0, no stdout" $? "rc=$RC out=[$OUT]"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
