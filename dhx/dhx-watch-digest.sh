#!/usr/bin/env bash
# dhx-watch-digest.sh — Phase 6.1 (REQ-CROSS-06) SessionStart surfacer.
# Patterns: HP-009, HP-015
# Reads pointer.txt + scans digest.jsonl + emits unsurfaced events to stdout.
# Atomic-rewrites pointer.txt to the digest's highest entry_id (forward after a surface;
# BACK to the tail when a corrupt/hand-edited pointer sits ahead of every id, 2026-09-19).
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
# ─── Emitted-line contract (CROSS-BOUNDARY — read before changing ANY output line) ───
# INVARIANT (cross-repo, producer<->consumer): this surfacer's stdout shape is a
# contract a CONSUMER probe in ANOTHER repo asserts by literal `grep -F`:
#   ~/repos/cross-repo/scripts/watch/tests/probe-dhx-watch-digest.sh
# There is NO automated sync across the boundary. A change to any emitted line below
# silently red-rots that probe with no local signal — exactly how the removed
# `checker_stale` assertion sat red from the 2026-05-28 migration to 2026-06-10. If you
# change an emitted line, update the cross-repo probe in the SAME change.
# The hooks-side canonical pins (own + test this output; cross-repo defers/retires
# rather than duplicating across the boundary):
#   tests/probes/probe-watch-health-render.js  — timer_stale / polls_degraded / failing-items
#   tests/probes/probe-watch-action-render.js  — ⚠ Action required (awaiting_us) inbox
# Row tag (both inbox blocks): `primary_tag` is getTags(item)[0] || 'untagged' from cross-repo
# dhx-watch-shared.cjs, byte-for-rule — the SAME value the checker stamps as a digest event's flat
# `tag`, so an item reads identically in its inbox row and its digest line. Reading the legacy
# single `.tag` alone rendered a BLANK tag for every tags[]-only item (#4936, 2026-09-25).
# Emitted lines (lead token · trigger):
#   [!] watch checker stale · …    timer_stale verdict   (health cache)
#   [!] watch polls degraded · …   polls_degraded verdict (health cache)
#   ⚠ N watch item(s) failing: …   failing_items verdict  (health cache)
#   ⚠ Action required (N): …       awaiting_us inbox      (watchlist.json)
#   ✔ Ready for your PR (N): …     pr_eligible inbox      (watchlist.json)
#       ↳ from reports/<file>.md    origin_report context sub-line on both inbox rows, above `›`
#   ⚠ N item(s) closed upstream …  upstream-closed drift  (watchlist.json)
#   [!] digest_corrupt · …         corrupt digest lines
#   [!] digest_pointer · …         pointer.txt ahead of every digest id (resynced; once)
#   [M]/[S]/[!]/blank  TAG · #REF · TYPE  + "summary" (rel)  per-event digest delta (2 lines)
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
# One jq pass over the digest; its `M` trailer carries the digest's max entry_id and whether the
# pointer is below / at / above it (DIGEST_REL lt|eq|gt) for the atomic-rewrite step.
DIGEST_MAX=""
DIGEST_REL=""
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
# ONE jq spawn for the whole digest (2026-09-14). The previous loop spawned `jq -c` + `jq -r`
# per line BEFORE the pointer compare -- >=3,600 processes to surface zero rows on a 1,800-line
# digest, 9-12 s of every SessionStart. `-Rs` slurps the file as one raw string; splitting on
# "\n" and dropping the LAST element keeps exactly the `while read` record framing on purpose:
# an unterminated final line (a row mid-append when SessionStart fires, or after a crash) is
# INVISIBLE this pass and read whole next time -- never surfaced from a half-written record,
# never counted corrupt. `try fromjson` tolerates a corrupt line instead of aborting the pass.
# Emits, in file order, one line per row the loop below needs:
#   C                        jq parse failure                        -> CORRUPT_LINES++
#   B                        valid JSON, id present but not ^[0-9]+\z -> CORRUPT_LINES++
#   <id><TAB><compact row>   digit-string id ABOVE the pointer         -> surfaced branch
# then, LAST, one trailer when the digest holds at least one digit-string id:
#   M<TAB><max id><TAB>lt|eq|gt   the digest's max id (raw, as written) and how it stands
#                                 to the pointer -> the atomic pointer write below
# and drops (never emits) blank lines, non-object JSON, null/absent ids, and ids <= pointer --
# exactly the lines the old loop `continue`d over without side effects. Sentinels cannot
# collide with a data line: a data line starts with its digit-string id, a sentinel starts
# with a letter, and a compact JSON row never contains a raw TAB or newline (JSON escapes
# both). `\z` (absolute end), NOT `$`: Oniguruma's `$` matches before a trailing newline, so
# `"123\n"` would pass `$` and split the tab protocol across two physical lines.
#
# entry_id is a JSON STRING of digits in the live digest (the producer allocates BigInt ids,
# D-40, and serialises .toString(); 19 digits today), so the id is handled as TEXT throughout:
# `tostring` reproduces what `jq -r` printed for the old `*[!0-9]*` test, and EVERY compare --
# row against pointer, digest max against pointer -- is this pass's exact digit-string compare
# (strip leading zeros, longer wins, else lexicographic), never a numeric one. Bash performs
# no integer comparison on an id or the pointer anywhere below (2026-09-19; the `-le` "belt"
# the 2026-09-14 rewrite kept was the one place representation still mattered: a 20-digit
# id or pointer made `[` error on every row -- a permanent re-render storm on the old loop,
# permanent silence on the new one). The `M` trailer is what makes the pointer write
# representation-free: `gt` = something surfaced, pointer advances to the max; `eq` = current,
# no write; `lt` = the pointer is AHEAD of every id in the file (a corrupt or hand-edited
# pointer.txt, or a digest restored from an older copy) -- resync it to the file's max, render
# nothing, and say so once via `[!] digest_pointer` (the rows in that gap are unrecoverable
# under any rule; the level-triggered inbox sections below do not depend on the pointer).
# Measured 2026-09-19 before choosing resync over the "coerce to 0, re-surface everything
# once" alternative: pointer 0 on a copy of the live digest cost 34 s and 217 KB of stdout
# into model context (1,536 rows), 94 s at 5k lines, 676 s at 20k -- past CC's 600 s hook
# timeout, i.e. killed before its own pointer write and therefore never healing at all.
# `tojson` here is byte-identical to the `jq -c '.'` the old loop handed the render branch.
if SCAN=$(jq -Rs -r --arg p "$PTR" '
  def norm: sub("^0+(?=[0-9])"; "");
  def below($a; $b): ($a | length) < ($b | length) or (($a | length) == ($b | length) and $a < $b);
  ($p | norm) as $pn
  # foreach, not a collected array: state is one row plus the running max, so memory stays
  # ~2x the file (an array of parsed rows measured 2.6x, 379 MB at 100k lines). The null
  # sentinel appended to the line stream is where the M trailer is emitted from the state.
  | foreach ((split("\n")[:-1][] | select(. != "")), null) as $line
      ({raw: null, n: null, out: null};
       if $line == null then
         .out = (if .raw == null then null else
                   "M\t" + .raw + "\t"
                   + (if below(.n; $pn) then "lt" elif .n == $pn then "eq" else "gt" end) end)
       else
         ($line | (try (fromjson | [1, .]) catch [0])) as $e
         | if $e[0] == 0 then .out = "C" else
             ($e[1] | (try .entry_id catch null)) as $idv
             | if ($idv == null or $idv == false) then .out = null
               else ($idv | tostring) as $id
               | if $id == "" then .out = null
                 elif ($id | test("^[0-9]+\\z") | not) then .out = "B"
                 else ($id | norm) as $n
                   | (if .n == null or below(.n; $n) then .raw = $id | .n = $n else . end)
                   | .out = (if below($n; $pn) or $n == $pn then null
                             else $id + "\t" + ($e[1] | tojson) end)
                 end
               end
           end
       end;
       .out // empty)' "$DIGEST" 2>/dev/null); then
  :
else
  # jq itself failed (missing/broken binary, unreadable digest): the old per-line loop counted
  # EVERY line corrupt in that state and warned loudly. Keep that -- never go silent here.
  # Count only LF-terminated non-blank lines: `while read` never saw an unterminated tail, so
  # the old loop never counted one either (close-review round 1, Q1). `sed '$d'` drops that
  # tail only when the file does not end in a newline. The last byte is read through `od`,
  # not `[ -z "$(tail -c1)" ]`: bash drops a trailing NUL from a command substitution, so a
  # NUL-ending tail would read as LF-terminated and be counted (round 2, Q1).
  if [ "$(tail -c1 "$DIGEST" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "0a" ]; then
    CORRUPT_LINES=$(command grep -c . "$DIGEST" 2>/dev/null)
  else
    CORRUPT_LINES=$(sed '$d' "$DIGEST" 2>/dev/null | command grep -c .)
  fi
  case "$CORRUPT_LINES" in ''|*[!0-9]*) CORRUPT_LINES=0 ;; esac
  SCAN=""
fi
while IFS= read -r LINE; do
  case "$LINE" in
    '')  continue ;;   # the empty-$SCAN herestring yields one blank iteration
    C|B) CORRUPT_LINES=$((CORRUPT_LINES + 1)); continue ;;
    M$'\t'*)  # the trailer: digest max + its standing to the pointer (see the jq comment)
      DIGEST_MAX=${LINE#M$'\t'}; DIGEST_REL=${DIGEST_MAX#*$'\t'}; DIGEST_MAX=${DIGEST_MAX%%$'\t'*}
      case "$DIGEST_REL" in lt|eq|gt) ;; *) DIGEST_MAX=""; DIGEST_REL="" ;; esac
      continue ;;
  esac
  # Narrowed corrupt predicate (surfacing-fidelity brief 2026-06-13): a valid-JSON line whose
  # entry_id is null/absent is an INTENTIONAL audit non-delta -- the driver (dhx-watch-driver.cjs)
  # writes ack/snooze events with entry_id:null, outside the checker's D-40 nextEntryId allocator.
  # It is skipped SILENTLY inside the jq pass above (`// empty`): it is not corrupt, and a null id
  # never advances the pointer, so the OLD predicate re-warned [!] digest_corrupt every SessionStart
  # forever. digest_corrupt is reserved for genuine parse failures (C) AND present-but-garbage ids
  # (B, non-numeric), which stay loud (AC-B2: narrow the predicate, do not blind it).
  EID=${LINE%%$'\t'*}
  PARSED=${LINE#*$'\t'}
  # Every row that arrives is above the pointer: the jq pass is the sole predicate, and the
  # pointer's next value is the `M` trailer's max, so no `[ -le ]`/`[ -gt ]` runs here (a
  # bash integer test on a 20-digit id errors; see the jq comment, 2026-09-19).
  ANY_SURFACED=1
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
done <<< "$SCAN"
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
# Pointer-ahead notice (2026-09-19) -- once, in the session that resyncs it (the write is
# below, after the printf). Sibling of digest_corrupt: an integrity fault in the state, not
# a per-event line. The pointer is quoted length-bounded (a corrupt pointer.txt can be
# arbitrarily long, and this line must stay one line): 12 digits or fewer print whole,
# longer ones as `<len> digits, <first4>…<last4>`.
POINTER_WARNING=""
if [ "$DIGEST_REL" = "lt" ]; then
  if [ "${#PTR}" -le 12 ]; then PTR_SHOWN="$PTR"; else PTR_SHOWN="${#PTR} digits, ${PTR:0:4}…${PTR: -4}"; fi
  POINTER_WARNING="[!] digest_pointer · pointer.txt (${PTR_SHOWN}) was ahead of every digest id; resynced to ${DIGEST_MAX}
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
#
# Gap 7 / AC9 (2026-09-04): the `last_seen_state` clauses are WR-04's UPSTREAM twin.
# WR-04 guards LOCAL drift (our `status` moved, action_state did not). These guard
# UPSTREAM drift: the issue closed on GitHub, but this banner is LEVEL-triggered on the
# STORED action_state, and the checker only recomputes it to `resolved` on that item's
# next due poll -- up to `cadence_hours` (24h default) later. Without the clauses a
# closed-upstream item keeps demanding action for the whole blind window (measured
# 2026-07-12: gsd-core #2140, one of 3 false positives in a 4-item banner).
# No new API and no new field -- `last_seen_state` is the SAME poll-maintained value the
# `closed_upstream_still_active` drift line below already keys on, so a closed item now
# shows in the drift line and NOT the action line; the two banners agree by construction.
# Residual window narrows from "closed but action_state not-yet-RECOMPUTED" to "closed but
# not-yet-RECORDED" (one poll). `!=` is null-safe in jq -- an item that has never been
# polled has no `last_seen_state`, and `null != "closed"` is true, so it still renders.
ACTION_BLOCK=""
if [ -f "$WATCHLIST" ]; then
  ACTION_COUNT=$(jq '[.items[]
    | select(.status == "active"
        and .action_state == "awaiting_us"
        and .last_seen_state != "closed"
        and .last_seen_state != "merged"
        and ((.pr_eligible == true and .last_seen_open_closing_pr != true) | not)
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
    # an actionable-inbox row per item (tag · labels · url · polled-age) + copy-ready
    # ack/snooze shortcuts -- the driver subcommands `ack <id>` / `snooze <id> 8h`,
    # which users invoke via /dhx:watch -- never bare ids.
    #
    # The `· polled Xh ago` suffix is POLL freshness (last_checked_at), NOT action
    # age -- it dates the row's labels/state so a poll-stale row self-discounts
    # instead of reading as a live demand. D-13 fail-silent: the same fractional-
    # second strip as the snooze gate above (producer stamps ms-precision ISO;
    # jq-1.7 fromdateiso8601 throws on it), whole pipe wrapped in (..)? // null so
    # a missing/malformed/non-string last_checked_at renders the row bare, never
    # throws. Display-only (D-05) -- read from disk, no recompute, no poll.
    ACTION_ROWS=$(jq -r 'def primary_tag: (if (.tags | type) == "array" then .tags elif (.tag | type) == "string" and .tag != "" then [.tag] else [] end) | map(select(type == "string") | gsub("^\\s+|\\s+$"; "") | ascii_downcase | select(. != "")) | .[0] // "untagged";
      .items[]
      | select(.status == "active"
          and .action_state == "awaiting_us"
          and .last_seen_state != "closed"
          and .last_seen_state != "merged"
          and ((.pr_eligible == true and .last_seen_open_closing_pr != true) | not)
          and (.snooze_until == null
               or (.snooze_until != "perma"
                   and (((.snooze_until | sub("\\.[0-9]+";"") | fromdateiso8601)? // 0) < now))))
      | "    " + primary_tag
        + (((.last_seen_labels // []) | .[0:3] | join(", ")) as $lbl | if $lbl == "" then "" else " · " + $lbl end)
        + " · " + .url
        + ((((.last_checked_at | sub("\\.[0-9]+";"") | fromdateiso8601)? // null) as $polled
            | if $polled == null then ""
              else (((now - $polled) | if . < 0 then 0 else . end) as $s
                | if $s < 3600 then " · polled \($s / 60 | floor)m ago"
                  else " · polled \($s / 3600 | floor)h ago" end)
              end))
        + ((.origin_report.path? // null) as $o
            | if ($o | type) == "string" and $o != "" then "\n      ↳ from " + $o else "" end)
        + "\n      › /dhx:watch ack " + .id + " · snooze " + .id + " 8h"' "$WATCHLIST" 2>/dev/null)
    ACTION_BLOCK="⚠ Action required (${ACTION_COUNT}):
${ACTION_ROWS}
"
  fi
fi

# PR-READY INBOX (AC7 / Gap 5, 2026-09-04). The criterion the action-required block could not
# satisfy: an approval label must produce a signal meaning "this issue is now eligible for OUR PR",
# DISTINCT from awaiting_us ("they need a reply from us"). Measured on the live banner the day this
# landed: 3 of 5 action-required rows actually meant "go open your PR" and rendered identically to
# the 2 that meant "answer the maintainer" — and the only verbs offered were ack/snooze, where `ack`
# sets awaiting_them and therefore BURIED the approval you had been waiting for.
#
# Producer: cross-repo scripts/watch/dhx-watch-check.cjs derives `pr_eligible` LEVEL-triggered from
# the labels the issue currently carries (approval allowlist only — never isActionLabel, whose
# needs-*/question base means the OPPOSITE). This surfacer is a READ-ONLY consumer of that field, the
# same posture it holds toward action_state: it never recomputes a verdict.
#
# `.last_seen_open_closing_pr != true` is the load-bearing second clause, not a refinement. Without
# it this block rendered 16 rows on live data, 13 of them issues with a fix ALREADY in flight — a
# wall listing work already done. Same poll-maintained field the Gap-6 awaiting_them demote keys on,
# so the two agree by construction and no new data is fetched.
#
# THE TWO BLOCKS PARTITION — nothing can fall through both. Action-required above excludes exactly
# this block's membership test (`(.pr_eligible == true and .last_seen_open_closing_pr != true) | not`,
# carried byte-identically in ITS two selects). The narrow form is deliberate: excluding on
# `.pr_eligible` ALONE would vanish an approved item that has an in-flight PR *and* a genuine
# maintainer question — out of action-required by the exclusion, out of here by the closing-PR clause.
# Verified by probe rather than left to inference.
#
# Symbol: `✔` is from the same documented state set as the `⚠` used by every other block here
# (✔/✖/⚠/ℹ) and is single-width BMP. Emoji are BANNED on this surface — they are double-width and
# misalign every column (terminal-constraints.md § Unicode). The check reads "the maintainer ticked
# this off", not "you finished it"; the heading carries the actual instruction.
PR_READY_BLOCK=""
if [ -f "$WATCHLIST" ]; then
  PR_READY_COUNT=$(jq '[.items[]
    | select(.status == "active"
        and .pr_eligible == true
        and .last_seen_open_closing_pr != true
        and .last_seen_state != "closed"
        and .last_seen_state != "merged"
        and (.snooze_until == null
             or (.snooze_until != "perma"
                 and (((.snooze_until | sub("\\.[0-9]+";"") | fromdateiso8601)? // 0) < now))))]
    | length' "$WATCHLIST" 2>/dev/null)
  case "$PR_READY_COUNT" in
    ''|*[!0-9]*) PR_READY_COUNT=0 ;;
  esac
  if [ "$PR_READY_COUNT" -gt 0 ]; then
    # SAME predicate as the count select above -- keep the two textually identical (the probe
    # asserts count and rows together so divergence is caught), mirroring the action-required pair.
    # Row shape mirrors the action rows deliberately: one scan-vocabulary for the whole banner. The
    # verb differs because the ask differs -- `/dhx:upstream pr` opens the PR these rows are cleared
    # for. `ack` is NOT offered: it sets awaiting_them, which is meaningless here and is precisely the
    # bug that buried these items. Snooze IS offered, and the reason is reachability rather than
    # symmetry: the row body renders `.url`, never `.id`, so dropping the snooze shortcut leaves the
    # id nowhere on the row and an affordance the selects genuinely honor becomes untypeable. That
    # was tried and reverted during authoring -- the shorter line cost the operator the only copy of
    # the argument. The line runs ~119 chars against a 76-char content width and will wrap; that is
    # this surface\'s existing condition, not a regression introduced here (every item row above
    # already renders 92-109), and the probe\'s NOT-BARE-IDS contract wants the shortcut present.
    PR_READY_ROWS=$(jq -r 'def primary_tag: (if (.tags | type) == "array" then .tags elif (.tag | type) == "string" and .tag != "" then [.tag] else [] end) | map(select(type == "string") | gsub("^\\s+|\\s+$"; "") | ascii_downcase | select(. != "")) | .[0] // "untagged";
      .items[]
      | select(.status == "active"
          and .pr_eligible == true
          and .last_seen_open_closing_pr != true
          and .last_seen_state != "closed"
          and .last_seen_state != "merged"
          and (.snooze_until == null
               or (.snooze_until != "perma"
                   and (((.snooze_until | sub("\\.[0-9]+";"") | fromdateiso8601)? // 0) < now))))
      | "    " + primary_tag
        + (((.last_seen_labels // []) | .[0:3] | join(", ")) as $lbl | if $lbl == "" then "" else " · " + $lbl end)
        + " · " + .url
        + ((((.last_checked_at | sub("\\.[0-9]+";"") | fromdateiso8601)? // null) as $polled
            | if $polled == null then ""
              else (((now - $polled) | if . < 0 then 0 else . end) as $s
                | if $s < 3600 then " · polled \($s / 60 | floor)m ago"
                  else " · polled \($s / 3600 | floor)h ago" end)
              end))
        + ((.origin_report.path? // null) as $o
            | if ($o | type) == "string" and $o != "" then "\n      ↳ from " + $o else "" end)
        + "\n      › /dhx:upstream pr " + .url + " · /dhx:watch snooze " + .id + " 8h"' "$WATCHLIST" 2>/dev/null)
    PR_READY_BLOCK="✔ Ready for your PR (${PR_READY_COUNT}):
${PR_READY_ROWS}
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
  && [ -z "$ACTION_BLOCK" ] && [ -z "$PR_READY_BLOCK" ] && [ -z "$DRIFT_LINE" ] && [ -z "$CORRUPT_WARNING" ] \
  && [ -z "$POINTER_WARNING" ]; then
  # A pointer that is merely ahead (DIGEST_REL=lt) never reaches here: POINTER_WARNING is
  # non-empty, so the notice prints and the resync below runs.
  exit 0
fi

# Emit in D-11 order: timer_stale → polls_degraded → failing-items → action-required
# → pr-ready → drift → corrupt → per-event rendered block. Action-required (the awaiting_us
# inbox, watchlist-derived) sits after the health-cache alarms and before drift: it
# is a direct ask on the user (higher priority than the informational closed-upstream
# drift line), while the watcher-health alarms above contextualize whether the
# awaiting_us verdict is even fresh.
#
# PR-ready sits directly AFTER action-required and before drift: both are direct asks on the user, so
# both outrank the informational drift line, but answering a maintainer who is waiting outranks
# starting work nobody is blocked on. The two are mutually exclusive by construction (see the
# partition note on the PR-ready block), so the ordering never splits one item across both.
printf '%s%s%s%s%s%s%s%s%s' \
  "$TIMER_STALE_LINE" "$POLLS_DEGRADED_LINE" "$FAILING_ITEMS_LINE" \
  "$ACTION_BLOCK" "$PR_READY_BLOCK" "$DRIFT_LINE" "$CORRUPT_WARNING" "$POINTER_WARNING" "$RENDER_OUT"

# Spec section Surfacer logic step 4: atomic-write new pointer. The next pointer is always
# the digest's max id (the `M` trailer): `gt` -- rows surfaced, advance; `lt` -- the pointer
# was ahead of the file, move it BACK to the tail (the resync the notice above announced);
# `eq` or no trailer (empty digest, no digit-string id, a failed jq) -- leave it alone.
if [ -n "$DIGEST_MAX" ] && [ "$DIGEST_REL" != "eq" ]; then
  PTR_TMP="$POINTER.tmp"
  printf '%s' "$DIGEST_MAX" > "$PTR_TMP"
  mv "$PTR_TMP" "$POINTER"
fi

exit 0
