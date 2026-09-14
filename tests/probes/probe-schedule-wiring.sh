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
#   C. Two event-correlated reference writers, one per leg's reference hook, each writing ONE
#      immutable record per occurrence (schema_version 2, cross-repo design note
#      2026-08-23-dhx-schedule-beat-record-layout-and-gc-design.md §1-§2) under
#      `$DHX_HOOKS_CACHE_DIR/<leg>/<session16>/<event16|none>.<fired_ms>.<pid>.<nonce>.json`,
#      carrying an `event_hash` digest of the identical stdin it received. No flat
#      `<session16>.json` is ever written again; "how many" is the directory's cardinality.
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
# The second: the record's field set drifting from cross-repo's `validateRecord`. Every record
# the writers produce in the B cells is validated by THAT function (B12), never by a local
# re-derivation — a probe that agrees with itself proves nothing.
#
# RESIDUAL (not closable from this repository): a probe can assert what a hook EMITS, never
# that Claude Code RENDERS it. See dhx/dhx-cold-return-gate.sh's header for the standing note.
#
# Backs docs/decisions.md 2026-08-22 "/dhx:schedule delivery legs wired" row.
# B9-B11 back the 2026-08-22 "One digest-tool policy at every /dhx:schedule computing site" row.
# A10-A11, A13, B6, B7b, B12-B14 back the 2026-08-23 "reference writers emit per-occurrence
# records (schema_version 2)" row. A4 (repinned) + B15 back the 2026-09-14 "schedule child runs
# directly under the reference record, emitted later" row. The `kind:"undigested"` arm is NOT behaviourally reachable
# from a probe: both keys share one digest chain, so with no digest tool the session key is
# empty and the guarded block is skipped before the arm is reached (B9-B11 cover the chain).
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

# A4 — dispatcher child line, hardcoded absolute path form (matches every sibling). Repinned
# 2026-09-03 when the SESSION key joined the event digest on this line; pinning the whole line
# is the point — it is why adding a forwarded value cannot pass silently.
# Repinned again 2026-09-14: the line is now a command substitution into `_SCH_CTX_OUT` — the
# child RUNS directly under the reference record and its stdout is EMITTED later (see [B15]).
grep -qE '^_SCH_CTX_OUT=\$\(printf .%s. "\$INPUT" \| DHX_SCHEDULE_EVENT_HASH="\$_SCH_EV_KEY" DHX_SCHEDULE_SESSION_KEY="\$_SCH_HB_KEY" bash /home/dhx/\.claude/hooks/dhx-schedule-context\.sh \|\| true\)$' "$DISPATCHER" 2>/dev/null \
  && grep -qE '^if \[ -n "\$_SCH_CTX_OUT" \]; then printf .%s\\n. "\$_SCH_CTX_OUT"; fi$' "$DISPATCHER" 2>/dev/null \
  && check "[A4] session-start.sh dispatches dhx-schedule-context.sh (absolute path + BOTH forwarded values; captured, then emitted)" ok \
  || check "[A4] session-start.sh dispatches dhx-schedule-context.sh (absolute path + BOTH forwarded values; captured, then emitted)" fail

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
  check "[A9] registry beat sits ABOVE the idempotency exit" fail "beat=${BEAT_LINE:-none} idem=${IDEM_LINE:-none} — below means one record per session and the leg reads DEAD in every long session"
fi

# A10-A11 — both reference writers emit the schema_version-2 record through the retrying
# transaction function, honour the reader's cache-root override, and never write the legacy
# flat slot (a `count` field or `last_fire_at` is the tell that the old printf came back).
for pair in "A10:REGISTRY_HOOK:dhx-session-registry-prompt.sh" "A11:DISPATCHER:session-start.sh"; do
  id="${pair%%:*}"; rest="${pair#*:}"; var="${rest%%:*}"; name="${rest##*:}"; f="${!var}"
  if grep -q '"schema_version":2,"kind":"%s","leg":"%s","fired_at":"%s","event_hash":%s,"session_hash_stdin":"%s","session_hash_env":"%s"' "$f" \
     && grep -q '^_dhx_sch_record()' "$f" \
     && grep -q '_dhx_sch_record || _dhx_sch_record' "$f" \
     && grep -q 'DHX_HOOKS_CACHE_DIR:-\$HOME/.cache/dhx/hooks' "$f" \
     && ! grep -q '"count"\|last_fire_at' "$f"; then
    check "[$id] $name writes the v2 record shape via _dhx_sch_record (retry once, DHX_HOOKS_CACHE_DIR root, no flat-file fields)" ok
  else
    check "[$id] $name writes the v2 record shape via _dhx_sch_record" fail
  fi
