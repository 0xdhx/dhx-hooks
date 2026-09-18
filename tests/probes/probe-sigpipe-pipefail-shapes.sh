#!/usr/bin/env bash
# probe-sigpipe-pipefail-shapes.sh — static lint enforcing the HP-028 invariant
#
# Invariant: dhx/*.sh contains zero `cmd | grep -[qm] PATTERN` shapes outside
# HP-028 reference comments. Such shapes are vulnerable to the SIGPIPE+pipefail
# interaction documented in HP-028 — under `set -o pipefail`, when LHS output
# exceeds the OS pipe buffer (~64 KiB on Linux), `grep -q`/`grep -m N`'s early
# exit causes the LHS to receive SIGPIPE, the pipeline exits 141, pipefail
# propagates the non-zero status, and the surrounding `if` body silently never
# runs.
#
# Scope rationale (narrow extension, 2026-04-28): the lint targets `grep -q`
# and `grep -m N` because both are structurally always used as truth-signal
# readers in `if` conditions — exactly the surface where pipefail propagation
# is load-bearing. Other early-exit readers HP-028 documents (`head -N`,
# `awk '/PAT/{exit}'`, `sed '/PAT/q'`) are overwhelmingly used in capture
# contexts (`$(... | head -N)`, often guarded by `|| true`) where the
# pipeline's exit code doesn't propagate to control flow. A static lint
# can't reliably classify capture-vs-test surroundings, so extending the
# regex to those shapes would generate false positives without catching new
# real bugs. HP-028 documents the broader class for reader awareness; the
# lint enforces only the shapes with concrete SIGPIPE-bites-control-flow
# evidence (rounds 1 + 2, commits c5e09f3 + 459df4c).
#
# Backs:
#   - docs/decisions.md — 2026-04-28 row "SIGPIPE+pipefail audit sweep — round 1"
#                                  (commit c5e09f3, 4 hooks)
#   - docs/decisions.md — 2026-04-28 row "SIGPIPE+pipefail audit sweep — round 2"
#                                  (commit 459df4c, 4 hooks, audit closed)
#   - docs/decisions.md — 2026-04-28 row "SIGPIPE+pipefail static lint"
#                                  (this probe — converts HP-028 from a
#                                  documented runtime assumption into an
#                                  enforced invariant)
#   - docs/hook-patterns.md — HP-028 (canonical pattern, workaround table,
#                                  per-hook fix log)
#
# Mechanism: scans dhx/*.sh for the literal `| *grep -q` regex (BRE — same
# expression used by the round-1/round-2 audit greps). Filters two classes
# of false positive:
#   1. Whole-line comments — line whose first non-whitespace char is `#`.
#      Comments in dhx-restart-plugins-stop.sh:5,27 and
#      dhx-deferred-check.sh:183 are documentation, not shell.
#   2. Lines containing the literal `HP-028` — intentional documentation of
#      the pattern (e.g., the HP-028 anchor in dhx-restart-plugins-stop.sh:5).
# Both filters are line-oriented; a hook author who legitimately wants to put
# `| grep -q` inside a heredoc body (rare) must add an HP-028 reference
# comment to that line so the lint exempts it.
#
# Allowlist: with the round-2 sweep closed (commit 459df4c), the allowlist is
# expected to be empty. Add `file:line` entries with reason + HP-028 reference
# only when an exception is deliberately reintroduced (e.g., reverting the
# round-2 collapse at dhx-deferred-check.sh:183,195 per the round-2 prompt's
# failure clause).
#
# Run: bash tests/probes/probe-sigpipe-pipefail-shapes.sh
# Exit 0 = no violations, 1 = one or more violations.

# SAFE_FOR_LIVE: yes   (static lint grepping in-repo `dhx/*.sh` for pipeline shapes; no writes)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DHX_DIR="$REPO_ROOT/dhx"

# The shape, as one definition both scans use.
#
# `[^|]` is load-bearing and was added 2026-09-18: the previous `'| *grep -[qm]'`
# matches the second `|` of a LOGICAL OR, so `[[ $rc -eq 124 ]] || grep -q X <<<"$v"`
# — a line already carrying the correct herestring — was reported as a violation.
# Measured 3 such false positives in tests/probes/ at the moment of widening. They
# never occurred in dhx/, which is why the imprecision survived since April.
HP028_SHAPE='[^|]\| *grep -[qm]'  # HP-028 (this line DEFINES the shape)

