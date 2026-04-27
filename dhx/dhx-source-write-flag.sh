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
# actually verify them.
# for the false-safety issue that motivated trimming this list.
#
# Scope (audit 2026-04-21, campaign 2026-04-21): intent is parent+subagent
# uniform — test-gate should run after subagent source writes that land in
# the repo. HP-003 campaign verified PostToolUse:Write|Edit propagation:
# subagent writes DO fire this hook with `session_id` = parent's session,
# so the flag is correctly addressed to the parent's Stop-time consumer.
# Intent matches actual; no agent_id branch.

set -uo pipefail

INPUT=$(cat)

if ! command -v jq &>/dev/null; then
  exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')

_TMPDIR="${TMPDIR:-${TEMP:-/tmp}}"

SOURCE_EXTS="py js ts tsx jsx rs go"

# INVARIANT: flag file is keyed by SESSION_ID from stdin. Subagent
# propagated fires carry the PARENT's session_id (HP-003 verified), so
# the parent's Stop consumer always sees the flag. No agent_id branch.
EXT="${FILE_PATH##*.}"
for src_ext in $SOURCE_EXTS; do
  if [ "$EXT" = "$src_ext" ]; then
    touch "$_TMPDIR/claude-source-dirty-${SESSION_ID}.flag"
    break
  fi
done

exit 0
