#!/usr/bin/env bash
# dhx-agent-leak-check.sh — SubagentStop hook
# Patterns: HP-009, HP-011, HP-021
#
# 2026-05-08 event migration: PostToolUse:Agent → SubagentStop. PostToolUse:Agent
# fires AT DISPATCH for run_in_background=true (HP-011 addendum) — the leak
# check would diff against an empty post-state because the subagent hadn't run
# yet. SubagentStop fires on actual subagent completion (HP-021, CC 2.1.112).
# Stdin schema changes (HP-021): no `tool_input.*` keys; isolation context
# restored from sidecar metadata file written by dhx-agent-leak-snapshot.sh.
# Old-shape fallback retained on `session_id` reads only for the transition
# window per HP-012 (stale-snapshot CC processes may still deliver legacy shape).
#
# D-08: atomic mv-claim before diff to resolve concurrent-SubagentStop race.
# D-10: strict schema validation — missing required field → DETECTION GAP.
# D-12: nullglob discipline on every ${SESSION}-* glob expansion.
# D-13: scan ALL orphan .pre files regardless of META_FILES count.
# D-14/SC#10: pre-existing ${SESSION}.pre files from old registration are
#             silently skipped under new check.sh (HP-012 transition window).

set -euo pipefail   # MIRROR existing check.sh; pipefail-safe via // empty + || true

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then exit 0; fi

# Only stdin field used: session_id. Defensive fallback chain matches 9846a21.
SESSION=$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null)
[[ -n "$SESSION" ]] || exit 0

CACHE="$HOME/.cache/dhx"

# ============================================================================
# D-13 orphan-detection completeness (default scan-orphans-first ordering).
# Scan ALL .pre files in the session glob, regardless of whether sibling
# .meta.json sidecars exist. An orphan .pre means snapshot half-failed
# (.pre written, .meta.json write failed, atomicity rollback didn't fire).
# D-12: wrap in nullglob to prevent literal-glob-string in messages/rm.
# ============================================================================
shopt -s nullglob
PRE_FILES=("$CACHE/agent-leak-${SESSION}-"*.pre)
META_FILES=("$CACHE/agent-leak-${SESSION}-"*.meta.json)
shopt -u nullglob

# Detect orphans: .pre files whose paired .meta.json is missing.
ORPHAN_PRES=()
for pre in "${PRE_FILES[@]}"; do
  paired_meta="${pre%.pre}.meta.json"
  if [[ ! -f "$paired_meta" ]]; then
    ORPHAN_PRES+=("$pre")
  fi
done

