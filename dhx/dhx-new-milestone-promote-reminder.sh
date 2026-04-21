#!/usr/bin/env bash
# dhx-new-milestone-promote-reminder.sh — PostToolUse hook (matcher: Skill)
# Patterns: HP-010
# After /gsd-new-milestone declares a new milestone, scans .planning/backlog/
# for `target_milestone: next` (exact) and `next+[1-3]` briefs and reminds
# the user to run /dhx:backlog promote-next. Non-blocking (exit 0). Silent
# when no matching briefs exist or preconditions unmet.

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

for brief in "$BACKLOG_DIR"/*.md; do
  [ -f "$brief" ] || continue
  tm=$(head -30 "$brief" | grep -E '^target_milestone:' | head -1 \
    | sed -E 's/^target_milestone:[[:space:]]*//' | tr -d '"'"'")
  case "$tm" in
    next)           NEXT_COUNT=$((NEXT_COUNT + 1)) ;;
    next+[1-3])     NEXT_PLUS_COUNT=$((NEXT_PLUS_COUNT + 1)) ;;
  esac
done

[ $NEXT_COUNT -eq 0 ] && [ $NEXT_PLUS_COUNT -eq 0 ] && exit 0

if [ $NEXT_COUNT -gt 0 ] && [ $NEXT_PLUS_COUNT -gt 0 ]; then
  echo "Milestone $VERSION declared. $NEXT_COUNT 'next' + $NEXT_PLUS_COUNT 'next+N' backlog brief(s) ready for promotion."
elif [ $NEXT_COUNT -gt 0 ]; then
  echo "Milestone $VERSION declared. $NEXT_COUNT 'next'-tagged backlog brief(s) ready for promotion."
else
  echo "Milestone $VERSION declared. $NEXT_PLUS_COUNT 'next+N' backlog brief(s) eligible for opt-in demotion."
fi
echo "Run /dhx:backlog promote-next to reassign frontmatter."
exit 0
