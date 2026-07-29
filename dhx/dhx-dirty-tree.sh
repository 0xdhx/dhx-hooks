#!/usr/bin/env bash
# dhx-dirty-tree.sh — SessionStart hook
# Patterns: HP-009, HP-015
# Reports uncommitted changes at session start. Read-only, non-blocking.
# Fires once per session. Silent on clean trees.
#
# On the two declared shared working trees (runtime allowlist — there is no
# per-repo hook; this one plugin hook fires in every repo, so scope is a
# runtime gate), the bare count is replaced by dhx-who's per-file attribution
# payload (who holds each dirty file), invoked through a strict fail-open
# wrapper:
#   - hard timeout      DHX_DIRTY_TREE_WHO_TIMEOUT, default 8s — covers the
#                       observed legitimate cold-cache range (3.5-6.3s);
#                       worst-case block is 2x timeout only when the helper
#                       hangs in BOTH the --version probe and the payload run
#   - output-size cap   16 KiB. Measured payloads ~1 KiB; the helper collapses
#                       >20 dirty files to rollups. Over-cap DEGRADES rather
#                       than truncates — a mid-payload cut would drop the
#                       payload's closing imperative line
#   - protocol check    `--version` must print exactly "dhx-who protocol 1"
#   - shape check       payload must open with "[shared-tree state]"
# Every repo outside the allowlist pays NO helper invocation and no scan (the
# cost boundary the allowlist holds), and every degrade path emits today's
# bare-count line BYTE-IDENTICAL to the pre-enrichment hook, silently.
# One deliberate exception: helper exit 3 is dhx-who's serialization CANARY
# (designed loud — a dead key form must never render as a clean ownership
# map). That is the one degrade someone can act on, so it emits the bare line
# plus one factual canary line instead of degrading silently.
#
# The helper is two files (dhx-who.sh + enumerate-ccs-sessions.sh); --version
# interrogates only the first, so a peer mid-edit can skew them briefly. By
# adjudication this rides the wrapper battery — the failure mode is "bare
# count for a few seconds, silently". Revisit deployment isolation only on a
# real incident where the wrapper degraded because of mid-edit tree state.
#
# Helper contract: ~/repos/skills/.planning/backlog/
#   2026-07-28-dirty-tree-attribution-session-start.md (criterion "Hook
#   boundary and scope") + docs/research/2026-07-28-dirty-tree-attribution-
#   codex-review.md §5 + M5/M6 (same repo).
#
# Suppression: DHX_SKIP_DIRTY_CHECK=1
# Source-of-truth: ~/repos/hooks/dhx/dhx-dirty-tree.sh
# Symlinked to:   ~/.claude/hooks/dhx-dirty-tree.sh
#
# TEST SEAMS (default-preserving; production sets none):
#   DHX_DIRTY_TREE_ALLOWLIST    colon-separated repo toplevels
#                               (default: ~/repos/skills:~/repos/cross-repo)
#   DHX_DIRTY_TREE_WHO          helper path
#                               (default: ~/.claude/dhx-tools/dhx-history/dhx-who.sh)
#   DHX_DIRTY_TREE_WHO_TIMEOUT  seconds (default: 8)

set -uo pipefail

# Parse cwd from stdin (graceful — degrades to env var / pwd)
INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
if [ -z "$CWD" ]; then
  CWD="${CLAUDE_PROJECT_DIR:-.}"
fi

# Must be a git repo
if ! git -C "$CWD" rev-parse --is-inside-work-tree &>/dev/null; then
  exit 0
fi

# Suppression via env var
if [ "${DHX_SKIP_DIRTY_CHECK:-}" = "1" ]; then
  exit 0
fi

# Count changes
STATUS=$(git -C "$CWD" status --porcelain 2>/dev/null)
if [ -z "$STATUS" ]; then
  exit 0
fi

TOTAL=$(echo "$STATUS" | wc -l | tr -d ' ')
UNTRACKED=$(echo "$STATUS" | grep -c '^??' || true)
MODIFIED=$((TOTAL - UNTRACKED))
BARE="Working tree has $TOTAL uncommitted changes ($MODIFIED modified, $UNTRACKED untracked)"

# ---- attribution branch (allowlist-gated, strict fail-open) ----------------
TOPLEVEL=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)
ALLOWLIST="${DHX_DIRTY_TREE_ALLOWLIST:-$HOME/repos/skills:$HOME/repos/cross-repo}"
IN_ALLOWLIST=0
if [ -n "$TOPLEVEL" ]; then
  IFS=':' read -ra ROOTS <<< "$ALLOWLIST"
  for r in "${ROOTS[@]}"; do
    if [ "$TOPLEVEL" = "$r" ]; then IN_ALLOWLIST=1; break; fi
  done
fi
if [ "$IN_ALLOWLIST" != "1" ]; then
  echo "$BARE"
  exit 0
fi

WHO="${DHX_DIRTY_TREE_WHO:-$HOME/.claude/dhx-tools/dhx-history/dhx-who.sh}"
TIMEOUT_S="${DHX_DIRTY_TREE_WHO_TIMEOUT:-8}"
if [ ! -e "$WHO" ]; then
  echo "$BARE"
  exit 0
fi

# Capture to a FILE, never $( ). `timeout` kills only its direct child; the
# helper's python grandchild survives the kill, and if it held a $( ) pipe the
# hook would block on pipe-EOF past the timeout. A file has no reader to block;
# the orphan writes to an unlinked inode and exits on its own.
TMPOUT=$(mktemp)
trap 'rm -f "$TMPOUT"' EXIT

timeout "$TIMEOUT_S" bash "$WHO" --version > "$TMPOUT" 2>/dev/null
RC=$?
if [ "$RC" -ne 0 ] || [ "$(head -c 64 "$TMPOUT")" != "dhx-who protocol 1" ]; then
  echo "$BARE"
  exit 0
fi

# HP-015: session_id is on SessionStart stdin; own files label "this session"
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
SELF_ARGS=()
if [ -n "$SESSION_ID" ]; then SELF_ARGS=(--self "$SESSION_ID"); fi

: > "$TMPOUT"
timeout "$TIMEOUT_S" bash "$WHO" --repo "$TOPLEVEL" "${SELF_ARGS[@]}" > "$TMPOUT" 2>/dev/null
RC=$?

if [ "$RC" -eq 3 ]; then
  # dhx-who's serialization canary — the one loud degrade (see header)
  echo "$BARE"
  echo "dhx-who attribution canary failed (helper exit 3: tool-input serialization drift); showing bare count until dhx-who's key form is updated"
  exit 0
fi
if [ "$RC" -ne 0 ]; then
  echo "$BARE"
  exit 0
fi

SIZE=$(stat -c %s "$TMPOUT" 2>/dev/null || echo 0)
if [ "$SIZE" -eq 0 ] || [ "$SIZE" -gt 16384 ]; then
  echo "$BARE"
  exit 0
fi

case "$(head -c 19 "$TMPOUT")" in
  "[shared-tree state]") cat "$TMPOUT" ;;
  *) echo "$BARE" ;;
esac
exit 0
