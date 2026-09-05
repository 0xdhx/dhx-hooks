#!/bin/bash
# probe-hermetic-tier-cost-axis.sh — backs docs/decisions.md 2026-09-05
# "cost needed its own axis; reclassifying is not deleting".
#
# THE FAILURE THIS EXISTS TO PREVENT:
#
# probe-sync-mirror-publish-gate.sh blocked two unrelated commits by timing out at
# run-probes.sh's 30s per-probe cap. It is O(commits) — five full-history
# filter-repo runs — so it worsens permanently. The tempting fixes were both lies:
# SAFE_FOR_LIVE: no claims the probe is unsafe to run (it is not), LIVE_RUNTIME: yes
# claims an upstream install can flip its verdict (it cannot). Either would have
# bought a scheduling outcome with a false answer — the same defect
# probe-hermetic-tier-contract-parity.sh exists to prevent one axis over.
#
# So cost got its own axis, HERMETIC_TIER, defaulting to `yes` (untagged keeps
# gating commits, matching LIVE_RUNTIME's fail-toward-the-gate principle).
#
# INVARIANT: every probe tagged `HERMETIC_TIER: no` must name a home that actually
# RUNS it. Reclassifying a probe out of the commit gate without rehoming it is
# indistinguishable from deleting its coverage, and nothing else would notice —
# the probe still exists, still passes when run by hand, and simply never runs.
# Enforced here because it is a cross-file contract spanning a shell tag, a gate
# invocation, and a CI workflow; no linter can see it.
#
# RUNTIME: ~2s
# SAFE_FOR_LIVE: yes  (reads tracked repo files; the one run-probes.sh invocation
#   uses --only on a probe it then SKIPS, so no probe body executes)
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="$REPO/scripts/run-probes.sh"
GATE="$REPO/scripts/verify-hook-patterns.sh"
RULE="$REPO/tests/probes/LIVE_RUNTIME.md"
WORKFLOWS="$REPO/.github/workflows"

pass=0; fail=0
ok()  { echo "OK   $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; fail=$((fail+1)); }

# --- 1. the axis exists in the runner, with the documented default -------------
grep -q 'HERMETIC_TIER) _pk_default=yes' "$RUNNER" \
  && ok "[1] run-probes.sh defaults untagged HERMETIC_TIER to yes (keeps gating)" \
  || bad "[1] run-probes.sh has no HERMETIC_TIER=yes untagged default"

grep -q 'LIVE_RUNTIME)  _pk_default=no' "$RUNNER" \
  && ok "[2] the pre-existing LIVE_RUNTIME default survived the refactor" \
  || bad "[2] LIVE_RUNTIME untagged default lost — the two axes must both keep their defaults"

# SAFE_FOR_LIVE must remain WITHOUT a default (untagged is refused, never assumed safe).
grep -qE 'SAFE_FOR_LIVE\)[[:space:]]*_pk_default=' "$RUNNER" \
  && bad "[3] SAFE_FOR_LIVE gained an untagged default — it must stay REFUSED" \
  || ok "[3] SAFE_FOR_LIVE still has no untagged default (stays refused)"

# --- 2. the commit gate actually passes the new key ---------------------------
grep -q -- '--filter SAFE_FOR_LIVE=yes --filter LIVE_RUNTIME=no --filter HERMETIC_TIER=yes' "$GATE" \
  && ok "[4] hermetic tier (check #8a) filters on HERMETIC_TIER=yes" \
  || bad "[4] check #8a does not pass --filter HERMETIC_TIER=yes — the tag is inert"

# --- 3. behavioral: a HERMETIC_TIER:no probe is skipped by that filter ---------
# --only selects before the filter runs, so this prints the SKIP without executing
# any probe body. That is the whole new behaviour, asserted end-to-end.
OUT=$(cd "$REPO" && bash scripts/run-probes.sh --only probe-sync-mirror-publish-gate.sh \
        --filter SAFE_FOR_LIVE=yes --filter LIVE_RUNTIME=no --filter HERMETIC_TIER=yes 2>&1)
grep -q 'SKIP.*probe-sync-mirror-publish-gate.sh.*HERMETIC_TIER' <<<"$OUT" \
  && ok "[5] behavioral: HERMETIC_TIER:no probe is SKIPPED by the hermetic filter" \
  || bad "[5] behavioral: expected a HERMETIC_TIER SKIP line, got: $(head -3 <<<"$OUT" | tr '\n' ' ')"

grep -qE '^Probes: 0 passed, 0 failed' <<<"$OUT" \
  && ok "[6] behavioral: nothing executed — the skip happened before the probe body" \
  || bad "[6] behavioral: expected 0 passed / 0 failed, got: $(grep -E '^Probes:' <<<"$OUT")"

# --- 4. THE INVARIANT: every HERMETIC_TIER:no probe has a home that runs it ----
HOMELESS=0
while IFS= read -r p; do
  [ -n "$p" ] || continue
  base="$(basename "$p")"
  if grep -rqF "$base" "$WORKFLOWS" 2>/dev/null; then
    ok "[7] $base is rehomed — referenced by a workflow that runs it"
  else
    bad "[7] $base is HERMETIC_TIER:no but NO workflow runs it — reclassified into a void"
    HOMELESS=$((HOMELESS+1))
  fi
done < <(grep -rlE '^# HERMETIC_TIER: no' "$REPO/tests/probes/"*.sh 2>/dev/null)

[ "$HOMELESS" -eq 0 ] \
  && ok "[8] no HERMETIC_TIER:no probe was reclassified without a home" \
  || bad "[8] $HOMELESS reclassified probe(s) have no runner"

# --- 5. the owning doc names the axis -----------------------------------------
grep -q '`HERMETIC_TIER`' "$RULE" \
  && ok "[9] LIVE_RUNTIME.md documents the HERMETIC_TIER axis" \
  || bad "[9] the owning classification doc does not mention HERMETIC_TIER"

grep -qE 'HERMETIC_TIER.*cheap enough to run on every commit' "$RULE" \
  && ok "[10] the doc states the axis's actual question (cost), not a liveness claim" \
  || bad "[10] LIVE_RUNTIME.md does not state HERMETIC_TIER's question"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
