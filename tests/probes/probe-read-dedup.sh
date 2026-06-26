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
#   STATE: <cache>/read-dedup/<session_id>.jsonl   {"path","start","end","mtime","size","ts","seq"[,"lines"]}  (ephemeral — reapable)
#   STATS: <data>/read-dedup-stats.jsonl           {ts,path,session,event,range,overlap_lines,overlap_tokens,band,
#          gap_s,gap_reads,compaction_since_prior[,full_tokens,diff_tokens,prior_full,prior_snapshot_available]}
#          (durable — XDG_DATA_HOME, NOT the cache dir; relocated 2026-06-09, see decisions.md)
#   event ∈ strict | broad | new | changed ;  band ∈ strict | broad | none
#   Phase-2a (2026-06-25 council telemetry): gap_s/gap_reads/compaction_since_prior on every event;
#     the changed-only quad (full_tokens/diff_tokens/prior_full/prior_snapshot_available) sizes the
#     diff-substitute guard. Companion: dhx-read-dedup-compact-marker.sh (PreCompact) writes the markers.
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
#   V-DURABLE-SPLIT  STATS lands in the durable data root (NOT the cache root) and SURVIVES a
#                    wipe of the cache dir — the invariant the 2026-06-09 relocation protects
#   V-LINECACHE-WRITE a re-read caches the file's line count into the state record (counted once
#                    per (session,version)); the first read carries no `lines` field
#   V-LINECACHE-HIT  a cached `lines` on a same-version prior is REUSED, not recounted — a
#                    poisoned sentinel surfaces in overlap clamping, proving the cache path
#   V-STATS-ROTATE   the durable stats log over DHX_READ_DEDUP_STATS_MAX_BYTES rotates to a
#                    single `.jsonl.1` backup during housekeeping; the current log resets
#   --- Phase-2a telemetry (2026-06-25 council; sizes the two substitutive guards) ---
#   V-SEQ-RECORD     each state record carries a 1-based session ordinal `seq`
#   V-GAP-S/READS    a re-read event carries gap_s (≥0) + gap_reads (cur_seq − prior_seq) + compaction_since_prior
#   V-CHANGED-SIZING a changed re-read with a cached prior snapshot logs full_tokens>0, real diff_tokens
#                    (< full_tokens — the substitute win), prior_full, prior_snapshot_available; overlap_tokens stays 0
#   V-CHANGED-NOSNAP a changed re-read over the snapshot cap → prior_snapshot_available:false, diff_tokens:-1
#                    (unsized), full_tokens still sized; no snapshot file written
#   V-COMPACT-MARKER the PreCompact companion writes {ts,trigger}; defaults absent trigger→"unknown";
#                    sanitizes empty/path-sep/`..` session_id (D-11); log-only (empty stdout, exit 0)
#   V-COMPACT-SINCE  a marker with ts in (prior_read_ts, now] → compaction_since_prior:true; a marker
#                    predating the prior read → false (the cross-process INVARIANT between the two hooks)
#
# INVARIANT: token magnitude uses the spike's flat chars/4 proxy (overlap bytes ÷ 4) so the
# live bands are directly comparable to docs/research .../2026-05-24-read-once-token-waste-
# measurement.md. A "full read" models [1,2001) but overlap is clamped to actual file lines.
#
# Run directly: bash tests/probes/probe-read-dedup.sh
# Exit 0 = all pass. Nonzero = at least one [FAIL].
#
# SAFE_FOR_LIVE: yes   (mktemp cache+data via DHX_READ_DEDUP_STATE_DIR + DHX_READ_DEDUP_DATA_DIR;
#                       all writes contained in $SBX — both roots are mktemp subdirs)
set -uo pipefail

