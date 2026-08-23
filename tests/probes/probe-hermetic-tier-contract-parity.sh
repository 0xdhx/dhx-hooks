#!/bin/bash
# probe-hermetic-tier-contract-parity.sh — backs docs/decisions.md 2026-08-23
# "the hermetic tier's two contract surfaces must name the same axis".
#
# THE FAILURE THIS EXISTS TO PREVENT, which already happened once:
#
# The hermetic tier has two documented surfaces. tests/probes/LIVE_RUNTIME.md is
# the OWNING classification rule; scripts/verify-hook-patterns.sh check #8a is a
# one-line summary in the gate that consumes it. Until 2026-08-23 they stated
# DIFFERENT contracts — #8a said "every probe whose verdict is a pure function of
# the repository", the owning rule said only that a /dhx:sym gsd-update cannot
# flip it. Repo-purity is a far stronger claim, and the tier does not hold it.
#
# That gap is not academic: the DHX_RED_COMMIT work read #8a, believed purity, and
# designed a parent-reconstruction oracle on it. Four reconstruction strategies
# were measured; all four produced false reds against a live tree the tier reports
# GREEN, and one is irreducible (verify-hooks.sh asserts this repo's ABSOLUTE
# path, which no copy elsewhere can satisfy). The design was abandoned.
#
# A summary that over-claims is worse than no summary, because it is the surface a
# new consumer reads first. This probe pins the two surfaces to the same axis so
# the next edit to either cannot silently desync them again.
#
# INVARIANT: no surface describing the hermetic tier may claim repo-purity, and
# every such surface must name the gsd-update axis that the tier actually
# guarantees. Enforced here because it is a cross-file prose contract — no
# compiler, linter, or type system can see it.
#
# Run: bash tests/probes/probe-hermetic-tier-contract-parity.sh
# SAFE_FOR_LIVE: yes  (reads two tracked repo files; the negative control operates
#   on a mktemp COPY; never writes the live repo or ~/.claude)
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$REPO/scripts/verify-hook-patterns.sh"
RULE="$REPO/tests/probes/LIVE_RUNTIME.md"

