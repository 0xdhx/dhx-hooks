#!/usr/bin/env bash
# probe-pytest-cgroup-cap-e2e.sh
#
# End-to-end cap-FIRES probe for dhx/dhx-pytest-cgroup-cap.sh (DHX-7). Proves the
# brief's acceptance criterion directly: a memory-hungry pytest run OUTSIDE the
# Stop-hook gate, wrapped by THIS hook's rewrite, is OOM-killed by the cgroup.
#
#   Scenario A — a `pytest` command whose (faked) pytest allocates 256 MB under a
#     DHX_PYTEST_CAP_MEM=64M cap → the rewrite runs it inside the scope →
#     cgroup OOM kill. This is the mid-session OOM the gate's Stop-time wrap
#     could never reach.
#
#     EXIT STATUS IS NOT THE PRIMARY EVIDENCE (widened 2026-08-12). Per HP-045 a
#     memory overrun surfaces as 137 in every controlled cell but has been
#     observed as 143 in the field, and the discriminating variable is not
#     isolated — so this probe accepts `137|143` and proves the cap fired from
#     the CGROUP instead:
#       - `memory.max` inside the scope equals the requested cap (67108864)
#       - the scope path is a NAMED transient `dhx-cap-*.scope`, not the caller's cgroup
#       - `memory.events` `oom_kill > 0`
#     The first two are published BY THE WORKLOAD ITSELF before it allocates, so
#     they cannot race teardown. `oom_kill` is polled by an out-of-cgroup watcher
#     and is therefore best-effort; see the watcher comment for why an uncaptured
#     read is reported rather than failed.
#
#     Why this matters: a status-only assertion cannot tell "OOM-killed by the
#     cap" from "killed for some other reason while running UNCAPPED." The
#     `memory.max` check is what actually detects an un-capping regression.
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
  # Payload carries the optional Bash fields (timeout / description /
  # run_in_background) like a real CC call would — updatedInput replaces the
  # whole tool_input, so the rewrite must re-emit them (asserted hermetically in
  # probe-pytest-cgroup-cap.sh; here they just ride along like production).
  local mem="$1"
  printf '%s' '{"tool_input":{"command":"pytest","timeout":600000,"description":"probe payload","run_in_background":true}}' \
    | env "DHX_PYTEST_CAP_MEM=$mem" bash "$HOOK" 2>/dev/null \
    | jq -r '.hookSpecificOutput.updatedInput.command // empty' 2>/dev/null
}

# ----------------------------------------------------------------------------
# Scenario A — cap fires: faked pytest allocates 256 MB under a 64 MB cap → 137.
# ----------------------------------------------------------------------------
FAKE_A="$TMP/bin-a"; mkdir -p "$FAKE_A"
EV="$TMP/evidence"; mkdir -p "$EV"

# The workload publishes its OWN cgroup identity and applied cap BEFORE it
# allocates. Everything written here is immune to the teardown race — by the time
# the kill happens these files are already on disk.
cat > "$FAKE_A/pytest" <<'EOF'
#!/usr/bin/env bash
CG=$(awk -F: '$1=="0"{print $3}' /proc/self/cgroup 2>/dev/null)
cat "/sys/fs/cgroup$CG/memory.max"      > "$DHX_EV/memory.max"      2>/dev/null
cat "/sys/fs/cgroup$CG/memory.swap.max" > "$DHX_EV/memory.swap.max" 2>/dev/null
# cgpath is written LAST and is the watcher's start signal — publishing it before
# the cap files would let the watcher read a half-written evidence dir.
printf '%s\n' "$CG" > "$DHX_EV/cgpath"
exec /usr/bin/python3 -c '
data = bytearray(256 * 1024 * 1024)
for i in range(0, len(data), 4096):
    data[i] = 1
'
EOF
chmod +x "$FAKE_A/pytest"

# Out-of-cgroup watcher for memory.events. It must live OUTSIDE the scope: the
# scope's default OOMPolicy=stop takes down every process in the unit, so an
# in-cgroup watcher dies with the workload and never reports.
#
# THE WATCHER'S OWN STARTUP COST IS THE RACE. A first cut spun its wait loop over
# `$(seq 1 200000)`; building that word list delayed the loop by ~1s and the
# watcher missed the entire ~200ms lifecycle — 5/5 runs captured nothing while the
# same logic with a bounded `while` captured oom_kill in 6/6. Keep the pre-loop
# work at zero; do not reintroduce a subshell, a `seq`, or a `sleep` before the
# first read.
#
# TERMINATION IS NOT "the cgroup went away". Cgroup disappearance is the SUCCESS
# path only. Under the very regression this probe exists to catch — an empty
# CGROUP_PREFIX (HP-051) — the workload runs in the CALLER'S long-lived cgroup,
# which never disappears and never OOMs, so a disappearance-only loop spins
# forever and the probe HANGS instead of failing red. (Measured: the first cut of
# this watcher did exactly that against a simulated un-capping, and had to be
# killed by hand.) The caller's `done` sentinel is the authoritative stop signal;
# the readability check is the fast path.
watch_events() {  # writes last-good memory.events to $EV/events
  local i=0 cg ev
  while [ "$i" -lt 2000000 ]; do
    [ -s "$EV/cgpath" ] && break
    [ -e "$EV/done" ] && return 0   # workload finished before it ever published
    i=$((i + 1))
  done
  cg=$(cat "$EV/cgpath" 2>/dev/null)
  # Empty cg would make the path resolve to the cgroup ROOT, whose memory.events
  # is always readable — an unbounded spin on the wrong cgroup. Refuse.
  [ -n "$cg" ] || return 0
  ev="/sys/fs/cgroup$cg/memory.events"
  while [ -r "$ev" ]; do
    cat "$ev" > "$EV/events.tmp" 2>/dev/null && mv "$EV/events.tmp" "$EV/events"
    # Read once MORE after the sentinel appears, then stop: the kill increments
    # oom_kill just before the workload dies, and `done` is written just after
    # the caller reaps it, so the final read is the one that matters.
    if [ -e "$EV/done" ]; then
      cat "$ev" > "$EV/events.tmp" 2>/dev/null && mv "$EV/events.tmp" "$EV/events"
      break
    fi
  done
}

