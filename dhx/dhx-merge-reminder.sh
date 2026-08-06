#!/usr/bin/env bash
# dhx-merge-reminder.sh — PostToolUse hook (matcher: Skill)
# Patterns: HP-010
# After /gsd-complete-milestone or /gsd-audit-milestone, reminds user
# to merge working branch into main to reset worktree divergence.
# Non-blocking (exit 0). Silent when already on main.
#
# Prints NO merge command (2026-08-06 sweep). The former one-liner
# `git checkout main && git merge $BRANCH && git checkout $BRANCH` moved the
# shared HEAD symref twice and left the primary off-main — the very state
# dhx-off-main-detector.sh warns about, whose text reads "Do NOT 'git checkout
# main' on the primary". Two hooks in one tree gave opposite instructions.
# Deleted rather than swapped, per D-2/D-7 of the 2026-05-08 council record.

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
Milestone complete — branch '$BRANCH' still diverges from main.
No merge command is printed here: on a shared primary, 'git checkout main'
moves the HEAD symref for every concurrent session, and the round trip back
leaves the primary off-main — the state dhx-off-main-detector.sh exists to
flag. Merge from an isolated lane instead; the route is the "Concurrent
sessions (shared working trees)" section of cross-repo CLAUDE.md.
EOF
