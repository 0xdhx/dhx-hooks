#!/usr/bin/env bash
# ============================================================================
# RETIRED FROM MANIFEST (2026-06-13). The SessionStart entry that ran this hook
# was removed from dhx-plugin/plugins/dhx/hooks/hooks.json — all consumers of the
# `.current-session.id` stamp it wrote now resolve identity per-session via
# dhx-shared/lib/session-identity.sh (skills) / scripts/dhx-draft-buffer.sh (this
# repo). With zero live readers (verified across hooks + skills 2026-06-13), the
# stamp this writes is inert. Script kept on disk ONE CYCLE for one-line
# reversibility (re-add the hooks.json entry) per Checkpoint-8 deliberate-retirement
# (mirrors the dhx-plugin-cache-staleness-detector retirement, docs/decisions.md
# 2026-06-11). Live unwire takes effect on the operator's next `claude plugin
# install dhx@dhx-local --scope user` re-cache + `/exit`+resume (HP-012); until then
# the cached 0.1.x manifest keeps firing this harmlessly. See docs/decisions.md
# 2026-06-13 retirement row + docs/backlog.md current-session-stamp-retire-migrate.
# ============================================================================
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
# Known limitation (R-2): parallel CC sessions in the same cwd race; last writer
# wins. Resolver's mtime-newest fallback recovers the right value at synthesis time.
# Known limitation (R-4 / HP-012): hook does not fire for the session it was
# installed in — first stamp lands on the next session start.
# Known limitation (R-5, 2026-06-13 / HP-015 bridge addendum): SessionStart does
# NOT refresh this stamp for BRIDGED sessions (bridgeSessionId: cse_*) — verified
# frozen for /home/dhx/repos while >=3 bridge sessions ran for hours. Combined with
# R-2, a cwd-keyed singleton is the wrong shape for a multi-concurrent + bridge host.
# Verdict: migrate consumers to the pid-file (<cfg>/sessions/<pid>.json .sessionId,
# process-bound) and retire this hook — do NOT patch the producer. See
# docs/decisions.md 2026-06-13 row + docs/backlog.md current-session-stamp-retire-migrate.
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
