#!/usr/bin/env bash
# dhx-milestone-close-blocker-check.sh — Stop hook
# Patterns: HP-002 (loop-prevention), HP-009 (block JSON), HP-017 (plugin-manifest), HP-020 (Stop plugin-hosted), HP-048 (STATE progress-block phase-completion)
# Surfaces open `urgency: milestone-close` items as session-end blockers.
# Compose-pair: /dhx:audit checkpoint 11 (model-side calibration, opt-in)
# + this hook (deterministic backstop). See docs/decisions.md 2026-05-18 row.
#
# Trigger gate: STATE.md `status:` matches `verifying|milestone-shipped` (D-01;
# 10-repo empirical anchor — `audit`/`complete` are never written by
# gsd-tools.cjs:358 despite spec recommendation; frontmatter-isolated parse
# prevents body-text false-positive per D-16).
#
# Parallel-execution discriminator (HP-048; report 2026-07-08): `verifying` is a
# PHASE-level status GSD writes on every linear current_phase completion, so under
# PARALLEL milestone execution it lands mid-milestone and the D-01 proxy false-fires
# on every Stop. The `verifying` branch is therefore gated on the STATE `progress:`
# counter — suppressed ONLY when it positively confirms phases remain
# (completed_phases < total_phases). `milestone-shipped` never suppresses; an absent
# or unparseable progress block fails toward firing (silent risks missing a blocker).
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
# The `n==1` awk band restricts the parse to the first --- … --- YAML
# frontmatter block — prevents body-text false-positives where STATE.md
# prose contains phrases like "current status: verifying" outside frontmatter.
# Frontmatter is captured once and reused for the status check AND the
# progress-block parse below.
# Use process-substitution + grep `<` (NOT `cmd | grep`) per HP-028: keeps
# the LHS out of any future pipefail watch (probe-sigpipe-pipefail-shapes.sh).
STATE_FILE="$CWD/.planning/STATE.md"
if [ ! -f "$STATE_FILE" ]; then exit 0; fi
FRONTMATTER=$(awk '/^---$/{n++; next} n==1{print}' "$STATE_FILE" 2>/dev/null)
if ! grep -qE '^status:[[:space:]]+(verifying|milestone-shipped)\b' \
     < <(printf '%s\n' "$FRONTMATTER"); then
  exit 0
fi

# Parallel-execution discriminator (HP-048). Suppress the `verifying` case ONLY when
# the STATE `progress:` counter positively confirms phases remain. `milestone-shipped`
# skips this block entirely (unambiguous close). Absent/unparseable progress → both
# vars empty → condition false → fall through and fire (fail toward the blocker).
# awk numeric extract: anchor on `..._phases:` (NOT `..._plans:`) then strip non-digits.
if grep -qE '^status:[[:space:]]+verifying\b' < <(printf '%s\n' "$FRONTMATTER"); then
  COMPLETED_PHASES=$(awk '/^[[:space:]]*completed_phases:[[:space:]]*[0-9]+/{v=$0; gsub(/[^0-9]/,"",v); print v; exit}' <<< "$FRONTMATTER")
  TOTAL_PHASES=$(awk '/^[[:space:]]*total_phases:[[:space:]]*[0-9]+/{v=$0; gsub(/[^0-9]/,"",v); print v; exit}' <<< "$FRONTMATTER")
  if [ -n "$COMPLETED_PHASES" ] && [ -n "$TOTAL_PHASES" ] && [ "$COMPLETED_PHASES" -lt "$TOTAL_PHASES" ]; then
    exit 0
  fi
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
