#!/usr/bin/env bash
# scripts/dhx-gsd-triad.sh — sha256 triad diagnostic for fork-tracked GSD workflow files.
#
# Walks the file set declared in ~/.claude/gsd-local-patches/backup-meta.json (`files` array).
# For each file, prints sha256 across the three layers:
#
#   live      — ~/.claude/get-shit-done/<rel>            (what CC runs)
#   canonical — ~/.claude/gsd-local-patches/<rel>        (the fork's patched truth)
#   pristine  — ~/.claude/gsd-pristine/<rel>             (clean upstream baseline, CC 1.40.0+)
#
# Classification per row:
#   OK (forked)    — live == canonical AND canonical != pristine   (patch in sync)
#   OK (unforked)  — live == canonical == pristine                 (no patch, all 3 byte-equal)
#   DRIFT          — live != canonical                             (the 2026-05-15 failure mode)
#   PARTIAL        — live == canonical, but pristine layer differs in an unexpected way
#                    (e.g., pristine missing on pre-1.40 CC; or canonical lost patch markers)
#
# Exit code: 0 if all rows OK; 2 if any row is DRIFT; 1 on setup failure.
# Backs Problem 3 from reports/2026-05-18-canonical-mirror-drift-from-unmirrored-edit.md.

set -uo pipefail

LIVE_PREFIX="$HOME/.claude"
CANONICAL_PREFIX="$HOME/.claude/gsd-local-patches"
PRISTINE_PREFIX="$HOME/.claude/gsd-pristine"
BACKUP_META="$HOME/.claude/gsd-local-patches/backup-meta.json"

if [ ! -f "$BACKUP_META" ]; then
  echo "ERROR: $BACKUP_META not found — fork mirror not installed." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq required but not found in PATH." >&2
  exit 1
fi

if ! command -v sha256sum >/dev/null 2>&1; then
  echo "ERROR: sha256sum required but not found in PATH." >&2
  exit 1
fi

mapfile -t FILES < <(jq -r '.files[]' "$BACKUP_META" 2>/dev/null)
if [ "${#FILES[@]}" -eq 0 ]; then
  echo "ERROR: backup-meta.json files[] is empty or unparseable." >&2
  exit 1
fi

FROM_VERSION=$(jq -r '.from_version // "?"' "$BACKUP_META" 2>/dev/null)
BACKED_UP_AT=$(jq -r '.backed_up_at // "?"' "$BACKUP_META" 2>/dev/null)

hash_or_marker() {
  local path="$1"
  if [ -f "$path" ]; then
    sha256sum "$path" 2>/dev/null | awk '{print substr($1,1,12)}'
  else
    printf '%-12s' '(missing)'
  fi
}

DIVERGED=0
PARTIAL=0
OK_FORKED=0
OK_UNFORKED=0

echo "GSD fork-tracked sha256 triad (12-char prefix)"
echo "  Backup baseline: from_version=$FROM_VERSION, backed_up_at=$BACKED_UP_AT"
echo "  Roots: live=$LIVE_PREFIX  canonical=$CANONICAL_PREFIX  pristine=$PRISTINE_PREFIX"
echo
printf '  %-40s  %-12s  %-12s  %-12s  %s\n' "file" "live" "canonical" "pristine" "status"
printf '  %-40s  %-12s  %-12s  %-12s  %s\n' "----------------------------------------" "------------" "------------" "------------" "------"

for rel in "${FILES[@]}"; do
  live_hash=$(hash_or_marker "$LIVE_PREFIX/$rel")
  canonical_hash=$(hash_or_marker "$CANONICAL_PREFIX/$rel")
  pristine_hash=$(hash_or_marker "$PRISTINE_PREFIX/$rel")

  if [ "$live_hash" = "$canonical_hash" ]; then
    if [ "$canonical_hash" = "$pristine_hash" ]; then
      status="OK (unforked)"
      OK_UNFORKED=$((OK_UNFORKED + 1))
    elif [ "$pristine_hash" = "$(printf '%-12s' '(missing)')" ]; then
      status="PARTIAL (no pristine)"
      PARTIAL=$((PARTIAL + 1))
    else
      status="OK (forked)"
      OK_FORKED=$((OK_FORKED + 1))
    fi
  else
    status="DRIFT live!=canonical"
    DIVERGED=$((DIVERGED + 1))
  fi

  printf '  %-40s  %-12s  %-12s  %-12s  %s\n' "$rel" "$live_hash" "$canonical_hash" "$pristine_hash" "$status"
done

echo
TOTAL="${#FILES[@]}"
echo "Summary: $TOTAL files | $OK_FORKED forked-ok | $OK_UNFORKED unforked-ok | $PARTIAL partial | $DIVERGED diverged"

if [ "$DIVERGED" -gt 0 ]; then
  echo
  echo "Fix-A: cp the live file(s) to canonical to restore byte-equality:"
  for rel in "${FILES[@]}"; do
    live_hash=$(hash_or_marker "$LIVE_PREFIX/$rel")
    canonical_hash=$(hash_or_marker "$CANONICAL_PREFIX/$rel")
    if [ "$live_hash" != "$canonical_hash" ]; then
      echo "  cp $LIVE_PREFIX/$rel $CANONICAL_PREFIX/$rel"
    fi
  done
  echo
  echo "Or investigate why the unmirrored edit happened (cf. 2026-05-15 incident)."
  exit 2
fi

exit 0
