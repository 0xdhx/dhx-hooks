#!/usr/bin/env bash
# probe-pytest-cgroup-cap-e2e.sh
#
# End-to-end cap-FIRES probe for dhx/dhx-pytest-cgroup-cap.sh (DHX-7). Proves the
# brief's acceptance criterion directly: a memory-hungry pytest run OUTSIDE the
# Stop-hook gate, wrapped by THIS hook's rewrite, is OOM-killed by the cgroup.
#
#   Scenario A — a `pytest` command whose (faked) pytest allocates 256 MB under a
#     DHX_PYTEST_CAP_MEM=64M cap → the rewrite runs it inside the scope →
#     cgroup OOM SIGKILL → exit 137. This is the mid-session OOM the gate's
#     Stop-time wrap could never reach.
#   Scenario B — exit-code preservation: a trivially-allocating `pytest` that
#     exits 7 under a generous 4G cap → the rewrite propagates exit 7 (the
#     HP-041 contract; `systemd-run --scope` returns the child's status).
#
# Host-gated: on a host where the memory controller is NOT delegated to the user
# manager (MemoryMax can't enforce), the scenarios soft-SKIP (exit 0) — mirrors
# probe-test-gate-cgroup.sh's HOST_HAS_CGROUP guard so the result is honest, not
# a false pass.
#
# Backs:
#   - docs/decisions.md — 2026-06-30 DHX-7 mid-session pytest cgroup-cap row
#   - docs/hook-patterns.md — HP-041 (exit-code preservation), HP-045 (137 OOM)
#   - .planning/backlog/shipped/2026-06-30-test-gate-cgroup-cap-mid-session-pytest-oom-design.md (AC: "a probe that runs a memory-hungry pytest OUTSIDE the gate and observes the cap fire")
#
# Run: bash tests/probes/probe-pytest-cgroup-cap-e2e.sh
#
# SAFE_FOR_LIVE: no   (executes real `systemd-run --user --scope` to enforce a
#                       cgroup MemoryMax on real subprocesses; the transient scope
#                       units land under live user@.service — self-cleaning on
#                       exit, not config drift. Mirrors probe-test-gate-cgroup.sh.
#                       Fixtures + fake pytest bins live under a per-run mktemp.)
# RUNTIME: ~5s

set -u

HOOK="/home/dhx/repos/hooks/dhx/dhx-pytest-cgroup-cap.sh"
TMP=$(mktemp -d /tmp/probe-pytest-cgroup-cap-e2e.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

# Canonical host-capability gate (same surface as probe-test-gate-cgroup.sh /
# probe-test-gate-host-preconditions.sh): memory controller delegated to the
# user manager. Absent → MemoryMax cannot enforce → soft-skip (honest, not a
# false pass).
CONTROLLERS="/sys/fs/cgroup/user.slice/user-${UID}.slice/user@${UID}.service/cgroup.controllers"
if [ ! -r "$CONTROLLERS" ] || ! grep -qw memory "$CONTROLLERS" 2>/dev/null; then
  echo "SKIP probe-pytest-cgroup-cap-e2e — memory controller not delegated to user manager"
  echo "     (path: $CONTROLLERS) — the rewrite shape is covered by probe-pytest-cgroup-cap.sh."
  echo "0 passed, 0 failed (skipped)"
  exit 0
fi

# Ask the hook to produce the rewrite for `pytest` with a given mem cap.
# Returns the rewritten command string on stdout (empty on no-op).
get_rewrite() {  # MEM
  local mem="$1"
  printf '%s' '{"tool_input":{"command":"pytest"}}' \
    | env "DHX_PYTEST_CAP_MEM=$mem" bash "$HOOK" 2>/dev/null \
    | jq -r '.hookSpecificOutput.updatedInput.command // empty' 2>/dev/null
}

# ----------------------------------------------------------------------------
# Scenario A — cap fires: faked pytest allocates 256 MB under a 64 MB cap → 137.
# ----------------------------------------------------------------------------
FAKE_A="$TMP/bin-a"; mkdir -p "$FAKE_A"
cat > "$FAKE_A/pytest" <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/python3 -c '
data = bytearray(256 * 1024 * 1024)
for i in range(0, len(data), 4096):
    data[i] = 1
'
EOF
chmod +x "$FAKE_A/pytest"

REW_A=$(get_rewrite "64M")
if [ -z "$REW_A" ]; then
  echo "FAIL [A] hook did not rewrite a bare 'pytest' command (cgroup available?)"; FAIL=$((FAIL+1))
else
  A_EXIT=0
  env "PATH=$FAKE_A:$PATH" bash -c "$REW_A" >/dev/null 2>&1 || A_EXIT=$?
  if [ "$A_EXIT" -eq 137 ]; then
    echo "OK   [A] 256 MB pytest under 64 MB cap → cgroup OOM exit 137"; PASS=$((PASS+1))
  else
    echo "FAIL [A] expected exit 137 (cgroup OOM), got $A_EXIT"; FAIL=$((FAIL+1))
    echo "     rewrite: $REW_A"
  fi
fi

# ----------------------------------------------------------------------------
# Scenario B — exit-code preservation: tiny pytest exits 7 under 4G → exit 7.
# ----------------------------------------------------------------------------
FAKE_B="$TMP/bin-b"; mkdir -p "$FAKE_B"
cat > "$FAKE_B/pytest" <<'EOF'
#!/usr/bin/env bash
/usr/bin/python3 -c 'b = bytearray(1024 * 1024)'
exit 7
EOF
chmod +x "$FAKE_B/pytest"

REW_B=$(get_rewrite "4G")
if [ -z "$REW_B" ]; then
  echo "FAIL [B] hook did not rewrite 'pytest' for the 4G case"; FAIL=$((FAIL+1))
else
  B_EXIT=0
  env "PATH=$FAKE_B:$PATH" bash -c "$REW_B" >/dev/null 2>&1 || B_EXIT=$?
  if [ "$B_EXIT" -eq 7 ]; then
    echo "OK   [B] non-OOM pytest exit 7 propagates through the cgroup wrap"; PASS=$((PASS+1))
  else
    echo "FAIL [B] expected exit 7 (preserved), got $B_EXIT"; FAIL=$((FAIL+1))
    echo "     rewrite: $REW_B"
  fi
fi

# ----------------------------------------------------------------------------
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
