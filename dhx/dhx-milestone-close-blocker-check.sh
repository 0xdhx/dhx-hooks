#!/usr/bin/env bash
# dhx-milestone-close-blocker-check.sh — Stop hook
# Patterns: HP-002 (loop-prevention), HP-009 (block JSON), HP-017 (plugin-manifest), HP-020 (Stop plugin-hosted)
# Surfaces open `urgency: milestone-close` items as session-end blockers.
# Compose-pair: /dhx:audit checkpoint 11 (model-side calibration, opt-in)
# + this hook (deterministic backstop). See docs/decisions.md 2026-05-18 row.
#
# Trigger gate: STATE.md `status:` matches `verifying|milestone-shipped` (D-01;
# 10-repo empirical anchor — `audit`/`complete` are never written by
# gsd-tools.cjs:358 despite spec recommendation; frontmatter-isolated parse
# prevents body-text false-positive per D-16).
#
# Surface scan:
#   - BACKLOG.md `## Milestone Close[…]` group via awk header pattern
#     `^## Milestone Close($|[[:space:]])` — matches both bare and em-dash
#     forms produced by backlog-regen.cjs:461-464 (D-08).
#   - .planning/todos/pending/*.md frontmatter via `find -maxdepth 1` (D-15);
#     done/archived dirs intentionally excluded.
#
# Drift coupling: URGENCY_MILESTONE_CLOSE constant ⟷ backlog-regen.cjs:177
# CANONICAL_URGENCY Set; enforced by tests/probes/probe-milestone-close-vocab-parity.sh.

readonly URGENCY_MILESTONE_CLOSE='milestone-close'  # D-02 + D-07 drift probe

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then exit 0; fi

# Loop prevention (HP-002) — verbatim from dhx-deferred-check.sh:42-46
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then exit 0; fi

CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
if [ -z "$CWD" ]; then exit 0; fi

# GSD project gate (top-level surface scan, no per-phase scoping —
# variant of dhx-deferred-check.sh:52)
if [ ! -d "$CWD/.planning" ]; then exit 0; fi

# Trigger gate (D-01 + D-16): frontmatter-isolated status check.
# The `n==1` awk band restricts the grep to the first --- … --- YAML
# frontmatter block — prevents body-text false-positives where STATE.md
# prose contains phrases like "current status: verifying" outside frontmatter.
# Use process-substitution + grep `<` (NOT `cmd | grep`) per HP-028: keeps
# the LHS out of any future pipefail watch (probe-sigpipe-pipefail-shapes.sh).
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

# Surface B: todos/pending urgency frontmatter (D-15 find pattern —
# -maxdepth 1 prevents done/archived/ cross-counting; -type f keeps subdirs out)
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

# Block message (D-09 + BACKLOG-INTEGRATION item 3 — 5 lines excluding bullets;
# NO marker-legend / vocabulary cheat-sheet inheritance from dhx-deferred-check.sh:225-238)
MSG="MILESTONE-CLOSE BLOCKERS — ${TOTAL} open item(s) flagged \`urgency: milestone-close\`:
  - ${MC_BACKLOG_COUNT} in BACKLOG.md (Milestone Close group)
  - ${MC_TODO_COUNT} in .planning/todos/pending/

Address before milestone archive, downgrade (re-capture without urgency), or
re-target with explicit authorization. Run /dhx:audit for per-item routing."

# Block JSON emission (HP-009 + verbatim from dhx-deferred-check.sh:240-241)
jq -n --arg msg "$MSG" \
  '{"decision": "block", "reason": $msg}'

exit 0
