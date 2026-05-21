#!/usr/bin/env bash
# dhx-gsd-canonical-mirror-gate.sh — PreToolUse hook (Write|Edit matcher)
# Patterns: HP-007, HP-009, HP-015, HP-031
#
# Blocks (exit 2) edits to canonical-mirror fork-tracked files — the entries in
# ~/.claude/gsd-local-patches/backup-meta.json `files[]` — when no valid
# draft-buffer marker is present. Warns (exit 1) on edits to other
# ~/.claude/get-shit-done/* paths under the same conditions. Silent (exit 0)
# on all other paths and when a valid marker is present.
#
# Hot path (per D-07/D-27): a single jq parse extracts `tool_input.file_path`
# from the stdin envelope, then a `case` path-prefix check exits 0 immediately
# for writes outside ~/.claude/get-shit-done/. No further jq, no stat — the
# common (non-GSD) write pays only one jq fork. Marker + backup-meta jq reads
# run ONLY on the rare in-subtree branch.
#
# ════════════════════════════════════════════════════════════════════════════
# SCOPE (HP-003 reframe, 2026-04-21): fires for parent AND subagent writes.
# ════════════════════════════════════════════════════════════════════════════
# PreToolUse:Write and PreToolUse:Edit propagate from Agent subprocesses to
# parent-registered hooks. A subagent edit to a fork-tracked GSD file bypasses
# the canonical mirror just as a top-level edit does — uniform enforcement
# intended; the hook does NOT branch on agent_id.
#
# Suppression: DHX_SKIP_DRIFT_GATE=1
#
# Env overrides (for SAFE_FOR_LIVE probes per Plan 16-05 Task 5.3):
#   DHX_DRAFT_BUFFER_DIR — defaults to $HOME/.cache/dhx
#   DHX_BACKUP_META      — defaults to $HOME/.claude/gsd-local-patches/backup-meta.json
#
# Source-of-truth: ~/repos/hooks/dhx/dhx-gsd-canonical-mirror-gate.sh
# Symlinked to:    ~/.claude/hooks/dhx-gsd-canonical-mirror-gate.sh
#                  (installed via 'ln -sfn' per D-30 — idempotent; tolerates
#                   pre-existing stale symlinks on re-run)
#
# ────────────────────────────────────────────────────────────────────────────
# INVARIANT (HP-031 — gate hook is the marker-reader half; cross-decl site #3):
#   1. The draft-buffer marker file is the runtime escape valve. A single
#      `[ -f "$MARKER" ]` test gates the hot path BEFORE any jq parse of it.
#   2. backup-meta.json `files[]` is the authoritative BLOCK-tier path set.
#      It is jq-read once per invocation, ONLY when the target is in the
#      guarded subtree AND the marker is absent/invalid.
#   3. Tiered emit: exit 2 for backup-meta members; exit 1 for the broader
#      ~/.claude/get-shit-done/ subtree; exit 0 silent for non-matching paths
#      or when a valid marker is present.
# ────────────────────────────────────────────────────────────────────────────

set -uo pipefail   # NOT -e: must tolerate jq failures in the optional marker-read path

# Suppression escape valve (matches dhx-watch-digest.sh convention)
[ "${DHX_SKIP_DRIFT_GATE:-0}" = "1" ] && exit 0

# Stdin envelope (HP-009 + HP-015 graceful-degrade — never block on a bad envelope)
INPUT=$(cat 2>/dev/null || true)
[ -z "$INPUT" ] && exit 0
echo "$INPUT" | jq -e . >/dev/null 2>&1 || exit 0

# jq precondition — if jq is missing the gate cannot reason; fail open (exit 0)
command -v jq >/dev/null 2>&1 || exit 0

# Single jq parse (per D-27): extract file_path + session_id from the envelope
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$FILE" ] && exit 0

# Session-id sanitization (T-16-06 marker-path-injection defense). This guard
# INTENTIONALLY diverges from the statusline-wrapper.js:1136 JS guard
# `!/[/\\]|\.\./.test(sessionId)`: the JS guard is reached only inside an
# `if (sessionId && ...)` truthiness pre-check, so the empty/missing case never
# reaches it. Bash has no such short-circuit here, so the empty case is folded
# in explicitly below. An empty/missing id cannot key a marker file — normalize
# it (and any traversal-bearing id) to "" so it is treated as un-annotatable:
# the gate still fires its tier (fail-safe), it just can never present a valid
# marker. The downstream `[ -n "$SESSION_ID" ]` at the marker check then skips
# the marker lookup entirely for the normalized-empty case.
case "$SESSION_ID" in
  ''|*[/\\]*|*..*) SESSION_ID="" ;;   # normalize: no valid marker possible
