#!/usr/bin/env bash
# probe-guard-load-assert.sh — dhx/dhx-guard-load-assert.sh (cross-channel plugin-load assertion)
#
# The hook warns ONCE per session invocation when the dhx plugin channel left no trace of
# having run, which means every dhx PreToolUse guard is absent from the running process. It
# is registered in settings.json, NOT in the plugin manifest, because a hook cannot report
# that its own channel failed to load. It is registered there twice: on SessionStart it writes
# a birth stamp (the invocation boundary), on UserPromptSubmit it asserts.
#
# THE FIVE STATES THIS PINS read identically to every registry-level check (symlinks,
# manifest, verify-hooks.sh); only channel records and the hook's stamps separate them, and
# only two may warn:
#   [1]-[2]  loaded (legacy: beat, no birth stamp)          -> SILENT
#   [3]-[6]  registry rejected (birth, no plugin record)    -> WARN at prompt 1, naming guards
#   [7]      manifest edited mid-session, beat PRESENT       -> SILENT
#   [15]     born without SessionStart, channel live         -> SILENT (fork / resume-mint)
#   [16]     born without SessionStart, channel dead         -> WARN at prompt 2, NO LATER
# [7] is the arm that keeps this hook alive. HP-020: manifest registration does not
# hot-reload, so every hook-development session in this repo edits a manifest whose new
# entries legitimately are not running. A check keyed on manifest freshness rather than on
# channel records would fire on all of them and be switched off inside a day.
# [15] is the arm that was missing until 2026-09-24: CC fires no SessionStart for a fork's id
# or a continuation-mint's, and 7 of 7 warnings on the host up to then were false alarms.
#
# [12] pins the STATED LIMIT in the emitted text: a record proves the CHANNEL loaded, not
# that CC routes PreToolUse to each guard. That caveat is load-bearing (an external reviewer
# raised it on 2026-09-20) and a future edit must not quietly upgrade the claim, so it is a
# contract tooth rather than a comment. [23] does the same for the weaker, no-SessionStart
# warning, which must not assert as fact what two misses only suggest.
#
# [17] ENCODES THE CONCURRENCY PREMISE rather than assuming it: hooks on one event run
# concurrently, and in the fork that surfaced the defect the prompt's own record landed 31 ms
# AFTER this hook ran. So the fix may not depend on the same-prompt record; [17] writes it only
# after the first call and shows the verdict comes from the earlier prompt.
#
# NEGATIVE CONTROL (run by hand; kept out of the tier so the probe never touches git):
#   git show fabe96ac:dhx/dhx-guard-load-assert.sh > /tmp/pre.sh
#   PROBE_GUARD_LOAD_ASSERT_HOOK=/tmp/pre.sh bash tests/probes/probe-guard-load-assert.sh
# must RED [15] (the pre-fix hook warns on the fork shape) and [19] (it stays silent on the
# resume-masking shape). A green run there means these cases stopped discriminating.
#
# Run: bash tests/probes/probe-guard-load-assert.sh
#
# SAFE_FOR_LIVE: yes   (every seam is redirected into mktemp trees — DHX_HOOKS_CACHE_DIR
#                       for the beat/prompt records, birth/verified/pending stamps and the
#                       first-sight marker, DHX_PLUGIN_MANIFEST for the guard enumeration;
#                       synthetic stdin; no reads or writes under ~/.cache/dhx, ~/.ccs,
#                       ~/.claude or the live repo; no git; no network.)

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="${PROBE_GUARD_LOAD_ASSERT_HOOK:-$REPO/dhx/dhx-guard-load-assert.sh}"

if [[ ! -f "$HOOK" ]]; then echo "FAIL hook not found: $HOOK"; exit 1; fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASSED=0; FAILED=0
_assert() { if [[ "$2" == "$3" ]]; then echo "OK   $1"; PASSED=$((PASSED+1));
            else echo "FAIL $1 (expected [$2], got [$3])"; FAILED=$((FAILED+1)); fi; }

