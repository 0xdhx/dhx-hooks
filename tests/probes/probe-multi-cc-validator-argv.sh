#!/bin/bash
# probe-multi-cc-validator-argv.sh
#
# SAFE_FOR_LIVE: yes  (fully mktemp-isolated; copies verify-multi-cc-results.sh
#                      into a throwaway REPO-shaped tree with one fixture cell;
#                      never touches the live repo, the live corpus, or ~/.claude)
# RUNTIME: ~2s
#
# INVARIANT: scripts/verify-multi-cc-results.sh takes exactly ONE argument or
# none, and every argv it does not understand exits 2 with a usage line —
# never 0. The adoption run (cross-repo docs/handoffs/*-adoption-ledger.md § H1)
# reads this script's rc 0 as "corpus valid", so a mistyped flag that is
# silently dropped is a green cell nobody measured.
#
# Found 2026-09-19 (2.1.278 adoption ledger, D7): `--all --verbose` and
# `2.1.278 --verbose` both DISCARDED the trailing token and exited 0. The D7
# row said a lone `--verbose` exits 0; it did not — it was tried as a version
# dir and exited 2 — the row read the "does not exist … --verbose" message
# without its rc. Both shapes are asserted here so neither reading can regress.
#
# Shapes (all against a fixture tree holding one valid 9.9.9 cell):
#   accepted : `9.9.9` -> 0            `--all` -> 0          `-h` / `--help` -> 0
#   refused  : `--verbose` -> 2        `-v` -> 2             `abc` -> 2
#              `--all --verbose` -> 2  `9.9.9 --verbose` -> 2
#              `1.2` -> 2  `1.2.3.4` -> 2  (exactly three components — the
#              close-gate reviewer's round-1 counterexamples, 2026-09-19)
#              `''` -> 2  (an explicit empty positional is not an absence —
#              round-2 counterexample; the parser branches on $# so this is
#              the whole non-matching class, not one more list entry)
#              `1.2.3` (absent dir) -> 2 (D-24, pre-existing)
#   each refusal prints a `usage:` line on stderr.
#
# Active mode (no argument) is NOT exercised: it shells out to the CC binary
# for the version and would read the live corpus dir, which this probe must
# not depend on.
#
# Backs:
#   - docs/decisions.md 2026-09-19 row (validator argv discipline)
#   - .planning/backlog/2026-09-19-doc-and-tooling-lags-surfaced-by-the-cc-2-1-278-adoption-run.md
#     (acceptance criterion 1)
#
# Run: bash tests/probes/probe-multi-cc-validator-argv.sh
#
# CC-STDERR-EXEMPT: no real Claude Code binary is ever reached. The one
#   `claude --version` call path (the validator's active mode) is exercised only
#   in the third negative control, against a fixture `claude` on a private PATH
#   that prints the constant "0.0.0 (fixture)" — it loads no settings, so no lint
#   line exists to leak, and nothing here classifies its output beyond the
#   validator's own version grep. Measured 2026-09-19: the net matched this file
#   on that fixture's `claude --version` string alone.
#   Convention: tests/probes/README.md § "A classifier's INPUT is a surface too".

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
PASS=0
FAIL=0

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

assert() {
  local name="$1" cond="$2"
  if [[ "$cond" == "true" ]]; then echo "OK   $name"; PASS=$((PASS+1))
  else echo "FAIL $name"; FAIL=$((FAIL+1)); fi
}

VER="9.9.9"
mkdir -p "$T/scripts" "$T/docs" "$T/tests/probes/.results/v1.3-multi-cc-ver/$VER"
cp "$REPO/scripts/verify-multi-cc-results.sh" "$T/scripts/"
chmod +x "$T/scripts/verify-multi-cc-results.sh"
: > "$T/docs/decisions.md"
printf '{"probe_id":"probe-known-marketplaces-natural-heal","cc_version":"%s","cc_version_match":true,"conclusion":"validated_stable"}\n' \
  "$VER" > "$T/tests/probes/.results/v1.3-multi-cc-ver/$VER/probe-known-marketplaces-natural-heal.json"

# run <args...> -> sets RC and ERR (stderr only; stdout is the validator's silent channel)
run() {
  ERR=$(bash "$T/scripts/verify-multi-cc-results.sh" "$@" 2>&1 >/dev/null); RC=$?
}

echo "=== accepted shapes ==="
run "$VER";  assert "explicit version with a valid cell -> 0"        "$([[ $RC -eq 0 ]] && echo true || echo false)"
run --all;   assert "--all -> 0"                                     "$([[ $RC -eq 0 ]] && echo true || echo false)"
run -h;      assert "-h -> 0"                                        "$([[ $RC -eq 0 ]] && echo true || echo false)"
run --help;  assert "--help -> 0 (the long alias, accepted since D-24)" "$([[ $RC -eq 0 ]] && echo true || echo false)"

