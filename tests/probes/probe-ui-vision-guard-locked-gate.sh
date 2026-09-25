#!/usr/bin/env bash
# probe-ui-vision-guard-locked-gate.sh
#
# Regression probe for dhx/dhx-ui-vision-guard.sh (PreToolUse Agent).
#
# Invariant: the zero-locked-rows exit guard is live — HAS_LOCKED is a
# single-line count (grep -c prints 0 on zero matches; its nonzero exit
# is deliberately unchecked, no `|| echo "0"` fallback). The pre-fix
# fallback double-emitted "0\n0", erroring the `-eq 0` test to false, so
# a DESIGN-VISION.md with ZERO locked hex rows scaffolded
# .claude/skills/z-gsdui/ anyway and emitted a broken advisory (asserted
# in [5]-[8]). A locked vision still scaffolds + injects the advisory;
# a missing vision file and non-UI agent types are silent no-ops.
#
#        (brief .planning/backlog/2026-07-07-ui-vision-guard-grep-count-
#        double-emission.md; same `|| echo` class as CL-H.assessed-guard).
#
# Run: bash tests/probes/probe-ui-vision-guard-locked-gate.sh
#
# SAFE_FOR_LIVE: yes  (hook subshell with synthetic stdin, cwd'd into a
#                      per-scenario mktemp fixture tree carrying its own
#                      CLAUDE.md project-root marker; the hook's scaffold
#                      writes land under the fixture's .claude/skills/;
#                      no live repo, .planning/, or config writes.)

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$REPO/dhx/dhx-ui-vision-guard.sh"

if [[ ! -f "$HOOK" ]]; then
  echo "FAIL hook not found: $HOOK"
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASSED=0
FAILED=0

_assert() { # $1 label, $2 expected, $3 actual
  if [[ "$2" == "$3" ]]; then
    echo "OK   $1"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL $1 (expected [$2], got [$3])"
    FAILED=$((FAILED + 1))
  fi
}

_json_agent() { # $1 subagent_type
  jq -n --arg t "$1" '{tool_name:"Agent",tool_input:{subagent_type:$t}}'
}

# _fixture <name> → fresh project root with CLAUDE.md marker; prints path
_fixture() {
  local d="$TMP/$1"
  mkdir -p "$d/docs/design"
  touch "$d/CLAUDE.md"
  printf '%s' "$d"
}

# _run <fixture-dir> <json> → sets RC, OUT (stdout), ERR (stderr)
_run() {
  local d="$1" json="$2"
  ERR_FILE="$TMP/stderr"
  OUT=$(printf '%s' "$json" | (cd "$d" && bash "$HOOK") 2>"$ERR_FILE")
  RC=$?
  ERR=$(cat "$ERR_FILE")
}

UNLOCKED_VISION='# Design Vision

| Token | Value |
|-------|-------|
| primary | <!-- TBD --> |
| accent  | pending review |
'

LOCKED_ROW='| primary | #1A2B3C |'

# --- Scenario A: no DESIGN-VISION.md → silent no-op --------------------
FA=$(_fixture "a-no-vision")
_run "$FA" "$(_json_agent gsd-ui-researcher)"
_assert "[1] no vision: exit 0" "0" "$RC"
_assert "[2] no vision: no scaffold" "absent" \
  "$([[ -e "$FA/.claude/skills/z-gsdui" ]] && echo present || echo absent)"
_assert "[3] no vision: stdout empty" "" "$OUT"
_assert "[4] no vision: stderr empty" "" "$ERR"

# --- Scenario B: vision present, ZERO locked rows → exit clean, NO
#     scaffold (the pre-fix `|| echo "0"` regression) -------------------
FB=$(_fixture "b-unlocked")
printf '%s' "$UNLOCKED_VISION" > "$FB/docs/design/DESIGN-VISION.md"
_run "$FB" "$(_json_agent gsd-ui-researcher)"
_assert "[5] unlocked vision: exit 0" "0" "$RC"
_assert "[6] unlocked vision: no scaffold" "absent" \
  "$([[ -e "$FB/.claude/skills/z-gsdui" ]] && echo present || echo absent)"
_assert "[7] unlocked vision: stderr empty (no integer-expression noise)" "" "$ERR"
_assert "[8] unlocked vision: stdout empty (no advisory)" "" "$OUT"

# --- Scenario C: vision with a locked hex row → scaffold + advisory ----
FC=$(_fixture "c-locked")
printf '%s%s\n' "$UNLOCKED_VISION" "$LOCKED_ROW" > "$FC/docs/design/DESIGN-VISION.md"
_run "$FC" "$(_json_agent gsd-ui-checker)"
_assert "[9] locked vision: exit 0" "0" "$RC"
_assert "[10] locked vision: scaffold rules file created" "present" \
  "$([[ -f "$FC/.claude/skills/z-gsdui/rules/design-vision-authority.md" ]] && echo present || echo absent)"
CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
_assert "[11] locked vision: advisory is valid JSON carrying the count" "yes" \
  "$([[ "$CTX" == *"has 1 locked token value"* ]] && echo yes || echo no)"

# --- Scenario D: non-UI agent type gated out even with a locked vision -
FD=$(_fixture "d-other-agent")
printf '%s%s\n' "$UNLOCKED_VISION" "$LOCKED_ROW" > "$FD/docs/design/DESIGN-VISION.md"
_run "$FD" "$(_json_agent general-purpose)"
_assert "[12] non-UI agent: no scaffold, silent" "0//absent" \
  "$RC/$OUT/$([[ -e "$FD/.claude/skills/z-gsdui" ]] && echo present || echo absent)"

echo "---"
echo "$PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]] || exit 1
exit 0
