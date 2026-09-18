#!/bin/bash
# probe-gsd-canonical-mirror-gate-tiered-outcome.sh — Phase 16 (REQ-DRIFT-ACTION-03),
# reworked 2026-07-14 for the block-all-steady-state ratification (see docs/decisions.md).
#
# Backs REQ-DRIFT-ACTION-03. Exercises the canonical-mirror gate hook's tiered
# outcome (dhx/dhx-gsd-canonical-mirror-gate.sh) under the BLOCK-ALL steady state:
# with a readable backup-meta.json, every in-subtree edit lacking a valid marker
# blocks (exit 2); `files[]` membership now selects only the MESSAGE, not
# block-vs-warn. The only WARN survivor is an ABSENT backup-meta (fresh install).
#
#   (a) BLOCK/member      — exit 2 + "load-bearing" on a backup-meta member
#   (b) PASS              — exit 0 silent with a valid (unexpired, listed) marker
#   (c) BLOCK/non-member  — exit 2 + "no live fork patch" on a non-member subtree
#                           file WITH a POPULATED files[] (was WARN/exit 1 pre-
#                           2026-07-14; this case pins the block-all flip)
#   (d) happy             — exit 0 silent for a path outside the guarded subtree
#   (e) EXPIRED           — an expired marker (past the D-28 60s grace) is treated
#                           as absent → falls through to the BLOCK tier
#   (f) CORRUPT           — an unreadable/non-array backup-meta → WR-02 fail-safe
#                           BLOCK, with the honest "unreadable/corrupt" message
#                           (NOT "load-bearing")
#   (g) EMPTY/negative-control — a parseable `files: []` (today's live steady
#                           state) → block-all with "no live fork patch". This
#                           case is the NEGATIVE CONTROL: it asserts on the
#                           MESSAGE, not just exit 2, because the pre-fix script
#                           ALSO exit-2'd on parseable-empty but with the wrong
#                           "load-bearing" message. Run it against the old script
#                           to see it fail:  GATE=<old> bash <this probe>
#   (h) ABSENT            — a missing backup-meta (fresh install) → WARN/exit 1,
#                           the one surviving WARN tier
#   (i)-(m) prefix-arms   — 2026-07-15 widen to ~/.claude/{agents,skills,
#                           commands}/gsd-* (GSD_PREFIX_MANAGED_DIRS parity):
#                           member block on the agents/ dialect (i), dhx-*
#                           same-dir precision control passes (j), skills/
#                           commands block (k)/(l), marker escape valve honors
#                           the agents/ rel dialect (m)
#
# Backs: 16-SPEC.md REQ-DRIFT-ACTION-03 acceptance criteria (a)-(e), extended
# (f)-(h) for the 2026-07-14 corrupt/parseable-empty split + block-all ratify.
# Run: bash tests/probes/probe-gsd-canonical-mirror-gate-tiered-outcome.sh
# Negative control: GATE=/path/to/pre-fix-gate.sh bash tests/probes/probe-...sh
#   (case (g) — and (c) — MUST fail: the pre-fix script emits "load-bearing" for
#    parseable-empty/non-member instead of "no live fork patch".)
#
# All fixtures (marker dir, backup-meta fixtures, marker files) live under a
# single mktemp -d; the gate hook is fed them via DHX_DRAFT_BUFFER_DIR +
# DHX_BACKUP_META env overrides (locked as MUST-haves by Plan 16-02 Task 2.1).
# The live ~/.cache/dhx/ and ~/.claude/gsd-local-patches/ are never touched.

# SAFE_FOR_LIVE: yes  (mktemp + env-override via DHX_DRAFT_BUFFER_DIR + DHX_BACKUP_META; never reads/writes live ~/.cache/dhx/ or ~/.claude/gsd-local-patches/)
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# GATE is overridable so the negative control can point at a pre-fix copy of the
# hook and prove the message assertions (cases (c)/(g)) actually discriminate.
GATE="${GATE:-$REPO_ROOT/dhx/dhx-gsd-canonical-mirror-gate.sh}"

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
echo "    GATE=$GATE"

SESSION_ID="probe-tiered-$$"

