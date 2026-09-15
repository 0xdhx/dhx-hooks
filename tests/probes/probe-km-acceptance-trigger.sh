#!/usr/bin/env bash
# SAFE_FOR_LIVE: yes  (runs dhx/dhx-km-acceptance.sh under env -i with DHX_HOOKS_CACHE_DIR,
#   CLAUDE_CODE_EXECPATH and DHX_KM_ACCEPTANCE_PROBE pointed into mktemp — a fake versioned
#   binary path and a stub probe. The real acceptance probe and Claude Code never run; nothing
#   live is read or written apart from a read-only grep of the in-repo dispatcher.)
#
# Guards the once-per-CC-version acceptance trigger (docs/decisions.md 2026-09-15 pre-launch row):
#   K1  no result → exit 0 at once; the probe runs DETACHED with --acceptance-out <cache>/<ver>.json
#       --binary <bin>; the in-flight marker is removed when it finishes
#   K2  stored pass → exit 0, silent, no new run
#   K3  stored fail → exit 1 with one stderr line naming the version and the detail
#   K4  fresh in-flight marker → exit 0, no second run
#   K5  in-flight marker older than 15 min → a new run starts
#   K6  a probe that dies without writing a result → an error result is written for it
#   K7  a binary whose basename is not a version → exit 0, no run
#   K8  DHX_KM_ACCEPTANCE_DISABLE=1 → exit 0, no run
#   K9  session-start.sh dispatches it through _dhx_child, after registry-heal
# Run: bash tests/probes/probe-km-acceptance-trigger.sh
set -u

REPO=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || echo /home/dhx/repos/hooks)
HOOK="$REPO/dhx/dhx-km-acceptance.sh"
DISPATCH="$REPO/dhx-plugin/plugins/dhx/hooks/session-start.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0
check() {  # name status
  if [[ "$2" == "0" ]]; then printf '  ✓ %s\n' "$1"; PASS=$((PASS + 1))
  else printf '  ✗ %s\n' "$1"; FAIL=$((FAIL + 1)); fi
}

mkdir -p "$T/home" "$T/versions"
printf '#!/bin/sh\nexit 0\n' > "$T/versions/9.9.9"
printf '#!/bin/sh\nexit 0\n' > "$T/versions/claude-dev"
chmod +x "$T/versions/9.9.9" "$T/versions/claude-dev"

STUB="$T/stub-probe.sh"
cat > "$STUB" <<'STUB'
#!/bin/bash
out=""
bin=""
while (( $# >= 2 )); do
  case "$1" in
    --acceptance-out) out=$2 ;;
    --binary) bin=$2 ;;
  esac
  shift 2
done
printf '%s\n' "$bin" >> "$STUB_CALLS"
case "${STUB_MODE:-pass}" in
  pass) printf '{"status":"pass","detail":""}\n' > "$out" ;;
  fail) printf '{"status":"fail","detail":"not accepted: BADJSON:rejected"}\n' > "$out" ;;
  none) : ;;
esac
STUB
chmod +x "$STUB"

# run CACHE [VAR=value ...] — runs the hook; rc in $?, stderr in CACHE.err
run() {
  local cache=$1
  shift
  env -i PATH=/usr/bin:/bin HOME="$T/home" DHX_HOOKS_CACHE_DIR="$cache" \
    CLAUDE_CODE_EXECPATH="$T/versions/9.9.9" DHX_KM_ACCEPTANCE_PROBE="$STUB" \
    STUB_CALLS="$cache.calls" "$@" bash "$HOOK" </dev/null 2>"$cache.err"
}
wait_for() {  # path → 0 once it exists (≤5 s)
  local i
  for i in $(seq 1 50); do [[ -e "$1" ]] && return 0; sleep 0.1; done
  return 1
}
wait_gone() {  # path → 0 once it is gone (≤5 s)
  local i
  for i in $(seq 1 50); do [[ -e "$1" ]] || return 0; sleep 0.1; done
  return 1
}
calls() { [[ -f "$1.calls" ]] && wc -l < "$1.calls" || echo 0; }

echo "=== dhx-km-acceptance.sh — 9 checks (K1-K9) ==="

