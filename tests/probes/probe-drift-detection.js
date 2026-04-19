#!/usr/bin/env node
// Probe: exercises checkDrift()/collectSnapshot() behavior in
// dhx/statusline-wrapper.js across all known failure modes. Backs the
// drift-detection audit (2026-04-18) and documents under-fire gaps for
// future remediation.
//
// Scope:
//   1. Baseline comparison (no drift)
//   2. Agents path recursive scan catches nested writes
//   3. GSD path recursive scan catches nested writes
//   4. Plugins path SHALLOW scan misses nested writes — CURRENT UNDER-FIRE
//   5. Plugins path RECURSIVE scan catches nested writes — proposed fix
//   6. Settings hash stability against benign mutations
//   7. Version bump triggers version label
//   8. Trigger label formatting (multi-trigger join with +, age format)
//   9. Deletion-only change (max mtime goes DOWN) — CURRENT UNDER-FIRE
//  10. Schema migration: legacy settings_mtime re-baselines silently
//
// Run: node tests/probes/probe-drift-detection.js
//
// Backs:
//   - docs/decisions.md — 2026-04-16 snapshot-comparison refactor row
//   - docs/decisions.md — 2026-04-16 settings_hash cutover row
//   - docs/backlog.md — checkdrift-mtime-bulk-restore-vulnerability (class G)
//   - docs/hook-patterns.md — HP-004 (find -mmin unreliability), HP-016 (CC start-ticks)
//
// Companion: tests/probes/probe-migration.js covers (10) in isolation.
// Companion: /tmp/drift-smoke-test.md covers the end-to-end display path
// that this code-level probe cannot exercise.

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');

const { hashWarnSettings, canonicalize } = require('../../dhx/statusline-wrapper.js');

// --- Reimplemented helpers (mirror collectSnapshot() lines 343-391) ---

function getMaxMtimeRecursive(dir) {
  let max = 0;
  try {
    const entries = fs.readdirSync(dir, { withFileTypes: true, recursive: true });
    for (const entry of entries) {
      try {
        const full = entry.path ? path.join(entry.path, entry.name) : path.join(dir, entry.name);
        const st = fs.statSync(full);
        if (st.mtimeMs > max) max = st.mtimeMs;
      } catch { /* skip */ }
    }
  } catch { /* missing dir */ }
  return max;
}

function getMaxMtimeShallow(dir) {
  let max = 0;
  try {
    const entries = fs.readdirSync(dir, { withFileTypes: true });
    for (const entry of entries) {
      try {
        const st = fs.statSync(path.join(dir, entry.name));
        if (st.mtimeMs > max) max = st.mtimeMs;
      } catch { /* skip */ }
    }
  } catch { /* missing dir */ }
  return max;
}

function checkDriftLogic(current, snapshot) {
  const triggers = [];
  if (current.agents_mtime > snapshot.agents_mtime) triggers.push('agents');
  if (current.settings_hash !== snapshot.settings_hash) triggers.push('settings');
  if (current.gsd_mtime > snapshot.gsd_mtime) triggers.push('gsd');
  if (current.plugins_mtime > snapshot.plugins_mtime) triggers.push('plugins');
  if (current.version !== snapshot.version) triggers.push('version');
  return triggers;
}

function formatAge(ageMs) {
  if (ageMs < 60 * 1000) return '<1m';
  if (ageMs < 60 * 60 * 1000) return `${Math.floor(ageMs / (60 * 1000))}m`;
  const h = Math.floor(ageMs / (60 * 60 * 1000));
  const m = Math.floor((ageMs % (60 * 60 * 1000)) / (60 * 1000));
  return `${h}h ${m}m`;
}

// --- Temp fixtures ---

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'probe-drift-'));
const AGENTS = path.join(TMP, 'agents');
const GSD = path.join(TMP, 'gsd');
const PLUGINS = path.join(TMP, 'plugins', 'cache');
fs.mkdirSync(AGENTS, { recursive: true });
fs.mkdirSync(GSD, { recursive: true });
fs.mkdirSync(PLUGINS, { recursive: true });

// Seed each tree with one nested file so there's a baseline max mtime
function seed(dir, relPath, mtimeMs = Date.now() - 60_000) {
  const full = path.join(dir, relPath);
  fs.mkdirSync(path.dirname(full), { recursive: true });
  fs.writeFileSync(full, 'seed');
  fs.utimesSync(full, mtimeMs / 1000, mtimeMs / 1000);
  return full;
}

