#!/usr/bin/env bash
# dhx-watch-digest.sh — Phase 6.1 (REQ-CROSS-06) SessionStart surfacer.
# Patterns: HP-009, HP-015
# Reads pointer.txt + scans digest.jsonl + emits unsurfaced events to stdout.
# Atomic-rewrites pointer.txt to highest surfaced entry_id.
# Silent if pointer is current (no output -> no SessionStart noise).
# Load-bearing silent-on-no-deltas property per BACKLOG-INTEGRATION section AI triage layer.
#
# D-48 design intent: label_change events emitted by the checker carry
# triage_hint=null per spec line 199 "render compactly". They fall through the
# `*) PREFIX="    "` blank-prefix branch and render alongside (and are subordinate
# to) maintainer/state/system events. Do NOT add a dedicated `label_change)` case --
# the spec's "render compactly" framing means label changes should be visible but
# not visually-elevated; the blank-prefix branch is correct.
#
# D-54 design intent: checker_stale emits per SessionStart while stale. This is a
# problem-state signal, NOT a notification. A cooldown was rejected (option A in
# the discuss fork point) because it would HIDE the broken-timer indicator from
# the single-maintainer user (who IS the sysadmin); "noise IS the signal" framing
# applies. The user suppresses by FIXING the underlying timer/checker issue, not
# by hiding the message.
#
# Suppression: DHX_SKIP_WATCH_DIGEST=1
# Source-of-truth: ~/repos/hooks/dhx/dhx-watch-digest.sh
# Symlinked to:   ~/.claude/hooks/dhx-watch-digest.sh (Task 3 of Plan 4)

set -uo pipefail   # NOT -e: must tolerate corrupt JSONL lines per spec line 358

# Suppression hook
if [ "${DHX_SKIP_WATCH_DIGEST:-0}" = "1" ]; then
  exit 0
fi

# Stdin envelope (HP-015 pattern -- graceful-degrade when missing)
INPUT=$(cat 2>/dev/null || true)
# Note: surfacer doesn't actually use cwd from envelope; reads $WATCH_DIR directly.
# But consume stdin to avoid SIGPIPE upstream.

WATCH_DIR="${DHX_WATCH_DIR:-$HOME/repos/cross-repo/watch}"
DIGEST="$WATCH_DIR/digest.jsonl"
POINTER="$WATCH_DIR/pointer.txt"
META="$WATCH_DIR/meta.json"
WATCHLIST="$WATCH_DIR/watchlist.json"

# Spec section Surfacer logic step 1: missing pointer = 0 (everything surfaces; first-run = recovery).
if [ -f "$POINTER" ]; then
  PTR=$(cat "$POINTER" 2>/dev/null || echo 0)
else
  PTR=0
fi
# Defensive: if pointer is empty or non-numeric, treat as 0
case "$PTR" in
  ''|*[!0-9]*) PTR=0 ;;
esac

# If digest doesn't exist yet, nothing to surface (first-run before any checker fire).
if [ ! -f "$DIGEST" ]; then
  exit 0
fi

# Spec section Surfacer logic steps 2-4: scan, render, atomic-write pointer.
# jq -c per-line; we capture the max entry_id surfaced for the atomic-rewrite step.
MAX_SURFACED="$PTR"
ANY_SURFACED=0
CORRUPT_LINES=0

# Buffer the rendered output so we can prepend optional checker_stale entry.
RENDER_OUT=""

