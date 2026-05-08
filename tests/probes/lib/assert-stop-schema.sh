#!/usr/bin/env bash
# tests/probes/lib/assert-stop-schema.sh
#
# Schema-shape sanity helpers for Stop / SubagentStop / advisory-only
# event probes. Validates hook stdout JSON against CC's hook-output
# validator: top-level keys must be in the universal allowlist AND
# the JSON must not carry hookSpecificOutput (the validator rejects
# hookSpecificOutput for non-union events: Stop, SubagentStop,
# SessionStart, Notification, PreCompact).
#
# Schema source: CC v2.1.121 validator output captured at heat-check
# session JSONL 2026-05-08 (stop_hook_summary attachment.hookErrors[0]).
# Documented in docs/hook-dev-guide.md "Output JSON Schema (advisory-
# only events)" section.
#
# Sourcing convention:
#   source "$(dirname "$0")/lib/assert-stop-schema.sh"
#
# Functions read their argument as JSON and modify the parent script's
# PASS / FAIL counters — matches the inline assert convention used by
# the existing probes (see e.g. probe-test-gate-phase-aware.sh helpers).
#
# Usage:
#   assert_stop_schema "$HOOK_OUT" "[1]"
#     → fires 3 sub-assertions, each contributing one PASS or FAIL:
#       1. stdout is valid JSON
#       2. stdout omits hookSpecificOutput (advisory events reject it)
#       3. all top-level keys are in the universal allowlist

# Universal top-level allowlist for hook output JSON. hookSpecificOutput
# IS in the allowlist (it's structurally permitted); the validator's
# event-specific constraint is on its CONTENTS — wrapped hookEventName
# must be in {PreToolUse, UserPromptSubmit, PostToolUse, PostToolBatch},
# which excludes Stop/SubagentStop/SessionStart/Notification/PreCompact.
# This helper's sub-assertion 2 catches the bug class for those events.
ASSERT_STOP_SCHEMA_ALLOWLIST='["continue","suppressOutput","stopReason","decision","reason","systemMessage","permissionDecision","hookSpecificOutput"]'

assert_stop_schema() {
  local json="$1" label="$2"

  # Sub-assertion 1: stdout parses as JSON
  if jq -e . <<< "$json" >/dev/null 2>&1; then
    echo "OK   $label stdout is valid JSON"
    PASS=$((PASS + 1))
  else
    echo "FAIL $label stdout is not valid JSON"
    echo "     output: $json"
    FAIL=$((FAIL + 1))
    # Bail — downstream sub-assertions need parseable JSON.
    return
  fi

  # Sub-assertion 2: no hookSpecificOutput (advisory-only events reject it).
  # CC's validator union for hookSpecificOutput is {PreToolUse,
  # UserPromptSubmit, PostToolUse, PostToolBatch}. Stop/SubagentStop and
  # the other advisory-only events fail validation if this key is present.
  if jq -e 'has("hookSpecificOutput") | not' <<< "$json" >/dev/null 2>&1; then
    echo "OK   $label stdout omits hookSpecificOutput (validator rejects for advisory-only events)"
    PASS=$((PASS + 1))
  else
    echo "FAIL $label stdout contains hookSpecificOutput — advisory-only event schema rejects this key"
    echo "     output: $json"
    FAIL=$((FAIL + 1))
  fi

  # Sub-assertion 3: every top-level key is in the universal allowlist.
  # Catches forward-incompatible additions (e.g., a future field added
  # without a corresponding validator update).
  if jq -e --argjson allow "$ASSERT_STOP_SCHEMA_ALLOWLIST" \
         'keys | all(. as $k | $allow | index($k))' <<< "$json" >/dev/null 2>&1; then
    echo "OK   $label stdout keys all in advisory-event top-level allowlist"
    PASS=$((PASS + 1))
  else
    echo "FAIL $label stdout has keys outside top-level allowlist"
    echo "     output: $json"
    FAIL=$((FAIL + 1))
  fi
}
