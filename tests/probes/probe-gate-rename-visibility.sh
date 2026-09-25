#!/bin/bash
# probe-gate-rename-visibility.sh
#
# SAFE_FOR_LIVE: yes  (fully mktemp-isolated: copies verify-hook-patterns.sh, its
#                      scripts/lib detectors and verify-multi-cc-results.sh into
#                      throwaway `git init` repos with their own user.name/email and
#                      a fake $HOME; never touches the live repo, ~/.claude or ~/.cache)
# RUNTIME: ~3s
#
# INVARIANT: every check in scripts/verify-hook-patterns.sh sees a RENAMED file at its
# new path. With rename detection on (git's default) a `git mv` is status R, and the
# gate's old `--diff-filter=ACM` selectors dropped R — so a renamed hook skipped checks
# #1-#3, a rename into the HP registry skipped #4, a moved corpus cell skipped #9, and a
# renamed probe skipped the set-plus-e lint, even when the rename also edited the file.
# Whole-file checks now share staged_whole_files (--no-renames: the new path is an A);
# the diff-reading set-plus-e lint pairs the rename instead, so a renamed probe's
# PRE-EXISTING set-plus-e line is not re-counted as new (cell D1 guards that).
#
# This file never contains that literal: the lint it tests matches it ANYWHERE
# on an added line (comments and strings included) in a probe that does not enable
# errexit, so the literal is assembled at runtime as $SPE.
#
# Each rename cell first asserts that git really reports the move as R. A fixture that
# degraded to D + A would pass against the old gate too and prove nothing about renames.
# Every blocking cell also asserts the check's own message, not just a non-zero exit,
# so a cell cannot go green because some unrelated check blocked.
#
# The plain (non-rename) controls for #1-#4 are the first coverage those checks have
# had: before this probe nothing in tests/ exercised their messages.
#
# Backs: docs/decisions.md 2026-09-25 row "gate rename visibility" (backlog row
# gate-acm-filter-drops-renames, executed).
#
# Fixture shape (tests/probes/probe-live-runtime-tier.sh § "3. Gate" is the model):
# scaffolding committed with --no-verify, only the case under test staged, and
# scripts/run-probes.sh deliberately NOT copied, so check #8 (the probe tier) stays
# disarmed and cannot block for its own reasons.
#
# Run: bash tests/probes/probe-gate-rename-visibility.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
PASS=0
FAIL=0
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

# A pre-commit hook exports GIT_DIR/GIT_INDEX_FILE; left set, every fixture git call
# below would operate on the REAL repo. Same scrub as run-probes.sh.
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX

chk() {
  if [ "$1" = "yes" ]; then echo "OK   $2"; PASS=$((PASS + 1))
  else echo "FAIL $2"; FAIL=$((FAIL + 1)); fi
}

REGISTRY_OK='## HP-001 Fixture pattern

**Evidence:**
- fixture evidence line'

HOOK_BODY='echo "fixture hook line 1"
echo "fixture hook line 2"
echo "fixture hook line 3"
echo "fixture hook line 4"
exit 0'

CELLDIR="tests/probes/.results/v1.3-multi-cc-ver/9.9.9"

# cell_json <probe_id> <conclusion>
cell_json() {
  printf '{"probe_id":"%s","exit_code":2,"exit_code_convention":"exit_0_means_v1_2_work_warranted",' "$1"
  printf '"cc_version":"9.9.9","cc_version_match":true,"conclusion":"%s"}\n' "$2"
}

# new_fixture [--no-registry] — prints the fixture root. Scaffolding is committed with
# --no-verify; the caller stages only the case under test. mktemp, never a counter:
# callers run this inside $( ), where a counter's increment dies with the subshell.
new_fixture() {
  local t; t=$(mktemp -d "$TMPROOT/fx-XXXXXX")
  mkdir -p "$t/scripts" "$t/docs" "$t/dhx" "$t/tests/probes" "$t/home"
  cp "$REPO/scripts/verify-hook-patterns.sh" "$REPO/scripts/verify-multi-cc-results.sh" "$t/scripts/"
  bash "$REPO/tests/probes/lib/gate-fixture-libs.sh" "$REPO" "$t"   # #5/#5b detectors; the gate fails CLOSED without them
  chmod +x "$t/scripts/verify-hook-patterns.sh" "$t/scripts/verify-multi-cc-results.sh"
  [ "${1:-}" = "--no-registry" ] || printf '%s\n' "$REGISTRY_OK" > "$t/docs/hook-patterns.md"
  : > "$t/docs/decisions.md"
  git -C "$t" init -q
  git -C "$t" config user.email probe@example.invalid
  git -C "$t" config user.name Probe
  git -C "$t" add -A >/dev/null 2>&1
  git -C "$t" commit -q --no-verify -m base >/dev/null 2>&1
  printf '%s' "$t"
}

