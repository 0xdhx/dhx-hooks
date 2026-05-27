#!/usr/bin/env bash
#
# synctrace-setup.sh — install + verify a persistent bpftrace trap that names the
# launcher of every `/usr/bin/sync` exec.
#
# WHY THIS EXISTS
#   2026-05-25 WSL/tmux near-lockup. ~22 `sync(1)` calls were wedged in
#   uninterruptible D-state for 9+ days, pinning load average ~20 (load counts
#   D-state) and leaving almost no fsync latency margin — the substrate that let
#   a heavy JSONL search + the statusline ccburn spawns tip into a resource storm.
#   The launcher of each `sync` orphans to init (ppid=1) before the wedged process
#   can be inspected, so only an exec-time tracer can name it.
#
# WHY NOT auditd
#   This WSL2 kernel has CONFIG_AUDIT(SYSCALL)=y, but the daemon fails with EPERM
#   on the audit-control interface even as root ("Error setting audit daemon pid
#   (Operation not permitted)") — systemd (PID 1) owns that path and the kernel
#   won't grant it to a second consumer. bpftrace uses the execve tracepoint
#   instead (BTF present) — no audit subsystem, no permission wall.
#
# PERSISTENCE
#   Installed as a systemd unit. systemd is PID 1 here, so `systemctl enable`
#   survives `wsl --shutdown` and the trap re-arms from boot. The sync calls recur
#   sporadically across days, so a boot-persistent trap catches the next one.
#
# See reports/2026-05-25-ccburn-storm-statusline-spawn-hardening.md.
#
# USAGE
#   sudo bash scripts/synctrace-setup.sh             # install (idempotent) + verify
#   sudo bash scripts/synctrace-setup.sh --verify    # verify only, no changes
#   sudo bash scripts/synctrace-setup.sh --trigger   # install + verify + fire a test sync
#
# Idempotent: safe to re-run. Requires sudo (writes /usr/local/bin + /etc/systemd).

set -uo pipefail

BPFTRACE="$(command -v bpftrace 2>/dev/null || echo /usr/bin/bpftrace)"
PROBE=/usr/local/bin/synctrace.bt
UNIT=/etc/systemd/system/synctrace.service
SERVICE=synctrace.service

MODE=install
case "${1:-}" in
  --verify)  MODE=verify ;;
  --trigger) MODE=trigger ;;
  "")        MODE=install ;;
  *) echo "unknown arg: ${1} (use --verify or --trigger)" >&2; exit 2 ;;
esac

say()  { printf '\n=== %s ===\n' "$*"; }
need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "This needs root. Re-run: sudo bash $0 ${1:-}" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
install_trap() {
  need_root "$MODE"

  say "writing bpftrace probe → $PROBE"
  # Quoted heredoc — nothing expands. Matches the two common absolute paths the
  # shell/libc resolve `sync` to. Captures the launcher (real_parent) and its
  # parent (grandparent) at exec time.
  cat > "$PROBE" <<'BT'
#!/usr/bin/env bpftrace
/*
 * synctrace.bt — name the launcher of every /usr/bin/sync exec.
 * Forensic for the 2026-05-25 D-state sync-wedge incident. execve tracepoint
 * (no audit subsystem). Captures the parent at exec time because the launcher
 * orphans to init before the wedged sync can be inspected.
 */
tracepoint:syscalls:sys_enter_execve,
tracepoint:syscalls:sys_enter_execveat
/ str(args->filename) == "/usr/bin/sync" || str(args->filename) == "/bin/sync" /
{
  printf("%s SYNC-EXEC file=%s pid=%d ppid=%d pcomm=%s gpcomm=%s\n",
         strftime("%Y-%m-%dT%H:%M:%S", nsecs),
         str(args->filename),
         pid,
         curtask->real_parent->pid,
         curtask->real_parent->comm,
         curtask->real_parent->real_parent->comm);
}
BT
  chmod 0644 "$PROBE"

  say "writing systemd unit → $UNIT"
  # Explicit, variable-free ExecStart (the empty-${BPFTRACE} footgun). bpftrace is
  # the executable; the .bt is just an argument, so it needn't be +x.
  cat > "$UNIT" <<UNIT
[Unit]
Description=Trace launcher of /usr/bin/sync (forensic: 2026-05-25 D-state sync wedge)
After=multi-user.target

[Service]
Type=simple
ExecStart=${BPFTRACE} ${PROBE}
Restart=on-failure
RestartSec=5
Nice=10

[Install]
WantedBy=multi-user.target
UNIT

  say "reloading + enabling + (re)starting $SERVICE"
  systemctl daemon-reload
  systemctl enable "$SERVICE"
  systemctl restart "$SERVICE"

  say "disabling broken auditd (EPERM on this WSL2 kernel — stops its boot restart-loop)"
  systemctl disable --now auditd.service 2>/dev/null || echo "(auditd already disabled / not present)"
}

