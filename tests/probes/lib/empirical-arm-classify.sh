#!/usr/bin/env bash
# empirical-arm-classify.sh — the D-01 empirical arm's ORACLE, as a sourced lib.
#
# `run-empirical-arm.sh` drives a real Claude Code child in a sandbox and then
# classifies what it left behind. Until 2026-09-19 that classification lived
# inline in the arm and its D-05 branch keyed on two signals only — marker
# absent + control fired → REFUTE — while the Stop-dispatch trace (8c) was
# advisory prose. Run unauthenticated, the child ends its turn at the API auth
# error BEFORE any Stop hook dispatches, the cache-only marker therefore cannot
# fire, and the arm still printed REFUTE (H5 run 1, CC 2.1.278: 0 Stop lines,
# `Suggested: REFUTE`). Vacuous-oracle class. Extracting the oracle here lets
# `probe-empirical-arm-oracle.sh` drive it on fixtures with no CC child, with the
# pre-fix shape as the negative control.
#
# Functions (all pure: read files, print, set variables; write nothing):
#
#   arm_marker_fired    <marker-log>  → prints yes|no
#       8a — the cache-only marker fixture wrote a line.
#   arm_control_fired   <beat-dir>    → prints yes|no
#       8b — since 2026-09-19 (D4): session-start.sh's OWN reference beat record
#       exists under the sandbox's hooks cache, `<beat-dir>/<session16>/<event16>.
#       <ms>.<pid>.<nonce>.json`, written by the dispatcher's first block on every
#       fire (`_SCH_HB_DIR="${DHX_HOOKS_CACHE_DIR:-$HOME/.cache/dhx/hooks}/session-start"`).
#       That is evidence the dispatcher registered in the live manifest RAN, and
#       nothing in a debug file can forge it. The previous control —
#       `grep -E "session-start|SessionStart"` over the debug file — was satisfied
#       in the arm's own sandbox by construction: the manifest's second
#       SessionStart entry (`$HOME/.claude/hooks/dhx-vitals-banner.sh`) ENOENTs
#       under the swapped HOME and CC logs `Hook SessionStart:startup (SessionStart)
#       error:` for it (H3 cells E/P), so the control could not tell "dispatcher
#       ran" from "dispatcher was attempted".
#   arm_stop_dispatched <debug-log>   → prints N (count of Stop-dispatch lines)
#       8c — LOAD-BEARING since 2026-09-19. Pinned to the 2.1.278 line shape
#       `<timestamp> [DEBUG] "Hook Stop (Stop) success:|error:` — anchored at
#       LINE START (one non-space token, the timestamp, then the record) so that
#       neither a permission-rule echo (a line beginning `<ts> [DEBUG] Applying
#       permission update:`, the one settings-text carrier that reaches the
#       debug file — H3) nor another hook record's EMBEDDED output (CC folds a
#       hook's stdout into its own `"Hook <Event> … success:\n…"` record, escaped
#       `\n`, one line — so embedded text never starts a line; close-gate
#       finding 1, 2026-09-19) can produce a match whatever the text says. A
#       future CC that changes the shape reads 0 → INCONCLUSIVE, the safe direction.
#   arm_auth_failed     <debug-log>   → prints yes|no
#       The child never reached the model (`Could not resolve authentication
#       method` / `Not logged in`). Named in the INCONCLUSIVE label so the
#       operator sees WHY, never a verdict input on its own.
#   arm_classify <marker> <control> <stops> <auth_failed>
#       Sets CLASS_VERDICT (AFFIRM|REFUTE|INCONCLUSIVE), CLASS_LABEL, CLASS_ARGS.
#       REFUTE requires ALL of: marker=no, control=yes, stops>=1.
#   arm_restamp_owed <fixture> <new cache_read_path: yes|no|inconclusive>
#       Sets RESTAMP_OWED (yes|no) and RESTAMP_RECORDED (the fixture's
#       cache_read_path, or absent|malformed); returns 2 on a bad new value.
#       Since 2026-09-24 the D-01 fixture records the last verdict CHANGE, not
#       the newest CC release: a write is owed only when the fixture is absent
#       or malformed, or a CONCLUSIVE new value differs from the recorded one.
#       INCONCLUSIVE never replaces a recorded value — it is an instrument
#       failure, not a verdict. Consumed by run-empirical-arm.sh's Step 9 and
#       by probe-plugin-cache-staleness.sh's write-result guard, so the rule
#       exists once.
#
# Backs: docs/decisions.md 2026-09-19 (H5 row: the arm needs credentials; D4 row: control re-key),
#        2026-09-24 (re-stamp only on a verdict change);
#        tests/probes/probe-empirical-arm-oracle.sh.

