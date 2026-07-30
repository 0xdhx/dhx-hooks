#!/usr/bin/env bash
# dhx-artifact-coverage-check.sh -- PostToolUse hook (Write|Edit matcher).
# Patterns: HP-003, HP-009, HP-038, HP-039
# Write-time advisory for creation-time coverage of reports/ and
# docs/prompts/ artifacts (COVER-01, Phase 53 plan 53-01).
#
# WRITTEN BUT NOT YET REGISTERED. This script is not referenced by hooks.json
# and no ~/.claude/hooks/ symlink is created for it -- arming is plan 53-05,
# after the cutover manifest is committed (53-02). See 53-01-PLAN.md
# reversibility_notes: the genuine human gate for this phase lives at
# registration time, not here.
#
# Matcher: registered (in 53-05) against a "Write|Edit" two-tool matcher
# ONLY -- the MultiEdit matcher is deliberately excluded (D-01): it is
# currently dormant on live CC (verified 2026-07-29 via ToolSearch against
# CC 2.1.220), so including it would add matcher surface with no live
# behavior to test.
#
# Canonical gate + taxonomy (D-06): the surface path-gate rule
# (surfaceForRelpath) and the required-field classifier (classifyArtifact)
# live in EXACTLY ONE place -- ~/repos/skills/scripts/lib/artifact-coverage-parser.cjs,
# consumed here only via the artifact-coverage.cjs CLI's `observe` verb. This
# script MUST NEVER carry a second copy of those rules (no directory
# exclusion tokens, no field-presence regex) -- that drift is exactly what
# ~/repos/skills/tests/probe-artifact-coverage-cross-repo.sh (plan 53-01
# Task 2) exists to pin, mirroring the 2026-04-29 deferred-item-classifier
# divergence this repo has already lived through once.
#
# Non-indirection discipline (mirrors dhx-deferred-check.sh): the CLI
# invocation below is spelled out as ONE literal command line -- never
# assembled through a `CLI=` variable -- specifically so the cross-repo drift
# probe's static grep for the contiguous literal `artifact-coverage.cjs
# observe` has something real to find. A `CLI=`-indirected invocation would
# make that static assertion unsatisfiable (a reviewer finding closed by
# this exact non-indirection choice, 53-01-PLAN.md review_dispositions).
#
# Output: dual-channel non-blocking advisory (HP-009: PostToolUse advises,
# cannot block). Exit 0 on EVERY path, including every internal error
# (missing jq, missing/unreadable CLI, malformed JSON, a non-zero CLI exit).
#   - stderr: warning-glyph advisory for the human terminal. HP-038:
#     PostToolUse exit-0 stderr does not surface to Claude inline.
#   - stdout: JSON {hookSpecificOutput: {hookEventName, additionalContext}}
#     -- surfaces to Claude inline as a <system-reminder> (HP-039). Only
#     emitted when the CLI's exit code is non-zero (the artifact currently
#     classifies non-null); otherwise stdout is EMPTY.
#
# Subagent propagation (HP-003): PostToolUse:Write|Edit fires from subagent
# writes too, carrying full agent_id. No agent_id branch -- a subagent
# authoring a report or a prompt gets the same observation as a top-level
# call.
#
# Repo-root resolution (ASVS V5, untrusted input): anchored on the TOUCHED
# FILE's own dirname via `git -C "$(dirname "$FILE_PATH")"`, never cwd -- a
# subagent or a background process may have a cwd unrelated to the file
# being written.
#
# Path-gate: a CHEAP, PERMISSIVE prefilter only (cost control -- skip the
# node spawn on the overwhelming non-target-surface majority of writes). The
# authoritative accept/reject decision belongs entirely to the Node gate
# (surfaceForRelpath) inside the CLI; this script's prefilter must never
# reimplement the directory-exclusion or skill-allowlist rules.

set -uo pipefail

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then exit 0; fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

[ -z "$FILE_PATH" ] && exit 0

case "$TOOL_NAME" in
  Write) EVENT="write_observed" ;;
  Edit) EVENT="content_observed" ;;
  *) exit 0 ;;
esac

# Cheap coarse prefilter -- cost control only, never the authoritative gate.
case "$FILE_PATH" in
  */reports/*.md) ;;
  */docs/prompts/*.md) ;;
  *) exit 0 ;;
esac

[ -f "$FILE_PATH" ] || exit 0

REPO_ROOT=$(git -C "$(dirname "$FILE_PATH")" rev-parse --show-toplevel 2>/dev/null) || exit 0

# Arming gate: inert in any repo without a committed cutover manifest --
# arming is a property of the OBSERVED repo, not of hook installation (D-17,
# D-25). Checked here too (cheap) even though the CLI re-checks it under
# lock; this avoids a needless node spawn on every unarmed-repo write.
[ -f "$REPO_ROOT/.planning/artifact-coverage-cutover.json" ] || exit 0

[ -r "${DHX_TOOLS:-$HOME/.claude/dhx-tools}"/artifact-coverage.cjs ] || exit 0

RELPATH="${FILE_PATH#"$REPO_ROOT"/}"

OUT=$(node "${DHX_TOOLS:-$HOME/.claude/dhx-tools}"/artifact-coverage.cjs observe --repo "$REPO_ROOT" --relpath "$RELPATH" --event "$EVENT" --signal "$TOOL_NAME" ${SESSION_ID:+--session-id "$SESSION_ID"} 2>&1 >/dev/null); RC=$?

if [ "$RC" -eq 0 ]; then
  exit 0
fi

BASENAME=$(basename "$FILE_PATH")
ADVISORY="warning: artifact-coverage: $BASENAME"$'\n'"$(echo "$OUT" | sed 's/^/  /')"

echo "$ADVISORY" >&2

jq -nc --arg msg "$ADVISORY" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: $msg
  }
}'

exit 0
