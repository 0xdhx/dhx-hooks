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
# Watch-health cache consumer (cross-repo D-08): the SessionStart dispatcher runs
# the cross-repo computer (scripts/watch/dhx-watch-health.cjs) which writes the
# precomputed {timer_stale, polls_degraded, failing_items} verdict to
# ~/.cache/dhx/dhx-watch-health.json. This surfacer READS that cache (never
# recomputes a verdict, D-06) and renders the timer_stale / polls_degraded /
# failing-items sections. The dead-man's-switch timer_stale verdict SUPERSEDES the
# former cadence-based `2x min` checker_stale heartbeat (D-01/D-12) removed here.
#
# Action-required inbox consumer (cross-repo Phase 21 action-state surface): READS
# watchlist.json directly (the same file + fail-silent jq shape as the drift line)
# and renders a distinct, level-triggered "⚠ Action required (N)" section listing
# every CURRENT non-snoozed action_state=="awaiting_us" item until ack/snooze clears
# it. Read-only consumer -- never recomputes action_state/snooze (D-05); does NOT
# touch the 12-key health cache. Distinct from the edge-triggered digest delta block.
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

# Spec section Surfacer logic steps 2-4: scan, render, atomic-write pointer.
# jq -c per-line; we capture the max entry_id surfaced for the atomic-rewrite step.
MAX_SURFACED="$PTR"
ANY_SURFACED=0
CORRUPT_LINES=0

# Buffer the rendered per-event output.
RENDER_OUT=""

# The digest scan only runs when the digest exists (first-run before any checker
# fire has none). The watchlist-derived drift line and the cache-derived health
# sections below are INDEPENDENT of the digest and still render when it is absent,
# so this is a scoped skip of the scan loop -- NOT an early `exit 0` (which would
# swallow drift/health on a no-digest session).
if [ -f "$DIGEST" ]; then
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
fi  # end digest-exists scan guard

# Watch-health cache sections (cross-repo D-08 CONTRACT-01 producer:
# scripts/watch/dhx-watch-health.cjs). Read-only consumer (D-06): NEVER recompute a
# verdict -- the booleans/counts below are precomputed in the cache. Fail-silent
# (D-09): absent / malformed / non-JSON / wrong schema_version / stale computed_at
# all render nothing. This SUPERSEDES the former cadence-based `2x min`
# checker_stale heartbeat (D-01/D-12) -- the timer_stale dead-man's switch in the
# cache replaces it.
#
# TWO DISTINCT STALENESS WINDOWS (do not conflate):
#  1. RENDERER freshness window = 1h (HEALTH_CACHE_STALE_SECONDS below). The cache
#     is recomputed every SessionStart, so a computed_at older than 1h means the
#     computer did not run / the symlink is broken -> hide the WHOLE section.
#  2. The cache's INTERNAL timer_stale verdict (3h default, timer_stale_threshold_hours,
#     cross-repo D-04) -- the dead-man's switch, already decided. We read the boolean.
HEALTH_CACHE="${DHX_WATCH_HEALTH_CACHE:-$HOME/.cache/dhx/dhx-watch-health.json}"
HEALTH_CACHE_STALE_SECONDS=3600   # renderer freshness window (1h), constant #1 above
TIMER_STALE_LINE=""
POLLS_DEGRADED_LINE=""
FAILING_ITEMS_LINE=""
if [ -f "$HEALTH_CACHE" ]; then
  HC=$(jq -c '.' "$HEALTH_CACHE" 2>/dev/null) || HC=""
  if [ -n "$HC" ] && [ "$HC" != "null" ]; then
    HC_SCHEMA=$(printf '%s' "$HC" | jq -r '.schema_version // empty' 2>/dev/null)
    HC_COMPUTED=$(printf '%s' "$HC" | jq -r '.computed_at // empty' 2>/dev/null)
    if [ "$HC_SCHEMA" = "1" ] && [ -n "$HC_COMPUTED" ]; then
      HC_TS=$(date -d "$HC_COMPUTED" +%s 2>/dev/null || echo 0)
      NOW_TS=$(date +%s)
      HC_AGE=$((NOW_TS - HC_TS))
      # Render only when the cache itself is fresh (window #1). Stale -> hide all.
      if [ "$HC_TS" -gt 0 ] && [ "$HC_AGE" -ge 0 ] && [ "$HC_AGE" -lt "$HEALTH_CACHE_STALE_SECONDS" ]; then
        # 1. timer_stale (dead-man's switch verdict, window #2 -- read, not recomputed).
        if [ "$(printf '%s' "$HC" | jq -r '.timer_stale // false' 2>/dev/null)" = "true" ]; then
          TFIRE=$(printf '%s' "$HC" | jq -r '.timer_fire_at // "never"' 2>/dev/null)
          TTHRESH=$(printf '%s' "$HC" | jq -r '.timer_stale_threshold_hours // "?"' 2>/dev/null)
          TIMER_STALE_LINE="[!] watch checker stale · last timer fire ${TFIRE} (>${TTHRESH}h threshold) — the watch checker may be dead.
