#!/usr/bin/env bash
# SAFE_FOR_LIVE: yes  (read-only grep of in-repo hooks.json / both shims / dispatcher /
#   registry hook; behavioural smoke drives each shim with synthetic stdin against a mktemp
#   cache root and a deliberately absent renderer path — no live cache writes, no mutation)
# LIVE_RUNTIME: no  (asserts in-repo source only; needs no installed symlink or live session)
#
# Exercises the /dhx:schedule DELIVERY-LEG wiring (cross-repo phase 40):
#
#   A. UserPromptSubmit leg — dhx/dhx-schedule-prompt.sh, registered in the plugin manifest.
#   B. SessionStart leg     — dhx/dhx-schedule-context.sh, invoked as a session-start.sh
#                             DISPATCHER CHILD (deliberately NOT a registered hook; a second
#                             registration would run it twice).
#   C. Two event-correlated heartbeats, one per leg's reference hook, each writing an
#      `event_hash` digest of the identical stdin it received.
#
# WHY event correlation and not a timestamp comparison: docs/hook-dev-guide.md § Execution
# Model states hooks on one event run IN PARALLEL with no inter-hook communication. A beat
# written by a perfectly healthy leg can therefore be OLDER than the reference beat for the
# same event, so a newer-or-older rule would false-alarm on roughly half of all healthy
# sessions. Each hook holds its own copy of the same bytes, so both digests arrive at the
# same value independently, with no shared state.
#
# ⚠ THIS PROBE MUST NOT ASSERT ANYTHING ABOUT MANIFEST ORDERING. Entries on one event execute
# concurrently; array position provides neither sequencing nor cost suppression, so an
# ordering assertion would pin a property the platform does not provide and would go red on
# any harmless reshuffle.
#
# The single most damaging mistake this probe exists to catch: the reference beat in
# dhx-session-registry-prompt.sh being placed BELOW that hook's `grep -qF -- "$MATCH"`
# idempotency exit. There it would fire exactly once per session, and the per-session
# liveness comparison would report the schedule leg dead in every session past its first
# turn — the precise inversion the comparison exists to prevent. [A9] asserts the ordering.
#
# RESIDUAL (not closable from this repository): a probe can assert what a hook EMITS, never
# that Claude Code RENDERS it. See dhx/dhx-cold-return-gate.sh's header for the standing note.
#
# Backs docs/decisions.md 2026-08-22 "/dhx:schedule delivery legs wired" row.
# Run: bash tests/probes/probe-schedule-wiring.sh

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOKS_JSON="$REPO_ROOT/dhx-plugin/plugins/dhx/hooks/hooks.json"
DISPATCHER="$REPO_ROOT/dhx-plugin/plugins/dhx/hooks/session-start.sh"
PROMPT_SHIM="$REPO_ROOT/dhx/dhx-schedule-prompt.sh"
CTX_SHIM="$REPO_ROOT/dhx/dhx-schedule-context.sh"
REGISTRY_HOOK="$REPO_ROOT/dhx/dhx-session-registry-prompt.sh"

PASS=0; FAIL=0
check(){ if [ "$2" = ok ]; then echo "OK   $1"; PASS=$((PASS+1)); else echo "FAIL $1${3:+ ($3)}"; FAIL=$((FAIL+1)); fi; }

echo "=== A. Wiring (in-repo source) ==="

# A1 — manifest registration. Position is deliberately NOT asserted (see header).
if command -v jq >/dev/null 2>&1 && [ -f "$HOOKS_JSON" ]; then
  jq -e '[.hooks.UserPromptSubmit[].hooks[]
          | select(.command | test("dhx-schedule-prompt\\.sh"))] | length == 1' \
     "$HOOKS_JSON" >/dev/null 2>&1 \
    && check "[A1] hooks.json registers dhx-schedule-prompt.sh under UserPromptSubmit (exactly once)" ok \
    || check "[A1] hooks.json registers dhx-schedule-prompt.sh under UserPromptSubmit (exactly once)" fail

  jq -e '[.hooks.UserPromptSubmit[].hooks[]
          | select(.command | test("dhx-schedule-prompt\\.sh"))
          | select(.timeout == 5)] | length == 1' \
     "$HOOKS_JSON" >/dev/null 2>&1 \
    && check "[A2] that entry carries \"timeout\": 5 (parity with its neighbours)" ok \
    || check "[A2] that entry carries \"timeout\": 5" fail

  # The context leg is a DISPATCHER CHILD. A SessionStart registration would run it twice.
  jq -e '[.hooks.SessionStart[]?.hooks[]?
          | select(.command | test("dhx-schedule-context\\.sh"))] | length == 0' \
     "$HOOKS_JSON" >/dev/null 2>&1 \
    && check "[A3] dhx-schedule-context.sh is NOT registered under SessionStart (child, not hook — would double-fire)" ok \
    || check "[A3] dhx-schedule-context.sh is NOT registered under SessionStart" fail
