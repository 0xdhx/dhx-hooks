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
#   bare major (v2) treated as v2.0.0; non-version tags (post-1) ignored
# - Parser parity with skills:scripts/backlog-promote-next.cjs — the hook must
#   accept EXACTLY the milestone headings and version tags the planner accepts
#   (vN / vN.M / vN.M.P), or the reminder points at a command that exits 2
# - Output shape: single summary line + action line (total 2 lines when output emitted)
# - Exit code always 0 (non-blocking)
#
# Backs: docs/decisions.md 2026-04-20 dhx-new-milestone-promote-reminder row
#        + 2026-07-16 stale-version count row
# Run:   bash tests/probes/probe-new-milestone-promote-reminder.sh

# SAFE_FOR_LIVE: yes   (mktemp dirs passed as `cwd` in hook stdin JSON; hook reads only via cwd; no HOME mutation)
set -u
# Override lets a negative control drive this probe against an older copy of the
# hook (e.g. `git show HEAD:dhx/...`), the same affordance DHX_*_CACHE_DIR gives
# the schedule probes. Unset = the live hook.
HOOK="${DHX_PROMOTE_REMINDER_HOOK:-/home/dhx/repos/hooks/dhx/dhx-new-milestone-promote-reminder.sh}"
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
EXPECTED="Closing v1.5 — 2 'next' + 1 'next+N' backlog brief(s) await promotion.
Run /dhx:backlog promote-next once the cut is committed."
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
EXPECTED="Closing v1.4 — 2 stale-version backlog brief(s) await promotion.
Run /dhx:backlog promote-next once the cut is committed."
check "A7 stale-only fires (equal+below counted, future not)" "$EXPECTED" "$OUT"
rm -rf "$TMP"

# --- Assertion 8: Per-component compare — v1.10 > v1.9, not string/decimal ---
TMP=$(mktemp -d)
mk_fixture "$TMP" "v1.9"
add_brief "$TMP" "a.md" "v1.10"  # numerically ABOVE v1.9 → not stale
add_brief "$TMP" "b.md" "v1.9"   # equal → stale
OUT=$(run "$TMP")
EXPECTED="Closing v1.9 — 1 stale-version backlog brief(s) await promotion.
Run /dhx:backlog promote-next once the cut is committed."
check "A8 per-component compare (v1.10 not stale at v1.9)" "$EXPECTED" "$OUT"
rm -rf "$TMP"

# --- Assertion 9: Bare major tag + non-version tags ---
TMP=$(mktemp -d)
mk_fixture "$TMP" "v2.1"
add_brief "$TMP" "a.md" "v2"      # bare major = v2.0 <= v2.1 → stale
add_brief "$TMP" "b.md" "post-1"  # not a version tag → ignored
add_brief "$TMP" "c.md" "v1.2.3"  # three components — ACCEPTED since 2026-09-04; v1.2.3 < v2.1 → stale
OUT=$(run "$TMP")
EXPECTED="Closing v2.1 — 2 stale-version backlog brief(s) await promotion.
Run /dhx:backlog promote-next once the cut is committed."
check "A9 bare-major + three-component counted, non-version tags ignored" "$EXPECTED" "$OUT"
rm -rf "$TMP"

# --- Assertion 10: All three counts compose in one summary line ---
TMP=$(mktemp -d)
mk_fixture "$TMP" "v1.5"
add_brief "$TMP" "a.md" "next"
add_brief "$TMP" "b.md" "next+2"
add_brief "$TMP" "c.md" "v1.5"
OUT=$(run "$TMP")
EXPECTED="Closing v1.5 — 1 'next' + 1 'next+N' + 1 stale-version backlog brief(s) await promotion.
Run /dhx:backlog promote-next once the cut is committed."
check "A10 mixed three-way compositional line" "$EXPECTED" "$OUT"
rm -rf "$TMP"

# --- Assertion 11: Three-component (semver) milestone heading ---
# The failure shape this pins: before 2026-09-04 the hook's regex captured only
# `v[0-9]+\.[0-9]+` and `.*`-ate the rest, so a `v0.3.0` heading emitted
# "Milestone v0.3 declared" — a version string appearing nowhere in the file —
# while backlog-promote-next.cjs returned version:null and exit 2 on that same
# file. Measured in ~/repos/barca with 34 stranded next briefs.
TMP=$(mktemp -d)
mk_fixture "$TMP" "v0.3.0"
add_brief "$TMP" "a.md" "next"
add_brief "$TMP" "b.md" "v0.2.9"  # below closing → stale
add_brief "$TMP" "c.md" "v0.3.0"  # equal to closing → stale (<= per INVARIANT)
add_brief "$TMP" "d.md" "v0.4.0"  # future → never counted
OUT=$(run "$TMP")
EXPECTED="Closing v0.3.0 — 1 'next' + 2 stale-version backlog brief(s) await promotion.
Run /dhx:backlog promote-next once the cut is committed."
check "A11 three-component heading kept whole (not truncated to v0.3)" "$EXPECTED" "$OUT"
rm -rf "$TMP"

# --- Assertion 12: Over-long version token is REJECTED, matching the planner ---
# `v0.3.0.1` is not a version the planner can parse, so the hook must stay
# silent rather than point at a command that would exit 2.
TMP=$(mktemp -d)
mk_fixture "$TMP" "v0.3.0.1"
add_brief "$TMP" "a.md" "next"
OUT=$(run "$TMP")
check "A12 four-component heading silent (planner rejects it too)" "" "$OUT"
rm -rf "$TMP"

# --- Assertion 13: LIVE parser parity against the planner itself ---
# The header's PARSER PARITY claim is only as good as something that checks it.
# For each heading shape, the hook emitting and the planner resolving a version
# must AGREE — and when both accept, they must agree on the version STRING.
# Skipped (not failed) when the skills repo isn't present on this machine.
PLANNER="$HOME/repos/skills/scripts/backlog-promote-next.cjs"
if [ -f "$PLANNER" ] && command -v node >/dev/null 2>&1; then
  PARITY_FAIL=0
  for ver in "v2" "v1.5" "v0.3.0" "v10.0.1" "v0.3.0.1"; do
    TMP=$(mktemp -d)
    mk_fixture "$TMP" "$ver"
    add_brief "$TMP" "a.md" "next"
    HOOK_OUT=$(run "$TMP")
    # Hook's view: the version it printed, or empty when it stayed silent.
    HOOK_VER=$(printf '%s' "$HOOK_OUT" | sed -nE 's/^Closing (v[0-9.]+) .*/\1/p')
    # Planner's view: the version it resolved, or empty on null.
    PLAN_VER=$(cd "$TMP" && node "$PLANNER" plan --from next --json 2>/dev/null \
      | sed -nE 's/.*"version":[[:space:]]*"([^"]+)".*/\1/p' | head -1)
    if [ "$HOOK_VER" != "$PLAN_VER" ]; then
      echo "     parity drift at heading '$ver': hook='$HOOK_VER' planner='$PLAN_VER'"
      PARITY_FAIL=1
    fi
    rm -rf "$TMP"
  done
  check "A13 hook/planner version-grammar parity across 5 heading shapes" "0" "$PARITY_FAIL"
else
  echo "SKIP A13 parser parity — skills repo planner not found at $PLANNER"
fi

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
