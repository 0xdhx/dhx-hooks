#!/usr/bin/env bash
# dhx-session-registry-end.sh — SessionEnd hook
# Patterns: HP-042 (SessionEnd fires + provides session_id + is plugin-hostable), HP-017 (plugin manifest)
#
# Appends one `end` row to the shared session registry on clean session exit. A
# crash (kill -9 / power loss) kills the process before SessionEnd fires, so a
# crashed session correctly leaves a `start` with NO matching `end` — which the
# consumer's reduce reads as "alive at crash". That is the whole mechanism: the
# absence of an end row, not its presence, is the signal.
#
# Contract: ~/repos/cross-repo/.planning/backlog/2026-06-08-alive-session-recovery-registry.md
# Registry path is LITERAL $HOME/.claude (see dhx-session-registry-start.sh header
# for the per-instance-fragmentation rationale).
#
# Row (3-field TSV — end rows need only ts,end,uuid per contract; the consumer
# keys the reduce on uuid, so the trailing instance/slug/repo/tmux fields are
# intentionally omitted, not empty-padded):
#   <iso_ts>\tend\t<uuid>
#
# Fail-open: SessionEnd cannot block termination (confirmed against the live hooks
# doc, 2026-06-08); any error => exit 0 silently. Fires on every end `reason`
# (clear|resume|logout|prompt_input_exit|bypass_permissions_disabled|other) — the
# manifest registers it with no matcher so all reasons record an end.
set -uo pipefail

REGISTRY="$HOME/.claude/dhx-session-registry.tsv"

INPUT=$(cat)

# Silent exit on unparseable JSON.
echo "$INPUT" | jq -e . >/dev/null 2>&1 || exit 0

UUID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
if [ -z "$UUID" ] && [ -n "$TRANSCRIPT" ]; then
  UUID=$(basename "$TRANSCRIPT" .jsonl)
fi
[ -n "$UUID" ] || exit 0

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '%s\t%s\t%s\n' "$TS" end "$UUID" >> "$REGISTRY"

exit 0
