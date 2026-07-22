#!/usr/bin/env bash
# dhx-upstream-bypass.sh — deliberate, audited escape hatch for the /dhx:upstream hard deny.
#
# Companion to `dhx-plugin/plugins/dhx/hooks/pre-tool-use-gh-issue-write.sh` (D-12 hard
# deny, 2026-07-21). That hook blocks foreign-repo `gh issue create` / `gh issue comment`
# / `gh api …POST` on an issue or PR thread unless the /dhx:upstream gated pre-flight ran.
# This script opens a 60-second window for ONE deliberate write that does not fit the
# gated path.
#
# Usage (the deny message prints this verbatim):
#   bash "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/dhx-tools/dhx-upstream-bypass.sh" \
#     --reason "why the 7-stage path does not fit"
#   # then re-run the gh command within 60s
#
# Options:
#   --reason "<text>"   REQUIRED. >= 12 chars. Written to the audit log verbatim.
#   --session <id>      Session to open the window for. Defaults to
#                       $CLAUDE_CODE_SESSION_ID (exported into every tool subprocess,
#                       HP-043) — pass explicitly only when that is absent.
#
# --- What this is, honestly ---
# It is FRICTION + AUDIT, not an airtight human gate. A model-issued Bash call has no tty
# (verified 2026-07-21: stdin/stdout both non-tty in a Claude Code Bash tool call, and
# /dev/tty is readable, so a `read < /dev/tty` prompt would hang rather than cleanly
# refuse), and under bypassPermissions there is no permission prompt to lean on either.
# No human-only channel exists in this session model. So the enforceable properties are:
#   - the call is LOUD (this name, in the transcript, with a stated reason)
#   - the call is LOGGED (append-only, with session + cwd + reason)
#   - the window is SHORT (60s, one command's worth)
# An agent CAN invoke it. That is a visible, attributable defection, not a silent bypass —
# which is the difference that matters. Do not "harden" this with an env-var or dotfile
# allowlist: anything the gated model can set is soft mode with extra steps.
#
# Own-repo writes never need this — the hook exempts owners in its OWN_OWNERS list.

set -euo pipefail

REASON=""
SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --reason)  REASON="${2:-}"; shift 2 ;;
    --session) SESSION_ID="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "REFUSE: unknown argument '$1' (see --help)" >&2; exit 2 ;;
  esac
done

if [ -z "$REASON" ]; then
  echo "REFUSE: --reason \"<why the /dhx:upstream gated path does not fit>\" is required." >&2
  echo "        The reason is logged. If you cannot state one, use /dhx:upstream instead." >&2
  exit 2
fi

if [ "${#REASON}" -lt 12 ]; then
  echo "REFUSE: --reason is too short (${#REASON} chars, need >= 12). State the actual reason." >&2
  exit 2
fi

if [ -z "$SESSION_ID" ]; then
  echo "REFUSE: no session id (\$CLAUDE_CODE_SESSION_ID unset and --session not given)." >&2
  echo "        The hook keys its window on the session id; without it there is nothing to open." >&2
  exit 2
fi

MARKER_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/dhx-tools"
mkdir -p "$MARKER_DIR"
MARKER="$MARKER_DIR/.upstream-bypass-$SESSION_ID"
AUDIT="$MARKER_DIR/upstream-bypass.log"

touch "$MARKER"
printf '%s\tsession=%s\tcwd=%s\treason=%s\n' \
  "$(date -Is)" "$SESSION_ID" "$PWD" "$REASON" >> "$AUDIT"

echo "BYPASS OPEN — 60s window for one upstream gh write (session $SESSION_ID)."
echo "  reason: $REASON"
echo "  logged: $AUDIT"
echo "  The /dhx:upstream 7-stage discipline (redaction sweep, fork audit, evidence"
echo "  inventory, atomic wire-up) is NOT running. The write is irreversible."
