#!/bin/bash
# probe-effort-level-stdin-absent.sh
#
# SAFE_FOR_LIVE: yes  (read-only via file-gated wrapper edit; no live mutation)
# RUNTIME: ~5s
#
# Supersession-watchdog probe (D-12). Asserts the negative premise that
# CC's statusline-wrapper stdin payload does NOT include `effortLevel` /
# `effort` keys at the top level.
#   exit 0 = premise holds (P3 work warranted) OR fixtures-only mode (no probe dir)
#   exit 1 = upstream supersession found (ship P5 retire instead)
#   exit 2 = ambiguous (internal asserts failed, capture timed out, etc.)
#
# Mode discrimination (D-17): if ${XDG_RUNTIME_DIR:-/tmp}/dhx-statusline-stdin-probe
# directory exists at probe-script start, run live-capture mode; otherwise run
# fixtures-only mode (the bash scripts/run-probes.sh path) and exit 0. Operator
# arms live capture by `mkdir -p ${XDG_RUNTIME_DIR:-/tmp}/dhx-statusline-stdin-probe`
# before invoking the probe. PROBE-01 #PROBE-01
#
# Backs:
#   - .planning/REQUIREMENTS.md PROBE-01
#   - docs/decisions.md 2026-04-30 supersession-watchdog row
#
# Run: bash tests/probes/probe-effort-level-stdin-absent.sh
set -uo pipefail

PROBE_DIR="${XDG_RUNTIME_DIR:-/tmp}/dhx-statusline-stdin-probe"
PASS=0
FAIL=0

assert_eq() {
  local name="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    echo "OK   $name"; PASS=$((PASS+1))
  else
    echo "FAIL $name"; echo "     got:  $got"; echo "     want: $want"; FAIL=$((FAIL+1))
  fi
}

# --- Stdin key-detection self-test (D-19) -------------------------------------
# Inline node -e JSON parser checks top-level effortLevel/effort key presence.
# Does NOT import dhx-statusline.js (no parsePaneEffort dependency).
declare -a STDIN_FIXTURES=(
  "no-effort-keys|absent|{\"workspace\":{\"current_dir\":\"/tmp\"},\"session_id\":\"x\"}"
  "effortLevel-present|present|{\"effortLevel\":\"high\",\"workspace\":{\"current_dir\":\"/tmp\"}}"
  "effort-present|present|{\"effort\":\"max\",\"workspace\":{\"current_dir\":\"/tmp\"}}"
  "both-effort-keys|present|{\"effortLevel\":\"high\",\"effort\":\"max\",\"workspace\":{\"current_dir\":\"/tmp\"}}"
  "malformed-json|absent|not json {{{"
)

