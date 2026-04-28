#!/usr/bin/env bash
# Probe: exercises dhx/dhx-restart-plugins-marker.sh against the prompt-shape
# matrix and the session_id sanitization branch. Backs the
# ⚠ restart plugins / `/restart-plugins` rebaseline pipeline.
#
# Scope:
#   1. /restart-plugins → marker file present
#   2. /reload-plugins → marker file present
#   3. /restart (no -plugins suffix) → no marker
#   4. /restart-plugins-foo (word-boundary anchor) → no marker
#   5. quoted occurrence in prose (^ anchor) → no marker
#   6. empty prompt → no marker
#   7. path-traversal session_id rejected → no file outside fake HOME's cache dir
#   8. malformed stdin (non-JSON) → exit 0, no marker (graceful degrade)
#
# Run: bash tests/probes/probe-restart-plugins-hook.sh
#
# Backs:
#   - docs/decisions.md — restart-plugins rebaseline marker row
#   - docs/hook-patterns.md — HP-008 (UserPromptSubmit .prompt + .session_id schema)
#   - docs/statusline-wrapper.md — Drift Detection § Marker-driven rebaseline

set -u

HOOK="/home/dhx/repos/hooks/dhx/dhx-restart-plugins-marker.sh"
TMP=$(mktemp -d /tmp/probe-restart-plugins-hook.XXXXXX)
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
  # Reject if any plugins-rebaseline marker was written ANYWHERE under TMP
  # (including via path-escape into a non-cache dir) AND nothing got written
  # under /tmp/etc/passwd-like targets.
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
}

# [1] /restart-plugins → marker present
reset_cache
run_hook '{"prompt":"/restart-plugins","session_id":"sess-rp"}'
rc=$?
[ $rc -eq 0 ] || { echo "FAIL [1] hook exit=$rc"; FAIL=$((FAIL + 1)); }
assert_marker_present "[1] /restart-plugins fires" "sess-rp"

# [2] /reload-plugins → marker present
reset_cache
run_hook '{"prompt":"/reload-plugins","session_id":"sess-rl"}'
assert_marker_present "[2] /reload-plugins fires" "sess-rl"

# [3] /restart (no -plugins suffix) → no marker
reset_cache
run_hook '{"prompt":"/restart","session_id":"sess-x"}'
assert_marker_absent "[3] /restart (without -plugins) does not fire"

# [4] /restart-plugins-foo (word-boundary anchor) → no marker
reset_cache
run_hook '{"prompt":"/restart-plugins-foo","session_id":"sess-x"}'
assert_marker_absent "[4] /restart-plugins-foo (word-boundary) does not fire"

# [5] embedded mention in prose (^ anchor) → no marker
reset_cache
run_hook '{"prompt":"tell me about /restart-plugins later","session_id":"sess-x"}'
assert_marker_absent "[5] embedded /restart-plugins in prose does not fire"

# [6] empty prompt → no marker
reset_cache
run_hook '{"prompt":"","session_id":"sess-x"}'
assert_marker_absent "[6] empty prompt does not fire"

# [7] path-traversal session_id rejected → no file written outside expected dir
reset_cache
run_hook '{"prompt":"/restart-plugins","session_id":"../../etc/passwd"}'
assert_no_path_escape "[7] path-traversal session_id rejected"

# Also reject sessions with backslash separators
reset_cache
run_hook '{"prompt":"/restart-plugins","session_id":"a\\b"}'
assert_no_path_escape "[7b] backslash session_id rejected"

# Also reject empty session_id (no marker name → no file)
reset_cache
run_hook '{"prompt":"/restart-plugins","session_id":""}'
assert_marker_absent "[7c] empty session_id does not fire"

# [8] malformed stdin → exit 0, no marker (jq parse fails silently)
reset_cache
run_hook 'not even json{{'
rc=$?
[ $rc -eq 0 ] || { echo "FAIL [8] hook exit=$rc on malformed stdin"; FAIL=$((FAIL + 1)); }
assert_marker_absent "[8] malformed stdin → exit 0, no marker"

# Bonus: trailing arguments after /restart-plugins still match
reset_cache
run_hook '{"prompt":"/restart-plugins now please","session_id":"sess-trail"}'
assert_marker_present "[bonus] /restart-plugins with trailing prose still fires" "sess-trail"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
