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
# INVARIANT: this hook MUST emit {"path":<abs>,"ts":<unix>,"source":"write"}
# format matching the D-08 schema in dhx-read-guard.js header doc-string and
# the dhx-read-cache.sh writer's `source:"read"` template. Schema parity is
# what lets the guard's accumulator treat write entries as "you've seen the
# bytes" full reads (closes the Write-create→Edit false-positive class).
#
# D-17 INVARIANT: this writer MUST NOT emit `partial:true` with `source:"write"`.
# `partial` semantics apply only to Read-tool partial loads (offset/limit) —
# Write/Edit operations always touch the full file. Guard treats any partial:true
# entry as partial regardless of source (defense-in-depth — see guard header),
# but emitting the forbidden combo here would be a writer regression.
#
# Probe: tests/probes/probe-write-cache.sh asserts new XDG path + source field.
#
# Scope (audit 2026-04-21, campaign 2026-04-21): intent is parent+subagent
# uniform — the global reads.jsonl cache should reflect ALL CC-runtime-
# accepted Write/Edit operations regardless of context. HP-003 campaign
# verified PostToolUse:Write|Edit propagation — subagent writes DO fire
# this hook and seed the cache, so dhx-read-guard.js's advisory stays
# accurate across parent and subagent. Do NOT branch on agent_id. The
# emitted path is absolute via realpath — correct across both parent and
# subagent worktree cwds.
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

GLOBAL_CACHE="${HOME}/.cache/dhx/read-cache.jsonl"
mkdir -p "$(dirname "$GLOBAL_CACHE")"
# WR-01: jq for JSONL escaping — paths containing `"` no longer break schema.
jq -cn --arg path "$RESOLVED" --argjson ts "$(date +%s)" \
  '{path: $path, ts: $ts, source: "write"}' >> "$GLOBAL_CACHE"

exit 0
