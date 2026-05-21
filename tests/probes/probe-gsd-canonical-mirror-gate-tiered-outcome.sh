#!/bin/bash
# probe-gsd-canonical-mirror-gate-tiered-outcome.sh — Phase 16 (REQ-DRIFT-ACTION-03).
#
# Backs REQ-DRIFT-ACTION-03. Exercises the canonical-mirror gate hook's tiered
# outcome (dhx/dhx-gsd-canonical-mirror-gate.sh):
#   (a) BLOCK  — exit 2 on a backup-meta member with no valid marker
#   (b) PASS   — exit 0 silent with a valid (unexpired, path-listed) marker
#   (c) WARN   — exit 1 on a non-backup-meta ~/.claude/get-shit-done/ subtree file
#   (d) happy  — exit 0 silent for a path outside the guarded subtree
#   (e) EXPIRED — an expired marker (past the D-28 60s grace) is treated as
#                 absent → falls through to the BLOCK tier
#
# Backs: 16-SPEC.md REQ-DRIFT-ACTION-03 acceptance criteria (a)-(e).
# Run: bash tests/probes/probe-gsd-canonical-mirror-gate-tiered-outcome.sh
#
# All fixtures (marker dir, backup-meta fixture, marker files) live under a
# single mktemp -d; the gate hook is fed them via DHX_DRAFT_BUFFER_DIR +
# DHX_BACKUP_META env overrides (locked as MUST-haves by Plan 16-02 Task 2.1).
# The live ~/.cache/dhx/ and ~/.claude/gsd-local-patches/ are never touched.

# SAFE_FOR_LIVE: yes  (mktemp + env-override via DHX_DRAFT_BUFFER_DIR + DHX_BACKUP_META; never reads/writes live ~/.cache/dhx/ or ~/.claude/gsd-local-patches/)
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$REPO_ROOT/dhx/dhx-gsd-canonical-mirror-gate.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0

assert() {
  local name="$1"; shift
  if "$@"; then
    echo "OK   $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL $name"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== canonical-mirror gate tiered outcome (tmpdir-isolated) ==="

SESSION_ID="probe-tiered-$$"

# Fixture backup-meta with a single fork-tracked entry — keeps the probe
# independent of the live backup-meta.json contents.
BACKUP_META_FIXTURE="$TMPDIR/backup-meta.json"
jq -n '{version:1, files:["get-shit-done/workflows/execute-phase.md"]}' > "$BACKUP_META_FIXTURE"

# Marker dir — empty initially (marker-absent path).
MARKER_DIR="$TMPDIR/markers"
mkdir -p "$MARKER_DIR"
MARKER="$MARKER_DIR/draft-buffer-${SESSION_ID}.json"

# Guarded-subtree paths (derived rel path matches backup-meta files[] dialect).
BACKUP_META_FILE="$HOME/.claude/get-shit-done/workflows/execute-phase.md"
NON_META_FILE="$HOME/.claude/get-shit-done/workflows/some-non-mirrored-file.md"

run_gate() {
  # $1 = file_path. Emits the gate's combined stdout+stderr; sets global EC.
  local file_path="$1"
  local envelope
  envelope=$(jq -n --arg sid "$SESSION_ID" --arg file "$file_path" \
    '{session_id:$sid, tool_name:"Edit", cwd:"/tmp", tool_input:{file_path:$file}}')
  OUT=$(printf '%s' "$envelope" | \
    DHX_DRAFT_BUFFER_DIR="$MARKER_DIR" DHX_BACKUP_META="$BACKUP_META_FIXTURE" \
    bash "$GATE" 2>&1)
  EC=$?
}

# ---- Case (a): BLOCK — backup-meta file, no marker ----
rm -f "$MARKER"
run_gate "$BACKUP_META_FILE"
assert "[a] backup-meta file w/o marker → exit 2" \
  bash -c '[ "$1" = "2" ]' _ "$EC"
assert "[a] BLOCK emits BLOCKED:" \
  bash -c 'echo "$1" | grep -qF "BLOCKED:"' _ "$OUT"
assert "[a] BLOCK emits a cp mirror command" \
  bash -c 'echo "$1" | grep -qF "cp "' _ "$OUT"

# ---- Case (b): PASS — valid marker (unexpired, path listed) ----
# // INVARIANT: a valid marker (expires_at in the future AND the rel path in
# // paths[]) makes the gate exit 0 silent regardless of tier.
FUTURE=$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)
jq -n --arg sid "$SESSION_ID" --arg exp "$FUTURE" \
  '{session_id:$sid, paths:["get-shit-done/workflows/execute-phase.md"], expires_at:$exp, reason:"probe fixture"}' \
  > "$MARKER"
run_gate "$BACKUP_META_FILE"
assert "[b] valid marker → exit 0" \
  bash -c '[ "$1" = "0" ]' _ "$EC"
assert "[b] valid marker → silent (no stderr)" \
  bash -c '[ -z "$1" ]' _ "$OUT"

# ---- Case (c): WARN — non-backup-meta subtree file, no marker ----
rm -f "$MARKER"
run_gate "$NON_META_FILE"
assert "[c] non-backup-meta subtree file w/o marker → exit 1" \
  bash -c '[ "$1" = "1" ]' _ "$EC"
assert "[c] WARN emits WARN:" \
  bash -c 'echo "$1" | grep -qF "WARN:"' _ "$OUT"

# ---- Case (d): happy path — file outside the guarded subtree ----
run_gate "/tmp/random-non-gsd-file.txt"
assert "[d] non-GSD path → exit 0" \
  bash -c '[ "$1" = "0" ]' _ "$EC"
assert "[d] non-GSD path → silent" \
  bash -c '[ -z "$1" ]' _ "$OUT"

# ---- Case (e): EXPIRED marker treated as absent → BLOCK tier ----
# // INVARIANT: a marker whose expires_at is past the D-28 60s grace is treated
# // as absent — the gate falls through to the tier it would emit with no marker.
PAST=$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)
jq -n --arg sid "$SESSION_ID" --arg exp "$PAST" \
  '{session_id:$sid, paths:["get-shit-done/workflows/execute-phase.md"], expires_at:$exp, reason:"probe expired fixture"}' \
  > "$MARKER"
run_gate "$BACKUP_META_FILE"
assert "[e] expired marker treated as absent → exit 2" \
  bash -c '[ "$1" = "2" ]' _ "$EC"
assert "[e] expired marker → BLOCK tier (BLOCKED:)" \
  bash -c 'echo "$1" | grep -qF "BLOCKED:"' _ "$OUT"

echo "---"
echo "$PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
