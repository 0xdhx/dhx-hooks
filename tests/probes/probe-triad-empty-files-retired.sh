#!/bin/bash
# probe-triad-empty-files-retired.sh — backs the 2026-06-08 triad empty-files[] row.
#
# Asserts scripts/dhx-gsd-triad.sh distinguishes a VALID but empty backup-meta files[]
# (the steady state once every fork is retired → informational, exit 0) from a
# corrupt/missing files[] (genuine setup failure → ERROR, exit 1). Before the fix a
# single guard conflated both into ERROR exit 1, so post-2026-06-05 fork retirement
# (live backup-meta.files[] → []) surfaced a false ERROR on the normal no-forks state.
#
# Uses the DHX_TRIAD_BACKUP_META override (added 2026-06-08) to fixture each meta shape
# under mktemp — never reads the live backup-meta.
#
# INVARIANT: empty files[] (valid array) → exit 0 + NO "ERROR"; unparseable JSON or a
# missing/non-array .files → exit 1 + "ERROR". The triad exit contract is 0=all-OK
# (incl. no-files), 2=DRIFT, 1=setup-failure.
#
# Backs: docs/decisions.md 2026-06-08 "triad empty-files[] classification" row.
# Run: bash tests/probes/probe-triad-empty-files-retired.sh

# SAFE_FOR_LIVE: yes  (mktemp + DHX_TRIAD_BACKUP_META env override; never reads live ~/.claude or the live backup-meta)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TRIAD="$REPO_ROOT/scripts/dhx-gsd-triad.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0

assert() {
  local name="$1"; shift
  if "$@"; then
    echo "OK   $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL $name"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== triad empty-vs-corrupt files[] classification (tmpdir-isolated) ==="

# Capability guard — the override is a 2026-06-08 deliverable.
if ! grep -q 'DHX_TRIAD_BACKUP_META' "$TRIAD" 2>/dev/null; then
  echo "SKIP: scripts/dhx-gsd-triad.sh has no DHX_TRIAD_BACKUP_META override yet"
  echo "---"
  echo "0 passed, 0 failed (capability-guard SKIP)"
  exit 0
fi

run_triad() { # <meta-json-file> -> prints "exit=<code>" then combined output
  local meta="$1" out code
  out=$(DHX_TRIAD_BACKUP_META="$meta" bash "$TRIAD" 2>&1); code=$?
  printf 'exit=%s\n%s' "$code" "$out"
}

# ---- Case A: VALID empty files[] → informational, exit 0, no ERROR ----
EMPTY="$TMPDIR/empty.json"
printf '{"files":[],"from_version":"x","backed_up_at":"y"}\n' > "$EMPTY"
A=$(run_triad "$EMPTY")
assert "[A1] empty files[] exits 0" \
  bash -c '[ "$(printf "%s" "$1" | sed -n "1s/exit=//p")" = "0" ]' _ "$A"
assert "[A2] empty files[] emits NO 'ERROR'" \
  bash -c '! printf "%s" "$1" | grep -qF "ERROR"' _ "$A"
assert "[A3] empty files[] emits the retired/nothing-to-triage notice" \
  bash -c 'printf "%s" "$1" | grep -qiF "nothing to triage"' _ "$A"

# ---- Case B: unparseable JSON → ERROR, exit 1 ----
CORRUPT="$TMPDIR/corrupt.json"
printf '{ this is not json\n' > "$CORRUPT"
B=$(run_triad "$CORRUPT")
assert "[B1] corrupt meta exits 1" \
  bash -c '[ "$(printf "%s" "$1" | sed -n "1s/exit=//p")" = "1" ]' _ "$B"
assert "[B2] corrupt meta emits ERROR" \
  bash -c 'printf "%s" "$1" | grep -qF "ERROR"' _ "$B"

# ---- Case C: missing .files key → ERROR, exit 1 (not an array) ----
NOKEY="$TMPDIR/nokey.json"
printf '{"from_version":"x"}\n' > "$NOKEY"
C=$(run_triad "$NOKEY")
assert "[C1] missing files key exits 1" \
  bash -c '[ "$(printf "%s" "$1" | sed -n "1s/exit=//p")" = "1" ]' _ "$C"
assert "[C2] missing files key emits ERROR" \
  bash -c 'printf "%s" "$1" | grep -qF "ERROR"' _ "$C"

echo "---"
echo "$PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
