#!/usr/bin/env bash
# tests/probes/lib/gate-fixture-libs.sh — seed a fixture repo with the scripts/lib files the
# pre-commit gate (scripts/verify-hook-patterns.sh) reads from the INDEX.
#
# WHY: the gate's staged lints (#5 HP-028, #5b TAB-IFS) run their detectors from the fixture's
# own index and FAIL CLOSED when a detector is absent. Five probes copy the gate into a fixture
# repo; on 2026-09-25 each carried its own `cp` line, and adding the HP-028 detector left two of
# them red until all five were patched by hand. One list here; a new gate lib is one edit.
# probe-tab-ifs-field-collapse-lint.sh fails when the gate names a scripts/lib path this list
# lacks, so the list cannot fall behind the gate silently (docs/decisions.md 2026-09-25
# gate-check row).
#
# Usage:  bash tests/probes/lib/gate-fixture-libs.sh <repo-root> <fixture-root>
#         bash tests/probes/lib/gate-fixture-libs.sh --list
# The fixture must still `git add` the copies (all five callers stage with `git add -A`).
set -uo pipefail

GATE_FIXTURE_LIBS=(
  scripts/lib/hp028-scan.awk     # check #5 detector
  scripts/lib/tab-ifs-scan.sh    # check #5b detector
)

if [ "${1:-}" = "--list" ]; then
  printf '%s\n' "${GATE_FIXTURE_LIBS[@]}"; exit 0
fi
[ $# -eq 2 ] || { echo "usage: gate-fixture-libs.sh <repo-root> <fixture-root> | --list" >&2; exit 2; }
repo=$1 dest=$2
for f in "${GATE_FIXTURE_LIBS[@]}"; do
  mkdir -p "$dest/$(dirname "$f")" && cp "$repo/$f" "$dest/$f" \
    || { echo "gate-fixture-libs: cannot seed $f into $dest" >&2; exit 1; }
done
exit 0
