#!/usr/bin/env bash
# probe-sigpipe-pipefail-shapes.sh — static lint enforcing the HP-028 invariant
#
# Invariant: dhx/*.sh contains zero `cmd | grep -q PATTERN` shapes outside
# HP-028 reference comments. Such shapes are vulnerable to the SIGPIPE+pipefail
# interaction documented in HP-028 — under `set -o pipefail`, when LHS output
# exceeds the OS pipe buffer (~64 KiB on Linux), `grep -q`'s early exit causes
# the LHS to receive SIGPIPE, the pipeline exits 141, pipefail propagates the
# non-zero status, and the surrounding `if` body silently never runs.
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

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DHX_DIR="$REPO_ROOT/dhx"

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
done < <(grep -rn '| *grep -q' "$DHX_DIR" --include='*.sh' \
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
  echo "HP-028 — SIGPIPE+pipefail breaks 'cmd | grep -q PATTERN' when LHS"
  echo "output exceeds the OS pipe buffer (~64 KiB on Linux). Replace with:"
  echo "  grep -q PAT <<< \"\$VAR\"        # for variable inputs"
  echo "  grep -q PAT < <(cmd args)     # for command outputs"
  echo
  echo "See docs/hook-patterns.md HP-028 for the full pattern, the canonical"
  echo "regression test in probe-restart-plugins-stop-hook.sh scenario [12],"
  echo "and the round-1 (c5e09f3) + round-2 (459df4c) audit history."
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
