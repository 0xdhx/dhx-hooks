#!/usr/bin/env bash
# dhx-gsd-canonical-mirror-gate.sh — PreToolUse hook (Write|Edit matcher)
# Patterns: HP-007, HP-009, HP-015, HP-031
#
# Guards direct Edit/Write to gsd-managed files against unmirrored drift:
# the ~/.claude/gsd-core/ subtree plus the prefix-managed dirs gsd-update
# also clobbers — ~/.claude/{agents,skills,commands}/gsd-* (added 2026-07-15).
# With a READABLE backup-meta.json, blocks (exit 2) every in-subtree edit that
# lacks a valid draft-buffer marker: registered `files[]` members are flagged
# load-bearing, all other in-subtree paths as unmirrored work-in-progress
# (block-all steady state, ratified 2026-07-14 — post-fork-retirement an empty
# `files[]` is the norm, so any direct edit is unmirrored WIP; the membership
# split now selects only the message, not block-vs-warn). A corrupt/unreadable
# backup-meta fails safe to BLOCK; an ABSENT backup-meta (fresh install) warns
# (exit 1). Silent (exit 0) outside the subtree and when a valid marker present.
#
# Hot path (per D-07/D-27): a single jq parse extracts `tool_input.file_path`
# from the stdin envelope, then a `case` path-prefix check exits 0 immediately
# for writes outside ~/.claude/gsd-core/. No further jq, no stat — the
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
#   2. backup-meta.json `files[]` is the registered fork-patch set, jq-read
#      once per invocation, ONLY when the target is in the guarded subtree AND
#      the marker is absent/invalid. Membership selects the block MESSAGE
#      (load-bearing member vs unmirrored non-member), not block-vs-warn —
#      under the block-all steady state both tiers exit 2.
#   3. Tiered emit (block-all steady state, ratified 2026-07-14): exit 2 for
#      ANY in-subtree path when backup-meta is readable (member or not) or
#      corrupt (fail-safe); exit 1 ONLY when backup-meta is absent
#      (fresh-install advisory); exit 0 silent for non-subtree paths or a
#      valid marker.
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
# INVARIANT (gsd-core 1.3.1, 2026-06-05): this literal MUST track the live gsd
# runtime dir name. @opengsd/gsd-core@1.3.1 renamed get-shit-done/ → gsd-core/;
# a stale name points the subtree gate at a MISSING dir, so every write to the
# live runtime silently passes the case-check → exit 0 → the write-protection
# gate is dead with no error. probe-gsd-roots-resolve.sh asserts this literal.
#
# INVARIANT (prefix-managed dirs, 2026-07-15): the three gsd-* arms below MUST
# track gsd-core's GSD_PREFIX_MANAGED_DIRS contract (gsd-tools.cjs ~:2353 —
# agents/skills/commands iterated with `startsWith('gsd-')`; verified against
# gsd-core@1.6.1). gsd-update overwrites (agents) or sweep-DELETES (skills,
# commands) exactly these prefix-matched entries, so an unmirrored direct edit
# there is clobbered on update just like an in-subtree edit — the 2026-07-15
# agents/ blind-spot closure (dotfiles c91968f registered the first fork-tracked
# agent; this gate arm makes the discipline reach it). REL_PATH derivation,
# backup-meta membership, and the draft-buffer escape valve are prefix-agnostic
# and work unchanged for these arms. NOT guarded (naming is mixed/unprefixed —
# needs manifest-derived matching, tracked separately): ~/.claude/hooks/,
# ~/.claude/scripts/. probe-gsd-roots-resolve.sh asserts all three arm literals;
# probe-gsd-canonical-mirror-gate-tiered-outcome.sh pins block + dhx-* pass.
GSD_LIVE_ROOT="$HOME/.claude/gsd-core"
case "$FILE" in
  "$GSD_LIVE_ROOT/"*) ;;                 # in guarded subtree — continue to gate check
  "$HOME/.claude/agents/gsd-"*) ;;       # gsd-shipped agent (34 live) — overwritten on update
  "$HOME/.claude/skills/gsd-"*) ;;       # gsd-shipped skill dir — sweep-dir prune on update
  "$HOME/.claude/commands/gsd-"*) ;;     # gsd-staged command — sweep-dir prune on update
  *) exit 0 ;;             # not gsd-managed — silent pass
esac

# Derive REL_PATH for backup-meta membership + cp suggestion.
# e.g. /home/dhx/.claude/gsd-core/workflows/execute-phase.md
#   →  gsd-core/workflows/execute-phase.md
REL_PATH="${FILE#$HOME/.claude/}"

