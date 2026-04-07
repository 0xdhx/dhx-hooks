#!/usr/bin/env bash
# dhx-test-reminder.sh — UserPromptSubmit hook
# Injects test requirements via JSON additionalContext.
# Framework-agnostic — works with any test runner.
# Uses JSON path (not plain-text stdout) to avoid regression issues
# documented in #13912, #9652, #10463, #12151.

cat << 'ENDJSON'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "MANDATORY: All code changes must include real unit tests.\n- Tests must import and call actual changed functions (no mocking the module under test)\n- Assertions must verify specific values/behavior (never assert true or use placeholder expects)\n- Include at least one edge case and one error path per changed function\n- If existing tests cover the changed paths, verify they pass\n- If no tests apply (config, docs, formatting), state why explicitly\n- Run the project's test suite and linter before declaring done"
  }
}
ENDJSON
