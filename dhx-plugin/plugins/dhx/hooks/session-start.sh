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
# Run all four even if one fails — each is independent.
printf '%s' "$INPUT" | bash /home/dhx/.claude/hooks/dhx-health-check.sh || true
printf '%s' "$INPUT" | bash /home/dhx/.claude/hooks/dhx-dirty-tree.sh || true
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
printf '%s' "$INPUT" | bash /home/dhx/.claude/hooks/dhx-watch-digest.sh || true

exit 0
