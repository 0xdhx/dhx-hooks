#!/usr/bin/env bash
# Probe: exercises dhx/dhx-restart-plugins-stop.sh against the
# transcript-shape matrix and the session_id sanitization branch.
# Backs the ⚠ restart plugins / `/restart-plugins` rebaseline pipeline
# (Stop variant — replaces the prior UserPromptSubmit-based probe after
# HP-027 established CLI slash commands bypass UserPromptSubmit).
#
# Scope:
#   1. transcript with /reload-plugins command-name → marker present
#   2. transcript with /restart-plugins command-name → marker present
#   3. transcript with prose mention only (no command-name tag) → no marker
#   4. transcript with assistant-only content mentioning command → no marker
#   5. empty transcript → no marker
#   6. missing transcript_path → no marker
#   7. transcript_path points to nonexistent file → no marker
#   8. path-traversal session_id rejected → no escape outside fake HOME's cache dir
#   9. backslash session_id rejected
#  10. empty session_id rejected
#  11. malformed stdin (non-JSON) → exit 0, no marker (graceful degrade)
#
# Run: bash tests/probes/probe-restart-plugins-stop-hook.sh
#
# Backs:
#   - docs/decisions.md — restart-plugins Stop-trigger swap row
#   - docs/hook-patterns.md — HP-026, HP-027
#   - docs/statusline-wrapper.md — Drift Detection § Marker-driven rebaseline

# SAFE_FOR_LIVE: yes   (mktemp + HOME=$TMP per scenario; transcript fixtures synthesized in $TMP)
set -u