HOOK="/home/dhx/repos/hooks/dhx/dhx-read-dedup.sh"
SBX=$(mktemp -d)
trap 'rm -rf "$SBX"' EXIT
# Split roots (2026-06-09 relocation): STATE stays in the cache root, STATS moves to the data
# root. Sibling subdirs under one mktemp $SBX so assertions can PROVE the separation.
export DHX_READ_DEDUP_STATE_DIR="$SBX/cache"
export DHX_READ_DEDUP_DATA_DIR="$SBX/data"
STATS="$SBX/data/read-dedup-stats.jsonl"

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
DHX_READ_DEDUP_STATE_DIR="$SBX_T/cache" mk "$TF2" "sidttl" | DHX_READ_DEDUP_STATE_DIR="$SBX_T/cache" DHX_READ_DEDUP_DATA_DIR="$SBX_T/data" bash "$HOOK"
chk "V-TTL-WINDOW aged-out prior → no event" "$(wc -l < "$SBX_T/data/read-dedup-stats.jsonl" 2>/dev/null || echo 0)" "0"

# --- V-SANITIZE: unsafe session_ids write nothing, exit 0 ---
SBX_S="$SBX/san"; export_save="$DHX_READ_DEDUP_STATE_DIR"
for bad_sid in "" "a/b" ".." "x/../y"; do
  rm -rf "$SBX_S"; mkdir -p "$SBX_S/cache"
  OUT=$(DHX_READ_DEDUP_STATE_DIR="$SBX_S/cache" mk "$TF" "$bad_sid" | DHX_READ_DEDUP_STATE_DIR="$SBX_S/cache" DHX_READ_DEDUP_DATA_DIR="$SBX_S/data" bash "$HOOK"); RC=$?
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
DHX_READ_DEDUP_STATE_DIR="$SBX_R/cache" mk "$LN" "siderp" | DHX_READ_DEDUP_STATE_DIR="$SBX_R/cache" DHX_READ_DEDUP_DATA_DIR="$SBX_R/data" bash "$HOOK"
REC_PATH=$(tail -1 "$SBX_R/cache/read-dedup/siderp.jsonl" 2>/dev/null | jq -r '.path' 2>/dev/null)
chk "V-REALPATH path symlink-resolved" "$REC_PATH" "$RP"

# --- V-EOF-CLAMP (drain MED-1): a partial read crossing EOF counts only real lines ---
# [250,450) on a 300-line file overlaps a prior full read only on real lines 250..300 = 51,
# NOT the raw interval 200. Guards the pre-fix overcount that inflated the BROAD band.
SBX_E="$SBX/eof"; mkdir -p "$SBX_E/cache"
TFE="$SBX/eof.md"; printf 'e%s\n' $(seq 1 300) > "$TFE"
runE(){ DHX_READ_DEDUP_STATE_DIR="$SBX_E/cache" DHX_READ_DEDUP_DATA_DIR="$SBX_E/data" bash "$HOOK"; }
printf '{"tool_name":"Read","session_id":"sideof","tool_input":{"file_path":"%s"}}' "$TFE" | runE
printf '{"tool_name":"Read","session_id":"sideof","tool_input":{"file_path":"%s","offset":250,"limit":200}}' "$TFE" | runE
EOF_EV=$(tail -1 "$SBX_E/data/read-dedup-stats.jsonl" 2>/dev/null)
chk "V-EOF-CLAMP event" "$(echo "$EOF_EV" | jq -r '.event')" "broad"
chk "V-EOF-CLAMP overlap clamped to real lines (51, not raw 200)" "$(echo "$EOF_EV" | jq -r '.overlap_lines')" "51"

# --- V-DURABLE-SPLIT (2026-06-09 relocation): STATS lives in the durable data root and survives
# a wipe of the cache dir. This is the whole point of the relocation — a reap of the cache dir
# (skills probe-dhx-sym-parity.sh's unconditional rm -rf, XDG cleanupPeriodDays sweeps) must NOT
# take the durable measurement dataset with it.
SBX_D="$SBX/durable"
TFD="$SBX/durable.md"; printf 'd%s\n' $(seq 1 120) > "$TFD"
runD(){ DHX_READ_DEDUP_STATE_DIR="$SBX_D/cache" DHX_READ_DEDUP_DATA_DIR="$SBX_D/data" bash "$HOOK"; }
mkD()  { printf '{"tool_name":"Read","session_id":"sidd","tool_input":{"file_path":"%s"}}' "$TFD"; }
mkD | runD                         # 1st read → STATE only, no event
mkD | runD                         # full re-read of unchanged file → STATS event in the DATA root
chk "V-DURABLE-SPLIT STATS in data root, not cache root" \
    "$([ -s "$SBX_D/data/read-dedup-stats.jsonl" ] && [ ! -e "$SBX_D/cache/read-dedup-stats.jsonl" ] && echo yes || echo no)" "yes"
