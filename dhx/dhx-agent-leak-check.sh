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

# WR-02: explicit schema-version compatibility window. Bump these in lockstep
# with snapshot.sh's `schema_version: N` payload when the D-02 schema evolves.
# Sidecars outside [SCHEMA_MIN_SUPPORTED..SCHEMA_MAX_SUPPORTED] surface as a
# DETECTION GAP (version-skew), preserved on disk for forensic inspection.
# Without this, a future v2 sidecar would parse fine but be interpreted under
# v1 field semantics — silent data corruption across the HP-012 transition window.
SCHEMA_MIN_SUPPORTED=1
SCHEMA_MAX_SUPPORTED=1

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
#
# BL-01 fix: schema problems on ONE sidecar must NOT block sibling valid pairs.
# Continue past malformed/missing-field metas (preserve on disk for forensics);
# accumulate SCHEMA_GAPS for a single batched DETECTION GAP message; still pick
# OLDEST_META from the surviving valid sidecars so wave-execute parallel
# dispatches don't lose leak detection on every sibling subagent forever.
#
# WR-01 FIFO ordering: the canonical "oldest" key is the filename's TIMESTAMP_NS
# suffix (nanosecond resolution from snapshot.sh:49 `date +%s%N`), NOT the
# JSON `dispatched_at` field (second resolution; ties on bursts within the same
# wall-clock second). Filename ns is strictly more informative and resolves
# bursts deterministically. `dispatched_at` remains in the schema as
# presentation-only metadata for forensics; do NOT key FIFO on it.
# ============================================================================
# WR-01 helper: extract the TIMESTAMP_NS suffix from a sidecar filename. The
# convention is agent-leak-${SESSION}-${TIMESTAMP_NS}.meta.json (snapshot.sh:51).
# Returns the ns string on stdout, or empty if the filename doesn't match.
fifo_key() {
  local path="$1" base
  base="${path##*/}"               # strip directory
  base="${base%.meta.json}"        # strip extension
  base="${base##agent-leak-${SESSION}-}"  # strip session prefix → leaves TIMESTAMP_NS
  printf '%s' "$base"
}

OLDEST_META=""
OLDEST_TS=""
SCHEMA_GAPS=()   # accumulate (file + reason) for batch reporting
for meta in "${META_FILES[@]}"; do
  # First: malformed JSON → record gap, preserve on disk, continue to siblings.
  if ! jq -e . "$meta" >/dev/null 2>&1; then
    PAIRED_PRE="${meta%.meta.json}.pre"
    if [[ -f "$PAIRED_PRE" ]]; then PRE_STATE="present"; else PRE_STATE="absent"; fi
    SCHEMA_GAPS+=("${meta} (malformed JSON; pair=${PAIRED_PRE} ${PRE_STATE})")
    continue
  fi

  # Second: D-10 strict schema validation — missing required field → record gap.
  MISSING_FIELDS=()
  for field in schema_version cwd isolation dispatched_at; do
    if ! jq -e --arg f "$field" 'has($f) and (.[$f] != null) and (.[$f] != "")' "$meta" >/dev/null 2>&1; then
      MISSING_FIELDS+=("$field")
    fi
  done
  if [[ ${#MISSING_FIELDS[@]} -gt 0 ]]; then
    PAIRED_PRE="${meta%.meta.json}.pre"
    if [[ -f "$PAIRED_PRE" ]]; then PRE_STATE="present"; else PRE_STATE="absent"; fi
    SCHEMA_GAPS+=("${meta} (missing required field(s): ${MISSING_FIELDS[*]}; pair=${PAIRED_PRE} ${PRE_STATE})")
    continue
  fi

  # WR-02: validate schema_version VALUE (not just presence). A future schema
  # bump leaves stale CC processes running v1 snapshot.sh while the new
  # check.sh expects vN — without this gate, fields are accepted under wrong
  # semantics. Outside [MIN..MAX] → record gap, preserve on disk, continue.
  SV=$(jq -r '.schema_version // empty' "$meta" 2>/dev/null)
  if ! [[ "$SV" =~ ^[0-9]+$ ]] || (( SV < SCHEMA_MIN_SUPPORTED )) || (( SV > SCHEMA_MAX_SUPPORTED )); then
    PAIRED_PRE="${meta%.meta.json}.pre"
    if [[ -f "$PAIRED_PRE" ]]; then PRE_STATE="present"; else PRE_STATE="absent"; fi
    SCHEMA_GAPS+=("${meta} (unsupported schema_version=${SV:-<empty>}; supported=${SCHEMA_MIN_SUPPORTED}..${SCHEMA_MAX_SUPPORTED}; pair=${PAIRED_PRE} ${PRE_STATE})")
    continue
  fi

  # Third: pick oldest by FILENAME ns suffix (D-03 FIFO consumption).
  # WR-01: canonical FIFO key is the ns suffix (nanosecond resolution),
  # NOT JSON `dispatched_at` (second resolution; ties on bursts).
  TS=$(fifo_key "$meta")
  [[ -z "$TS" ]] && continue   # defensive — filename didn't match expected shape
  if [[ -z "$OLDEST_TS" || "$TS" < "$OLDEST_TS" ]]; then
    OLDEST_TS="$TS"
    OLDEST_META="$meta"
  fi
done

# BL-01 fix: emit a SINGLE combined DETECTION GAP listing all schema-problem
# sidecars (preserved on disk for forensic inspection), then continue with
# whatever valid pair (if any) was found. This decouples "preserve for forensics"
# from "block sibling processing" — without it, one corrupt sidecar would
# permanently block all valid sibling pairs in the same session (silent #36182
# regression).
if [[ ${#SCHEMA_GAPS[@]} -gt 0 ]]; then
  cat <<SCHEMAGAP
⚠ AGENT-LEAK DETECTION GAP — ${#SCHEMA_GAPS[@]} sidecar(s) for session ${SESSION} have schema problems.

The following sidecar(s) cannot be parsed or are missing required field(s) per
the D-02 schema contract (schema_version, cwd, isolation, dispatched_at).
Each problem pair is preserved on disk for forensic inspection (NOT cleaned up —
investigate before next dispatch). Sibling valid pairs (if any) are still being
processed below. Leak detection for the affected dispatch(es) is BLIND because
isolation context cannot be restored.

$(printf '  - %s\n' "${SCHEMA_GAPS[@]}")

Common causes:
  - Snapshot wrote partial JSON before crash (set -euo pipefail interruption).
  - Filesystem corruption or out-of-space mid-write.
  - Manual edit of the cache file.
  - Schema-version skew between snapshot.sh and check.sh (HP-012 transition window).
SCHEMAGAP
fi

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
  # WR-01: same filename-ns FIFO key as the primary loop above.
  OLDEST_META=""
  OLDEST_TS=""
  for meta in "${REMAINING[@]}"; do
    TS=$(fifo_key "$meta")
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
