#!/bin/bash
# probe-live-runtime-tier.sh — backs docs/decisions.md 2026-08-20
# "live-runtime probes move to an install-triggered tier".
#
# Three things must hold for the tier split to be safe rather than merely
# convenient, and each has bitten a comparable gate before:
#
#   1. ROSTER PARITY. Every `LIVE_RUNTIME: yes` probe is documented in
#      tests/probes/LIVE_RUNTIME.md and vice versa, and every declared
#      LIVE_SUBJECT path still exists. Classification rot is what turned the
#      SAFE_FOR_LIVE audit into a D-29 parity assertion; same failure mode here.
#   2. FAIL-TOWARD-RUNNING. An untagged probe must read as LIVE_RUNTIME:no, so a
#      new live probe that forgets its tag joins the tier that runs MORE often.
#      The opposite default would let a differential silently stop running —
#      the failure direction the 2026-08-20 decision names as the one that matters.
#   3. NO DEADLOCK. `--stamp` must write on FAIL as well as PASS. If the stamp
#      only recorded successes, a slow live red would leave it stale forever and
#      check #8c would block every commit until the multi-hour fix landed —
#      exactly the blast radius the split exists to remove.
#
# INVARIANT: the live tier cannot silently stop running. An install moves
# ~/.claude/gsd-core/VERSION; the stamp does not follow until the tier is actually
# executed; check #8c blocks while they disagree.
#
# Run: bash tests/probes/probe-live-runtime-tier.sh
# SAFE_FOR_LIVE: yes  (all behavioral cells run inside mktemp trees with a fake
#   $HOME and a throwaway git repo; reads the real repo only to grep tags/roster;
#   never writes to the live repo, the live stamp, or ~/.claude)
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROSTER="$REPO/tests/probes/LIVE_RUNTIME.md"
pass=0; fail=0
ok()  { echo "OK   $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; fail=$((fail+1)); }
chk() { if [ "$1" = "yes" ]; then ok "$2"; else bad "$2"; fi; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# ═══ 1. Roster parity + subject liveness ════════════════════════════════════
if [ ! -f "$ROSTER" ]; then
  bad "roster missing: tests/probes/LIVE_RUNTIME.md"
else
  ok "roster present"
fi

shopt -s nullglob
TAGGED=()
for p in "$REPO"/tests/probes/probe-*.sh "$REPO"/tests/probes/probe-*.js; do
  grep -qE '^(# |// )LIVE_RUNTIME: yes\b' "$p" && TAGGED+=("$(basename "$p")")
done

# The tier is non-vacuous. A zero-length roster would make every assertion below
# trivially true — the "photograph, not a test" shape.
if [ "${#TAGGED[@]}" -ge 5 ]; then
  ok "live tier is non-vacuous (${#TAGGED[@]} tagged probes)"
else
  bad "live tier has only ${#TAGGED[@]} tagged probes — expected >= 5 (roster gutted?)"
fi

for base in "${TAGGED[@]}"; do
  if grep -qF "\`$base\`" "$ROSTER" 2>/dev/null; then
    ok "roster documents $base"
  else
    bad "roster missing a row for $base"
  fi

  src="$REPO/tests/probes/$base"
  if grep -qE '^(# |// )LIVE_SUBJECT:' "$src"; then
    ok "$base declares LIVE_SUBJECT"
  else
    bad "$base has LIVE_RUNTIME: yes but no LIVE_SUBJECT line"
    continue
  fi

  subjects=$(sed -nE 's|^(# \|// )LIVE_SUBJECT:[[:space:]]*(.*)$|\2|p' "$src")
  for sub in $subjects; do
    if [ -e "$REPO/$sub" ]; then
      ok "$base subject exists: $sub"
    else
      bad "$base declares a LIVE_SUBJECT that no longer exists: $sub"
    fi
  done
done

# An empty LIVE_SUBJECT is a deliberate statement (the red is cleared by a
# live-state action, never a repo edit), so at least one probe must carry one —
# otherwise someone has "helpfully" invented a subject for gate-6.
EMPTY_SUBJ=0
for base in "${TAGGED[@]}"; do
  s=$(sed -nE 's|^(# \|// )LIVE_SUBJECT:[[:space:]]*(.*)$|\2|p' "$REPO/tests/probes/$base")
  [ -z "${s// /}" ] && EMPTY_SUBJ=$((EMPTY_SUBJ+1))
done
if [ "$EMPTY_SUBJ" -ge 1 ]; then
  ok "at least one probe declares an EMPTY LIVE_SUBJECT (live-state-cleared red)"
else
  bad "no probe declares an empty LIVE_SUBJECT — gate-6's live-state-only red lost its marker"
fi

# ═══ 2. Runner: tier partition, untagged default, stamp-on-fail ═════════════
SB="$TMPROOT/sandbox"
mkdir -p "$SB/scripts" "$SB/tests/probes" "$SB/home/.claude/gsd-core"
cp "$REPO/scripts/run-probes.sh" "$SB/scripts/run-probes.sh"
echo "9.9.9" > "$SB/home/.claude/gsd-core/VERSION"

# Fixture tag lines are EMITTED, never written as literals at column 0.
# A heredoc would put `# LIVE_RUNTIME: yes` at line-start inside THIS file, and
# run-probes.sh greps whole files for `^(# |// )LIVE_RUNTIME: yes` — so the
# fixtures would classify this probe itself into the live tier. Caught by this
# probe's own roster-parity assertion on its first run; kept as an emitted form
# so the trap cannot reopen. Same reasoning for the SAFE_FOR_LIVE literals.
_SFL='SAFE_FOR_LIVE'; _LRT='LIVE_RUNTIME'; _LSJ='LIVE_SUBJECT'
{ printf '#!/bin/bash\n'
  printf '# %s: yes\n' "$_SFL"
  printf 'echo "alpha ran"; exit 0\n'
} > "$SB/tests/probes/probe-alpha.sh"          # untagged for LIVE_RUNTIME → hermetic
{ printf '#!/bin/bash\n'
  printf '# %s: yes\n' "$_SFL"
  printf '# %s: yes\n' "$_LRT"
  printf '# %s: dhx/thing.js\n' "$_LSJ"
  printf 'echo "beta ran"; exit 1\n'
} > "$SB/tests/probes/probe-beta.sh"           # live tier, and it FAILS (stamp-on-fail cell)
{ printf '#!/bin/bash\n'
  printf '# %s: no\n' "$_SFL"
  printf 'echo "gamma ran"; exit 0\n'
} > "$SB/tests/probes/probe-gamma.sh"          # excluded from both tiers
chmod +x "$SB"/tests/probes/*.sh

run_sb() { OUT=$(cd "$SB" && HOME="$SB/home" bash scripts/run-probes.sh "$@" 2>&1); RC=$?; }

# Case A — hermetic tier: alpha (untagged → no) runs, beta does not.
run_sb --filter SAFE_FOR_LIVE=yes --filter LIVE_RUNTIME=no
chk "$(grep -q 'alpha ran' <<<"$OUT" && echo yes || echo no)" \
    "[A] hermetic tier RUNS the untagged probe (fail-toward-running default)"
chk "$(grep -q 'beta ran' <<<"$OUT" && echo no || echo yes)" \
    "[A] hermetic tier EXCLUDES the LIVE_RUNTIME probe"
chk "$([ "$RC" -eq 0 ] && echo yes || echo no)" \
    "[A] hermetic tier exits 0 (beta's red does not reach it)"

# Case B — live tier + stamp, with a FAILING probe.
run_sb --filter SAFE_FOR_LIVE=yes --filter LIVE_RUNTIME=yes --stamp
chk "$(grep -q 'beta ran' <<<"$OUT" && echo yes || echo no)" \
    "[B] live tier RUNS the LIVE_RUNTIME probe"
chk "$(grep -q 'alpha ran' <<<"$OUT" && echo no || echo yes)" \
    "[B] live tier EXCLUDES the hermetic probe"
chk "$([ "$RC" -ne 0 ] && echo yes || echo no)" \
    "[B] live tier propagates the red as a non-zero exit"

STAMP="$SB/tests/probes/.results/live-tier/status.json"
if [ -f "$STAMP" ]; then
  ok "[B] stamp WRITTEN despite the failure (no-deadlock invariant)"
  if command -v jq >/dev/null 2>&1; then
    chk "$([ "$(jq -r '.gsd_version' "$STAMP")" = "9.9.9" ] && echo yes || echo no)" \
        "[B] stamp records the gsd-core version it ran against"
    chk "$(jq -e '.failing | index("probe-beta.sh")' "$STAMP" >/dev/null 2>&1 && echo yes || echo no)" \
        "[B] stamp names the failing probe"
  else
    echo "SKIP jq absent — stamp content not parsed"
  fi
else
  bad "[B] stamp NOT written on failure — a slow live red would deadlock every commit"
fi

# Case C — bare invocation must still run BOTH tiers (no silent coverage loss
# for health.sh --probes / sync-public-mirror.sh).
run_sb
chk "$(grep -q 'alpha ran' <<<"$OUT" && grep -q 'beta ran' <<<"$OUT" && echo yes || echo no)" \
    "[C] bare invocation still runs hermetic AND live probes"
chk "$(grep -q 'gamma ran' <<<"$OUT" && echo no || echo yes)" \
    "[C] bare invocation still honours SAFE_FOR_LIVE=yes (gamma excluded)"

# Case D — bad value is refused, not silently ignored.
run_sb --filter LIVE_RUNTIME=maybe
chk "$([ "$RC" -eq 2 ] && echo yes || echo no)" "[D] --filter LIVE_RUNTIME=maybe exits 2"

# ═══ 3. Gate: check #8c blocks on a stale stamp, passes on a fresh one ══════
GR="$TMPROOT/gaterepo"
mkdir -p "$GR/scripts" "$GR/tests/probes" "$GR/docs" "$GR/home/.claude/gsd-core"
cp "$REPO/scripts/verify-hook-patterns.sh" "$GR/scripts/"
mkdir -p "$GR/scripts/lib" && cp "$REPO/scripts/lib/hp028-scan.awk" "$GR/scripts/lib/"   # check #5 detector; the gate fails CLOSED without it
cp "$REPO/scripts/run-probes.sh" "$GR/scripts/"
chmod +x "$GR"/scripts/*.sh
: > "$GR/docs/hook-patterns.md"
echo "9.9.9" > "$GR/home/.claude/gsd-core/VERSION"
cp "$SB/tests/probes/probe-alpha.sh" "$GR/tests/probes/"
git -C "$GR" init -q 2>/dev/null
git -C "$GR" config user.email probe@local >/dev/null 2>&1
git -C "$GR" config user.name probe >/dev/null 2>&1
# Stage a probe file only: arms check #8's trigger, no-ops checks 1-7.
git -C "$GR" add -A >/dev/null 2>&1

run_gate() { GOUT=$(cd "$GR" && HOME="$GR/home" bash scripts/verify-hook-patterns.sh 2>&1); GRC=$?; }

# 3a — no stamp at all reads as stale → block, and the message must name the fix.
run_gate
chk "$([ "$GRC" -ne 0 ] && echo yes || echo no)" \
    "[8c] absent stamp BLOCKS (self-bootstraps on a fresh clone)"
chk "$(grep -q -- '--filter LIVE_RUNTIME=yes --stamp' <<<"$GOUT" && echo yes || echo no)" \
    "[8c] block message prints the exact command that clears it"

# 3b — stamp matching the installed version → the gate passes.
mkdir -p "$GR/tests/probes/.results/live-tier"
printf '{"gsd_version": "9.9.9", "ran_at": "x", "passed": 1, "failing": []}\n' \
  > "$GR/tests/probes/.results/live-tier/status.json"
run_gate
chk "$([ "$GRC" -eq 0 ] && echo yes || echo no)" "[8c] fresh stamp PASSES the gate"

# 3c — an outstanding live red is reported but does NOT block an unrelated commit.
# This is the whole point of the split: the 2026-08-19 incident, inverted.
printf '{"gsd_version": "9.9.9", "ran_at": "x", "passed": 0, "failing": ["probe-beta.sh"]}\n' \
  > "$GR/tests/probes/.results/live-tier/status.json"
run_gate
chk "$([ "$GRC" -eq 0 ] && echo yes || echo no)" \
    "[8c] outstanding live red does NOT block a commit that stages none of its subjects"
chk "$(grep -q 'probe-beta.sh' <<<"$GOUT" && echo yes || echo no)" \
    "[8c] outstanding live red is still SURFACED, not swallowed"

# 3d — installed version moves (an install happened) → stale again, block.
echo "9.9.10" > "$GR/home/.claude/gsd-core/VERSION"
run_gate
chk "$([ "$GRC" -ne 0 ] && echo yes || echo no)" \
    "[8c] a gsd-core install re-arms the block until the live tier re-runs"

echo
echo "$pass passed, $fail failed"
exit $((fail > 0 ? 1 : 0))