# Fixture backup-metas — keep the probe independent of the live backup-meta.json.
# Populated fixture carries one gsd-core member AND one agents/ member so the
# 2026-07-15 prefix-arm cases (i)-(m) can exercise membership on the new dialect.
BACKUP_META_POPULATED="$TMPDIR/backup-meta-populated.json"
jq -n '{version:1, files:["gsd-core/workflows/execute-phase.md","agents/gsd-ui-auditor.md"]}' > "$BACKUP_META_POPULATED"
BACKUP_META_EMPTY="$TMPDIR/backup-meta-empty.json"          # parseable []  (live steady state)
jq -n '{version:1, files:[]}' > "$BACKUP_META_EMPTY"
BACKUP_META_CORRUPT="$TMPDIR/backup-meta-corrupt.json"      # truncated / unreadable JSON
printf '{"files":' > "$BACKUP_META_CORRUPT"
BACKUP_META_ABSENT="$TMPDIR/backup-meta-absent.json"        # deliberately never created
rm -f "$BACKUP_META_ABSENT"

# Marker dir — empty initially (marker-absent path).
MARKER_DIR="$TMPDIR/markers"
mkdir -p "$MARKER_DIR"
MARKER="$MARKER_DIR/draft-buffer-${SESSION_ID}.json"

# Guarded-subtree paths (derived rel path matches backup-meta files[] dialect).
MEMBER_FILE="$HOME/.claude/gsd-core/workflows/execute-phase.md"
NON_MEMBER_FILE="$HOME/.claude/gsd-core/workflows/some-non-mirrored-file.md"

run_gate() {
  # $1 = file_path. $2 = backup-meta fixture (default: populated). Emits the
  # gate's combined stdout+stderr into OUT; sets global EC.
  local file_path="$1"
  local meta="${2:-$BACKUP_META_POPULATED}"
  local envelope
  envelope=$(jq -n --arg sid "$SESSION_ID" --arg file "$file_path" \
    '{session_id:$sid, tool_name:"Edit", cwd:"/tmp", tool_input:{file_path:$file}}')
  OUT=$(printf '%s' "$envelope" | \
    DHX_DRAFT_BUFFER_DIR="$MARKER_DIR" DHX_BACKUP_META="$meta" \
    bash "$GATE" 2>&1)
  EC=$?
}

# ---- Case (a): BLOCK/member — backup-meta member, populated files[], no marker ----
rm -f "$MARKER"
run_gate "$MEMBER_FILE" "$BACKUP_META_POPULATED"
assert "[a] member (populated files[]) w/o marker → exit 2" \
  bash -c '[ "$1" = "2" ]' _ "$EC"
assert "[a] member → 'load-bearing' message" \
  bash -c 'grep -qF "load-bearing" <<<"$1"' _ "$OUT"
assert "[a] member → emits a cp mirror command" \
  bash -c 'grep -qF "cp " <<<"$1"' _ "$OUT"

# ---- Case (b): PASS — valid marker (unexpired, path listed) ----
# // INVARIANT: a valid marker (expires_at in the future AND the rel path in
# // paths[]) makes the gate exit 0 silent regardless of tier.
FUTURE=$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)
jq -n --arg sid "$SESSION_ID" --arg exp "$FUTURE" \
  '{session_id:$sid, paths:["gsd-core/workflows/execute-phase.md"], expires_at:$exp, reason:"probe fixture"}' \
  > "$MARKER"
run_gate "$MEMBER_FILE" "$BACKUP_META_POPULATED"
assert "[b] valid marker → exit 0" \
  bash -c '[ "$1" = "0" ]' _ "$EC"
assert "[b] valid marker → silent (no stderr)" \
  bash -c '[ -z "$1" ]' _ "$OUT"

# ---- Case (c): BLOCK/non-member — populated files[], target NOT a member ----
# // INVARIANT (block-all steady state, ratified 2026-07-14): with a readable
# // backup-meta a non-member subtree edit BLOCKS (exit 2), not WARNs. Pre-fix
# // this was exit 1 / "WARN:". Assert the exit code AND the message so the case
# // fails against the pre-fix script (which emitted "load-bearing" here too).
rm -f "$MARKER"
run_gate "$NON_MEMBER_FILE" "$BACKUP_META_POPULATED"
assert "[c] non-member (populated files[]) w/o marker → exit 2 (block-all)" \
  bash -c '[ "$1" = "2" ]' _ "$EC"
