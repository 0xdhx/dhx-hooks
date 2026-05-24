#!/bin/bash
# probe-gate-6-cross-repo-parity.sh — Phase 16 (REQ-DRIFT-ACTION-04).
#
# Backs REQ-DRIFT-ACTION-04. Verifies sha256 parity of the Gate 6 section text
# between the hooks-side doc (docs/upstream-proposal-discipline.md) and the
# cross-repo-side canonical (~/repos/cross-repo/docs/governance/
# 2026-05-19-upstream-proposal-discipline.md). VERIFY-ONLY per D-21 / the Q5 SPEC
# boundary lock — this probe surfaces drift but does NOT modify cross-repo.
# If cross-repo is the side that needs updating, that write happens in a
# cross-repo session, never here.
#
# Backs: 16-SPEC.md REQ-DRIFT-ACTION-04 + 16-CONTEXT.md decisions D-21, D-24.
# Run: bash tests/probes/probe-gate-6-cross-repo-parity.sh
#
# Exit: 0 on sha256-match; 2 on mismatch (preserves the REQ-04 boundary lock);
#       0-with-SKIP when either doc is absent.
#
# History: the Gate 6 sections diverged (hooks pre-D-37 prose vs canonical D-37)
# from Phase 16 until Phase 25 (2026-05-24), masked by a now-retired
# DHX_PROBE_ALLOW_CROSS_REPO_DIVERGENCE env-override. Phase 25 D-06 re-synced the
# hooks H3 to canonical byte-for-byte and removed the override — a mismatch now
# means real drift and blocks (exit 2) per the original REQ-04 contract.
#
# CAVEAT: the awk extraction pattern depends on stable H3 ordering in both docs.
# If either doc adds a new H3 between "### Gate 6" and the next "### "/"## "
# heading, widen the awk range. The explicit-next form below is load-bearing —
# see the WHY note above the awk calls.

# SAFE_FOR_LIVE: yes  (read-only sha256 against ~/repos/cross-repo/; never modifies)
set -uo pipefail

HOOKS_DOC="$HOME/repos/hooks/docs/upstream-proposal-discipline.md"
CROSS_REPO_DOC="$HOME/repos/cross-repo/docs/governance/2026-05-19-upstream-proposal-discipline.md"

# SKIP cleanly when either doc is absent — the probe is a no-op when cross-repo
# isn't mounted (CI, fresh checkout).
[ -f "$HOOKS_DOC" ] || { echo "SKIP: hooks-side doc absent ($HOOKS_DOC)"; exit 0; }
[ -f "$CROSS_REPO_DOC" ] || { echo "SKIP: cross-repo doc not mounted ($CROSS_REPO_DOC)"; exit 0; }

# Extract the Gate 6 section from each doc.
#
# WHY the explicit-next form below is load-bearing: a naive awk comma-range
# (start-pattern matching the H3 line, end-pattern an H3/H2 alternation)
# self-terminates on the START line, because the `### Gate 6 ...` header matches
# BOTH the range-start regex AND the range-end alternative. That returns ONLY
# the header line — sha256 of two header-only extractions is identical even when
# the bodies diverge, producing a silent false-pass on real divergence.
# The form below captures the start line with `print; next` (the `next` skips
# end-pattern evaluation on the first iteration), then exits at the next H3/H2.
# // INVARIANT: NEVER replace this with a bare comma-range — it false-passes.
extract_gate6() {
  awk '/^### Gate 6/{p=1; print; next} p && /^### |^## /{exit} p' "$1"
}

hooks_section=$(extract_gate6 "$HOOKS_DOC")
cross_section=$(extract_gate6 "$CROSS_REPO_DOC")

hooks_sha=$(printf '%s' "$hooks_section" | sha256sum | cut -d' ' -f1)
cross_sha=$(printf '%s' "$cross_section" | sha256sum | cut -d' ' -f1)

# // INVARIANT: this probe NEVER writes to ~/repos/cross-repo/ — a cross-repo
# // update happens in a cross-repo session (per Q5 SPEC boundary lock + D-21).
if [ "$hooks_sha" = "$cross_sha" ]; then
  echo "OK   Gate 6 sections sha256-equal across hooks ↔ cross-repo"
  echo "---"
  echo "1 passed, 0 failed"
  exit 0
fi

# Mismatch — real drift. Exit 2 with actionable diff context (REQ-04 boundary lock).
{
  echo "FAIL sha256 mismatch — hooks=$hooks_sha cross-repo=$cross_sha"
  echo "Gate 6 H3 drifted from the cross-repo canonical. Re-sync the hooks H3 to canonical"
  echo "(any cross-repo-side change happens in a cross-repo session). diff context (first 100 lines):"
  diff <(printf '%s' "$hooks_section") <(printf '%s' "$cross_section") | head -100
} >&2
echo "---"
echo "0 passed, 1 failed"
exit 2
