#!/usr/bin/env bash
# dhx-oracle-prestate-gate.sh — PreToolUse hook (Agent|Task matcher)
# Patterns: HP-011 (PreToolUse:Agent fires at parent with the prompt in stdin),
#           HP-017 (plugin manifest is the rewriter-safe registration path),
#           HP-028 (no `cmd | grep -q/-m N` — every filter here reads a
#                   here-string, so a short-circuiting grep cannot SIGPIPE its
#                   producer and manufacture a false-clean disposition)
#
# The DISPATCH station of the oracle pre-state gate. Runs
# `oracle-prestate-check.cjs --station dispatch` over each PLAN.md named in a
# `gsd-executor` dispatch prompt, measuring the plan's own grep-shaped
# acceptance oracles against the tree as it stands AT DISPATCH.
#
# Why a hook and not only the inline station: `/dhx:execute` § Pre-spawn audit
# item F is the `prechain` station. It is skippable (a session served a skill
# body older than item F, or a hand-written `Agent(subagent_type=...)` call from
# a resume runbook, never reaches it) and it is mis-timed (it runs once before
# chaining, so every plan in a phase is measured against the pre-wave-1 tree —
# barca 2026-09-02: five records, one tree_sha). Three of seven known instances
# of the vacuous-oracle class are decidable ONLY at dispatch, because an earlier
# plan in the same phase creates the vacuity. This is the station that reaches
# them, and the one station every dispatch path passes through.
#
# BOTH stations run and both are labelled. Never add a "skip if the other ran"
# arm in either direction: a file on disk is not a registered, matched, fired
# hook, and a skipped run zero-counts the telemetry exactly when the other
# station did not fire. Read-back groups by station and never sums them.
# Ruling: skills DEC-2026-09-02-oracle-prestate-gate-report-only-execute-item-f
# Amendment 1 (1).
#
# REPORT-ONLY, by that DEC's disposition. This hook sets no permissionDecision
# and ALWAYS exits 0 — it never stops a dispatch. Promotion to a spawn-stop is a
# one-line edit gated on the DEC's promotion condition, which Amendment 3
# (2026-09-17) made CUMULATIVE across phases: >= 3 cumulative VIOLATED at
# >= 2/3 confirmed true positives with UNDECLARED < 20%, and no ruling at all
# below 15 cumulative declared rows. The per-phase bar this comment used to
# name was withdrawn as unreachable. Still the DEC's call to make on
# `dispatch`-station numbers, not this hook's.
#
# What a clean run establishes: the tool compares reality against a label
# supplied by the same author who wrote the possibly-defective criterion. That
# is validation of BOOKKEEPING, not of the oracle. The output says "declared
# pre-state matched" and must never be read as "oracles valid".
#
# Fires: PreToolUse on Agent|Task
# Gate:  subagent_type == gsd-executor, in a GSD project, with dhx-tools present
# Exit:  always 0

INPUT=$(cat)

command -v jq   >/dev/null 2>&1 || exit 0
command -v node >/dev/null 2>&1 || exit 0

AGENT_TYPE=$(printf '%s' "$INPUT" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null)
[ "$AGENT_TYPE" = "gsd-executor" ] || exit 0

# Existence-gated exactly as item F is: a machine without dhx-tools sees zero change.
TOOL="$HOME/.claude/dhx-tools/oracle-prestate-check.cjs"
[ -f "$TOOL" ] || exit 0

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$CWD" ] || CWD="$(pwd)"
[ -d "$CWD" ] || exit 0

# GSD project: .planning/config.json under cwd, or under the git toplevel of cwd.
REPO=""
if [ -f "$CWD/.planning/config.json" ]; then
  REPO="$CWD"
else
  TOP=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)
  if [ -n "$TOP" ] && [ -f "$TOP/.planning/config.json" ]; then
    REPO="$TOP"
  fi
fi
[ -n "$REPO" ] || exit 0

PROMPT=$(printf '%s' "$INPUT" | jq -r '.tool_input.prompt // empty' 2>/dev/null)

# ---------------------------------------------------------------- extraction --
# Plan paths are extracted from the dispatch prompt, then VALIDATED — never
# trusted. An optional absolute prefix is captured so an absolute hit can be
# tested for containment in this repo rather than silently re-rooted here: a
# bare `.planning/...` match would otherwise map another repo's plan onto a
# same-named plan of ours. Delimiters excluded from the tail are the ones that
# actually wrap a path in a dispatch prompt: whitespace, quotes, backticks,
# commas and parens (markdown links and prose).
PLAN_RE='(/[^[:space:]"'"'"'`,()]*)?\.planning/(phases|quick)/[^[:space:]"'"'"'`,()]*-PLAN\.md'

