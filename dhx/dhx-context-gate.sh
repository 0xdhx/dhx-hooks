#!/usr/bin/env bash
# dhx-context-gate.sh — PostToolUse hook (Write matcher)
# Patterns: HP-007, HP-009
# Validates CONTEXT.md structural completeness on Write.
# Blocks (exit 2) when required DHX sections are missing.
# Accepts documented placeholder text as valid.
# Exits silently for non-CONTEXT.md files and non-GSD projects.

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

# Gate 3: Only DHX-format CONTEXT.md (has tagged sections)
if ! echo "$CONTENT" | grep -q '<decisions>'; then
  exit 0
fi

FAILURES=""

# Check 1: Numbered decisions (D-XX: pattern)
if ! echo "$CONTENT" | grep -qE 'D-[0-9]+:'; then
  FAILURES="${FAILURES}- Decisions are not numbered (use D-01, D-02, etc.)\n"
fi

# Check 2: Canonical refs populated or placeholder
REFS=$(echo "$CONTENT" | sed -n '/<canonical_refs>/,/<\/canonical_refs>/p')
if [ -z "$REFS" ]; then
  FAILURES="${FAILURES}- <canonical_refs> section is missing\n"
elif ! echo "$REFS" | grep -qE '(^\s*-\s*`|No external specs)'; then
  FAILURES="${FAILURES}- <canonical_refs> section is empty (add file paths or 'No external specs')\n"
fi

# Check 3: Deferred section exists
DEFERRED=$(echo "$CONTENT" | sed -n '/<deferred>/,/<\/deferred>/p')
if [ -z "$DEFERRED" ]; then
  FAILURES="${FAILURES}- <deferred> section is missing\n"
fi

# Check 4: Code context exists
if ! echo "$CONTENT" | grep -q '<code_context>'; then
  FAILURES="${FAILURES}- <code_context> section is missing\n"
fi

# Check 5: Specifics exists
if ! echo "$CONTENT" | grep -q '<specifics>'; then
  FAILURES="${FAILURES}- <specifics> section is missing\n"
fi

if [ -n "$FAILURES" ]; then
  # Use jq for safe JSON construction
  jq -n --arg reason "$(printf "CONTEXT.md quality gate failures:\n${FAILURES}Fix these sections and rewrite the file.")" \
    '{"decision": "block", "reason": $reason}'
  exit 2
fi

exit 0
