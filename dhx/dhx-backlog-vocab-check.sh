#!/usr/bin/env bash
# dhx-backlog-vocab-check.sh — PostToolUse hook (Write|Edit|MultiEdit matcher)
# Patterns: HP-003, HP-007, HP-009, HP-017, HP-038, HP-039
# Write-time advisory for non-canonical target_milestone in .planning/backlog/*.md briefs.
#
# Layering (closes write-time VALUE-enum gap):
#   - cross-repo backlog-frontmatter-validator.cjs (pre-commit) validates
#     PRESENCE of target_milestone, not VALUE-enum.
#   - skills-repo backlog-regen.cjs --check validates VALUE-enum — but runs
#     at regen-time, not write-time.
#   - This hook surfaces drift at write-time so non-canonical values surface
#     immediately for inline correction. The 2026-05-08 incident
#     (target_milestone: v1.4 literal, undetected ~3 hours until backlog-regen
#     logged the coercion) is the motivating gap.
#
# Path gate: top-level .planning/backlog/*.md only — terminal subdirs
# (rejected/, shipped/, superseded/) are intentionally skipped (re-classifying
# a brief to a terminal state must NOT fire the gate).
#
# Output: dual-channel non-blocking advisory. Exit 0 always (PostToolUse
# advises; cannot block — HP-009).
#   - stderr ⚠ advisory per terminal-patterns-status.md — for the human user's
#     terminal. HP-038: PostToolUse exit-0 stderr does NOT surface to Claude
#     inline on CC 2.1.152, so stderr alone cannot drive Claude inline
#     correction (it can only drive user-side correction).
#   - stdout JSON {hookSpecificOutput: {hookEventName, additionalContext}} —
#     surfaces to Claude inline as a <system-reminder> in the triggering
#     tool-result wrapper (HP-039, verified 2026-05-27). This is the channel
#     that closes the loop for Claude-side inline correction.
# Source-of-truth vocab stays in backlog-regen.cjs; we shell out to
# --check <brief.md> rather than mirroring the canonical-set logic in bash.
# One place to update when MILESTONES.md grows; zero drift surface here.
#
# Scope: passes target_milestone + status (the scope of --check upstream).
# urgency is explicitly OUT OF SCOPE — --check excludes it (advisory vocabulary,
# warn-don't-coerce), and inventing a parallel urgency-check here would diverge
# from the canonical contract. Extend --check upstream first if urgency needs
# write-time coverage.
#
# Subagent propagation (HP-003 v2): PostToolUse:Write|Edit fires from subagent
# writes too, carrying full agent_id. Uniform enforcement — no agent_id branch
# (a subagent authoring a brief bypasses the same vocab discipline as a
# top-level call). MultiEdit matcher is currently dormant in CC 2.1.112
# (HP-003); included for forward-compat against future tool reintroduction.
#
# False-positive note: if MILESTONES.md is in flight (mid-milestone-cut), a
# brief authored against the new version fires advisory until the version
# line lands. Acceptable — advisory only; never breaks flow.

set -uo pipefail

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then exit 0; fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
[ -z "$FILE_PATH" ] && exit 0

# Path gate: top-level .planning/backlog/*.md only. Terminal-subdir patterns
# checked first so rejected/shipped/superseded moves short-circuit before the
# general top-level pattern can match. Microsecond cost on non-backlog writes
# (the dominant case).
case "$FILE_PATH" in
  */.planning/backlog/rejected/*) exit 0 ;;
  */.planning/backlog/shipped/*) exit 0 ;;
  */.planning/backlog/superseded/*) exit 0 ;;
  */.planning/backlog/*.md) ;;
  *) exit 0 ;;
esac

# Defensive: PostToolUse fires after the write, but a subsequent Edit that
# removes the file (or any race) could leave nothing on disk. Skip silently.
[ -f "$FILE_PATH" ] || exit 0

# Locate repo root from the touched brief; required to anchor --check's vocab
# derivation (reads MILESTONES.md / ROADMAP.md / STATE.md relative to root).
REPO_ROOT=$(git -C "$(dirname "$FILE_PATH")" rev-parse --show-toplevel 2>/dev/null) || exit 0

# Locate the canonical regen tool. Honors DHX_TOOLS override (used by probes).
REGEN="${DHX_TOOLS:-$HOME/.claude/dhx-tools}/backlog-regen.cjs"
[ -r "$REGEN" ] || exit 0

# Single-brief --check: exit 0 = canonical, exit 1 = drift. stderr carries the
# drift detail + canonical-set hint already shaped for humans by --check.
# stdout swallowed (--check's "OK" line is noise when clean; nothing useful on
# drift). Subshell captures stderr only.
CHECK_OUT=$(node "$REGEN" --check "$REPO_ROOT" "$FILE_PATH" 2>&1 >/dev/null)
CHECK_RC=$?

if [ "$CHECK_RC" -eq 0 ]; then
  exit 0
fi

# Drift detected — dual-channel advisory:
#   stderr → user terminal (HP-038: PostToolUse exit-0 stderr does NOT surface
#             to Claude inline on CC 2.1.152 — terminal-visible only)
#   stdout → JSON {hookSpecificOutput: {hookEventName: PostToolUse,
#             additionalContext}} surfaces to Claude inline as a
#             <system-reminder> in the triggering tool result (HP-039 — verified
#             2026-05-27 via direct write-tool spike on CC 2.1.152). This is the
#             "write-time advisory for inline correction" channel — keeps the
#             hook's design intent intact across both the human and Claude.
# ⚠ (U+26A0) leading symbol, single-line headline, indented detail rows.
BASENAME=$(basename "$FILE_PATH")
ADVISORY="⚠ backlog-vocab: non-canonical frontmatter in $BASENAME"$'\n'"$(echo "$CHECK_OUT" | sed 's/^/  /')"

echo "$ADVISORY" >&2

jq -nc --arg msg "$ADVISORY" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: $msg
  }
}'

exit 0
