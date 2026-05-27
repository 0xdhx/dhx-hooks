#!/usr/bin/env bash
# dhx-deferred-check.sh — Stop hook
# Patterns: HP-001, HP-002, HP-004, HP-005, HP-006, HP-009, HP-028
# Surfaces UNASSESSED deferred items from CONTEXT.md before context clears.
# Batch presents all items with brief recommendations, then walks through
# each via AskUserQuestion. 'discuss' option gives deeper reasoning.
#
# Marker protocol — any of these silence the hook for an item. Recognized as
# prefix OR end-of-bullet bracketed token:
#   [captured]      or [captured: ticket]    — captured to backlog/todo via /dhx:capture
#   [existing]      or [existing: path]      — already has a durable home
#   [assessed]      or [assessed: reason]    — user confirmed: intentionally not captured
#   [tracked: REQ-ID]                        — tracked against a requirement
#   [note]          or [note: detail]        — non-actionable decision-trail commentary
#   [preserved-in]  or [preserved-in: phase] — content folded into another phase/decision
#   ~~item~~                                 — strikethrough (legacy compat)
#
# Filter logic is canonical at ~/.claude/dhx-tools/dhx-classify-deferred.sh —
# this hook sources that script and calls classify_deferred_lines on the
# deferred block. Drift between this hook and the skills-repo consumers
# (/dhx:defer-review, /dhx:backlog audit, /dhx:capture) is enforced by
# ~/repos/skills/tests/probe-classifier-cross-repo.sh.
#
# CRITICAL: [assessed] requires EXPLICIT USER APPROVAL. The agent must present
# the item, give its assessment, and WAIT for the user to confirm. The
# dhx-assessed-guard.sh PreToolUse hook enforces this mechanically.

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then exit 0; fi

# Source the canonical deferred-item classifier. Single source of truth shared
# with the skills repo. If the symlink is missing (dhx-tools not installed in
# this environment), fall back to no-op exit rather than blocking session-end.
# Path expression duplicated rather than indirected through a variable so the
# skills-repo cross-repo drift probe (probe-classifier-cross-repo.sh) can
# statically assert the source target.
if [ ! -f "${DHX_TOOLS:-$HOME/.claude/dhx-tools}/dhx-classify-deferred.sh" ]; then exit 0; fi
# shellcheck source=/dev/null
. "${DHX_TOOLS:-$HOME/.claude/dhx-tools}/dhx-classify-deferred.sh"

# Loop prevention: Claude Code sets this after one block to avoid infinite loops.
# We respect it — the block message instructs the agent to complete the full
# review protocol before attempting to stop again.
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then exit 0; fi

CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
if [ -z "$CWD" ]; then exit 0; fi

# Gate: GSD project check
if [ ! -d "$CWD/.planning/phases" ]; then exit 0; fi

# Build STATE.md phase allowlist — same logic as dhx-execute-stop-review.sh.
# Restricts CONTEXT.md discovery to phases STATE.md says Claude is actively
# working on. Kills bulk-restore false positives where historical CONTEXT.md
# files get fresh mtimes via `git checkout <sha> -- .planning/` and `ls -t`
# then picks an ancient phase's deferred items.
#
# See dhx-execute-stop-review.sh:49-93 for the rationale behind N-1 fallback
# and the field list below.
STATE_FILE="$CWD/.planning/STATE.md"
PHASE_ALLOWLIST=""
if [ -f "$STATE_FILE" ]; then
  SIGNAL_LINES=$(grep -E '^stopped_at:|^\*\*Phase:\*\*|^\*\*Current Phase:\*\*|^\*\*Current focus:\*\*|^\*\*Last Activity Description:\*\*|^\*\*Last activity description:\*\*' "$STATE_FILE" 2>/dev/null)
  STATE_NUMS=$({
    printf '%s\n' "$SIGNAL_LINES" | grep -oE '[Pp]hase[[:space:]]+[0-9]+(\.[0-9]+)?' | sed 's/^[Pp]hase[[:space:]]*//'
    printf '%s\n' "$SIGNAL_LINES" | grep -oE '^\*\*(Current )?Phase:\*\*[[:space:]]+[0-9]+(\.[0-9]+)?' | sed -E 's/^\*\*[^*]+\*\*[[:space:]]*//'
  } | sort -u | grep -v '^$')

  if [ -n "$STATE_NUMS" ]; then
    for n in $STATE_NUMS; do
      n_int=$(echo "$n" | grep -oE '^[0-9]+' | sed 's/^0*//')
      [ -z "$n_int" ] && n_int="0"
      PHASE_ALLOWLIST="${PHASE_ALLOWLIST} ${n_int}"
      if [ "$n_int" -gt 0 ]; then
        PHASE_ALLOWLIST="${PHASE_ALLOWLIST} $((n_int - 1))"
      fi
    done
    PHASE_ALLOWLIST=$(echo "$PHASE_ALLOWLIST" | tr ' ' '\n' | sort -u | grep -v '^$')
  fi