done
# A13 — eligibility parity: the registry writer applies the shim's predicate (skip on a
# non-empty agent_id / empty session_id) from the SAME jq extraction.
if grep -qF "jq -r '[(.session_id // \"\"), (.agent_id // \"\")] | @tsv'" "$REGISTRY_HOOK" \
   && grep -q '\[ -z "\${_SCH_AGENT:-}" \] && \[ -n "\${_SCH_SID:-}" \]' "$REGISTRY_HOOK"; then
  check "[A13] registry writer gates its record on the shim's eligibility predicate (agent_id empty, session_id non-empty)" ok
else
  check "[A13] registry writer gates its record on the shim's eligibility predicate" fail
fi

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
    SESS_DIR=$(ls -d "$FH"/.cache/dhx/hooks/prompt/*/ 2>/dev/null | head -1)
    BEAT=$(ls "$SESS_DIR"*.json 2>/dev/null | head -1)
    B=$(sed -n 's/.*"event_hash":"\([^"]*\)".*/\1/p' "$BEAT" 2>/dev/null)
    if [ -n "$A" ] && [ "$A" = "$B" ]; then
      check "[B5] both legs derive the SAME event digest from identical stdin ($A)" ok
    else
      check "[B5] both legs derive the same event digest" fail "shim=${A:-none} beat=${B:-none}"
    fi
    # Runtime companion to [A9], and THE REPEATED-EVENT CASE: two byte-identical prompts must
    # yield two DISTINCT record files in one session directory, both named by the same
    # <event16>, no flat `<session16>.json` beside the directory.
    N=$(ls "$SESS_DIR"*.json 2>/dev/null | wc -l | tr -d ' ')
    NH=$(ls "$SESS_DIR" 2>/dev/null | sed -n 's/^\([0-9a-f]\{16\}\)\..*\.json$/\1/p' | sort -u | wc -l | tr -d ' ')
    FLAT=$(ls "$FH"/.cache/dhx/hooks/prompt/*.json 2>/dev/null | wc -l | tr -d ' ')
    if [ "${N:-0}" -eq 2 ] && [ "${NH:-0}" -eq 1 ] && [ "${FLAT:-0}" -eq 0 ]; then
      check "[B6] two identical prompts -> two distinct records sharing one <event16>, no legacy flat slot (fires every turn, not once)" ok
    else
      check "[B6] two identical prompts -> two distinct records sharing one <event16>" fail "records=${N:-0} hashes=${NH:-0} flat=${FLAT:-0} — one record means the writer is below the idempotency exit"
    fi
    # B12 — every record the registry writer produced passes cross-repo's validateRecord
    # (the closed validator the health reader applies), checked by THAT function. Skipped
    # when the store is not on this host; its absence is a different repo's concern.
    STORE="$HOME/repos/cross-repo/scripts/schedule/dhx-schedule-store.cjs"
    if [ -r "$STORE" ] && node -e 'if(typeof require(process.argv[1]).validateRecord!=="function")process.exit(1)' "$STORE" 2>/dev/null; then
      V=$(node -e '
const s=require(process.argv[1]),fs=require("fs"),p=require("path");
const root=process.argv[2];let n=0,bad=0;
for(const leg of ["prompt","session-start"]){const d=p.join(root,leg);if(!fs.existsSync(d))continue;
  for(const k of fs.readdirSync(d)){const sd=p.join(d,k);if(!fs.statSync(sd).isDirectory())continue;
    for(const f of fs.readdirSync(sd)){n++;let doc=null;
      try{doc=JSON.parse(fs.readFileSync(p.join(sd,f),"utf8"));}catch(e){}
      const pr=s.validateRecord(doc,{leg,sessionKey:k,fileName:f});
      if(pr.length){bad++;console.error(leg+"/"+k+"/"+f+": "+pr.join("; "));}}}}
console.log(n+" "+bad);' "$STORE" "$FH/.cache/dhx/hooks" 2>"$SB/v-err")
      VN="${V%% *}"; VB="${V##* }"
      if [ "${VN:-0}" -ge 2 ] && [ "${VB:-1}" -eq 0 ]; then
        check "[B12] all $VN registry records pass cross-repo validateRecord byte-for-byte ([] problems)" ok
      else
        check "[B12] registry records pass cross-repo validateRecord" fail "records=${VN:-0} problems=${VB:-?} $(head -c 300 "$SB/v-err" 2>/dev/null)"
      fi
    else
      echo "SKIP [B12] validateRecord cross-check — cross-repo store absent on this host"
    fi
    # B13 — ELIGIBILITY PARITY (design §1): a non-empty agent_id must produce NO reference
    # record, exactly as the shim writes nothing; likewise an empty session_id. Anything else
    # is one unpaired occurrence that the multiset reader scores DEAD.
    FH5="$SB/home5"; mkdir -p "$FH5/.claude"
    SUBP='{"session_id":"probe-sched-0001","transcript_path":"/probe/x.jsonl","agent_id":"agent-9","cwd":"/probe","prompt":"p"}'
    printf '%s' "$SUBP" | env HOME="$FH5" bash "$REGISTRY_HOOK" >/dev/null 2>&1
    NOSID='{"transcript_path":"/probe/probe-sched-0002.jsonl","cwd":"/probe","prompt":"p"}'
    printf '%s' "$NOSID" | env HOME="$FH5" bash "$REGISTRY_HOOK" >/dev/null 2>&1
    SUBN=$(find "$FH5/.cache/dhx/hooks" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [ "${SUBN:-0}" -eq 0 ]; then
      check "[B13] registry writer emits NO record on a non-empty agent_id or an empty session_id (parity with the shim)" ok
    else
      check "[B13] registry writer emits NO record on a non-empty agent_id / empty session_id" fail "records=$SUBN"
    fi
    # B14 — DHX_HOOKS_CACHE_DIR is honoured (the reader's HOOKS_CACHE_ENV) and the writer
    # re-runs its whole transaction when the session directory vanishes mid-write: a stub
    # `mv` that deletes the target directory on its first call models the GC's quarantine
    # rename; the record must still land on the retry.
    RR="$SB/root14"; mkdir -p "$SB/fakemv"
    cat > "$SB/fakemv/mv" <<'MVEOF'
#!/bin/sh
# First call: model the GC renaming the session directory away under the writer.
if [ ! -e "$DHX_PROBE_MV_ONCE" ]; then : > "$DHX_PROBE_MV_ONCE"; rm -rf "$(dirname "$2")"; fi
exec /bin/mv "$@"
MVEOF
    chmod +x "$SB/fakemv/mv"
    printf '%s' "$PAYLOAD" | env HOME="$FH5" PATH="$SB/fakemv:$PATH" DHX_PROBE_MV_ONCE="$SB/mv-once" \
      DHX_HOOKS_CACHE_DIR="$RR" bash "$REGISTRY_HOOK" >/dev/null 2>&1
    R14=$(find "$RR/prompt" -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')
    T14=$(find "$RR" -name '*.tmp.*' 2>/dev/null | wc -l | tr -d ' ')
    if [ -e "$SB/mv-once" ] && [ "${R14:-0}" -eq 1 ] && [ "${T14:-0}" -eq 0 ]; then
      check "[B14] DHX_HOOKS_CACHE_DIR honoured; record lands on the retried transaction after the session dir vanished mid-write, no temp orphan" ok
    else
      check "[B14] DHX_HOOKS_CACHE_DIR honoured + whole-transaction retry" fail "mv-called=$([ -e "$SB/mv-once" ] && echo yes || echo no) records=${R14:-0} temps=${T14:-0}"
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
const j=a.indexOf('--session-key');
const fs=require('fs');
fs.appendFileSync(process.env.REC,(i>=0?a[i+1]:'<none>')+'\n');
if(process.env.REC_SK)fs.appendFileSync(process.env.REC_SK,(j>=0&&a[j+1]!==''?a[j+1]:'<none>')+'\n');
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
  REC2SK="$SB/rec2sk.txt"; : > "$REC2SK"
  printf '%s\n\n\n' "$P2" | env PATH="$SB/fakebin:$PATH" HOME="$FH2" REC="$REC2" REC_SK="$REC2SK" \
    DHX_SCHEDULE_RENDERER="$SB/render2.cjs" DHX_SCHEDULE_CACHE_DIR="$SB/cache2" \
    /bin/bash "$DISPATCHER" >/dev/null 2>&1
  CTX_SEEN=$(head -1 "$REC2" 2>/dev/null)
  BEAT2=$(ls "$FH2"/.cache/dhx/hooks/session-start/*/*.json 2>/dev/null | head -1)
  CTX_REF=$(sed -n 's/.*"event_hash":"\([^"]*\)".*/\1/p' "$BEAT2" 2>/dev/null)
  if [ -n "$CTX_SEEN" ] && [ "$CTX_SEEN" != "<none>" ] && [ "$CTX_SEEN" = "$CTX_REF" ]; then
    check "[B7] context leg: the dispatcher's reference digest reaches the renderer verbatim ($CTX_SEEN)" ok
  else
    check "[B7] context leg: the dispatcher's reference digest reaches the renderer" fail \
      "renderer=${CTX_SEEN:-none} reference=${CTX_REF:-none}"
  fi
  # B7b — THE REPEATED-EVENT CASE on the SessionStart leg: the same payload fired again
  # (compact storms are byte-identical) must add a SECOND record under the same <event16>,
  # and every record in the session directory must pass cross-repo's validateRecord.
  printf '%s\n\n\n' "$P2" | env PATH="$SB/fakebin:$PATH" HOME="$FH2" REC="$REC2" \
    DHX_SCHEDULE_RENDERER="$SB/render2.cjs" DHX_SCHEDULE_CACHE_DIR="$SB/cache2" \
    /bin/bash "$DISPATCHER" >/dev/null 2>&1
  SD2=$(dirname "$BEAT2")
  N2=$(ls "$SD2"/*.json 2>/dev/null | wc -l | tr -d ' ')
  NH2=$(ls "$SD2" 2>/dev/null | sed -n 's/^\([0-9a-f]\{16\}\)\..*\.json$/\1/p' | sort -u | wc -l | tr -d ' ')
  FLAT2=$(ls "$FH2"/.cache/dhx/hooks/session-start/*.json 2>/dev/null | wc -l | tr -d ' ')
  STORE="$HOME/repos/cross-repo/scripts/schedule/dhx-schedule-store.cjs"
  V2=""
  if [ -r "$STORE" ]; then
    V2=$(node -e '
const s=require(process.argv[1]),fs=require("fs"),p=require("path");
const sd=process.argv[2],k=p.basename(sd);let bad=0;
for(const f of fs.readdirSync(sd)){let doc=null;try{doc=JSON.parse(fs.readFileSync(p.join(sd,f),"utf8"));}catch(e){}
  const pr=s.validateRecord(doc,{leg:"session-start",sessionKey:k,fileName:f});if(pr.length){bad++;console.error(f+": "+pr.join("; "));}}
console.log(String(bad));' "$STORE" "$SD2" 2>/dev/null)
  fi
  if [ "${N2:-0}" -eq 2 ] && [ "${NH2:-0}" -eq 1 ] && [ "${FLAT2:-0}" -eq 0 ] && [ "${V2:-0}" = 0 ]; then
    check "[B7b] SessionStart repeated event -> two distinct records, one <event16>, no flat slot, both pass validateRecord" ok
  else
    check "[B7b] SessionStart repeated event -> two distinct valid records under one <event16>" fail "records=${N2:-0} hashes=${NH2:-0} flat=${FLAT2:-0} invalid=${V2:-?}"
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
  # B12 — THE SESSION KEY, END TO END, AND AGAINST THE RIGHT TARGET (2026-09-03).
  # The assertion is NOT "a value arrived". It is that the key the renderer received is the
  # DIRECTORY NAME the dispatcher filed its own reference beat under, because that directory is
  # what cross-repo's classifier groups the two trees by. A beat placed anywhere else is not a
  # weaker match — it leaves the reference session DEAD and adds a MISSING-REFERENCE row.
  # Reads the B7 dispatcher run above; no second dispatch.
  CTX_SK=$(head -1 "$REC2SK" 2>/dev/null)
  REF_DIR=$(basename "$(dirname "$BEAT2")" 2>/dev/null)
  if [ -n "$CTX_SK" ] && [ "$CTX_SK" != "<none>" ] && [ "$CTX_SK" = "$REF_DIR" ]; then
    check "[B12] context leg: the renderer is handed the SAME session key the reference beat is filed under ($CTX_SK)" ok
  else
    check "[B12] context leg: the renderer's session key matches the reference beat's directory" fail \
      "renderer=${CTX_SK:-none} reference-dir=${REF_DIR:-none}"
  fi
  # B13 — the forgery floor, same contract as B8. This variable picks a whole session DIRECTORY
  # rather than one filename, so a non-digest value must degrade to empty and let the renderer
  # fall back to its own derivation — never be honoured as a place to file records.
  : > "$REC2"; : > "$REC2SK"
  printf '%s' "$P2" | env HOME="$FH2" REC="$REC2" REC_SK="$REC2SK" DHX_SCHEDULE_RENDERER="$SB/render2.cjs" \
    DHX_SCHEDULE_CACHE_DIR="$SB/cache2" DHX_SCHEDULE_SESSION_KEY='../../etc; rm -rf /' \
    /bin/bash "$CTX_SHIM" >/dev/null 2>&1
  FORGED_SK=$(head -1 "$REC2SK" 2>/dev/null)
  if [ -z "$FORGED_SK" ] || [ "$FORGED_SK" = "<none>" ]; then
    check "[B13] context shim rejects a malformed forwarded session key (empty, not forwarded)" ok
  else
    check "[B13] context shim rejects a malformed forwarded session key" fail "forwarded=${FORGED_SK}"
  fi
  # B15 — THE SCHEDULE CHILD SURVIVES A MID-DISPATCH KILL (2026-09-14). CC terminates a
  # still-running SessionStart hook when the session exits; before 2026-09-14 the child ran
  # ~10 siblings (5-30 s) after the reference record, so a session quitting inside that window
  # left reference-without-schedule and the health verb scored the leg DEAD (8/8 all-time
  # unpaired occurrences ended 5-32 s after the fire; 0/568 paired ever ended before their
  # record). The child now runs directly under the reference record and is EMITTED later.
  #
  # Synchronised, not timed: EVERY sibling stub writes a marker and then blocks, so the kill
  # lands the instant the first sibling — whichever it is — starts. That is deterministic and
  # robust to sibling reorders; a sleep-then-kill would be a race. SIGTERM to the dispatcher pid
  # alone is what a Node child.kill() sends; the fixture reproduction showed SIGKILL gives the
  # same shape. NOT a line-order assertion: line order is not the property, completion-before-
  # the-first-sibling is. Negative control (run once, 2026-09-14): the pre-reorder dispatcher
  # leaves the schedule record absent under this exact cell.
  FH15="$SB/home15"; mkdir -p "$FH15/.claude"
  MARK15="$SB/mark15"; rm -f "$MARK15"
  mkdir -p "$SB/fakebin15"
  cat > "$SB/fakebin15/bash" <<FB15EOF
#!/bin/sh
case "\$*" in
  *dhx-schedule-context.sh*) exec /bin/bash "\$@" ;;
  *) cat >/dev/null 2>&1; : > "$MARK15"; exec sleep 30 ;;
esac
FB15EOF
  chmod +x "$SB/fakebin15/bash"
  # Stub renderer: files ONE record under the forwarded session key, the way the real one does.
  cat > "$SB/render15.cjs" <<'JS15EOF'
const a=process.argv.slice(2),fs=require('fs'),p=require('path');
const j=a.indexOf('--session-key');const k=(j>=0&&a[j+1])||'nokey';
const d=p.join(process.env.DHX_SCHEDULE_CACHE_DIR,'health','session-start',k);
fs.mkdirSync(d,{recursive:true});fs.writeFileSync(p.join(d,'stub.json'),'{}\n');
process.stdout.write('due\n');
JS15EOF
  P15='{"session_id":"probe-ctx-kill-0001","source":"resume"}'
  K15=$(printf '%s' "probe-ctx-kill-0001" | sha256sum | cut -c1-16)
  printf '%s' "$P15" | env PATH="$SB/fakebin15:$PATH" HOME="$FH15" \
    DHX_SCHEDULE_RENDERER="$SB/render15.cjs" DHX_SCHEDULE_CACHE_DIR="$SB/cache15" \
    setsid /bin/bash "$DISPATCHER" >/dev/null 2>&1 &
  DPID15=$!
  SEEN15=0
  for _i in $(seq 1 100); do [ -e "$MARK15" ] && { SEEN15=1; break; }; sleep 0.1; done
  kill -TERM "$DPID15" 2>/dev/null
  wait "$DPID15" 2>/dev/null; RC15=$?
  kill -9 -- "-$DPID15" 2>/dev/null   # the orphaned `sleep 30` sibling stub
  REF15=$(ls "$FH15"/.cache/dhx/hooks/session-start/"$K15"/*.json 2>/dev/null | wc -l | tr -d ' ')
  SCH15=$(ls "$SB/cache15/health/session-start/$K15"/*.json 2>/dev/null | wc -l | tr -d ' ')
  if [ "$SEEN15" = 1 ] && [ "$RC15" = 143 ] && [ "${REF15:-0}" -ge 1 ] && [ "${SCH15:-0}" -ge 1 ]; then
    check "[B15] dispatcher SIGTERM'd the instant its first sibling starts -> reference AND schedule records both present (child ran before any sibling)" ok
  else
    check "[B15] dispatcher killed at first sibling -> both records present" fail \
      "marker-seen=$SEEN15 rc=$RC15 reference=${REF15:-0} schedule=${SCH15:-0}"
  fi
else
  echo "SKIP [B7-B8,B12-B13,B15] context-leg forwarding smoke — sha256sum/jq/node or the installed shim absent"
fi

# B9-B11 — DIGEST-TOOL PORTABILITY (cross-repo brief 2026-08-23 "schedule digest tool policy").
# Policy: every computing site runs ONE chain, `sha256sum` then `shasum -a 256`, for BOTH the
# session key and the event key (the dhx/poll-guard.sh SESSION_HASH precedent). Before this,
# a shasum-only host (macOS) produced NO reference beat at all — the guarded block was skipped
# on an empty session key — while the renderer still wrote its own beat, so health reported
# MISSING-REFERENCE and FAILed. Driven with a PATH that holds every tool EXCEPT sha256sum.
# The expected values come from the real sha256sum, so this also pins that the two tools
# agree byte-for-byte on the same canonicalised input.
if command -v sha256sum >/dev/null 2>&1 && command -v shasum >/dev/null 2>&1 \
   && command -v jq >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
  # Build a PATH that has no sha256sum on it. Only the dirs that actually CARRY
  # sha256sum need a sanitised mirror; every other dir passes through untouched.
  #
  # This used to mirror the WHOLE PATH — 9289 files across 28 dirs, one
  # $(basename) fork and up to one ln -s each. Profiled 2026-08-23: ~28k of the
  # probe's 63k traced commands, and the dominant term in a 20.2s runtime against
  # a 30s D-16 cap. On this host exactly 2 of 28 PATH dirs carry sha256sum
  # (/usr/bin, /bin), so the mirror shrinks by ~83% and the forks go to zero.
  # ${f##*/} is the fork-free spelling of basename.
  NSDIR="$SB/nosha"; mkdir -p "$NSDIR"
  IFS=: read -r -a _PDIRS <<<"$PATH"
  _NSPATH=()
  for d in "${_PDIRS[@]}"; do
    [ -d "$d" ] || continue
    if [ ! -e "$d/sha256sum" ]; then
      _NSPATH+=("$d")
      continue
    fi
    for f in "$d"/*; do
      b=${f##*/}
      [ "$b" = sha256sum ] && continue
      [ -x "$f" ] && [ ! -e "$NSDIR/$b" ] && ln -s "$f" "$NSDIR/$b" 2>/dev/null
    done
    _NSPATH+=("$NSDIR")
  done
  # $NS stays the PATH STRING the cells below consume, so their `PATH="$NS"` uses
  # are unchanged. Dir order is preserved, so shadowing precedence is too.
  NS=$(IFS=:; printf '%s' "${_NSPATH[*]}")
  if env PATH="$NS" sh -c 'command -v sha256sum' >/dev/null 2>&1; then
    echo "SKIP [B9-B11] could not build a sha256sum-less PATH"
  else
    P3='{"session_id":"probe-nosha-0001","transcript_path":"/probe/probe-nosha-0001.jsonl","cwd":"/probe","prompt":"100% - cafe"}'
    EXP_EV=$(printf '%s' "$P3" | sha256sum | cut -c1-16)
    EXP_SK=$(printf '%s' "probe-nosha-0001" | sha256sum | cut -c1-16)
    # B9 — registry hook (prompt leg reference beat)
    FH3="$SB/home3"; mkdir -p "$FH3/.claude"
    printf '%s' "$P3" | env PATH="$NS" HOME="$FH3" bash "$REGISTRY_HOOK" >/dev/null 2>&1
    B9F=$(ls "$FH3/.cache/dhx/hooks/prompt/$EXP_SK/$EXP_EV".*.json 2>/dev/null | head -1)
    B9E=$(sed -n 's/.*"event_hash":"\([^"]*\)".*/\1/p' "$B9F" 2>/dev/null)
    if [ -n "$B9F" ] && [ -f "$B9F" ] && [ "$B9E" = "$EXP_EV" ]; then
      check "[B9] registry reference beat written via shasum fallback; session key + event digest identical to sha256sum's ($EXP_SK/$EXP_EV)" ok
    else
      check "[B9] registry reference beat written via shasum fallback with sha256sum-identical keys" fail \
        "beat=$( [ -n "$B9F" ] && [ -f "$B9F" ] && echo present || echo ABSENT ) event=${B9E:-none} want=$EXP_EV"
    fi
    # B10 — dispatcher (session-start leg reference beat + forwarded digest)
    FH4="$SB/home4"; mkdir -p "$FH4/.claude"
    REC4="$SB/rec4.txt"; : > "$REC4"
    cat > "$SB/render4.cjs" <<'JS4EOF'