assert "[c] non-member → 'no live fork patch' message" \
  bash -c 'grep -qF "no live fork patch" <<<"$1"' _ "$OUT"
assert "[c] non-member → NOT 'load-bearing' (truthful: it is not a member)" \
  bash -c '! grep -qF "load-bearing" <<<"$1"' _ "$OUT"
assert "[c] non-member → NOT 'WARN:' (block-all, no warn downgrade)" \
  bash -c '! grep -qF "WARN:" <<<"$1"' _ "$OUT"

# ---- Case (d): happy path — file outside the guarded subtree ----
run_gate "/tmp/random-non-gsd-file.txt" "$BACKUP_META_POPULATED"
assert "[d] non-GSD path → exit 0" \
  bash -c '[ "$1" = "0" ]' _ "$EC"
assert "[d] non-GSD path → silent" \
  bash -c '[ -z "$1" ]' _ "$OUT"

# ---- Case (e): EXPIRED marker treated as absent → BLOCK tier ----
# // INVARIANT: a marker whose expires_at is past the D-28 60s grace is treated
# // as absent — the gate falls through to the tier it would emit with no marker.
PAST=$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)
jq -n --arg sid "$SESSION_ID" --arg exp "$PAST" \
  '{session_id:$sid, paths:["gsd-core/workflows/execute-phase.md"], expires_at:$exp, reason:"probe expired fixture"}' \
  > "$MARKER"
run_gate "$MEMBER_FILE" "$BACKUP_META_POPULATED"
assert "[e] expired marker treated as absent → exit 2" \
  bash -c '[ "$1" = "2" ]' _ "$EC"
assert "[e] expired marker → BLOCK tier (BLOCKED:)" \
  bash -c 'grep -qF "BLOCKED:" <<<"$1"' _ "$OUT"

# ---- Case (f): CORRUPT backup-meta → WR-02 fail-safe BLOCK, honest message ----
# // INVARIANT: an unreadable / non-array backup-meta blocks (mirror state
# // unverifiable) and must NOT masquerade as a "load-bearing" member — the two
# // states were conflated pre-2026-07-14.
rm -f "$MARKER"
run_gate "$NON_MEMBER_FILE" "$BACKUP_META_CORRUPT"
assert "[f] corrupt backup-meta → exit 2 (fail-safe)" \
  bash -c '[ "$1" = "2" ]' _ "$EC"
assert "[f] corrupt → 'unreadable/corrupt' message" \
  bash -c 'grep -qF "unreadable/corrupt" <<<"$1"' _ "$OUT"
assert "[f] corrupt → NOT 'load-bearing' (it is not a member; it is corrupt)" \
  bash -c '! grep -qF "load-bearing" <<<"$1"' _ "$OUT"

# ---- Case (g): EMPTY files[] (NEGATIVE CONTROL) → block-all, truthful message ----
# // INVARIANT (negative control, ratified 2026-07-14): a parseable `files: []`
# // (today's live steady state) is NOT corruption — it blocks by design as
# // unmirrored-WIP. The assertion is on the MESSAGE, because exit-2 alone does
# // not discriminate the fix: the PRE-FIX script also exit-2'd here, but with
# // "load-bearing". Running this probe with GATE=<pre-fix> MUST fail this case.
rm -f "$MARKER"
run_gate "$NON_MEMBER_FILE" "$BACKUP_META_EMPTY"
assert "[g] parseable-empty files[] → exit 2 (block-all steady state)" \
  bash -c '[ "$1" = "2" ]' _ "$EC"
assert "[g] parseable-empty → 'no live fork patch' message (truthful)" \
  bash -c 'grep -qF "no live fork patch" <<<"$1"' _ "$OUT"
assert "[g] parseable-empty → NOT 'load-bearing' (negative control vs pre-fix)" \
  bash -c '! grep -qF "load-bearing" <<<"$1"' _ "$OUT"

# ---- Case (h): ABSENT backup-meta (fresh install) → the one surviving WARN ----
# // INVARIANT: a missing backup-meta is legitimate (fork mirror not yet
# // installed) and warns (exit 1) rather than blocking — do not obstruct a
# // not-yet-set-up host. This is distinct from CORRUPT (present but unreadable).
rm -f "$MARKER"
run_gate "$NON_MEMBER_FILE" "$BACKUP_META_ABSENT"
assert "[h] absent backup-meta → exit 1 (WARN, fresh-install advisory)" \
  bash -c '[ "$1" = "1" ]' _ "$EC"
