#!/bin/bash
# probe-subagent-stop-sync.sh
#
# SAFE_FOR_LIVE: yes  (arming-mode writes only to per-process scratch dir;
#                      see SAFE_FOR_LIVE.md row alongside probe-effort-level-stdin-absent.sh)
# RUNTIME: ~5s fixtures-only; up to 300s per arm in live-capture mode
#
# Sync+bg SubagentStop verification probe (BG-AGENT-2, Phase 9). Verifies that
# 9846a21 (3 checkpoint hooks PostToolUse:Agent → SubagentStop, 2026-05-07) AND
# c518c31 (Phase 8 dhx-agent-leak-check.sh migration, 2026-05-08) fire reliably
# for synchronous Skill→Agent dispatches. HP-021 verified only the bg path
# empirically on CC 2.1.112; this probe re-verifies bg as control + verifies
# sync as the load-bearing assumption underlying both migrations.
#
#   exit 0 = SubagentStop fired (PASS or PASS_SLOW); marker captured payload
#   exit 1 = SubagentStop did NOT fire within 300s (FAIL — invoke FAIL Routing
#            Playbook in 09-CONTEXT.md <decisions> to schedule Phase 9.1 Hybrid Option B)
#   exit 2 = ambiguous (internal asserts failed, malformed capture, PII gate, RUN_ID malformed, probe dir perm wrong, etc.)
#
# Mode discrimination (mirrors D-17 from PROBE-01): if probe dir absent at
# start, run fixtures-only mode and exit 0. Operator arms via:
#   install -d -m 700 ${XDG_RUNTIME_DIR:-/tmp}/dhx-subagent-stop-sync-probe   # D-14: explicit 0700 perm
#   echo "sync $(uuidgen)" > $.../flag    # or "bg $(uuidgen)"
#   In a fresh CC session, dispatch agent matching the arm
#   bash tests/probes/probe-subagent-stop-sync.sh
#   rm -rf ${XDG_RUNTIME_DIR:-/tmp}/dhx-subagent-stop-sync-probe   # disarm
#
# Backs:
#   - .planning/phases/09-.../09-CONTEXT.md D-01..D-06 + cascade locks + D-07..D-18 review-driven hardening
#   - .planning/phases/09-.../09-REVIEWS.md (gemini + codex CALL_ID=1)
#   - docs/decisions.md 2026-05-08 BG-AGENT-2 row
#
# Run: bash tests/probes/probe-subagent-stop-sync.sh
set -uo pipefail

PROBE_DIR="${XDG_RUNTIME_DIR:-/tmp}/dhx-subagent-stop-sync-probe"
PASS=0
FAIL=0

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "$(cd "$(dirname "$0")/../.." && pwd)")

assert_eq() {
  local name="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    echo "OK   $name"; PASS=$((PASS+1))
  else
    echo "FAIL $name"; echo "     got:  $got"; echo "     want: $want"; FAIL=$((FAIL+1))
  fi
}

# Inline fixture self-tests — flag-content parser handles both arms
got_arm=""; got_run=""
read -r got_arm got_run <<< "sync abc-123"
assert_eq "fixture: sync flag-parse arm" "$got_arm" "sync"
assert_eq "fixture: sync flag-parse run_id" "$got_run" "abc-123"
read -r got_arm got_run <<< "bg def-456"
assert_eq "fixture: bg flag-parse arm" "$got_arm" "bg"

# Mode discriminator: probe dir absent → fixtures-only mode → exit 0
if [[ ! -d "$PROBE_DIR" ]]; then
  echo "---"
  echo "PASS: $PASS  FAIL: $FAIL  mode=fixtures-only (probe dir absent — arm with: install -d -m 700 $PROBE_DIR)"
  if [[ "$FAIL" -eq 0 ]]; then
    exit 0
  else
    exit 2
  fi
fi

# --- D-14: probe dir 0700 perm assertion -----------------------------------
# install -d -m 700 in operator runbook should produce 0700; assert here so
# multi-user /tmp fallback (XDG_RUNTIME_DIR unset) doesn't silently expose
# capture file PII surface.
PROBE_DIR_PERM="$(stat -c %a "$PROBE_DIR" 2>/dev/null || echo "?")"
if [[ "$PROBE_DIR_PERM" != "700" ]]; then
  echo "FAIL probe-dir-perms: expected 700, got $PROBE_DIR_PERM (use 'install -d -m 700 $PROBE_DIR' or 'mkdir -p $PROBE_DIR && chmod 700 $PROBE_DIR')"
  exit 2