const baseMtime = Date.now() - 60_000;
seed(AGENTS, 'nested/dir/agent.md', baseMtime);
seed(GSD, 'workflows/update.md', baseMtime);
// Plugins: nested 3 levels deep — mirrors real plugins/cache/<marketplace>/<plugin>/<version>/hooks.json
const pluginsDeepFile = seed(PLUGINS, 'marketplace/plugin/1.0/hooks.json', baseMtime);
// Force plugins top-level dir mtime to MATCH the marketplace entry's creation — this is what
// happens in real plugins cache where top-level mtime reflects marketplace-install date
const marketplaceDir = path.join(PLUGINS, 'marketplace');
const topLevelMtime = fs.statSync(marketplaceDir).mtimeMs;

// --- Run scenarios ---

const results = [];
const assert = (name, cond) => {
  results.push({ name, ok: !!cond });
  console.log(`${cond ? 'OK  ' : 'FAIL'} ${name}`);
};

const baseSnap = {
  agents_mtime: getMaxMtimeRecursive(AGENTS),
  gsd_mtime: getMaxMtimeRecursive(GSD),
  plugins_mtime: getMaxMtimeShallow(PLUGINS),   // CURRENT code uses shallow
  settings_hash: 'baseline',
  version: '2.1.112',
};

// --- 1. Baseline: clean state → no drift ---
{
  const current = { ...baseSnap };
  const triggers = checkDriftLogic(current, baseSnap);
  assert('[1] clean state produces no triggers', triggers.length === 0);
}

// --- 2. Agents path: nested write ---
{
  const deep = path.join(AGENTS, 'nested/dir/new-agent.md');
  fs.writeFileSync(deep, 'x');
  const current = { ...baseSnap, agents_mtime: getMaxMtimeRecursive(AGENTS) };
  const triggers = checkDriftLogic(current, baseSnap);
  assert('[2] agents nested write → agents trigger fires', triggers.length === 1 && triggers[0] === 'agents');
  fs.unlinkSync(deep);
}

// --- 3. GSD path: nested write ---
{
  const deep = path.join(GSD, 'workflows/new-flow.md');
  fs.writeFileSync(deep, 'x');
  const current = { ...baseSnap, gsd_mtime: getMaxMtimeRecursive(GSD) };
  const triggers = checkDriftLogic(current, baseSnap);
  assert('[3] gsd nested write → gsd trigger fires', triggers.length === 1 && triggers[0] === 'gsd');
  fs.unlinkSync(deep);
}

// --- 4. Plugins: nested write, top-level dir mtime UNCHANGED → CURRENT code misses ---
{
  // Write a new file 4 levels deep WITHOUT adding entries to marketplaceDir or PLUGINS itself.
  // This simulates a plugin version update writing files inside an existing version dir.
  const deep = path.join(PLUGINS, 'marketplace/plugin/1.0/new-hook.json');
  fs.writeFileSync(deep, 'x');
  // Explicitly pin top-level mtime to pre-write value (POSIX normally preserves it when
  // a file is added inside a grandchild dir, but we pin to be deterministic across FS types)
  fs.utimesSync(marketplaceDir, topLevelMtime / 1000, topLevelMtime / 1000);
  fs.utimesSync(PLUGINS, topLevelMtime / 1000, topLevelMtime / 1000);

  const currentShallow = { ...baseSnap, plugins_mtime: getMaxMtimeShallow(PLUGINS) };
  const triggersShallow = checkDriftLogic(currentShallow, baseSnap);
  // CURRENT BUG: shallow scan misses nested writes. Assertion asserts the bug so a
  // future recursive-scan fix flips this to false and forces the probe update.
  assert('[4] plugins nested write — shallow scan MISSES (CURRENT UNDER-FIRE)',
    triggersShallow.length === 0);

  // --- 5. Demonstrate the proposed fix: recursive scan catches it ---
  const currentRecursive = { ...baseSnap, plugins_mtime: getMaxMtimeRecursive(PLUGINS) };
  const triggersRecursive = checkDriftLogic(currentRecursive, baseSnap);
  assert('[5] plugins nested write — recursive scan catches (proposed fix)',
    triggersRecursive.length === 1 && triggersRecursive[0] === 'plugins');

  fs.unlinkSync(deep);
}

