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

# --- Assertion 14: TWO-CUT EQUIVALENCE — the hook's <= and promote-next's < ---
# The header INVARIANT claims the hook's `<=` at v1.5-CLOSING and the planner's
# `<` at v1.6-DECLARED select the IDENTICAL set of stale briefs. That is the
# load-bearing reason the compare did not have to change when the reminder was
# re-scoped, so it is demonstrated here across an actual cut rather than argued.
# Skipped (not failed) when the skills repo planner is absent.
PLANNER="$HOME/repos/skills/scripts/backlog-promote-next.cjs"
if [ -f "$PLANNER" ] && command -v node >/dev/null 2>&1; then
  TMP=$(mktemp -d)
  mk_fixture "$TMP" "v1.5"                    # PRE-cut: v1.5 is the CLOSING milestone
  cat > "$TMP/.planning/MILESTONES.md" <<'MS'
# Milestones

## v1.3 (closed)
## v1.4 (closed)
## v1.5 (closing)
## v1.6 (next)
MS
  add_brief "$TMP" "s13.md" "v1.3"   # below closing  → stale on both sides
  add_brief "$TMP" "s14.md" "v1.4"   # below closing  → stale on both sides
  add_brief "$TMP" "s15.md" "v1.5"   # EQUAL to closing → the whole point of <=
  add_brief "$TMP" "s16.md" "v1.6"   # the incoming milestone → stale on NEITHER side

  # Side A — the hook, fired PRE-cut while PROJECT.md still names v1.5.
  OUT=$(run "$TMP")
  HOOK_STALE=$(printf '%s' "$OUT" | sed -nE 's/.*[^0-9]([0-9]+) stale-version.*/\1/p')

  # Side B — the planner, run POST-cut. Nothing but the heading changes.
  sed -i 's/^## Current Milestone: v1.5.*/## Current Milestone: v1.6 Next Up/' "$TMP/.planning/PROJECT.md"
  PLAN_STALE=$(cd "$TMP" && node "$PLANNER" plan --from stale --json 2>/dev/null \
    | tr ',' '\n' | grep -c '"tag"')
  PLAN_TAGS=$(cd "$TMP" && node "$PLANNER" plan --from stale --json 2>/dev/null \
    | sed -nE 's/.*"tag": "([^"]+)".*/\1/p' | sort | tr '\n' ' ')

  check "A14a two-cut equivalence: hook <= at closing == planner < at declared" "$HOOK_STALE" "$PLAN_STALE"
  # Membership, not just cardinality: the equal-to-closing brief MUST be in the
  # set, and the incoming-milestone brief MUST NOT be.
  check "A14b planner's post-cut stale set is exactly v1.3 v1.4 v1.5" "v1.3 v1.4 v1.5 " "$PLAN_TAGS"
  rm -rf "$TMP"
else
  echo "SKIP A14 two-cut equivalence — skills repo planner not found at $PLANNER"
fi

# --- Assertion 15: frontmatter is read as a BLOCK, not a line window ---
# The failure shape: the scan used `head -30`, so a brief whose frontmatter runs
# long (a multi-line `trigger_when:` is the common cause) had its
# `target_milestone:` fall outside the window and went uncounted. Measured
# 2026-09-04 in ~/repos/barca: 16 of 34 `next` briefs sat beyond line 30,
# deepest at line 76 — the reminder printed 24 where promote-next reported 34.
# The same fixture pins the inverse: a `target_milestone:` line in BODY prose is
# outside the frontmatter block and must NOT count.
TMP=$(mktemp -d)
mk_fixture "$TMP" "v1.5"
{
  echo "---"
  echo "created: 2026-09-04"
  echo "trigger_when: >"
  for i in $(seq 1 40); do echo "  padding line $i of a long block scalar"; done
  echo "target_milestone: next"     # line 45 — well past any 30-line window
  echo "---"
  echo "# Deep frontmatter brief"
} > "$TMP/.planning/backlog/deep.md"
{
  echo "---"
  echo "target_milestone: v2.0"     # future → not counted
  echo "---"
  echo "# Body-text decoy"
  echo ""
  echo "target_milestone: next"     # BODY prose → must NOT count as next
} > "$TMP/.planning/backlog/decoy.md"
OUT=$(run "$TMP")
EXPECTED="Closing v1.5 — 1 'next' backlog brief(s) await promotion.
Run /dhx:backlog promote-next once the cut is committed."
check "A15 deep frontmatter counted; body-text target_milestone ignored" "$EXPECTED" "$OUT"
rm -rf "$TMP"