fi

# --- Live-capture preamble: variables needed by trap and red-state branches -
FLAG_FILE="$PROBE_DIR/flag"
MANIFEST="$REPO_ROOT/dhx-plugin/plugins/dhx/hooks/hooks.json"
# CAPTURE_FILE is derived AFTER flag parse (depends on ARM/RUN_ID); trap references
# it by name and bash resolves it at trap-execution time, so empty-init is safe.
CAPTURE_FILE=""
# MANIFEST_BAK is set ONLY by the missing-from-manifest red-state branch via
# mktemp; trap's [[ -f "$MANIFEST_BAK" ]] guard no-ops when unset/empty.
MANIFEST_BAK=""

# --- D-09: EXIT trap pre-installation (HOISTED above DHX_PROBE_FORCE_RED case)
# D-10: includes $FLAG_FILE cleanup (closes phantom-capture window) + uses
# $MANIFEST_BAK (mktemp path) for collision-resistant manifest restore.
# Bash trap with EXIT REPLACES previous traps — single trap site here covers
# ALL arms (normal + broken-marker + missing-from-manifest); do NOT add
# competing traps in the DHX_PROBE_FORCE_RED case branches.
# Trap variables resolve at trap-execution time, so referencing $CAPTURE_FILE /
# $MANIFEST_BAK before they're populated is safe — the [[ -f ... ]] / -n
# guards no-op on empty values.
trap '[[ -n "$MANIFEST_BAK" && -f "$MANIFEST_BAK" ]] && mv "$MANIFEST_BAK" "$MANIFEST"; rm -f "$CAPTURE_FILE" "$FLAG_FILE" "$PROBE_DIR"/force-red-* 2>/dev/null' EXIT

# --- DHX_PROBE_FORCE_RED red-state companion (D-05) ------------------------
# Two scenarios catch distinct failure modes:
#   broken-marker         — marker logic wrong (writes nothing despite firing)
#   missing-from-manifest — HP-012 manifest-edit-without-restart class
#
# The DHX_PROBE_FORCE_RED scenarios run in the SAME probe invocation as the
# normal capture path — operator-driven via env var. Trap is already installed
# above (D-09 hoist) so any exit from here onward triggers cleanup.

case "${DHX_PROBE_FORCE_RED:-}" in
  broken-marker)
    # Sentinel-file mechanism: marker hook (Plan 02) checks for
    # $PROBE_DIR/force-red-broken-marker file and exits without writing capture.
    # File-sentinel works across CC's hook subprocess boundary (env vars do not
    # reliably propagate per HP-011). Plan 02 Task 4 will add the touch call.
    # In RED scaffolding (this commit), no marker exists at all — falls through
    # to the normal capture path which also FAILs no-capture. Inversion
    # (FAIL→PASS) logic gates on EXPECT_FAIL at the classification step.
    echo "DHX_PROBE_FORCE_RED=broken-marker — expecting FAIL no-capture as PASS (probe catches broken marker)"
    EXPECT_FAIL=1
    ;;
  missing-from-manifest)
    # jq surgical removal of marker entry from plugin manifest (mirrors
    # probe-read-guard-strong-signal.sh unregister_read_guard at L60-66).
    # D-10: backup path is mktemp-derived (collision-resistant); trap restores
    # via $MANIFEST_BAK (set here, read by trap on EXIT).
    if [[ -f "$MANIFEST" ]]; then
      MANIFEST_BAK="$(mktemp "${MANIFEST}.dhx-probe-bak.XXXXXX")"
      cp "$MANIFEST" "$MANIFEST_BAK"
      jq '(.hooks.SubagentStop[].hooks) |= map(select((.command // "") | test("dhx-subagent-stop-sync-probe-marker") | not))' \
        "$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
      echo "DHX_PROBE_FORCE_RED=missing-from-manifest — marker entry removed from manifest; backup at $MANIFEST_BAK; expecting FAIL no-capture as PASS"
      EXPECT_FAIL=1
    else
      echo "FAIL manifest-not-found: $MANIFEST"
      exit 2
    fi
    ;;
  "")
    EXPECT_FAIL=0
    ;;
  *)
    echo "FAIL unknown DHX_PROBE_FORCE_RED value: ${DHX_PROBE_FORCE_RED}"
    exit 2
    ;;
