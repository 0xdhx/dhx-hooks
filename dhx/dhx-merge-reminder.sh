#!/usr/bin/env bash
# dhx-merge-reminder.sh — PostToolUse hook (matcher: Skill)
# Patterns: HP-010
# After /gsd-complete-milestone or /gsd-audit-milestone, reminds user
# to merge working branch into main to reset worktree divergence.
# Non-blocking (exit 0). Silent when already on main.

INPUT=$(cat)
SKILL=$(echo "$INPUT" | jq -r '.tool_input.skill // empty' 2>/dev/null)
if [ -z "$SKILL" ]; then exit 0; fi

# Only fire on milestone completion skills
case "$SKILL" in
  gsd-complete-milestone|gsd-audit-milestone) ;;
  *) exit 0 ;;
esac

# No-op if already on main
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ]; then exit 0; fi

cat <<EOF
Milestone complete. Merge to main to reset worktree divergence:
  git checkout main && git merge $BRANCH && git checkout $BRANCH
EOF