for f in "${STDIN_FIXTURES[@]}"; do
  name=${f%%|*}; rest=${f#*|}
  expected=${rest%%|*}; body=${rest#*|}
  got=$(printf '%s' "$body" | node -e '
    let buf=""; process.stdin.on("data",c=>buf+=c).on("end",()=>{
      try {
        const d = JSON.parse(buf);
        const has = ("effortLevel" in d) || ("effort" in d);
        process.stdout.write(has ? "present" : "absent");
      } catch { process.stdout.write("absent"); }
    });')
  assert_eq "fixture: $name" "$got" "$expected"
done

# D-17 mode discriminator: probe dir absent → fixtures-only mode → exit 0
if [[ ! -d "$PROBE_DIR" ]]; then
  echo "---"
  echo "PASS: $PASS  FAIL: $FAIL  mode=fixtures-only (probe dir absent — arm with: mkdir -p $PROBE_DIR)"
  if [[ "$FAIL" -eq 0 ]]; then
    exit 0
  else
    exit 2
  fi
fi

# --- Live-capture orchestration (D-16 — fixed-path file convention) ----------
RUN_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || date +%s%N)
FLAG_FILE="$PROBE_DIR/flag"
CAPTURE_FILE="$PROBE_DIR/capture-$RUN_ID.json"

# Trap-clean only this run's flag + capture file (preserve probe dir for operator concurrency)
trap 'rm -f "$FLAG_FILE" "$CAPTURE_FILE"' EXIT

# Run-id propagation channel: flag file content (env var doesn't reach the wrapper subprocess
# launched by CC's parent process — sibling, not child, of probe's bash).
echo "$RUN_ID" > "$FLAG_FILE"
echo ""
echo "Live capture: trigger a statusline refresh (any keystroke / new turn). Waiting up to 30s..."

for i in {1..30}; do
  if [[ -s "$CAPTURE_FILE" ]]; then break; fi
  sleep 1
done

exit_code=2
conclusion="ambiguous"
if [[ ! -s "$CAPTURE_FILE" ]]; then
  echo "FAIL live-capture-timeout: no statusline refresh observed in 30s"
  FAIL=$((FAIL+1))
else
  if ! jq -e . "$CAPTURE_FILE" >/dev/null 2>&1; then
    echo "FAIL captured-payload-not-json"
    FAIL=$((FAIL+1))
  else
    PASS=$((PASS+1))
    echo "OK   captured-payload-valid-json"
  fi
fi

# --- Observation extraction + Convention A exit code (D-01) -----------------
# Detection scope: top-level effortLevel/effort keys only.
has_effort=$(jq -r '(has("effortLevel") or has("effort"))' "$CAPTURE_FILE" 2>/dev/null || echo "false")
stdin_keys_json=$(jq -c 'keys' "$CAPTURE_FILE" 2>/dev/null || echo "[]")
workspace_present=$(jq -r 'has("workspace") and (.workspace | has("current_dir"))' "$CAPTURE_FILE" 2>/dev/null || echo "false")

if [[ "$FAIL" -gt 0 ]]; then
  exit_code=2
  conclusion="ambiguous"
elif [[ "$has_effort" == "true" ]]; then
  exit_code=1
  conclusion="supersession_found_drop_p3"
else
  exit_code=0
  conclusion="v1_2_work_warranted"
fi

# --- Outcome JSON write (D-08 schema; D-30 hostname-hash; live cc_version) ---
CC_VERSION=$(claude --version 2>/dev/null | awk '{print $1}')
[[ -n "$CC_VERSION" ]] || CC_VERSION="unknown"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "$(cd "$(dirname "$0")/../.." && pwd)")
OUT_DIR="$REPO_ROOT/tests/probes/.results/v1.2-phase-0"
mkdir -p "$OUT_DIR"
OUT_FILE="$OUT_DIR/probe-effort-level-stdin-absent.json"

# D-30: published_from_hostname is SHA-256 of hostname -s (synthetic identifier)
HOSTNAME_HASH=$(printf '%s' "$(hostname -s)" | sha256sum | awk '{print $1}')

OBSERVATIONS=$(jq -n \
  --argjson keys "$stdin_keys_json" \
  --argjson effortLevel_present "$(jq -r 'has("effortLevel")' "$CAPTURE_FILE" 2>/dev/null || echo false)" \
  --argjson effort_present "$(jq -r 'has("effort")' "$CAPTURE_FILE" 2>/dev/null || echo false)" \
  --argjson workspace_current_dir_present "$workspace_present" \
  --arg published_from_hostname "$HOSTNAME_HASH" \
  '{stdin_payload_top_level_keys:$keys, effortLevel_present:$effortLevel_present, effort_present:$effort_present, workspace_current_dir_present:$workspace_current_dir_present, published_from_hostname:$published_from_hostname}')

# JSON-time sanitizer (D-21 load-bearing gate): refuse to write if observations contain PII
HOST=$(hostname -s)
if echo "$OBSERVATIONS" | grep -qE "(/home/|/Users/|$HOST)"; then
  echo "FATAL: observations contain PII; refusing write"
  exit 2
fi

jq -n \
  --arg id "probe-effort-level-stdin-absent" \
  --argjson code "$exit_code" \
  --arg cc "$CC_VERSION" \
  --arg ts "$TS" \
  --arg run "$RUN_ID" \
  --argjson obs "$OBSERVATIONS" \
  --arg conc "$conclusion" \
  '{probe_id:$id, exit_code:$code, exit_code_convention:"exit_0_means_v1_2_work_warranted", cc_version:$cc, ts:$ts, run_id:$run, observations:$obs, conclusion:$conc}' \
  > "$OUT_FILE"

echo "OK   outcome-json-written: $OUT_FILE"
PASS=$((PASS+1))

# --- Summary + exit (Convention A) -------------------------------------------
echo "---"
echo "PASS: $PASS  FAIL: $FAIL  conclusion=$conclusion  exit_code=$exit_code"
exit $exit_code