esac

# --- Live-capture orchestration --------------------------------------------

# Read arm + run_id from flag (D-03 — two-arm dispatch shape)
if [[ ! -s "$FLAG_FILE" ]]; then
  echo "FAIL flag-file-missing-or-empty: arm via 'echo \"sync \$(uuidgen)\" > $FLAG_FILE' (or \"bg \$(uuidgen)\")"
  exit 2
fi

read -r ARM RUN_ID < "$FLAG_FILE"
if [[ -z "${ARM:-}" || -z "${RUN_ID:-}" ]]; then
  echo "FAIL flag-content-malformed: expected 'sync UUID' or 'bg UUID', got: $(cat "$FLAG_FILE")"
  exit 2
fi
case "$ARM" in
  sync|bg) ;;
  *) echo "FAIL flag-arm-unknown: $ARM (expected sync|bg)"; exit 2 ;;
esac

# D-13: validate RUN_ID shape — prevents path-escape via malformed flag content
# (e.g., RUN_ID="../../etc/passwd" would land capture file outside scratch dir).
# Allowed character class matches uuidgen output shape and basic identifier shapes.
if [[ ! "$RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "FAIL run_id-malformed: $RUN_ID (expected ^[A-Za-z0-9._-]+$ — use 'uuidgen' or 'cat /proc/sys/kernel/random/uuid')"
  exit 2
fi

CAPTURE_FILE="$PROBE_DIR/capture-${ARM}-${RUN_ID}.json"

echo ""
echo "Live capture: arm=$ARM run_id=$RUN_ID — dispatch the matching agent in a fresh CC session. Waiting up to 300s..."

START=$(date +%s)
for i in {1..300}; do
  if [[ -s "$CAPTURE_FILE" ]]; then break; fi
  sleep 1
done
END=$(date +%s)
ELAPSED=$((END - START))

exit_code=2
conclusion="ambiguous"
if [[ ! -s "$CAPTURE_FILE" ]]; then
  echo "FAIL no-capture: SubagentStop did not fire within 300s (arm=$ARM)"
  conclusion="fail_no_capture"
  exit_code=1
elif ! jq -e . "$CAPTURE_FILE" >/dev/null 2>&1; then
  echo "FAIL captured-payload-not-json"
  conclusion="ambiguous_malformed_capture"
  exit_code=2
elif [[ "$ELAPSED" -le 60 ]]; then
  echo "OK   captured in ${ELAPSED}s (PASS — fast path)"
  PASS=$((PASS+1))
  conclusion="pass"
  exit_code=0
elif [[ "$ELAPSED" -le 300 ]]; then
  echo "OK   captured in ${ELAPSED}s (PASS_SLOW — advisory: SubagentStop fires but with unexpected lag; flagged for Phase 15 cross-version delta corpus)"
  PASS=$((PASS+1))
  conclusion="pass_slow"
  exit_code=0
fi

# Invert verdict for DHX_PROBE_FORCE_RED scenarios — FAIL no-capture is the
# expected outcome (proves the probe catches the broken state).
if [[ "${EXPECT_FAIL:-0}" -eq 1 ]]; then
  if [[ "$exit_code" -eq 1 ]]; then
    echo "OK   red-state companion: probe correctly caught broken marker / missing-from-manifest (FAIL→PASS inversion)"
    PASS=$((PASS+1))
    exit_code=0
    conclusion="red_state_caught"
  else
    echo "FAIL red-state companion: probe did NOT catch broken state (capture appeared anyway — vacuous PASS risk)"
    FAIL=$((FAIL+1))
    exit_code=1
    conclusion="red_state_missed"
  fi
fi

echo "---"
echo "PASS: $PASS  FAIL: $FAIL  arm=${ARM:-fixtures-only}  conclusion=$conclusion  exit_code=$exit_code"
exit $exit_code
