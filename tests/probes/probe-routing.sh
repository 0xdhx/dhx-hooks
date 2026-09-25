#!/usr/bin/env bash
# SAFE_FOR_LIVE: yes  (read-only: greps in-repo hooks.json + the hook source,
#   and pipes fixture JSON to the hook — the hook only READS stdin and writes a
#   JSON object to stdout; no file writes, no mutation)
#
# Exercises dhx-routing.sh — the UserPromptSubmit hook that routes GSD commands
# to their DHX equivalents (redirect) or overlays DHX calibration (augment) by
# injecting additionalContext.
#
# REGRESSION GUARD (the reason this probe exists): from the d2bada5 migration
# (2026-04-06) until 2026-07-09 the hook read `.user_prompt`, a field CC never
# sends, so its case-dispatch matched nothing and it was a SILENT NO-OP for the
# repo's entire life — undetected precisely because no probe covered it. The
# core assertion here is that routing FIRES on a real `.prompt` payload.
#
#   A. WIRING: reads the correct `.prompt` field (HP-008), NOT `.user_prompt`;
#      carries a `# Patterns:` header; registered under UserPromptSubmit.
#   B. BEHAVIORAL: fires (valid additionalContext JSON) on every routed GSD
#      command (colon + hyphen forms); redirect vs calibration mode is correct;
#      silent on a non-GSD prompt and on a word-boundary near-miss.
#
# fix (3-month silent no-op)" row (D-04 GSD->DHX routing).
# Run: bash tests/probes/probe-routing.sh

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOKS_JSON="$REPO_ROOT/dhx-plugin/plugins/dhx/hooks/hooks.json"
HOOK="$REPO_ROOT/dhx/dhx-routing.sh"

PASS=0; FAIL=0
check(){ if [ "$2" = ok ]; then echo "OK   $1"; PASS=$((PASS+1)); else echo "FAIL $1${3:+ ($3)}"; FAIL=$((FAIL+1)); fi; }

# fire <prompt> -> additionalContext string (empty if the hook was silent)
fire(){ printf '%s' "{\"prompt\":$(jq -Rn --arg p "$1" '$p')}" | bash "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null; }
# raw <prompt> -> full stdout (to assert silence)
raw(){ printf '%s' "{\"prompt\":$(jq -Rn --arg p "$1" '$p')}" | bash "$HOOK" 2>/dev/null; }

echo "=== A. Wiring ==="
[ -f "$HOOK" ] && check "dhx/dhx-routing.sh present" ok || check "dhx/dhx-routing.sh present" fail
grep -q '^# Patterns:' "$HOOK" 2>/dev/null && check "hook has a # Patterns: header" ok || check "hook has a # Patterns: header" fail
grep -qE "jq -r '\.prompt // empty'" "$HOOK" 2>/dev/null && check "hook reads the correct .prompt field (HP-008)" ok || check "hook reads .prompt" fail
grep -qE "jq -r '\.user_prompt" "$HOOK" 2>/dev/null && check "hook does NOT read the buggy .user_prompt field (regression guard)" fail "found a .user_prompt jq read" || check "hook does NOT read the buggy .user_prompt field (regression guard)" ok
if command -v jq >/dev/null 2>&1 && [ -f "$HOOKS_JSON" ]; then
  jq -e '[.hooks.UserPromptSubmit[].hooks[].command | select(test("dhx-routing\\.sh"))] | length > 0' "$HOOKS_JSON" >/dev/null 2>&1 \
    && check "hooks.json registers dhx-routing.sh under UserPromptSubmit" ok \
    || check "hooks.json registers dhx-routing.sh under UserPromptSubmit" fail
else
  check "hooks.json present + jq available" fail "missing"
fi

echo "=== B. Behavioral — fires on GSD commands (the regression guard), silent otherwise ==="
if ! command -v jq >/dev/null 2>&1; then
  check "jq available for behavioral smoke" fail "missing"
else
  # Every routed command fires with a non-empty additionalContext (colon + hyphen).
  for p in \
    "/gsd-discuss-phase 5" "/gsd:discuss-phase 5" \
    "/gsd-plan-phase 5" "/gsd:plan-phase 5" \
    "/gsd-execute-phase 5" "/gsd:execute-phase 5" \
    "/gsd-new-project foo" "/gsd:new-milestone v0.6" \
    "/gsd-audit-milestone" "/gsd-verify-work" \
    "/gsd:ui-phase" "/gsd-ui-review"; do
    [ -n "$(fire "$p")" ] && check "[B] fires additionalContext on '$p'" ok || check "[B] fires on '$p'" fail "SILENT (regression)"
  done

  # Mode correctness: redirect (ROUTING) vs calibration (CALIBRATION) leads.
  case "$(fire '/gsd-discuss-phase 5')" in "ROUTING:"*"/dhx:discuss"*) check "[B] discuss-phase -> ROUTING redirect to /dhx:discuss" ok ;; *) check "[B] discuss-phase redirect" fail ;; esac
  case "$(fire '/gsd-plan-phase 5')" in "CALIBRATION:"*"/dhx:plan"*) check "[B] plan-phase -> CALIBRATION overlay for /dhx:plan" ok ;; *) check "[B] plan-phase calibration" fail ;; esac
  case "$(fire '/gsd-verify-work')" in "ROUTING:"*"/dhx:test"*) check "[B] verify-work -> ROUTING redirect to /dhx:test" ok ;; *) check "[B] verify-work redirect" fail ;; esac

  # Silent: non-GSD, word-boundary near-miss, empty.
  for p in "fix the bug in README" "/gsd-newish" ""; do
    OUT=$(raw "$p")
    [ -z "$OUT" ] && check "[B] silent on non-routed prompt '$p'" ok || check "[B] silent on '$p'" fail "emitted output"
  done
  # Malformed JSON -> fail-open silent.
  OUT=$(printf 'not json' | bash "$HOOK" 2>/dev/null); RC=$?
  { [ -z "$OUT" ] && [ "$RC" -eq 0 ]; } && check "[B] fail-open silent (exit 0) on malformed JSON" ok || check "[B] fail-open on malformed JSON" fail "rc=$RC bytes=${#OUT}"
fi

echo "---"
echo "$PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
