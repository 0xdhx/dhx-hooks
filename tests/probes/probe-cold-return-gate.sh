#!/usr/bin/env bash
# probe-cold-return-gate.sh — regression probe for dhx/dhx-cold-return-gate.sh
# SAFE_FOR_LIVE: yes
# RUNTIME: ~5s
#
# Invariant exercised: the cold-return gate blocks (exit 2) ONLY on positive
# evidence of a dead cache over a large context, stages the erased prompt, and
# passes the immediate resend — and fails OPEN on every ambiguous transcript
# state, because exit 2 erases the operator's prompt.
#
# Backs: docs/decisions.md 2026-08-15 "cold-return advisory gate" row
#        (arc node N6, manifest Item B as amended by the N5 codex review).
#
# Run: bash tests/probes/probe-cold-return-gate.sh
#
# Isolation: every case runs against a mktemp cache dir + mktemp transcript
# fixtures via DHX_COLD_RETURN_CACHE_DIR / DHX_COLD_RETURN_NOW; the hook is
# invoked as a subshell with synthetic stdin. Nothing reads or writes live
# ~/.cache/dhx, live transcripts, or any repo state.

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/dhx/dhx-cold-return-gate.sh"
PASS=0
FAIL=0

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

NOW=1780000000   # fixed clock; every fixture timestamp is derived from it

ok()   { PASS=$((PASS + 1)); printf 'OK   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1 (expected $3, got $2)"; fi; }

# ISO 8601 with milliseconds — the exact shape CC writes (and the shape jq's
# fromdateiso8601 refuses without the hook's fractional-second strip).
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z; }

# assistant_entry <epoch> <read> <creation> <e1h> <e5m> [sidechain] [model]
assistant_entry() {
  local ts read crt e1h e5m side model
  ts=$(iso "$1"); read=$2; crt=$3; e1h=$4; e5m=$5; side=${6:-false}; model=${7:-claude-opus-5}
  printf '{"type":"assistant","isSidechain":%s,"timestamp":"%s","message":{"model":"%s","usage":{"input_tokens":4,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s,"cache_creation":{"ephemeral_1h_input_tokens":%s,"ephemeral_5m_input_tokens":%s},"output_tokens":50}}}\n' \
    "$side" "$ts" "$model" "$read" "$crt" "$e1h" "$e5m"
}

# user_entry <epoch> <content>
user_entry() {
  printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"%s"}}\n' "$(iso "$1")" "$2"
}

# run_case <name> <transcript-file> [extra env assignments...] — sets RC/OUT/ERR
run_case() {
  local name=$1 transcript=$2; shift 2
  CASE_DIR="$TMPROOT/$name"
  mkdir -p "$CASE_DIR"
  local prompt='do the thing\nline two — keep these bytes'
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"/tmp","prompt":"%s"}' \
    "$name" "$transcript" "$prompt" > "$CASE_DIR/in.json"
  OUT_F="$CASE_DIR/stdout"; ERR_F="$CASE_DIR/stderr"
  ( export DHX_COLD_RETURN_CACHE_DIR="$CASE_DIR/cache" DHX_COLD_RETURN_NOW="$NOW" "$@"
    bash "$HOOK" < "$CASE_DIR/in.json" > "$OUT_F" 2> "$ERR_F" )
  RC=$?
  OUT=$(cat "$OUT_F"); ERR=$(cat "$ERR_F")
}

printf '=== dhx-cold-return-gate ===\n'

# --- [1] warm anchor: inside TTL -> silent allow -----------------------------
T="$TMPROOT/warm.jsonl"
assistant_entry $((NOW - 600)) 200000 600 600 0 > "$T"
run_case warm "$T"
check '[1] warm anchor (10m old) -> allow' "$RC" 0
check '[1] warm anchor -> silent stderr' "$([ -z "$ERR" ] && echo empty || echo noisy)" empty

# --- [2] cold + large context -> block, stage, message -----------------------
T="$TMPROOT/cold.jsonl"
{ user_entry $((NOW - 7300)) "hello"
  assistant_entry $((NOW - 7200)) 200000 600 600 0; } > "$T"
