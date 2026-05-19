#!/usr/bin/env bash
# dhx-verify-drift-gate.sh — UserPromptSubmit hook (matchless)
# Patterns: HP-008, HP-009, HP-017
#
# Detects missing {phase}-VERIFICATION.md when operator types /dhx:test {N}
# (full-pipeline shape only — subcommands skip the gate). Emits block-JSON
# whose `reason` LEADS with the actionable fix (dispatch `gsd-verifier` via
# Task tool) and still names the three exit lanes (A wave-slice / B
# /dhx:execute early-exit / C operator-bypass) so all closure paths remain
# audit-traceable. Operator dispensation row in docs/decisions.md overrides
# the gate (D-12). Silent on happy path; fail-open on STATE.md errors (D-17).
#
# CONTEXT.md decisions implemented: D-01..D-17 (locked 2026-05-15;
# D-01 pivoted to UserPromptSubmit on 2026-05-15; D-11 obsolete;
# D-23 reason-text wording revised 2026-05-18 per first field-signal —
# leads with dispatch verb + phase-prefixed VERIFICATION.md naming hint).

set -uo pipefail

INPUT=$(cat)
if ! command -v jq >/dev/null 2>&1; then exit 0; fi

# Step 1: Prompt extraction + prefix filter (D-01)
# Anchor on a word boundary — `/dhx:test` must be followed by whitespace or
# end-of-string. The bare `/dhx:test*` glob would also fire on /dhx:testify,
# /dhx:test-harness, /dhx:testbench (WR-01).
PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)
if [[ -z "$PROMPT" ]]; then exit 0; fi
case "$PROMPT" in
  "/dhx:test"|"/dhx:test "*) ;;
  *) exit 0 ;;   # not our prompt
esac

# Step 2: Subcommand scope filter (D-05)
# Anchor each subcommand on a trailing word boundary too — the bare
# `"/dhx:test run"*` glob would treat `/dhx:test runner` as the `run`
# subcommand and bypass the gate (WR-02).
case "$PROMPT" in
  "/dhx:test nyquist"|"/dhx:test nyquist "* \
  |"/dhx:test run"|"/dhx:test run "* \
  |"/dhx:test sweep"|"/dhx:test sweep "*) exit 0 ;;
esac

# Step 3: Phase resolution (D-09 args -> STATE.md fallback)
PHASE=""
if [[ "$PROMPT" =~ ^/dhx:test[[:space:]]+([0-9]+(\.[0-9]+)?)[[:space:]]*$ ]]; then
  PHASE="${BASH_REMATCH[1]}"
fi
if [[ -z "$PHASE" ]]; then
  STATE=".planning/STATE.md"
  if [[ ! -r "$STATE" ]]; then
    echo "dhx-verify-drift-gate: STATE.md unreadable; gate skipped" >&2
    exit 0   # D-17 fail-open
  fi
  # Primary parse: extract the leading N or N.M token from the `current_phase:`
  # line. Bash-native `[[ =~ ]]` + BASH_REMATCH — extracts the first phase token
  # and ignores trailing annotations (`12 (wave 3 in progress)`, `12 — plan
  # 3.1`, `12 # blocked`). Earlier `awk gsub(/[^0-9.]/,"")` deleted *all*
  # non-digit chars and corrupted annotated values (`12 (wave 3)` -> `123`)
  # (CR-01). Pure bash also drops the gawk-only 3-arg match() dependency (WR-05).
  while IFS= read -r _line; do
    if [[ "$_line" =~ ^current_phase:[[:space:]]*([0-9]+(\.[0-9]+)?) ]]; then
      PHASE="${BASH_REMATCH[1]}"
      break
    fi
  done < "$STATE"
  # Fallback parse: the first `Phase N` / `Phase N.M` token on a `stopped_at:`
  # line. Same bash-native extraction (was a gawk-only 3-arg match() — WR-05).
  if [[ -z "$PHASE" ]]; then
    while IFS= read -r _line; do
      if [[ "$_line" =~ ^stopped_at:.*Phase[[:space:]]+([0-9]+(\.[0-9]+)?) ]]; then
        PHASE="${BASH_REMATCH[1]}"
        break
      fi
    done < "$STATE"
  fi
  if [[ -z "$PHASE" ]]; then
    echo "dhx-verify-drift-gate: STATE.md current_phase unresolved; gate skipped" >&2
    exit 0   # D-17 fail-open
  fi
fi

# Step 4: Dispensation row check (D-10 + D-12)
# Row-anchored: only a decisions.md TABLE ROW (line starts with `|`) carrying
# the dispensation phrase counts — a bare `grep -qF` matched the phrase
# anywhere, so any prose mention (even a *rejected* dispensation discussion)
# would silently disable the gate (IN-01). The phase number is matched
# LITERALLY via a `case` glob (a decimal phase like `12.1` must not be treated
# as a regex). A bash `while read` loop avoids a pipeline grep — `set -uo
# pipefail` + SIGPIPE makes `cmd | grep -q` fragile on large inputs (HP-028).
DECISIONS="docs/decisions.md"
if [[ -r "$DECISIONS" ]]; then
  while IFS= read -r _line; do
    case "$_line" in
      "|"*"Phase $PHASE VERIFICATION.md drift dispensation"*)
        exit 0 ;;   # operator dispensation row; gate skipped (D-12)
    esac
  done < "$DECISIONS"
