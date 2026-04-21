#!/usr/bin/env bash
# probe-new-milestone-promote-reminder.sh
#
# Exercises dhx/dhx-new-milestone-promote-reminder.sh invariants:
# - Skill filter: only gsd-new-milestone triggers output
# - Precondition guards: missing .planning/, missing PROJECT.md, unparseable version → silent
# - Count partitioning: `next` vs `next+[1-3]` tracked separately
# - Output shape: single summary line + action line (total 2 lines when output emitted)
# - Exit code always 0 (non-blocking)
#
# Backs: docs/decisions.md 2026-04-20 dhx-new-milestone-promote-reminder row
# Run:   bash tests/probes/probe-new-milestone-promote-reminder.sh

set -u
HOOK=/home/dhx/repos/hooks/dhx/dhx-new-milestone-promote-reminder.sh
PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "OK   $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL $name"
    echo "     expected: $expected"
    echo "     actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

mk_fixture() {
  local dir="$1" version="$2"
  mkdir -p "$dir/.planning/backlog"
  cat > "$dir/.planning/PROJECT.md" <<EOF
# Fixture

## Current Milestone: $version Test
EOF
}

add_brief() {
  local dir="$1" name="$2" tm="$3"
  cat > "$dir/.planning/backlog/$name" <<EOF
---
target_milestone: $tm
created: 2026-04-20
---
# $name
EOF
}

run() {
  local cwd="$1" skill="${2:-gsd-new-milestone}"
  echo "{\"tool_input\":{\"skill\":\"$skill\"},\"cwd\":\"$cwd\"}" \
    | bash "$HOOK" 2>/dev/null
}

# --- Assertion 1: Skill filter — wrong skill → silent ---
OUT=$(run "/tmp" "gsd-plan-phase")
check "A1 wrong skill silent" "" "$OUT"

# --- Assertion 2: Missing .planning/ → silent ---
TMP=$(mktemp -d)
OUT=$(run "$TMP")
check "A2 missing .planning silent" "" "$OUT"
rm -rf "$TMP"

# --- Assertion 3: Missing PROJECT.md → silent ---
TMP=$(mktemp -d)
mkdir -p "$TMP/.planning/backlog"
add_brief "$TMP" "a.md" "next"
OUT=$(run "$TMP")
check "A3 missing PROJECT.md silent" "" "$OUT"
rm -rf "$TMP"

# --- Assertion 4: Unparseable version → silent ---
TMP=$(mktemp -d)
mk_fixture "$TMP" "vX.Y"  # invalid format
add_brief "$TMP" "a.md" "next"
OUT=$(run "$TMP")
check "A4 unparseable version silent" "" "$OUT"
rm -rf "$TMP"

# --- Assertion 5: Mixed next + next+N produces combined summary + action ---
TMP=$(mktemp -d)
mk_fixture "$TMP" "v1.5"
add_brief "$TMP" "a.md" "next"
add_brief "$TMP" "b.md" "next"
add_brief "$TMP" "c.md" "next+1"
add_brief "$TMP" "d.md" "v2.0"  # unrelated — not counted
OUT=$(run "$TMP")
EXPECTED="Milestone v1.5 declared. 2 'next' + 1 'next+N' backlog brief(s) ready for promotion.
Run /dhx:backlog promote-next to reassign frontmatter."
check "A5 mixed counts output" "$EXPECTED" "$OUT"
rm -rf "$TMP"

# --- Assertion 6: Exit code is 0 across all scenarios ---
TMP=$(mktemp -d)
mk_fixture "$TMP" "v1.5"
add_brief "$TMP" "a.md" "next"
echo "{\"tool_input\":{\"skill\":\"gsd-new-milestone\"},\"cwd\":\"$TMP\"}" \
  | bash "$HOOK" > /dev/null 2>&1
check "A6 exit code 0 on emit" "0" "$?"
rm -rf "$TMP"

echo "---"
echo "$PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