while IFS= read -r LINE; do
  # Skip blank
  [ -z "$LINE" ] && continue
  # Parse the JSON line; on parse failure, count it but skip
  PARSED=$(printf '%s' "$LINE" | jq -c '.' 2>/dev/null) || { CORRUPT_LINES=$((CORRUPT_LINES + 1)); continue; }
  EID=$(printf '%s' "$PARSED" | jq -r '.entry_id // empty' 2>/dev/null)
  case "$EID" in
    ''|*[!0-9]*) CORRUPT_LINES=$((CORRUPT_LINES + 1)); continue ;;
  esac
  # Skip if entry_id <= pointer (already surfaced; bash arithmetic is fine for large ints)
  if [ "$EID" -le "$PTR" ]; then
    continue
  fi
  ANY_SURFACED=1
  if [ "$EID" -gt "$MAX_SURFACED" ]; then
    MAX_SURFACED="$EID"
  fi
  # Extract render fields
  TAG=$(printf '%s' "$PARSED" | jq -r '.tag // "unknown"' 2>/dev/null)
  URL=$(printf '%s' "$PARSED" | jq -r '.url // ""' 2>/dev/null)
  EVENT_TYPE=$(printf '%s' "$PARSED" | jq -r '.event_type // "unknown"' 2>/dev/null)
  TRIAGE=$(printf '%s' "$PARSED" | jq -r '.triage_hint // "null"' 2>/dev/null)
  SUMMARY=$(printf '%s' "$PARSED" | jq -r '.event_summary // ""' 2>/dev/null)
  EMITTED_AT=$(printf '%s' "$PARSED" | jq -r '.emitted_at // ""' 2>/dev/null)

  # Prefix per triage_hint.
  # D-48: label_change events fall through the *) blank-prefix branch (triage_hint=null per spec line 199).
  case "$TRIAGE" in
    maintainer_activity) PREFIX="[M] " ;;
    state_transition)    PREFIX="[S] " ;;
    system_issue)        PREFIX="[!] " ;;
    *)                   PREFIX="    " ;;  # blank prefix — null triage incl. label_change per D-48
  esac

  # Issue/PR ref from URL (last path segment with #)
  REF=$(printf '%s' "$URL" | awk -F/ '{print "#"$NF}')
  REF=${REF:-#?}

  # Truncate summary to 120 chars with ... suffix per spec line 207
  if [ "${#SUMMARY}" -gt 120 ]; then
    SUMMARY="${SUMMARY:0:117}..."
  fi

  # Relative time (best-effort; coarse buckets)
  REL=""
  if [ -n "$EMITTED_AT" ]; then
    EMITTED_TS=$(date -d "$EMITTED_AT" +%s 2>/dev/null || echo 0)
    NOW_TS=$(date +%s)
    DIFF=$((NOW_TS - EMITTED_TS))
    if [ "$EMITTED_TS" -gt 0 ]; then
      if [ "$DIFF" -lt 60 ]; then REL="(just now)";
      elif [ "$DIFF" -lt 3600 ]; then REL="($((DIFF / 60))m ago)";
      elif [ "$DIFF" -lt 86400 ]; then REL="($((DIFF / 3600))h ago)";
      else REL="($((DIFF / 86400))d ago)"; fi
    fi
  fi

  RENDER_OUT="$RENDER_OUT${PREFIX}${TAG} · ${REF} · ${EVENT_TYPE}
    \"${SUMMARY}\" ${REL}
"
done < "$DIGEST"

# Spec section Surfacer logic step 5: checker_stale check.
# OPEN QUESTION 3 resolution: jq min cadence_hours across active items; default 24h if none.
# D-54: emit per-SessionStart while stale (NO cooldown -- "noise IS the signal" per surfacer header).
STALE_HEADER=""
if [ -f "$META" ] && [ -f "$WATCHLIST" ]; then
  LAST_RUN=$(jq -r '.last_check_run_at // ""' "$META" 2>/dev/null)
  if [ -n "$LAST_RUN" ]; then
    LAST_RUN_TS=$(date -d "$LAST_RUN" +%s 2>/dev/null || echo 0)
    NOW_TS=$(date +%s)
    MIN_CADENCE_HOURS=$(jq -r '[.items[] | select(.status == "active") | .cadence_hours] | min // 24' "$WATCHLIST" 2>/dev/null)
    case "$MIN_CADENCE_HOURS" in
      ''|*[!0-9]*) MIN_CADENCE_HOURS=24 ;;
    esac
    THRESHOLD_SECONDS=$((MIN_CADENCE_HOURS * 3600 * 2))
    if [ "$LAST_RUN_TS" -gt 0 ] && [ "$((NOW_TS - LAST_RUN_TS))" -gt "$THRESHOLD_SECONDS" ]; then
      STALE_HEADER="[!] checker_stale · last run ${LAST_RUN} (>2× min cadence ${MIN_CADENCE_HOURS}h)
"
    fi
  fi
fi

# Corrupt-line warning -- single line per session, not per-bad-line (spec line 358).
CORRUPT_WARNING=""
if [ "$CORRUPT_LINES" -gt 0 ]; then
  CORRUPT_WARNING="[!] digest_corrupt · skipped ${CORRUPT_LINES} unparseable line(s)
"
fi

# BACKLOG-INTEGRATION obligation 2: silent on no deltas. EXIT EARLY before any stdout.
if [ "$ANY_SURFACED" -eq 0 ] && [ -z "$STALE_HEADER" ] && [ -z "$CORRUPT_WARNING" ]; then
  exit 0
fi

# Emit (stale + corrupt headers first, then per-event rendered block)
printf '%s%s%s' "$STALE_HEADER" "$CORRUPT_WARNING" "$RENDER_OUT"

# Spec section Surfacer logic step 4: atomic-write new pointer.
if [ "$MAX_SURFACED" != "$PTR" ]; then
  PTR_TMP="$POINTER.tmp"
  printf '%s' "$MAX_SURFACED" > "$PTR_TMP"
  mv "$PTR_TMP" "$POINTER"
fi

exit 0
