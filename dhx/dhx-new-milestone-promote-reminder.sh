#!/usr/bin/env bash
# dhx-new-milestone-promote-reminder.sh — PostToolUse hook (matcher: Skill)
# Patterns: HP-010
# Fires when /gsd-new-milestone is invoked and scans .planning/backlog/ for
# briefs that the upcoming cut will make promotable: `target_milestone: next`
# (exact), `next+[1-3]`, and stale-version tags. Emits a 2-line PRE-CUT
# heads-up. Non-blocking (exit 0). Silent when no matching briefs exist or
# preconditions unmet.
#
# WHAT THIS HOOK KNOWS, AND WHEN (read before retargeting it — 2026-09-04):
# PostToolUse:Skill fires at the Skill tool's RETURN — instruction load, BEFORE
# the skill body rewrites PROJECT.md. So at fire time the cut has NOT happened:
# $VERSION is the CLOSING milestone, and /dhx:backlog promote-next would exit 2
# if run at this instant. The hook therefore does NOT claim a milestone was
# declared and does NOT tell the operator to act now — it names the close and
# defers the action to "once the cut is committed". The post-cut call to action
# is owned by /dhx:new § Next Step (skills repo), which fires after the chain
# reaches its committed postcondition and is the authoritative signal; this
# hook is the pre-cut heads-up that also covers a bare /gsd-new-milestone.
# Retargeting to a later event was assessed and REJECTED 2026-09-04: the
# planner's own precondition is this same PROJECT.md heading (see PARSER
# PARITY), so later timing buys no precondition, and a cache-marker "did the
# version change" detector cannot distinguish a first observation of a repo
# from an actual declaration. See docs/decisions.md 2026-09-04 row.
#
# INVARIANT — the stale compare is <= (not <), and that is NOT an approximation:
# at fire time $VERSION is the CLOSING milestone, so briefs tagged <= closing
# are exactly the briefs that will compare < declared once the cut lands. The
# hook's <= at v1.5-closing and promote-next's < at v1.6-declared select the
# IDENTICAL set. Change one only if the other changes. Future-version tags
# (> $VERSION) are legitimate forward scoping and never count.
#
# PARSER PARITY — the version grammar below MUST mirror
# skills:scripts/backlog-promote-next.cjs (`parseProjectMilestone`,
# `parseVersionTag`, `cmpVersion`). A looser parser here makes the hook point
# at a command that then exits 2. Measured 2026-09-04 before this was aligned:
# on `## Current Milestone: v0.3.0 <Name>` the hook printed "Milestone v0.3
# declared" — a version string appearing nowhere in the file — while the
# planner returned version:null and exit 2 on the same file. Both grammars now
# accept vN, vN.M and vN.M.P, with absent components reading as 0.
# Drift teeth: tests/probes/probe-new-milestone-promote-reminder.sh (A11/A12).

INPUT=$(cat)
SKILL=$(echo "$INPUT" | jq -r '.tool_input.skill // empty' 2>/dev/null)
[ "$SKILL" = "gsd-new-milestone" ] || exit 0

CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$CWD" ] && CWD="$(pwd)"

BACKLOG_DIR="$CWD/.planning/backlog"
PROJECT_FILE="$CWD/.planning/PROJECT.md"

[ -d "$BACKLOG_DIR" ] || exit 0
[ -f "$PROJECT_FILE" ] || exit 0

# Milestone heading. Anchored end-to-end so the accept set matches the planner
# exactly: a version token, then optionally whitespace + a name, then EOL.
# `v0.3.0.1` is rejected here because the planner rejects it too.
MILESTONE_RX='^##[[:space:]]+Current Milestone:[[:space:]]+v[0-9]+(\.[0-9]+){0,2}([[:space:]]+.+)?[[:space:]]*$'
VERSION=$(grep -E "$MILESTONE_RX" "$PROJECT_FILE" \
  | head -1 \
  | sed -E 's/^##[[:space:]]+Current Milestone:[[:space:]]+(v[0-9]+(\.[0-9]+){0,2})([[:space:]].*)?$/\1/')
[ -n "$VERSION" ] || exit 0

# Split a vN[.M[.P]] token into three numeric components, absent ones as 0 —
# the bash mirror of the planner's parseVersionTag.
split_version() {
  local t=${1#v} maj min pat
  maj=${t%%.*}
  case "$t" in
    *.*.*) min=${t#*.}; min=${min%%.*}; pat=${t##*.} ;;
    *.*)   min=${t#*.};                 pat=0 ;;
    *)     min=0;                       pat=0 ;;
  esac
  printf '%s %s %s' "$maj" "$min" "$pat"
}

read -r VMAJ VMIN VPAT <<< "$(split_version "$VERSION")"

NEXT_COUNT=0
NEXT_PLUS_COUNT=0
STALE_COUNT=0

for brief in "$BACKLOG_DIR"/*.md; do
  [ -f "$brief" ] || continue
  tm=$(head -30 "$brief" | grep -E '^target_milestone:' | head -1 \
    | sed -E 's/^target_milestone:[[:space:]]*//' | tr -d '"'"'")
  case "$tm" in
    next)           NEXT_COUNT=$((NEXT_COUNT + 1)) ;;
    next+[1-3])     NEXT_PLUS_COUNT=$((NEXT_PLUS_COUNT + 1)) ;;
    v[0-9]*)
      # Same tag grammar as the planner's parseVersionTag: vN, vN.M, vN.M.P.
      grep -qE '^v[0-9]+(\.[0-9]+){0,2}$' <<< "$tm" || continue
      read -r TMAJ TMIN TPAT <<< "$(split_version "$tm")"
      # Per-component numeric compare (v1.10 > v1.9); <= per header INVARIANT.
      if [ "$TMAJ" -lt "$VMAJ" ] \
        || { [ "$TMAJ" -eq "$VMAJ" ] && [ "$TMIN" -lt "$VMIN" ]; } \
        || { [ "$TMAJ" -eq "$VMAJ" ] && [ "$TMIN" -eq "$VMIN" ] && [ "$TPAT" -le "$VPAT" ]; }; then
        STALE_COUNT=$((STALE_COUNT + 1))
      fi ;;
  esac
done

[ $NEXT_COUNT -eq 0 ] && [ $NEXT_PLUS_COUNT -eq 0 ] && [ $STALE_COUNT -eq 0 ] && exit 0

PARTS=""
[ $NEXT_COUNT -gt 0 ] && PARTS="$NEXT_COUNT 'next'"
[ $NEXT_PLUS_COUNT -gt 0 ] && PARTS="${PARTS:+$PARTS + }$NEXT_PLUS_COUNT 'next+N'"
[ $STALE_COUNT -gt 0 ] && PARTS="${PARTS:+$PARTS + }$STALE_COUNT stale-version"
# Two lines, per the 2026-04-20 output cap. "Closing", not "declared": at fire
# time the cut has not happened and $VERSION is the milestone being left.
echo "Closing $VERSION — $PARTS backlog brief(s) await promotion."
echo "Run /dhx:backlog promote-next once the cut is committed."
exit 0