assert "[h] absent → 'WARN:' message" \
  bash -c 'grep -qF "WARN:" <<<"$1"' _ "$OUT"

# ════ 2026-07-15 prefix-managed arms (agents/skills/commands gsd-*) ════
# // INVARIANT: the gate's guarded surface includes the GSD_PREFIX_MANAGED_DIRS
# // arms — ~/.claude/{agents,skills,commands}/gsd-* — with IDENTICAL tier
# // behavior to the gsd-core/ subtree (block-all, membership picks message,
# // marker escape valve honors the agents/... rel-path dialect). A dhx-*
# // agent in the SAME directory must stay unguarded (precision control).

# ---- Case (i): BLOCK/member on the agents/ dialect — registered fork-tracked agent ----
rm -f "$MARKER"
run_gate "$HOME/.claude/agents/gsd-ui-auditor.md" "$BACKUP_META_POPULATED"
assert "[i] agents/ member (gsd-ui-auditor) w/o marker → exit 2" \
  bash -c '[ "$1" = "2" ]' _ "$EC"
assert "[i] agents/ member → 'load-bearing' message" \
  bash -c 'grep -qF "load-bearing" <<<"$1"' _ "$OUT"
assert "[i] agents/ member → cp command targets gsd-local-patches/agents/" \
  bash -c 'grep -qF "gsd-local-patches/agents/gsd-ui-auditor.md" <<<"$1"' _ "$OUT"

# ---- Case (j): PRECISION negative-control — dhx-* agent in the same dir passes ----
# // INVARIANT: the arm is the gsd- PREFIX, not the agents/ DIRECTORY. User
# // agents (dhx-*) share ~/.claude/agents/ by design (D-08 namespace split)
# // and must never block. This case fails if the arm ever widens to the dir.
run_gate "$HOME/.claude/agents/dhx-coupling-verifier.md" "$BACKUP_META_POPULATED"
assert "[j] agents/dhx-* (user agent, same dir) → exit 0" \
  bash -c '[ "$1" = "0" ]' _ "$EC"
assert "[j] agents/dhx-* → silent" \
  bash -c '[ -z "$1" ]' _ "$OUT"

# ---- Case (k): BLOCK/non-member on skills/gsd-* (sweep-DELETE surface) ----
run_gate "$HOME/.claude/skills/gsd-capture/SKILL.md" "$BACKUP_META_POPULATED"
assert "[k] skills/gsd-* w/o marker → exit 2 (block-all)" \
  bash -c '[ "$1" = "2" ]' _ "$EC"
assert "[k] skills/gsd-* → 'no live fork patch' message (non-member)" \
  bash -c 'grep -qF "no live fork patch" <<<"$1"' _ "$OUT"

# ---- Case (l): BLOCK/non-member on commands/gsd-* (profile-staged surface) ----
run_gate "$HOME/.claude/commands/gsd-plan.md" "$BACKUP_META_POPULATED"
assert "[l] commands/gsd-* w/o marker → exit 2 (block-all)" \
  bash -c '[ "$1" = "2" ]' _ "$EC"

# ---- Case (m): escape-valve parity — valid marker on the agents/ rel dialect ----
# // INVARIANT: the draft-buffer marker suppresses the gate for agents/... rel
# // paths exactly as for gsd-core/... ones (REL_PATH strip is prefix-agnostic;
# // the operator-authorized-edit valve must not be subtree-only).
FUTURE=$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)
jq -n --arg sid "$SESSION_ID" --arg exp "$FUTURE" \
  '{session_id:$sid, paths:["agents/gsd-ui-auditor.md"], expires_at:$exp, reason:"probe agents-dialect fixture"}' \
  > "$MARKER"
run_gate "$HOME/.claude/agents/gsd-ui-auditor.md" "$BACKUP_META_POPULATED"
assert "[m] valid marker on agents/ dialect → exit 0" \
  bash -c '[ "$1" = "0" ]' _ "$EC"
assert "[m] valid marker on agents/ dialect → silent" \
  bash -c '[ -z "$1" ]' _ "$OUT"
rm -f "$MARKER"

echo "---"
echo "$PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