rm -rf "$SBX_D/cache"              # simulate the skills probe's unconditional cache wipe
chk "V-DURABLE-SPLIT STATS survives a cache-dir wipe" \
    "$([ -s "$SBX_D/data/read-dedup-stats.jsonl" ] && echo survived || echo gone)" "survived"

# --- V-LINECACHE-WRITE: a re-read caches the file's line count into the state record ---
SBX_LC="$SBX/linecache"; mkdir -p "$SBX_LC/cache"
TFL="$SBX/lc.md"; printf 'l%s\n' $(seq 1 250) > "$TFL"
LC_LINES=$(wc -l < "$TFL")
runLC(){ DHX_READ_DEDUP_STATE_DIR="$SBX_LC/cache" DHX_READ_DEDUP_DATA_DIR="$SBX_LC/data" bash "$HOOK"; }
mkLC(){ printf '{"tool_name":"Read","session_id":"sidlc","tool_input":{"file_path":"%s"}}' "$TFL"; }
mkLC | runLC                       # 1st read → state record, NO lines field
mkLC | runLC                       # re-read → computes + caches lines
LC_STATE="$SBX_LC/cache/read-dedup/sidlc.jsonl"
chk "V-LINECACHE-WRITE first-read record carries no lines" \
    "$(sed -n '1p' "$LC_STATE" 2>/dev/null | jq -r '.lines // "none"')" "none"
chk "V-LINECACHE-WRITE re-read record caches real line count" \
    "$(tail -1 "$LC_STATE" 2>/dev/null | jq -r '.lines')" "$LC_LINES"

# --- V-LINECACHE-HIT: a cached `lines` on a same-version prior is REUSED, not recounted ---
# Poison a prior record with a deliberately wrong count (999 on a 300-line file) at the file's
# real mtime/size; a full re-read must clamp overlap to the CACHED 999, not recount the real 300.
# (overlap_lines surfacing 999 can ONLY happen if the cache was consulted — teeth for the reuse.)
SBX_HIT="$SBX/lchit"; mkdir -p "$SBX_HIT/cache/read-dedup"
TFH="$SBX/lchit.md"; printf 'h%s\n' $(seq 1 300) > "$TFH"
HMT=$(stat -c %Y "$TFH"); HSZ=$(stat -c %s "$TFH"); HNOW=$(date +%s)
printf '{"path":"%s","start":1,"end":2001,"mtime":"%s","size":"%s","ts":%s,"lines":999}\n' \
    "$TFH" "$HMT" "$HSZ" "$HNOW" > "$SBX_HIT/cache/read-dedup/sidhit.jsonl"
printf '{"tool_name":"Read","session_id":"sidhit","tool_input":{"file_path":"%s"}}' "$TFH" \
  | DHX_READ_DEDUP_STATE_DIR="$SBX_HIT/cache" DHX_READ_DEDUP_DATA_DIR="$SBX_HIT/data" bash "$HOOK"
HIT_EV=$(tail -1 "$SBX_HIT/data/read-dedup-stats.jsonl" 2>/dev/null)
chk "V-LINECACHE-HIT overlap uses cached 999, not recounted 300" \
    "$(echo "$HIT_EV" | jq -r '.overlap_lines')" "999"