# Fixture manifest — two recognisable guard basenames, one of them nested in a second entry
# so the flattening over .hooks[] is exercised rather than assumed.
MANIFEST="$TMP/hooks.json"
cat > "$MANIFEST" <<'JSON'
{"hooks":{"PreToolUse":[
  {"matcher":"Read|Grep|Bash","hooks":[{"type":"command","command":"node \"$HOME/.claude/hooks/fixture-key-guard.js\""}]},
  {"matcher":"Bash","hooks":[
     {"type":"command","command":"bash \"$HOME/.claude/hooks/fixture-destructive-guard.sh\""},
     {"type":"command","command":"bash \"$HOME/.claude/hooks/fixture-worktree-guard.sh\""}]}],
 "SessionStart":[{"matcher":"startup","hooks":[{"type":"command","command":"bash \"x/session-start.sh\""}]}]}}
JSON

SID="probe-guard-load-session"
# Digest computed EXACTLY as the dispatcher's _dhx_digest16 does: printf '%s' (no trailing
# newline), sha256sum, cut -c1-16. If this probe and the hook ever disagree on the chain,
# [1] goes red — which is the point of writing the beat under an independently derived key
# rather than asking the hook where it looked.
KEY=$(printf '%s' "$SID" | sha256sum | cut -c1-16)
STDIN_JSON=$(jq -nc --arg s "$SID" '{session_id:$s, prompt:"anything"}')
SS_JSON=$(jq -nc --arg s "$SID" '{session_id:$s, hook_event_name:"SessionStart", source:"startup"}')

# The witness wait defaults to 2 s; fixtures that must warn would pay it on every case. 150 ms
# keeps the poll loop exercised (it runs at least once) without the stall. [18] overrides it.
WAIT=150
_fire() { # $1 cache root ; echoes stdout, stderr captured to $TMP/err
  DHX_HOOKS_CACHE_DIR="$1" DHX_PLUGIN_MANIFEST="$MANIFEST" DHX_GUARD_LOAD_ASSERT_WAIT_MS="$WAIT" \
    bash "$HOOK" <<<"$STDIN_JSON" 2>"$TMP/err"
}
_now_ms() { date +%s%3N; }
# A birth stamp as the hook's SessionStart arm writes it (epoch ms). Written directly so the
# registry-rejected fixtures do not depend on [21]'s arm being right.
_born() { # $1 cache root [$2 ms]
  mkdir -p "$1/guard-load-assert-state/$KEY"; printf '%s\n' "${2:-$(_now_ms)}" > "$1/guard-load-assert-state/$KEY/birth"
}
# A plugin record named the way the real writers name them: <event16>.<fired_ms>.<pid>.<nonce>.json
_record() { # $1 cache root, $2 leg, $3 fired_ms
  mkdir -p "$1/$2/$KEY"; echo "{\"schema_version\":2,\"leg\":\"$2\"}" > "$1/$2/$KEY/ev.$3.1.2.json"
}
_warned() { [[ -n "$(find "$1/guard-load-assert/$KEY" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)" ]] && echo yes || echo no; }

# --- [1]-[2] loaded: a beat exists -> silent ---
LOADED="$TMP/loaded"; mkdir -p "$LOADED/session-start/$KEY"
echo '{"schema_version":2,"leg":"session-start"}' > "$LOADED/session-start/$KEY/ev.1.2.3.json"
OUT=$(_fire "$LOADED")
_assert "[1] beat present (dispatcher-derived key) -> silent" "" "$OUT"
_assert "[2] beat present -> nothing on stderr either" "" "$(cat "$TMP/err")"

# --- [3]-[6] registry rejected: SessionStart fired (birth stamp), no plugin record -> one
# warning at the FIRST prompt, naming the absent guards. The birth stamp is what makes this
# fixture the registry-rejected state: without it the same disk is the fork shape of [16]. ---
ABSENT="$TMP/absent"; mkdir -p "$ABSENT"; _born "$ABSENT"
OUT=$(_fire "$ABSENT")
_assert "[3] beat absent -> emits valid JSON" "yes" \
  "$(jq -e . >/dev/null 2>&1 <<<"$OUT" && echo yes || echo no)"
_assert "[4] beat absent -> systemMessage reaches the operator (HP-055)" "yes" \
  "$(jq -re '.systemMessage | select(length>0)' >/dev/null 2>&1 <<<"$OUT" && echo yes || echo no)"
CTX=$(jq -r '.hookSpecificOutput.additionalContext // ""' <<<"$OUT" 2>/dev/null)
_assert "[5] warning NAMES the absent guards, not just a registry state" "yes" \
  "$(grep -q 'fixture-key-guard.js' <<<"$CTX" && grep -q 'fixture-destructive-guard.sh' <<<"$CTX" \
     && grep -q 'fixture-worktree-guard.sh' <<<"$CTX" && echo yes || echo no)"
