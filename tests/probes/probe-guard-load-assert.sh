#!/usr/bin/env bash
# probe-guard-load-assert.sh — dhx/dhx-guard-load-assert.sh (cross-channel plugin-load assertion)
#
# The hook warns ONCE per session when the dhx plugin's SessionStart dispatcher left no beat
# record, which means the manifest channel did not load and every dhx PreToolUse guard is
# absent from the running process. It is registered in settings.json, NOT in the plugin
# manifest, because a hook cannot report that its own channel failed to load.
#
# THE THREE STATES THIS PINS are disk-identical and only one of them may warn:
#   [1]-[2]  loaded            -> beat present -> SILENT
#   [3]-[6]  registry rejected -> beat absent  -> WARN, naming the absent guards
#   [7]      manifest edited mid-session -> beat PRESENT -> SILENT
# [7] is the arm that keeps this hook alive. HP-020: manifest registration does not
# hot-reload, so every hook-development session in this repo edits a manifest whose new
# entries legitimately are not running. A check keyed on manifest freshness rather than on
# the beat would fire on all of them and be switched off inside a day.
#
# [12] pins the STATED LIMIT in the emitted text: the beat proves the CHANNEL loaded, not
# that CC routes PreToolUse to each guard. That caveat is load-bearing (an external reviewer
# raised it on 2026-09-20) and a future edit must not quietly upgrade the claim, so it is a
# contract tooth rather than a comment.
#
# Run: bash tests/probes/probe-guard-load-assert.sh
#
# SAFE_FOR_LIVE: yes   (every seam is redirected into mktemp trees — DHX_HOOKS_CACHE_DIR
#                       for the beat + first-sight marker, DHX_PLUGIN_MANIFEST for the
#                       guard enumeration; synthetic stdin; no reads or writes under
#                       ~/.cache/dhx, ~/.ccs, ~/.claude or the live repo; no network.)

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$REPO/dhx/dhx-guard-load-assert.sh"

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

_fire() { # $1 cache root ; echoes stdout, stderr captured to $TMP/err
  DHX_HOOKS_CACHE_DIR="$1" DHX_PLUGIN_MANIFEST="$MANIFEST" \
    bash "$HOOK" <<<"$STDIN_JSON" 2>"$TMP/err"
}

# --- [1]-[2] loaded: a beat exists -> silent ---
LOADED="$TMP/loaded"; mkdir -p "$LOADED/session-start/$KEY"
echo '{"schema_version":2,"leg":"session-start"}' > "$LOADED/session-start/$KEY/ev.1.2.3.json"
OUT=$(_fire "$LOADED")
_assert "[1] beat present (dispatcher-derived key) -> silent" "" "$OUT"
_assert "[2] beat present -> nothing on stderr either" "" "$(cat "$TMP/err")"

# --- [3]-[6] registry rejected: no beat -> one warning, naming the absent guards ---
ABSENT="$TMP/absent"; mkdir -p "$ABSENT"
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
# The beat proves the CHANNEL loaded; it cannot prove CC routes PreToolUse to each guard.
# Overstating that is how a necessary-but-not-sufficient signal gets treated as sufficient
# and retires the behavioural check that actually covers routing.
LIM="$TMP/lim"; mkdir -p "$LIM"
CTX2=$(_fire "$LIM" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
_assert "[12] emitted text states it does not cover per-guard tool routing" "yes" \
  "$(grep -qi 'routing' <<<"$CTX2" && echo yes || echo no)"

# --- [13] manifest unreadable + no beat -> still warns, and says why it cannot enumerate ---
BAD="$TMP/bad"; mkdir -p "$BAD"
CTX3=$(DHX_HOOKS_CACHE_DIR="$BAD" DHX_PLUGIN_MANIFEST="$TMP/does-not-exist.json" \
         bash "$HOOK" <<<"$STDIN_JSON" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // ""')
_assert "[13] unreadable manifest -> warns anyway, treating ALL guards as absent" "yes" \
  "$(grep -q 'cannot enumerate' <<<"$CTX3" && echo yes || echo no)"

# --- [14] the hook never writes outside the cache root it was given ---
_assert "[14] no stray writes at the cache root's parent" "0" \
  "$(find "$TMP" -maxdepth 1 -newer "$MANIFEST" -name 'guard-load-assert' 2>/dev/null | wc -l)"

echo "---"
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