esac

# D-07 happy path — case-statement path-prefix check; sub-millisecond, no fork,
# no further jq for non-GSD paths (per D-27 reword).
GSD_LIVE_ROOT="$HOME/.claude/get-shit-done"
case "$FILE" in
  "$GSD_LIVE_ROOT/"*) ;;   # in guarded subtree — continue to gate check
  *) exit 0 ;;             # not in subtree — silent pass
esac

# Derive REL_PATH for backup-meta membership + cp suggestion.
# e.g. /home/dhx/.claude/get-shit-done/workflows/execute-phase.md
#   →  get-shit-done/workflows/execute-phase.md
REL_PATH="${FILE#$HOME/.claude/}"

# D-08 marker check — single `[ -f ... ]` test gates the hot path; jq parse runs
# only on the marker-exists branch. DHX_DRAFT_BUFFER_DIR override lets Plan 5
# Task 5.3 inject a fixture marker dir for SAFE_FOR_LIVE: yes probe posture.
DRAFT_BUFFER_DIR="${DHX_DRAFT_BUFFER_DIR:-$HOME/.cache/dhx}"
MARKER="$DRAFT_BUFFER_DIR/draft-buffer-${SESSION_ID}.json"
MARKER_VALID=0
if [ -n "$SESSION_ID" ] && [ -f "$MARKER" ]; then
  EXPIRES=$(jq -r '.expires_at // empty' "$MARKER" 2>/dev/null)
  if [ -n "$EXPIRES" ]; then
    # Uses GNU date -d; portable across WSL2/Linux (project requirement); not POSIX-portable.
    EXPIRES_EPOCH=$(date -u -d "$EXPIRES" +%s 2>/dev/null || echo 0)
    NOW=$(date -u +%s)
    # 60s clock-skew grace per RESEARCH.md Pitfall 3 — defends against minor host
    # clock drift / NTP slew on the marker-write/read boundary.
    if [ "$((EXPIRES_EPOCH + 60))" -gt "$NOW" ]; then
      # Explicit '!= null' check per D-29 — defends against jq index()-returns-0-truthy subtlety.
      if jq -e --arg p "$REL_PATH" '(.paths // []) | index($p) != null' "$MARKER" >/dev/null 2>&1; then
        MARKER_VALID=1
      fi
    fi
  fi
fi
# Valid marker → silent pass regardless of tier (SPEC AC (b))
[ "$MARKER_VALID" = "1" ] && exit 0

# D-09 backup-meta tier selection — jq-read once. DHX_BACKUP_META override lets
# Plan 5 Task 5.3 inject a fixture backup-meta for SAFE_FOR_LIVE: yes posture.
BACKUP_META="${DHX_BACKUP_META:-$HOME/.claude/gsd-local-patches/backup-meta.json}"
TIER="WARN"
EXIT_CODE=1
if [ -f "$BACKUP_META" ]; then
  if jq -r '.files[]' "$BACKUP_META" 2>/dev/null | grep -Fxq "$REL_PATH"; then
    TIER="BLOCKED"
    EXIT_CODE=2
  fi
fi

# D-10 tiered stderr emit
CANONICAL="$HOME/.claude/gsd-local-patches/$REL_PATH"
{
  if [ "$TIER" = "BLOCKED" ]; then
    echo "BLOCKED: edit of $REL_PATH bypasses canonical mirror (load-bearing GSD fork-tracked file)."
  else
    echo "WARN: edit of $REL_PATH may cause canonical-mirror drift (mirror policy advisory; not load-bearing)."
  fi
  echo "Either annotate the draft buffer first:"
  echo "  scripts/dhx-draft-buffer.sh add $REL_PATH --reason \"<why>\""
  echo "Or mirror after editing:"
  echo "  cp $FILE $CANONICAL"
} >&2

exit "$EXIT_CODE"
