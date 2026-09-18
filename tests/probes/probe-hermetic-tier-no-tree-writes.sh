#!/bin/bash
# probe-hermetic-tier-no-tree-writes.sh
#
# SAFE_FOR_LIVE: yes  (sandbox-only: copies run-probes.sh into a mktemp repo and
#                      runs stub probes there; reads the real tests/probes/*.sh
#                      read-only for the class-parity arm; writes nothing outside
#                      its own mktemp root)
# LIVE_RUNTIME: no
# HERMETIC_TIER: yes
# RUNTIME: ~3s
#
# Backs docs/decisions.md 2026-09-17 — the two rows that landed together:
#   hermetic-tier-refuses-live-capture  (run-probes.sh exports DHX_PROBE_HERMETIC)
#   baseline-publish-gate               (probe-subagent-stop-sync.sh)
#
# THE DEFECT THIS GUARDS. On 2026-09-17 a commit staging
# tests/probes/.results/v1.3-multi-cc-ver/2.1.275/probe-effort-level-stdin-absent.json
# could not be made: pre-commit check #8a ran the hermetic tier, the tier ran
# probe-effort-level-stdin-absent.sh, that probe found an arming directory left
# behind by a hand-run two days earlier, escalated itself to live-capture mode,
# and rewrote the staged cell mid-commit. 30-deletion-audit.sh then correctly
# refused, because the candidate had changed between the attempts.
#
# The arming latch is a MODE DISCRIMINATOR — "probe dir exists → capture live" —
# and it is machine-local scratch, so it silently changes what the commit gate
# does. The fix is that run-probes.sh declares the context (DHX_PROBE_HERMETIC=1
# whenever the resolved filter set asks for LIVE_RUNTIME=no) and every
# mode-discriminated probe honours it.
#
# SECTION 3 is the one that matters over time: it is CLASS parity, and it is
# BEHAVIOURAL. Both it and section 2 iterate the same source-scanned set, so a
# third arming-latch probe added later without the guard reds here rather than
# re-creating the 2026-09-17 commit block on some future day — but section 2 only
# greps for the marker, and greps do not catch a guard that is present and wrong.
# See MUTATION COVERAGE below for which arm caught what.
#
# INVARIANT: every probe that gates live-capture mode on an $XDG_RUNTIME_DIR
# arming directory MUST also honour DHX_PROBE_HERMETIC in the same discriminator.
# Not enforceable by the shell — the latch is a filesystem fact and the probes
# are independent scripts — so it is asserted here.
#
# MUTATION COVERAGE (measured 2026-09-17, 3 mutants, all caught BY NAME). The
# first shape of this probe asserted the invariant with a grep for the marker on
# the discriminator line, and that was hollow: it caught the marker being DELETED
# and MISSED it being INVERTED (`== "0"` — token still present, grep still green;
# the mutant was caught only incidentally, by an unrelated assertion). Section 3
# is therefore behavioural and iterates the SAME discovered set, arming each probe
# via its own PROBE_DIR line. The load-bearing assertion is the middle one — the
# probe must SAY it saw the latch and ignored it — because "wrote nothing" is
# satisfied equally by a probe that never noticed the latch, a misspelled arming
# path, or a no-op. Mutants: (1) inverted guard, (2) guard deleted, (3) a NEW latch
# probe added with no guard at all, which is the case the class tooth exists for.
# Re-run those three before changing section 2 or 3; a structural-only rewrite
# passes the suite and silently removes the tooth.
#
# Run: bash tests/probes/probe-hermetic-tier-no-tree-writes.sh

set -uo pipefail

# This probe's negative controls assert that the runner does NOT export the
# marker on bare and live invocations, and that an unmarked armed latch reaches
# the live path. All four are meaningless if the variable is already set in the
# inherited environment — and it IS, on the one run that matters most: inside the
# hermetic tier, where run-probes.sh exports it before invoking every child.
# Inherit-blindness is why this probe passed standalone and went red in the tier.
# The probe sets these per-invocation below; it must never read them ambiently.
unset DHX_PROBE_HERMETIC DHX_PROBE_PUBLISH