else
  check "[A1-A3] hooks.json present + jq available" fail "missing"
fi

# A4 — dispatcher child line, hardcoded absolute path form (matches every sibling).
grep -qE '^printf .%s. "\$INPUT" \| DHX_SCHEDULE_EVENT_HASH="\$_SCH_EV_KEY" bash /home/dhx/\.claude/hooks/dhx-schedule-context\.sh \|\| true$' "$DISPATCHER" 2>/dev/null \
  && check "[A4] session-start.sh dispatches dhx-schedule-context.sh (absolute path + forwarded digest)" ok \
  || check "[A4] session-start.sh dispatches dhx-schedule-context.sh (absolute path + forwarded digest)" fail

# A5-A6 — both shims are structurally unable to break their event.
for pair in "PROMPT_SHIM:dhx-schedule-prompt.sh" "CTX_SHIM:dhx-schedule-context.sh"; do
  var="${pair%%:*}"; name="${pair##*:}"; f="${!var}"
  [ -f "$f" ] && [ -x "$f" ] \
    && check "[A5:$name] present and executable" ok \
    || check "[A5:$name] present and executable" fail
  grep -q '^# Patterns:' "$f" 2>/dev/null \
    && check "[A6:$name] carries a # Patterns: header (verify-hook-patterns check #2)" ok \
    || check "[A6:$name] carries a # Patterns: header" fail
  grep -qE '^\[ -e "\$RENDERER" \] \|\| exit 0$' "$f" 2>/dev/null \
    && check "[A7:$name] guards the provisioned renderer ([ -e \$RENDERER ] || exit 0)" ok \
    || check "[A7:$name] guards the provisioned renderer" fail
  grep -qE '^exit 0$' "$f" 2>/dev/null \
    && check "[A8:$name] is exit 0-terminated (fail-open)" ok \
    || check "[A8:$name] is exit 0-terminated" fail
done

# A9 — THE ORDERING ASSERTION. The beat must sit ABOVE the idempotency exit, or it fires
# once per session and the liveness comparison inverts. This is the one that matters.
BEAT_LINE=$(grep -n '_SCH_HB_DIR=' "$REGISTRY_HOOK" 2>/dev/null | head -1 | cut -d: -f1)
IDEM_LINE=$(grep -n 'grep -qF -- "\$MATCH"' "$REGISTRY_HOOK" 2>/dev/null | head -1 | cut -d: -f1)
if [ -n "$BEAT_LINE" ] && [ -n "$IDEM_LINE" ] && [ "$BEAT_LINE" -lt "$IDEM_LINE" ]; then
  check "[A9] registry beat sits ABOVE the idempotency exit (line $BEAT_LINE < $IDEM_LINE) — fires every turn" ok
else
  check "[A9] registry beat sits ABOVE the idempotency exit" fail "beat=${BEAT_LINE:-none} idem=${IDEM_LINE:-none} — below means count never exceeds 1 and the leg reads DEAD in every long session"
fi

# A10-A11 — both heartbeats write the shared event digest.
grep -q '"event_hash"' "$REGISTRY_HOOK" 2>/dev/null \
  && check "[A10] dhx-session-registry-prompt.sh beat writes an event_hash field" ok \
  || check "[A10] dhx-session-registry-prompt.sh beat writes an event_hash field" fail
grep -q '"event_hash"' "$DISPATCHER" 2>/dev/null \
  && check "[A11] session-start.sh beat writes an event_hash field" ok \
  || check "[A11] session-start.sh beat writes an event_hash field" fail

# A12 — the never-emit-JSON rule for the dispatcher child. A JSON child corrupts the
# dispatcher's WHOLE concatenated payload, not merely its own contribution.
if grep -qE "jq -n|hookSpecificOutput|systemMessage|printf '\{" "$CTX_SHIM" 2>/dev/null; then
  check "[A12] dhx-schedule-context.sh emits no JSON (plain-text-only dispatcher child)" fail "found a JSON emission shape"
else
  check "[A12] dhx-schedule-context.sh emits no JSON (plain-text-only dispatcher child)" ok
fi

echo "=== B. Behavioural smoke — graceful absence (mktemp cache root, absent renderer) ==="

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
PAYLOAD='{"session_id":"probe-sched-0001","transcript_path":"/probe/probe-sched-0001.jsonl","cwd":"/probe","prompt":"probe"}'
ABSENT="$SB/definitely-not-provisioned.cjs"