"
        fi
        # 2. polls_degraded (systemic: auth_error | rate-limit halt | processed:0-with-active).
        if [ "$(printf '%s' "$HC" | jq -r '.polls_degraded // false' 2>/dev/null)" = "true" ]; then
          POLLS_DEGRADED_LINE="[!] watch polls degraded · last run accomplished nothing (auth failure / rate-limit halt / no items processed).
"
        fi
        # 3. failing-items (level-triggered, D-15) -- modeled on the drift line below:
        #    count via jq with non-numeric->0 guard, render only when > 0, one line per item.
        FAIL_COUNT=$(printf '%s' "$HC" | jq '.failing_items | length' 2>/dev/null)
        case "$FAIL_COUNT" in ''|*[!0-9]*) FAIL_COUNT=0 ;; esac
        if [ "$FAIL_COUNT" -gt 0 ]; then
          FAIL_ROWS=$(printf '%s' "$HC" | jq -r '.failing_items[] | "    \(.url) · \(.last_failure_reason) (\(.consecutive_failures)x)"' 2>/dev/null)
          FAILING_ITEMS_LINE="⚠ ${FAIL_COUNT} watch item(s) failing:
${FAIL_ROWS}
"
        fi
      fi
    fi
  fi
fi

# Corrupt-line warning -- single line per session, not per-bad-line (spec line 358).
CORRUPT_WARNING=""
if [ "$CORRUPT_LINES" -gt 0 ]; then
  CORRUPT_WARNING="[!] digest_corrupt · skipped ${CORRUPT_LINES} unparseable line(s)
"
fi