# seed <fixture> <path> <content> — commit one more file, bypassing the gate.
seed() {
  mkdir -p "$1/$(dirname "$2")"
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add -f -- "$2" >/dev/null 2>&1
  git -C "$1" commit -q --no-verify -m "seed $2" >/dev/null 2>&1
}

# stage <fixture> <path> <content>
stage() {
  mkdir -p "$1/$(dirname "$2")"
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add -f -- "$2" >/dev/null 2>&1
}

is_rename() {
  local ns; ns=$(git -C "$1" diff --cached --name-status -M)   # captured, never piped into grep -q (HP-028)
  grep -qE "^R[0-9]+"$'\t'"$2"$'\t'"$3\$" <<<"$ns" && echo yes || echo no
}

run_gate() { GOUT=$(cd "$1" && HOME="$1/home" bash scripts/verify-hook-patterns.sh 2>&1); GRC=$?; }
blocked_with() { [ "$GRC" -ne 0 ] && grep -qF -- "$1" <<<"$GOUT" && echo yes || echo no; }
passed() { [ "$GRC" -eq 0 ] && echo yes || echo no; }

echo "=== checks #1-#3: dhx hook # Patterns: header ==="

t=$(new_fixture); stage "$t" dhx/new.sh "#!/usr/bin/env bash
$HOOK_BODY"; run_gate "$t"
chk "$(blocked_with "dhx/new.sh is missing a '# Patterns:' header line")" "A-ctl: added hook without a header BLOCKS (#2)"

t=$(new_fixture); stage "$t" dhx/new.sh "#!/usr/bin/env bash
# Patterns: none yet
$HOOK_BODY"; run_gate "$t"
chk "$(blocked_with "dhx/new.sh has a '# Patterns:' header but no HP-NNN IDs")" "A-ctl: header with no HP ids BLOCKS (#2b)"

t=$(new_fixture); stage "$t" dhx/new.sh "#!/usr/bin/env bash
# Patterns: HP-999
$HOOK_BODY"; run_gate "$t"
chk "$(blocked_with "dhx/new.sh references unknown pattern HP-999")" "A-ctl: unresolved HP id BLOCKS (#3)"

t=$(new_fixture); stage "$t" dhx/new.sh "#!/usr/bin/env bash
# Patterns: HP-001
$HOOK_BODY"; run_gate "$t"
chk "$(passed)" "A-ctl: added hook with a resolving header PASSES"

t=$(new_fixture); seed "$t" dhx/old.sh "#!/usr/bin/env bash
# Patterns: HP-001
$HOOK_BODY"
git -C "$t" mv dhx/old.sh dhx/new.sh
printf '%s\n' "#!/usr/bin/env bash" "$HOOK_BODY" > "$t/dhx/new.sh"; git -C "$t" add dhx/new.sh
chk "$(is_rename "$t" dhx/old.sh dhx/new.sh)" "A-ren precondition: git reports the header-stripping move as R"
run_gate "$t"
chk "$(blocked_with "dhx/new.sh is missing a '# Patterns:' header line")" "A-ren: renamed hook that drops its header BLOCKS at the new path"

t=$(new_fixture); seed "$t" dhx/old.sh "#!/usr/bin/env bash
# Patterns: HP-001
$HOOK_BODY"
git -C "$t" mv dhx/old.sh dhx/new.sh
printf '%s\n' "#!/usr/bin/env bash" "# Patterns: HP-999" "$HOOK_BODY" > "$t/dhx/new.sh"; git -C "$t" add dhx/new.sh
chk "$(is_rename "$t" dhx/old.sh dhx/new.sh)" "A-ren precondition: git reports the id-changing move as R"
run_gate "$t"
chk "$(blocked_with "dhx/new.sh references unknown pattern HP-999")" "A-ren: renamed hook with an unresolved HP id BLOCKS"

t=$(new_fixture); seed "$t" dhx/old.sh "#!/usr/bin/env bash
# Patterns: HP-001
$HOOK_BODY"
git -C "$t" mv dhx/old.sh dhx/new.sh
chk "$(is_rename "$t" dhx/old.sh dhx/new.sh)" "A-ren precondition: a pure move is R"
run_gate "$t"
chk "$(passed)" "A-ren: a pure move of a valid hook PASSES (no false block)"

echo "=== check #4: HP registry Evidence ==="

t=$(new_fixture); stage "$t" docs/hook-patterns.md "$REGISTRY_OK

## HP-002 Unevidenced

