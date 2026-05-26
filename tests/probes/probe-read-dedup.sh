#!/usr/bin/env bash
# probe-read-dedup.sh — verify dhx-read-dedup.sh content-dedup re-read MEASUREMENT (Phase 1, log-only).
#
# Backs the 2026-05-25 decisions.md BUILD row (read-once restoration, brief option 2).
# dhx-read-dedup.sh is a PreToolUse:Read hook that records every Read's line-range per
# session, detects overlapping re-reads of UNCHANGED files, classifies them into the
# cross-repo spike's bands, and logs one event per re-read to a durable stats file.
# It is LOG-ONLY: emits nothing to Claude (zero context cost + no observer effect on the
# very re-read behavior it measures). See the hook header + the measurement doc.
#
#   STATE: <cache>/read-dedup/<session_id>.jsonl   {"path","start","end","mtime","size","ts"}
#   STATS: <cache>/read-dedup-stats.jsonl          {ts,path,session,event,range,overlap_lines,overlap_tokens,band}
#   event ∈ strict | broad | new | changed ;  band ∈ strict | broad | none
#
# Asserts:
#   V-LOG-ONLY       every invocation: empty stdout, exit 0 (no advisory, never blocks)
#   V-FIRST-NOOP     first read of a path → NO stats event (not a re-read)
#   V-STRICT         full→full unchanged re-read → event=strict, range=[1,2001],
#                    overlap_lines clamped to file length, overlap_tokens ≈ size/4 (spike basis)
#   V-BROAD          overlapping partial re-read of unchanged file → event=broad
#   V-NEW            re-read of a NON-overlapping region → event=new, overlap 0 (new content)
#   V-CHANGED        re-read after content change → event=changed (legitimate, not waste)
#   V-TTL-WINDOW     prior read older than TTL → not counted (compaction/scroll-out proxy)
#   V-SANITIZE       empty / path-separator / `..` session_id → exit 0, no file written (D-11)
#   V-STATE-RECORDED every processed read appends a state record (so future reads detect overlap)
#   V-REALPATH       a symlinked read path is recorded symlink-resolved (IN-02)
#
# INVARIANT: token magnitude uses the spike's flat chars/4 proxy (overlap bytes ÷ 4) so the
# live bands are directly comparable to docs/research .../2026-05-24-read-once-token-waste-
# measurement.md. A "full read" models [1,2001) but overlap is clamped to actual file lines.
#
# Run directly: bash tests/probes/probe-read-dedup.sh
# Exit 0 = all pass. Nonzero = at least one [FAIL].
#
# SAFE_FOR_LIVE: yes   (mktemp cache via DHX_READ_DEDUP_STATE_DIR; all writes contained in $SBX)
set -uo pipefail

HOOK="/home/dhx/repos/hooks/dhx/dhx-read-dedup.sh"
SBX=$(mktemp -d)
trap 'rm -rf "$SBX"' EXIT
export DHX_READ_DEDUP_STATE_DIR="$SBX/cache"
STATS="$SBX/cache/read-dedup-stats.jsonl"

