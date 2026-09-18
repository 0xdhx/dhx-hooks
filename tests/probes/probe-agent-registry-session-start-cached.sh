#!/usr/bin/env bash
# probe-agent-registry-session-start-cached.sh — behavior probe backing HP-062.
#
# WHAT THIS PINS: the PASSIVE axis of the `.claude/agents/*.md` agent registry.
# The registry is a snapshot that is never refreshed passively, so an agent file
# written mid-session is NOT dispatchable in that session —
# `Agent(subagent_type="<name>")` refuses with "Agent type '<name>' not found",
# regardless of the file being well-formed. Measured 2026-09-05 on CC 2.1.261 at
# BOTH project and user scope (see docs/hook-patterns.md HP-062).
#
# WHAT THIS DELIBERATELY DOES NOT COVER — and cannot: `/reload-plugins` DOES
# refresh the registry (measured 2026-09-05, both scopes, as an in-session
# before/after). That axis is NOT scriptable here: `/reload-plugins` is a TUI
# slash command, and the `claude -p` children this probe drives cannot issue one.
# So the reload half is operator-measured only, recorded in HP-062's evidence
# bullets. A green run here therefore means "no passive reload", NEVER "a restart
# is required" — do not let this probe's silence on the reload path harden back
# into the fresh-session-only prescription HP-062 already had to retract once.
#
# WHY IT NEEDS A PROBE AT ALL: this is the THIRD load path, and its two siblings
# disagree. `settings.json` hot-reloads at both scopes (HP-012); the plugin
# manifest does not (HP-020). HP-012 previously asserted the OPPOSITE of its
# current claim — upstream changed underneath a sound April probe. So "cached"
# here is a live upstream behavior, not a law: it can flip the same way, and the
# consumers that would silently break are named in the HP-062 row (forgefinder's
# `ff-*` dispatch constraint; `statusline-wrapper.js::checkDrift()`'s agents-dir
# `⚠ restart` warning).
#
# SEMANTICS (Convention B: exit 0 = pass):
#   exit 0 + pass     = mid-session write NOT dispatchable, AND both controls
#                       resolved (so the negative is genuine caching).
#   exit 1 + fail     = the mid-session write RESOLVED with no reload — the
#                       registry now hot-reloads PASSIVELY. Behavior flipped
#                       upstream. Revisit HP-062, HP-012's Process line, the
#                       docs/decisions.md rows, and forgefinder's
#                       `.continue-here.md` blocking constraint, whose
#                       reload-before-dispatch requirement would then be DEAD.
#   exit 0 + skipped  = inconclusive (no auth, subprocess failure, or the child
#                       model deviated from the instructed tool sequence).
#                       NOT a pass, NOT a fail.
#
# THE CONTROL LEGS ARE THE PROBE (do not remove them). A bare "not found" has two
# causes — the registry is cached, or the fixture was malformed / its `name:` did
# not match its basename. Those are indistinguishable from the failed dispatch
# alone, and the malformed-frontmatter trap is not hypothetical: forgefinder
# shipped EIGHT `ff-*` agents with no `name:` field and CC dropped them all from
# the registry with no load-time warning. So:
#   Control 1 (in child 1, after the write): dispatch a session-start-registered
#     agent (`general-purpose`). Proves dispatch works in that child at all.
#   Control 2 (child 2, same project dir): dispatch the SAME fixture file, now
#     pre-existing at that session's start. Resolving proves the file was
#     well-formed all along, so child 1's refusal was genuine caching.
# Child 1 writes the fixture BEFORE its control dispatch on purpose: were the
# roster materialized lazily at first Agent use rather than at session start, a
# control-first ordering would materialize it pre-write and confound the result.
# (That axis was itself measured 2026-09-05 — a session that had never dispatched
# an agent still refused the file it had just written — but the ordering here
# keeps the probe sound without depending on that.)
#
# AUTH: live OAuth. This drives a NON-sandboxed `claude -p` against the real
# CLAUDE_CONFIG_DIR, so no ANTHROPIC_API_KEY is needed and the 2026-05-24
# sandbox cred-seeding hazard (seeding a credentials_file ROTATES and invalidates
# the source credential) is sidestepped entirely. Only cwd is redirected, into a
# throwaway mktemp project dir; nothing under the live repo or ~/.claude is
# written or read as a fixture.
#
# Operator-invoked (NOT via run-probes.sh's 30s loop — claude -p turns exceed it;
# SAFE_FOR_LIVE=no keeps it out of the default pre-commit suite).
#
# SAFE_FOR_LIVE: no    (spawns claude -p subprocesses; mktemp project dir only)
# SUITE_TIMEOUT: 120   (measured 39s, 3/3. Spawns TWO real `claude -p` children; its own
#                       per-child `timeout 240` bounds CORRECTNESS, so this is a STALL bound
#                       — killing a hung run at 120s beats waiting out 480s. Only reachable
#                       under --filter SAFE_FOR_LIVE=no, where the old 30s cap killed it on
#                       every single run.)
# RUNTIME: ~60-180s    (two claude -p turns)
set -uo pipefail

