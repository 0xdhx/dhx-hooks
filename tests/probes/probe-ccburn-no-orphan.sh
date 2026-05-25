#!/usr/bin/env bash
# Probe: runCcburn() cache + orphan-prevention invariants (2026-05-25 ccburn-storm).
#
# runCcburn() is stale-while-revalidate: the render path returns a cached segment
# instantly and NEVER blocks on ccburn; when the cache is stale it fires ONE
# detached, timeout-bounded background refresher. `ccburn --json --once` is a heavy
# ~5s usage scan, so taking it off the render path (and throttling it to one run per
# TTL) is the actual fix for the incident — the timeout alone only stopped orphans.
#
# INVARIANTS:
#  1. runCcburn returns fast even when ccburn would hang (cache-read path, no block).
#  2. The detached refresher is `timeout`-bounded, so it self-terminates and cannot
#     orphan into a storm — even though it deliberately OUTLIVES the wrapper (it must,
#     to finish the slow scan and write the cache). This is the D-14 compliance.
#  3. No ccburn survives once the band elapses, whether or not the parent was killed.
#  (Single-flight via the pre-spawn mtime-claim is covered by construction — see the
#   claim block in runCcburn — not timing-raced here.)
#
# Backs docs/statusline-wrapper.md § ccburn segment +
# reports/2026-05-25-ccburn-storm-statusline-spawn-hardening.md. Drives the REAL
# exported runCcburn under a hung fake ccburn + tiny env-override bands.
#
# SAFE_FOR_LIVE: yes
# Reason: mktemp-scoped fake ccburn on PATH; DHX_CCBURN_CACHE points the cache at the
# tmpdir so nothing touches live ~/.cache/dhx; SIGKILL targets only this probe's own
# backgrounded node, pkill -f matches only the unique $TMP path. No live state.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WRAPPER="$REPO_ROOT/dhx/statusline-wrapper.js"

pass=0; fail=0
ok() {
  if [ "$2" = "$3" ]; then echo "OK   $1"; pass=$((pass+1));
  else echo "FAIL $1"; echo "  got:  $2"; echo "  want: $3"; fail=$((fail+1)); fi
}

TMP="$(mktemp -d)"
cleanup() { pkill -f "$TMP/ccburn" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

# Fake ccburn: a single hanging process (faithful to real ccburn — no grandchildren,
# so `timeout` killing its direct child suffices). The tmpdir path lands in argv so
# pgrep -f can count survivors without touching real ccburn.
cat > "$TMP/ccburn" <<'EOF'
#!/usr/bin/env python3
import time
time.sleep(60)
EOF
chmod +x "$TMP/ccburn"

# Tiny bands + always-stale TTL + tmp cache → the refresher fires every call and its
# ccburn is killed at ~1s instead of the production 10s.
export PATH="$TMP:$PATH"
export DHX_CCBURN_CACHE="$TMP/ccburn-json.json"
export DHX_CCBURN_TTL_MS=0
export DHX_CCBURN_REFRESH_TIMEOUT=1s
export DHX_CCBURN_COLLECT_TIMEOUT=1s
export DHX_CCBURN_KILL_AFTER=0.5s

# --- § 1 runCcburn returns fast — never blocks on the hung ccburn ----------------
start=$(date +%s.%N)
timeout 8 node -e 'require(process.argv[1]).runCcburn("{}").then(()=>process.exit(0))' "$WRAPPER" >/dev/null 2>&1
rc=$?
end=$(date +%s.%N)
elapsed=$(awk -v a="$start" -v b="$end" 'BEGIN { printf "%.2f", b - a }')
ok "runCcburn resolves (rc 0) with a hung ccburn" "$rc" "0"
fast=$(awk -v e="$elapsed" 'BEGIN { print (e < 2.0) ? "yes" : "no" }')
ok "runCcburn returns fast (${elapsed}s < 2s — does not await the scan)" "$fast" "yes"

# --- § 2 detached refresher self-terminates after the parent is SIGKILLed ---------
# Start runCcburn (fires the detached refresher), kill the node parent ~0.4s in.
node -e '
  const w = require(process.argv[1]);
  w.runCcburn(JSON.stringify({ session_id: "probe" }));
  setTimeout(() => {}, 60000); // keep node alive until SIGKILLed
' "$WRAPPER" &
NODE_PID=$!
disown "$NODE_PID" 2>/dev/null || true  # suppress the shell's SIGKILL job notice
sleep 0.4
kill -9 "$NODE_PID" 2>/dev/null
# Wait past refresh timeout (1s) + kill-after (0.5s) + margin.
sleep 3
survivors_after_kill=$(pgrep -fc "$TMP/ccburn" 2>/dev/null); :
ok "no orphaned ccburn after parent SIGKILL (detached refresher self-bounds)" "$survivors_after_kill" "0"

# --- § 3 no survivors after a normal completed run --------------------------------
sleep 2
survivors_after_run=$(pgrep -fc "$TMP/ccburn" 2>/dev/null); :
ok "no surviving ccburn after the band elapses" "$survivors_after_run" "0"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
