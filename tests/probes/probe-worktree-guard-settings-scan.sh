#!/usr/bin/env bash
# probe-worktree-guard-settings-scan.sh
#
# Static double-fire assertion (Phase 43 D-04c / D-13). The four worktree/agent-leak
# guards register via EXACTLY ONE sanctioned channel — the dhx-plugin manifest
# (dhx-plugin/plugins/dhx/hooks/hooks.json, HP-017). A second registration in any
# settings.json / settings.local.json hooks block would silently DOUBLE-FIRE the
# deny (Repudiation/Tampering). This probe FAILS (exit 1) if ANY of the four guard
# basenames appears in any live settings.json OR settings.local.json under the
# active config trees.
#
# Scope (RESEARCH Pitfall 3, verified): the stale backup carries the WRITE +
# agent-leak guards (NOT the bash guard), so the scan MUST cover all four basenames
# — scoping to the bash guard alone misses the actual double-fire vector. D-13:
# settings.local.json is a live CC hook-registration channel, so it is scanned too;
# scoping to settings.json alone left a hole in the very assertion this phase exists
# to provide.
#
# The exact-name globs (-name 'settings.json' / 'settings.local.json') do NOT match
# the neutralized backup `settings.json.bak.2026-04-19-bash-guard.disabled` (D-04b)
# nor any `.bak`/`.disabled` suffix — only live settings files are scanned.
#
# Backs: docs/decisions.md Phase 43 ownership disposition (global-only, plugin-only).
# Companion: probe-worktree-bash-guard.sh, probe-worktree-write-guard.sh,
#            probe-worktree-guard-adversarial.test.js.
#
# Run: bash tests/probes/probe-worktree-guard-settings-scan.sh

# SAFE_FOR_LIVE: yes   (read-only grep over live settings.json/settings.local.json; no mutation)
set -uo pipefail

GUARDS='dhx-worktree-bash-guard|dhx-worktree-write-guard|dhx-agent-leak-snapshot|dhx-agent-leak-check'

PASS=0
FAIL=0
HITS=0

# Enumerate live settings files across BOTH config trees (D-13: both filenames).
# `$HOME/.ccs` is the CCS shared tree (the real settings.json lives at
# ~/.ccs/shared/settings.json); ${CLAUDE_CONFIG_DIR:-$HOME/.claude} is the active
# config dir. 2>/dev/null tolerates absent trees (e.g. an isolated negative-control HOME).
mapfile -t SETTINGS_FILES < <(find "$HOME/.ccs" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" \
    -maxdepth 2 \( -name 'settings.json' -o -name 'settings.local.json' \) 2>/dev/null | sort -u)

for f in "${SETTINGS_FILES[@]}"; do
  [ -f "$f" ] || continue
  if grep -qE "$GUARDS" "$f" 2>/dev/null; then
    echo "FAIL guard registered in settings file (anti-pattern — must be plugin-only): $f"
    HITS=$((HITS + 1))
  fi
done

if [[ "$HITS" -eq 0 ]]; then
  echo "OK   no worktree/agent-leak guard in any settings.json/settings.local.json hooks block (${#SETTINGS_FILES[@]} file(s) scanned)"
  PASS=$((PASS + 1))
else
  FAIL=$HITS
fi

echo ""
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