PLANS=()
SEEN=""
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  case "$hit" in
    /*)
      # A leading `/` does NOT prove an absolute path. The mainline dispatch
      # shape renders the root as an UNEXPANDED variable —
      # `${PROJECT_ROOT}/.planning/phases/NN-…/NN-MM-PLAN.md`, measured in 9
      # resource-monitor transcripts across phases 01/02/03 on 2026-09-02 — and
      # the prefix group then captures only the `/` after the brace, yielding
      # `/.planning/…`. Tested for containment that fails, so every such
      # dispatch was dropped and the station never ran on the path the gate was
      # built for. Resolve the ambiguity on DISK, which is the one authority:
      #   exists  -> a real absolute path; it must lie under this repo or it is
      #              another repo's plan and re-rooting it here would map it
      #              onto a same-named plan of ours (the original hazard, kept).
      #   absent  -> the leading segments are an expansion artifact; retry the
      #              `.planning/` tail as repo-relative and let the existence
      #              check below be the validator, exactly as for a bare hit.
      if [ -e "$hit" ]; then
        case "$hit" in
          "$REPO"/*) abs="$hit" ;;
          *) continue ;;
        esac
      else
        abs="$REPO/.planning/${hit#*/.planning/}"
      fi
      ;;
    *) abs="$REPO/$hit" ;;
  esac
  [ -f "$abs" ] || continue          # a named plan that is not on disk is not measurable
  case "$SEEN" in
    *"|$abs|"*) continue ;;          # one record per DISTINCT plan
  esac
  SEEN="$SEEN|$abs|"
  PLANS+=("$abs")
done < <(grep -oE "$PLAN_RE" <<<"$PROMPT" 2>/dev/null | sort -u)

emit() {
  jq -n --arg m "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$m}}'
}

# Fail-VISIBLE on zero plans. No record is written: the tool writes records only
# for plans it measured, and a fabricated record would poison the firing rate
# that the DEC's promote/retire conditions are read from.
if [ ${#PLANS[@]} -eq 0 ]; then
  MSG='oracle pre-state gate (dispatch): no plan path found in the dispatch prompt — the dispatch station did not run'
  printf '%s\n' "$MSG" >&2
  emit "$MSG"
  exit 0
fi

# ------------------------------------------------------------------- phase ----
# Derived from the `phases/NN…` segment, and only when every plan agrees.
# `.planning/quick/` plans carry no phase, so --phase is omitted for them.
PHASE=""
PHASE_CONFLICT=0
for p in "${PLANS[@]}"; do
  rel="${p#"$REPO"/}"
  case "$rel" in
    .planning/phases/*)
      seg="${rel#.planning/phases/}"
      nn="${seg%%-*}"
      case "$nn" in
        ''|*[!0-9]*) n="" ;;
        *) n=$((10#$nn)) ;;
      esac
      ;;
    *) n="" ;;
  esac
  if [ -z "$PHASE" ]; then
    PHASE="$n"
  elif [ "$PHASE" != "$n" ]; then
    PHASE_CONFLICT=1
  fi
done
[ "$PHASE_CONFLICT" -eq 1 ] && PHASE=""

# --------------------------------------------------------------------- run ----
ARGS=(--repo "$REPO")
[ -n "$PHASE" ] && ARGS+=(--phase "$PHASE")
ARGS+=(--station dispatch)

ERRF=$(mktemp) || exit 0
trap 'rm -f "$ERRF"' EXIT

# The tool measured ~25 ms per plan (2026-09-02). The 20s cap is hook-side head-
# room inside the manifest's 30s: a timeout kills the run with rc 124, which
# lands in the gate-command-failure arm and is reported, never read as clean.
if command -v timeout >/dev/null 2>&1; then
  OUT=$(timeout 20 node "$TOOL" "${ARGS[@]}" "${PLANS[@]}" 2>"$ERRF")
else
  OUT=$(node "$TOOL" "${ARGS[@]}" "${PLANS[@]}" 2>"$ERRF")
fi
RC=$?
ERR=$(cat "$ERRF" 2>/dev/null)

# The record's tree_sha is this repo's HEAD at PreToolUse time, and the executor
# worktree is cut from the HEAD the orchestrator stamps immediately before
# dispatch. Echoing it lets the orchestrator compare the two by eye.
TREE_SHA=$(git -C "$REPO" rev-parse HEAD 2>/dev/null)
[ -n "$TREE_SHA" ] || TREE_SHA="unknown"

# ------------------------------------------------- three-way disposition ------
# Mirrored from item F. The tool also exits non-zero on usage / file / extraction
# errors WITHOUT the marker; do NOT collapse to "non-zero = finding".
if [ "$RC" -eq 0 ]; then
  SUMMARY=$(grep -m1 '^declared pre-state matched' <<<"$OUT")
  [ -n "$SUMMARY" ] || SUMMARY='declared pre-state matched (no summary line returned)'
  MSG="oracle pre-state gate (dispatch): $SUMMARY
tree_sha=$TREE_SHA
This validates bookkeeping, not the oracle: a mis-declared clause reads as honoured."
elif grep -q 'ORACLE_PRESTATE_VIOLATED' <<<"$ERR"; then
  MARKER_LINE=$(grep -m1 'ORACLE_PRESTATE_VIOLATED' <<<"$ERR")
  ROWS=$(sed -n '/^VIOLATED/,$p' <<<"$OUT")
  MSG="oracle pre-state gate (dispatch): $MARKER_LINE
$ROWS
report-only: dispatch proceeds; the operator may stop by hand
tree_sha=$TREE_SHA"
else
  FIRST_ERR=$(grep -m1 . <<<"$ERR")
  [ -n "$FIRST_ERR" ] || FIRST_ERR="exit $RC with no diagnostic"
  MSG="oracle pre-state gate (dispatch): gate-command failure: $FIRST_ERR
This run is NOT clean — the gate did not complete. rc=$RC tree_sha=$TREE_SHA"
fi

emit "$MSG"
exit 0
