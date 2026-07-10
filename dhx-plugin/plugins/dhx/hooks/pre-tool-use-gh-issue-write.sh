#!/usr/bin/env bash
# pre-tool-use-gh-issue-write.sh — PreToolUse:Bash matcher (Phase 7 — REQ-UPSTR-01)
# Patterns: HP-049 (non-blocking warn surface), HP-009 (exit-2 blocks / exit-1 does not)
#
# Soft-deny: warns when `gh issue create` OR `gh issue comment` runs outside the
# /dhx:upstream skill surface. Both verbs are upstream mutations gated by the same
# marker file: `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/dhx-tools/.upstream-marker-<session-id>`.
# The create path writes it in run.sh (Stage 7 start); the reply/comment path writes
# the identical marker in run-comment.sh (Stage 7 start) — both 5-min TTL, both
# deleted on EXIT. A fresh marker => the gated pre-flight ran => hook stays silent.
# (Renamed from -gh-issue-create.sh when the `comment` verb was added — the create-only
# name no longer described the surface. See docs/decisions.md 2026-07-10 row.)
#
# Wiring: registered in this plugin's `hooks.json` PreToolUse array as a
# `Bash` matcher (RESEARCH Track 3 Q3.1 Option A — plugin-manifest channel,
# NOT shared settings.json). Auto-distributes across CCS instances when the
# plugin updates. Diverges from `~/.claude/hooks/dhx-worktree-bash-guard.sh`
# (which uses settings.json wiring) — see 07-RESEARCH Risk 2 closure.
#
# Surface (HP-049): a non-blocking advisory on PreToolUse:Bash must use the
# structured JSON fields — plain stdout is debug-log-only here and reaches NEITHER
# user nor model (the pre-rename OD-1 dead-warn bug). This hook emits `systemMessage`
# (the user channel — the only field that reaches the terminal) + `additionalContext`
# (the model channel), with `permissionDecision:"allow"` + exit 0 so it warns without
# blocking. NOTE: `allow` also AUTO-APPROVES the Bash call (bypasses the permission
# prompt) — a deliberate side effect here: the hook OWNS the allow/deny decision for
# this command, and the D-12 hard-deny flip is simply allow→deny (see below).
#
# Hard-deny upgrade path (D-12 deferred): flip the warn emit to a DENY —
# `permissionDecision:"deny"` + `exit 2` (exit 2 is the block per HP-009; exit 1 does
# NOT block, and plain stdout `echo BLOCK` never surfaces — HP-049). Leave systemMessage
# as the user-facing reason. Backlog: cross-repo 2026-05-06-dhx-upstream-hard-deny-upgrade.md.
#
# Match grep is token-anchored to handle:
#   - `gh issue create --title x --body y`        (canonical create)
#   - `gh issue comment 123 --body y`             (canonical comment / reply path)
#   - `bash -c 'gh issue create ...'`             (wrapper)
#   - `gh issue comment 42 | tee log.txt`         (piped)
#   - leading/trailing whitespace
# But NOT:
#   - `gh issue list`                             (different subcmd)
#   - `gh issue create-something-else`            (alphanumeric continuation)
#   - `mygh issue comment`                        (alphanumeric prefix)

set -euo pipefail

INPUT=$(cat)

# jq absent -> defensive no-op (cannot parse stdin)
if ! command -v jq >/dev/null 2>&1; then exit 0; fi

# Parse cwd + command from PreToolUse stdin JSON
IFS=$'\t' read -r CWD CMD < <(jq -r '[.cwd // "", .tool_input.command // ""] | @tsv' <<<"$INPUT" 2>/dev/null || echo $'\t')

# Match `gh issue create` OR `gh issue comment` (token-anchored)
if ! grep -qE '(^|[^[:alnum:]_])gh[[:space:]]+issue[[:space:]]+(create|comment)([[:space:]]|$)' <<< "$CMD"; then
  exit 0
fi

# Resolve session_id; defensive no-op if missing
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
[ -n "$SESSION_ID" ] || exit 0

MARKER_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/dhx-tools"
MARKER="$MARKER_DIR/.upstream-marker-$SESSION_ID"

# Stale check: marker absent OR older than 5 minutes -> warn (5-min TTL).
# Emit via HP-049 structured fields (systemMessage=user, additionalContext=model);
# permissionDecision:"allow" + exit 0 = non-blocking warn (see header note on auto-approve).
if [ ! -f "$MARKER" ] || [ "$(find "$MARKER" -mmin -5 2>/dev/null)" = "" ]; then
  cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "permissionDecisionReason": "No fresh /dhx:upstream marker for this session — this gh issue create/comment is running outside the gated upstream pre-flight. Non-blocking allow (soft warning; hard-deny deferred per D-12).",
    "additionalContext": "This 'gh issue create'/'gh issue comment' is running WITHOUT a fresh /dhx:upstream marker. The /dhx:upstream skill runs a 7-stage discipline (pristine fetch, fork audit, self-shim audit, redaction sweep, search corpus, evidence inventory, atomic wire-up) that protects upstream credibility — a bare gh call skips all of it. Prefer '/dhx:upstream <report-path>' for a new issue, or '/dhx:upstream reply <issue>' for a comment. Proceeding is allowed (soft warning only)."
  },
  "systemMessage": "/dhx:upstream runs the gated pre-flight for upstream filings — prefer it over a bare 'gh issue create'/'gh issue comment' (soft warning; proceeding is allowed)."
}
JSON
fi
exit 0
