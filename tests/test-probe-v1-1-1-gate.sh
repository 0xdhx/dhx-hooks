#!/usr/bin/env bash
# tests/test-probe-v1-1-1-gate.sh — Companion failure-state tests for probe-v1-1-1-gate.sh
# Asserts each gate's red path + indeterminate paths produce correct Convention A exit codes (D-06).
# Run: bash tests/test-probe-v1-1-1-gate.sh
# Exit: 0 = all pass, 1 = any failure

set -euo pipefail   # D-25 binds tests/probes/ only; this test harness uses errexit.

# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

PROBE="$(cd "$(dirname "$0")/.." && pwd)/tests/probes/probe-v1-1-1-gate.sh"
[[ -r "$PROBE" ]] || { echo "FATAL: probe not found at $PROBE"; exit 1; }

FIXTURES_DIR=$(mktemp -d)
trap 'rm -rf "$FIXTURES_DIR"' EXIT

mkdir -p "$FIXTURES_DIR/empty-bin"

# Helper: invoke probe and capture rc without tripping set -e
run_probe() {
  bash "$PROBE" >/dev/null 2>&1 && echo 0 || echo $?
}

# ----- Test 1: Gate 1 RED — synthetic recent commit (< 7d) ----------------
test_01_gate1_red() {
  echo "Test 1: Gate 1 (commit-age) red → exit 1"
  local recent_epoch=$(( $(date +%s) - 86400 ))   # 1 day ago
  local rc
  rc=$(DHX_PROBE_BC_EPOCH_OVERRIDE="$recent_epoch" run_probe)
  if [[ "$rc" -eq 1 ]]; then
    PASS=$((PASS+1)); echo "  PASS: 1a: probe exits 1 on synthetic recent commit (1d elapsed)"
  else
    FAIL=$((FAIL+1)); echo "  FAIL: 1a: expected exit 1, got $rc"
  fi
}

# ----- Test 2: Gate 4 RED — synthetic CC PID predating bc45a2e ------------
test_02_gate4_red() {
  echo "Test 2: Gate 4 (pre-bc45a2e CC process) red → exit 1"
  local rc
  rc=$(DHX_PROBE_PGREP_FAKE_OUTPUT="99999" \
       DHX_PROBE_PS_LSTART_OVERRIDE="Sat Apr 26 11:00:00 2026" \
       run_probe)
  # 11:00:00 is 57min before bc45a2e (11:57:20). Only this PID, so it's eldest.
  if [[ "$rc" -eq 1 ]]; then
    PASS=$((PASS+1)); echo "  PASS: 2a: probe exits 1 on synthetic stale CC process"
  else
    FAIL=$((FAIL+1)); echo "  FAIL: 2a: expected exit 1, got $rc"
  fi
}

# ----- Test 3: Gate 5 RED — settings.json with read-once reference --------
test_03_gate5_red() {
  echo "Test 3: Gate 5 (settings reachability) red → exit 1"
  local fake_shared="$FIXTURES_DIR/tainted-shared-settings.json"
  local fake_repo="$FIXTURES_DIR/tainted-repo-settings.json"
  cat > "$fake_shared" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "Read", "hooks": [{"command": "~/.claude/read-once/hook.sh"}]}
    ]
  }
}
EOF
  # Repo-side stays clean so we isolate failure to shared
  echo '{}' > "$fake_repo"
  local rc
  rc=$(DHX_PROBE_SHARED_SETTINGS="$fake_shared" \
       DHX_PROBE_REPO_SETTINGS="$fake_repo" \
       run_probe)
  if [[ "$rc" -eq 1 ]]; then
    PASS=$((PASS+1)); echo "  PASS: 3a: probe exits 1 on tainted shared settings.json"
  else
    FAIL=$((FAIL+1)); echo "  FAIL: 3a: expected exit 1, got $rc"
  fi
}

# ----- Test 4: Gate 2 RED — verify-hooks.sh non-zero rc -------------------
test_04_gate2_red() {
  echo "Test 4: Gate 2 (verify-hooks) red → exit 1"
  local rc
  rc=$(DHX_PROBE_VERIFY_HOOKS_RC=1 run_probe)
  if [[ "$rc" -eq 1 ]]; then
    PASS=$((PASS+1)); echo "  PASS: 4a: probe exits 1 on injected verify-hooks rc=1"
  else
    FAIL=$((FAIL+1)); echo "  FAIL: 4a: expected exit 1, got $rc"
  fi
}

