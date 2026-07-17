#!/usr/bin/env bash
# probe-new-milestone-promote-reminder.sh
#
# Exercises dhx/dhx-new-milestone-promote-reminder.sh invariants:
# - Skill filter: only gsd-new-milestone triggers output
# - Precondition guards: missing .planning/, missing PROJECT.md, unparseable version → silent
# - Count partitioning: `next` vs `next+[1-3]` vs stale-version tracked separately
# - Stale semantics: version tag <= $VERSION counted (<=, not <, because the hook
#   fires BEFORE /gsd-new-milestone rewrites PROJECT.md — $VERSION is the CLOSING
#   milestone); future tags never counted; per-component compare (v1.10 > v1.9);
#   bare major (v2) treated as v2.0; non-version tags (post-1) ignored
# - Output shape: single summary line + action line (total 2 lines when output emitted)
# - Exit code always 0 (non-blocking)
#
# Backs: docs/decisions.md 2026-04-20 dhx-new-milestone-promote-reminder row
#        + 2026-07-16 stale-version count row
# Run:   bash tests/probes/probe-new-milestone-promote-reminder.sh

# SAFE_FOR_LIVE: yes   (mktemp dirs passed as `cwd` in hook stdin JSON; hook reads only via cwd; no HOME mutation)
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

# --- Assertion 7: Stale-only fires — the failure shape from the driving brief ---
# Zero next-tagged briefs; equal-to-closing and below tags counted, future not.
TMP=$(mktemp -d)
mk_fixture "$TMP" "v1.4"
add_brief "$TMP" "a.md" "v1.4"   # equal to closing milestone → stale (<=)
add_brief "$TMP" "b.md" "v1.3"   # below → stale
add_brief "$TMP" "c.md" "v2.0"   # future → never counted
OUT=$(run "$TMP")
EXPECTED="Milestone v1.4 declared. 2 stale-version backlog brief(s) ready for promotion.
Run /dhx:backlog promote-next to reassign frontmatter."
check "A7 stale-only fires (equal+below counted, future not)" "$EXPECTED" "$OUT"
rm -rf "$TMP"

# --- Assertion 8: Per-component compare — v1.10 > v1.9, not string/decimal ---
TMP=$(mktemp -d)
mk_fixture "$TMP" "v1.9"
add_brief "$TMP" "a.md" "v1.10"  # numerically ABOVE v1.9 → not stale
add_brief "$TMP" "b.md" "v1.9"   # equal → stale
OUT=$(run "$TMP")
EXPECTED="Milestone v1.9 declared. 1 stale-version backlog brief(s) ready for promotion.
Run /dhx:backlog promote-next to reassign frontmatter."
check "A8 per-component compare (v1.10 not stale at v1.9)" "$EXPECTED" "$OUT"
rm -rf "$TMP"

# --- Assertion 9: Bare major tag + non-version tags ---
TMP=$(mktemp -d)
mk_fixture "$TMP" "v2.1"
add_brief "$TMP" "a.md" "v2"      # bare major = v2.0 <= v2.1 → stale
add_brief "$TMP" "b.md" "post-1"  # not a version tag → ignored
add_brief "$TMP" "c.md" "v1.2.3"  # three components — outside pattern → ignored
OUT=$(run "$TMP")
EXPECTED="Milestone v2.1 declared. 1 stale-version backlog brief(s) ready for promotion.
Run /dhx:backlog promote-next to reassign frontmatter."
check "A9 bare-major counted, non-version tags ignored" "$EXPECTED" "$OUT"
rm -rf "$TMP"

# --- Assertion 10: All three counts compose in one summary line ---
TMP=$(mktemp -d)
mk_fixture "$TMP" "v1.5"
add_brief "$TMP" "a.md" "next"
add_brief "$TMP" "b.md" "next+2"
add_brief "$TMP" "c.md" "v1.5"
OUT=$(run "$TMP")
EXPECTED="Milestone v1.5 declared. 1 'next' + 1 'next+N' + 1 stale-version backlog brief(s) ready for promotion.
Run /dhx:backlog promote-next to reassign frontmatter."
check "A10 mixed three-way compositional line" "$EXPECTED" "$OUT"
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