# Awaiting-us action inbox (cross-repo Phase 21 action-state surface consumer;
# CONTRACT-01 producer: scripts/watch/dhx-watch-check.cjs computes action_state,
# dhx-watch-driver.cjs writes ack/snooze via stampAndWrite). Level-triggered (D-05):
# reads watchlist.json DIRECTLY -- the SAME file + fail-silent jq shape as the drift
# line below -- and re-renders every CURRENT non-snoozed awaiting_us item each
# session until ack/snooze clears it. DISTINCT from the edge-triggered digest delta
# block above: a delta fires once and is gone next session, so an unacted awaiting_us
# item must NOT fall out of view -- this section persists it. Read-only consumer:
# NEVER recomputes action_state / snooze fields. Does NOT touch the Phase-20 12-key
# health cache (D-05) -- watchlist.json and the health cache are two independent
# surfaces.
#
# Filter: status=="active" AND action_state=="awaiting_us" AND not currently snoozed.
# The snooze test is DEFENSIVE (D-13): a null / expired / malformed snooze_until is
# treated as NOT snoozed (the item RENDERS); only a still-in-the-future ISO timestamp
# or the literal "perma" HIDES the item. DO NOT invert this predicate.
#
#   snooze_until value           -> action-banner disposition
#     null                       -> RENDER  (never snoozed)
#     missing field              -> RENDER  (the `== null` branch is true)
#     expired ISO (parsed < now) -> RENDER  (snooze elapsed; parses, compares < now)
#     malformed / unparseable    -> RENDER  ((..)? fails -> // 0 -> 0 < now is TRUE -> RENDER)
#     future ISO (parsed >= now) -> HIDE    (still snoozed)
#     "perma"                    -> HIDE    (permanently snoozed)
#
# INVARIANT (cross-process, producer<->consumer): the cross-repo producer stamps
# millisecond-precision ISO timestamps; this jq consumer MUST strip fractional seconds
# before fromdateiso8601 or the snooze gate silently never hides. Enforced here, proven
# by probe-watch-action-render.js; the producer side cannot enforce it for us.
#
# LOAD-BEARING: the `sub("\\.[0-9]+";"")` strips fractional seconds BEFORE
# fromdateiso8601. The producer stamps millisecond-precision ISO (e.g. last_checked_at
# "2026-05-14T03:00:43.430Z" -- the snooze_until fingerprint), but jq-1.7's
# fromdateiso8601 does NOT parse fractional seconds -> it would throw on EVERY real
# snooze_until -> // 0 -> a *future* snooze would (wrongly) RENDER, never hiding. The
# strip restores the future->HIDE half of the contract for the producer's actual
# format while keeping malformed->RENDER (a genuinely unparseable string still fails
# after the strip). The whole pipe is wrapped in (..)? so a non-string snooze_until
# (producer misbehaves) is swallowed to // 0 -> RENDER too, never a banner throw.
# DO NOT "simplify" this back to a bare `fromdateiso8601? // 0` -- that reintroduces
# the never-hide bug. (Probe: probe-watch-action-render.js future-ISO HIDE case.)
#
# WR-04: the `status == "active"` clause is REQUIRED, not redundant -- an action_state
# left at "awaiting_us" on an item later closed/paused must NOT render; action_state
# is NOT re-cleared on status change, so dropping the clause re-surfaces resolved/
# closed items.
ACTION_BLOCK=""
if [ -f "$WATCHLIST" ]; then
  ACTION_COUNT=$(jq '[.items[]
    | select(.status == "active"
        and .action_state == "awaiting_us"
        and (.snooze_until == null
             or (.snooze_until != "perma"
                 and (((.snooze_until | sub("\\.[0-9]+";"") | fromdateiso8601)? // 0) < now))))]
    | length' "$WATCHLIST" 2>/dev/null)
  case "$ACTION_COUNT" in
    ''|*[!0-9]*) ACTION_COUNT=0 ;;
  esac
  if [ "$ACTION_COUNT" -gt 0 ]; then
    # SAME predicate as the count select above -- keep the two textually identical
    # (the probe asserts count and render together so divergence is caught). Renders
    # an actionable-inbox row per item (tag · labels · url) + copy-ready ack/snooze
    # shortcuts -- the driver subcommands `ack <id>` / `snooze <id> 8h`, which users
    # invoke via /dhx:watch -- never bare ids.
    ACTION_ROWS=$(jq -r '.items[]
      | select(.status == "active"
          and .action_state == "awaiting_us"
          and (.snooze_until == null
               or (.snooze_until != "perma"
                   and (((.snooze_until | sub("\\.[0-9]+";"") | fromdateiso8601)? // 0) < now))))
      | "    " + .tag
        + (((.last_seen_labels // []) | .[0:3] | join(", ")) as $lbl | if $lbl == "" then "" else " · " + $lbl end)
        + " · " + .url
        + "\n      › /dhx:watch ack " + .id + " · snooze " + .id + " 8h"' "$WATCHLIST" 2>/dev/null)
    ACTION_BLOCK="⚠ Action required (${ACTION_COUNT}):
${ACTION_ROWS}
"
  fi
fi

# Upstream-closed drift surfacing (XR-WATCH-RECONCILE): count active watchlist items
# whose upstream went closed/merged while still locally active. Single source: matches
# isUpstreamClosedDrift() in cross-repo scripts/watch/dhx-watch-shared.cjs (current-state
# 2-field predicate, NOT a digest-event join — durable, catches born-closed adds, survives
# digest rotation per cross-repo D-1). The /dhx:watch list + driver leg already surfaces
# this (dhx-watch-driver.cjs); this is the digest/timer leg so an idle session that only
# sees the digest learns of the drift too. Surfacing only — never mutates the watchlist.
DRIFT_LINE=""
if [ -f "$WATCHLIST" ]; then
  DRIFT_COUNT=$(jq '[.items[] | select(.status == "active" and (.last_seen_state == "closed" or .last_seen_state == "merged"))] | length' "$WATCHLIST" 2>/dev/null)
  case "$DRIFT_COUNT" in
    ''|*[!0-9]*) DRIFT_COUNT=0 ;;
  esac
  if [ "$DRIFT_COUNT" -gt 0 ]; then
    DRIFT_LINE="⚠ ${DRIFT_COUNT} item(s) closed upstream, still active locally — enable config.auto_close_on_upstream_close to auto-close, or close manually.
"
  fi
fi

# BACKLOG-INTEGRATION obligation 2: silent on no deltas. EXIT EARLY before any stdout.
# Each health section + DRIFT_LINE is independent of ANY_SURFACED (cache/watchlist-
# derived), so each MUST be in this guard -- else a session whose ONLY output is a
# health/drift section (no new events, no corrupt lines) exits silently and that
# section is swallowed before the printf below.
if [ "$ANY_SURFACED" -eq 0 ] \
  && [ -z "$TIMER_STALE_LINE" ] && [ -z "$POLLS_DEGRADED_LINE" ] && [ -z "$FAILING_ITEMS_LINE" ] \
  && [ -z "$ACTION_BLOCK" ] && [ -z "$DRIFT_LINE" ] && [ -z "$CORRUPT_WARNING" ]; then
  exit 0
fi

# Emit in D-11 order: timer_stale → polls_degraded → failing-items → action-required
# → drift → corrupt → per-event rendered block. Action-required (the awaiting_us
# inbox, watchlist-derived) sits after the health-cache alarms and before drift: it
# is a direct ask on the user (higher priority than the informational closed-upstream
# drift line), while the watcher-health alarms above contextualize whether the
# awaiting_us verdict is even fresh.
printf '%s%s%s%s%s%s%s' \
  "$TIMER_STALE_LINE" "$POLLS_DEGRADED_LINE" "$FAILING_ITEMS_LINE" \
  "$ACTION_BLOCK" "$DRIFT_LINE" "$CORRUPT_WARNING" "$RENDER_OUT"

# Spec section Surfacer logic step 4: atomic-write new pointer.
if [ "$MAX_SURFACED" != "$PTR" ]; then
  PTR_TMP="$POINTER.tmp"
  printf '%s' "$MAX_SURFACED" > "$PTR_TMP"
  mv "$PTR_TMP" "$POINTER"
fi

exit 0
