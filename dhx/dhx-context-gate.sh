#!/usr/bin/env bash
# dhx-context-gate.sh — PostToolUse hook (Write matcher)
# Patterns: HP-003, HP-007, HP-009
# Validates CONTEXT.md structural completeness on Write.
# Blocks (exit 2) when required DHX sections are missing.
# Accepts documented placeholder text as valid.
# Exits silently for non-CONTEXT.md files and non-GSD projects.
#
# Scope (audit 2026-04-21, campaign 2026-04-21): intent is parent+subagent
# uniform — the same structural invariants apply to CONTEXT.md regardless
# of who writes it. HP-003 campaign verified PostToolUse:Write propagation
# — subagent CONTEXT.md writes DO fire this gate, matching intent. No
# agent_id branch.
# Note: matcher is Write only (not Write|Edit) — Edit cannot rewrite
# tagged sections wholesale, so structural checks trigger on full Writes.

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then exit 0; fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Gate 1: Only CONTEXT.md files in .planning/phases/
case "$FILE_PATH" in
  */.planning/phases/*-CONTEXT.md|*\\.planning\\phases\\*-CONTEXT.md) ;;
  *) exit 0 ;;
esac

# Gate 2: Project uses GSD
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
if [ -n "$CWD" ] && [ ! -d "$CWD/.planning" ]; then
  exit 0
fi

CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')

# Gate 3: Only DHX-format CONTEXT.md (has tagged sections).
# Line-anchored — a backticked mention of `<decisions>` in body prose should
# not qualify a non-DHX file as DHX-format.
if ! echo "$CONTENT" | grep -qE '^[[:space:]]*<decisions>[[:space:]]*$'; then
  exit 0
fi

FAILURES=""

# Check 1: Numbered decisions (D-XX: pattern)
if ! echo "$CONTENT" | grep -qE 'D-[0-9]+:'; then
  FAILURES="${FAILURES}- Decisions are not numbered (use D-01, D-02, etc.)\n"
fi

# Check 2: Canonical refs populated or placeholder.
# Line-anchored pattern prevents body-prose mentions like
# "`<canonical_refs>` will hold the file list" (inside a decision) from
# shifting the sed range start into the middle of the document. Without
# anchoring, an empty canonical_refs block would be silently rescued by
# backticked bullets from earlier sections. See
REFS=$(echo "$CONTENT" | sed -n '/^[[:space:]]*<canonical_refs>[[:space:]]*$/,/^[[:space:]]*<\/canonical_refs>[[:space:]]*$/p')
if [ -z "$REFS" ]; then
  FAILURES="${FAILURES}- <canonical_refs> section is missing\n"
elif ! echo "$REFS" | grep -qE '(^\s*-\s*`|No external specs)'; then
  FAILURES="${FAILURES}- <canonical_refs> section is empty (add file paths or 'No external specs')\n"
fi

# Check 3: Deferred section exists. Same line-anchoring rationale as Check 2.
DEFERRED=$(echo "$CONTENT" | sed -n '/^[[:space:]]*<deferred>[[:space:]]*$/,/^[[:space:]]*<\/deferred>[[:space:]]*$/p')
if [ -z "$DEFERRED" ]; then
  FAILURES="${FAILURES}- <deferred> section is missing\n"
fi

# Check 4: Code context exists. Line-anchored so a body-prose mention of
# `<code_context>` cannot mask a missing section.
if ! echo "$CONTENT" | grep -qE '^[[:space:]]*<code_context>[[:space:]]*$'; then
  FAILURES="${FAILURES}- <code_context> section is missing\n"
fi

# Check 5: Specifics exists. Same line-anchoring rationale as Check 4.
if ! echo "$CONTENT" | grep -qE '^[[:space:]]*<specifics>[[:space:]]*$'; then
  FAILURES="${FAILURES}- <specifics> section is missing\n"
fi

# INVARIANT: block applies to parent AND subagent PostToolUse:Write
# (HP-003 campaign verified propagation). No agent_id branch.
if [ -n "$FAILURES" ]; then
  # Use jq for safe JSON construction
  jq -n --arg reason "$(printf "CONTEXT.md quality gate failures:\n${FAILURES}Fix these sections and rewrite the file.")" \
    '{"decision": "block", "reason": $reason}'
  exit 2
fi

exit 0