HOOK="/home/dhx/repos/hooks/dhx/dhx-restart-plugins-stop.sh"
TMP=$(mktemp -d /tmp/probe-restart-plugins-stop.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

assert_marker_present() {
  local label="$1" sid="$2"
  local marker="$TMP/.cache/dhx/plugins-rebaseline-${sid}.marker"
  if [ -f "$marker" ]; then
    echo "OK   $label (marker present)"
    PASS=$((PASS + 1))
  else
    echo "FAIL $label (marker absent at $marker)"
    FAIL=$((FAIL + 1))
  fi
}

assert_marker_absent() {
  local label="$1"
  if find "$TMP/.cache/dhx" -name 'plugins-rebaseline-*.marker' -print 2>/dev/null | grep -q .; then
    local found
    found=$(find "$TMP/.cache/dhx" -name 'plugins-rebaseline-*.marker' -print 2>/dev/null)
    echo "FAIL $label (unexpected marker: $found)"
    FAIL=$((FAIL + 1))
  else
    echo "OK   $label (no marker)"
    PASS=$((PASS + 1))
  fi
}

assert_no_path_escape() {
  local label="$1"
  local hit
  hit=$(find "$TMP" -name 'plugins-rebaseline-*' -print 2>/dev/null)
  if [ -n "$hit" ]; then
    echo "FAIL $label (path-escape leaked: $hit)"
    FAIL=$((FAIL + 1))
  else
    echo "OK   $label (no marker written; path-traversal session_id rejected)"
    PASS=$((PASS + 1))
  fi
}

run_hook() {
  local payload="$1"
  HOME="$TMP" bash "$HOOK" <<< "$payload"
}

reset_cache() {
  rm -rf "$TMP/.cache"
  rm -f "$TMP/transcript.jsonl"
}

write_transcript() {
  printf '%s\n' "$1" > "$TMP/transcript.jsonl"
}

# [1] /reload-plugins command-name in transcript → marker present
reset_cache
write_transcript '{"type":"user","message":{"role":"user","content":"<command-name>/reload-plugins</command-name>"}}'
run_hook "{\"transcript_path\":\"$TMP/transcript.jsonl\",\"session_id\":\"sess-rl\"}"
rc=$?
[ $rc -eq 0 ] || { echo "FAIL [1] hook exit=$rc"; FAIL=$((FAIL + 1)); }
assert_marker_present "[1] /reload-plugins command-name fires" "sess-rl"

# [2] /restart-plugins command-name in transcript → marker present
reset_cache
write_transcript '{"type":"user","message":{"role":"user","content":"<command-name>/restart-plugins</command-name>"}}'
run_hook "{\"transcript_path\":\"$TMP/transcript.jsonl\",\"session_id\":\"sess-rs\"}"
assert_marker_present "[2] /restart-plugins command-name fires" "sess-rs"

# [3] prose mention without command-name tag → no marker
reset_cache
write_transcript '{"type":"user","message":{"role":"user","content":"the user wrote /reload-plugins in prose, but it was not a command"}}'
run_hook "{\"transcript_path\":\"$TMP/transcript.jsonl\",\"session_id\":\"sess-prose\"}"
assert_marker_absent "[3] prose mention without tag does not fire"

# [4] assistant content mentioning command (no user command-name) → no marker
reset_cache
write_transcript '{"type":"assistant","message":{"role":"assistant","content":"please run /reload-plugins"}}'
run_hook "{\"transcript_path\":\"$TMP/transcript.jsonl\",\"session_id\":\"sess-asst\"}"
assert_marker_absent "[4] assistant-only mention does not fire"

# [5] empty transcript → no marker
reset_cache
write_transcript ''
run_hook "{\"transcript_path\":\"$TMP/transcript.jsonl\",\"session_id\":\"sess-empty\"}"
assert_marker_absent "[5] empty transcript does not fire"

# [6] missing transcript_path → no marker
reset_cache
run_hook '{"session_id":"sess-no-path"}'
assert_marker_absent "[6] missing transcript_path does not fire"

# [7] nonexistent transcript file → no marker
reset_cache
run_hook "{\"transcript_path\":\"$TMP/does-not-exist.jsonl\",\"session_id\":\"sess-no-file\"}"
assert_marker_absent "[7] nonexistent transcript file does not fire"

# [8] path-traversal session_id rejected
reset_cache
write_transcript '{"type":"user","message":{"role":"user","content":"<command-name>/reload-plugins</command-name>"}}'
run_hook "{\"transcript_path\":\"$TMP/transcript.jsonl\",\"session_id\":\"../../etc/passwd\"}"
assert_no_path_escape "[8] path-traversal session_id rejected"

# [9] backslash session_id rejected
reset_cache
write_transcript '{"type":"user","message":{"role":"user","content":"<command-name>/reload-plugins</command-name>"}}'
run_hook "{\"transcript_path\":\"$TMP/transcript.jsonl\",\"session_id\":\"a\\\\b\"}"
assert_no_path_escape "[9] backslash session_id rejected"

# [10] empty session_id rejected
reset_cache
write_transcript '{"type":"user","message":{"role":"user","content":"<command-name>/reload-plugins</command-name>"}}'
run_hook "{\"transcript_path\":\"$TMP/transcript.jsonl\",\"session_id\":\"\"}"
assert_marker_absent "[10] empty session_id does not fire"

# [11] malformed stdin → exit 0, no marker
reset_cache
run_hook 'not even json{{'
rc=$?
[ $rc -eq 0 ] || { echo "FAIL [11] hook exit=$rc on malformed stdin"; FAIL=$((FAIL + 1)); }
assert_marker_absent "[11] malformed stdin → exit 0, no marker"

# [bonus] command-name buried in transcript with surrounding noise still matches
reset_cache
{
  echo '{"type":"user","message":{"role":"user","content":"earlier message"}}'
  echo '{"type":"assistant","message":{"role":"assistant","content":"some reply"}}'
  echo '{"type":"user","message":{"role":"user","content":"<command-name>/reload-plugins</command-name>\n            <command-message>reload-plugins</command-message>"}}'
} > "$TMP/transcript.jsonl"
run_hook "{\"transcript_path\":\"$TMP/transcript.jsonl\",\"session_id\":\"sess-bonus\"}"
assert_marker_present "[bonus] command-name in mixed transcript fires" "sess-bonus"

# [12] SIGPIPE+pipefail regression: when tail must write more after grep -q
# matches early, the broken `tail | grep -q` form under `set -o pipefail`
# loses the marker. grep -q exits on first match → tail's next write SIGPIPEs
# (exit 141) → pipefail propagates → if-condition evaluates false.
# Live evidence: 2026-04-28 trace from session fe8a6b58 captured tail50_match=2
# but NO_MATCH from the if-branch in the same script invocation. Fix uses
# process substitution so tail runs in a subshell whose exit doesn't propagate.
#
# Determinism: a single post-match line larger than the Linux pipe buffer
# (64KB) guarantees SIGPIPE. We place the pattern at line 151 (first in the
# tail-50 window) followed by one 256KB line — tail's write of that line
# always blocks/SIGPIPEs once grep -q has closed its read end.
reset_cache
{
  # 150 small prefix lines (outside tail-50 window — content irrelevant)
  for i in $(seq 1 150); do
    printf '{"type":"system","text":"prefix-%d"}\n' "$i"
  done
  # pattern at line 151 = first line of tail -n 50's output
  echo '{"type":"user","message":{"role":"user","content":"<command-name>/reload-plugins</command-name>"}}'
  # one giant line (256KB > 64KB pipe buffer) — guarantees SIGPIPE on broken impl
  printf '{"type":"assistant","text":"giant-line %s"}\n' "$(printf 'x%.0s' {1..262144})"
  # 48 small trailing lines to fill out tail-50
  for i in $(seq 1 48); do
    printf '{"type":"assistant","text":"trailing-%d"}\n' "$i"
  done
} > "$TMP/transcript.jsonl"
run_hook "{\"transcript_path\":\"$TMP/transcript.jsonl\",\"session_id\":\"sess-sigpipe\"}"
assert_marker_present "[12] post-match pipe-buffer overflow does not lose marker (SIGPIPE+pipefail regression)" "sess-sigpipe"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
