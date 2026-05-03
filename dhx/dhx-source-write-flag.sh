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
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // ""')
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // ""')

_TMPDIR="${TMPDIR:-${TEMP:-/tmp}}"

SOURCE_EXTS="py js ts tsx jsx rs go"

# INVARIANT: flag file is keyed by SESSION_ID from stdin. Subagent
# propagated fires carry the PARENT's session_id (HP-003 verified), so
# the parent's Stop consumer always sees the flag. No agent_id branch.
#
# Diagnostic log (no behavior change, 2026-05-03): when the flag is set,
# we append one line to ~/.cache/dhx/source-write-flag.log capturing the
# extension, file path, parent session_id, and (when subagent-propagated)
# agent_id + agent_type. Closes the perception/reality gap from the test-
# gate Q5 framing — when a user perceives "doc-only turn fired the gate,"
# `grep agent_id= ~/.cache/dhx/source-write-flag.log | tail` shows which
# subagent wrote a tracked source file under the parent's session.
EXT="${FILE_PATH##*.}"
for src_ext in $SOURCE_EXTS; do
  if [ "$EXT" = "$src_ext" ]; then
    touch "$_TMPDIR/claude-source-dirty-${SESSION_ID}.flag"
    mkdir -p "$HOME/.cache/dhx" 2>/dev/null || true
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] ext=$EXT path=$FILE_PATH session=$SESSION_ID agent_id=$AGENT_ID agent_type=$AGENT_TYPE" \
      >> "$HOME/.cache/dhx/source-write-flag.log" 2>/dev/null || true
    break
  fi
done

exit 0