# --- V-STATS-ROTATE: durable stats log over the size cap rotates to a single .1 backup ---
SBX_RO="$SBX/rotate"; mkdir -p "$SBX_RO/cache/read-dedup"
TFRO="$SBX/ro.md"; printf 'r%s\n' $(seq 1 100) > "$TFRO"
runRO(){ DHX_READ_DEDUP_STATE_DIR="$SBX_RO/cache" DHX_READ_DEDUP_DATA_DIR="$SBX_RO/data" \
         DHX_READ_DEDUP_STATS_MAX_BYTES=50 bash "$HOOK"; }
mkRO(){ printf '{"tool_name":"Read","session_id":"sidro","tool_input":{"file_path":"%s"}}' "$TFRO"; }
mkRO | runRO                       # 1st read (state only; housekeeping writes the marker)
mkRO | runRO                       # re-read → strict event (~130 B > the 50-B cap)
rm -f "$SBX_RO/cache/read-dedup/.last-cleanup"   # force housekeeping to re-run next read
mkRO | runRO                       # housekeeping sees STATS > cap → rotate to .1, then append fresh
chk "V-STATS-ROTATE .1 backup created when stats exceed cap" \
    "$([ -s "$SBX_RO/data/read-dedup-stats.jsonl.1" ] && echo yes || echo no)" "yes"
chk "V-STATS-ROTATE current log reset to a fresh post-rotation event" \
    "$(wc -l < "$SBX_RO/data/read-dedup-stats.jsonl" 2>/dev/null || echo 0)" "1"

# ============================ Phase-2a telemetry (2026-06-25 council) ============================

# --- V-SEQ-RECORD + V-GAP-S/READS: state records carry seq; re-read events carry the gap fields ---
SBX_SQ="$SBX/seq"; mkdir -p "$SBX_SQ/cache"
TFS="$SBX/seq.md"; printf 's%s\n' $(seq 1 150) > "$TFS"
runSQ(){ DHX_READ_DEDUP_STATE_DIR="$SBX_SQ/cache" DHX_READ_DEDUP_DATA_DIR="$SBX_SQ/data" bash "$HOOK"; }
mkSQ(){ printf '{"tool_name":"Read","session_id":"sidsq","tool_input":{"file_path":"%s"}}' "$TFS"; }
mkSQ | runSQ; sleep 1; mkSQ | runSQ      # read 1 (seq 1, no event) → read 2 (seq 2, strict event)
SQ_STATE="$SBX_SQ/cache/read-dedup/sidsq.jsonl"
chk "V-SEQ-RECORD first record seq=1"  "$(sed -n '1p' "$SQ_STATE" 2>/dev/null | jq -r '.seq')" "1"
chk "V-SEQ-RECORD second record seq=2" "$(sed -n '2p' "$SQ_STATE" 2>/dev/null | jq -r '.seq')" "2"
SQ_EV=$(tail -1 "$SBX_SQ/data/read-dedup-stats.jsonl" 2>/dev/null)
chk "V-GAP-S present on strict event (≥0)" \
    "$(echo "$SQ_EV" | jq -r 'if (.gap_s != null and .gap_s >= 0) then "yes" else "no" end')" "yes"
chk "V-GAP-READS strict re-read gap_reads=1" "$(echo "$SQ_EV" | jq -r '.gap_reads')" "1"
chk "V-GAP compaction_since_prior false (no marker)" "$(echo "$SQ_EV" | jq -r '.compaction_since_prior')" "false"

