#!/usr/bin/env bash
# probe-test-gate-host-preconditions.sh
#
# 2-tier host-capability probe for dhx/dhx-test-gate.sh cgroup wrap (REQ TEST-GATE-07).
#
# Tier 1 (read-only): canonical cgroup-delegation check — reads
#   /sys/fs/cgroup/user.slice/user-$UID.slice/user@$UID.service/cgroup.controllers
#   for the literal token `memory` (canonical per systemd/docs/CGROUP_DELEGATION.md).
#   On miss → stderr diagnostic + exit 0 (sibling-skip per D-09).
#
# Tier 2 (gated on Tier 1 pass): dry-run with the same property set the real
#   workload uses at dhx-test-gate.sh:249-259 —
#   systemd-run --user --scope --quiet -p MemoryMax=4G -p MemorySwapMax=0 -p RuntimeMaxSec=60s true
#   On non-zero rc → stderr diagnostic + exit 0 (sibling-skip per D-09).
#
# All-pass → single PASS line on stdout + exit 0.
# Opt-out: DHX_SKIP_TEST_GATE=1 → exit 0 silently (matches gate at
#   dhx-test-gate.sh:81; consistent with the production opt-out cascade
#   so silencing the probe does not require silencing the production gate
#   via a different env — D-09 closes the conflation gemini flagged HIGH).
#
# Exit-code contract (D-09 — sibling-skip convention mirroring
# probe-test-gate-cgroup.sh:209):
#   exit 0 — all preconditions present (Tier 1 + Tier 2 both pass)
#   exit 0 — DHX_SKIP_TEST_GATE=1 env set (opt-out cascade)
#   exit 0 — any precondition missing (stderr carries operator-actionable
#            diagnostic naming the missing capability)
#   exit > 0 — only on internal probe error (e.g., syntax error caught by `set -u`)
#
# Backs:
#   - docs/decisions.md — 2026-05-19 Phase 14 TEST-GATE closure row
#   - reports/2026-05-03-test-gate-collection-cost.md (design memo Q-frame)
#   - .planning/REQUIREMENTS.md TEST-GATE-07
#   - .planning/phases/14-test-gate-cgroup-bounded-redesign-test-gate/14-CONTEXT.md
#     § D-09, D-10, D-11, G-01
#
# Run: bash tests/probes/probe-test-gate-host-preconditions.sh
#
# SAFE_FOR_LIVE: yes  (Tier 1 read-only file read; Tier 2 dry-run `true`
#                      inside a transient scope unit that self-cleans on exit.)
# RUNTIME: ~1-2s

set -u

# Opt-out cascade — matches gate's own opt-out at dhx-test-gate.sh:81.
if [ "${DHX_SKIP_TEST_GATE:-}" = "1" ]; then
  echo "SKIP probe-test-gate-host-preconditions (DHX_SKIP_TEST_GATE=1)"
  exit 0
fi

CONTROLLERS="/sys/fs/cgroup/user.slice/user-${UID}.slice/user@${UID}.service/cgroup.controllers"

# Tier 1 — canonical capability check (cgroup memory controller delegated to user manager).
# Per D-10 + D-11: canonical surface per systemd/docs/CGROUP_DELEGATION.md;
# replaces the prior 2-check `systemd-run + user-manager active-target` shape
# AND the GNU-stat cgroup-v2 mount check (G-01 — cgroup.controllers strictly
# subsumes the mount check; memory in controllers implies cgroup-v2 is mounted).
if [ ! -r "$CONTROLLERS" ] || ! grep -qw memory "$CONTROLLERS" 2>/dev/null; then
  echo "FAIL host-precondition: memory controller not delegated to user manager (path: $CONTROLLERS)" >&2
  echo "     → on such hosts the gate falls through to bare invocation; only the plugin manifest timeout: 300 bounds the runner." >&2
  echo "     → see docs/scripts-reference.md § dhx-test-gate.sh § Known assumptions for the operator decision tree." >&2
  exit 0
fi

# Tier 2 — dry-run with the real-workload property set (D-11).
# Matches the property set dhx-test-gate.sh:249-259 uses for the real workload —
# the full set flushes systemd's property-parsing path (swap-accounting absence
# + RuntimeMaxSec parsing + user-manager scope creation). The `true` command is
# intentionally trivial; we're exercising the systemd-run plumbing, not work.
# `--scope` creates a transient unit that self-cleans on exit; `--quiet`
# suppresses unit-creation chatter.
DRY_RC=0
systemd-run --user --scope --quiet \
  -p MemoryMax=4G -p MemorySwapMax=0 -p RuntimeMaxSec=60s \
  true >/dev/null 2>&1 || DRY_RC=$?

if [ "$DRY_RC" -ne 0 ]; then
  echo "FAIL host-precondition: systemd-run dry-run rc=$DRY_RC (cmd: systemd-run --user --scope --quiet -p MemoryMax=4G -p MemorySwapMax=0 -p RuntimeMaxSec=60s true)" >&2
  echo "     → swap-accounting absent OR RuntimeMaxSec unsupported OR user-manager cgroup-tree not active." >&2
  echo "     → see docs/scripts-reference.md § dhx-test-gate.sh § Known assumptions for the operator decision tree." >&2
  exit 0
fi

echo "PASS probe-test-gate-host-preconditions (cgroup memory controller delegated; systemd-run dry-run OK)"
exit 0
