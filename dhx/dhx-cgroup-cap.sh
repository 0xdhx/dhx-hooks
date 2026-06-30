#!/usr/bin/env bash
# dhx-cgroup-cap.sh — shared cgroup memory-cap factory (NOT a hook; sourced).
# Patterns: HP-045
#
# Single source of truth for the `systemd-run --user --scope` memory-cap wrap.
# Sourced by BOTH consumers so the cap construction can never copy-drift:
#   - dhx/dhx-test-gate.sh  (Stop hook — caps its OWN pytest runner)
#   - dhx/dhx-pytest-cgroup-cap.sh (PreToolUse:Bash — caps a subagent's OWN
#     mid-session pytest, the DHX-7 OOM gap the gate's Stop-time wrap can't see)
#
# Runtime behavior this lib relies on is HP-045: on this WSL2 host a
# `systemd-run --user --scope` with `MemoryMax` + `MemorySwapMax=0` OOM-SIGKILLs
# an overrunning child (exit 137), and `RuntimeMaxSec` SIGTERMs at the runtime
# ceiling (exit 143). `MemorySwapMax=0` is load-bearing — `MemoryMax` alone is
# advisory on a swap-enabled host (verified in
# reports/2026-05-03-test-gate-collection-cost.md).
#
# This file is sourced, never executed — no stdin read, no exit. It only DEFINES
# functions. A consumer that sources it and finds the functions absent (truncated
# file, etc.) is expected to fall back to a bare (uncapped) invocation — the cap
# is defense-in-depth, never a hard dependency.

# dhx_cgroup_available — return 0 iff the host can honor the scope cap.
# Matches the precondition dhx-test-gate.sh used inline before this extraction
# (systemd-run on PATH AND an active --user systemd manager). Kept byte-for-byte
# so the gate's host-fallback behavior is unchanged by the refactor. (The two
# host-precondition PROBES read the canonical cgroup.controllers surface instead;
# this is the gate's lighter runtime check, deliberately preserved.)
dhx_cgroup_available() {
  command -v systemd-run >/dev/null 2>&1 && \
    systemctl --user is-active default.target >/dev/null 2>&1
}

# dhx_cgroup_prefix_tokens MEM [TIME] — emit the systemd-run scope prefix as one
# token per line, terminated by `--`. Every token is whitespace-free, so a caller
# may either `mapfile` it into an array (direct argv exec — the gate) OR join it
# with spaces into a command string (the rewrite — the interceptor).
#
#   MEM   memory ceiling, e.g. 4G (passed to MemoryMax). Required.
#   TIME  runtime ceiling in whole seconds (passed to RuntimeMaxSec=${TIME}s).
#         OPTIONAL — omit/empty to apply a MEMORY-ONLY cap (no runtime ceiling).
#         The gate passes its runtime budget; the mid-session interceptor omits
#         it by default (the DHX-7 threat is OOM, not a hang — and CC's own Bash
#         tool timeout already backstops a hung command, so a runtime cap here
#         would only add a false-positive class on legitimately-slow suites).
#
# Token order is identical to the gate's former inline array, so a `mapfile`d
# array with TIME present is byte-for-byte what the gate built pre-refactor.
dhx_cgroup_prefix_tokens() {
  local mem="$1" time="${2:-}"
  printf '%s\n' systemd-run --user --scope --quiet \
    -p "MemoryMax=$mem" \
    -p "MemorySwapMax=0"
  if [ -n "$time" ]; then
    printf '%s\n' -p "RuntimeMaxSec=${time}s"
  fi
  printf '%s\n' --
}