ARM_STOP_RE='^[^ ]+ \[DEBUG\] "Hook Stop \(Stop\) (success|error):'
ARM_AUTH_FAIL_RE='Could not resolve authentication method|Not logged in'

arm_marker_fired() {
  if [ -n "${1:-}" ] && [ -s "$1" ]; then printf 'yes\n'; else printf 'no\n'; fi
}

arm_control_fired() {
  local d="${1:-}" f=""
  if [ -n "$d" ] && [ -d "$d" ]; then
    f=$(find "$d" -type f -name '*.json' -print -quit 2>/dev/null)
  fi
  if [ -n "$f" ]; then printf 'yes\n'; else printf 'no\n'; fi
}

arm_stop_dispatched() {
  local n
  n=$(grep -cE "$ARM_STOP_RE" "${1:-/dev/null}" 2>/dev/null) || n=0
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s\n' "$n"
}

arm_auth_failed() {
  if grep -qE "$ARM_AUTH_FAIL_RE" "${1:-/dev/null}" 2>/dev/null; then printf 'yes\n'; else printf 'no\n'; fi
}

# arm_classify <marker_fired> <control_fired> <stops_dispatched> <auth_failed>
arm_classify() {
  local marker="${1:-no}" control="${2:-no}" stops="${3:-0}" auth="${4:-no}"
  case "$stops" in ''|*[!0-9]*) stops=0 ;; esac
  CLASS_VERDICT=""; CLASS_LABEL=""; CLASS_ARGS=""
  if [ "$marker" = "yes" ]; then
    CLASS_VERDICT=AFFIRM
    CLASS_LABEL="AFFIRM (cache IS the read path)"
    CLASS_ARGS="--cache-read-path yes --control-hook-fired $control"
  elif [ "$marker" = "no" ] && [ "$control" = "yes" ] && [ "$stops" -ge 1 ]; then
    CLASS_VERDICT=REFUTE
    CLASS_LABEL="REFUTE (live source is the read path — cache is metadata-only, confirms HP-020; $stops source Stop hook(s) dispatched, cache-only marker silent)"
    CLASS_ARGS="--cache-read-path no --control-hook-fired yes"
  elif [ "$marker" = "no" ] && [ "$control" = "yes" ]; then
    CLASS_VERDICT=INCONCLUSIVE
    if [ "$auth" = "yes" ]; then
      CLASS_LABEL="INCONCLUSIVE (Stop never dispatched — the child failed to authenticate and ended the turn before Stop; the marker COULD NOT fire, so its absence is not a REFUTE)"
    else
      CLASS_LABEL="INCONCLUSIVE (Stop never dispatched — 0 Stop-dispatch lines in the debug file; the marker COULD NOT fire, so its absence is not a REFUTE)"
    fi
    CLASS_ARGS="--cache-read-path inconclusive --control-hook-fired yes"
  else
    CLASS_VERDICT=INCONCLUSIVE
    CLASS_LABEL="INCONCLUSIVE (control did not fire — session-start.sh left no beat record: claude failed / install error / dispatcher not run)"
    CLASS_ARGS="--cache-read-path inconclusive --control-hook-fired $control"
  fi
}

arm_restamp_owed() {
  local fixture="${1:-}" new="${2:-}" rec=""
  RESTAMP_OWED=""; RESTAMP_RECORDED=""
  case "$new" in yes|no|inconclusive) ;; *) return 2 ;; esac
  if [ -z "$fixture" ] || [ ! -r "$fixture" ]; then
    RESTAMP_RECORDED=absent; RESTAMP_OWED=yes; return 0
  fi
  # First frontmatter key only — the body quotes `cache_read_path: <v>` in prose.
  rec=$(awk '/^---$/{n++; next} n==1 && /^cache_read_path: /{print $2; exit}' "$fixture")
  case "$rec" in
    yes|no|inconclusive) RESTAMP_RECORDED="$rec" ;;
    *) RESTAMP_RECORDED=malformed; RESTAMP_OWED=yes; return 0 ;;
  esac
  if [ "$new" = "$rec" ] || [ "$new" = inconclusive ]; then
    RESTAMP_OWED=no
  else
    RESTAMP_OWED=yes
  fi
}
