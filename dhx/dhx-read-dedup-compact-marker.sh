#!/usr/bin/env bash
# dhx-read-dedup-compact-marker.sh — PreCompact companion to dhx-read-dedup.sh (Phase-2a, log-only)
# Patterns: HP-017, HP-022
#
# WHAT: the compaction signal the read-dedup measurement was missing (issue #3 of the 2026-06-25
# council, brief 2026-05-24-read-once-content-dedup-restoration §0). dhx-read-dedup.sh is compaction-
# blind — its 1200s wall-clock TTL ≠ context residency, so it can't tell a genuinely still-in-context
# redundant re-read from a necessary post-compaction reload. This hook records WHEN a compaction
# happened, per session, so read-dedup can log `compaction_since_prior` and the Phase-2a check-in can
# confirm (not just hypothesize) which strict re-reads were redundant-in-context.
#
# HOW: PreCompact fires before `/compact` truncates context (HP-022, plugin-manifest-registered). This
# hook appends one {ts,trigger} marker to the per-session compaction log in the read-dedup STATE dir.
# `trigger` (manual|auto) is captured BUT defensively defaulted to "unknown" — HP-022 only verified
# PreCompact firing on MANUAL /compact; whether it fires on AUTO compaction is unconfirmed for this
# host's CC. Capturing the trigger lets the check-in SEE its own reliability: if 7 days of long sessions
# log zero `auto` markers, that is the signal PreCompact-on-auto is unreliable → fall back to the
# transcript-join / gap_reads proxy. We do not bet the measurement window on an unverified signal.
#
# CONTRACT (cross-process INVARIANT with dhx-read-dedup.sh): both derive the marker path identically —
#   ${DHX_READ_DEDUP_STATE_DIR:-~/.cache/dhx}/read-dedup/compaction/<session_id>.jsonl
# and both honor DHX_READ_DEDUP_STATE_DIR for fixture injection. probe-read-dedup.sh V-COMPACT-* asserts
# the writer here lands a marker the reader there consumes for `compaction_since_prior`.
#
# LOG-ONLY: no stdout (PreCompact is advisory-only — see docs/hook-dev-guide.md; a `hookSpecificOutput`
# payload would fail validation anyway). Always exit 0; a marker-write failure must never break /compact.
#
# Fires: PreCompact (matcher-less). Registered in dhx-plugin/plugins/dhx/hooks/hooks.json — needs a
# session restart / /reload-plugins to take effect (HP-022 registration timing; manifest is NOT hot-
# reloaded mid-session). No config/settings.json drift-sync (manifest is version-controlled inherently).

set -uo pipefail   # NOT -e; a hook error must never break the compaction.

[ "${DHX_READ_DEDUP_DISABLED:-0}" = "1" ] && exit 0

command -v jq >/dev/null 2>&1 || exit 0
INPUT=$(cat)

# One field per line (IFS= read keeps empty fields as empty lines) — session_id + trigger.
{
  IFS= read -r SESSION_ID
  IFS= read -r TRIGGER
} < <(
  printf '%s' "$INPUT" | jq -r '.session_id // "", (.trigger // "unknown")' 2>/dev/null
)

# D-11: session_id is an untrusted filename component. Reject-and-disable (NOT sanitize) if empty /
# path-separator / `..` — never write outside the cache dir or collide IDs. (Mirrors dhx-read-dedup.sh.)
[ -z "${SESSION_ID:-}" ] && exit 0
case "$SESSION_ID" in
  */*|*'\'*|*..*) exit 0 ;;
esac

# Normalize trigger to the known set; anything else → "unknown" (defensive — see header).
case "${TRIGGER:-}" in
  manual|auto) ;;
  *) TRIGGER="unknown" ;;
esac

CACHE_ROOT="${DHX_READ_DEDUP_STATE_DIR:-${HOME}/.cache/dhx}"
COMPACT_DIR="${CACHE_ROOT}/read-dedup/compaction"
COMPACT_FILE="${COMPACT_DIR}/${SESSION_ID}.jsonl"
mkdir -p "$COMPACT_DIR" 2>/dev/null || exit 0

NOW=$(date +%s)

# WR-01: jq escapes the trigger; atomic O_APPEND write (< PIPE_BUF, single logical writer per session).
jq -cn --argjson ts "$NOW" --arg trigger "$TRIGGER" \
   '{ts:$ts,trigger:$trigger}' >> "$COMPACT_FILE" 2>/dev/null || true

exit 0
