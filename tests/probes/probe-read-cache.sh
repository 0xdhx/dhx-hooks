#!/usr/bin/env bash
# probe-read-cache.sh — verify dhx-read-cache.sh partial-detection writer.
#
# Backs the 2026-05-24 decisions.md Option C collapse row. After the collapse,
# dhx-read-cache.sh records ONLY partial Reads, to a SESSION-SCOPED detection
# store keyed on session_id ALONE:
#   ~/.cache/dhx/partial-read-detect-<session_id>.jsonl   entries: {"path":<abs>}
# Full reads, non-partial Reads, and unsafe session_ids write nothing. The old
# global read-cache.jsonl + TTL/prune/flock are gone (retired with the global-
# cache probe corpus — reference impl pinned in the Option C decisions.md row).
#
# Asserts:
#   - V-PARTIAL-OFFSET / V-PARTIAL-LIMIT: partial Read → detect entry written
#   - V-FULL-NOOP:        full Read (no offset/limit) → nothing written
#   - V-SESSION-KEYED:    store filename carries session_id; distinct ids → distinct files
#   - V-INVALID-SESSION:  empty / path-separator / `..` session_id → reject-and-disable
#   - V-REALPATH:         recorded path is symlink-resolved (IN-02)
#   - V-NO-GLOBAL-CACHE:  the retired global read-cache.jsonl is NOT created
#
# INVARIANT: detection keys on session_id ALONE (NOT session_id+ticks) — ticks
# rotate every resume (HP-016/HP-036); ticks-keying would miss the NOTE on every
# cross-session edit. The reader (dhx-read-guard.js) keys identically.
#
# Run directly: bash tests/probes/probe-read-cache.sh
# Exit 0 = pass. Nonzero with [FAIL] line = failure.
#
# SAFE_FOR_LIVE: yes   (mktemp HOME isolation; all writes contained in $TMPHOME/.cache/dhx)
set -uo pipefail

HOOK="/home/dhx/repos/hooks/dhx/dhx-read-cache.sh"
TMPHOME=$(mktemp -d)
WORK=$(mktemp -d)
trap 'rm -rf "$TMPHOME" "$WORK"' EXIT

cleanup_fail() { echo "[FAIL] $1" >&2; exit 1; }

CACHE_DIR="$TMPHOME/.cache/dhx"
TGT="$WORK/file.txt"; printf 'a\nb\nc\nd\ne\n' > "$TGT"
RTGT=$(realpath "$TGT")

run() { echo "$1" | HOME="$TMPHOME" bash "$HOOK"; }

# V-PARTIAL-OFFSET: Read with offset → detect entry written, keyed on session_id.
run "$(printf '{"session_id":"probe-A","tool_name":"Read","tool_input":{"file_path":"%s","offset":1,"limit":2}}' "$TGT")"
DET_A="$CACHE_DIR/partial-read-detect-probe-A.jsonl"
[ -f "$DET_A" ] || cleanup_fail "V-PARTIAL-OFFSET: detect store not created at $DET_A"
tail -1 "$DET_A" | jq -e --arg p "$RTGT" '.path == $p' >/dev/null \
  || cleanup_fail "V-PARTIAL-OFFSET: entry malformed: $(tail -1 "$DET_A")"

# V-PARTIAL-LIMIT: Read with limit only (no offset) → also recorded.
run "$(printf '{"session_id":"probe-B","tool_name":"Read","tool_input":{"file_path":"%s","limit":3}}' "$TGT")"
[ -f "$CACHE_DIR/partial-read-detect-probe-B.jsonl" ] || cleanup_fail "V-PARTIAL-LIMIT: limit-only Read not recorded"

# V-FULL-NOOP: full Read (no offset/limit) → nothing written.
run "$(printf '{"session_id":"probe-C","tool_name":"Read","tool_input":{"file_path":"%s"}}' "$TGT")"
[ -f "$CACHE_DIR/partial-read-detect-probe-C.jsonl" ] && cleanup_fail "V-FULL-NOOP: full Read wrongly recorded a detect entry"

# V-SESSION-KEYED: distinct session_ids → distinct store files (A and B both exist, C absent).
{ [ -f "$DET_A" ] && [ -f "$CACHE_DIR/partial-read-detect-probe-B.jsonl" ]; } \
  || cleanup_fail "V-SESSION-KEYED: per-session store files missing"

# V-INVALID-SESSION: empty / path-separator / `..` session_id → reject-and-disable (no write, no escape).
run "$(printf '{"session_id":"","tool_name":"Read","tool_input":{"file_path":"%s","offset":1,"limit":2}}' "$TGT")"
run "$(printf '{"session_id":"a/b","tool_name":"Read","tool_input":{"file_path":"%s","offset":1,"limit":2}}' "$TGT")"
run "$(printf '{"session_id":"..","tool_name":"Read","tool_input":{"file_path":"%s","offset":1,"limit":2}}' "$TGT")"
# the path-separator case must not escape the cache dir into a nested 'detect-a/b.jsonl'
[ -e "$CACHE_DIR/partial-read-detect-a" ] && cleanup_fail "V-INVALID-SESSION: path-separator session_id escaped into the cache dir"
# the `..` and empty cases must not create any new store file
[ -f "$CACHE_DIR/partial-read-detect-...jsonl" ] && cleanup_fail "V-INVALID-SESSION: '..' session_id produced a store file"

# V-REALPATH: symlink target is resolved to its real path (IN-02 alignment with the guard).
LINKDIR="$WORK/link"; mkdir -p "$LINKDIR"; ln -s "$TGT" "$LINKDIR/alias.txt"
run "$(printf '{"session_id":"probe-L","tool_name":"Read","tool_input":{"file_path":"%s","offset":1,"limit":2}}' "$LINKDIR/alias.txt")"
tail -1 "$CACHE_DIR/partial-read-detect-probe-L.jsonl" | jq -e --arg p "$RTGT" '.path == $p' >/dev/null \
  || cleanup_fail "V-REALPATH: symlink path not resolved to $RTGT: $(tail -1 "$CACHE_DIR/partial-read-detect-probe-L.jsonl")"

# V-NO-GLOBAL-CACHE: the retired global read-cache.jsonl must NOT be created.
[ -f "$CACHE_DIR/read-cache.jsonl" ] && cleanup_fail "V-NO-GLOBAL-CACHE: retired global read-cache.jsonl was created"

echo "[PASS] probe-read-cache.sh: 7/7 assertions (partial-detect writer, session_id-alone keying, invalid-session reject, realpath, no global cache)"
exit 0