REW_A=$(get_rewrite "64M")
if [ -z "$REW_A" ]; then
  echo "FAIL [A] hook did not rewrite a bare 'pytest' command (cgroup available?)"; FAIL=$((FAIL+1))
else
  watch_events & WATCHER=$!
  A_EXIT=0
  # The trailing `; exit $?` is load-bearing, not decoration.
  #
  # `systemd-run --scope` moves the CALLING process into the new cgroup before
  # exec'ing, so every process in this chain — env, bash, systemd-run itself —
  # ends up inside the capped scope and is SIGKILLed along with the workload. The
  # probe's own shell then reaps a killed direct child and prints
  # "Killed  <full command line>" to stderr, which reads as a probe failure in
  # otherwise-green output. Redirecting stderr does not suppress it (the message
  # comes from the REAPING shell) and neither does backgrounding + `wait` (both
  # measured 2026-08-12).
  #
  # With a command following it, bash cannot apply its exec-the-last-command
  # optimization: it FORKS systemd-run and stays outside the scope, survives,
  # reaps 137, and exits 137 through the normal path. Same status, no report.
  A_CMD="$REW_A; exit \$?"
  env "PATH=$FAKE_A:$PATH" "DHX_EV=$EV" bash -c "$A_CMD" >/dev/null 2>&1 || A_EXIT=$?
  : > "$EV/done"          # authoritative watcher stop signal — see watch_events
  wait "$WATCHER" 2>/dev/null

  A_CGPATH=$(cat "$EV/cgpath" 2>/dev/null)
  A_MEMMAX=$(cat "$EV/memory.max" 2>/dev/null)
  A_SWAPMAX=$(cat "$EV/memory.swap.max" 2>/dev/null)
  A_OOMKILL=$(awk '$1 == "oom_kill" { print $2 }' "$EV/events" 2>/dev/null)

  # [A1] terminal status — 137 OR 143 (HP-045: the memory-kill status is not
  # categorical on this host). Anything else means the workload was not killed.
  case "$A_EXIT" in
    137|143)
      echo "OK   [A1] 256 MB pytest under 64 MB cap → killed (exit $A_EXIT; HP-045 allows 137|143)"
      PASS=$((PASS+1)) ;;
    *)
      echo "FAIL [A1] expected a kill status (137 or 143), got $A_EXIT"; FAIL=$((FAIL+1))
      echo "     rewrite: $REW_A" ;;
  esac

  # [A2] THE CAP WAS ACTUALLY APPLIED. This is the assertion that detects an
  # un-capping regression; a status check alone cannot.
  if [ "$A_MEMMAX" = "67108864" ] && [ "$A_SWAPMAX" = "0" ]; then
    echo "OK   [A2] workload ran under memory.max=67108864 (=64M) + memory.swap.max=0"
    PASS=$((PASS+1))
  else
    echo "FAIL [A2] cgroup did not carry the requested cap"; FAIL=$((FAIL+1))
    echo "     memory.max='${A_MEMMAX:-<unpublished>}' (want 67108864)"
    echo "     memory.swap.max='${A_SWAPMAX:-<unpublished>}' (want 0)"
  fi

  # [A3] it ran in a TRANSIENT SCOPE, not the caller's own cgroup. An empty
  # CGROUP_PREFIX regression (HP-051) leaves the workload in the probe's cgroup,
  # where memory.max is whatever the session cap happens to be.
  #
  # Re-anchored on the `dhx-cap-` prefix 2026-09-02 (was `run-*.scope`). The factory
  # names every scope it builds, so an anonymous `run-r<hex>.scope` reaching here
  # means the interceptor got a cap from somewhere OTHER than dhx-cgroup-cap.sh.
  case "$A_CGPATH" in
    */dhx-cap-[A-Za-z0-9]*.scope)
      echo "OK   [A3] scope cgroup is a NAMED transient scope: ${A_CGPATH##*/}"; PASS=$((PASS+1)) ;;
    *)
      echo "FAIL [A3] workload did not run in a transient dhx-cap-*.scope"; FAIL=$((FAIL+1))
      echo "     cgroup: '${A_CGPATH:-<unpublished>}'" ;;
  esac

  # [A4] the kill was the MEMORY controller's. Watcher-sourced, so a missed read
  # is possible in principle (6/6 captured when this was written). An UNCAPTURED
  # read is reported, not failed — [A2]+[A3] already prove the cap applied, and a
  # flaky red here would train the suite to be ignored. A CAPTURED zero, however,
  # is a real finding: killed while capped, but not by the memcg.
  if [ -z "$A_OOMKILL" ]; then
    echo "OK   [A4] memory.events oom_kill UNCAPTURED (watcher raced teardown) — not asserted"
    PASS=$((PASS+1))
  elif [ "$A_OOMKILL" -gt 0 ] 2>/dev/null; then
    echo "OK   [A4] memory.events oom_kill=$A_OOMKILL → the memory controller killed it"
    PASS=$((PASS+1))
  else
    echo "FAIL [A4] oom_kill=$A_OOMKILL — the memory controller killed nothing in this cgroup"; FAIL=$((FAIL+1))
    echo "     events: $(tr '\n' ' ' < "$EV/events" 2>/dev/null)"
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