# D-08 marker check — single `[ -f ... ]` test gates the hot path; jq parse runs
# only on the marker-exists branch. DHX_DRAFT_BUFFER_DIR override lets Plan 5
# Task 5.3 inject a fixture marker dir for SAFE_FOR_LIVE: yes probe posture.
#
# INVARIANT (cross-process, cross-repo — gate↔buffer marker-key parity; this is the
# READER half; the WRITER is scripts/dhx-draft-buffer.sh):
#   $SESSION_ID here is this hook's stdin `.session_id`. The buffer resolves the SAME
#   id out-of-band (it has no stdin envelope) via $CLAUDE_CODE_SESSION_ID / pid-file
#   .sessionId — see dhx-shared/lib/session-identity.sh. Both build the marker name
#   below from it; they MUST agree or an operator-authorized edit silently fails to
#   suppress this gate. CC stamps ONE session UUID into both the hook envelope and the
#   tool-subprocess env — incl. bridged sessions (local UUID, never bridgeSessionId;
#   verified 2026-06-13). Enforced by tests/probes/probe-draft-buffer-gate-key-parity.sh.
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
#
# THREE distinct backup-meta states, kept distinct ON PURPOSE. They used to
# collapse: `jq -r '.files[]' 2>/dev/null` yields EMPTY both when the JSON is
# unreadable AND when it parses cleanly to `[]`, so a `[ -z "$META_FILES" ]`
# test could not tell a corrupt file from the legitimate post-retirement
# steady state — and blocked both under the SAME "load-bearing" message.
# `jq -e '.files | type == "array"'` splits them: exit 0 only when `.files`
# parses to an array; exit 1/>1 on corruption, a missing `.files` key, or a
# non-array value (see the probe's negative control).
#
#   - absent                → legitimate (fresh install, fork mirror not yet
#                             installed) → WARN (advisory; don't obstruct a
#                             not-yet-set-up host).
#   - present, .files NOT a parseable array → WR-02 fail-safe → BLOCK.
#                             Silently downgrading an unreadable backup-meta is
#                             exactly how the 2026-05-15 unmirrored-edit incident
#                             slips through; the mirror state is unverifiable.
#   - present, .files a parseable array → block-all by design (ratified
#                             2026-07-14, see docs/decisions.md). Membership
#                             selects only the MESSAGE, not block-vs-warn:
#                               · member of files[] → "load-bearing" (accurate).
#                               · non-member (incl. the EMPTY-files[] steady
#                                 state) → "no live fork patch registered". With
#                                 no live patches, every direct ~/.claude/gsd-core/
#                                 edit is unmirrored WIP — the CLAUDE.md
#                                 mirror-canonical discipline verbatim. The
#                                 draft-buffer marker is the sanctioned escape
#                                 valve (checked above, before this block).
BACKUP_META="${DHX_BACKUP_META:-$HOME/.claude/gsd-local-patches/backup-meta.json}"
EXIT_CODE=1          # default: backup-meta absent → fresh-install advisory (WARN)
REASON="WARN: edit of $REL_PATH may cause canonical-mirror drift (backup-meta not installed; advisory)."
if [ -f "$BACKUP_META" ]; then
  if ! jq -e '.files | type == "array"' "$BACKUP_META" >/dev/null 2>&1; then
    # present but unreadable / corrupt / missing-key / non-array — WR-02 fail-safe.
    EXIT_CODE=2
    REASON="BLOCKED: edit of $REL_PATH — backup-meta.json unreadable/corrupt; failing safe (mirror state unverifiable)."
  else
    # parseable array → block-all; membership only picks the message.
    META_FILES=$(jq -r '.files[]' "$BACKUP_META" 2>/dev/null)
    EXIT_CODE=2
    if printf '%s\n' "$META_FILES" | grep -Fxq "$REL_PATH"; then
      REASON="BLOCKED: edit of $REL_PATH bypasses canonical mirror (load-bearing GSD fork-tracked file)."
    else
      REASON="BLOCKED: edit of $REL_PATH bypasses canonical mirror (no live fork patch registered — unmirrored edit under managed ~/.claude/gsd-core/)."
    fi
  fi
fi

# D-10 stderr emit — tier-specific first line (REASON) + shared remediation body.
CANONICAL="$HOME/.claude/gsd-local-patches/$REL_PATH"
# Absolute path to the draft-buffer driver, derived from this script's own
# location (resolving the ~/.claude/hooks symlink back into the repo). The gate
# fires on writes to ~/.claude/gsd-core/ from ANY cwd, so the repo-relative
# form this used to print was unrunnable for the operator who tripped it
# unless they happened to be sitting in the hooks repo (2026-08-06 sweep).
SELF_RESOLVED="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
DRAFT_BUFFER="$(dirname "$(dirname "$SELF_RESOLVED")")/scripts/dhx-draft-buffer.sh"
{
  echo "$REASON"
  echo "Either annotate the draft buffer first:"
  echo "  $DRAFT_BUFFER add $REL_PATH --reason \"<why>\""
  echo "Or mirror after editing:"
  echo "  cp $FILE $CANONICAL"
} >&2

exit "$EXIT_CODE"
