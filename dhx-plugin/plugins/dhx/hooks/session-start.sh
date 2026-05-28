#!/usr/bin/env bash
# dhx-plugin session-start dispatcher — invoked by plugin hooks.json.
# Logs probe + dispatches to the canonical dhx scripts in ~/.claude/hooks/.
# Receives the same stdin JSON CC hands the hook (session_id, source, etc.).
# Silent on happy path for both children; logs probe on every fire.

set -uo pipefail

INPUT=$(cat)
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
SID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null || echo unknown)
SRC=$(echo "$INPUT" | jq -r '.source // "unknown"' 2>/dev/null || echo unknown)
echo "[$TS] dhx-plugin-dispatch session=$SID source=$SRC" >> /tmp/dhx-plugin-probe.log

# Dispatch to canonical scripts. Hand each its own stdin copy.
# Run each even if one fails — they are independent.
printf '%s' "$INPUT" | bash /home/dhx/.claude/hooks/dhx-health-check.sh || true
printf '%s' "$INPUT" | bash /home/dhx/.claude/hooks/dhx-dirty-tree.sh || true
# Phase 16 (REQ-DRIFT-ACTION-01/02): actionable drift surface; reads ~/.cache/dhx/gsd-drift-first-seen.json
printf '%s' "$INPUT" | bash /home/dhx/.claude/hooks/dhx-gsd-drift-surface.sh || true
# Heal plugin registry drift (HP-025 companion) — runs BEFORE stale-worktree-sweep
# so the heal establishes a valid baseline before downstream checks touch state.
# No stdin needed; heal is filesystem-only (reads cache, writes installed_plugins.json).
bash /home/dhx/.claude/hooks/dhx-plugin-registry-heal.sh < /dev/null || true
# Detect plugin cache hooks.json staleness (HP-025 § Cache-staleness detection;
# HP-020 read-path finding under empirical test). Runs AFTER registry-heal so
# heal-side baseline is established before staleness comparison fires.
# Detector is filesystem-only via `stat -c %Y` (no content parse); < /dev/null
# mirrors heal-hook (no stdin parsing).
bash /home/dhx/.claude/hooks/dhx-plugin-cache-staleness-detector.sh < /dev/null || true
printf '%s' "$INPUT" | bash /home/dhx/.claude/hooks/dhx-stale-worktree-sweep.sh || true
# Watch-health computer (cross-repo D-08/D-10/D-22a): recompute the precomputed
# health verdict cache BEFORE the digest banner reads it, so the banner consumes a
# fresh cache in the same session. The explicit `[ -e … ]` existence test guarantees
# a graceful no-op when the cross-repo installer hasn't provisioned the symlink yet
# (a bare `node <absent-symlink>` would exit non-zero); >/dev/null 2>&1 || true keeps
# it silent + non-blocking regardless. Filesystem/network-only; no stdin needed.
[ -e ~/.claude/dhx-tools/dhx-watch-health.cjs ] && node ~/.claude/dhx-tools/dhx-watch-health.cjs >/dev/null 2>&1 || true
printf '%s' "$INPUT" | bash /home/dhx/.claude/hooks/dhx-watch-digest.sh || true
# RAT-06 (STATUSLINE-RAT-06): CC-version-drift check. Network-only (npm view via
# detached worker); no stdin needed. Mirrors registry-heal / staleness-detector dispatch.
node /home/dhx/.claude/hooks/cc-check-update.js < /dev/null || true
# Phase 14 (DETECT-01): warn when cross-repo PRIMARY is off main.
printf '%s' "$INPUT" | bash /home/dhx/.claude/hooks/dhx-off-main-detector.sh || true

exit 0
