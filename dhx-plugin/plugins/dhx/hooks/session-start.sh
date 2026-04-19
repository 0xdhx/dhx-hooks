#!/usr/bin/env bash
# dhx-plugin session-start dispatcher — invoked by plugin hooks.json.
# Logs probe + dispatches to the canonical dhx scripts in ~/.claude/hooks/.
# Receives the same stdin JSON CC hands the hook (session_id, source, etc.).
# Silent on happy path for both children; logs probe on every fire.

set -uo pipefail

INPUT=$(cat)
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
SID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null || echo unknown)
SRC=$(echo "$INPUT" | jq -r '.source // "unknown"' 2>/dev/null || echo unknown)
echo "[$TS] dhx-plugin-dispatch session=$SID source=$SRC" >> /tmp/dhx-plugin-probe.log

# Dispatch to canonical scripts. Hand each its own stdin copy.
# Run all three even if one fails — each is independent.
printf '%s' "$INPUT" | bash /home/dhx/.claude/hooks/dhx-health-check.sh || true
printf '%s' "$INPUT" | bash /home/dhx/.claude/hooks/dhx-dirty-tree.sh || true
printf '%s' "$INPUT" | bash /home/dhx/.claude/hooks/dhx-stale-worktree-sweep.sh || true

exit 0