# ---------------------------------------------------------------------------
verify() {
  local ok=1

  say "service state"
  local active enabled
  active="$(systemctl is-active "$SERVICE" 2>&1)"
  enabled="$(systemctl is-enabled "$SERVICE" 2>&1)"
  echo "  is-active:  $active   (want: active)"
  echo "  is-enabled: $enabled   (want: enabled — boot-persistent)"
  [ "$active" = active ]   || { echo "  ✗ service not running"; ok=0; }
  [ "$enabled" = enabled ] || { echo "  ✗ service not boot-enabled"; ok=0; }

  say "bpftrace probe attached?"
  if pgrep -af 'bpftrace.*synctrace' >/dev/null 2>&1; then
    pgrep -af 'bpftrace.*synctrace'
  else
    echo "  ✗ no running bpftrace synctrace process"; ok=0
  fi

  say "auditd parked?"
  echo "  is-enabled: $(systemctl is-enabled auditd.service 2>&1)   (want: disabled/masked)"

  say "ExecStart sanity (must name bpftrace, not a bare .bt path)"
  grep -E '^ExecStart=' "$UNIT" 2>/dev/null || echo "  ✗ unit file missing"
  if grep -qE '^ExecStart=\S*bpftrace\s' "$UNIT" 2>/dev/null; then
    echo "  ✓ ExecStart invokes bpftrace"
  else
    echo "  ✗ ExecStart does not invoke bpftrace (the empty-variable bug)"; ok=0
  fi

  say "captures in service journal so far"
  local n; n="$(journalctl -u "$SERVICE" --no-pager 2>/dev/null | grep -c SYNC-EXEC || true)"
  echo "  SYNC-EXEC lines: ${n:-0}"

  if [ "$ok" -eq 1 ]; then
    echo; echo "RESULT: ✓ trap is installed, running, and boot-persistent."
  else
    echo; echo "RESULT: ✗ something is off — see the ✗ lines above."
    return 1
  fi
}

# ---------------------------------------------------------------------------
trigger_test() {
  need_root "$MODE"
  say "live end-to-end test — firing one background sync"
  echo "  (adds one D-state sync; cleared by the next 'wsl --shutdown')"
  local since; since="$(date '+%Y-%m-%d %H:%M:%S')"
  sync &            # background so a wedged sync doesn't block the script
  sleep 2
  say "did the SERVICE capture it?"
  if journalctl -u "$SERVICE" --since "$since" --no-pager 2>/dev/null | grep SYNC-EXEC; then
    echo "  ✓ captured (line above) — end-to-end path confirmed"
  else
    echo "  ✗ no capture since $since — widen the path filter in $PROBE if 'sync' resolves elsewhere"
    echo "    (resolved sync path on this box: $(readlink -f "$(command -v sync)"))"
    return 1
  fi
}

# ---------------------------------------------------------------------------
case "$MODE" in
  install) install_trap; verify ;;
  verify)  verify ;;
  trigger) install_trap; verify && trigger_test ;;
esac
