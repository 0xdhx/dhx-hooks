#!/usr/bin/env bash
# dhx-milestone-close-blocker-pretooluse.sh — PreToolUse:Skill hook
# Patterns: HP-009 (PreToolUse exit-2 block), HP-010 (.tool_input.skill),
#           HP-017 (plugin manifest), HP-030 (PreToolUse:Skill firing asymmetric — H1 verdict)
#
# Shape B complement to dhx-milestone-close-blocker-check.sh (Plan 13-01 Stop hook).
# HP-030 ASYMMETRY: fires ONLY for model-invoked Skill dispatches (Skill tool path).
# Operator-typed `/gsd-complete-milestone` bypasses this hook — Plan 13-01's Stop
# hook is the catch-all for the operator-typed path. Verdict source: Plan 13-02
# spike (.planning/phases/13-milestone-close-blocker-stop-hook-mc-blocker/13-02-SUMMARY.md).
#
# Compose-pair: Shape A (Stop, deterministic backstop, fires at session-end on both
# paths) + Shape B (this hook, model-invoked early-fire, blocks before Skill executes).
# Trigger gate, surface scan, and block message all mirror Plan 13-01 verbatim.

readonly URGENCY_MILESTONE_CLOSE='milestone-close'  # D-02 + D-07 drift probe
readonly TARGET_SKILL='gsd-complete-milestone'      # HP-030 Skill-identifier gate

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then exit 0; fi

# Skill-identifier gate (HP-010 .tool_input.skill — confirmed for PreToolUse path
# by Plan 13-02 spike with tool_input_keys=skill as sole key in fire envelope).
SKILL=$(echo "$INPUT" | jq -r '.tool_input.skill // empty')
if [ "$SKILL" != "$TARGET_SKILL" ]; then exit 0; fi

CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
if [ -z "$CWD" ]; then exit 0; fi

if [ ! -d "$CWD/.planning" ]; then exit 0; fi

# Trigger gate (D-01 + D-16): frontmatter-isolated status check (HP-028 grep `<` form).
STATE_FILE="$CWD/.planning/STATE.md"
if [ ! -f "$STATE_FILE" ]; then exit 0; fi
if ! grep -qE '^status:[[:space:]]+(verifying|milestone-shipped)\b' \
     < <(awk '/^---$/{n++; next} n==1{print}' "$STATE_FILE" 2>/dev/null); then
  exit 0
fi

# Surface A: BACKLOG.md ## Milestone Close group (D-08 dual-form header pattern)
MC_BACKLOG_COUNT=0
BACKLOG_MD="$CWD/.planning/BACKLOG.md"
if [ -f "$BACKLOG_MD" ]; then
  MC_BACKLOG_COUNT=$(awk '
    /^## Milestone Close($|[[:space:]])/ { in_group=1; next }
    /^## / && in_group { in_group=0 }
    in_group && /^\| \[/ { count++ }
    END { print count+0 }
  ' "$BACKLOG_MD")
fi

# Surface B: todos/pending urgency frontmatter (D-15 -maxdepth 1 hermetic scan)
MC_TODO_COUNT=0
TODOS_DIR="$CWD/.planning/todos/pending"
if [ -d "$TODOS_DIR" ]; then
  while IFS= read -r todo_file; do
    if grep -qE "^urgency:[[:space:]]+${URGENCY_MILESTONE_CLOSE}\b" "$todo_file" 2>/dev/null; then
      MC_TODO_COUNT=$((MC_TODO_COUNT + 1))
    fi
  done < <(find "$TODOS_DIR" -maxdepth 1 -name '*.md' -type f 2>/dev/null)
fi

TOTAL=$((MC_BACKLOG_COUNT + MC_TODO_COUNT))
if [ "$TOTAL" -eq 0 ]; then exit 0; fi

# Block path (HP-009 PreToolUse): stderr block message + exit 2. Same 5-line shape
# as Plan 13-01 (D-09 + BACKLOG-INTEGRATION item 3 — no marker-legend cheat-sheet).
cat >&2 <<EOF
MILESTONE-CLOSE BLOCKERS — ${TOTAL} open item(s) flagged \`urgency: milestone-close\`:
  - ${MC_BACKLOG_COUNT} in BACKLOG.md (Milestone Close group)
  - ${MC_TODO_COUNT} in .planning/todos/pending/

Address before milestone archive, downgrade (re-capture without urgency), or
re-target with explicit authorization. Run /dhx:audit for per-item routing.
EOF

exit 2
