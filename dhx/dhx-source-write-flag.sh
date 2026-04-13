#!/usr/bin/env bash
# dhx-source-write-flag.sh — PostToolUse hook (Write|Edit matcher)
# Patterns: HP-003, HP-007
# Sets per-turn flag when a source file is written. The Stop hook
# (dhx-test-gate.sh) consumes this flag to decide whether to run tests.
# No flag = no source changes this turn = skip tests.
#
# Supported extensions: .py .js .ts .tsx .jsx .rs .go
# Only extensions with a matching runner in dhx-test-gate.sh's cascade
# are flagged. Do NOT add extensions without verifying the gate can
# actually verify them — see reports/done/2026-04-11-source-write-flag-sh-classification.md
# for the false-safety issue that motivated trimming this list.

set -uo pipefail

INPUT=$(cat)

if ! command -v jq &>/dev/null; then
  exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')

_TMPDIR="${TMPDIR:-${TEMP:-/tmp}}"

SOURCE_EXTS="py js ts tsx jsx rs go"

EXT="${FILE_PATH##*.}"
for src_ext in $SOURCE_EXTS; do
  if [ "$EXT" = "$src_ext" ]; then
    touch "$_TMPDIR/claude-source-dirty-${SESSION_ID}.flag"
    break
  fi
done

exit 0
