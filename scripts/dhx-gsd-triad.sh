#!/usr/bin/env bash
# scripts/dhx-gsd-triad.sh — sha256 triad diagnostic for fork-tracked GSD workflow files.
#
# Walks the file set declared in ~/.claude/gsd-local-patches/backup-meta.json (`files` array).
# For each file, prints sha256 across the three layers:
#
#   live      — ~/.claude/gsd-core/<rel>                 (what CC runs)
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
#
# HP-031 declared here because this script CONSUMES the gsd-drift-first-seen.json cache
# (producer-consumer surface — see docs/hook-patterns.md § HP-031). Operator scripts that
# neither produce nor consume HP-031 surfaces (e.g., scripts/dhx-draft-buffer.sh) do not declare.
# Patterns: HP-031

set -uo pipefail

PRISTINE_PREFIX="$HOME/.claude/gsd-pristine"
BACKUP_META="${DHX_TRIAD_BACKUP_META:-$HOME/.claude/gsd-local-patches/backup-meta.json}"

# Env overrides (Plan 16-05 probe-triad-duration-enrichment.sh fixture injection):
#   DHX_DRIFT_CACHE       — defaults to $HOME/.cache/dhx/gsd-drift-first-seen.json
#   DHX_TRIAD_LIVE_ROOT   — defaults to $HOME/.claude/gsd-core (per D-32; gsd-core 1.3.1 rename)
#   DHX_TRIAD_CANONICAL_ROOT — defaults to $HOME/.claude/gsd-local-patches/gsd-core (per D-32; gsd-core 1.3.1 rename)
#   DHX_TRIAD_BACKUP_META — defaults to $HOME/.claude/gsd-local-patches/backup-meta.json (the
#                           files[] source). Added 2026-06-08: once the worktree-safety fork was
#                           retired (live backup-meta files[] → []), the probe — which fixtured only
#                           the live/canonical CONTENT roots, not the file LIST — went red (the triad
#                           exits at the empty-files[] guard before any DRIFT row). Overriding the
#                           meta lets the probe stage its own tracked-file list, decoupling it from
#                           live fork-retirement state.
DRIFT_CACHE="${DHX_DRIFT_CACHE:-$HOME/.cache/dhx/gsd-drift-first-seen.json}"
# INVARIANT (gsd-core 1.3.1, 2026-06-05): these defaults MUST track the live gsd
# runtime dir name AND the backup-meta.json files[] dialect (which @opengsd/gsd-core
# @1.3.1 migrated get-shit-done/* → gsd-core/*). The rel-strip below depends on it.
# probe-gsd-roots-resolve.sh asserts these literals.
LIVE_ROOT="${DHX_TRIAD_LIVE_ROOT:-$HOME/.claude/gsd-core}"
CANONICAL_ROOT="${DHX_TRIAD_CANONICAL_ROOT:-$HOME/.claude/gsd-local-patches/gsd-core}"

# D-26: Surface corrupt cache out-of-band; triad is operator-invoked so a WARN is actionable.
# The SessionStart emitter (dhx-gsd-drift-surface.sh) stays silent-on-corrupt (HP-015 hot-path discipline).
if [ -f "$DRIFT_CACHE" ] && command -v jq >/dev/null 2>&1 && ! jq -e . "$DRIFT_CACHE" >/dev/null 2>&1; then
  printf 'WARN: drift-cache corrupt, run: rm "%s"; restart claude\n' "$DRIFT_CACHE" >&2
fi

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

# days_unresolved <rel> — emit " (first detected: YYYY-MM-DD, N days unresolved)"
# when DRIFT_CACHE has a matching ISO 8601 timestamp for <rel> and N>=1.
# Silent (empty output) when cache absent, jq absent, no matching entry, or N<1.
# <rel> is the cache key — the bare path under gsd-core/ (e.g. workflows/execute-plan.md).
days_unresolved() {
  local rel="$1"
  [ -f "$DRIFT_CACHE" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local iso
  iso=$(jq -r --arg p "$rel" '.[$p] // empty' "$DRIFT_CACHE" 2>/dev/null)
  [ -n "$iso" ] || return 0
  local then_s now_s diff_d
  # Uses GNU date -d; portable across WSL2/Linux (project requirement); not POSIX-portable.
  then_s=$(date -u -d "$iso" +%s 2>/dev/null) || return 0
  now_s=$(date -u +%s)
  diff_d=$(( (now_s - then_s) / 86400 ))
  [ "$diff_d" -ge 1 ] || return 0
  printf '%s' "(first detected: ${iso%T*}, ${diff_d} days unresolved)"
}

DIVERGED=0
PARTIAL=0
OK_FORKED=0
OK_UNFORKED=0

echo "GSD fork-tracked sha256 triad (12-char prefix)"
echo "  Backup baseline: from_version=$FROM_VERSION, backed_up_at=$BACKED_UP_AT"
echo "  Roots: live=$LIVE_ROOT  canonical=$CANONICAL_ROOT  pristine=$PRISTINE_PREFIX"
echo
printf '  %-40s  %-12s  %-12s  %-12s  %s\n' "file" "live" "canonical" "pristine" "status"
printf '  %-40s  %-12s  %-12s  %-12s  %s\n' "----------------------------------------" "------------" "------------" "------------" "------"

for rel in "${FILES[@]}"; do
  # gsd_rel — the bare path under gsd-core/ (drift-cache key dialect; the cache
  # is keyed bare-rel-under-root, matching this strip — see HP-031).
  # LIVE_ROOT / CANONICAL_ROOT (D-32) already point at the gsd-core subtree,
  # so resolve files relative to gsd_rel; pristine keeps the prefix-based path.
  # NOTE (worktree-safety fork retired 2026-06-05): live backup-meta files[] is now []
  # so this loop does not iterate and the pristine arm below is not reached; the orphan
  # ~/.claude/gsd-pristine/ tree was deleted alongside the retirement. The pristine arm is
  # retained for any FUTURE gsd-core fork — should one be tracked, the layer resolves to
  # gsd-pristine/gsd-core/<rel> and the installer must populate it in the LIVE dir name
  # (NOT papered over with an old-name map: pristine MUST track the live dialect).
  gsd_rel="${rel#gsd-core/}"
  live_hash=$(hash_or_marker "$LIVE_ROOT/$gsd_rel")
  canonical_hash=$(hash_or_marker "$CANONICAL_ROOT/$gsd_rel")
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
    status="DRIFT live!=canonical $(days_unresolved "$gsd_rel")"
    # Trim trailing whitespace so graceful-degrade (cache absent → empty suffix)
    # renders byte-identically to pre-enrichment output (SPEC AC for REQ-06).
    status="${status%"${status##*[![:space:]]}"}"
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
    gsd_rel="${rel#gsd-core/}"
    live_hash=$(hash_or_marker "$LIVE_ROOT/$gsd_rel")
    canonical_hash=$(hash_or_marker "$CANONICAL_ROOT/$gsd_rel")
    if [ "$live_hash" != "$canonical_hash" ]; then
      echo "  cp $LIVE_ROOT/$gsd_rel $CANONICAL_ROOT/$gsd_rel"
    fi
  done
  echo
  echo "Or investigate why the unmirrored edit happened (cf. 2026-05-15 incident)."
  exit 2
fi

exit 0