# CC-STDERR: filtered
# Claude Code lints whatever settings.json it is handed and echoes each rule it
# considers questionable VERBATIM to stderr — which lands in the same `2>&1`
# capture this probe then classifies. Route every capture through the filter
# BEFORE any regex touches it. Rationale + exactly what is dropped, and the
# measured 3/3 forged-timeout regression that motivated it: lib/cc-cell-stderr.sh.
# shellcheck source=lib/cc-cell-stderr.sh
source "$(dirname "$0")/lib/cc-cell-stderr.sh"

AUTH_FAIL_RE='Not logged in|Please run /login|Invalid API key|invalid x-api-key|authentication_error|authentication_failed|Invalid authentication credentials|Failed to authenticate|api_error_status":401|Credit balance is too low|OAuth token has expired'

CC_VERSION=$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Unique per run so a stale roster entry from an earlier run can never satisfy
# the test leg. Lowercase/hyphen only — the shape CC accepts for an agent name.
AGENT="probe-reg-cached-$(printf '%04x' $((RANDOM % 65536)))"
CONTROL_TOKEN="CTRL-OK-$$"
TEST_TOKEN="TEST-RESOLVED-$$"

pass=0; fail=0; skipped=0
ck() { # ck <rc> <label>
  if [ "$1" -eq 0 ]; then echo "PASS $2"; pass=$((pass + 1))
  else echo "FAIL $2"; fail=$((fail + 1)); fi
}

echo "probe-agent-registry-session-start-cached: CC $CC_VERSION, agent=$AGENT"

# ---------------------------------------------------------------------------
# Child 1 — write the fixture mid-session, then control, then test.
# ---------------------------------------------------------------------------
read -r -d '' PROMPT1 <<EOF
Do these steps in order. Use NO Agent tool before step 2.

Step 1: Write the file .claude/agents/$AGENT.md relative to the current working
directory, with EXACTLY this content between the markers (do not include the
markers themselves):
<<<BEGIN
---
name: $AGENT
description: throwaway measurement fixture for an agent-registry load-path probe
tools: Read
---

Reply with exactly $TEST_TOKEN and nothing else.
BEGIN>>>

Step 2: Use the Agent tool with subagent_type="general-purpose" and
prompt="Reply with exactly $CONTROL_TOKEN and nothing else. Use no tools."

Step 3: Use the Agent tool with subagent_type="$AGENT" and
prompt="Reply with exactly $TEST_TOKEN and nothing else."

Step 4: Print exactly two lines and nothing else:
CONTROL=<the token step 2 returned, or the first line of its error>
TEST=<the token step 3 returned, or the first line of its error>
EOF

OUT1=$( (cd "$WORK" && timeout 240 claude -p --permission-mode bypassPermissions \
  --model haiku "$PROMPT1" 2>&1) )
RC1=$?
echo "INFO child 1 stderr: $(count_cc_config_advisories "$OUT1") config-advisory line(s) dropped before classification (lib/cc-cell-stderr.sh)"
OUT1=$(strip_cc_config_advisories "$OUT1")

if [ $RC1 -ne 0 ] || grep -qE "$AUTH_FAIL_RE" < <(printf '%s' "$OUT1"); then
  echo "SKIP child 1 did not complete (rc=$RC1 / auth failure) — inconclusive"
  skipped=$((skipped + 1))
  echo "--- child 1 output ---"; printf '%s\n' "$OUT1" | tail -20
  echo "probe-agent-registry-session-start-cached: pass=$pass fail=$fail skipped=$skipped"
  exit 0
fi

# The child must actually have written the fixture; without it step 3 measures
# nothing and a "not found" is trivially true for the wrong reason.
if [ ! -f "$WORK/.claude/agents/$AGENT.md" ]; then
  echo "SKIP child 1 never wrote the fixture — step 1 deviated, inconclusive"
  skipped=$((skipped + 1))
  echo "--- child 1 output ---"; printf '%s\n' "$OUT1" | tail -20
  echo "probe-agent-registry-session-start-cached: pass=$pass fail=$fail skipped=$skipped"
  exit 0
