#!/usr/bin/env bash
# probe-deferred-gate-disjointness.sh
#
# Backs the 2026-08-08 decisions.md row "deferred-debt gates are file-disjoint
# (keep all three)". gsd-core 1.10.0 gave /gsd-complete-milestone a ninth
# auditOpenArtifacts category, `deferred_items`, which surfaces unresolved
# entries from `.planning/phases/<phase>/deferred-items.md` with the [R]/[A]/[C]
# prompt. That lands on the SAME command two dhx gates already guard, which
# raised a redundancy question: is a dhx gate now duplicating upstream?
#
# The 2026-08-08 investigation answered no, on the grounds that the three gates
# read three DIFFERENT files written by three DIFFERENT producers:
#
#   dhx-milestone-close-blocker-{pretooluse,check}.sh
#       -> .planning/BACKLOG.md `## Milestone Close` group
#       -> .planning/todos/pending/*.md carrying `urgency: milestone-close`
#       (producer: the operator, via /dhx:capture)
#   dhx-deferred-check.sh
#       -> .planning/phases/*/*-CONTEXT.md `<deferred>` block
#       (producer: the /dhx:discuss template)
#   gsd-core auditOpenArtifacts `deferred_items`
#       -> .planning/phases/<phase>/deferred-items.md
#       (producer: gsd-executor's SCOPE BOUNDARY convention)
#
# "Keep all three" is only sound while that disjointness HOLDS. The moment a dhx
# hook starts reading deferred-items.md, the two surfaces genuinely overlap, the
# keep-both decision is void, and it should be re-litigated rather than silently
# inherited. That is what this probe guards: it is a decision-premise probe, not
# a behavioural one. If it reds, re-open the decisions row — do not delete the
# assertion.
#
# INVARIANT: no dhx hook may read `deferred-items.md` while the 2026-08-08
# keep-all-three decision stands. Upstream owns that file exclusively.
#
# Run: bash tests/probes/probe-deferred-gate-disjointness.sh

# SAFE_FOR_LIVE: yes   (static grep over committed dhx/*.sh + a READ-ONLY grep of
#   ~/.claude/gsd-core/bin/lib/audit.cjs, skipped when gsd-core is absent; no writes,
#   no fixtures, no live mutation)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DHX_DIR="$REPO_ROOT/dhx"
GSD_LIB="${HOME}/.claude/gsd-core/bin/lib"

PASS=0
FAIL=0
SKIP=0
pass() { echo "OK   $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }
skipf() { echo "SKIP $1"; SKIP=$((SKIP + 1)); }
chk() { if [ "$1" = "yes" ]; then pass "$2"; else fail "$2"; fi; }

MC_PRE="$DHX_DIR/dhx-milestone-close-blocker-pretooluse.sh"
MC_STOP="$DHX_DIR/dhx-milestone-close-blocker-check.sh"
DEFERRED="$DHX_DIR/dhx-deferred-check.sh"

# ── 0. The three hooks under test still exist ────────────────────────────────
for f in "$MC_PRE" "$MC_STOP" "$DEFERRED"; do
  if [ -f "$f" ]; then pass "present: $(basename "$f")"
  else fail "MISSING: $(basename "$f") — the decision's subject moved or was deleted"; fi
done

# ── 1. The load-bearing negative: no dhx hook reads deferred-items.md ────────
# Scoped to the whole dhx/ namespace, not just the three hooks above: the
# disjointness claim is about the dhx side as a WHOLE, so a new hook that starts
# reading the file must red this too.
HITS=$(grep -rlF 'deferred-items' "$DHX_DIR" 2>/dev/null || true)
if [ -z "$HITS" ]; then
  pass "no hook in dhx/ reads deferred-items.md (upstream owns it exclusively)"
else
  fail "dhx hook(s) now reference deferred-items.md — keep-all-three premise VOID, re-open the 2026-08-08 decisions row:"
  printf '       %s\n' $HITS
fi

# ── 2. The dhx close-blocker pair still reads its OWN two surfaces ───────────
for f in "$MC_PRE" "$MC_STOP"; do
  b=$(basename "$f")
  [ -f "$f" ] || continue
  grep -qF 'BACKLOG.md' "$f" && r1=yes || r1=no
  chk "$r1" "$b reads BACKLOG.md (Milestone Close group)"
  grep -qF 'milestone-close' "$f" && r2=yes || r2=no
  chk "$r2" "$b gates on the \`urgency: milestone-close\` flag"
  grep -qF 'todos/pending' "$f" && r3=yes || r3=no
  chk "$r3" "$b scans .planning/todos/pending/"
done

# ── 3. dhx-deferred-check still reads the CONTEXT.md <deferred> block ────────
if [ -f "$DEFERRED" ]; then
  grep -qF 'CONTEXT.md' "$DEFERRED" && r=yes || r=no
  chk "$r" "dhx-deferred-check.sh reads phase CONTEXT.md"
  grep -qF '<deferred>' "$DEFERRED" && r=yes || r=no
  chk "$r" "dhx-deferred-check.sh extracts the <deferred> block"
  # Its item set is CONTEXT.md-scoped; it must not have grown a BACKLOG surface,
  # which is the close-blocker's job (that overlap would be real duplication).
  grep -qF 'BACKLOG.md' "$DEFERRED" && r=no || r=yes
  chk "$r" "dhx-deferred-check.sh does NOT also scan BACKLOG.md (no overlap with the close-blocker)"
fi

# ── 4. Upstream still owns deferred-items.md via the audit category ──────────
# Read-only. Skipped rather than failed when gsd-core is absent: the dhx-side
# invariants above are the ones this repo can actually enforce.
if [ ! -d "$GSD_LIB" ]; then
  skipf "gsd-core absent — upstream ownership of deferred-items.md not checked"
else
  AUDIT="$GSD_LIB/audit.cjs"
  if [ ! -f "$AUDIT" ]; then
    fail "gsd-core present but audit.cjs missing — the deferred_items category moved; re-derive the decision"
  else
    grep -qF "DEFERRED_ITEMS_FILENAME = 'deferred-items.md'" "$AUDIT" && r=yes || r=no
    chk "$r" "gsd-core audit.cjs still owns the deferred-items.md filename constant"
    grep -qF 'deferred_items:' "$AUDIT" && r=yes || r=no
    chk "$r" "gsd-core auditOpenArtifacts still carries the deferred_items category"
    # The scan is phase-DIRECTORY scoped. A file at .planning/phases/deferred-items.md
    # (no phase dir) is NOT scanned — worth pinning, because it silently changes
    # which of the operator's files the [R]/[A]/[C] prompt will surface.
    grep -qF 'scanDeferredItems' "$AUDIT" && r=yes || r=no
    chk "$r" "gsd-core still exposes scanDeferredItems (the phase-directory scanner)"
  fi
fi

echo
echo "$PASS passed, $FAIL failed${SKIP:+, $SKIP skipped}"
[[ "$FAIL" == 0 ]]