# --- V-CHANGED-SIZING: changed re-read with a cached prior snapshot → full + real diff sized ---
SBX_CS="$SBX/chsize"; mkdir -p "$SBX_CS/cache"
TFC="$SBX/chsize.md"; printf 'orig%s\n' $(seq 1 200) > "$TFC"
runCS(){ DHX_READ_DEDUP_STATE_DIR="$SBX_CS/cache" DHX_READ_DEDUP_DATA_DIR="$SBX_CS/data" bash "$HOOK"; }
mkCS(){ printf '{"tool_name":"Read","session_id":"sidcs","tool_input":{"file_path":"%s"}}' "$TFC"; }
mkCS | runCS                              # full read v1 → snapshot cached
sleep 1; printf 'orig%s\n' $(seq 1 205) > "$TFC"   # +5 lines → small diff vs full
mkCS | runCS                              # changed re-read → sized
CS_EV=$(tail -1 "$SBX_CS/data/read-dedup-stats.jsonl" 2>/dev/null)
chk "V-CHANGED-SIZING event"                       "$(echo "$CS_EV" | jq -r '.event')" "changed"
chk "V-CHANGED-SIZING full_tokens > 0"             "$(echo "$CS_EV" | jq -r 'if .full_tokens > 0 then "yes" else "no" end')" "yes"
chk "V-CHANGED-SIZING prior_snapshot_available"    "$(echo "$CS_EV" | jq -r '.prior_snapshot_available')" "true"
chk "V-CHANGED-SIZING prior_full"                  "$(echo "$CS_EV" | jq -r '.prior_full')" "true"
chk "V-CHANGED-SIZING diff_tokens sized & < full (the substitute win)" \
    "$(echo "$CS_EV" | jq -r 'if (.diff_tokens >= 0 and .diff_tokens < .full_tokens) then "yes" else "no" end')" "yes"
chk "V-CHANGED-SIZING overlap_tokens stays 0 (additive: zero UNCHANGED overlap)" \
    "$(echo "$CS_EV" | jq -r '.overlap_tokens')" "0"

# --- V-CHANGED-NOSNAP: changed re-read over the snapshot cap → unsized diff, full still sized ---
SBX_NS="$SBX/nosnap"; mkdir -p "$SBX_NS/cache"
TFN="$SBX/nosnap.md"; printf 'big%s\n' $(seq 1 200) > "$TFN"
runNS(){ DHX_READ_DEDUP_STATE_DIR="$SBX_NS/cache" DHX_READ_DEDUP_DATA_DIR="$SBX_NS/data" \
         DHX_READ_DEDUP_SNAPSHOT_MAX_BYTES=10 bash "$HOOK"; }   # 10 B cap → every file skipped
mkNS(){ printf '{"tool_name":"Read","session_id":"sidns","tool_input":{"file_path":"%s"}}' "$TFN"; }
mkNS | runNS                              # full read v1 → snapshot SKIPPED (over cap)
sleep 1; printf 'big%s\n' $(seq 1 210) > "$TFN"
mkNS | runNS                              # changed re-read → no snapshot to diff
NS_EV=$(tail -1 "$SBX_NS/data/read-dedup-stats.jsonl" 2>/dev/null)
chk "V-CHANGED-NOSNAP prior_snapshot_available false (over cap)" "$(echo "$NS_EV" | jq -r '.prior_snapshot_available')" "false"
chk "V-CHANGED-NOSNAP diff_tokens unsized sentinel -1"           "$(echo "$NS_EV" | jq -r '.diff_tokens')" "-1"
chk "V-CHANGED-NOSNAP full_tokens still sized (>0)"              "$(echo "$NS_EV" | jq -r 'if .full_tokens > 0 then "yes" else "no" end')" "yes"
chk "V-CHANGED-NOSNAP no content snapshot written (over cap)"    "$(find "$SBX_NS/cache/read-dedup/content" -type f 2>/dev/null | wc -l)" "0"

