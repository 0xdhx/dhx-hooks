#!/usr/bin/env bash
# dhx-new-milestone-promote-reminder.sh — PostToolUse hook (matcher: Skill)
# Patterns: HP-010
# After /gsd-new-milestone declares a new milestone, scans .planning/backlog/
# for `target_milestone: next` (exact), `next+[1-3]`, and stale-version briefs
# (version tag <= the closing milestone) and reminds the user to run
# /dhx:backlog promote-next. Non-blocking (exit 0). Silent when no matching
# briefs exist or preconditions unmet.
#
# INVARIANT: the stale compare is <= (not <) because PostToolUse:Skill fires
# at Skill-tool return — instruction load, BEFORE the skill body rewrites
# PROJECT.md — so $VERSION is the CLOSING milestone and briefs tagged with
# exactly that version (the primary stale class; see skills
# docs/decisions/2026-07-16-promote-next-stale-pass.md) compare EQUAL.
# Future-version tags (> $VERSION) are legitimate scoping and never count.

INPUT=$(cat)
SKILL=$(echo "$INPUT" | jq -r '.tool_input.skill // empty' 2>/dev/null)
[ "$SKILL" = "gsd-new-milestone" ] || exit 0

CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$CWD" ] && CWD="$(pwd)"

BACKLOG_DIR="$CWD/.planning/backlog"
PROJECT_FILE="$CWD/.planning/PROJECT.md"

[ -d "$BACKLOG_DIR" ] || exit 0
[ -f "$PROJECT_FILE" ] || exit 0

VERSION=$(grep -E '^## Current Milestone: v[0-9]+\.[0-9]+' "$PROJECT_FILE" \
  | head -1 \
  | sed -E 's/^## Current Milestone: (v[0-9]+\.[0-9]+).*/\1/')
[ -n "$VERSION" ] || exit 0

NEXT_COUNT=0
NEXT_PLUS_COUNT=0
STALE_COUNT=0

VMAJ=${VERSION#v}; VMIN=${VMAJ#*.}; VMAJ=${VMAJ%%.*}

for brief in "$BACKLOG_DIR"/*.md; do
  [ -f "$brief" ] || continue
  tm=$(head -30 "$brief" | grep -E '^target_milestone:' | head -1 \
    | sed -E 's/^target_milestone:[[:space:]]*//' | tr -d '"'"'")
  case "$tm" in
    next)           NEXT_COUNT=$((NEXT_COUNT + 1)) ;;
    next+[1-3])     NEXT_PLUS_COUNT=$((NEXT_PLUS_COUNT + 1)) ;;
    v[0-9]*)
      grep -qE '^v[0-9]+(\.[0-9]+)?$' <<< "$tm" || continue
      t=${tm#v}; TMIN=0
      case "$t" in *.*) TMIN=${t#*.} ;; esac
      TMAJ=${t%%.*}
      # per-component numeric compare (v1.10 > v1.9); <= per header INVARIANT
      if [ "$TMAJ" -lt "$VMAJ" ] || { [ "$TMAJ" -eq "$VMAJ" ] && [ "$TMIN" -le "$VMIN" ]; }; then
        STALE_COUNT=$((STALE_COUNT + 1))
      fi ;;
  esac
done

[ $NEXT_COUNT -eq 0 ] && [ $NEXT_PLUS_COUNT -eq 0 ] && [ $STALE_COUNT -eq 0 ] && exit 0

PARTS=""
[ $NEXT_COUNT -gt 0 ] && PARTS="$NEXT_COUNT 'next'"
[ $NEXT_PLUS_COUNT -gt 0 ] && PARTS="${PARTS:+$PARTS + }$NEXT_PLUS_COUNT 'next+N'"
[ $STALE_COUNT -gt 0 ] && PARTS="${PARTS:+$PARTS + }$STALE_COUNT stale-version"
echo "Milestone $VERSION declared. $PARTS backlog brief(s) ready for promotion."
echo "Run /dhx:backlog promote-next to reassign frontmatter."
exit 0