run_case cold "$T"
check '[2] cold anchor (2h) + 200k ctx -> BLOCK' "$RC" 2
check '[2] block writes nothing to stdout' "$([ -z "$OUT" ] && echo empty || echo leaked)" empty
STAGE="$TMPROOT/cold/cache/cold-return-stage-cold.txt"
check '[2] stage file exists' "$([ -f "$STAGE" ] && echo yes || echo no)" yes
check '[2] stage file mode 0600' "$(stat -c '%a' "$STAGE" 2>/dev/null)" 600
check '[2] stage preserves multiline prompt bytes' \
  "$(printf 'do the thing\nline two — keep these bytes' | cmp -s - "$STAGE" && echo exact || echo differs)" exact
case "$ERR" in *"$STAGE"*) ok '[2] stderr names the stage path' ;; *) bad '[2] stderr names the stage path' ;; esac
case "$ERR" in *"≈401k"*) ok '[2] stderr states the ~2x cold cost (401k)' ;; *) bad "[2] stderr states the ~2x cold cost — got: $ERR" ;; esac
case "$ERR" in *"/clear"*"/compact"*) ok '[2] stderr states both fork options' ;; *) bad '[2] stderr states both fork options' ;; esac
case "$ERR" in *"observed write bucket"*) ok '[2] TTL labelled observed' ;; *) bad '[2] TTL labelled observed' ;; esac
# Renderer ceiling: <=76 cols, no emoji/PUA (terminal-constraints.md).
WIDE=$(awk 'length($0) > 76 {c++} END {print c+0}' "$TMPROOT/cold/stderr")
check '[2] every stderr line <= 76 cols' "$WIDE" 0
check '[2] no emoji / PUA in stderr' \
  "$(LC_ALL=C grep -cP '[\x{1F300}-\x{1FAFF}\x{E000}-\x{F8FF}]' "$TMPROOT/cold/stderr" 2>/dev/null || echo 0)" 0

# --- [3] marker consume: the immediate resend passes -------------------------
( export DHX_COLD_RETURN_CACHE_DIR="$TMPROOT/cold/cache" DHX_COLD_RETURN_NOW="$NOW"
  bash "$HOOK" < "$TMPROOT/cold/in.json" > "$TMPROOT/cold/stdout2" 2> "$TMPROOT/cold/stderr2" )
RC=$?
check '[3] resend consumes marker -> allow' "$RC" 0
check '[3] resend is silent' "$([ -s "$TMPROOT/cold/stderr2" ] && echo noisy || echo empty)" empty
check '[3] marker removed on consume' \
  "$([ -f "$TMPROOT/cold/cache/cold-return-marker-cold.json" ] && echo present || echo gone)" gone
check '[3] stage file removed on consume' "$([ -f "$STAGE" ] && echo present || echo gone)" gone

# --- [4] cooldown: no second block inside the window -------------------------
( export DHX_COLD_RETURN_CACHE_DIR="$TMPROOT/cold/cache" DHX_COLD_RETURN_NOW=$((NOW + 300))
  bash "$HOOK" < "$TMPROOT/cold/in.json" > /dev/null 2> "$TMPROOT/cold/stderr3" )
check '[4] second cold prompt inside cooldown -> allow' "$?" 0
# ...and blocks again once the cooldown has expired (state is not a permanent mute)
( export DHX_COLD_RETURN_CACHE_DIR="$TMPROOT/cold/cache" DHX_COLD_RETURN_NOW=$((NOW + 1000))
  bash "$HOOK" < "$TMPROOT/cold/in.json" > /dev/null 2> /dev/null )
check '[4] cold prompt after cooldown -> BLOCK again' "$?" 2

# --- [5] deadband: over threshold but under the arm level --------------------
T="$TMPROOT/deadband.jsonl"
assistant_entry $((NOW - 7200)) 155000 600 600 0 > "$T"
run_case deadband "$T"
check '[5] 155k ctx (>150k, <165k arm) -> allow' "$RC" 0

# --- [6] anchoring on a cold WRITE, not only on reads ------------------------
# The read-only predicate in readCacheAnchor is the source of its one-turn lag;
# a completed cache_creation means the server just wrote a warm prefix.
T="$TMPROOT/writeanchor.jsonl"
assistant_entry $((NOW - 7200)) 0 220000 220000 0 > "$T"
run_case writeanchor "$T"
check '[6] read=0 + 220k creation anchors -> BLOCK' "$RC" 2

