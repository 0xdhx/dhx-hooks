#!/usr/bin/env bash
# dhx-upstream-bypass.sh — deliberate, audited escape hatch for the /dhx:upstream hard deny.
#
# Companion to `dhx-plugin/plugins/dhx/hooks/pre-tool-use-gh-issue-write.sh` (D-12 hard
# deny, 2026-07-21). That hook blocks foreign-repo `gh issue create` / `gh issue comment`
# / `gh api …POST` on an issue or PR thread unless the /dhx:upstream gated pre-flight ran.
# This script opens a SINGLE-USE 60-second window for ONE deliberate write that does not
# fit the gated path. Single-use is enforced, not merely described: the gate removes the
# marker and records a consume line on the write it allows, so the second write needs a
# second invocation of this script with its own stated reason.
#
# Usage (the deny message prints this verbatim):
#   bash "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/dhx-tools/dhx-upstream-bypass.sh" \
#     --reason "why the 7-stage path does not fit"
#   # then re-run the command within 60s. The opening is spent by that one write.
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
# No human-only channel exists in this session model. An agent CAN invoke this script, and
# nothing here or in the gate tries to stop it. The property being bought is ATTRIBUTION:
# a defection should be visible in a file someone reads, rather than silent.
#
# The one property the companion gate ENFORCES (since 2026-09-20):
#   - the window cannot open unless THIS LOG holds a line naming the session, timestamped
#     inside the TTL. The gate reads the log line, not just the marker file.
# The two properties that FOLLOW from it, and are not separately checked:
#   - the window is SHORT (60s) and SINGLE-USE (the gate consumes it on the write it
#     allows, and re-touching the marker afterwards does not revive it -- the gate takes
#     the LAST logged event for the session, and that event is now a consume)
#   - the call is LOUD (this script name, in the transcript, with a stated reason) -- true
#     whenever the window was opened the intended way, which is now the only way that does
#     not involve writing to the audit file by hand
#
# What that does and does not buy, precisely. Until 2026-09-20 the gate allowed on the
# MTIME of `$MARKER_DIR/.upstream-bypass-<session-id>` alone, so a bare `touch` of a path
# the gate's own deny message prints verbatim opened the window, wrote nothing here, and
# left nothing recognisable in the transcript. LOUD and LOGGED were claimed and not
# enforced; only SHORT actually held. Now the absence of a record is not a reachable state:
# the window opens only with a log line inside the TTL. A determined caller can still append
# a forged line -- there is no way to prevent that from inside the sandbox it runs in -- but
# the forgery then lands IN THE AUDITED FILE, which is where a reviewer is already looking.
# Absent-vs-forged is the whole difference, and it is the one worth having.
#
# Do not "harden" this with an env-var or dotfile allowlist: anything the gated model can
# set is soft mode with extra steps. Do not relax the gate back to an mtime check.
#
# Own-repo writes never need this — the hook exempts owners in its OWN_OWNERS list.

set -euo pipefail

REASON=""
SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --reason)  REASON="${2:-}"; shift 2 ;;
    --session) SESSION_ID="${2:-}"; shift 2 ;;
    # Range covers usage + options + the honesty header through the OWN_OWNERS line.
    # Re-check it when the header grows; a stale range silently truncates --help.
    -h|--help) sed -n '2,56p' "$0"; exit 0 ;;
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

# --- Stale-marker sweep (2026-09-20) ---
# Markers are per-session and never cleaned up by anything else, so they accumulated: 19
# zero-byte files on 2026-09-20, the oldest from 2026-08-06. They were already INERT -- the
# companion gate has always re-checked the mtime at read time, and since 2026-09-20 it also
# requires a fresh audit line -- so this sweep is hygiene, not a fix, and nothing security-
# relevant depends on it running.
# THRESHOLD IS ONE DAY, not the 60s TTL, and deliberately so: a peer session may hold a live
# window while this runs, and a sweep keyed to the TTL itself would race it. A day is far
# outside any window and far inside "this is litter".
# THE SWEEP LOGS ITSELF. The count of markers against the count of `session=` lines was the
# standing evidence that every window ever opened came through this script (19 vs 19, an exact
# 1:1, reconciled 2026-09-20). A silent sweep would destroy that instrument by making the
# marker count meaningless. An `event=sweep` line preserves it: markers removed are accounted
# for in the same file, so the reconciliation is still computable after a cleanup. The field
# name is `event=`, never `session=`, so a sweep line can never be mistaken for an open window
# by the gate's tab-bounded `session=<id>` match.
# `-mmin` is required here -- a relative `-newermt` exits 1 with no output under this machine's
# bfs `find` shim and would read as "nothing stale" (global CLAUDE.md).
SWEPT=$(find "$MARKER_DIR" -maxdepth 1 -name '.upstream-bypass-*' -mmin +1440 -print -delete 2>/dev/null | wc -l || echo 0)
if [ "${SWEPT:-0}" -gt 0 ]; then
  printf '%s\tevent=sweep\tremoved=%s\tnote=%s\n' \
    "$(date -Is)" "$SWEPT" "stale bypass markers older than 1 day" >> "$AUDIT"
fi

echo "BYPASS OPEN — 60s window for one upstream gh write (session $SESSION_ID)."
echo "  reason: $REASON"
echo "  logged: $AUDIT"
echo "  The /dhx:upstream 7-stage discipline (redaction sweep, fork audit, evidence"
echo "  inventory, atomic wire-up) is NOT running. The write is irreversible."
