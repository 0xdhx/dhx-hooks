#!/bin/bash
# Probe: the hardcoded gsd-runtime path constants track the live gsd install
# dir name. Two surfaces hardcode it:
#   - dhx/statusline-wrapper.js  GSD_LIVE_ROOT / GSD_FORK_ROOT (drift detection)
#   - dhx/dhx-health-check.sh    symlink-checklist `for item in ...` loop
#
# Failure mode this guards (observed 2026-06-05): `@opengsd/gsd-core@1.3.1`
# renamed `~/.claude/get-shit-done/` -> `~/.claude/gsd-core/` and migrated the
# fork mirror to `gsd-local-patches/gsd-core/`. The stale `get-shit-done`
# literals were SILENT — health-check counted a permanently-missing dir (false
# `patches:DRIFT 1 broken symlink`), and scanRecursive(missing dir) returned
# gsd_mtime/count=0 so the statusline gsd drift trigger never fired (dead, no
# error). A future rename does the same. This is NOT hermetically guardable from
# the consumer side — the existing probe-gsd-fork-aware-drift.sh exercises the
# mechanism with OVERRIDE roots, so it can't catch a stale DEFAULT.
#
# Static checks (always run): the source literals name `gsd-core`, not the
# retired `get-shit-done`. Live-resolve checks (only when gsd is installed):
# the named live root + fork mirror actually exist — catches the NEXT rename
# (source still names the old dir, live dir moved -> red).
#
# Backs decisions.md 2026-06-05 "gsd-core 1.3.1 rename — hooks follow-ups" row.
# Run: bash tests/probes/probe-gsd-roots-resolve.sh
# SAFE_FOR_LIVE: yes   (grep-only against in-repo source + read-only dir-exists checks on live ~/.claude; no writes)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WRAPPER="$REPO_ROOT/dhx/statusline-wrapper.js"
HEALTH="$REPO_ROOT/dhx/dhx-health-check.sh"

pass=0
fail=0
assert() {
  local name="$1" cond="$2"
  if eval "$cond"; then echo "OK   $name"; pass=$((pass+1));
  else echo "FAIL $name"; fail=$((fail+1)); fi
}

# --- Static: source literals name the live gsd dir, not the retired name ---
LIVE_LINE="$(grep -nE 'const GSD_LIVE_ROOT' "$WRAPPER" || true)"
FORK_LINE="$(grep -nE 'const GSD_FORK_ROOT' "$WRAPPER" || true)"
HEALTH_LOOP="$(grep -nE '^for item in .* hooks ' "$HEALTH" || true)"

assert "statusline GSD_LIVE_ROOT names 'gsd-core'"            "echo \"\$LIVE_LINE\" | grep -q \"'gsd-core'\""
assert "statusline GSD_LIVE_ROOT drops retired 'get-shit-done'" "! echo \"\$LIVE_LINE\" | grep -q 'get-shit-done'"
assert "statusline GSD_FORK_ROOT names 'gsd-local-patches','gsd-core'" "echo \"\$FORK_LINE\" | grep -q \"'gsd-local-patches', 'gsd-core'\""
assert "statusline GSD_FORK_ROOT drops retired 'get-shit-done'" "! echo \"\$FORK_LINE\" | grep -q 'get-shit-done'"
assert "health-check checklist names 'gsd-core'"              "echo \"\$HEALTH_LOOP\" | grep -q 'gsd-core'"
assert "health-check checklist drops retired 'get-shit-done'" "! echo \"\$HEALTH_LOOP\" | grep -q 'get-shit-done'"

# --- Live-resolve: only when gsd is installed (manifest is a stable marker) ---
LIVE_ROOT="$HOME/.claude/gsd-core"
FORK_PARENT="$HOME/.claude/gsd-local-patches"
FORK_ROOT="$FORK_PARENT/gsd-core"

if [[ -e "$HOME/.claude/gsd-file-manifest.json" ]]; then
  assert "live gsd runtime dir resolves ($LIVE_ROOT)" "[[ -d \"$LIVE_ROOT\" ]]"
  # Fork mirror is optional infrastructure; only assert if the fork tree exists.
  if [[ -d "$FORK_PARENT" ]]; then
    assert "live fork mirror resolves ($FORK_ROOT)" "[[ -d \"$FORK_ROOT\" ]]"
  else
    echo "SKIP live fork-mirror check — gsd-local-patches/ absent (no fork system)"
  fi
else
  echo "SKIP live-resolve checks — gsd not installed (no ~/.claude/gsd-file-manifest.json)"
fi

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