for pair in "PROMPT_SHIM:dhx-schedule-prompt.sh" "CTX_SHIM:dhx-schedule-context.sh"; do
  var="${pair%%:*}"; name="${pair##*:}"; f="${!var}"
  OUT="$SB/out-$name"
  printf '%s' "$PAYLOAD" | env DHX_SCHEDULE_CACHE_DIR="$SB/cache" DHX_SCHEDULE_RENDERER="$ABSENT" \
    bash "$f" >"$OUT" 2>/dev/null
  RC=$?
  [ "$RC" -eq 0 ] \
    && check "[B1:$name] exits 0 with an absent renderer (graceful absence)" ok \
    || check "[B1:$name] exits 0 with an absent renderer" fail "rc=$RC"
  [ ! -s "$OUT" ] \
    && check "[B2:$name] emits nothing with an absent renderer (zero context tokens)" ok \
    || check "[B2:$name] emits nothing with an absent renderer" fail "non-empty stdout"
done

# B3 — the prompt shim must never slow a subagent turn (half of the eligibility symmetry rule).
SUB='{"session_id":"probe-sched-0001","transcript_path":"/probe/subagents/x.jsonl","agent_id":"agent-9","prompt":"p"}'
OUT="$SB/out-subagent"
printf '%s' "$SUB" | env DHX_SCHEDULE_CACHE_DIR="$SB/cache" DHX_SCHEDULE_RENDERER="$ABSENT" \
  bash "$PROMPT_SHIM" >"$OUT" 2>/dev/null
RC=$?
if [ "$RC" -eq 0 ] && [ ! -s "$OUT" ]; then
  check "[B3] prompt shim exits 0 + silent on a non-empty agent_id (subagent guard)" ok
else
  check "[B3] prompt shim exits 0 + silent on a non-empty agent_id" fail "rc=$RC"
fi

# B4 — malformed stdin must never break a prompt.
OUT="$SB/out-malformed"
printf '%s' 'not json at all {{{' | env DHX_SCHEDULE_CACHE_DIR="$SB/cache" DHX_SCHEDULE_RENDERER="$ABSENT" \
  bash "$PROMPT_SHIM" >"$OUT" 2>/dev/null
RC=$?
if [ "$RC" -eq 0 ] && [ ! -s "$OUT" ]; then
  check "[B4] prompt shim exits 0 + silent on unparseable stdin" ok
else
  check "[B4] prompt shim exits 0 + silent on unparseable stdin" fail "rc=$RC"
fi

# B5 — the correlation property itself: both legs, handed the SAME bytes, independently
# derive the SAME digest. This is what makes the liveness comparison possible without any
# inter-hook communication. Driven against a fake $HOME so no live cache is touched.
if command -v sha256sum >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  FH="$SB/home"; mkdir -p "$FH/.claude"
  REC="$SB/rec.txt"; : > "$REC"
  cat > "$SB/render.cjs" <<'JSEOF'