# ---- K1 no result → detached run with the right arguments ----
c="$T/k1"
t0=$(date +%s%N)
run "$c"
rc=$?
ms=$(( ($(date +%s%N) - t0) / 1000000 ))
wait_for "$c/km-acceptance/9.9.9.json"
got=$?
wait_gone "$c/km-acceptance/9.9.9.running"
gone=$?
[[ "$rc" == "0" && "$got" == "0" && "$gone" == "0" && "$(cat "$c.calls" 2>/dev/null)" == "$T/versions/9.9.9" ]]
check "K1 no result: exit 0 in ${ms}ms; probe ran detached with --binary; marker removed" $?

# ---- K2 stored pass → silent, no new run ----
run "$c"
rc=$?
sleep 0.3
[[ "$rc" == "0" && ! -s "$c.err" && "$(calls "$c")" == "1" ]]
check "K2 stored pass: exit 0, no stderr, no second run" $?

# ---- K3 stored fail → exit 1, one line ----
c="$T/k3"
mkdir -p "$c/km-acceptance"
printf '{"status":"fail","detail":"not accepted: BADJSON:rejected"}\n' > "$c/km-acceptance/9.9.9.json"
run "$c"
rc=$?
[[ "$rc" == "1" && "$(grep -c . "$c.err")" == "1" ]] \
  && grep -q '^km acceptance fail at CC 9.9.9: not accepted: BADJSON:rejected' "$c.err"
check "K3 stored fail: exit 1 with one stderr line naming version and detail" $?

# ---- K4 fresh in-flight marker → no second run ----
c="$T/k4"
mkdir -p "$c/km-acceptance/9.9.9.running"
run "$c"
rc=$?
sleep 0.3
[[ "$rc" == "0" && "$(calls "$c")" == "0" ]]
check "K4 fresh in-flight marker: exit 0, no run" $?

# ---- K5 stale in-flight marker → new run ----
c="$T/k5"
mkdir -p "$c/km-acceptance/9.9.9.running"
touch -d '-20 minutes' "$c/km-acceptance/9.9.9.running"
run "$c"
wait_for "$c/km-acceptance/9.9.9.json"
check "K5 marker older than 15 min: a new run starts and writes a result" $?

# ---- K6 probe dies without a result → error result ----
c="$T/k6"
run "$c" STUB_MODE=none
wait_for "$c/km-acceptance/9.9.9.json"
[[ "$(jq -r '.status' "$c/km-acceptance/9.9.9.json" 2>/dev/null)" == "error" ]]
check "K6 probe exits without a result: an error result is written" $?

# ---- K7 non-version basename → no run ----
c="$T/k7"
env -i PATH=/usr/bin:/bin HOME="$T/home" DHX_HOOKS_CACHE_DIR="$c" CLAUDE_CODE_EXECPATH="$T/versions/claude-dev" \
  DHX_KM_ACCEPTANCE_PROBE="$STUB" STUB_CALLS="$c.calls" bash "$HOOK" </dev/null 2>/dev/null
rc=$?
sleep 0.3
[[ "$rc" == "0" && "$(calls "$c")" == "0" ]]
check "K7 binary basename not a version: exit 0, no run" $?

# ---- K8 disabled → no run ----
c="$T/k8"
run "$c" DHX_KM_ACCEPTANCE_DISABLE=1
rc=$?
sleep 0.3
[[ "$rc" == "0" && "$(calls "$c")" == "0" ]]
check "K8 DHX_KM_ACCEPTANCE_DISABLE=1: exit 0, no run" $?

# ---- K9 dispatcher wiring ----
heal_line=$(grep -nE '^_dhx_child registry-heal bash /home/dhx/\.claude/hooks/dhx-plugin-registry-heal\.sh < /dev/null$' "$DISPATCH" | head -n1 | cut -d: -f1)
acc_line=$(grep -nE '^_dhx_child km-acceptance bash /home/dhx/\.claude/hooks/dhx-km-acceptance\.sh < /dev/null$' "$DISPATCH" | head -n1 | cut -d: -f1)
[[ -n "$heal_line" && -n "$acc_line" ]] && (( heal_line < acc_line ))
check "K9 session-start.sh: _dhx_child km-acceptance (line ${acc_line:-?}) after registry-heal (line ${heal_line:-?})" $?

echo "---"
echo "PASS: $PASS  FAIL: $FAIL"
exit $FAIL
