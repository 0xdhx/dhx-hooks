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
#
# Scope (audit 2026-04-21): intent is parent+subagent uniform — test-gate
# should run after subagent source writes that land in the repo. HP-003
# reframe verified PreToolUse:Write|Edit propagation; PostToolUse:Write|Edit
# propagation is UNVERIFIED (HP-003 table). If PostToolUse propagates,
# subagent writes set the flag keyed to the parent's session_id (per HP-003
# evidence that session_id is the parent's), so parent's Stop-time test-gate
# correctly runs. If propagation does NOT happen, subagent source writes
# silently skip the test-gate — a false-negative tracked by backlog row
# hp-003-other-matcher-propagation-probes. Do NOT branch on agent_id.

set -uo pipefail

INPUT=$(cat)

if ! command -v jq &>/dev/null; then
  exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')

_TMPDIR="${TMPDIR:-${TEMP:-/tmp}}"

SOURCE_EXTS="py js ts tsx jsx rs go"

# INVARIANT: flag file is keyed by SESSION_ID from stdin. For propagated
# subagent calls (if PostToolUse propagates — unverified), SESSION_ID is
# the PARENT's session per HP-003 evidence — so parent's Stop consumer
# sees the flag and runs tests. Uniform intent; no agent_id branch.
EXT="${FILE_PATH##*.}"
for src_ext in $SOURCE_EXTS; do
  if [ "$EXT" = "$src_ext" ]; then
    touch "$_TMPDIR/claude-source-dirty-${SESSION_ID}.flag"
    break
  fi
done

exit 0