PASS=0; FAIL=0
ok()   { echo "OK   $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL $1"; FAIL=$((FAIL+1)); }
chk()  { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1 — expected [$3] got [$2]"; fi; }

SID="probe-sid"
# NB: ${2-$SID} (no colon) so an explicitly-empty 2nd arg stays empty (tests empty session_id);
# only an UNSET 2nd arg falls back to the default $SID.
mk()   { printf '{"tool_name":"Read","session_id":"%s","tool_input":{"file_path":"%s"%s}}' "${2-$SID}" "$1" "${3:-}"; }
last() { tail -1 "$STATS" 2>/dev/null; }
field(){ last | jq -r "$1" 2>/dev/null; }

# Fixture file: 300 lines.
TF="$SBX/sample.md"; printf 'line%s\n' $(seq 1 300) > "$TF"
SIZE=$(stat -c %s "$TF"); LINES=$(wc -l < "$TF")
EXP_TOK=$(python3 -c "print(int(round($LINES*($SIZE/$LINES)/4)))")

# --- V-LOG-ONLY + V-FIRST-NOOP: first full read ---
OUT=$(mk "$TF" | bash "$HOOK"); RC=$?
chk "V-LOG-ONLY stdout-empty (1st read)" "${OUT:-<empty>}" "<empty>"
chk "V-LOG-ONLY exit-0 (1st read)" "$RC" "0"
N1=$(wc -l < "$STATS" 2>/dev/null || echo 0)
chk "V-FIRST-NOOP no stats event on first read" "${N1:-0}" "0"
chk "V-STATE-RECORDED state file has 1 record" "$(wc -l < "$SBX/cache/read-dedup/$SID.jsonl" 2>/dev/null || echo 0)" "1"

# --- V-STRICT: second full read, unchanged ---
OUT=$(mk "$TF" | bash "$HOOK")
chk "V-LOG-ONLY stdout-empty (re-read)" "${OUT:-<empty>}" "<empty>"
chk "V-STRICT event"   "$(field '.event')" "strict"
chk "V-STRICT band"    "$(field '.band')"  "strict"
chk "V-STRICT range"   "$(field '.range|@csv')" "1,2001"
chk "V-STRICT overlap_lines clamped to file" "$(field '.overlap_lines')" "$LINES"
chk "V-STRICT overlap_tokens ≈ size/4 (spike basis)" "$(field '.overlap_tokens')" "$EXP_TOK"

# --- V-BROAD: overlapping partial re-read [10,30) ⊂ prior full (same session) ---
mk "$TF" "$SID" ',"offset":10,"limit":20' | bash "$HOOK"
chk "V-BROAD event" "$(field '.event')" "broad"
chk "V-BROAD overlap_lines" "$(field '.overlap_lines')" "20"

# --- V-NEW: re-read of a region never seen [3000,3050) (no overlap with [1,2001)) ---
mk "$TF" "$SID" ',"offset":3000,"limit":50' | bash "$HOOK"
chk "V-NEW event" "$(field '.event')" "new"
chk "V-NEW overlap" "$(field '.overlap_lines')" "0"

# --- V-CHANGED: mutate the file, then full read ---
sleep 1; printf 'CHANGED%s\n' $(seq 1 400) > "$TF"
mk "$TF" | bash "$HOOK"
chk "V-CHANGED event" "$(field '.event')" "changed"

# --- V-TTL-WINDOW: prior read older than TTL → not waste ---
SBX_T="$SBX/ttl"; mkdir -p "$SBX_T/cache/read-dedup"
TF2="$SBX/aged.md"; printf 'x%s\n' $(seq 1 100) > "$TF2"
MT=$(stat -c %Y "$TF2"); SZ=$(stat -c %s "$TF2"); OLD=$(( $(date +%s) - 5000 ))
printf '{"path":"%s","start":1,"end":2001,"mtime":"%s","size":"%s","ts":%s}\n' "$TF2" "$MT" "$SZ" "$OLD" \
  > "$SBX_T/cache/read-dedup/sidttl.jsonl"
DHX_READ_DEDUP_STATE_DIR="$SBX_T/cache" mk "$TF2" "sidttl" | DHX_READ_DEDUP_STATE_DIR="$SBX_T/cache" bash "$HOOK"
chk "V-TTL-WINDOW aged-out prior → no event" "$(wc -l < "$SBX_T/cache/read-dedup-stats.jsonl" 2>/dev/null || echo 0)" "0"

# --- V-SANITIZE: unsafe session_ids write nothing, exit 0 ---
SBX_S="$SBX/san"; export_save="$DHX_READ_DEDUP_STATE_DIR"
for bad_sid in "" "a/b" ".." "x/../y"; do
  rm -rf "$SBX_S"; mkdir -p "$SBX_S/cache"
  OUT=$(DHX_READ_DEDUP_STATE_DIR="$SBX_S/cache" mk "$TF" "$bad_sid" | DHX_READ_DEDUP_STATE_DIR="$SBX_S/cache" bash "$HOOK"); RC=$?
  WROTE=$(find "$SBX_S/cache/read-dedup" -type f 2>/dev/null | wc -l)
  if [ "$RC" = "0" ] && [ "${OUT:-}" = "" ] && [ "$WROTE" = "0" ]; then
    ok "V-SANITIZE rejected unsafe session_id [${bad_sid:-<empty>}]"
  else
    bad "V-SANITIZE leaked on [${bad_sid:-<empty>}] (rc=$RC out=[$OUT] files=$WROTE)"
  fi
done
export DHX_READ_DEDUP_STATE_DIR="$export_save"

# --- V-REALPATH: symlinked read path recorded resolved ---
SBX_R="$SBX/rp"; mkdir -p "$SBX_R/cache"
LN="$SBX/link.md"; ln -sf "$TF" "$LN"; RP=$(realpath "$LN")
DHX_READ_DEDUP_STATE_DIR="$SBX_R/cache" mk "$LN" "siderp" | DHX_READ_DEDUP_STATE_DIR="$SBX_R/cache" bash "$HOOK"
REC_PATH=$(tail -1 "$SBX_R/cache/read-dedup/siderp.jsonl" 2>/dev/null | jq -r '.path' 2>/dev/null)
chk "V-REALPATH path symlink-resolved" "$REC_PATH" "$RP"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