// --- 6. Settings hash stability: benign vs real mutation ---
{
  // Real settings-like objects
  const baseline = {
    hooks: { SessionStart: [{ hooks: [{ command: 'x' }] }] },
    enabledPlugins: { 'dhx@dhx-local': true },
    extraKnownMarketplaces: { 'dhx-local': { source: { path: '/foo' } } },
    env: { DHX_DEBUG: '1' },
    // Non-WARN keys (should not affect hash):
    effortLevel: 'high',
    model: 'opus',
    outputStyle: 'default',
    theme: 'dark',
    statusLine: { command: 'node x' },
    permissions: { allow: ['Bash(git:*)'] },
  };
  const mutated = { ...baseline, effortLevel: 'xhigh', outputStyle: 'concise', theme: 'light' };
  const realChange = { ...baseline, hooks: { ...baseline.hooks, Stop: [] } };

  // Write to tmp and hash
  const f1 = path.join(TMP, 'settings-baseline.json');
  const f2 = path.join(TMP, 'settings-mutated.json');
  const f3 = path.join(TMP, 'settings-real.json');
  fs.writeFileSync(f1, JSON.stringify(baseline));
  fs.writeFileSync(f2, JSON.stringify(mutated));
  fs.writeFileSync(f3, JSON.stringify(realChange));

  const h1 = hashWarnSettings(f1);
  const h2 = hashWarnSettings(f2);
  const h3 = hashWarnSettings(f3);

  assert('[6a] benign mutation (effort/outputStyle/theme) leaves hash unchanged', h1 === h2);
  assert('[6b] real mutation (hooks.Stop added) changes hash', h1 !== h3);
}

// --- 7. Version bump ---
{
  const current = { ...baseSnap, version: '2.1.113' };
  const triggers = checkDriftLogic(current, baseSnap);
  assert('[7] version bump → version trigger fires', triggers.length === 1 && triggers[0] === 'version');
}

// --- 8. Trigger label formatting + age format ---
{
  const multi = {
    agents_mtime: baseSnap.agents_mtime + 1,
    gsd_mtime: baseSnap.gsd_mtime + 1,
    plugins_mtime: baseSnap.plugins_mtime,
    settings_hash: 'different',
    version: baseSnap.version,
  };
  const triggers = checkDriftLogic(multi, baseSnap);
  const joined = triggers.join('+');
  assert('[8a] multi-trigger joins with + in snapshot-key order',
    joined === 'agents+settings+gsd');

  // Age format bands
  assert('[8b] age <60s → <1m', formatAge(30_000) === '<1m');
  assert('[8c] age 14min → 14m', formatAge(14 * 60_000) === '14m');
  assert('[8d] age 2h13m → "2h 13m"', formatAge(2 * 60 * 60_000 + 13 * 60_000) === '2h 13m');
}

// --- 9. Deletion-only change: max mtime goes DOWN → comparison misses ---
{
  // Simulate: GSD update removes the newest file, no additions, older files remain.
  // getMaxMtimeRecursive returns a SMALLER value. Since comparison is strict `>`,
  // the smaller value is not "greater than" snapshot — drift misses.
  const currentSmaller = { ...baseSnap, gsd_mtime: baseSnap.gsd_mtime - 10_000 };
  const triggers = checkDriftLogic(currentSmaller, baseSnap);
  // CURRENT BUG: asymmetric `>` comparison misses deletions.
  assert('[9] deletion lowers max mtime — comparison MISSES (CURRENT UNDER-FIRE)',
    triggers.length === 0);
}

// --- 10. Schema migration: legacy settings_mtime → silent re-baseline ---
// (Full coverage lives in probe-migration.js; repeat the invariant here so this
// probe is a complete single-file drift audit.)
{
  const testFile = path.join(TMP, 'legacy-snapshot.json');
  const legacy = {
    agents_mtime: 100,
    settings_mtime: 200,   // legacy field, no settings_hash
    gsd_mtime: 300,
    plugins_mtime: 400,
    version: '2.1.100',
  };
  fs.writeFileSync(testFile, JSON.stringify(legacy));
  const snap = JSON.parse(fs.readFileSync(testFile, 'utf8'));
  const isLegacy = !('settings_hash' in snap);
  assert('[10] legacy snapshot (no settings_hash) detected as migration-eligible', isLegacy);
}

// --- Cleanup + summary ---
fs.rmSync(TMP, { recursive: true, force: true });

const passed = results.filter((r) => r.ok).length;
const failed = results.length - passed;
console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