A claim with no evidence block."; run_gate "$t"
chk "$(blocked_with "docs/hook-patterns.md § HP-002 has no evidence")" "B-ctl: registry section without Evidence BLOCKS"

t=$(new_fixture); stage "$t" docs/hook-patterns.md "$REGISTRY_OK

## HP-002 Evidenced

**Evidence:**
- a second fixture line"; run_gate "$t"
chk "$(passed)" "B-ctl: registry section with Evidence PASSES"

t=$(new_fixture --no-registry); seed "$t" docs/hp-draft.md "$REGISTRY_OK

## HP-002 Unevidenced

A claim with no evidence block."
git -C "$t" mv docs/hp-draft.md docs/hook-patterns.md
chk "$(is_rename "$t" docs/hp-draft.md docs/hook-patterns.md)" "B-ren precondition: the move into the registry path is R"
run_gate "$t"
chk "$(blocked_with "docs/hook-patterns.md § HP-002 has no evidence")" "B-ren: a rename INTO the registry lacking Evidence BLOCKS"

echo "=== check #9: staged multi-cc corpus cells ==="

t=$(new_fixture); stage "$t" "$CELLDIR/probe-known-marketplaces-natural-heal.json" \
  "$(cell_json probe-known-marketplaces-natural-heal banana)"; run_gate "$t"
chk "$(blocked_with "BLOCKED: a multi-cc corpus cell staged in this commit")" "C-ctl: staged invalid cell BLOCKS"

t=$(new_fixture); seed "$t" "$CELLDIR/probe-known-marketplaces-natural-heal.json" \
  "$(cell_json probe-known-marketplaces-natural-heal banana)"
git -C "$t" mv "$CELLDIR/probe-known-marketplaces-natural-heal.json" "$CELLDIR/probe-effort-level-stdin-absent.json"
chk "$(is_rename "$t" "$CELLDIR/probe-known-marketplaces-natural-heal.json" "$CELLDIR/probe-effort-level-stdin-absent.json")" \
  "C-ren precondition: the cell move is R"
run_gate "$t"
chk "$(blocked_with "BLOCKED: a multi-cc corpus cell staged in this commit")" "C-ren: a moved invalid cell BLOCKS"
chk "$(grep -qF "$CELLDIR/probe-effort-level-stdin-absent.json" <<<"$GOUT" && echo yes || echo no)" \
  "C-ren: the block names the cell's NEW path"

t=$(new_fixture); seed "$t" "$CELLDIR/probe-known-marketplaces-natural-heal.json" \
  "$(cell_json probe-known-marketplaces-natural-heal validated_stable)"
git -C "$t" mv "$CELLDIR/probe-known-marketplaces-natural-heal.json" "$CELLDIR/probe-effort-level-stdin-absent.json"
run_gate "$t"
chk "$(passed)" "C-ren: a moved VALID cell PASSES (no false block)"

echo "=== probe set-plus-e lint, whole gate ==="

SPE="set +""e"   # the literal, assembled (see header)
PROBE_BODY="#!/bin/bash
set -uo pipefail
$SPE
echo \"probe line a\"
echo \"probe line b\"
echo \"probe line c\""

t=$(new_fixture); seed "$t" tests/probes/probe-old.sh "$PROBE_BODY"
git -C "$t" mv tests/probes/probe-old.sh tests/probes/probe-new.sh
printf '%s\n' 'echo "appended, not a set flag"' >> "$t/tests/probes/probe-new.sh"; git -C "$t" add tests/probes/probe-new.sh
chk "$(is_rename "$t" tests/probes/probe-old.sh tests/probes/probe-new.sh)" "D1 precondition: the probe move is R"
run_gate "$t"
chk "$(passed)" "D1: a renamed probe's PRE-EXISTING set-plus-e is not re-counted as new"

t=$(new_fixture); seed "$t" tests/probes/probe-old.sh "$PROBE_BODY"
git -C "$t" mv tests/probes/probe-old.sh tests/probes/probe-new.sh
printf '%s\n' "$SPE  # added in the rename commit" >> "$t/tests/probes/probe-new.sh"; git -C "$t" add tests/probes/probe-new.sh
chk "$(is_rename "$t" tests/probes/probe-old.sh tests/probes/probe-new.sh)" "D2 precondition: the probe move is R"
run_gate "$t"
chk "$(blocked_with "tests/probes/probe-new.sh introduces a no-op '$SPE'")" "D2: a set-plus-e ADDED in a rename commit BLOCKS"
chk "$(grep -qF "+$SPE  # added in the rename commit" <<<"$GOUT" && ! grep -qx "+$SPE" <<<"$GOUT" && echo yes || echo no)" \
  "D2: the block quotes only the added set-plus-e, not the moved file's pre-existing one"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