pass=0; fail=0
ok()  { echo "OK   $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; fail=$((fail+1)); }
chk() { if [ "$1" = "yes" ]; then ok "$2"; else bad "$2"; fi; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# The over-claim, as a single literal. Both the assertion and the negative control
# use THIS variable, so the control cannot drift away from what is asserted.
OVERCLAIM='pure function of the repository'

# Extract check #8a's block: from its heading to the start of #8b.
extract_8a() {
  sed -n '/8a HERMETIC TIER/,/8b STAGED LIVE SUBJECTS/p' "$1"
}

# ═══ 1. Both surfaces exist and the extraction is non-vacuous ════════════════
if [ ! -f "$GATE" ]; then bad "gate missing: scripts/verify-hook-patterns.sh"; else ok "gate present"; fi
if [ ! -f "$RULE" ]; then bad "owning rule missing: tests/probes/LIVE_RUNTIME.md"; else ok "owning rule present"; fi

BLOCK_8A="$(extract_8a "$GATE")"
B8_LINES=$(printf '%s\n' "$BLOCK_8A" | grep -c .)
# Guard the extractor itself. If the sed range stops matching (a heading reword),
# every absence-assertion below would pass on an EMPTY string — the exact
# "photograph, not a test" shape this repo has been bitten by before.
chk "$([ "$B8_LINES" -ge 4 ] && echo yes || echo no)" \
    "check #8a block extracted and non-vacuous ($B8_LINES lines) — sed range still matches"

# ═══ 2. Neither surface claims repo-purity ═══════════════════════════════════
chk "$(grep -qF "$OVERCLAIM" <<<"$BLOCK_8A" && echo no || echo yes)" \
    "check #8a does NOT claim \"$OVERCLAIM\""

# The owning rule may DISCUSS the rejected purity claim in its non-guarantees
# section; what it must never do is assert it. Scope the check to "The rule".
RULE_STATEMENT="$(sed -n '/^## The rule/,/^## /p' "$RULE")"
chk "$(grep -qF "$OVERCLAIM" <<<"$RULE_STATEMENT" && echo no || echo yes)" \
    "LIVE_RUNTIME.md § The rule does NOT claim \"$OVERCLAIM\""

# ═══ 3. Both surfaces name the SAME axis ═════════════════════════════════════
chk "$(grep -q 'gsd-update' <<<"$BLOCK_8A" && echo yes || echo no)" \
    "check #8a names the gsd-update axis"
chk "$(grep -qE 'gsd-update.?.? alone' <<<"$RULE_STATEMENT" && echo yes || echo no)" \
    "LIVE_RUNTIME.md § The rule names the gsd-update axis"
chk "$(grep -q 'repository unchanged' <<<"$RULE_STATEMENT" && echo yes || echo no)" \
    "LIVE_RUNTIME.md § The rule still states the repository-unchanged qualifier"

# ═══ 4. The gate points a reader at the owning rule ══════════════════════════
chk "$(grep -q 'LIVE_RUNTIME.md' <<<"$BLOCK_8A" && echo yes || echo no)" \
    "check #8a cross-references tests/probes/LIVE_RUNTIME.md"
chk "$(grep -qi 'NOT repo-purity\|not repo-purity' <<<"$BLOCK_8A" && echo yes || echo no)" \
    "check #8a states the non-guarantee explicitly, not just by omission"

# ═══ 5. The owning rule carries the non-guarantees ═══════════════════════════
NG="$(sed -n '/^## What this tier does NOT guarantee/,/^## Roster/p' "$RULE")"
NG_LINES=$(printf '%s\n' "$NG" | grep -c .)
chk "$([ "$NG_LINES" -ge 15 ] && echo yes || echo no)" \
    "LIVE_RUNTIME.md has a non-guarantees section ($NG_LINES lines)"
chk "$(grep -qi 'read live config\|Read live configuration' <<<"$NG" && echo yes || echo no)" \
    "non-guarantees section names the live-configuration read"
chk "$(grep -qi 'absolute path' <<<"$NG" && echo yes || echo no)" \
    "non-guarantees section names the absolute-path / relocation coupling"
chk "$(grep -q 'reconstructed tree' <<<"$NG" && echo yes || echo no)" \
    "non-guarantees section warns against running the tier on a reconstructed tree"
chk "$(grep -q 'git archive HEAD' <<<"$NG" && grep -q 'git clone --shared' <<<"$NG" && echo yes || echo no)" \
    "non-guarantees section records the measured oracle results"
chk "$(grep -qi 'Considered and rejected' <<<"$NG" && echo yes || echo no)" \
    "the unbounded purity sweep is recorded as considered-and-rejected, not left as latent scope"

# ═══ 6. NEGATIVE CONTROL ═════════════════════════════════════════════════════
# Prove the absence-assertions can actually fire. Re-introduce the historical
# over-claim into a COPY of the gate and confirm the extraction+grep catches it.
# Without this, a reworded heading silently turns section 2 into a no-op.
FAKE="$TMPROOT/gate-with-overclaim.sh"
cp "$GATE" "$FAKE"
python3 - "$FAKE" "$OVERCLAIM" <<'PY'
import io,sys
p,claim=sys.argv[1],sys.argv[2]
s=io.open(p,encoding='utf-8').read()
needle="#        8a HERMETIC TIER"
i=s.index(needle)
j=s.index("\n",i)+1
s=s[:j]+"#           Every probe whose verdict is a "+claim+".\n"+s[j:]
io.open(p,'w',encoding='utf-8').write(s)
PY
FAKE_BLOCK="$(extract_8a "$FAKE")"
chk "$(grep -qF "$OVERCLAIM" <<<"$FAKE_BLOCK" && echo yes || echo no)" \
    "[negative control] a re-introduced over-claim IS detected by this probe's extraction"
chk "$(grep -qF "$OVERCLAIM" <<<"$BLOCK_8A" && echo no || echo yes)" \
    "[negative control] ...and the real gate is still clean, so the control is discriminating"

echo
echo "$pass passed, $fail failed"
exit $((fail > 0 ? 1 : 0))