# --- [7] sidechain entries never anchor the main conversation ----------------
T="$TMPROOT/sidechain.jsonl"
{ assistant_entry $((NOW - 7200)) 200000 600 600 0
  assistant_entry $((NOW - 60)) 190000 500 0 500 true; } > "$T"
run_case sidechain "$T"
check '[7] fresh sidechain read does not refresh anchor -> BLOCK' "$RC" 2

# --- [8] HP-019 file-order/timestamp disorder -> fail open -------------------
T="$TMPROOT/disorder.jsonl"
{ assistant_entry $((NOW - 7200)) 200000 600 600 0
  assistant_entry $((NOW - 20000)) 200000 600 600 0; } > "$T"
run_case disorder "$T"
check '[8] late-flushed out-of-order entry -> allow (fail open)' "$RC" 0

# --- [9] HP-027 /model + /login observed after the anchor -> fail open -------
T="$TMPROOT/modelswitch.jsonl"
{ assistant_entry $((NOW - 7200)) 200000 600 600 0
  user_entry $((NOW - 300)) '<command-name>/model</command-name>'; } > "$T"
run_case modelswitch "$T"
check '[9] /model after anchor -> allow (anchor invalidated)' "$RC" 0
T="$TMPROOT/loginswitch.jsonl"
{ assistant_entry $((NOW - 7200)) 200000 600 600 0
  user_entry $((NOW - 300)) '<command-name>/login</command-name>'; } > "$T"
run_case loginswitch "$T"
check '[9] /login after anchor -> allow (anchor invalidated)' "$RC" 0
# A /model BEFORE the anchor is history, not invalidation.
T="$TMPROOT/modelbefore.jsonl"
{ user_entry $((NOW - 9000)) '<command-name>/model</command-name>'
  assistant_entry $((NOW - 7200)) 200000 600 600 0; } > "$T"
run_case modelbefore "$T"
check '[9] /model BEFORE anchor -> still BLOCK' "$RC" 2

# --- [10] future-dated anchor -> fail open -----------------------------------
T="$TMPROOT/future.jsonl"
assistant_entry $((NOW + 7200)) 200000 600 600 0 > "$T"
run_case future "$T"
check '[10] anchor dated in the future -> allow' "$RC" 0

# --- [11] TTL source: 5m bucket observed -------------------------------------
# 20 minutes idle is warm under 1h and dead under 5m — the bucket read decides.
T="$TMPROOT/ttl5m.jsonl"
assistant_entry $((NOW - 1200)) 200000 60000 0 60000 > "$T"
run_case ttl5m "$T"
check '[11] 20m idle on an observed 5m bucket -> BLOCK' "$RC" 2
case "$ERR" in *"TTL 5m"*) ok '[11] message reports TTL 5m' ;; *) bad "[11] message reports TTL 5m — got: $ERR" ;; esac
T="$TMPROOT/ttl1h.jsonl"
assistant_entry $((NOW - 1200)) 200000 600 600 0 > "$T"
run_case ttl1h "$T"
check '[11] 20m idle on an observed 1h bucket -> allow' "$RC" 0

# --- [12] TTL unreadable -> 3600 assumed, and the message says so ------------
T="$TMPROOT/ttlassumed.jsonl"
printf '{"type":"assistant","timestamp":"%s","message":{"model":"claude-opus-5","usage":{"input_tokens":4,"cache_read_input_tokens":200000,"cache_creation_input_tokens":0,"output_tokens":50}}}\n' \
  "$(iso $((NOW - 7200)))" > "$T"
run_case ttlassumed "$T"
check '[12] no write bucket in tail -> BLOCK on assumed 1h' "$RC" 2
case "$ERR" in *"assumed"*) ok '[12] message flags the TTL as assumed' ;; *) bad "[12] message flags the TTL as assumed — got: $ERR" ;; esac
case "$ERR" in *"overage"*) ok '[12] assumed branch carries the overage caveat' ;; *) bad '[12] assumed branch carries the overage caveat' ;; esac

# --- [13] no anchor candidate in the window -> fail open ---------------------
T="$TMPROOT/noanchor.jsonl"
{ user_entry $((NOW - 7200)) "hello"
  assistant_entry $((NOW - 7200)) 0 900 900 0; } > "$T"   # creation below CRT_MIN
