#!/usr/bin/env bash
# dhx-audit-checkpoint.sh — SubagentStop hook
# Patterns: HP-011, HP-021
# Injects audit calibration when a gsd-verifier agent completes.
# Counteracts optimistic completion bias at the moment verification
# results are returned. Advisory only — no blocking.
#
# 2026-05-07 event migration: PostToolUse:Agent → SubagentStop. PostToolUse:Agent
# fires AT DISPATCH for run_in_background=true (HP-011 addendum); the audit
# checkpoint would arrive against work that hadn't run yet. SubagentStop fires
# on actual subagent completion (HP-021, CC 2.1.112). Stdin shape changes:
# `tool_input.subagent_type` → `agent_type`. Old-shape fallback retained for
# the transition window per HP-012 (stale-snapshot safety).

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then exit 0; fi

AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // .tool_input.subagent_type // empty')

# Gate: Only gsd-verifier completions
[ "$AGENT_TYPE" != "gsd-verifier" ] && exit 0

cat << 'ENDJSON'
{ "systemMessage": "AUDIT CHECKPOINT — Verifier completed. Apply anti-optimism review:\n1. Does 'verified' mean 'tested and confirmed working' or 'code exists that should work'? Only the former counts.\n2. Are acceptance criteria evaluated individually, or summarized as 'all met'? Check each one.\n3. Were any criteria silently dropped or weakened from the original CONTEXT.md?\n4. If this completes the milestone, run /dhx:audit before archiving.\n5. Run /dhx:test nyquist to validate test coverage for this phase before proceeding to the next phase." }
ENDJSON