const a=process.argv.slice(2);
const i=a.indexOf('--event-hash');
require('fs').appendFileSync(process.env.REC,(i>=0?a[i+1]:'<none>')+'\n');
JSEOF
  if command -v node >/dev/null 2>&1; then
    printf '%s' "$PAYLOAD" | env HOME="$FH" REC="$REC" DHX_SCHEDULE_RENDERER="$SB/render.cjs" \
      bash "$PROMPT_SHIM" >/dev/null 2>&1
    printf '%s' "$PAYLOAD" | env HOME="$FH" bash "$REGISTRY_HOOK" >/dev/null 2>&1
    printf '%s' "$PAYLOAD" | env HOME="$FH" bash "$REGISTRY_HOOK" >/dev/null 2>&1
    A=$(head -1 "$REC" 2>/dev/null)
    BEAT=$(ls "$FH"/.cache/dhx/hooks/prompt/*.json 2>/dev/null | head -1)
    B=$(sed -n 's/.*"event_hash":"\([^"]*\)".*/\1/p' "$BEAT" 2>/dev/null)
    N=$(sed -n 's/.*"count":\([0-9]*\).*/\1/p' "$BEAT" 2>/dev/null)
    if [ -n "$A" ] && [ "$A" = "$B" ]; then
      check "[B5] both legs derive the SAME event digest from identical stdin ($A)" ok
    else
      check "[B5] both legs derive the same event digest" fail "shim=${A:-none} beat=${B:-none}"
    fi
    # Runtime companion to [A9]: two fires of one session must reach count 2.
    if [ "${N:-0}" -gt 1 ]; then
      check "[B6] reference beat count reaches $N after two prompts (fires every turn, not once)" ok
    else
      check "[B6] reference beat count exceeds 1 after two prompts" fail "count=${N:-none} — beat is below the idempotency exit"
    fi
  else
    echo "SKIP [B5-B6] correlation smoke — node absent"
  fi
else
  echo "SKIP [B5-B6] correlation smoke — sha256sum/jq absent"
fi

# B7 — THE CONTEXT LEG'S DIGEST, END TO END, THROUGH THE REAL DISPATCHER.
# This is the assertion whose absence let the leg ship inert: [B5] above exercises the PROMPT
# pair only, so a context leg that passed no digest at all stayed green for a full phase.
#
# It is deliberately BEHAVIOURAL, not a source-level re-derivation. Re-implementing the hash in
# the probe would only prove the probe agrees with itself; what matters is that the value the
# dispatcher WROTE to its reference beat is the value the renderer RECEIVED. The dispatcher
# invokes each child as `bash <abs-path>`, so a fake `bash` earlier on PATH runs the real
# schedule child and silently no-ops every sibling — the dispatcher's own shebang has already
# resolved by then, so it is unaffected.
if command -v sha256sum >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
   && command -v node >/dev/null 2>&1 && [ -e "$HOME/.claude/hooks/dhx-schedule-context.sh" ]; then
  FH2="$SB/home2"; mkdir -p "$FH2/.claude"
  REC2="$SB/rec2.txt"; : > "$REC2"
  cat > "$SB/render2.cjs" <<'JS2EOF'
const a=process.argv.slice(2);
const i=a.indexOf('--event-hash');
require('fs').appendFileSync(process.env.REC,(i>=0?a[i+1]:'<none>')+'\n');
JS2EOF
  mkdir -p "$SB/fakebin"
  cat > "$SB/fakebin/bash" <<'FBEOF'
#!/bin/sh
case "$*" in
  *dhx-schedule-context.sh*) exec /bin/bash "$@" ;;
  *) cat >/dev/null 2>&1; exit 0 ;;
esac
FBEOF
  chmod +x "$SB/fakebin/bash"
  # The payload carries the shapes that could plausibly break canonicalisation: a percent sign
  # (data under printf '%s', never a format), multibyte UTF-8, and TRAILING NEWLINES that
  # `$(cat)` must strip identically on both sides.
  P2='{"session_id":"probe-ctx-0001","source":"startup","note":"100% - cafe UTF8 check"}'
  printf '%s\n\n\n' "$P2" | env PATH="$SB/fakebin:$PATH" HOME="$FH2" REC="$REC2" \
    DHX_SCHEDULE_RENDERER="$SB/render2.cjs" DHX_SCHEDULE_CACHE_DIR="$SB/cache2" \
    /bin/bash "$DISPATCHER" >/dev/null 2>&1
  CTX_SEEN=$(head -1 "$REC2" 2>/dev/null)
  BEAT2=$(ls "$FH2"/.cache/dhx/hooks/session-start/*.json 2>/dev/null | head -1)
  CTX_REF=$(sed -n 's/.*"event_hash":"\([^"]*\)".*/\1/p' "$BEAT2" 2>/dev/null)
  if [ -n "$CTX_SEEN" ] && [ "$CTX_SEEN" != "<none>" ] && [ "$CTX_SEEN" = "$CTX_REF" ]; then
    check "[B7] context leg: the dispatcher's reference digest reaches the renderer verbatim ($CTX_SEEN)" ok
  else
    check "[B7] context leg: the dispatcher's reference digest reaches the renderer" fail \
      "renderer=${CTX_SEEN:-none} reference=${CTX_REF:-none}"
  fi
  # B8 — the shim must REFUSE a forged or malformed digest rather than forward it. The variable
  # is environment-sourced, so a non-digest value must degrade to the pre-forwarding floor
  # (empty -> isDigestKey() null), never reach the beat as if it were real.
  : > "$REC2"
  printf '%s' "$P2" | env HOME="$FH2" REC="$REC2" DHX_SCHEDULE_RENDERER="$SB/render2.cjs" \
    DHX_SCHEDULE_CACHE_DIR="$SB/cache2" DHX_SCHEDULE_EVENT_HASH='not-a-digest; rm -rf /' \
    /bin/bash "$CTX_SHIM" >/dev/null 2>&1
  FORGED=$(head -1 "$REC2" 2>/dev/null)
  if [ -z "$FORGED" ] || [ "$FORGED" = "<none>" ]; then
    check "[B8] context shim rejects a malformed forwarded digest (empty, not forwarded)" ok
  else
    check "[B8] context shim rejects a malformed forwarded digest" fail "forwarded=${FORGED}"
  fi
else
  echo "SKIP [B7-B8] context-leg digest smoke — sha256sum/jq/node or the installed shim absent"
fi

echo "---"
echo "$PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