run_case noanchor "$T"
check '[13] no read + sub-threshold creation -> allow' "$RC" 0

# --- [14] torn first line in the tail window is dropped, not fatal -----------
T="$TMPROOT/torn.jsonl"
{ printf '{"type":"assistant","timestamp":"trunc\n'
  assistant_entry $((NOW - 7200)) 200000 600 600 0; } > "$T"
run_case torn "$T"
check '[14] torn leading record -> still BLOCK on the valid anchor' "$RC" 2

# --- [15] malformed / missing payloads -> fail open --------------------------
CASE_DIR="$TMPROOT/malformed"; mkdir -p "$CASE_DIR/cache"
( export DHX_COLD_RETURN_CACHE_DIR="$CASE_DIR/cache" DHX_COLD_RETURN_NOW="$NOW"
  printf 'not json at all' | bash "$HOOK" > "$CASE_DIR/out" 2> "$CASE_DIR/err" )
check '[15] non-JSON stdin -> allow' "$?" 0
( export DHX_COLD_RETURN_CACHE_DIR="$CASE_DIR/cache" DHX_COLD_RETURN_NOW="$NOW"
  printf '' | bash "$HOOK" > /dev/null 2>&1 )
check '[15] empty stdin -> allow' "$?" 0
( export DHX_COLD_RETURN_CACHE_DIR="$CASE_DIR/cache" DHX_COLD_RETURN_NOW="$NOW"
  printf '{"session_id":"x","prompt":"hi"}' | bash "$HOOK" > /dev/null 2>&1 )
check '[15] missing transcript_path -> allow' "$?" 0
( export DHX_COLD_RETURN_CACHE_DIR="$CASE_DIR/cache" DHX_COLD_RETURN_NOW="$NOW"
  printf '{"session_id":"x","transcript_path":"/nonexistent/nope.jsonl","prompt":"hi"}' | bash "$HOOK" > /dev/null 2>&1 )
check '[15] unreadable transcript -> allow' "$?" 0

# --- [16] subagent payload -> never blocked ----------------------------------
T="$TMPROOT/agent.jsonl"
assistant_entry $((NOW - 7200)) 200000 600 600 0 > "$T"
CASE_DIR="$TMPROOT/agentcase"; mkdir -p "$CASE_DIR/cache"
( export DHX_COLD_RETURN_CACHE_DIR="$CASE_DIR/cache" DHX_COLD_RETURN_NOW="$NOW"
  printf '{"session_id":"a1","agent_id":"ag-1","transcript_path":"%s","prompt":"hi"}' "$T" \
    | bash "$HOOK" > /dev/null 2>&1 )
check '[16] payload carrying agent_id -> allow' "$?" 0

# --- [17] kill switch --------------------------------------------------------
T="$TMPROOT/kill.jsonl"
assistant_entry $((NOW - 7200)) 200000 600 600 0 > "$T"
run_case killswitch "$T" DHX_COLD_RETURN_DISABLE=1
check '[17] DHX_COLD_RETURN_DISABLE=1 -> allow' "$RC" 0

# --- [18] session_id sanitization: no path escape ----------------------------
T="$TMPROOT/traversal.jsonl"
assistant_entry $((NOW - 7200)) 200000 600 600 0 > "$T"
CASE_DIR="$TMPROOT/traversal"; mkdir -p "$CASE_DIR/cache" "$CASE_DIR/outside"
( export DHX_COLD_RETURN_CACHE_DIR="$CASE_DIR/cache" DHX_COLD_RETURN_NOW="$NOW"
  printf '{"session_id":"../outside/evil","transcript_path":"%s","prompt":"hi"}' "$T" \
    | bash "$HOOK" > /dev/null 2>&1 )
RC=$?
check '[18] traversal session_id still evaluates' "$RC" 2
check '[18] nothing written outside the cache dir' \
  "$(find "$CASE_DIR/outside" -type f | wc -l)" 0
check '[18] stage lands inside the cache dir' \
  "$(find "$CASE_DIR/cache" -name 'cold-return-stage-*' | wc -l)" 1

# --- [19] happy path writes no state at all ----------------------------------
check '[19] allow path leaves no marker/stage behind' \
  "$(find "$TMPROOT/warm/cache" -type f 2>/dev/null | wc -l)" 0

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