fi

# Step 5: VERIFICATION.md presence check (AC1 primary gate)
# Resolve .planning/phases/{PHASE}-* via a bash glob array (shellcheck-clean —
# avoids SC2012 ls-parse on the equivalent ls -d form). Ambiguity-safe: collect
# ALL matching dirs rather than breaking on the first. 0 matches -> not
# scaffolded (exit 0); >1 match -> fail-open with a one-line stderr warning
# (consistent with the D-17 STATE.md stance); exactly 1 -> use it. The bare
# break-on-first loop silently committed to glob-sort order, so a renamed-but-
# not-removed stale dir could yield a false-positive block (WR-03).
PHASE_DIR=""
_matches=()
for _cand in ".planning/phases/${PHASE}-"*; do
  [[ -d "$_cand" ]] && _matches+=("$_cand")
done
if [[ ${#_matches[@]} -eq 0 ]]; then
  exit 0   # phase not scaffolded (or glob did not expand); nothing to verify
elif [[ ${#_matches[@]} -gt 1 ]]; then
  echo "dhx-verify-drift-gate: phase $PHASE matches ${#_matches[@]} dirs; gate skipped" >&2
  exit 0   # ambiguous phase dir; fail-open (D-17 stance)
fi
PHASE_DIR="${_matches[0]}"
if [[ -z "$PHASE_DIR" || ! -d "$PHASE_DIR" ]]; then
  exit 0   # phase not scaffolded (or glob did not expand); nothing to verify
fi
VERIFICATION="$PHASE_DIR/${PHASE}-VERIFICATION.md"
if [[ -r "$VERIFICATION" ]]; then exit 0; fi   # gate passes — silent allow

# Step 5.5: Exit-D awaiting-upstream lane (2026-05-17)
# Closure class: phases that closed `awaiting-upstream` (D-08 contingency on a
# tractability NO outcome). Operator review surface is {phase}-UAT.md (not
# {phase}-VERIFICATION.md) because some plans intentionally do not execute, so
# the count-based Exit-A signal mis-fires ("Phase has incomplete plans" is
# misleading when the missing SUMMARY.md is by design). Recognized structurally
# via UAT.md status:complete + an upstream-routing marker (CONTEXT.md
# phase_status OR ROADMAP.md closure line). Phase-scoped — no STATE.md
# milestone-cumulative reads (mirrors the Exit-A invariant). Fail-open on all
# error paths (D-17 stance): unparseable UAT.md / unreadable marker source /
# missing marker → fall through to Step 6 Exit-A. Step 4 dispensation row
# (Lane C escape valve) still runs first; this lane backstops it structurally.
UAT="$PHASE_DIR/${PHASE}-UAT.md"
if [[ -r "$UAT" ]]; then
  # Parse UAT.md frontmatter for `status: complete`. Bash-native idiom mirrors
  # Step 3 STATE.md parse at L58-77 — same `while read` + `[[ =~ ]]` +
  # BASH_REMATCH template; bounded by an `^---` counter so prose body lines
  # containing "status:" cannot match.
  UAT_STATUS=""
  _in_fm=0
  _fm_seen=0
  while IFS= read -r _line; do
    if [[ "$_line" =~ ^---[[:space:]]*$ ]]; then
      if [[ "$_in_fm" -eq 0 && "$_fm_seen" -eq 0 ]]; then
        _in_fm=1
        _fm_seen=1
        continue
      elif [[ "$_in_fm" -eq 1 ]]; then
        _in_fm=0
        break
      fi
    fi
    if [[ "$_in_fm" -eq 1 && "$_line" =~ ^status:[[:space:]]*([a-zA-Z]+) ]]; then
      UAT_STATUS="${BASH_REMATCH[1]}"
      break
    fi
  done < "$UAT"
  if [[ "$UAT_STATUS" == "complete" ]]; then
    # Upstream-routing marker check (OR of two arms; first success wins).
    UPSTREAM_MARKER=0
    # Arm (a): CONTEXT.md frontmatter `phase_status: awaiting-upstream`.
    CONTEXT="$PHASE_DIR/${PHASE}-CONTEXT.md"
    if [[ -r "$CONTEXT" ]]; then
      _in_fm=0
      _fm_seen=0
      while IFS= read -r _line; do
        if [[ "$_line" =~ ^---[[:space:]]*$ ]]; then
          if [[ "$_in_fm" -eq 0 && "$_fm_seen" -eq 0 ]]; then
            _in_fm=1
            _fm_seen=1
            continue
          elif [[ "$_in_fm" -eq 1 ]]; then
            _in_fm=0
            break
          fi
        fi
        if [[ "$_in_fm" -eq 1 && "$_line" =~ ^phase_status:[[:space:]]*awaiting-upstream ]]; then
          UPSTREAM_MARKER=1
          break
        fi
      done < "$CONTEXT"
    fi
    # Arm (b): ROADMAP.md body line containing `Phase $PHASE` AND `Closed
    # `awaiting-upstream``. Case-glob style matches $PHASE literally (decimal-
    # safe like Step 4 at L91). Backticks inside double-quoted glob patterns
    # are literal characters. while-read is bounded single-pass — no slurp.
    if [[ "$UPSTREAM_MARKER" -eq 0 ]]; then
      ROADMAP=".planning/ROADMAP.md"
      if [[ -r "$ROADMAP" ]]; then
        while IFS= read -r _line; do
          case "$_line" in
            *"Phase $PHASE"*"Closed \`awaiting-upstream\`"*)
              UPSTREAM_MARKER=1
              break
              ;;
          esac
        done < "$ROADMAP"
      fi
    fi
    if [[ "$UPSTREAM_MARKER" -eq 1 ]]; then
      exit 0   # Exit-D: awaiting-upstream closure recognized; silent allow
    fi
  fi
fi

# Step 6: Exit-A detection (D-06 — refine message based on incomplete plans).
# Phase-scoped only: an unfinished `- [ ]` checkbox in any phase PLAN.md, OR a
# phase PLAN.md with no matching SUMMARY.md. STATE.md `progress.*` is NOT used —
# it is milestone-cumulative (total_plans/completed_plans span the whole
# milestone, not this phase), so `completed_plans < total_plans` is true for
# nearly every in-progress milestone and would mis-fire Exit-A on every phase.
# The #PLAN-vs-#SUMMARY count mirrors `gsd-sdk phase-plan-index` has_summary.
EXIT_A_DETECTED=0
# grep exit codes are tri-valued: 0 = match, 1 = no match, 2 = error
# (unreadable file, mid-write truncation). This `if` intentionally collapses
# exit 2 into "no checkbox found" (WR-06): the #PLAN-vs-#SUMMARY count path
# below remains the independent Exit-A signal, so an unreadable PLAN.md
# degrades message accuracy at worst, never a missed block. The trade-off is
# accepted rather than branched on — the count path is the sturdier signal.
if grep -lE '^[[:space:]]*- \[ \]' "$PHASE_DIR"/*-PLAN.md >/dev/null 2>&1; then
  EXIT_A_DETECTED=1
fi
if [[ "$EXIT_A_DETECTED" -eq 0 ]]; then
  # Count *-PLAN.md vs *-SUMMARY.md in the phase dir. The [[ -f ]] guard makes an
  # unexpanded glob (no matches) count as zero — same idiom as Step 5 line ~66.
  PLAN_COUNT=0
  for _plan in "$PHASE_DIR"/*-PLAN.md; do
    [[ -f "$_plan" ]] && PLAN_COUNT=$((PLAN_COUNT + 1))
  done
  SUMMARY_COUNT=0
  for _summary in "$PHASE_DIR"/*-SUMMARY.md; do
    [[ -f "$_summary" ]] && SUMMARY_COUNT=$((SUMMARY_COUNT + 1))
  done
  if [[ "$PLAN_COUNT" -gt 0 && "$SUMMARY_COUNT" -lt "$PLAN_COUNT" ]]; then
    EXIT_A_DETECTED=1
  fi
fi

# Step 7: Emit block-JSON (D-03 + D-07 three-lane message)
if [[ "$EXIT_A_DETECTED" -eq 1 ]]; then
  REASON="VERIFICATION.md missing for phase $PHASE AND incomplete plans detected (Phase has incomplete plans). Fix in order: (1) run \`/gsd-execute-phase $PHASE\` (no --wave) to finish remaining plan work, (2) dispatch the \`gsd-verifier\` agent via Task tool to produce \`.planning/phases/{phase_dir}/$PHASE-VERIFICATION.md\` (phase-prefixed — agent occasionally drops the prefix; rename if so), (3) re-run \`/dhx:test $PHASE\`. Step (2) covers Lane A wave-slice / Lane B /dhx:execute wrapper early-exit / Lane C operator-bypass closure. Dispensation path: add row to docs/decisions.md (prefix: \"Phase $PHASE VERIFICATION.md drift dispensation\"). Exit-D: awaiting-upstream closure with completed $PHASE-UAT.md fires silently without operator intervention."
else
  REASON="VERIFICATION.md missing for phase $PHASE. Fix: dispatch the \`gsd-verifier\` agent via Task tool (phase $PHASE) — it writes \`.planning/phases/{phase_dir}/$PHASE-VERIFICATION.md\` (phase-prefixed — agent occasionally drops the prefix; rename if so). Re-run \`/dhx:test $PHASE\` after. Same dispatch covers Lane A wave-slice / Lane B /dhx:execute wrapper early-exit / Lane C operator-bypass closure. Dispensation path: add row to docs/decisions.md (prefix: \"Phase $PHASE VERIFICATION.md drift dispensation\"). Exit-D: awaiting-upstream closure with completed $PHASE-UAT.md fires silently without operator intervention."
fi

jq -n --arg r "$REASON" '{decision:"block", reason:$r}'
exit 0
