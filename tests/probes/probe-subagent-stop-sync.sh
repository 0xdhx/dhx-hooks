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

# --- D-18: write_outcome() shell function — DRY single source of truth ----
# Args: $1=arm, $2=run_id, $3=conclusion, $4=exit_code, $5=observations_json
# Path layout per D-08: tests/probes/.results/v1.3-phase-9/<cc_version>/<arm>-<run_id>.json
# Deterministic baseline path: <cc_version>/fixtures-only-baseline.json (no ts field per G-02)
write_outcome() {
  local arm="$1" run_id="$2" conclusion="$3" exit_code_arg="$4" observations="$5"
  local cc_version
  cc_version=$(timeout 1s claude --version 2>/dev/null | awk '{print $1}' || echo "unknown")
  [[ -n "$cc_version" ]] || cc_version="unknown"

  local out_dir_base="$REPO_ROOT/tests/probes/.results/v1.3-phase-9"
  local out_dir="$out_dir_base/$cc_version"
  mkdir -p "$out_dir"

  local out_file
  if [[ "$arm" == "fixtures-only" && "$run_id" == "baseline" ]]; then
    # Deterministic baseline (G-02): no ts field, has built_against_cc_version
    out_file="$out_dir/fixtures-only-baseline.json"
    jq -n \
      --arg id "probe-subagent-stop-sync" \
      --argjson code "$exit_code_arg" \
      --arg built_cc "$cc_version" \
      --arg arm "$arm" \
      --arg run "$run_id" \
      --argjson obs "$observations" \
      --arg conc "$conclusion" \
      '{probe_id:$id, exit_code:$code, exit_code_convention:"exit_0_means_subagent_stop_fires_for_arm", built_against_cc_version:$built_cc, arm:$arm, run_id:$run, observations:$obs, conclusion:$conc}' \
      > "$out_file"
  else
    # Live (or non-baseline fixtures) outcome: includes ts; gitignored per D-08
    out_file="$out_dir/${arm}-${run_id}.json"
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    jq -n \
      --arg id "probe-subagent-stop-sync" \
      --argjson code "$exit_code_arg" \
      --arg cc "$cc_version" \
      --arg ts "$ts" \
      --arg run "$run_id" \
      --arg arm "$arm" \
      --argjson obs "$observations" \
      --arg conc "$conclusion" \
      '{probe_id:$id, exit_code:$code, exit_code_convention:"exit_0_means_subagent_stop_fires_for_arm", cc_version:$cc, ts:$ts, run_id:$run, arm:$arm, observations:$obs, conclusion:$conc}' \
      > "$out_file"
  fi

  echo "OK   outcome-json-written: $out_file"
}

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
  # D-18 + G-02: deterministic fixtures-only baseline write
  write_outcome "fixtures-only" "baseline" "fixtures_only_baseline" 0 '{}'
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
    # File-sentinel mechanism (env vars do not propagate across CC's hook
    # subprocess boundary per HP-011 — file-sentinel works cross-process).
    # Marker hook checks for $PROBE_DIR/force-red-broken-marker and exits
    # without writing capture; probe expects FAIL no-capture as PASS.
    SENTINEL_FILE="$PROBE_DIR/force-red-broken-marker"
    touch "$SENTINEL_FILE"
    # Sentinel cleanup is handled by the live-capture block trap (D-09 hoist
    # in Plan 01 — single trap site, force-red-* glob covers this sentinel).
    echo "DHX_PROBE_FORCE_RED=broken-marker — sentinel file created at $SENTINEL_FILE; expecting FAIL no-capture as PASS"
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

# --- Outcome JSON write (D-04 (b) + (d) refined by D-08; D-18 DRY refactor) ---
# Build per-arm observation block + invoke write_outcome
# D-30 hostname-hash for synthetic identifier (PII surface — paths-summarized)
HOSTNAME_HASH=$(printf '%s' "$(hostname -s)" | sha256sum | awk '{print $1}')

if [[ -s "$CAPTURE_FILE" ]] && jq -e . "$CAPTURE_FILE" >/dev/null 2>&1; then
  payload_keys=$(jq -c '.payload | keys' "$CAPTURE_FILE" 2>/dev/null || echo "[]")
  marker_version_captured=$(jq -r '.metadata.marker_version // 0' "$CAPTURE_FILE" 2>/dev/null || echo "0")
  captured_at_field=$(jq -r '.metadata.captured_at // ""' "$CAPTURE_FILE" 2>/dev/null || echo "")
else
  payload_keys="[]"
  marker_version_captured=0
  captured_at_field=""
fi

ARM_OBSERVATION=$(jq -n \
  --argjson fired "$(if [[ "$exit_code" -eq 0 ]]; then echo true; else echo false; fi)" \
  --argjson elapsed_seconds "${ELAPSED:-0}" \
  --argjson payload_top_level_keys "$payload_keys" \
  --argjson marker_version "$marker_version_captured" \
  --arg captured_at "$captured_at_field" \
  '{fired: $fired, elapsed_seconds: $elapsed_seconds, payload_top_level_keys: $payload_top_level_keys, marker_version: $marker_version, captured_at: $captured_at}')

if [[ "${ARM:-}" == "sync" ]]; then
  OBSERVATIONS=$(jq -n --argjson sync "$ARM_OBSERVATION" --arg published_from_hostname "$HOSTNAME_HASH" \
    '{sync_arm: $sync, bg_arm: null, published_from_hostname: $published_from_hostname}')
elif [[ "${ARM:-}" == "bg" ]]; then
  OBSERVATIONS=$(jq -n --argjson bg "$ARM_OBSERVATION" --arg published_from_hostname "$HOSTNAME_HASH" \
    '{sync_arm: null, bg_arm: $bg, published_from_hostname: $published_from_hostname}')
else
  OBSERVATIONS=$(jq -n --arg published_from_hostname "$HOSTNAME_HASH" \
    '{sync_arm: null, bg_arm: null, published_from_hostname: $published_from_hostname}')
fi

# JSON-time PII sanitizer (D-21 load-bearing gate)
HOST=$(hostname -s)
if echo "$OBSERVATIONS" | grep -qE "(/home/|/Users/|$HOST)"; then
  echo "FATAL: observations contain PII; refusing write"
  exit 2
fi

write_outcome "${ARM:-unknown}" "${RUN_ID:-unknown}" "$conclusion" "$exit_code" "$OBSERVATIONS"
PASS=$((PASS+1))

echo "---"
echo "PASS: $PASS  FAIL: $FAIL  arm=${ARM:-fixtures-only}  conclusion=$conclusion  exit_code=$exit_code"
exit $exit_code