# --- Assertion 16: LIVE count parity with the planner ---
# A13 pins that the two agree on which VERSIONS parse. This pins that they agree
# on HOW MANY briefs are promotable — the axis the head -30 window broke while
# every version assertion stayed green. Skipped when the skills repo is absent.
PLANNER="$HOME/repos/skills/scripts/backlog-promote-next.cjs"
if [ -f "$PLANNER" ] && command -v node >/dev/null 2>&1; then
  TMP=$(mktemp -d)
  mk_fixture "$TMP" "v1.5"
  {
    echo "---"
    echo "trigger_when: >"
    for i in $(seq 1 40); do echo "  padding line $i"; done
    echo "target_milestone: next"
    echo "---"
    echo "# Deep"
  } > "$TMP/.planning/backlog/deep.md"
  HOOK_NEXT=$(run "$TMP" | sed -nE "s/.*— ([0-9]+) 'next'.*/\1/p")
  PLAN_NEXT=$(cd "$TMP" && node "$PLANNER" plan --from next --json 2>/dev/null \
    | tr ',' '\n' | grep -c '"file"')
  check "A16 hook 'next' count == planner next_items count" "$HOOK_NEXT" "$PLAN_NEXT"
  rm -rf "$TMP"
else
  echo "SKIP A16 count parity — skills repo planner not found at $PLANNER"
fi

# --- Assertion 17: flat-mode-only — silent under a workstream ---
# This is the one thing A13 and A16 are structurally blind to. They compare the
# hook and the planner on version GRAMMAR and brief COUNT; neither can see a
# MODE divergence, so a green parity pair would happily certify a hook that
# advertises a promotion the planner refuses. A17 pins the mode behaviour
# directly.
#
# The fixture is deliberately adversarial: the heading is a perfectly parseable
# `v1.5` and there IS a `next` brief, so every pre-workstream precondition says
# "emit". Only the workstream guard can produce silence here — which is what
# makes the pre-fix negative control go RED rather than pass by accident. It
# also pins the exact hole the old "the version check already covers it" claim
# left open: a STALE-BUT-PARSEABLE heading, which is the normal workstream
# state, not an edge case.
#
# 17a uses the no-resolver branch, so it runs identically on a machine with no
# gsd-core; 17b drives the live resolver and self-skips when gsd-core is absent.
TMP=$(mktemp -d)
mk_fixture "$TMP" "v1.5"
add_brief "$TMP" "a.md" "next"
mkdir -p "$TMP/.planning/workstreams/alpha"
NOGSD=$(mktemp -d)
OUT=$(echo "{\"tool_input\":{\"skill\":\"gsd-new-milestone\"},\"cwd\":\"$TMP\"}" \
  | CLAUDE_CONFIG_DIR="$NOGSD" bash "$HOOK" 2>/dev/null)
check "A17a silent under a workstreams dir with no resolver (undetermined != flat)" "" "$OUT"

# Control for 17a: with the workstreams dir removed and still no resolver, the
# SAME fixture must emit. Without this arm 17a would also pass if the guard
# silenced the hook unconditionally — the assertion would be inert.
rm -rf "$TMP/.planning/workstreams"
OUT=$(echo "{\"tool_input\":{\"skill\":\"gsd-new-milestone\"},\"cwd\":\"$TMP\"}" \
  | CLAUDE_CONFIG_DIR="$NOGSD" bash "$HOOK" 2>/dev/null)
if [ -n "$OUT" ]; then
  echo "OK   A17b flat mode still emits (guard is not an unconditional silencer)"
  PASS=$((PASS + 1))
else
  echo "FAIL A17b flat mode still emits (guard is not an unconditional silencer)"
  echo "     expected: non-empty reminder"
  echo "     actual:   <empty>"
  FAIL=$((FAIL + 1))
fi
rm -rf "$NOGSD"

GSD_TOOLS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/gsd-core/bin/gsd-tools.cjs"
if [ -f "$GSD_TOOLS" ]; then
  mkdir -p "$TMP/.planning/workstreams/alpha"
  printf 'milestone: v9.0\n' > "$TMP/.planning/workstreams/alpha/STATE.md"
  printf '# Roadmap\n'       > "$TMP/.planning/workstreams/alpha/ROADMAP.md"
  WSKEY="probe-a17-$$-$RANDOM"
  ( cd "$TMP" && GSD_SESSION_KEY="$WSKEY" node "$GSD_TOOLS" workstream set alpha >/dev/null 2>&1 )
  OUT=$(echo "{\"tool_input\":{\"skill\":\"gsd-new-milestone\"},\"cwd\":\"$TMP\"}" \
    | GSD_SESSION_KEY="$WSKEY" bash "$HOOK" 2>/dev/null)
  check "A17c silent under a LIVE active workstream (stale-but-parseable heading)" "" "$OUT"
else
  echo "SKIP A17c live workstream — gsd-core not found at $GSD_TOOLS"
fi
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