fi

# Independent frontmatter check: name must equal basename. If the child fumbled
# the file, control 2 would fail and we would misread a fixture defect as a
# measurement. Assert it here so the diagnosis is unambiguous.
fm_name=$(sed -n 's/^name: *//p' "$WORK/.claude/agents/$AGENT.md" | head -1)
if [ "$fm_name" != "$AGENT" ]; then
  echo "SKIP child 1 wrote malformed frontmatter (name='$fm_name' != '$AGENT') — inconclusive"
  skipped=$((skipped + 1))
  echo "probe-agent-registry-session-start-cached: pass=$pass fail=$fail skipped=$skipped"
  exit 0
fi

# Control 1: dispatch worked at all in child 1.
if grep -q "$CONTROL_TOKEN" < <(printf '%s' "$OUT1"); then
  ck 0 "control 1: a session-start-registered agent dispatches in child 1"
else
  echo "SKIP control 1 did not resolve — child 1's dispatch path is untrustworthy, inconclusive"
  skipped=$((skipped + 1))
  echo "--- child 1 output ---"; printf '%s\n' "$OUT1" | tail -20
  echo "probe-agent-registry-session-start-cached: pass=$pass fail=$fail skipped=$skipped"
  exit 0
fi

# Test leg: the mid-session write must NOT be dispatchable.
if grep -q "$TEST_TOKEN" < <(printf '%s' "$OUT1"); then
  ck 1 "test: mid-session agent file is NOT dispatchable (it RESOLVED — registry now hot-reloads)"
  registry_hot_reloaded=1
elif grep -qE "not found|Agent type" < <(printf '%s' "$OUT1"); then
  ck 0 "test: mid-session agent file is NOT dispatchable (refused as unknown agent type)"
  registry_hot_reloaded=0
else
  echo "SKIP test leg produced neither the token nor an unknown-agent refusal — inconclusive"
  skipped=$((skipped + 1))
  echo "--- child 1 output ---"; printf '%s\n' "$OUT1" | tail -20
  echo "probe-agent-registry-session-start-cached: pass=$pass fail=$fail skipped=$skipped"
  exit 0
fi

# ---------------------------------------------------------------------------
# Child 2 — same project dir, fixture now pre-exists at session start.
# This is the leg that makes a negative mean anything.
# ---------------------------------------------------------------------------
OUT2=$( (cd "$WORK" && timeout 240 claude -p --permission-mode bypassPermissions \
  --model haiku "Use the Agent tool with subagent_type=\"$AGENT\" and prompt=\"Reply with exactly $TEST_TOKEN and nothing else.\" Then print the returned token, or the first line of the error verbatim. Be terse." 2>&1) )
RC2=$?
echo "INFO child 2 stderr: $(count_cc_config_advisories "$OUT2") config-advisory line(s) dropped before classification (lib/cc-cell-stderr.sh)"
OUT2=$(strip_cc_config_advisories "$OUT2")

if [ $RC2 -ne 0 ] || grep -qE "$AUTH_FAIL_RE" < <(printf '%s' "$OUT2"); then
  echo "SKIP child 2 did not complete (rc=$RC2 / auth failure) — the negative above is UNCONFIRMED"
  skipped=$((skipped + 1))
elif grep -q "$TEST_TOKEN" < <(printf '%s' "$OUT2"); then
  ck 0 "control 2: the same fixture resolves in a session that started after it was written"
else
  echo "SKIP control 2 did not resolve the fixture — the fixture may be malformed, so child 1's"
  echo "     refusal measured nothing. Fix the fixture and re-run rather than recording a result."
  skipped=$((skipped + 1))
  echo "--- child 2 output ---"; printf '%s\n' "$OUT2" | tail -20
fi

if [ "${registry_hot_reloaded:-0}" -eq 1 ]; then
  echo
  echo "BEHAVIOR FLIP: the agent registry now hot-reloads PASSIVELY (no reload needed)."
  echo "  Revisit: docs/hook-patterns.md HP-062 + HP-012 Process line,"
  echo "           docs/decisions.md 2026-09-05 agent-registry rows (both),"
  echo "           docs/troubleshooting.md 'An Agent Type Is Not Found' path,"
  echo "           ~/repos/forgefinder/.planning/milestones/v1.4-phases/25-ff-manager-dashboard/.continue-here.md"
  echo "           + 25-02-SMOKE-RESULTS.md (their reload-before-dispatch requirement would be DEAD)."
fi

echo "probe-agent-registry-session-start-cached: pass=$pass fail=$fail skipped=$skipped"
[ "$fail" -eq 0 ]
