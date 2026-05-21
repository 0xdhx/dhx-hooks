#!/bin/bash
# probe-gate-6-canonical-mirror-discipline.sh — Phase 16 (REQ-DRIFT-ACTION-04).
#
# Backs REQ-DRIFT-ACTION-04. Asserts byte-equality across the fork-tracked files
# declared in ~/.claude/gsd-local-patches/backup-meta.json `files[]`. Mirrors the
# Gate 6 "Pass criterion" assertion logic at docs/upstream-proposal-discipline.md
# (the `diff -q` loop over the 4 fork-tracked workflow files) — this probe IS the
# executable form of that doc snippet. The file set is DERIVED from backup-meta.json
# so any future fork-tracked file added to the manifest joins the check set.
#
# Backs: 16-SPEC.md REQ-DRIFT-ACTION-04 + docs/upstream-proposal-discipline.md
#        § Gate 6 Pass criterion.
# Run: bash tests/probes/probe-gate-6-canonical-mirror-discipline.sh
#
# Exit: 0 when every fork-tracked file is byte-equal live ↔ canonical; 2 on any
#       byte-divergence (per SPEC AC "exits 2 on byte-divergence"); 0-with-SKIP
#       when the fork mirror is not installed (backup-meta.json / jq absent).

# SAFE_FOR_LIVE: yes  (read-only diff -q against live ~/.claude/ trees; never writes; reads backup-meta.json files[] to derive the file set so future fork-tracked additions propagate)
set -uo pipefail

BACKUP_META="$HOME/.claude/gsd-local-patches/backup-meta.json"

# SKIP cleanly when the fork mirror isn't installed — the probe is a no-op in
# environments without the gsd-local-patches mirror (fresh CC install, CI).
[ -f "$BACKUP_META" ] || { echo "SKIP: backup-meta.json absent (fork mirror not installed)"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq absent"; exit 0; }

# Derive the file set from backup-meta.json files[] (NOT hard-coded — fork-tracked
# additions propagate automatically).
mapfile -t FILES < <(jq -r '.files[]' "$BACKUP_META" 2>/dev/null)
[ "${#FILES[@]}" -gt 0 ] || { echo "SKIP: backup-meta.json files[] empty or unparseable"; exit 0; }

PASS=0
FAIL=0

echo "=== Gate 6 canonical-mirror byte-equality (${#FILES[@]} fork-tracked files) ==="

# // INVARIANT: live ~/.claude/<f> MUST be byte-equal to its canonical mirror at
# // ~/.claude/gsd-local-patches/<f> for every entry in backup-meta.json files[].
# // Any divergence is the 2026-05-15 / 2026-05-12 unmirrored-edit failure mode.
for f in "${FILES[@]}"; do
  if diff -q "$HOME/.claude/$f" "$HOME/.claude/gsd-local-patches/$f" >/dev/null 2>&1; then
    echo "OK   $f byte-equal"
    PASS=$((PASS + 1))
  else
    echo "FAIL $f diverges (live != canonical)"
    diff "$HOME/.claude/$f" "$HOME/.claude/gsd-local-patches/$f" 2>&1 | head -20
    FAIL=$((FAIL + 1))
  fi
done

echo "---"
echo "$PASS passed, $FAIL failed"
# Exit 2 on divergence per SPEC AC ("exits 2 on byte-divergence"); 0 on full pass.
exit $((FAIL > 0 ? 2 : 0))
