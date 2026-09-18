#!/usr/bin/env bash
# probe-sigpipe-pipefail-shapes.sh — static lint enforcing the HP-028 invariant
#
# Invariant: `dhx/`, `tests/probes/` and `scripts/` contain ZERO
# `cmd | grep -[qm] PATTERN` shapes outside HP-028 reference comments. Such
# shapes are vulnerable to the SIGPIPE+pipefail interaction documented in
# HP-028 — under `set -o pipefail`, when the LHS produces more output than the
# reader drains before exiting, the LHS takes SIGPIPE, the pipeline exits 141,
# pipefail propagates the non-zero status, and the surrounding `if` body
# silently never runs.
#
# The failure is NOT symmetric, which is why it survived so long unseen. In an
# `if cmd | grep -q X` the fail-open reads as "no match" and the probe reports
# a false RED, which someone investigates. In the INVERTED shapes —
# `! cmd | grep -q X`, or `cmd | grep -q X && check fail || check pass` — the
# fail-open takes the passing arm, so the guard reports itself HOLDING exactly
# when the thing it forbids is present. That is a false GREEN, and nothing
# looks at it. 21 of the 122 sites converted on 2026-09-18 were that shape.
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
# SCAN ROOTS — all three, zero tolerance, as of 2026-09-18.
#
# 2026-09-18 (later the same day): the root was WIDENED from `tests/probes` to
# `tests`. `tests/lib.sh` and `tests/test-sed-extraction.sh` sit one level above
# the old root and held FOUR live sites the ratchet had never seen — and one of
# them fired: `assert_contains`'s `echo "$actual" | grep -qF "$expected"` took
# SIGPIPE under the suite's `set -euo pipefail`, reporting FAIL on a string that
# was PRESENT (its own diagnostic printed the expected text inside the actual
# output), which blocked a commit at the pre-commit gate. Intermittent — the
# suite passes 5/5 standalone — which is why a green run never surfaced it.
# The root list was a SPELLING of "where this shape lives", and `tests/probes`
# is not the same set as `tests`.
# From April 2026 this lint scanned `dhx/` ALONE, so it reported "audit closed,
# allowlist expected empty" while 191 sites accumulated one directory over. The
# roots widened on 2026-09-18 and the two new ones were RATCHETED against a
# per-file baseline while that population was driven down. It reached zero the
# same day, so the ratchet, its baseline file and the conversion verifier built
# to drive it are all gone: there is nothing left for a floor to hold up, and a
# ratchet kept past zero is a place for a regression to hide inside headroom
# already earned. A new site in ANY of the three roots now simply fails.
#
# Backs:
#   - docs/decisions.md — 2026-04-28 rows "SIGPIPE+pipefail audit sweep"
#                                  round 1 (c5e09f3) and round 2 (459df4c)
#   - docs/decisions.md — 2026-04-28 row "SIGPIPE+pipefail static lint"
#   - docs/decisions.md — 2026-09-18 row (scan roots widened; 191 -> 122 -> 0)
#   - docs/hook-patterns.md — HP-028 (canonical pattern, the two necessary
#                                  legs, workaround table, per-hook fix log)
#
# Mechanism: greps the three roots for the shape below. Filters two classes of
# false positive, both line-oriented:
#   1. Whole-line comments — first non-whitespace character is `#`.
#   2. Lines containing the literal `HP-028` — intentional documentation, and
#      the exemption for a fixture that CONSTRUCTS the broken form on purpose.
#      Two such instruments exist: probe-deferred-check-canonical-classifier.sh
#      6.5 (a deterministic SIGPIPE reproduction) and probe-pii-gate-fail-open
#      .sh (which re-pipelines each live guard as its instrument control). A
#      sweep that "fixes" either disarms it silently, which is why the
#      exemption is a visible token rather than a disguise — a fixture hidden
#      from the lint's own grep is invisible to the next reader too.
#
# Run: bash tests/probes/probe-sigpipe-pipefail-shapes.sh
# Exit 0 = no violations, 1 = one or more violations.

