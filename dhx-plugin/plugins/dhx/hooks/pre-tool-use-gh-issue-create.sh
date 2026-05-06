#!/usr/bin/env bash
# pre-tool-use-gh-issue-create.sh — PreToolUse:Bash matcher (Phase 7 — REQ-UPSTR-01)
#
# Soft-deny: warns when `gh issue create` runs outside the /dhx:upstream skill
# surface. Verifies fresh marker file
# `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/dhx-tools/.upstream-marker-<session-id>`
# written by run.sh at Stage 7 start (5-min TTL).
#
# Wiring: registered in this plugin's `hooks.json` PreToolUse array as a
# `Bash` matcher (RESEARCH Track 3 Q3.1 Option A — plugin-manifest channel,
# NOT shared settings.json). Auto-distributes across CCS instances when the
# plugin updates. Diverges from `~/.claude/hooks/dhx-worktree-bash-guard.sh`
# (which uses settings.json wiring) — see 07-RESEARCH Risk 2 closure.
#
# Hard-deny upgrade path (D-12 deferred): change the final `exit 0` after
# the warning to `exit 1` and the warning text to a denial message.
# Backlog: 2026-05-06-dhx-upstream-hard-deny-upgrade.md.
#
# Match grep is token-anchored to handle:
#   - `gh issue create --title x --body y`        (canonical)
#   - `bash -c 'gh issue create ...'`             (wrapper)
#   - `gh issue create | tee log.txt`             (piped)
#   - leading/trailing whitespace
# But NOT:
#   - `gh issue list`                             (different subcmd)
#   - `gh issue create-something-else`            (alphanumeric continuation)
#   - `mygh issue create`                         (alphanumeric prefix)

set -euo pipefail

INPUT=$(cat)

# jq absent -> defensive no-op (cannot parse stdin)
if ! command -v jq >/dev/null 2>&1; then exit 0; fi

# Parse cwd + command from PreToolUse stdin JSON
IFS=$'\t' read -r CWD CMD < <(jq -r '[.cwd // "", .tool_input.command // ""] | @tsv' <<<"$INPUT" 2>/dev/null || echo $'\t')

# Match `gh issue create` (token-anchored)
if ! grep -qE '(^|[^[:alnum:]_])gh[[:space:]]+issue[[:space:]]+create([[:space:]]|$)' <<< "$CMD"; then
  exit 0
fi

# Resolve session_id; defensive no-op if missing
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
[ -n "$SESSION_ID" ] || exit 0

MARKER_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/dhx-tools"
MARKER="$MARKER_DIR/.upstream-marker-$SESSION_ID"

# Stale check: marker absent OR older than 5 minutes -> warn (5-min TTL)
if [ ! -f "$MARKER" ] || [ "$(find "$MARKER" -mmin -5 2>/dev/null)" = "" ]; then
  cat <<'WARN_EOF'
/dhx:upstream pre-flight not engaged for this filing.

The 7-stage discipline (pristine fetch, fork audit, self-shim audit, redaction sweep,
search corpus, evidence inventory, atomic wire-up) protects upstream credibility.
Run /dhx:upstream <report-path> instead of bare 'gh issue create'.

(Soft warning only — proceeding with 'gh issue create' is allowed. Hard-deny upgrade
deferred per CONTEXT.md D-12; backlog: 2026-05-06-dhx-upstream-hard-deny-upgrade.md.)
WARN_EOF
fi
exit 0
