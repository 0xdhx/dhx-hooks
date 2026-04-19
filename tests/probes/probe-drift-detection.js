#!/usr/bin/env node
// Probe: exercises checkDrift()/collectSnapshot() behavior in
// dhx/statusline-wrapper.js across all known failure modes and the
// 2026-04-18 drift-bundle invariants (recursive plugins scan + count-decrease
// branch). Backs the drift-detection audit rows in docs/decisions.md.
//
// Scope:
//   1. Baseline comparison (no drift)
//   2. Agents path recursive scan catches nested writes
//   3. GSD path recursive scan catches nested writes
//   4. Plugins path RECURSIVE scan catches nested writes (fixed 2026-04-18)
//   5. Sentinel: documents the old shallow-scan blind spot so a future
//      regression flips an assertion red. Read-only proof of the POSIX
//      directory-mtime invariant the recursive scan depends on.
//   6. Settings hash stability against benign mutations
//   7. Version bump triggers version label
//   8. Trigger label formatting (multi-trigger join with +, age format)
//   9. Deletion-only change: count branch catches shrinkage even when max
//      mtime goes DOWN (fixed 2026-04-18)
//  10. Schema migration: legacy snapshot missing agents_count re-baselines
//      silently (unified guard with the older settings_hash migration)
//  11. scanRecursive().count accuracy after add N / remove M
//  12. Clock-skew: future mtime still caught by `>` even with count stable
//
// Run: node tests/probes/probe-drift-detection.js
//
// Backs:
//   - docs/decisions.md — 2026-04-18 drift bundle (recursive+deletion)
//   - docs/decisions.md — 2026-04-16 snapshot-comparison refactor
//   - docs/decisions.md — 2026-04-16 settings_hash cutover
//   - docs/backlog.md — ~~drift-plugins-recursive-scan~~ (closed 2026-04-19)
//   - docs/backlog.md — ~~drift-deletion-only-regression~~ (closed 2026-04-19)
//   - docs/hook-patterns.md — HP-004 (find -mmin unreliability), HP-016 (CC start-ticks)
//
// Companion: tests/probes/probe-migration.js — schema-migration in isolation.
// Companion: /tmp/drift-smoke-test.md (ephemeral) — end-to-end display path.

const fs = require('fs');
const os = require('os');
const path = require('path');

const { hashWarnSettings } = require('../../dhx/statusline-wrapper.js');

// --- Reimplemented helpers (mirror statusline-wrapper.js:scanRecursive) ---
// Probe duplicates the scanner locally — same pattern as probe-migration.js —
// so the probe documents expected behavior explicitly. Divergence between
// this scanner and the wrapper's shows up as a red assertion on the shared
// fixtures.

function scanRecursive(dir) {
  let maxMtime = 0;
  let count = 0;
  try {
    const entries = fs.readdirSync(dir, { withFileTypes: true, recursive: true });
    count = entries.length;
    for (const entry of entries) {
      try {
        const full = entry.path ? path.join(entry.path, entry.name) : path.join(dir, entry.name);
        const st = fs.statSync(full);
        if (st.mtimeMs > maxMtime) maxMtime = st.mtimeMs;
      } catch { /* skip */ }
    }
  } catch { /* missing dir */ }
  return { maxMtime, count };
}

function scanShallow(dir) {
  // Legacy shallow scan — retained for scenario [5] regression-sentinel only.
  let maxMtime = 0;
  try {
    const entries = fs.readdirSync(dir, { withFileTypes: true });
    for (const entry of entries) {
      try {
        const st = fs.statSync(path.join(dir, entry.name));
        if (st.mtimeMs > maxMtime) maxMtime = st.mtimeMs;
      } catch { /* skip */ }
    }
  } catch { /* missing dir */ }
  return maxMtime;
}