_assert "[6] enumeration is PreToolUse-scoped (no SessionStart entry leaks in)" "no" \
  "$(grep -q 'session-start.sh' <<<"$CTX" && echo yes || echo no)"

# --- [7] manifest edited mid-session, beat present -> SILENT (the no-wolf-crying arm) ---
touch "$MANIFEST"
OUT=$(_fire "$LOADED")
_assert "[7] manifest newer than the beat, beat present -> silent (HP-020 dev sessions)" "" "$OUT"

# --- [8] first-sight: the same broken session warns once, not every prompt ---
OUT=$(_fire "$ABSENT")
_assert "[8] second prompt in a broken session -> silent (mkdir test-and-set)" "" "$OUT"
_assert "[8b] first-sight marker was created under the cache root" "yes" \
  "$([[ -d "$ABSENT/guard-load-assert/$KEY" ]] && echo yes || echo no)"

# --- [9]-[11] guards: kill switch, missing id, literal `unknown` ---
KS="$TMP/ks"; mkdir -p "$KS"
_assert "[9] kill switch DHX_GUARD_LOAD_ASSERT=0 -> silent" "" \
  "$(DHX_GUARD_LOAD_ASSERT=0 DHX_HOOKS_CACHE_DIR="$KS" DHX_PLUGIN_MANIFEST="$MANIFEST" \
       bash "$HOOK" <<<"$STDIN_JSON" 2>/dev/null)"
NOID="$TMP/noid"; mkdir -p "$NOID"
_assert "[10] no session_id -> silent (nothing to key on)" "" \
  "$(DHX_HOOKS_CACHE_DIR="$NOID" DHX_PLUGIN_MANIFEST="$MANIFEST" \
       bash "$HOOK" <<<'{"prompt":"x"}' 2>/dev/null)"
UNK="$TMP/unk"; mkdir -p "$UNK"
_assert "[11] session_id 'unknown' -> silent (never a beat key)" "" \
  "$(DHX_HOOKS_CACHE_DIR="$UNK" DHX_PLUGIN_MANIFEST="$MANIFEST" \
       bash "$HOOK" <<<'{"session_id":"unknown"}' 2>/dev/null)"