echo "=== refused shapes (each: rc 2 + usage line) ==="
refused() {
  local label="$1"; shift
  run "$@"
  assert "$label -> 2"                    "$([[ $RC -eq 2 ]] && echo true || echo false)"
  assert "$label prints a usage line"     "$(grep -q '^usage: ' <<<"$ERR" && echo true || echo false)"
}
refused "lone --verbose"                  --verbose
refused "short unknown -v"                -v
refused "non-version positional 'abc'"    abc
refused "--all --verbose (trailing flag)" --all --verbose
refused "$VER --verbose (trailing flag)"  "$VER" --verbose
refused "three args"                      "$VER" "$VER" "$VER"
refused "two-component '1.2'"             1.2
refused "four-component '1.2.3.4'"        1.2.3.4
refused "explicit empty positional ''"    ""
refused "whitespace positional ' '"       " "
refused "leading-zero-free but 2-dot-suffixed '1.2.'" 1.2.

# The one pre-existing exit-2 path: a well-formed version with no dir. Kept
# distinct from the usage class — its message names the dir, not the usage.
run 1.2.3
assert "well-formed version with no dir -> 2 (D-24)"      "$([[ $RC -eq 2 ]] && echo true || echo false)"
assert "  ...and names the missing dir, not usage"        "$(grep -q 'does not exist' <<<"$ERR" && ! grep -q '^usage: ' <<<"$ERR" && echo true || echo false)"

# Negative control for the trailing-flag class: a copy with the argc guard
# removed must exit 0 on `--all --verbose` (the pre-fix shape), proving the
# assertions above have a tooth and are not passing on the fixture alone.
sed '/^elif (( \$# > 1 )); then$/,+1d' "$T/scripts/verify-multi-cc-results.sh" > "$T/scripts/pre-fix.sh"
grep -q 'unexpected extra argument' "$T/scripts/pre-fix.sh" && echo "WARN: argc-guard mutation did not apply"
PRE_RC=$(bash "$T/scripts/pre-fix.sh" --all --verbose >/dev/null 2>&1; echo $?)
assert "negative control: without the argc guard, --all --verbose -> 0 (the pre-fix false clean)" \
  "$([[ $PRE_RC -eq 0 ]] && echo true || echo false)"

# Negative control for the component-count class: a copy carrying the round-1
# regex (`^[0-9]+(\.[0-9]+)+$`) must ACCEPT `1.2.3.4` against a valid fixture
# dir of that name — the shape the close-gate reviewer produced.
mkdir -p "$T/tests/probes/.results/v1.3-multi-cc-ver/1.2.3.4"
sed "s/\"cc_version\":\"$VER\"/\"cc_version\":\"1.2.3.4\"/" \
  "$T/tests/probes/.results/v1.3-multi-cc-ver/$VER/probe-known-marketplaces-natural-heal.json" \
  > "$T/tests/probes/.results/v1.3-multi-cc-ver/1.2.3.4/probe-known-marketplaces-natural-heal.json"
sed 's/\^\[0-9\]+\\\.\[0-9\]+\\\.\[0-9\]+\$/^[0-9]+(\\.[0-9]+)+$/' "$T/scripts/verify-multi-cc-results.sh" > "$T/scripts/pre-fix-regex.sh"
grep -q '(\\.\[0-9\]+)+\$' "$T/scripts/pre-fix-regex.sh" || echo "WARN: regex mutation did not apply"
PRE2_RC=$(bash "$T/scripts/pre-fix-regex.sh" 1.2.3.4 >/dev/null 2>&1; echo $?)
assert "negative control: with the round-1 regex, 1.2.3.4 -> 0 (the reviewer's counterexample)" \
  "$([[ $PRE2_RC -eq 0 ]] && echo true || echo false)"
run 1.2.3.4
assert "  ...and the fixed script refuses the same dir -> 2" "$([[ $RC -eq 2 ]] && echo true || echo false)"

# Negative control for the empty-positional class: a copy that branches on
# "${1:-}" (the round-2 shape) must read '' as active mode. Active mode shells
# out to `claude --version`; the copy is given a fake `claude` on PATH that
# prints a version with no corpus dir, so active mode's absent-dir arm exits 0
# — exactly the false clean the reviewer observed on the live tree.
mkdir -p "$T/bin"; printf '#!/bin/sh\necho "0.0.0 (fixture)"\n' > "$T/bin/claude"; chmod +x "$T/bin/claude"
sed 's/^if (( \$# == 0 )); then$/if [[ -z "${1:-}" ]]; then/' "$T/scripts/verify-multi-cc-results.sh" > "$T/scripts/pre-fix-argc.sh"
grep -q 'if \[\[ -z "\${1:-}" \]\]; then' "$T/scripts/pre-fix-argc.sh" || echo "WARN: argc mutation did not apply"
PRE3_RC=$(PATH="$T/bin:$PATH" bash "$T/scripts/pre-fix-argc.sh" "" >/dev/null 2>&1; echo $?)
assert "negative control: branching on \"\${1:-}\", '' -> 0 (the round-2 false clean)" \
  "$([[ $PRE3_RC -eq 0 ]] && echo true || echo false)"
PRE3B_RC=$(PATH="$T/bin:$PATH" bash "$T/scripts/verify-multi-cc-results.sh" "" >/dev/null 2>&1; echo $?)
assert "  ...and the fixed script refuses '' -> 2 under the same fake claude" "$([[ $PRE3B_RC -eq 2 ]] && echo true || echo false)"

echo "---"
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
