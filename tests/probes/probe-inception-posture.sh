#!/usr/bin/env bash
# SAFE_FOR_LIVE: yes  (read-only: greps in-repo hooks.json + the hook source,
#   and pipes fixture JSON to the hook — the hook only READS stdin and writes a
#   JSON object to stdout; no file writes, no mutation)
#
# Exercises dhx-inception-posture.sh — the UserPromptSubmit hook that injects a
# build-posture elicitation checklist (runtime/distribution/reuse + gated
# commercial-options) ONLY on project/milestone inception commands, and is
# silent on every other prompt (zero per-session tax).
#
#   A. WIRING (unconditional): hooks.json registers dhx-inception-posture.sh
#      under UserPromptSubmit; the hook carries a `# Patterns:` header; it reads
#      the CORRECT `.prompt` field (HP-008), NOT the `.user_prompt` typo that
#      makes dhx-routing.sh silently no-op.
#   B. BEHAVIORAL: fires (valid JSON + additionalContext) on both colon and
#      hyphen inception forms; is silent on a non-inception prompt, on a
#      word-boundary near-miss (/gsd-new-project-harness), on empty prompt, and
#      on malformed JSON (fail-open). additionalContext carries both principles.
#
# hook (#1 runtime + #3 commercial) + #2 global CLAUDE.md bullet" row.
# Run: bash tests/probes/probe-inception-posture.sh

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOKS_JSON="$REPO_ROOT/dhx-plugin/plugins/dhx/hooks/hooks.json"
HOOK="$REPO_ROOT/dhx/dhx-inception-posture.sh"

PASS=0; FAIL=0
check(){ if [ "$2" = ok ]; then echo "OK   $1"; PASS=$((PASS+1)); else echo "FAIL $1${3:+ ($3)}"; FAIL=$((FAIL+1)); fi; }

# fire <prompt> -> stdout of the hook for that prompt
fire(){ printf '%s' "{\"prompt\":$(jq -Rn --arg p "$1" '$p')}" | bash "$HOOK" 2>/dev/null; }

echo "=== A. Wiring ==="
[ -f "$HOOK" ] && check "dhx/dhx-inception-posture.sh present" ok || check "dhx/dhx-inception-posture.sh present" fail
grep -q '^# Patterns:' "$HOOK" 2>/dev/null && check "hook has a # Patterns: header (verify-hook-patterns)" ok || check "hook has a # Patterns: header" fail
# Correct field: reads .prompt, never .user_prompt (the dhx-routing.sh latent bug)
grep -qE "jq -r '\.prompt // empty'" "$HOOK" 2>/dev/null && check "hook reads the correct .prompt field (HP-008)" ok || check "hook reads .prompt" fail
# Assert the hook does not EXTRACT .user_prompt (a jq read), not merely that the
# string appears — the header comment names .user_prompt to document the contrast.
grep -qE "jq -r '\.user_prompt" "$HOOK" 2>/dev/null && check "hook does NOT read the buggy .user_prompt field" fail "found a .user_prompt jq read" || check "hook does NOT read the buggy .user_prompt field" ok

if command -v jq >/dev/null 2>&1 && [ -f "$HOOKS_JSON" ]; then
  jq -e '[.hooks.UserPromptSubmit[].hooks[].command | select(test("dhx-inception-posture\\.sh"))] | length > 0' "$HOOKS_JSON" >/dev/null 2>&1 \
    && check "hooks.json registers dhx-inception-posture.sh under UserPromptSubmit" ok \
    || check "hooks.json registers dhx-inception-posture.sh under UserPromptSubmit" fail
else
  check "hooks.json present + jq available" fail "missing"
fi

echo "=== B. Behavioral — fires on inception, silent otherwise ==="
if ! command -v jq >/dev/null 2>&1; then
  check "jq available for behavioral smoke" fail "missing"
else
  # Fires: both forms emit valid JSON with a non-empty additionalContext.
  for p in "/gsd-new-project" "/gsd:new-project v2" "/gsd-new-milestone v0.6" "/gsd:new-milestone"; do
    OUT=$(fire "$p")
    if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.hookEventName=="UserPromptSubmit" and (.hookSpecificOutput.additionalContext|type=="string" and (.|length>0))' >/dev/null 2>&1; then
      check "[B] fires + valid additionalContext JSON on '$p'" ok
    else
      check "[B] fires + valid additionalContext JSON on '$p'" fail
    fi
  done

  # Content: additionalContext carries BOTH principles.
  BODY=$(fire "/gsd-new-project" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
  case "$BODY" in *"RUNTIME"*"REUSE"*) check "[B] additionalContext carries the #1 runtime/reuse principle" ok ;; *) check "[B] #1 runtime/reuse principle present" fail ;; esac
  case "$BODY" in *"COMMERCIAL OPTIONS"*"release path"*) check "[B] additionalContext carries the #3 gated commercial-options principle" ok ;; *) check "[B] #3 commercial-options (gated) present" fail ;; esac

  # Silent: non-inception, word-boundary near-miss, empty, malformed.
  for p in "fix the typo in README" "/gsd-new-project-harness foo" "/gsd:new-projectile" ""; do
    OUT=$(fire "$p")
    [ -z "$OUT" ] && check "[B] silent on non-inception prompt '$p'" ok || check "[B] silent on '$p'" fail "emitted output"
  done
  # Malformed JSON on stdin -> fail-open silent.
  OUT=$(printf 'not json' | bash "$HOOK" 2>/dev/null); RC=$?
  { [ -z "$OUT" ] && [ "$RC" -eq 0 ]; } && check "[B] fail-open silent (exit 0) on malformed JSON" ok || check "[B] fail-open on malformed JSON" fail "rc=$RC bytes=${#OUT}"
fi

echo "---"
echo "$PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