# Roots scanned, and how strictly.
#   dhx/          — ZERO tolerance (allowlist below, empty)
#   tests/probes/ — RATCHET, see hp028-ratchet-baseline.txt
#   scripts/      — RATCHET
RATCHET_BASELINE="$REPO_ROOT/tests/probes/hp028-ratchet-baseline.txt"

# Count HP-028-shaped sites under a root, applying the same comment and
# HP-028-reference filters the dhx/ scan uses, and emit `<relpath>\t<count>`.
hp028_census() {
  local root="$1"
  grep -rnE "$HP028_SHAPE" "$root" --include='*.sh' \
       --exclude-dir='.inactive' --exclude-dir='.planned' 2>/dev/null \
  | awk -F: -v rr="$REPO_ROOT/" '
      { file=$1; $1=""; $2=""; sub(/^::/,""); content=$0
        t=content; sub(/^[[:space:]]+/,"",t)
        if (t ~ /^#/) next
        if (content ~ /HP-028/) next
        rel=file; sub(rr,"",rel); n[rel]++ }
      END { for (f in n) printf "%s\t%s\n", f, n[f] }' \
  | sort
}

# `--emit-baseline` regenerates hp028-ratchet-baseline.txt from the census
# ABOVE — deliberately the same function the check uses. A separate generator
# could drift from the checker and the ratchet would compare two different
# definitions of "a site" while reporting green.
if [[ "${1:-}" == "--emit-baseline" ]]; then
  {
    echo "# HP-028 ratchet baseline — sites per file in the ratcheted roots."
    echo "# Generated by: bash tests/probes/probe-sigpipe-pipefail-shapes.sh --emit-baseline"
    echo "# This number may only go DOWN. See the ratchet section at the foot of that probe."
    for root in tests/probes scripts; do hp028_census "$REPO_ROOT/$root"; done
  } > "$RATCHET_BASELINE"
  echo "wrote ${RATCHET_BASELINE#$REPO_ROOT/}"
  exit 0
fi

# file:line entries to skip. Empty in the audit-closed state.
ALLOWLIST=(
  # Example shape — uncomment + customize when an exception is justified:
  # "dhx/example.sh:NN — reason — HP-028 reference"
)

is_allowlisted() {
  local match="$1"
  local entry
  for entry in "${ALLOWLIST[@]}"; do
    [[ "$entry" == "$match"* ]] && return 0
  done
  return 1
}

PASS=0
FAIL=0
VIOLATIONS=()

# Process substitution (canonical HP-028 workaround) so the probe's own LHS
# enumeration never SIGPIPEs under pipefail. The grep walks dhx/ excluding
# .inactive/ (one-shot HP probes — historical references) and .planned/
# (drafts not yet symlinked).
while IFS=: read -r file lineno content; do
  [[ -z "${file:-}" ]] && continue

  # Strip leading whitespace; treat lines starting with `#` as comments.
  trimmed="${content#"${content%%[![:space:]]*}"}"
  [[ "$trimmed" == \#* ]] && continue

  # Lines explicitly documenting HP-028 (anchor comments, audit notes).
  [[ "$content" == *HP-028* ]] && continue

  rel="${file#$REPO_ROOT/}"
  if is_allowlisted "$rel:$lineno"; then
    continue
  fi

  VIOLATIONS+=("$rel:$lineno: $content")
done < <(grep -rnE "$HP028_SHAPE" "$DHX_DIR" --include='*.sh' \
           --exclude-dir='.inactive' --exclude-dir='.planned' \
           2>/dev/null || true)

if [[ "${#VIOLATIONS[@]}" -eq 0 ]]; then
  echo "OK   no SIGPIPE+pipefail-prone shapes in dhx/*.sh (HP-028 invariant holds)"
  PASS=1
else
  for v in "${VIOLATIONS[@]}"; do
    echo "FAIL $v"
    FAIL=$((FAIL + 1))
  done
  echo
  echo "HP-028 — SIGPIPE+pipefail breaks 'cmd | grep -q PATTERN' (and"
  echo "'cmd | grep -m N PATTERN') when LHS output exceeds the OS pipe"  # HP-028 (help text)
  echo "buffer (~64 KiB on Linux). Replace with:"
  echo "  grep -q PAT <<< \"\$VAR\"        # for variable inputs"
  echo "  grep -q PAT < <(cmd args)     # for command outputs"
  echo "  (same swap shape applies to grep -m N)"
  echo
  echo "See docs/hook-patterns.md HP-028 for the full pattern, the canonical"
  echo "regression test in probe-restart-plugins-stop-hook.sh scenario [12],"
  echo "and the round-1 (c5e09f3) + round-2 (459df4c) audit history."
fi


# ── Ratchet roots ───────────────────────────────────────────────────────────
# `dhx/` above is zero-tolerance. `tests/probes/` and `scripts/` carry a
# population that PREDATES this lint having any net over them: the scan root was
# `dhx/` alone from April 2026 until 2026-09-18, so the audit reported "closed,
# allowlist expected empty" while 191 sites accumulated one directory over. They
# are ratcheted rather than allowlisted: parking 120 entries in ALLOWLIST would
# convert an unmeasured gap into a measured-and-ACCEPTED one, and this probe
# would keep reporting green while knowingly containing every one of them.
#
# The baseline may only go DOWN. An increase FAILs and names the file. A
# decrease also FAILs — with the new number to write — so every reduction is
# recorded in the commit that earned it and the ratchet cannot silently slip.
if [[ ! -f "$RATCHET_BASELINE" ]]; then
  echo "FAIL ratchet baseline missing: ${RATCHET_BASELINE#$REPO_ROOT/}"
  FAIL=$((FAIL + 1))
else
  CENSUS=$(for root in tests/probes scripts; do hp028_census "$REPO_ROOT/$root"; done)

  # Direction 1 — every site present NOW must be at or below its baseline.
  while IFS=$'\t' read -r relfile cur; do
    [[ -z "${relfile:-}" ]] && continue
    base=$(awk -F'\t' -v f="$relfile" '$1==f {print $2}' "$RATCHET_BASELINE")
    base="${base:-0}"
    if [[ "$cur" -gt "$base" ]]; then
      echo "FAIL ratchet BROKEN — $relfile has $cur HP-028 shapes, baseline $base"
      echo "     A new \`cmd | grep -q\` entered a ratcheted root. Convert it:"  # HP-028 (help text)
      echo "       grep -q PAT <<<\"\$VAR\"        # variable input"
      echo "       grep -q PAT < <(cmd args)     # command output"
      echo "     A deliberate construction of the broken form (a test fixture) is"
      echo "     exempted by putting HP-028 in a comment on that line."
      FAIL=$((FAIL + 1))
    fi
  done <<<"$CENSUS"

  # Direction 2 — every baselined file must still be at its baseline. A file that
  # dropped to ZERO vanishes from the census entirely, so direction 1 is blind to it;
  # without this the ratchet silently keeps headroom it has already earned, and the
  # next peer's regression fits inside it unnoticed.
  while IFS=$'\t' read -r relfile base; do
    [[ -z "${relfile:-}" || "$relfile" == \#* ]] && continue
    [[ -f "$REPO_ROOT/$relfile" ]] || continue
    cur=$(awk -F'\t' -v f="$relfile" '$1==f {print $2}' <<<"$CENSUS")
    cur="${cur:-0}"
    if [[ "$cur" -lt "$base" ]]; then
      echo "FAIL ratchet moved DOWN and was not recorded — $relfile now $cur, baseline $base"
      echo "     Record the win in this commit:"
      echo "       bash tests/probes/probe-sigpipe-pipefail-shapes.sh --emit-baseline"
      FAIL=$((FAIL + 1))
    fi
  done < "$RATCHET_BASELINE"

  if [[ "$FAIL" -eq 0 ]]; then
    echo "OK   ratchet holds for tests/probes/ + scripts/ (baseline matched exactly)"
    PASS=$((PASS + 1))
  fi
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