# SAFE_FOR_LIVE: yes   (static lint grepping in-repo `*.sh` for pipeline shapes; no writes)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# The shape, as one definition.
#
# `[^|]` is load-bearing and was added 2026-09-18: the previous `'| *grep -[qm]'`
# matches the second `|` of a LOGICAL OR, so `[[ $rc -eq 124 ]] || grep -q X <<<"$v"`
# — a line already carrying the correct herestring — was reported as a violation.
# Measured 3 such false positives in tests/probes/ at the moment of widening. They
# never occurred in dhx/, which is why the imprecision survived since April.
HP028_SHAPE='[^|]\| *grep -[qm]'  # HP-028 (this line DEFINES the shape)

SCAN_ROOTS=(dhx tests scripts)

# file:line entries to skip. Empty, and expected to stay that way: a deliberate
# construction is exempted by an HP-028 token ON the line, where the next reader
# finds it, rather than in a list they would have to know to consult.
ALLOWLIST=(
  # Example shape — uncomment + customize when an exception is justified:
  # "dhx/example.sh:NN — reason — HP-028 reference"
)

is_allowlisted() {
  local match="$1" entry
  for entry in "${ALLOWLIST[@]}"; do
    [[ "$entry" == "$match"* ]] && return 0
  done
  return 1
}

PASS=0
FAIL=0
VIOLATIONS=()

# Process substitution (canonical HP-028 workaround) so the probe's own LHS
# enumeration never SIGPIPEs under pipefail. Excludes .inactive/ (one-shot HP
# probes — historical references) and .planned/ (drafts not yet symlinked).
SCAN_PATHS=()
for _r in "${SCAN_ROOTS[@]}"; do SCAN_PATHS+=("$REPO_ROOT/$_r"); done

while IFS=: read -r file lineno content; do
  [[ -z "${file:-}" ]] && continue

  trimmed="${content#"${content%%[![:space:]]*}"}"
  [[ "$trimmed" == \#* ]] && continue
  [[ "$content" == *HP-028* ]] && continue

  rel="${file#$REPO_ROOT/}"
  is_allowlisted "$rel:$lineno" && continue

  VIOLATIONS+=("$rel:$lineno: $content")
done < <(grep -rnE "$HP028_SHAPE" "${SCAN_PATHS[@]}" --include='*.sh' \
           --exclude-dir='.inactive' --exclude-dir='.planned' \
           2>/dev/null || true)

if [[ "${#VIOLATIONS[@]}" -eq 0 ]]; then
  echo "OK   no SIGPIPE+pipefail-prone shapes in dhx/, tests/ or scripts/ (HP-028 invariant holds)"
  PASS=1
else
  for v in "${VIOLATIONS[@]}"; do
    echo "FAIL $v"
    FAIL=$((FAIL + 1))
  done
  echo
  echo "HP-028 — SIGPIPE+pipefail breaks 'cmd | grep -q PAT' (and"
  echo "'cmd | grep -m N PAT') when the reader exits before draining the"  # HP-028 (help text)
  echo "producer. Replace with, BY PRODUCER:"
  echo "  grep -q PAT <<<\"\$VAR\"                 # echo \"\$VAR\" or printf '%s\\n' \"\$VAR\""
  echo "  grep -q PAT < <(printf '%s' \"\$VAR\")   # printf '%s' — NO trailing newline"
  echo "  grep -q PAT < <(cmd args)              # any command output"
  echo "  (same swap shape applies to grep -m N)"
  echo
  echo "The producer decides. 'echo \"\$V\"' and 'printf '%s\\n' \"\$V\"' both emit"
  echo "\"\$V\\n\", which is byte-identical to a here-string. 'printf '%s' \"\$V\"'"
  echo "emits NO trailing newline and is NOT — measured 0/5 by byte-compare,"
  echo "and 'printf '%s' \"\" | grep -q '^\$'' returns 1 where the here-string"  # HP-028 (help text)
  echo "returns 0. Using <<< there silently changes the matched input."
  echo
  echo "A deliberate construction of the broken form (a test fixture) is"
  echo "exempted by putting HP-028 in a comment on that line."
  echo
  echo "See docs/hook-patterns.md HP-028 for the full pattern, the two"
  echo "necessary legs (shape AND size), and the canonical regression test in"
  echo "probe-restart-plugins-stop-hook.sh scenario [12]."
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