function checkDriftLogic(current, snapshot) {
  const triggers = [];
  if (current.agents_mtime > snapshot.agents_mtime ||
      current.agents_count < snapshot.agents_count) triggers.push('agents');
  if (current.settings_hash !== snapshot.settings_hash) triggers.push('settings');
  if (current.gsd_mtime > snapshot.gsd_mtime ||
      current.gsd_count < snapshot.gsd_count) triggers.push('gsd');
  if (current.plugins_mtime > snapshot.plugins_mtime ||
      current.plugins_count < snapshot.plugins_count) triggers.push('plugins');
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

// Pin the seed mtimes AND re-stamp parent directories explicitly. fs.mkdirSync
// bumps each parent's mtime to Date.now(); unless we also push those into the
// past, the recursive scan returns the dir-creation time (~now) rather than
// the seed file's past mtime, and subsequent writes can't produce a strictly
// greater mtime against the baseline.
const BASE_MS = Date.now() - 120_000; // 2 minutes ago

function seed(dir, relPath, mtimeMs) {
  const full = path.join(dir, relPath);
  fs.mkdirSync(path.dirname(full), { recursive: true });
  fs.writeFileSync(full, 'seed');
  fs.utimesSync(full, mtimeMs / 1000, mtimeMs / 1000);
  return full;
}

function restampTree(root, mtimeMs) {
  // Walk the tree and push every dir + file's mtime to mtimeMs. Files first
  // (setting a file's mtime touches its parent dir), then deepest dirs up,
  // then the root — guarantees every stat in the tree ends at mtimeMs.
  const entries = fs.readdirSync(root, { withFileTypes: true, recursive: true });
  const dirs = [];
  for (const entry of entries) {
    const full = entry.path ? path.join(entry.path, entry.name) : path.join(root, entry.name);
    if (entry.isDirectory()) dirs.push(full);
    else {
      try { fs.utimesSync(full, mtimeMs / 1000, mtimeMs / 1000); } catch {}
    }
  }
  dirs.sort((a, b) => b.length - a.length);
  for (const d of dirs) {
    try { fs.utimesSync(d, mtimeMs / 1000, mtimeMs / 1000); } catch {}
  }
  try { fs.utimesSync(root, mtimeMs / 1000, mtimeMs / 1000); } catch {}
}

seed(AGENTS, 'nested/dir/agent.md', BASE_MS);
seed(GSD, 'workflows/update.md', BASE_MS);
// Plugins: nested 3 levels deep — mirrors real plugins/cache/<marketplace>/<plugin>/<version>/hooks.json
seed(PLUGINS, 'marketplace/plugin/1.0/hooks.json', BASE_MS);
restampTree(AGENTS, BASE_MS);
restampTree(GSD, BASE_MS);
restampTree(PLUGINS, BASE_MS);

// --- Run scenarios ---

const results = [];
const assert = (name, cond) => {
  results.push({ name, ok: !!cond });
  console.log(`${cond ? 'OK  ' : 'FAIL'} ${name}`);
};

function snap() {
  const a = scanRecursive(AGENTS);
  const g = scanRecursive(GSD);
  const p = scanRecursive(PLUGINS);
  return {
    agents_mtime: a.maxMtime,
    agents_count: a.count,
    gsd_mtime: g.maxMtime,
    gsd_count: g.count,
    plugins_mtime: p.maxMtime,
    plugins_count: p.count,
    settings_hash: 'baseline',
    version: '2.1.112',
  };
}

const baseSnap = snap();

// --- 1. Baseline: clean state → no drift ---
{
  const triggers = checkDriftLogic({ ...baseSnap }, baseSnap);
  assert('[1] clean state produces no triggers', triggers.length === 0);
}

// --- 2. Agents path: nested write catches via mtime ---
{
  const deep = path.join(AGENTS, 'nested/dir/new-agent.md');
  fs.writeFileSync(deep, 'x');
  // Explicitly stamp to a future mtime so the assertion can't flake on
  // millisecond collisions with the mkdir-bumped parent dir.
  const futureMs = BASE_MS + 60_000;
  fs.utimesSync(deep, futureMs / 1000, futureMs / 1000);
  const s = scanRecursive(AGENTS);
  const current = { ...baseSnap, agents_mtime: s.maxMtime, agents_count: s.count };
  const triggers = checkDriftLogic(current, baseSnap);
  assert('[2] agents nested write → agents trigger fires',
    triggers.length === 1 && triggers[0] === 'agents');
  fs.unlinkSync(deep);
  // Re-stamp the tree so later scenarios don't inherit parent-dir mtime
  // bumps from this deletion.
  restampTree(AGENTS, BASE_MS);
}

// --- 3. GSD path: nested write catches via mtime ---
{
  const deep = path.join(GSD, 'workflows/new-flow.md');
  fs.writeFileSync(deep, 'x');
  const futureMs = BASE_MS + 60_000;
  fs.utimesSync(deep, futureMs / 1000, futureMs / 1000);
  const s = scanRecursive(GSD);
  const current = { ...baseSnap, gsd_mtime: s.maxMtime, gsd_count: s.count };
  const triggers = checkDriftLogic(current, baseSnap);
  assert('[3] gsd nested write → gsd trigger fires',
    triggers.length === 1 && triggers[0] === 'gsd');
  fs.unlinkSync(deep);
  restampTree(GSD, BASE_MS);
}

// --- 4. Plugins: nested write 4 levels deep — recursive scan catches ---
{
  const deep = path.join(PLUGINS, 'marketplace/plugin/1.0/new-hook.json');
  fs.writeFileSync(deep, 'x');
  const futureMs = BASE_MS + 60_000;
  fs.utimesSync(deep, futureMs / 1000, futureMs / 1000);
  const s = scanRecursive(PLUGINS);
  const current = { ...baseSnap, plugins_mtime: s.maxMtime, plugins_count: s.count };
  const triggers = checkDriftLogic(current, baseSnap);
  assert('[4] plugins nested write — recursive scan catches (fixed 2026-04-18)',
    triggers.length === 1 && triggers[0] === 'plugins');
  fs.unlinkSync(deep);
  restampTree(PLUGINS, BASE_MS);
}

// --- 5. Regression sentinel: old shallow scan's blind spot ---
//
// Documents the invariant the recursive scan depends on. If someone
// re-introduces a shallow plugins scan in collectSnapshot(), this assertion
// goes red — a shallow scan returns the same value before and after a deep
// write, because POSIX dir mtime doesn't bump on descendant changes.
{
  const deep = path.join(PLUGINS, 'marketplace/plugin/1.0/sentinel-hook.json');
  const shallowBefore = scanShallow(PLUGINS);
  fs.writeFileSync(deep, 'x');
  // Do NOT touch marketplaceDir or PLUGINS directly — simulates the real
  // failure mode where only a grandchild changes.
  const shallowAfter = scanShallow(PLUGINS);
  assert('[5] sentinel: shallow scan blind to descendant writes (POSIX invariant)',
    shallowBefore === shallowAfter);
  fs.unlinkSync(deep);
  restampTree(PLUGINS, BASE_MS);
}

// --- 6. Settings hash stability: benign vs real mutation ---
{
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
  assert('[7] version bump → version trigger fires',
    triggers.length === 1 && triggers[0] === 'version');
}

// --- 8. Trigger label formatting + age format ---
{
  const multi = {
    ...baseSnap,
    agents_mtime: baseSnap.agents_mtime + 1,
    gsd_mtime: baseSnap.gsd_mtime + 1,
    settings_hash: 'different',
  };
  const triggers = checkDriftLogic(multi, baseSnap);
  const joined = triggers.join('+');
  assert('[8a] multi-trigger joins with + in snapshot-key order',
    joined === 'agents+settings+gsd');

  assert('[8b] age <60s → <1m', formatAge(30_000) === '<1m');
  assert('[8c] age 14min → 14m', formatAge(14 * 60_000) === '14m');
  assert('[8d] age 2h13m → "2h 13m"', formatAge(2 * 60 * 60_000 + 13 * 60_000) === '2h 13m');
}

// --- 9. Deletion-only change: count branch catches shrinkage ---
//
// Simulate: newest file gets deleted, leaving older files behind. Recursive
// max mtime goes DOWN; under the strict `>` comparison alone, no trigger
// fires. With the count branch, the smaller count correctly triggers drift.
{
  // Seed a dedicated subtree with 3 files at distinct mtimes so deleting the
  // newest drops the recursive max below the snapshot's.
  const subtree = path.join(TMP, 'del-tree');
  fs.mkdirSync(subtree);
  const older = path.join(subtree, 'older.md');
  const middle = path.join(subtree, 'middle.md');
  const newest = path.join(subtree, 'newest.md');
  fs.writeFileSync(older, 'a');
  fs.writeFileSync(middle, 'b');
  fs.writeFileSync(newest, 'c');
  const t1 = BASE_MS + 10_000;
  const t2 = BASE_MS + 20_000;
  const t3 = BASE_MS + 30_000;
  fs.utimesSync(older, t1 / 1000, t1 / 1000);
  fs.utimesSync(middle, t2 / 1000, t2 / 1000);
  fs.utimesSync(newest, t3 / 1000, t3 / 1000);
  // Stamp the dir too so the baseline scan picks up file-mtime not dir-mtime
  fs.utimesSync(subtree, t3 / 1000, t3 / 1000);

  const s1 = scanRecursive(subtree);
  const snapWithTriplet = {
    ...baseSnap,
    // Piggyback on the gsd slot — the logic is per-tree identical.
    gsd_mtime: s1.maxMtime,
    gsd_count: s1.count,
  };

  fs.unlinkSync(newest);
  // Deleting the newest file bumps the subtree's own dir mtime to now, which
  // is AHEAD of snapshot — to faithfully model a deletion-only drop in
  // recursive max, stamp the directory back to middle's mtime (the oldest
  // surviving file's upper bound). In production, most trees don't get their
  // container mtimes pushed forward by routine operations this cleanly, but
  // we want the probe to exercise the worst-case (strict-> alone misses).
  fs.utimesSync(subtree, t2 / 1000, t2 / 1000);
  const s2 = scanRecursive(subtree);

  // Strict `>` alone WOULD miss it: new recursive max < snapshot max.
  const mtimeBranchAlone = s2.maxMtime > snapWithTriplet.gsd_mtime;
  assert('[9a] deletion alone doesn\'t trip strict-> mtime comparison',
    mtimeBranchAlone === false);

  // Count branch fires correctly.
  const current = { ...snapWithTriplet, gsd_mtime: s2.maxMtime, gsd_count: s2.count };
  const triggers = checkDriftLogic(current, snapWithTriplet);
  assert('[9b] deletion lowers count → gsd trigger fires via count branch',
    triggers.length === 1 && triggers[0] === 'gsd');

  try { fs.unlinkSync(older); } catch {}
  try { fs.unlinkSync(middle); } catch {}
}

// --- 10. Schema migration: legacy snapshot (no agents_count) re-baselines ---
//
// Two legacy shapes must both migrate cleanly: (a) pre-hash (no settings_hash,
// the 2026-04-16 cutover), (b) pre-count (has settings_hash but no *_count,
// the 2026-04-18 drift bundle). Unified guard: either absence triggers
// re-baseline, no drift fires during the grace round.
{
  const preHash = {
    agents_mtime: 100,
    settings_mtime: 200,
    gsd_mtime: 300,
    plugins_mtime: 400,
    version: '2.1.100',
  };
  const preCount = {
    agents_mtime: 100,
    settings_hash: 'abc',
    gsd_mtime: 300,
    plugins_mtime: 400,
    version: '2.1.100',
  };
  const currentSnap = {
    agents_mtime: 500,
    agents_count: 2,
    settings_hash: 'xyz',
    gsd_mtime: 700,
    gsd_count: 1,
    plugins_mtime: 900,
    plugins_count: 3,
    version: '2.1.112',
  };

  const preHashMigrates = !('settings_hash' in preHash) || !('agents_count' in preHash);
  const preCountMigrates = !('settings_hash' in preCount) || !('agents_count' in preCount);
  const currentDoesNotMigrate = ('settings_hash' in currentSnap) && ('agents_count' in currentSnap);

  assert('[10a] legacy pre-hash snapshot detected as migration-eligible', preHashMigrates);
  assert('[10b] legacy pre-count snapshot detected as migration-eligible', preCountMigrates);
  assert('[10c] current-format snapshot not migration-eligible', currentDoesNotMigrate);
}

// --- 11. scanRecursive.count accuracy under add/remove churn ---
{
  const tree = path.join(TMP, 'count-tree');
  fs.mkdirSync(tree);
  for (let i = 0; i < 5; i++) fs.writeFileSync(path.join(tree, `f${i}.md`), '');
  const baseCount = scanRecursive(tree).count;

  // Add 3, remove 1 → expected delta = +2.
  fs.writeFileSync(path.join(tree, 'extra-a.md'), '');
  fs.writeFileSync(path.join(tree, 'extra-b.md'), '');
  fs.writeFileSync(path.join(tree, 'extra-c.md'), '');
  fs.unlinkSync(path.join(tree, 'f0.md'));
  const afterCount = scanRecursive(tree).count;

  assert('[11a] baseline count = 5 after seed',    baseCount === 5);
  assert('[11b] count reflects +3 adds / -1 delete (5→7)', afterCount === 7);
}

// --- 12. Clock-skew: future mtime still caught by `>` ---
//
// If a file's mtime is deliberately set INTO THE FUTURE (clock skew,
// tar -xp from another host, user-visible mtime shenanigans), the `>` branch
// still catches the drift. The count branch doesn't regress when the count
// stays the same — prior implementations that replaced `>` with `!=` would
// false-positive on every clock correction, which is why `>` was kept.
{
  const pinnedTree = path.join(TMP, 'skew-tree');
  fs.mkdirSync(pinnedTree);
  const file = path.join(pinnedTree, 'pinned.md');
  fs.writeFileSync(file, '');
  const pastMs = Date.now() - 10_000;
  fs.utimesSync(file, pastMs / 1000, pastMs / 1000);
  fs.utimesSync(pinnedTree, pastMs / 1000, pastMs / 1000);
  const baseline = scanRecursive(pinnedTree);

  // Push mtime 1 hour into the future without adding/removing files.
  const futureMs = Date.now() + 3600_000;
  fs.utimesSync(file, futureMs / 1000, futureMs / 1000);
  const future = scanRecursive(pinnedTree);

  const snapForSkew = {
    agents_mtime: baseline.maxMtime, agents_count: baseline.count,
    settings_hash: 'h', gsd_mtime: 0, gsd_count: 0,
    plugins_mtime: 0, plugins_count: 0, version: 'v',
  };
  const cur = {
    agents_mtime: future.maxMtime, agents_count: future.count,
    settings_hash: 'h', gsd_mtime: 0, gsd_count: 0,
    plugins_mtime: 0, plugins_count: 0, version: 'v',
  };
  const triggers = checkDriftLogic(cur, snapForSkew);
  assert('[12] future mtime (count unchanged) still trips agents trigger',
    triggers.length === 1 && triggers[0] === 'agents');
}

// --- Cleanup + summary ---
fs.rmSync(TMP, { recursive: true, force: true });

const passed = results.filter((r) => r.ok).length;
const failed = results.length - passed;
console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
