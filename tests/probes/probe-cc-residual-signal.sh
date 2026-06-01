#!/bin/bash
# SAFE_FOR_LIVE: yes   (mktemp fixture tree; node -e require with explicit fixture paths; never reads live ~/.claude or ~/.cache/dhx)
#
# probe-cc-residual-signal.sh — RAT-01 residual-signal demonstration probe.
#
# Demonstrates the residual signal D-01's RETAIN verdict for the plugins/cache
# drift scan rests on: a plugin version bumped INSIDE an existing
# plugins/cache/<marketplace>/<plugin>/<version>/ tree — with NO `claude plugin
# install` re-run — pushes the recursive `plugins` drift trigger while leaving
# settings.json byte-identical (so the `settings` trigger, which compares
# settings_hash, does NOT fire). This is the class settings_hash and the
# HP-025 plugin-registry detector are both blind to: the registry JSONs stay
# consistent and settings.json is untouched, yet a real plugin code change
# landed on disk.
#
# This is a DEMONSTRATION probe per D-01 — it shows the residual signal EXISTS.
# It is NOT a subsumption proof (it does not, and cannot, prove the scan is
# the *only* detector of this class — D-01 deliberately scopes RAT-01 to
# evidence-of-signal, not subsumption). It is the empirical artifact the
# docs/decisions.md RETAIN row (authored in Plan 17-05) cites by name, and it
# backs REQ STATUSLINE-RAT-01.
#
# Run: bash tests/probes/probe-cc-residual-signal.sh
#
# Strategy (D-11 + D-20): every scenario stands up an isolated
# `plugins/cache/<mp>/<plugin>/<version>/hook.json` fixture tree PLUS a
# settings.json fixture under `mktemp -d`, and calls the LIVE wrapper module
# via `node -e "require('$WRAPPER')"` — the probe carries NO in-file copy of
# `scanRecursive` or `hashWarnSettings`, so a regression in the wrapper flips
# an assertion red (verification-skew discipline). `scanRecursive` is exported
# by Plan 17-01 Task 2 (D-20); `hashWarnSettings` was already exported.
#
# mtime control (D-21 — HARD REQUIREMENT, not `sleep`, not conditional):
# the new version directory + its file get an EXPLICIT FUTURE mtime via
# `fs.utimesSync` so `current.plugins_mtime > snapshot.plugins_mtime` is
# deterministically true. Coarse filesystem mtime resolution makes a
# wall-clock advance flaky; `utimesSync` with an explicit timestamp is the
# only acceptable approach.
#

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# Every scenario below does `require("$WRAPPER")` of dhx/statusline-wrapper.js
# — the live module, never an in-file copy of scanRecursive / hashWarnSettings.
WRAPPER="$REPO_ROOT/dhx/statusline-wrapper.js"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0

