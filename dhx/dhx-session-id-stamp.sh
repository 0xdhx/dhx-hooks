#!/usr/bin/env bash
# dhx-session-id-stamp.sh — SessionStart hook
# Patterns: HP-015 (SessionStart provides session_id), HP-017 (plugin manifest)
#
# Writes the current session_id + transcript_path to a deterministic file
# under the project's JSONL dir, so skills (specifically /dhx:report skill-use
# and /dhx:skills field-review) can resolve session provenance without
# prompting the user.
#
# Output file: <CLAUDE_CONFIG_DIR-resolved>/projects/<encoded-cwd>/.current-session.id
# Format    : <session_id>\t<transcript_path>\t<cwd>\t<iso8601-ts>\n  (single TSV line)
#
# Spec: ~/repos/skills/reports/2026-05-03-session-id-jsonl-context-spec.md
# Known limitation (R-2): parallel CC sessions in the same cwd race; last writer
# wins. Resolver's mtime-newest fallback recovers the right value at synthesis time.
# Known limitation (R-4 / HP-012): hook does not fire for the session it was
# installed in — first stamp lands on the next session start.
set -euo pipefail

INPUT=$(cat)

# Defensive: silent exit on unparseable JSON. SessionStart must never fail
# (per docs/hook-dev-guide.md). Without this guard, set -e + pipefail would
# propagate jq's non-zero exit through the command substitutions below.
echo "$INPUT" | jq -e . >/dev/null 2>&1 || exit 0

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty')
CWD=$(echo "$INPUT"        | jq -r '.workspace.current_dir // .cwd // empty')

# Silent exit on missing session_id — never fail SessionStart
[ -n "$SESSION_ID" ] || exit 0
[ -n "$CWD" ] || CWD="$PWD"

# Resolve the projects root the same way Claude Code does:
# follow CLAUDE_CONFIG_DIR (or default ~/.claude), then "projects/<encoded>".
# CCS users have CLAUDE_CONFIG_DIR pointing at /home/dhx/.ccs/instances/<a|b|c>;
# readlink -f resolves through any symlink chain to the physical root.
ROOT="$(readlink -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")/projects"
ENCODED=$(echo "$CWD" | sed 's|/|-|g')
DIR="$ROOT/$ENCODED"

# Defensive: only write if the JSONL dir already exists (Claude Code creates it
# at session init). Skip rather than spawning surprise dirs under projects/.
[ -d "$DIR" ] || exit 0

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '%s\t%s\t%s\t%s\n' "$SESSION_ID" "$TRANSCRIPT" "$CWD" "$TS" \
  > "$DIR/.current-session.id"

exit 0
