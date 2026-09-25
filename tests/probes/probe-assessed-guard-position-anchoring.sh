#!/usr/bin/env bash
# probe-assessed-guard-position-anchoring.sh
#
# Regression probe for dhx/dhx-assessed-guard.sh (PreToolUse Write|Edit).
#
# Invariant: [assessed detection is position-anchored — a marker counts only
# at a deferred-item bullet position (final bracketed token at end of line,
# stacked trailing markers allowed, OR bullet-leading; classifier parity with
# skills/scripts/dhx-classify-deferred.sh :92/:155-160). The bare token in
# prose does NOT trip the guard. The Edit branch reconstructs effective
# post-edit content from the on-disk file (fragments start mid-line — anchors
# can't run on fragments), and the Write branch compares single-emission
# anchored counts: the pre-fix `|| echo 0` double-emitted "0\n0" on
# zero-match files, erroring the -gt test to false, so the FIRST [assessed]
# written into an existing CONTEXT.md never blocked (asserted in [3]/[12]).
#
#        (CL-H.assessed-guard; brief
#        2026-06-30-assessed-guard-bracket-position-anchoring.md).
#
# Run: bash tests/probes/probe-assessed-guard-position-anchoring.sh
#
# SAFE_FOR_LIVE: yes   (hook subshell with synthetic stdin against mktemp
#                       fixture CONTEXT.md files; the review-marker cell
#                       writes/removes a /tmp marker keyed to the fixture
#                       cwd's md5, which cannot collide with a live session
#                       cwd; no live repo or config writes.)

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$REPO/dhx/dhx-assessed-guard.sh"

if [[ ! -f "$HOOK" ]]; then
  echo "FAIL hook not found: $HOOK"
  exit 1
fi

TMP="$(mktemp -d)"
PHASE_DIR="$TMP/.planning/phases/09-fixture"
mkdir -p "$PHASE_DIR"
CTX="$PHASE_DIR/09-CONTEXT.md"
CTX_NEW="$PHASE_DIR/10-CONTEXT.md"   # never created on disk — new-file cells
MARKER="/tmp/dhx-deferred-review-$(echo "$TMP" | md5sum | cut -d' ' -f1)"
trap 'rm -rf "$TMP"; rm -f "$MARKER"' EXIT

PASSED=0
FAILED=0

# _decision <json> → prints "block" or "none" (stderr discarded)
_decision() {
  local out
  out=$(printf '%s' "$1" | bash "$HOOK" 2>/dev/null)
  if [[ -z "$out" ]]; then
    echo "none"
  else
    printf '%s' "$out" | jq -r '.decision // "none"'
  fi
}

_assert() { # $1 label, $2 expected, $3 actual
  if [[ "$2" == "$3" ]]; then
    echo "OK   $1"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL $1 (expected $2, got $3)"
    FAILED=$((FAILED + 1))
  fi
}

_json_edit() { # $1 old, $2 new, [$3 replace_all]
  jq -n --arg fp "$CTX" --arg old "$1" --arg new "$2" --arg cwd "$TMP" \
    --argjson ra "${3:-false}" \
    '{tool_name:"Edit",tool_input:{file_path:$fp,old_string:$old,new_string:$new,replace_all:$ra},cwd:$cwd}'
}

_json_write() { # $1 file_path, $2 content
  jq -n --arg fp "$1" --arg c "$2" --arg cwd "$TMP" \
    '{tool_name:"Write",tool_input:{file_path:$fp,content:$c},cwd:$cwd}'
}

# Baseline fixture: deferred section with disposed + open bullets, ZERO
# [assessed markers on disk (the P-2 broken-open precondition).
_reset_fixture() {
  cat > "$CTX" <<'EOF'
## Deferred Items

- **VCR cassettes**: replay infra deferred. [captured: 2026-06-30-vcr.md]
- **Golden files**: framework choice deferred. [tracked: BACKLOG-12]
- Open item without disposition
EOF
}

_reset_fixture

# [1] P-1 Edit: prose mention mid-line must NOT trip
_assert "[1] Edit prose mid-line mention -> no block" "none" \
  "$(_decision "$(_json_edit 'Open item without disposition' 'Open item without disposition (never mark `[assessed` in prose here)')")"

# [2] P-1 Write: prose mention appended to existing file must NOT trip
_assert "[2] Write prose mention -> no block" "none" \
  "$(_decision "$(_json_write "$CTX" "$(cat "$CTX")
The \`[assessed\` token is documented in this prose paragraph.")")"

# [3] P-2 regression: FIRST end-of-bullet marker written into an existing
#     zero-marker file must block (pre-fix: "0\n0" counter let it through)
_assert "[3] Write first end-of-bullet marker -> block" "block" \
  "$(_decision "$(_json_write "$CTX" "$(cat "$CTX")
- Old idea, user reviewed and declined. [assessed: user decided 2026-07-07]")")"

# [4] Edit mid-line fragment marking (reconstruction path): fragment carries
#     no bullet prefix, so only whole-content reconstruction can anchor it
_assert "[4] Edit mid-line fragment [captured]->[assessed] -> block" "block" \
  "$(_decision "$(_json_edit '[captured: 2026-06-30-vcr.md]' '[assessed: user reviewed]')")"

# [5] Edit adds bullet-leading marker
_assert "[5] Edit bullet-leading marker -> block" "block" \
  "$(_decision "$(_json_edit '- Open item without disposition' '- [assessed] Open item without disposition')")"

# [6] Stacked trailing markers (classifier end_marker_re parity)
_assert "[6] Edit stacked trailing markers -> block" "block" \
  "$(_decision "$(_json_edit '[tracked: BACKLOG-12]' '[assessed: ok] [note: kept for reference]')")"

# [7] New-file Write with a real end-of-bullet marker
_assert "[7] New-file Write real marker -> block" "block" \
  "$(_decision "$(_json_write "$CTX_NEW" '- Declined after review. [assessed: reason]')")"

# [8] New-file Write with only a prose token
_assert "[8] New-file Write prose-only token -> no block" "none" \
  "$(_decision "$(_json_write "$CTX_NEW" 'Discussing the `[assessed` marker convention in prose.')")"

# [9] Path gate: real marker outside .planning/phases/*-CONTEXT.md
_assert "[9] Non-CONTEXT.md path -> no block" "none" \
  "$(_decision "$(_json_write "$TMP/notes.md" '- Declined. [assessed: reason]')")"

# [10] replace_all reconstruction honors the // branch
_assert "[10] Edit replace_all marking -> block" "block" \
  "$(_decision "$(_json_edit 'deferred. [' 'deferred. [assessed: x] [' true)")"

# [11] Review-marker exception: fresh marker for this cwd allows the write
touch "$MARKER"
_assert "[11] Active review marker -> no block" "none" \
  "$(_decision "$(_json_write "$CTX" "$(cat "$CTX")
- Old idea, user reviewed and declined. [assessed: user decided 2026-07-07]")")"
rm -f "$MARKER"

# [12] stderr-clean on the P-2 scenario (pre-fix emitted
#      "integer expression expected" on stderr)
ERR=$(printf '%s' "$(_json_write "$CTX" "$(cat "$CTX")
- Declined. [assessed: r]")" | bash "$HOOK" 2>&1 >/dev/null)
_assert "[12] no stderr noise on Write counting" "" "$ERR"

echo "---"
echo "$PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]] || exit 1
exit 0