# --- V-COMPACT-MARKER: the PreCompact companion writes {ts,trigger}; defaults + sanitizes ---
MARKER="/home/dhx/repos/hooks/dhx/dhx-read-dedup-compact-marker.sh"
SBX_CM="$SBX/cmark"; mkdir -p "$SBX_CM/cache"
runCM(){ DHX_READ_DEDUP_STATE_DIR="$SBX_CM/cache" bash "$MARKER"; }
OUT=$(printf '{"session_id":"sidcm","trigger":"manual","hook_event_name":"PreCompact"}' | runCM); RC=$?
chk "V-COMPACT-MARKER stdout-empty (log-only)" "${OUT:-<empty>}" "<empty>"
chk "V-COMPACT-MARKER exit-0" "$RC" "0"
CM_FILE="$SBX_CM/cache/read-dedup/compaction/sidcm.jsonl"
chk "V-COMPACT-MARKER trigger recorded" "$(tail -1 "$CM_FILE" 2>/dev/null | jq -r '.trigger')" "manual"
chk "V-COMPACT-MARKER ts numeric"       "$(tail -1 "$CM_FILE" 2>/dev/null | jq -r 'if (.ts|type)=="number" then "yes" else "no" end')" "yes"
printf '{"session_id":"sidcm2"}' | runCM   # absent trigger → "unknown"
chk "V-COMPACT-MARKER absent trigger → unknown" "$(tail -1 "$SBX_CM/cache/read-dedup/compaction/sidcm2.jsonl" 2>/dev/null | jq -r '.trigger')" "unknown"
for bad_sid in "" "a/b" ".."; do
  rm -rf "$SBX_CM/cache/read-dedup/compaction"
  printf '{"session_id":"%s","trigger":"auto"}' "$bad_sid" | runCM
  chk "V-COMPACT-MARKER sanitize [${bad_sid:-<empty>}] writes nothing" \
      "$(find "$SBX_CM/cache/read-dedup/compaction" -type f 2>/dev/null | wc -l)" "0"
done

# --- V-COMPACT-SINCE: the cross-process INVARIANT — marker in (prior_ts, now] flips the flag ---
SBX_CSN="$SBX/csince"; mkdir -p "$SBX_CSN/cache/read-dedup/compaction"
TFCS="$SBX/csince.md"; printf 'c%s\n' $(seq 1 120) > "$TFCS"
runCSN(){ DHX_READ_DEDUP_STATE_DIR="$SBX_CSN/cache" DHX_READ_DEDUP_DATA_DIR="$SBX_CSN/data" bash "$HOOK"; }
mkCSN(){ printf '{"tool_name":"Read","session_id":"sidcsn","tool_input":{"file_path":"%s"}}' "$TFCS"; }
mkCSN | runCSN                            # 1st read at T1
sleep 1; printf '{"ts":%s,"trigger":"auto"}\n' "$(date +%s)" > "$SBX_CSN/cache/read-dedup/compaction/sidcsn.jsonl"  # marker T2
sleep 1; mkCSN | runCSN                   # re-read at T3 → marker T2 ∈ (T1,T3]
CSN_EV=$(tail -1 "$SBX_CSN/data/read-dedup-stats.jsonl" 2>/dev/null)
chk "V-COMPACT-SINCE marker between prior read and now → true" "$(echo "$CSN_EV" | jq -r '.compaction_since_prior')" "true"
# negative teeth: a marker PREDATING the prior read must NOT count
SBX_CN2="$SBX/csince2"; mkdir -p "$SBX_CN2/cache/read-dedup/compaction"
TFC2="$SBX/csince2.md"; printf 'c%s\n' $(seq 1 120) > "$TFC2"
printf '{"ts":%s,"trigger":"manual"}\n' "$(( $(date +%s) - 100 ))" > "$SBX_CN2/cache/read-dedup/compaction/sidcn2.jsonl"
runCN2(){ DHX_READ_DEDUP_STATE_DIR="$SBX_CN2/cache" DHX_READ_DEDUP_DATA_DIR="$SBX_CN2/data" bash "$HOOK"; }
mkCN2(){ printf '{"tool_name":"Read","session_id":"sidcn2","tool_input":{"file_path":"%s"}}' "$TFC2"; }
mkCN2 | runCN2                            # 1st read AFTER the stale marker
sleep 1; mkCN2 | runCN2                   # re-read → stale marker predates prior read → false
CN2_EV=$(tail -1 "$SBX_CN2/data/read-dedup-stats.jsonl" 2>/dev/null)
chk "V-COMPACT-SINCE marker predating prior read → false" "$(echo "$CN2_EV" | jq -r '.compaction_since_prior')" "false"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