const a=process.argv.slice(2);
const i=a.indexOf('--event-hash');
require('fs').appendFileSync(process.env.REC,(i>=0?a[i+1]:'<none>')+'\n');
JS4EOF
    mkdir -p "$SB/fakebin4"
    cat > "$SB/fakebin4/bash" <<'FB4EOF'
#!/bin/sh
case "$*" in
  *dhx-schedule-context.sh*) exec /bin/bash "$@" ;;
  *) cat >/dev/null 2>&1; exit 0 ;;
esac
FB4EOF
    chmod +x "$SB/fakebin4/bash"
    printf '%s' "$P3" | env PATH="$SB/fakebin4:$NS" HOME="$FH4" REC="$REC4" \
      DHX_SCHEDULE_RENDERER="$SB/render4.cjs" DHX_SCHEDULE_CACHE_DIR="$SB/cache4" \
      /bin/bash "$DISPATCHER" >/dev/null 2>&1
    B10F=$(ls "$FH4/.cache/dhx/hooks/session-start/$EXP_SK/$EXP_EV".*.json 2>/dev/null | head -1)
    B10E=$(sed -n 's/.*"event_hash":"\([^"]*\)".*/\1/p' "$B10F" 2>/dev/null)
    if [ -n "$B10F" ] && [ -f "$B10F" ] && [ "$B10E" = "$EXP_EV" ]; then
      check "[B10] dispatcher reference beat written via shasum fallback; session key + event digest identical to sha256sum's" ok
    else
      check "[B10] dispatcher reference beat written via shasum fallback with sha256sum-identical keys" fail \
        "beat=$( [ -n "$B10F" ] && [ -f "$B10F" ] && echo present || echo ABSENT ) event=${B10E:-none} want=$EXP_EV"
    fi
    # B11 — prompt shim (already had the fallback; pinned so the chain stays symmetric)
    : > "$REC4"
    printf '%s' "$P3" | env PATH="$NS" HOME="$FH4" REC="$REC4" DHX_SCHEDULE_RENDERER="$SB/render4.cjs" \
      DHX_SCHEDULE_CACHE_DIR="$SB/cache4" bash "$PROMPT_SHIM" >/dev/null 2>&1
    B11=$(head -1 "$REC4" 2>/dev/null)
    if [ "$B11" = "$EXP_EV" ]; then
      check "[B11] prompt shim event digest via shasum fallback identical to sha256sum's" ok
    else
      check "[B11] prompt shim event digest via shasum fallback identical to sha256sum's" fail "got=${B11:-none} want=$EXP_EV"
    fi
  fi
else
  echo "SKIP [B9-B11] digest-tool portability — sha256sum/shasum/jq/node absent"
fi

echo "---"
echo "$PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