if [[ ${#ORPHAN_PRES[@]} -gt 0 ]]; then
  cat <<DETECTGAP
⚠ AGENT-LEAK DETECTION GAP — orphan baseline file(s) present without sidecar metadata for session ${SESSION}.

Found .pre file(s) without paired .meta.json:
${ORPHAN_PRES[*]}

The dhx-agent-leak-snapshot.sh hook half-failed (baseline written, sidecar write failed).
Leak detection for the affected dispatch(es) is BLIND because isolation context cannot be restored.
DETECTGAP
  # Cleanup orphan .pre files (snapshot's atomicity rollback didn't fire — clean up now).
  for orphan in "${ORPHAN_PRES[@]}"; do
    rm -f "$orphan" 2>/dev/null
  done
  # Continue — sibling valid pairs (if any) still need processing.
fi

# ============================================================================
# 4-state branch (D-04(d)). If no .meta.json files at all → silent skip
# (handles both legitimate non-worktree dispatch AND HP-012 transition window
# per SC#10/D-14 where pre-existing ${SESSION}.pre exists alone from old
# registration — orphan-scan above already handled cleanup).
# ============================================================================
if [[ ${#META_FILES[@]} -eq 0 ]]; then
  exit 0   # silent (D-14/SC#10: HP-012 transition window — graceful no-crash)
fi

# ============================================================================
# D-10 strict schema validation: each sidecar must have ALL required fields.
# Required: schema_version, cwd, isolation, dispatched_at. (subagent_type
# tolerated absent → "unknown" fallback in WARNING.)
# Missing-field path → DETECTION GAP, symmetric with malformed-JSON path.
# ============================================================================
OLDEST_META=""
OLDEST_TS=""
for meta in "${META_FILES[@]}"; do
  # First: malformed JSON → DETECTION GAP (D-02).
  if ! jq -e . "$meta" >/dev/null 2>&1; then
    PAIRED_PRE="${meta%.meta.json}.pre"
    if [[ -f "$PAIRED_PRE" ]]; then PRE_STATE="present"; else PRE_STATE="absent"; fi
    cat <<MALFORMED
⚠ AGENT-LEAK DETECTION GAP — sidecar metadata for session ${SESSION} is malformed.

Found: ${meta} (jq parse failure)
Pair:  ${PAIRED_PRE} (${PRE_STATE})

The dhx-agent-leak-snapshot.sh hook wrote a metadata sidecar that this check
cannot parse. Leak detection for this dispatch is BLIND because isolation
context cannot be restored. The pair has been preserved on disk for forensic
inspection (NOT cleaned up — investigate before next dispatch).

Common causes:
  - Snapshot wrote partial JSON before crash (set -euo pipefail interruption).
  - Filesystem corruption or out-of-space mid-write.
  - Manual edit of the cache file.

Inspect with:
  cat ${meta}
  cat ${PAIRED_PRE}
MALFORMED
    exit 0
  fi

  # Second: D-10 strict schema validation — missing required field → DETECTION GAP.
  MISSING_FIELDS=()
  for field in schema_version cwd isolation dispatched_at; do
    if ! jq -e --arg f "$field" 'has($f) and (.[$f] != null) and (.[$f] != "")' "$meta" >/dev/null 2>&1; then
      MISSING_FIELDS+=("$field")
    fi
  done
  if [[ ${#MISSING_FIELDS[@]} -gt 0 ]]; then
    PAIRED_PRE="${meta%.meta.json}.pre"
    if [[ -f "$PAIRED_PRE" ]]; then PRE_STATE="present"; else PRE_STATE="absent"; fi
    cat <<SCHEMAGAP
⚠ AGENT-LEAK DETECTION GAP — sidecar metadata for session ${SESSION} is missing required field(s).

Found: ${meta}
Missing field(s): ${MISSING_FIELDS[*]}
Pair:  ${PAIRED_PRE} (${PRE_STATE})

The sidecar parses as JSON but is missing fields required by the D-02 schema
contract (schema_version, cwd, isolation, dispatched_at). Leak detection for
this dispatch is BLIND. The pair has been preserved on disk for forensic
inspection (NOT cleaned up — investigate before next dispatch).
SCHEMAGAP
    exit 0
  fi

  # Third: pick oldest by dispatched_at (D-03 FIFO consumption).
  TS=$(jq -r '.dispatched_at // empty' "$meta" 2>/dev/null)
  [[ -z "$TS" ]] && continue   # defensive — should be unreachable post D-10
  if [[ -z "$OLDEST_TS" || "$TS" < "$OLDEST_TS" ]]; then
    OLDEST_TS="$TS"
    OLDEST_META="$meta"
  fi
done

[[ -n "$OLDEST_META" ]] || exit 0   # all sidecars filtered out

# ============================================================================
# D-08 atomic mv-claim. The `mv` syscall is atomic on POSIX filesystems.
# If a sibling SubagentStop process already claimed this sidecar, mv fails
# (target exists or source missing) → continue loop to next-oldest unclaimed.
# ============================================================================
CLAIMED_META="${OLDEST_META}.claimed.$$"
if ! mv "$OLDEST_META" "$CLAIMED_META" 2>/dev/null; then
  # Lost the race; sibling process already claimed. Look for next-oldest unclaimed.
  shopt -s nullglob
  REMAINING=("$CACHE/agent-leak-${SESSION}-"*.meta.json)
  shopt -u nullglob
  [[ ${#REMAINING[@]} -eq 0 ]] && exit 0   # nothing left to claim
  # Recompute oldest among remaining (defensive — usually one mv loss is rare).
  OLDEST_META=""
  OLDEST_TS=""
  for meta in "${REMAINING[@]}"; do
    TS=$(jq -r '.dispatched_at // empty' "$meta" 2>/dev/null)
    [[ -z "$TS" ]] && continue
    if [[ -z "$OLDEST_TS" || "$TS" < "$OLDEST_TS" ]]; then
      OLDEST_TS="$TS"
      OLDEST_META="$meta"
    fi
  done
  [[ -n "$OLDEST_META" ]] || exit 0
  CLAIMED_META="${OLDEST_META}.claimed.$$"
  mv "$OLDEST_META" "$CLAIMED_META" 2>/dev/null || exit 0
fi

PRE="${OLDEST_META%.meta.json}.pre"

# Branch: exactly one present (.meta.json claimed but paired .pre missing) → DETECTION GAP.
if [[ ! -f "$PRE" ]]; then
  cat <<DETECTGAP
⚠ AGENT-LEAK DETECTION GAP — sidecar metadata present but baseline missing for session ${SESSION}.

Found: ${CLAIMED_META} (claimed)
Missing: ${PRE}

The dhx-agent-leak-snapshot.sh hook half-failed (sidecar written, baseline write failed).
Leak detection for this dispatch is BLIND because the pre-dispatch worktree state was not captured.
DETECTGAP
  rm -f "$CLAIMED_META" 2>/dev/null
  exit 0
fi

# ============================================================================
# Branch: both present → normal compare path (D-04(d) happy case).
# Read sidecar context from CLAIMED_META (post-rename path).
# ============================================================================
CWD_FROM_SIDECAR=$(jq -r '.cwd // empty' "$CLAIMED_META" 2>/dev/null)
ISOLATION_FROM_SIDECAR=$(jq -r '.isolation // empty' "$CLAIMED_META" 2>/dev/null)
SUBAGENT_FROM_SIDECAR=$(jq -r '.subagent_type // "unknown"' "$CLAIMED_META" 2>/dev/null)

# Nested-worktree skip via SIDECAR cwd (D-04(e)) — NOT via SubagentStop stdin cwd.
if [[ "$CWD_FROM_SIDECAR" == *".claude/worktrees/"* ]]; then
  rm -f "$PRE" "$CLAIMED_META" 2>/dev/null
  exit 0   # nested-worktree dispatch is intentionally not tracked
fi

[[ -n "$CWD_FROM_SIDECAR" ]] || { rm -f "$PRE" "$CLAIMED_META" 2>/dev/null; exit 0; }

POST_STATUS=$(git -C "$CWD_FROM_SIDECAR" status --porcelain 2>/dev/null || echo "")
PRE_STATUS=$(cat "$PRE")

# Cleanup CONSUMED PAIR ONLY (siblings persist for sibling SubagentStop fires per D-03).
rm -f "$PRE" "$CLAIMED_META" 2>/dev/null

NEW=$(diff <(echo "$PRE_STATUS") <(echo "$POST_STATUS") 2>/dev/null | grep '^>' | sed 's/^> //' | head -15 || true)

[[ -z "$NEW" ]] && exit 0

# ============================================================================
# WARNING heredoc body — D-15 INLINED VERBATIM (no template, no preserve-from-file).
# Source: original dhx-agent-leak-check.sh lines 91-107, with two intentional
# changes ONLY: (1) added `with isolation=${ISOLATION_FROM_SIDECAR}` to the
# subject line (was bare `with isolation=worktree`), and (2) `${SUBAGENT}`
# variable renamed to `${SUBAGENT_FROM_SIDECAR}` to reflect sidecar source.
# All other text is character-for-character identical to the original.
# ============================================================================
cat <<WARNING
⚠ WORKTREE LEAK SUSPECTED — main repo modified while subagent (${SUBAGENT_FROM_SIDECAR}) with isolation=${ISOLATION_FROM_SIDECAR} ran.

New entries in main repo working tree (not present before dispatch):
${NEW}

Known Claude Code bug: https://github.com/anthropics/claude-code/issues/36182
Edit/Write calls inside the subagent can resolve to main-repo absolute paths
instead of worktree-rooted ones, silently leaking writes.

If unexpected, recover before proceeding:
  git stash push -u -m "leak-\$(date -Iseconds)"
  git merge worktree-agent-<id> --no-ff
  # verify with probes / tests, drop stash after

If expected (agent intentionally wrote to shared state), no action needed.
WARNING

exit 0