# ----- Test 5: Gate 3 RED — legacy mtime newer than eldest CC -------------
# D-21 (cross-AI review 2026-05-05): Inject DHX_PROBE_PGREP_FAKE_OUTPUT +
# DHX_PROBE_PS_LSTART_OVERRIDE so probe Gate 3 deterministically takes the
# "live CC procs found, compare epochs" branch. Without injection, Gate 3
# falls through to "no live CC procs → GREEN" when pgrep finds no matches,
# making Test 5 environment-dependent (passes-by-accident on dev box; would
# fail in clean sandbox where pgrep returns no matches).
test_05_gate3_red() {
  echo "Test 5: Gate 3 (legacy mtime) red → exit 1"
  # Inject a future mtime (way newer than any live CC proc) so legacy < eldest fails.
  local future_mtime=$(( $(date +%s) + 86400 ))
  # Need an existing file because Plan 01 Gate 3 only runs the comparison if the file
  # exists OR the override is non-empty. Provide a real file at fixture path.
  local fake_legacy="$FIXTURES_DIR/fake-reads.jsonl"
  echo '{}' > "$fake_legacy"
  local rc
  # Inject pgrep + lstart so probe's eldest_cc_epoch() helper returns 0 with
  # a known post-bc45a2e epoch. lstart "Fri May 1 21:17:28 2026" is the
  # eldest CC PID lstart from RESEARCH § Q2 (epoch 1777688248), well after
  # the future_mtime so Gate 3 RED comparison fires deterministically.
  rc=$(DHX_PROBE_LEGACY_FILE="$fake_legacy" \
       DHX_PROBE_LEGACY_MTIME_OVERRIDE="$future_mtime" \
       DHX_PROBE_PGREP_FAKE_OUTPUT="99999" \
       DHX_PROBE_PS_LSTART_OVERRIDE="Fri May 1 21:17:28 2026" \
       run_probe)
  if [[ "$rc" -eq 1 ]]; then
    PASS=$((PASS+1)); echo "  PASS: 5a: probe exits 1 on legacy mtime > eldest CC epoch (pgrep+lstart injected)"
  else
    FAIL=$((FAIL+1)); echo "  FAIL: 5a: expected exit 1, got $rc"
  fi
}

# ----- Test 6: Indeterminate — settings.json unparseable ------------------
test_06_indeterminate_unparseable_settings() {
  echo "Test 6: Indeterminate (unparseable settings.json) → exit 2"
  local bad_json="$FIXTURES_DIR/bad-settings.json"
  echo '{not json' > "$bad_json"
  local rc
  rc=$(DHX_PROBE_SHARED_SETTINGS="$bad_json" run_probe)
  if [[ "$rc" -eq 2 ]]; then
    PASS=$((PASS+1)); echo "  PASS: 6a: probe exits 2 on unparseable settings.json (jq parse error)"
  else
    FAIL=$((FAIL+1)); echo "  FAIL: 6a: expected exit 2, got $rc"
  fi
}

# ----- Test 7: Indeterminate — settings.json missing ----------------------
test_07_indeterminate_missing_settings() {
  echo "Test 7: Indeterminate (settings.json missing) → exit 2"
  local rc
  rc=$(DHX_PROBE_SHARED_SETTINGS="$FIXTURES_DIR/does-not-exist.json" run_probe)
  if [[ "$rc" -eq 2 ]]; then
    PASS=$((PASS+1)); echo "  PASS: 7a: probe exits 2 on missing settings.json"
  else
    FAIL=$((FAIL+1)); echo "  FAIL: 7a: expected exit 2, got $rc"
  fi
}

# ----- Test 8: Indeterminate — git lookup fails (PATH-manipulation) ------
# Locked-in design (post-FLAG F-1 from plan-checker 2026-05-04): plant a
# fake `git` on PATH that returns rc=128 ("not a git repo"). Forces the
# probe's `git -C "$REPO" log -1 bc45a2e` lookup to fail, triggering Gate 1
# INDETERMINATE. Does not depend on cwd or alt-repo behavior.
test_08_indeterminate_bc45a2e_drift() {
  echo "Test 8: Indeterminate (bc45a2e unreachable via fake git rc=128) → exit 2"
  cat > "$FIXTURES_DIR/empty-bin/git" <<'EOF'
#!/bin/sh
exit 128
EOF
  chmod +x "$FIXTURES_DIR/empty-bin/git"
  local rc
  rc=$( PATH="$FIXTURES_DIR/empty-bin:$PATH" run_probe )
  rm -f "$FIXTURES_DIR/empty-bin/git"
  if [[ "$rc" -eq 2 ]]; then
    PASS=$((PASS+1)); echo "  PASS: 8a: probe exits 2 when git lookup fails (Gate 1 INDETERMINATE)"
  else
    FAIL=$((FAIL+1)); echo "  FAIL: 8a: expected exit 2, got $rc"
  fi
}

# ----- Test 9: Indeterminate — pgrep returns system error ------------------
test_09_indeterminate_missing_pgrep() {
  echo "Test 9: Indeterminate (pgrep returns rc=2 — system error) → exit 2"
  # Plant a fake pgrep in empty-bin that exits 2 (system error class).
  cat > "$FIXTURES_DIR/empty-bin/pgrep" <<'EOF'
#!/bin/sh
exit 2
EOF
  chmod +x "$FIXTURES_DIR/empty-bin/pgrep"
  local rc
  rc=$( PATH="$FIXTURES_DIR/empty-bin:$PATH" run_probe )
  # Cleanup so subsequent tests don't see the fake pgrep
  rm -f "$FIXTURES_DIR/empty-bin/pgrep"
  if [[ "$rc" -eq 2 ]]; then
    PASS=$((PASS+1)); echo "  PASS: 9a: probe exits 2 when pgrep returns system-error rc"
  else
    FAIL=$((FAIL+1)); echo "  FAIL: 9a: expected exit 2, got $rc"
  fi
}

# ----- Run all tests sequentially ----------------------------------------
echo "=== probe-v1-1-1-gate companion failure-state tests ==="
echo ""

test_01_gate1_red; echo ""
test_02_gate4_red; echo ""
test_03_gate5_red; echo ""
test_04_gate2_red; echo ""
test_05_gate3_red; echo ""
test_06_indeterminate_unparseable_settings; echo ""
test_07_indeterminate_missing_settings; echo ""
test_08_indeterminate_bc45a2e_drift; echo ""
test_09_indeterminate_missing_pgrep; echo ""

print_results
