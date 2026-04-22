#!/usr/bin/env bash
# dhx-write-cache.sh — PostToolUse:Write|Edit hook
# Patterns: HP-003, HP-007
#
# Mirrors successful Write/Edit operations into the global reads.jsonl
# cache so dhx-read-guard.js no longer fires false-positive advisories
# on Write-create -> Edit chains.
#
# Mechanism: PostToolUse fires only after CC's runtime accepted the
# operation. CC's runtime read-before-edit check passes in two cases:
#   1. The file was Read this session (read-once/hook.sh populates cache)
#   2. The Write created a new file (no prior content to "see")
# Case 2 is the false-positive class for dhx-read-guard.js, which only
# tracks Read events. This hook closes the gap by appending an entry on
# every successful Write|Edit — propagating CC's "seen" state into the
# read-guard's cache.
#
# INVARIANT: this hook MUST emit {"path":<abs>,"ts":<unix>} format
# matching the schema in dhx-read-guard.js:14 and read-once/hook.sh:169.
# Probe: tests/probes/probe-write-cache.sh asserts schema parity.
#
# Scope (audit 2026-04-21): intent is parent+subagent uniform — the global
# reads.jsonl cache should reflect ALL CC-runtime-accepted Write/Edit
# operations regardless of context, so dhx-read-guard.js's advisory stays
# accurate across parent and subagent. HP-003 PostToolUse propagation is
# UNVERIFIED (HP-003 table); if it does not propagate, subagent writes do
# not seed the cache and parent may get spurious advisories on files the
# subagent created. Tracked by backlog row hp-003-other-matcher-propagation-
# probes. Do NOT branch on agent_id. The emitted path is absolute via
# realpath — correct across both parent and subagent worktree cwds.
#
# Fires: PostToolUse on Write or Edit
# Action: cache-write only, no stdout, no blocking

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
case "$TOOL_NAME" in
  Write|Edit) ;;
  *) exit 0 ;;
esac

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$FILE_PATH" ] && exit 0

RESOLVED=$(realpath "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")

GLOBAL_CACHE="${HOME}/.claude/read-once/reads.jsonl"
mkdir -p "$(dirname "$GLOBAL_CACHE")"
echo "{\"path\":\"$RESOLVED\",\"ts\":$(date +%s)}" >> "$GLOBAL_CACHE"

exit 0
