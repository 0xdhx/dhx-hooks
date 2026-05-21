#!/usr/bin/env bash
# dhx-gsd-drift-surface.sh — Phase 16 (REQ-DRIFT-ACTION-01/02) SessionStart surfacer.
# Patterns: HP-009, HP-015, HP-031
# Reads ~/.cache/dhx/gsd-drift-first-seen.json and emits a structured, actionable
# GSD canonical-drift block to stderr at session start. Silent when the cache is
# absent / empty / unparseable, or when DHX_SKIP_DRIFT_SURFACE=1.
#
# Block shape: header line + up to 5 drift entries + per-entry cp suggestion +
# truncation footer for 6+ files. NOT a generic "5-line soft cap" — the rendered
# height is bounded by 5 drift entries plus the surrounding scaffolding (header,
# "Run to repair:" separator, cp suggestion lines, and the 6+ truncation footer).
#
# Suppression: DHX_SKIP_DRIFT_SURFACE=1
# Cache override (for SAFE_FOR_LIVE probes): DHX_DRIFT_CACHE=<path>
#
# NOTE: Delete-only drift surfaces via statusline label only; SessionStart block
# does not enumerate deletions.
# Rationale: when GSD trigger fires for count-only reasons (canonical files DELETED
# from fork tree at statusline-wrapper.js:1111), gsdDiverging is never collected
# (statusline-wrapper.js:1195 gate). The cache writer doesn't fire.
# No actionable cp suggestion exists for the delete case (restoration source
# depends on operator intent). Phase 17 STATUSLINE-RAT or a future follow-on may
# address. Bounded by acknowledged surface, not silently deferred work (D-39).
#
# NOTE: Cache lifecycle is statusline-driven by design. At SessionStart, this
# emitter reads the cache as-of-last-statusline-refresh; stale-until-next-refresh
# is acceptable. No runtime re-verification on session start because that would
# duplicate collectGsdDriftDivergingFiles logic for marginal benefit (D-35).
#
# Source-of-truth: ~/repos/hooks/dhx/dhx-gsd-drift-surface.sh
# Symlinked to:    ~/.claude/hooks/dhx-gsd-drift-surface.sh

set -uo pipefail   # NOT -e: must tolerate corrupt JSON per RESEARCH.md A1

# Suppression hook (S2 convention)
[ "${DHX_SKIP_DRIFT_SURFACE:-0}" = "1" ] && exit 0

# Stdin envelope graceful-degrade (HP-009/HP-015 pattern). The persistent cache
# is NOT session-scoped — session_id is not needed for cache reads. Consume and
# validate stdin for parity with the SessionStart convention; exit 0 on parse
# failure so the dispatcher chain is never broken.
INPUT=$(cat 2>/dev/null || true)
printf '%s' "$INPUT" | jq -e . >/dev/null 2>&1 || exit 0

# jq precondition
command -v jq >/dev/null 2>&1 || exit 0

# INVARIANTS (HP-031 — declared here for the drift-surface emitter half of the
# producer/consumer contract):
#   1. The SessionStart drift block fires ONCE per session via the session-start.sh
#      dispatcher (NOT per statusline refresh).
#   2. ~/.cache/dhx/gsd-drift-first-seen.json persists cross-session, keyed by
#      relative path under ~/.claude/get-shit-done/.
#   3. Entries are removed when drift resolves (state-authoritative writer in
#      statusline-wrapper.js drops non-diverging paths by construction); no TTL.
#   4. (Inapplicable to this file; declared in the gate hook) The marker file is
#      the runtime escape valve for the canonical-mirror gate.

# Cache resolution — DHX_DRIFT_CACHE overrides the default for probe fixtures.
CACHE="${DHX_DRIFT_CACHE:-$HOME/.cache/dhx/gsd-drift-first-seen.json}"

# Silent exits: missing cache, or unparseable JSON (HP-015 graceful-degrade —
# RESEARCH.md A1; the triad surfaces the corrupt-cache WARN, not this hot path).
[ -f "$CACHE" ] || exit 0
jq -e . "$CACHE" >/dev/null 2>&1 || exit 0

# Entry count — silent on empty {} (no drift state to surface).
N=$(jq 'length' "$CACHE" 2>/dev/null || echo 0)
case "$N" in
  ''|*[!0-9]*) exit 0 ;;
esac
[ "$N" -gt 0 ] || exit 0

# Read entries oldest-first by ISO timestamp (D-02 — the 6-day-mask anchor must
# render first). Tab-delimited key\tvalue rows into a bash array.
ROWS=()
while IFS= read -r ROW; do
  [ -n "$ROW" ] && ROWS+=("$ROW")
done < <(jq -r 'to_entries | sort_by(.value) | .[] | "\(.key)\t\(.value)"' "$CACHE" 2>/dev/null)

[ "${#ROWS[@]}" -gt 0 ] || exit 0

NOW_S=$(date -u +%s)

# Build the block on stderr (D-03 plain text only — no ANSI escape codes).
{
  # Header (D-05) — ≤80 chars; recognizable ⚠ glyph matches the statusline label.
  printf '⚠ GSD canonical drift — %d file(s) diverged (oldest first)\n' "$N"

  # File lines (D-01, D-04, D-37) — up to 5; two-column aligned.
  i=0
  for ROW in "${ROWS[@]}"; do
    [ "$i" -ge 5 ] && break
    REL="${ROW%%$'\t'*}"
    ISO="${ROW#*$'\t'}"
    # Uses GNU date -d; portable across WSL2/Linux (project requirement);
    # not POSIX-portable.
    THEN_S=$(date -u -d "$ISO" +%s 2>/dev/null || echo "$NOW_S")
    DIFF_D=$(( (NOW_S - THEN_S) / 86400 ))
    [ "$DIFF_D" -lt 0 ] && DIFF_D=0
    ISO_DATE="${ISO%%T*}"
    printf '  %-40s  first seen %s (%dd unresolved)\n' "$REL" "$ISO_DATE" "$DIFF_D"
    i=$((i + 1))
  done
  # Truncation footer for 6+ files (D-04) — literal pointer to the Phase 17 triad.
  if [ "$N" -gt 5 ]; then
    printf '  +%d more — run /dhx:statusline triad\n' "$((N - 5))"
  fi

  # Repair separator + cp suggestions (D-01, D-04) — only up to 5 cp lines, one
  # per rendered file line. Tilde-form paths for clean operator copy-paste.
  printf 'Run to repair:\n'
  i=0
  for ROW in "${ROWS[@]}"; do
    [ "$i" -ge 5 ] && break
    REL="${ROW%%$'\t'*}"
    printf '  cp ~/.claude/get-shit-done/%s ~/.claude/gsd-local-patches/get-shit-done/%s\n' "$REL" "$REL"
    i=$((i + 1))
  done
} >&2

exit 0