# --- [12] the STATED LIMIT survives in the emitted text ---
# A record proves the CHANNEL loaded; it cannot prove CC routes PreToolUse to each guard.
# Overstating that is how a necessary-but-not-sufficient signal gets treated as sufficient
# and retires the behavioural check that actually covers routing.
LIM="$TMP/lim"; mkdir -p "$LIM"; _born "$LIM"
CTX2=$(_fire "$LIM" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
_assert "[12] emitted text states it does not cover per-guard tool routing" "yes" \
  "$(grep -qi 'routing' <<<"$CTX2" && echo yes || echo no)"

# --- [13] manifest unreadable + no beat -> still warns, and says why it cannot enumerate ---
BAD="$TMP/bad"; mkdir -p "$BAD"; _born "$BAD"
CTX3=$(DHX_HOOKS_CACHE_DIR="$BAD" DHX_PLUGIN_MANIFEST="$TMP/does-not-exist.json" DHX_GUARD_LOAD_ASSERT_WAIT_MS="$WAIT" \
         bash "$HOOK" <<<"$STDIN_JSON" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // ""')
_assert "[13] unreadable manifest -> warns anyway, treating ALL guards as absent" "yes" \
  "$(grep -q 'cannot enumerate' <<<"$CTX3" && echo yes || echo no)"

# --- [14] the hook never writes outside the cache root it was given ---
_assert "[14] no stray writes at the cache root's parent" "0" \
  "$(find "$TMP" -maxdepth 1 -newer "$MANIFEST" -name 'guard-load-assert' 2>/dev/null | wc -l)"

# ======================= 2026-09-24: sessions born without SessionStart =======================

# --- [15] fork / resume-mint, channel live: no beat, no birth, a prompt record from an EARLIER
# prompt -> silent, no first-sight marker, nothing deferred. The pre-fix hook warns here. ---
FORK="$TMP/fork"; mkdir -p "$FORK"; _record "$FORK" prompt "$(( $(_now_ms) - 60000 ))"
OUT=$(_fire "$FORK")
_assert "[15] born without SessionStart, earlier prompt record -> silent" "" "$OUT"
_assert "[15b] ... and no first-sight marker planted" "no" "$(_warned "$FORK")"

# --- [16] fork, channel DEAD: no record of either leg. Latency pinned: silent at prompt 1
# (undecidable), warns at prompt 2, then silent (first-sight). ---
DEAD="$TMP/dead"; mkdir -p "$DEAD"
OUT=$(_fire "$DEAD")
_assert "[16] born without SessionStart, no record, prompt 1 -> silent (deferred)" "" "$OUT"
_assert "[16b] ... a pending stamp was planted" "yes" \
  "$([[ -s "$DEAD/guard-load-assert-state/$KEY/pending" ]] && echo yes || echo no)"
OUT=$(_fire "$DEAD")
CTX4=$(jq -r '.hookSpecificOutput.additionalContext // ""' <<<"$OUT" 2>/dev/null)
_assert "[16c] ... prompt 2 WARNS and names the absent guards (no later than prompt 2)" "yes" \
  "$(grep -q 'fixture-key-guard.js' <<<"$CTX4" && grep -q 'fixture-destructive-guard.sh' <<<"$CTX4" && echo yes || echo no)"
_assert "[16d] ... prompt 3 silent (first-sight)" "" "$(_fire "$DEAD")"

# --- [17] the concurrency premise: the prompt's own record lands only AFTER the hook ran ---
# Prompt 1 sees nothing (its record is written after), so it must defer, not warn; prompt 2
# then finds prompt 1's record. Nothing in this sequence ever lets prompt 1 see its own record.
RACE="$TMP/race"; mkdir -p "$RACE"
OUT=$(_fire "$RACE")
_assert "[17] same-prompt record not yet written -> prompt 1 silent" "" "$OUT"
_record "$RACE" prompt "$(_now_ms)"          # the concurrent writer finishing late
OUT=$(_fire "$RACE")
_assert "[17b] ... prompt 2 finds prompt 1's record -> silent, never warned" "|no" "$OUT|$(_warned "$RACE")"

# --- [18] the bounded wait: at the verdict prompt, a record landing DURING the wait rescues ---
# Also the silent-write-failure shape: prompt 1's record never landed, prompt 2's does.
LATE="$TMP/late"; mkdir -p "$LATE"; _fire "$LATE" >/dev/null     # prompt 1 -> pending
( sleep 0.4; _record "$LATE" prompt "$(_now_ms)" ) &
OUT=$(DHX_HOOKS_CACHE_DIR="$LATE" DHX_PLUGIN_MANIFEST="$MANIFEST" DHX_GUARD_LOAD_ASSERT_WAIT_MS=3000 \
        bash "$HOOK" <<<"$STDIN_JSON" 2>/dev/null)
wait
_assert "[18] witness lands 400 ms into a 3 s wait -> silent" "|no" "$OUT|$(_warned "$LATE")"

# --- [19] resume masking (external reviewer, 2026-09-24): an OLD invocation's beat and prompt
# record, then a fresh SessionStart (birth) with the plugin dead -> WARN at prompt 1. Keying on
# "any record for this id" -- the pre-fix design -- is silent here. ---
RES="$TMP/resume"; mkdir -p "$RES"
OLD=$(( $(_now_ms) - 3600000 ))
_record "$RES" session-start "$OLD"; _record "$RES" prompt "$((OLD + 5000))"; _born "$RES"
OUT=$(_fire "$RES")
_assert "[19] --resume with only the previous invocation's records -> warns at prompt 1" "yes" \
  "$(jq -re '.systemMessage | select(length>0)' >/dev/null 2>&1 <<<"$OUT" && echo yes || echo no)"

# --- [20] healthy invocation: birth + a beat from the same SessionStart (a few ms EARLIER than
# the stamp -- the two writers are concurrent) -> silent, and a verified stamp caches it ---
OK1="$TMP/ok"; mkdir -p "$OK1"; B=$(_now_ms); _record "$OK1" session-start "$((B - 800))"; _born "$OK1" "$B"
_assert "[20] beat within the SessionStart skew of the birth stamp -> silent" "" "$(_fire "$OK1")"
_assert "[20b] ... verified stamp written" "yes" \
  "$([[ -s "$OK1/guard-load-assert-state/$KEY/verified" ]] && echo yes || echo no)"
# The 7-day record GC deletes the beat later; the verified stamp is in this hook's own tree.
rm -rf "$OK1/session-start"
_assert "[20c] ... beat GC'd afterwards -> still silent (verified outlives the record GC)" "" "$(_fire "$OK1")"

# --- [21] the SessionStart arm: writes the birth stamp, emits NOTHING on either stream ---
SS="$TMP/ss"; mkdir -p "$SS"
OUT=$(DHX_HOOKS_CACHE_DIR="$SS" DHX_PLUGIN_MANIFEST="$MANIFEST" bash "$HOOK" <<<"$SS_JSON" 2>"$TMP/err")
_assert "[21] SessionStart event -> no stdout, no stderr" "|" "$OUT|$(cat "$TMP/err")"
_assert "[21b] ... birth stamp is epoch ms" "yes" \
  "$(grep -qE '^[0-9]{13}$' "$SS/guard-load-assert-state/$KEY/birth" 2>/dev/null && echo yes || echo no)"

# --- [22] residual (F3, operator-ruled 2026-09-24): where the prompt writer writes nothing by
# design, its absence is not evidence -> the fork-dead shape stays silent through prompt 2 ---
QW="$TMP/qw"; mkdir -p "$QW"
for _ in 1 2; do OUT=$(QW_CELL=1 _fire "$QW"); done
_assert "[22] QW_CELL=1, born without SessionStart, no record, prompt 2 -> silent" "|no" "$OUT|$(_warned "$QW")"
AG="$TMP/agent"; mkdir -p "$AG"
for _ in 1 2; do OUT=$(DHX_HOOKS_CACHE_DIR="$AG" DHX_PLUGIN_MANIFEST="$MANIFEST" DHX_GUARD_LOAD_ASSERT_WAIT_MS="$WAIT" \
  bash "$HOOK" <<<"$(jq -nc --arg s "$SID" '{session_id:$s, agent_id:"a1", prompt:"x"}')" 2>/dev/null); done
_assert "[22b] non-empty agent_id, same shape -> silent" "|no" "$OUT|$(_warned "$AG")"

# --- [23] the weaker warning says only what two misses show ---
D2="$TMP/dead2"; mkdir -p "$D2"; _fire "$D2" >/dev/null; W2=$(_fire "$D2")
MSG4=$(jq -r '.systemMessage // ""' <<<"$W2"); CTX5=$(jq -r '.hookSpecificOutput.additionalContext // ""' <<<"$W2")
_assert "[23] no-SessionStart warning hedges ('appears'), never asserts the guards absent as fact" "yes|no" \
  "$(grep -q 'appears' <<<"$MSG4" && echo yes || echo no)|$(grep -q 'guard is absent from this process' <<<"$MSG4$CTX5" && echo yes || echo no)"
_assert "[23b] ... and still states the routing limit" "yes" "$(grep -qi 'routing' <<<"$CTX5" && echo yes || echo no)"

# --- [24] first-sight is per INVOCATION: a resume that finds the plugin dead again speaks again ---
# Reuses [3]'s broken invocation (already warned) and stamps a new SessionStart.
sleep 0.01; _born "$ABSENT"
_assert "[24] new birth after a warned invocation, plugin still dead -> warns again" "yes" \
  "$(_fire "$ABSENT" | jq -re '.systemMessage | select(length>0)' >/dev/null 2>&1 && echo yes || echo no)"

# --- [25] the SessionStart arm prunes state dirs untouched for 14 days, and nothing else ---
PR="$TMP/prune"; mkdir -p "$PR/guard-load-assert-state/0123456789abcdef" "$PR/guard-load-assert-state/not-a-key"
touch -d '20 days ago' "$PR/guard-load-assert-state/0123456789abcdef" "$PR/guard-load-assert-state/not-a-key"
DHX_HOOKS_CACHE_DIR="$PR" bash "$HOOK" <<<"$SS_JSON" >/dev/null 2>&1
_assert "[25] 20-day-old key dir pruned; a non-key name left alone; own dir kept" "no|yes|yes" \
  "$([[ -d "$PR/guard-load-assert-state/0123456789abcdef" ]] && echo yes || echo no)|$([[ -d "$PR/guard-load-assert-state/not-a-key" ]] && echo yes || echo no)|$([[ -s "$PR/guard-load-assert-state/$KEY/birth" ]] && echo yes || echo no)"

echo "---"
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
