#!/usr/bin/env bash
# tests/probes/lib/assert-stop-schema.sh
#
# Schema-shape sanity helpers for the in-repo Stop / SubagentStop probes.
# Asserts hook stdout JSON uses the PORTABLE top-level shape: top-level
# keys in the universal allowlist AND no hookSpecificOutput wrapper.
#
# NOT a claim that the wrapper is invalid on current CC. As of CC 2.1.197
# (2026-07-01, HP-046) Stop / SubagentStop / SessionStart DO accept
# hookSpecificOutput.additionalContext — the wrapper was rejected only on
# ~2.1.121 (the stop_hook_summary capture below). This helper is a
# CROSS-VERSION PORTABILITY guard: the dhx Stop/SubagentStop hooks emit
# top-level systemMessage / decision, which works on every CC version;
# this asserts they keep doing so.
#
# History: CC v2.1.121 validator output captured at heat-check session
# JSONL 2026-05-08 (stop_hook_summary attachment.hookErrors[0]).
# Documented in docs/hook-dev-guide.md "Output JSON Schema" section
# (whole-event-class re-verification: HP-046).
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
# IS in the allowlist (structurally permitted). On CC 2.1.197 the wrapper's
# additionalContext channel is accepted for PreToolUse, UserPromptSubmit,
# PostToolUse, PostToolBatch, SessionStart, Stop, and SubagentStop (HP-046);
# only Notification/PreCompact lack an injection channel. Sub-assertion 2
# below asserts the in-repo Stop/SubagentStop hooks nonetheless emit the
# PORTABLE top-level shape (no wrapper) — a cross-version guard, not a
# validity constraint.
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

  # Sub-assertion 2: hook uses the PORTABLE top-level shape (no hookSpecificOutput
  # wrapper). On CC 2.1.197 the wrapper IS accepted for Stop/SubagentStop
  # (HP-046) — this is NOT a validity check but a cross-version portability
  # guard: the dhx Stop/SubagentStop hooks emit top-level systemMessage/decision,
  # which works on every CC version including pre-2.1.19x builds that rejected
  # the wrapper.
  if jq -e 'has("hookSpecificOutput") | not' <<< "$json" >/dev/null 2>&1; then
    echo "OK   $label stdout uses portable top-level shape (no hookSpecificOutput wrapper)"
    PASS=$((PASS + 1))
  else
    echo "FAIL $label stdout carries hookSpecificOutput — dhx advisory hooks use the portable top-level shape"
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
