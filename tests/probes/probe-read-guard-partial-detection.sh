#!/usr/bin/env bash
# probe-read-guard-partial-detection.sh — verify the collapsed (partial-only)
# dhx-read-guard.js fires the PARTIAL-READ NOTE off the session-scoped detection
# store, and is SILENT in every other case.
#
# The Option C read-guard collapse removed
# State-1 (strong READ-BEFORE-EDIT advisory) and State-2 (full-read suppress +
# global-TTL cache). The guard now fires the soft PARTIAL-READ NOTE iff the file
# was recorded in ~/.cache/dhx/partial-read-detect-<session_id>.jsonl by
# dhx-read-cache.sh this session, deduped once-per-(session_id, ticks).
#
# Asserts:
#   - V-NOTE-FIRES:        detection present → Edit → PARTIAL-READ NOTE
#   - V-SILENT-NO-DETECT:  NO detection → Edit → SILENT (the old strong advisory is gone)
#   - V-DEDUP:             2nd Edit, same (session_id, live ticks), same file → silent
#   - V-DIFF-FILE-FIRES:   another detected file in the same session → fires
#   - V-SESSION-ALONE:     detection keys on session_id ALONE — an Edit under a
#                          DIFFERENT session_id (no detect store) is silent
#   - V-NEW-FILE-SILENT:   non-existent file → silent (no detection possible)
#   - V-NON-EDIT-SILENT:   a Read tool call → silent (only Write|Edit intercepted)
#   - V-INVALID-SID-SILENT: unsafe session_id (/, .., empty) → silent (reject-and-disable)
#
# INVARIANT (the load-bearing Probe-5/Branch-1 constraint): detection keys on
# session_id ALONE, NOT session_id+ticks. ticks rotate on every resume
# (HP-016/HP-036); ticks-keying would miss the NOTE on every cross-session edit.
# V-SESSION-ALONE guards the keying scheme; a regression that folded ticks into
# the detection filename would flip V-NOTE-FIRES red (the seeded store name no
# longer matches the guard's lookup).
#
# Run directly: bash tests/probes/probe-read-guard-partial-detection.sh
# Exit 0 = pass. Nonzero with [FAIL] line = failure.
#
# SAFE_FOR_LIVE: yes   (mktemp HOME isolation; reads/writes confined to $TMPHOME/.cache/dhx)
set -uo pipefail

GUARD="/home/dhx/repos/hooks/dhx/dhx-read-guard.js"
TMPHOME=$(mktemp -d)
WORK=$(mktemp -d)
trap 'rm -rf "$TMPHOME" "$WORK"' EXIT

cleanup_fail() { echo "[FAIL] $1" >&2; exit 1; }

CACHE_DIR="$TMPHOME/.cache/dhx"; mkdir -p "$CACHE_DIR"
TGT="$WORK/file.txt";  printf 'a\nb\nc\nd\ne\n' > "$TGT";  RTGT=$(realpath "$TGT")
TGT2="$WORK/other.txt"; printf 'x\ny\n' > "$TGT2";          RTGT2=$(realpath "$TGT2")

SID="probe-detect-001"
seed_detect() { # $1 = session_id, $2 = realpath to record
  printf '{"path":"%s"}\n' "$2" >> "$CACHE_DIR/partial-read-detect-$1.jsonl"
}
edit() { # $1 = session_id, $2 = file_path  → emits guard stdout
  printf '{"session_id":"%s","tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$1" "$2" \
    | HOME="$TMPHOME" node "$GUARD"
}
has_note() { jq -e '.hookSpecificOutput.additionalContext | test("PARTIAL-READ NOTE")' >/dev/null 2>&1; }

# V-NOTE-FIRES: detection recorded for (SID, TGT) → first Edit fires the NOTE.
seed_detect "$SID" "$RTGT"
OUT=$(edit "$SID" "$TGT")
echo "$OUT" | has_note || cleanup_fail "V-NOTE-FIRES: detected partial-read did not fire the NOTE (got: '$OUT')"

# V-DEDUP: 2nd Edit, same session_id + same live ticks + same file → silent.
OUT=$(edit "$SID" "$TGT")
[ -z "$OUT" ] || cleanup_fail "V-DEDUP: 2nd same-(session,ticks,file) Edit should be silent (got: '$OUT')"

# V-DIFF-FILE-FIRES: a different detected file in the same session fires (per-file dedup).
seed_detect "$SID" "$RTGT2"
OUT=$(edit "$SID" "$TGT2")
echo "$OUT" | has_note || cleanup_fail "V-DIFF-FILE-FIRES: a different detected file should fire (got: '$OUT')"

# V-SILENT-NO-DETECT: a file with NO detection entry → SILENT (the removed strong advisory).
NODET="$WORK/undetected.txt"; printf 'z\n' > "$NODET"
OUT=$(edit "$SID" "$NODET")
[ -z "$OUT" ] || cleanup_fail "V-SILENT-NO-DETECT: undetected file should be SILENT (no strong advisory), got: '$OUT'"

# V-SESSION-ALONE: a DIFFERENT session_id has no detect store → silent. Proves the
# detection key is the session_id (folding in ticks would also have broken V-NOTE-FIRES).
OUT=$(edit "other-session-999" "$TGT")
[ -z "$OUT" ] || cleanup_fail "V-SESSION-ALONE: edit under a session with no detect store should be silent, got: '$OUT'"

# V-NEW-FILE-SILENT: a non-existent file → silent (guard exits before detection).
OUT=$(edit "$SID" "$WORK/does-not-exist.txt")
[ -z "$OUT" ] || cleanup_fail "V-NEW-FILE-SILENT: non-existent file should be silent, got: '$OUT'"

# V-NON-EDIT-SILENT: a Read tool call (not Write|Edit) → silent even with detection present.
OUT=$(printf '{"session_id":"%s","tool_name":"Read","tool_input":{"file_path":"%s"}}' "$SID" "$TGT" | HOME="$TMPHOME" node "$GUARD")
[ -z "$OUT" ] || cleanup_fail "V-NON-EDIT-SILENT: a Read tool call should be silent, got: '$OUT'"

# V-INVALID-SID-SILENT: unsafe session_id → silent (cannot key the store; reject-and-disable).
for bad in "a/b" ".." ""; do
  OUT=$(edit "$bad" "$TGT")
  [ -z "$OUT" ] || cleanup_fail "V-INVALID-SID-SILENT: unsafe session_id '$bad' should be silent, got: '$OUT'"
done

echo "[PASS] probe-read-guard-partial-detection.sh: 8/8 assertions (NOTE fires on detection, silent otherwise, session_id-alone keying, dedup)"
exit 0
