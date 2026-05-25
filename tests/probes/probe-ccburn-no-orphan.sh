#!/usr/bin/env bash
# Probe: runCcburn() orphan-prevention invariant (2026-05-25 ccburn-storm incident).
#
# INVARIANT: every ccburn subprocess runCcburn() spawns is bounded by coreutil
# `timeout`, so the child self-terminates even when the Node wrapper is SIGKILLed
# mid-flight (CC cancels an in-flight statusline by killing the wrapper on the next
# refresh). A Node-side setTimeout would die with the parent and orphan the child,
# which then blocks indefinitely on fsync against a degraded WSL writeback layer —
# the incident's amplification loop. This is ccburn's belated compliance with the
# D-14 "no unbounded subprocess on the render hot path" rule (2026-04-26 capture-pane
# wedge precedent).
#
# Backs: docs/statusline-wrapper.md § ccburn segment (orphan-prevention),
#        reports/2026-05-25-ccburn-storm-statusline-spawn-hardening.md.
# Drives the REAL exported runCcburn (not a reimplementation) under a hung fake
# ccburn injected via PATH.
#
# SAFE_FOR_LIVE: yes
# Reason: mktemp-scoped fake ccburn on PATH + node -e require of the live wrapper;
# the fake emits nothing so buildCcburnSegment returns '' and appendTrace never
# fires (no live ~/.cache/dhx write); SIGKILL targets only this probe's own
# backgrounded node, pkill -f targets only the unique $TMP path. No live state.
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

# Fake ccburn: a single hanging process (faithful to the real python ccburn — no
# grandchildren, so `timeout` killing its direct child is sufficient). The tmpdir
# path lands in argv so pgrep -f can count survivors without touching real ccburn.
cat > "$TMP/ccburn" <<'EOF'
#!/usr/bin/env python3
import time
time.sleep(60)
EOF
chmod +x "$TMP/ccburn"

# --- § 1 child self-terminates after the Node parent is SIGKILLed ------------
# Start runCcburn, then SIGKILL node ~0.3s in (simulating CC's in-flight cancel),
# while collect's `timeout` band (0.8s) is still open.
PATH="$TMP:$PATH" node -e '
  const w = require(process.argv[1]);
  w.runCcburn(JSON.stringify({ session_id: "probe" })).catch(() => {});
  setTimeout(() => {}, 60000); // keep node alive until SIGKILLed
' "$WRAPPER" &
NODE_PID=$!
disown "$NODE_PID" 2>/dev/null || true  # suppress the shell's SIGKILL job notice
sleep 0.3
kill -9 "$NODE_PID" 2>/dev/null
# Wait past collect timeout (0.8s) + kill-after (0.5s) + generous margin.
sleep 3
survivors_after_kill=$(pgrep -fc "$TMP/ccburn" 2>/dev/null); :
ok "no orphaned ccburn after parent SIGKILL" "$survivors_after_kill" "0"

# --- § 2 runCcburn returns within budget under a hung ccburn (no render hang) -
start=$(date +%s.%N)
PATH="$TMP:$PATH" timeout 8 node -e '
  require(process.argv[1]).runCcburn("{}").then((s) => { process.stdout.write(String(s)); process.exit(0); });
' "$WRAPPER" >/dev/null 2>&1
rc=$?
end=$(date +%s.%N)
elapsed=$(awk -v a="$start" -v b="$end" 'BEGIN { printf "%.2f", b - a }')
ok "runCcburn resolves (rc 0) under hung ccburn" "$rc" "0"
# collect(0.8s)+kill(0.5s)+json(1.2s)+kill(0.5s) worst case ≈ 3.0s; allow 5s.
within_budget=$(awk -v e="$elapsed" 'BEGIN { print (e < 5.0) ? "yes" : "no" }')
ok "runCcburn returns within budget (${elapsed}s < 5s)" "$within_budget" "yes"

# --- § 3 no fake-ccburn survives a completed run -----------------------------
sleep 2
survivors_after_run=$(pgrep -fc "$TMP/ccburn" 2>/dev/null); :
ok "no surviving ccburn after completed run" "$survivors_after_run" "0"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