run_case() {
  local name="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    echo "OK   $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL $name (got=$got want=$want)"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== RAT-01 residual-signal demonstration (tmpdir-isolated) ==="

# ----------------------------------------------------------------------------
# Scenario A — the residual signal: a version bump inside an existing tree.
#
# Run the whole 4-step scenario inside ONE node process so the fixture mtimes
# (set with fs.utimesSync) are deterministic and the live wrapper's
# scanRecursive + hashWarnSettings are exercised against explicit fixture
# paths. The node program emits a single result token per check; the bash
# harness compares each to its `want`.
# ----------------------------------------------------------------------------
RESULT=$(node -e "
  const fs = require('fs');
  const path = require('path');
  const m = require('$WRAPPER');

  const root = '$TMPDIR/a';
  const cacheRoot = path.join(root, 'plugins', 'cache');
  const mp = 'dhx-local';
  const plugin = 'dhx';

  // --- Step 1: stand up plugins/cache/<mp>/<plugin>/1.0.0/hook.json + settings.json ---
  const v100 = path.join(cacheRoot, mp, plugin, '1.0.0');
  fs.mkdirSync(v100, { recursive: true });
  const hook100 = path.join(v100, 'hook.json');
  fs.writeFileSync(hook100, JSON.stringify({ version: '1.0.0' }));

  // settings.json fixture — carries the SETTINGS_WARN_KEYS hashWarnSettings
  // projects over (hooks/enabledPlugins/extraKnownMarketplaces/env) so the
  // hash is a meaningful, non-empty value rather than the empty-projection hash.
  const settingsFile = path.join(root, 'settings.json');
  fs.writeFileSync(settingsFile, JSON.stringify({
    hooks: { SessionStart: [{ hooks: [{ command: 'x' }] }] },
    enabledPlugins: { 'dhx@dhx-local': true },
    extraKnownMarketplaces: { 'dhx-local': { source: { path: '/foo' } } },
    env: { DHX_DEBUG: '1' },
    // non-WARN keys — must NOT influence the hash:
    effortLevel: 'high', model: 'opus', theme: 'dark',
  }));

  // Pin the seed tree's mtimes into the past so the post-mutation scan can
  // produce a strictly-greater plugins_mtime. fs.mkdirSync stamps each parent
  // dir to Date.now(); without re-stamping, the recursive scan returns the
  // dir-creation time (~now) and a +10s mutation can't beat it.
  const BASE = Date.now() - 120000; // 2 min ago
  const stamp = (p, ms) => fs.utimesSync(p, ms / 1000, ms / 1000);
  // files first, then dirs deepest-up, then roots — see probe-drift-detection.js restampTree.
  stamp(hook100, BASE);
  stamp(v100, BASE);
  stamp(path.join(cacheRoot, mp, plugin), BASE);
  stamp(path.join(cacheRoot, mp), BASE);
  stamp(cacheRoot, BASE);

  // --- Step 2: snapshot ---
  const snapScan = m.scanRecursive(cacheRoot);
  const snapPluginsMtime = snapScan.maxMtime;
  const snapPluginsCount = snapScan.count;
  const snapSettingsHash = m.hashWarnSettings(settingsFile);

  // --- Step 3: mutate — the residual signal ---
  // Write plugins/cache/<mp>/<plugin>/1.0.1/hook.json: a NEW version directory
  // INSIDE the existing tree (a plugin version bump with no \`claude plugin
  // install\` re-run). settings.json is left BYTE-IDENTICAL — not touched.
  const v101 = path.join(cacheRoot, mp, plugin, '1.0.1');
  fs.mkdirSync(v101, { recursive: true });
  const hook101 = path.join(v101, 'hook.json');
  fs.writeFileSync(hook101, JSON.stringify({ version: '1.0.1' }));
  // D-21: explicit FUTURE mtime via fs.utimesSync — deterministic, never a
  // wall-clock delay. coarse FS mtime resolution makes a delay-then-write flaky.
  const FUTURE = BASE + 130000; // 10s past 'now', well above the seed BASE
  stamp(hook101, FUTURE);
  stamp(v101, FUTURE);

  // --- Step 4: assert ---
  const curScan = m.scanRecursive(cacheRoot);
  const curPluginsMtime = curScan.maxMtime;
  const curPluginsCount = curScan.count;
  // settings.json untouched → re-hash the same fixture file.
  const curSettingsHash = m.hashWarnSettings(settingsFile);

  // The \`plugins\` drift trigger fires when current.plugins_mtime advances OR
  // current.plugins_count grows past the snapshot — checkDrift's plugins branch.
  const pluginsMtimeAdvanced = curPluginsMtime > snapPluginsMtime;
  const pluginsCountGrew = curPluginsCount > snapPluginsCount;
  // The \`settings\` drift trigger fires when settings_hash changes — it must NOT.
  const settingsHashUnchanged = curSettingsHash === snapSettingsHash;
  // Sanity: the hash is the meaningful non-empty projection, not the empty fallback.
  const settingsHashNonEmpty = typeof snapSettingsHash === 'string' && snapSettingsHash.length === 64;

  process.stdout.write([
    pluginsMtimeAdvanced,
    pluginsCountGrew,
    settingsHashUnchanged,
    settingsHashNonEmpty,
  ].join('|'));
" 2>/dev/null || echo "<error>")

A_PLUGINS_MTIME=$(echo "$RESULT" | cut -d'|' -f1)
A_PLUGINS_COUNT=$(echo "$RESULT" | cut -d'|' -f2)
A_SETTINGS_UNCHANGED=$(echo "$RESULT" | cut -d'|' -f3)
A_SETTINGS_NONEMPTY=$(echo "$RESULT" | cut -d'|' -f4)

run_case "[A1] version bump inside existing tree → plugins_mtime advances (plugins trigger fires)" \
  "$A_PLUGINS_MTIME" "true"
run_case "[A2] version bump adds a leaf → plugins_count grows (plugins trigger fires)" \
  "$A_PLUGINS_COUNT" "true"
run_case "[A3] settings.json byte-identical → settings_hash unchanged (settings trigger does NOT fire)" \
  "$A_SETTINGS_UNCHANGED" "true"
run_case "[A4] sanity: settings_hash is the meaningful 64-hex projection, not the empty fallback" \
  "$A_SETTINGS_NONEMPTY" "true"

# ----------------------------------------------------------------------------
# Scenario B — no-op control: a refresh with no mutation.
#
# Proves the `plugins` trigger is mutation-sensitive (not always-on): two
# scans of an UNCHANGED tree return an identical maxMtime, so current is NOT
# strictly greater than snapshot → the trigger does not fire. Without this
# control, scenario A alone cannot distinguish "the mutation caused the
# advance" from "the trigger fires on every refresh".
# ----------------------------------------------------------------------------
RESULT_B=$(node -e "
  const fs = require('fs');
  const path = require('path');
  const m = require('$WRAPPER');

  const root = '$TMPDIR/b';
  const cacheRoot = path.join(root, 'plugins', 'cache');
  const v100 = path.join(cacheRoot, 'dhx-local', 'dhx', '1.0.0');
  fs.mkdirSync(v100, { recursive: true });
  const hook100 = path.join(v100, 'hook.json');
  fs.writeFileSync(hook100, JSON.stringify({ version: '1.0.0' }));

  const BASE = Date.now() - 120000;
  const stamp = (p, ms) => fs.utimesSync(p, ms / 1000, ms / 1000);
  stamp(hook100, BASE);
  stamp(v100, BASE);
  stamp(path.join(cacheRoot, 'dhx-local', 'dhx'), BASE);
  stamp(path.join(cacheRoot, 'dhx-local'), BASE);
  stamp(cacheRoot, BASE);

  // Snapshot, then re-scan WITHOUT touching the tree.
  const snapScan = m.scanRecursive(cacheRoot);
  const curScan = m.scanRecursive(cacheRoot);

  // No-op refresh: maxMtime must be identical → strictly-greater is false →
  // plugins trigger does NOT fire. count likewise stable.
  const pluginsMtimeUnchanged = curScan.maxMtime === snapScan.maxMtime;
  const pluginsTriggerWouldFire =
    (curScan.maxMtime > snapScan.maxMtime) || (curScan.count < snapScan.count);

  process.stdout.write([
    pluginsMtimeUnchanged,
    pluginsTriggerWouldFire,
  ].join('|'));
" 2>/dev/null || echo "<error>")

B_MTIME_UNCHANGED=$(echo "$RESULT_B" | cut -d'|' -f1)
B_TRIGGER_FIRES=$(echo "$RESULT_B" | cut -d'|' -f2)

run_case "[B1] no-op refresh → plugins_mtime unchanged" \
  "$B_MTIME_UNCHANGED" "true"
run_case "[B2] no-op refresh → plugins trigger does NOT fire (trigger is mutation-sensitive, not always-on)" \
  "$B_TRIGGER_FIRES" "false"

echo "---"
echo "$PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