PASS=0
FAIL=0
REPO="$(cd "$(dirname "$0")/.." && cd .. && pwd)"

ok()  { echo "OK   $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; FAIL=$((FAIL+1)); }
chk() { if [[ "$2" == "yes" ]]; then ok "$1"; else bad "$1"; fi; }

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

# ═══ 1. run-probes.sh exports DHX_PROBE_HERMETIC on the tier filter, not bare ══
SB="$TMPROOT/sandbox"
mkdir -p "$SB/scripts" "$SB/tests/probes"
cp "$REPO/scripts/run-probes.sh" "$SB/scripts/"
chmod +x "$SB/scripts/run-probes.sh"

# Stub probes: report what the runner exported into their environment.
#
# INVARIANT: the tag lines are ASSEMBLED, never written as heredoc literals. Every
# tag scanner in this repo — run-probes.sh's matches_filter(), and
# probe-live-runtime-tier.sh's roster-parity arm — greps probe files for
# `^(# |// )KEY: value`, with no notion of a heredoc. A stub carrying a column-0
# `# LIVE_RUNTIME: yes` in this file's source therefore classifies THIS probe as a
# live-tier probe, and the parity arm then demands a LIVE_RUNTIME.md roster row for
# a probe that is hermetic. That is not hypothetical: it is what this file did on
# its first tier run. A probe that embeds probe fixtures inline must keep their tags
# out of column 0.
H='#'
mk_stub() {  # $1=path  $2=live-runtime tag value  $3=echo label
  {
    printf '%s!/bin/bash\n' "$H"
    printf '%s SAFE_FOR_LIVE: yes\n'   "$H"
    printf '%s LIVE_RUNTIME: %s\n'     "$H" "$2"
    printf '%s HERMETIC_TIER: yes\n'   "$H"
    [ "$2" = "yes" ] && printf '%s LIVE_SUBJECT:\n' "$H"
    printf 'echo "%s: DHX_PROBE_HERMETIC=${DHX_PROBE_HERMETIC:-unset}"\n' "$3"
    printf 'exit 0\n'
  } > "$1"
  chmod +x "$1"
}

mk_stub "$SB/tests/probes/probe-envcheck.sh" no envcheck

# Second stub, tagged for the LIVE tier. Needed because 1c runs the live filter,
# which SKIPS the hermetic stub above — without this the 1c grep would find no
# output at all and report "unset" as a pass for the wrong reason.
mk_stub "$SB/tests/probes/probe-envcheck-live.sh" yes envcheck-live

run_sb() { OUT=$(cd "$SB" && bash scripts/run-probes.sh "$@" 2>&1); RC=$?; }

# 1a — the gate's own invocation (verify-hook-patterns.sh check #8a, verbatim).
run_sb --filter SAFE_FOR_LIVE=yes --filter LIVE_RUNTIME=no --filter HERMETIC_TIER=yes
chk "[1a] tier invocation exports DHX_PROBE_HERMETIC=1" \
    "$(grep -q 'envcheck: DHX_PROBE_HERMETIC=1' <<<"$OUT" && echo yes || echo no)"

# 1b — a bare invocation must NOT set it. Arming is the operator's deliberate
# publication path; suppressing it everywhere would be the "nobody ever takes a
# cell again" failure the publish gate is explicitly shaped to avoid.
run_sb
chk "[1b] bare invocation leaves DHX_PROBE_HERMETIC unset" \
    "$(grep -q 'envcheck: DHX_PROBE_HERMETIC=unset' <<<"$OUT" && echo yes || echo no)"

# 1c — the live tier must not set it either: LIVE_RUNTIME=yes is the tier whose
# whole point is live dependence.
run_sb --filter SAFE_FOR_LIVE=yes --filter LIVE_RUNTIME=yes
chk "[1c] live tier leaves DHX_PROBE_HERMETIC unset" \
    "$(grep -q 'envcheck-live: DHX_PROBE_HERMETIC=unset' <<<"$OUT" && echo yes || echo no)"

echo "---"

# ═══ 2. CLASS PARITY — every arming-latch probe honours the marker ════════════
# Discovered from source, never from a hardcoded list: a hardcoded roster is the
# shape that goes stale exactly when a third probe is added, which is the case
# this arm exists to catch.
LATCH_PROBES=$(grep -l 'PROBE_DIR="\${XDG_RUNTIME_DIR' "$REPO"/tests/probes/probe-*.sh 2>/dev/null || true)
LATCH_COUNT=$(printf '%s\n' "$LATCH_PROBES" | grep -c . || true)

chk "[2] at least one arming-latch probe found (scan is live, not a stale roster)" \
    "$([ "$LATCH_COUNT" -ge 1 ] && echo yes || echo no)"

while IFS= read -r p; do
  [ -n "$p" ] || continue
  base=$(basename "$p")
  # The discriminator is the `if [[ ! -d "$PROBE_DIR" ...` line; the marker must
  # appear IN it, not merely somewhere in the file (a comment would pass that).
  disc=$(grep -n 'if \[\[ ! -d "\$PROBE_DIR"' "$p" | head -1 | cut -d: -f1)
  if [ -z "$disc" ]; then
    bad "[2] $base — no recognisable arming-dir discriminator to check"
    continue
  fi
  line=$(sed -n "${disc}p" "$p")
  # STRUCTURAL ONLY — a diagnostic, NOT the class tooth. Mutation-measured
  # 2026-09-17: this arm catches the marker being DELETED from a discriminator and
  # MISSES it being INVERTED (`== "0"`, token still present, grep still green). The
  # behavioural arm in section 3 is what actually holds the class; this line just
  # names the file fast when the token is simply gone.
  chk "[2] $base — discriminator mentions DHX_PROBE_HERMETIC (structural)" \
      "$(grep -q 'DHX_PROBE_HERMETIC' <<<"$line" && echo yes || echo no)"
done <<< "$LATCH_PROBES"

echo "---"

# ═══ 3. The marker actually suppresses the tracked-corpus write ═══════════════
# THE CLASS TOOTH, and behavioural on purpose. This loop iterates the SAME
# discovered set section 2 scans — not a hardcoded pair — so a third arming-latch
# probe added later is exercised here automatically rather than inheriting only
# section 2's text match, which mutation showed is hollow against an inverted guard.
#
# Each probe gets its OWN latch armed, derived from its own PROBE_DIR line, then
# runs with the marker set. Three assertions per probe, and the middle one is what
# an inverted guard fails: the probe must SAY it saw the latch and ignored it.
# Without that, "wrote nothing" is satisfied just as well by a probe that never
# noticed the latch, by a misspelled arming path, or by a no-op.
GR="$TMPROOT/gaterepo"
XRD="$TMPROOT/xdg"
mkdir -p "$GR/tests/probes" "$XRD"
git -C "$GR" init -q 2>/dev/null

while IFS= read -r p; do
  [ -n "$p" ] || continue
  base=$(basename "$p")
  # Derive the latch directory from the probe's own PROBE_DIR line, so the arming
  # path can never drift out of step with the probe it is meant to arm.
  latch=$(sed -nE 's|^PROBE_DIR="\$\{XDG_RUNTIME_DIR:-/tmp\}/([^"]+)".*|\1|p' "$p" | head -1)
  if [ -z "$latch" ]; then
    bad "[3] $base — could not derive its arming dir from PROBE_DIR"
    continue
  fi
  mkdir -p "$XRD/$latch"
  chmod 700 "$XRD/$latch"          # probe-subagent-stop-sync.sh asserts 0700 (D-14)
  cp "$p" "$GR/tests/probes/"

  # Both probes resolve their corpus root from `git rev-parse --show-toplevel`, so
  # running them inside $GR keeps every write inside the throwaway root.
  rm -rf "$GR/tests/probes/.results"
  OUT_P=$( cd "$GR" && XDG_RUNTIME_DIR="$XRD" DHX_PROBE_HERMETIC=1 \
             timeout 25 bash "tests/probes/$base" 2>&1 )
  RC_P=$?
  WROTE=$(find "$GR/tests/probes/.results" -type f 2>/dev/null | wc -l)

  chk "[3] $base — armed latch + marker: takes the fixtures path (rc 0)" \
      "$([ "$RC_P" -eq 0 ] && echo yes || echo no)"
  chk "[3] $base — and SAYS it ignored the latch (inverted-guard tooth)" \
      "$(grep -q 'arming dir present but IGNORED' <<<"$OUT_P" && echo yes || echo no)"
  chk "[3] $base — and writes NOTHING under .results/" \
      "$([ "$WROTE" -eq 0 ] && echo yes || echo no)"
done <<< "$LATCH_PROBES"

# Keep the two probes present for the controls below.
cp "$REPO/tests/probes/probe-effort-level-stdin-absent.sh" \
   "$REPO/tests/probes/probe-subagent-stop-sync.sh" "$GR/tests/probes/" 2>/dev/null || true

# 3c — POSITIVE CONTROL. Without the marker the armed latch must reach a
# DIFFERENT path, otherwise the per-probe loop above proves nothing about the
# marker — it would pass just as happily if the latch were broken, or the arming
# dir misspelled, or the probe a no-op. (The loop's own middle assertion covers
# most of that per probe; this control is the end-to-end version, and the two
# together are why an inverted guard now has nowhere to hide.) Measured: the
# unmarked run walks past the discriminator into the
# live arm and stops at the missing flag file with rc 2, so the discriminating
# pair is (rc 0, fixtures-only) vs (rc 2, flag-file-missing) on identical inputs.
CTRL_OUT=$( cd "$GR" && XDG_RUNTIME_DIR="$XRD" timeout 20 \
    bash tests/probes/probe-subagent-stop-sync.sh 2>&1 )
CTRL_RC=$?
chk "[3c] control: unmarked run with an armed latch takes the LIVE path (rc 2)" \
    "$([ "$CTRL_RC" -eq 2 ] && echo yes || echo no)"
chk "[3d] control: and stops at the live arm's flag check, not the discriminator" \
    "$(grep -q 'flag-file-missing-or-empty' <<<"$CTRL_OUT" && echo yes || echo no)"

echo "---"

# ═══ 4. The baseline publish gate ════════════════════════════════════════════
rm -rf "$GR/tests/probes/.results"
( cd "$GR" && XDG_RUNTIME_DIR="$TMPROOT/empty" timeout 20 \
    bash tests/probes/probe-subagent-stop-sync.sh ) >/dev/null 2>&1
UNPUB=$(find "$GR/tests/probes/.results" -name 'fixtures-only-baseline.json' 2>/dev/null | wc -l)
chk "[4a] unpublished run writes NO baseline into the repo corpus" \
    "$([ "$UNPUB" -eq 0 ] && echo yes || echo no)"

( cd "$GR" && XDG_RUNTIME_DIR="$TMPROOT/empty" DHX_PROBE_PUBLISH=1 timeout 20 \
    bash tests/probes/probe-subagent-stop-sync.sh ) >/dev/null 2>&1
PUB=$(find "$GR/tests/probes/.results" -name 'fixtures-only-baseline.json' 2>/dev/null | wc -l)
chk "[4b] DHX_PROBE_PUBLISH=1 DOES write it (the gate is a gate, not a deletion)" \
    "$([ "$PUB" -eq 1 ] && echo yes || echo no)"

echo "---"
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