fi

# Find most recent CONTEXT.md — filtered to allowlisted phases if available,
# otherwise fall back to unfiltered (preserves old behavior when STATE.md
# is missing or unparseable).
LATEST=""
if [ -n "$PHASE_ALLOWLIST" ]; then
  while IFS= read -r candidate; do
    [ -z "$candidate" ] && continue
    dir_name=$(basename "$(dirname "$candidate")")
    phase_from_dir=$(echo "$dir_name" | grep -oE '^[0-9]+' | sed 's/^0*//')
    [ -z "$phase_from_dir" ] && phase_from_dir="0"
    if grep -qFx "$phase_from_dir" <<< "$PHASE_ALLOWLIST"; then
      LATEST="$candidate"
      break
    fi
  done <<< "$(ls -t "$CWD"/.planning/phases/*/*-CONTEXT.md 2>/dev/null)"
  # If allowlist exists but nothing matched, there's nothing relevant to
  # review — skip the hook rather than falling back to an unrelated phase.
  [ -z "$LATEST" ] && exit 0
else
  LATEST=$(ls -t "$CWD"/.planning/phases/*/*-CONTEXT.md 2>/dev/null | head -1)
fi
if [ -z "$LATEST" ]; then exit 0; fi

# Extract deferred section.
# Line-anchored patterns prevent body-prose mentions of `<deferred>` (e.g.
# "(See `<deferred>` below)" inside a decision) from shifting the sed range
# start into the middle of the document. The discuss template always places
# <deferred>/</deferred> tags alone on their own line — see
# ~/.claude/dhx/references/discuss-templates.md. Reported 2026-04-11,
# reports/done/2026-04-11-deferred-check-sed-tag-collision.md.
#
# When tag extraction returns empty, a secondary fallback checks for deferred
# items under markdown headers (## Deferred / ## Deferred Ideas). This catches
# content placed outside the tagged section — see Gap 1 in
# reports/done/2026-04-12-context-tag-corpus-analysis.md.
#
# Header-fallback: when the <deferred> tag section is missing OR present but
# empty (no bullets), check for deferred items under markdown headers
# (## Deferred / ## Deferred Ideas). This catches Edge Cases 1 and 2 from
# the corpus analysis. The fallback fires from two branches: (a) empty sed
# extraction and (b) non-empty extraction but zero bullet items after filtering.
check_header_fallback() {
  local file="$1"
  # Two-stage pipeline parity with the main UNCAPTURED path: Stage 1
  # (classify_deferred_lines, marker silencing) + Stage 2
  # (auto_silence_deferred_lines, REQ-ID / dated-filename resolution).
  # The fallback was Stage 1 only until 2026-05-27 — an item under an untagged
  # `## Deferred` header whose only durable-home signal is a Stage 2 signal
  # (resolvable REQ-ID or dated `.md` citation) was silenced by the main path
  # but surfaced as a false positive here. See docs/decisions.md 2026-05-27
  # header-fallback Stage 2 parity row + brief
  # .planning/backlog/2026-05-22-deferred-check-header-fallback-missing-stage2-autosilence.md.
  MD_DEFERRED=$(sed -n '/^##[^#].*[Dd]eferred/,/^##[^#]/p' "$file" 2>/dev/null \
    | classify_deferred_lines \
    | auto_silence_deferred_lines "$file")
  if [ -n "$MD_DEFERRED" ]; then
    # WR-03 (Phase 20 code-review follow-up): mirror the main-path D-01/D-10 fix.
    # The prior echo|wc-l count returned 1 for empty/whitespace-only classifier
    # output (the `-n` guard above passes on whitespace), producing a phantom
    # "1 deferred item(s)" header-fallback warning. Count classifier bullets with
    # the same errexit-safe formula as the main UNCAPTURED path, and guard on a
    # positive count before emitting the warning.
    COUNT=$(printf '%s\n' "$MD_DEFERRED" | grep -c '^- ' || true)
    [ "${COUNT:-0}" -le 0 ] && exit 0
    jq -n --arg msg "WARNING: ${COUNT} deferred item(s) found under markdown headers in ${file} but the <deferred> section is empty or missing. Items may not be tracked. Run /dhx:defer-review to inspect." \
      '{"decision": "block", "reason": $msg}'
    exit 0
  fi
  exit 0
}

# SILENCED marker check (D-03 / D-07 / D-28 / D-34).
#
# /dhx:defer-review writes the marker on Step 4a confirmation that all surfaced
# markers persisted to CONTEXT.md. If the marker is fresh (< 10 min) AND its
# filename matches the current state's double-hash (cwd-md5 + deferred-block-md5),
# self-suppress this hook for one session-end — the user just resolved everything
# and shouldn't be re-prompted.
#
# CRITICAL POSITIONING (WARNING #2 Option A from gsd-plan-checker review): this
# check lands BEFORE the <deferred> tag extraction below, BEFORE both
# check_header_fallback invocations (in the empty-tag and empty-classification
# paths). Earlier positioning closes the header-fallback bypass: users with
# `## Deferred` section but no <deferred> XML tag would otherwise hit
# check_header_fallback's internal `exit 0` before reaching any later-positioned
# SILENCED check.
#
# DOUBLE-HASH FILENAME (D-28): the marker encodes BOTH cwd-md5 AND a hash of the
# verbatim <deferred> block text. Mid-TTL CONTEXT.md mutation produces a new
# block-hash → new filename → no match here → hook fires on the new state.
# Closes the codex MEDIUM "marker suppresses changed deferred content during TTL"
# concern by construction.
#
# HELPER-SOURCED (D-34): path computation lives in scripts/dhx-silenced-marker.sh
# (Plan 08-08, single SoT). The defer-review write side (Plan 08-03 Step 4a)
# and this read side BOTH funnel through the *_from_file wrappers, which feed
# silenced_marker_extract_block (awk, no boundary tags) into silenced_marker_path.
# Hash divergence between writer and reader becomes structurally impossible.
#
# Distinct from REVIEW marker (line ~163, 60-min TTL, used by dhx-assessed-guard.sh
# to allow [assessed] writes during active review). Two markers, two consumers,
# two TTLs — see canonical script header doc + skills-repo
# .planning/phases/08-deferred-item-discipline-patches/08-CONTEXT.md decisions
# D-03, D-28, D-34.

# Source the helper from Plan 08-08 (single SoT for the D-28 double-hash idiom)
# Sourced via the canonical $HOME/.claude/dhx-tools/ symlink path (mirrors
# dhx-classify-deferred.sh sourcing convention).
. "$HOME/.claude/dhx-tools/dhx-silenced-marker.sh"

# Path computation funnels through the helper's *_from_file wrapper, which
# internally calls silenced_marker_extract_block (awk, NO boundary tags). The
# defer-review write side (dhx/defer-review.md Step 4a) routes through the
# parallel touch_from_file wrapper feeding the SAME extractor. This is the
# only configuration where writer and reader hash identical bytes — earlier
# inline sed-extraction here captured the boundary tags too, producing a
# different block-hash from the writer's awk extraction (skills-repo CR-01).
# The skills-repo e2e probe (tests/probe-deferred-silence-e2e.sh:81-83) greps
# the hook for `silenced_marker_path_from_file` or `silenced_marker_extract_block`
# as the drift-detection signal — adopting *_from_file here is what flips
# PROBE_MODE from warn-skip to full and unblocks Phase 8 close (D-35 gate).
# INVARIANT: the hook's SILENCED-marker path computation MUST funnel through
# silenced_marker_path_from_file (or silenced_marker_extract_block + silenced_marker_path).
# Direct silenced_marker_path callers are forbidden — they bypass the canonical
# extractor and re-introduce CR-01 writer/reader hash drift.
SILENCED_MARKER=$(silenced_marker_path_from_file "$CWD" "$LATEST")
if [ -f "$SILENCED_MARKER" ] && [ "$(find "$SILENCED_MARKER" -mmin -10 2>/dev/null)" ]; then exit 0; fi

DEFERRED=$(sed -n '/^[[:space:]]*<deferred>[[:space:]]*$/,/^[[:space:]]*<\/deferred>[[:space:]]*$/p' "$LATEST" 2>/dev/null)
if [ -z "$DEFERRED" ]; then
  check_header_fallback "$LATEST"
fi

# Check for "None" placeholder — anchored to avoid matching "none" mid-sentence
if grep -qE '^\s*-?\s*[Nn]one(\s*$|\s+—)' <<< "$DEFERRED"; then exit 0; fi

# Find unassessed items via the canonical classifier (sourced above), then
# drop items that already have a durable home. Both filters live in the
# canonical script — single source of truth so hook count and skill count
# (/dhx:defer-review) cannot diverge. See
# ~/.claude/dhx-tools/dhx-classify-deferred.sh `auto_silence_deferred_lines`
# header for the REQ-ID + dated-filename regex set and the leading-{2,}
# INVARIANT that rejects D-NN/Q-NN/F-NN GSD labels (backed by
# tests/probes/probe-deferred-check-req-id-regex.sh).
CLASSIFIED=$(printf '%s\n' "$DEFERRED" | classify_deferred_lines)
if [ -z "$CLASSIFIED" ]; then check_header_fallback "$LATEST"; fi

UNCAPTURED=$(printf '%s\n' "$CLASSIFIED" | auto_silence_deferred_lines "$LATEST")
if [ -z "$UNCAPTURED" ]; then exit 0; fi

# Count — Fix A (D-01/D-10): bullet-shape-aware + errexit-safe. `echo|wc -l`
# appended a phantom newline → 1 for empty/whitespace-only input (the phantom
# "1 unassessed item(s)" block). `printf` + `grep -c '^- '` counts only
# classifier bullets (0 for empty/whitespace); trailing `|| true` neutralizes
# grep's rc=1-on-zero-matches so a future `set -e` cannot crash the hook.
COUNT=$(printf '%s\n' "$UNCAPTURED" | grep -c '^- ' || true)
# Fix B (D-01): defense-in-depth numeric guard — if any future regression leaks
# past the line-215 `-z` check, exit silently before rendering a 0-item block.
[ "${COUNT:-0}" -le 0 ] && exit 0

# Signal that deferred review is active (assessed-guard checks this)
REVIEW_MARKER="/tmp/dhx-deferred-review-$(echo "$CWD" | md5sum | cut -d' ' -f1 2>/dev/null || echo "default")"
touch "$REVIEW_MARKER"

# Block message: count line + PRIMARY path + a one-line pointer to where the
# inline marker syntax is canonically documented. D-06 (Phase 20) dropped the
# 6-marker inline legend (reverses e2bd3df 2026-05-02) — the legend re-printed
# ~565 chars (~141 tok) on every Stop block (~127K effective tok/7d) for an
# operator who already knows the markers; marker syntax stays discoverable at
# /dhx:defer-review or /dhx:capture. HP-009 decision:block + the uncaptured-
# items count line are preserved verbatim.
MSG="DEFERRED ITEM REVIEW — ${COUNT} unassessed item(s) in ${LATEST}.

PRIMARY path: resolve via /dhx:defer-review ${LATEST} (interactive review with batched UAQ; touches SILENCED marker on confirmation so this hook self-suppresses for 10 min).

See /dhx:defer-review or /dhx:capture for marker syntax."

jq -n --arg msg "$MSG" \
  '{"decision": "block", "reason": $msg}'

exit 0
