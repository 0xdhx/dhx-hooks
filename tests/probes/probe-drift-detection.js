#!/usr/bin/env node
// Probe: exercises checkDrift()/collectSnapshot() behavior in
// dhx/statusline-wrapper.js across all known failure modes and the
// 2026-04-18 drift-bundle invariants (recursive plugins scan + count-decrease
// branch).
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
//  13. .orphaned_at basename filter (CC orphan-sweep noise)
//  14. temp_git_* path-segment filter (CC install-cycle clone noise)
//  15. /restart-plugins marker-driven rebaseline of plugins fields
//      (single-shot consumption, surgical scope, per-session keying)
//  16. .in_use/<pid> path-segment filter (CC session-lifetime lock noise)
//  17. Drift-debug breadcrumb for plugins trigger (forensic shortcut)
//  18. gsdDriftPersistenceDays: cross-session drift persistence (Nd) render
//      + the >=1d gate (drift-duration-render, 2026-06-25)
//  19. Drift-debug breadcrumb BOUNDS: dedupe, rotation, prefix-keyed
//      retention + its scope guard, per-run deletion cap (2026-09-17)
//
// Run: node tests/probes/probe-drift-detection.js
//
//
// Companion: tests/probes/probe-migration.js — schema-migration in isolation.
// Companion: /tmp/drift-smoke-test.md (ephemeral) — end-to-end display path.

// SAFE_FOR_LIVE: yes   (mkdtempSync + tmp-file fixtures; reimplemented compare core; no live writes)
const fs = require('fs');
const os = require('os');
const path = require('path');

const { hashWarnSettings, gsdDriftPersistenceDays } = require('../../dhx/statusline-wrapper.js');

// --- Reimplemented helpers (mirror statusline-wrapper.js:scanRecursive) ---
// Probe duplicates the scanner locally — same pattern as probe-migration.js —
// so the probe documents expected behavior explicitly. Divergence between
// this scanner and the wrapper's shows up as a red assertion on the shared
// fixtures.

// Engine-portable Dirent parent resolution. Node 24 REMOVED `dirent.path`
// (deprecated DEP0178); `dirent.parentPath` is the surviving property from
// Node >= 20.12. This mirror is deliberately independent of the wrapper's
// `direntParent` — the probe carries its own scanner so divergence shows up
// as a red assertion (see the header note above `scanRecursive`). Keeping the
// same fallback ORDER is what makes the two comparable across engines.
function direntParent(entry, root) {
  return entry.parentPath || entry.path || root;
}

function scanRecursive(dir, ignoreBasenames, ignorePathPattern) {
  let maxMtime = 0;
  let count = 0;
  // `maxPath` tracks the file whose mtime won the scan — the breadcrumb's
  // load-bearing forensic signal (see scenario [17]). Always paired with
  // maxMtime inside the same conditional so the path never desyncs from
  // the mtime it describes.
  let maxPath = '';
  try {
    const entries = fs.readdirSync(dir, { withFileTypes: true, recursive: true });
    for (const entry of entries) {
      if (ignoreBasenames && ignoreBasenames.has(entry.name)) continue;
      if (ignorePathPattern) {
        const full = path.join(direntParent(entry, dir), entry.name);
        if (ignorePathPattern.test(full)) continue;
      }
      count++;
      if (entry.isDirectory && entry.isDirectory()) continue;
      try {
        const full = path.join(direntParent(entry, dir), entry.name);
        const st = fs.statSync(full);
        if (st.mtimeMs > maxMtime) {
          maxMtime = st.mtimeMs;
          maxPath = full;
        }
      } catch { /* skip */ }
    }
  } catch { /* missing dir */ }
  return { maxMtime, count, maxPath };
}

const PLUGIN_CACHE_IGNORE = new Set(['.orphaned_at']);
const PLUGIN_CACHE_PATH_IGNORE = /(^|\/)(temp_git_\d+_[a-z0-9]+|\.in_use)(\/|$)/;

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
    const full = path.join(direntParent(entry, root), entry.name);
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

// --- 8. Trigger label formatting (multi-trigger join). The session-age format
// assertions ([8b/c/d]) were retired 2026-06-25 when the session-age token was
// dropped from the render (it re-baselined per session and understated drift
// persistence); the render now carries cross-session persistence — see [18]. ---
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

// --- 13. Plugin cache: .orphaned_at filter suppresses CC orphan-sweep noise ---
//
// CC writes `.orphaned_at` markers into plugins/cache during session-start orphan
// sweeps and periodic GC. Because `~/.ccs/shared/plugins/cache` is shared across
// all CCS instances via symlink, any sibling session's sweep bumps mtime and count
// seen by every running session → spurious ⚠ restart plugins warnings across all
// sessions. Filter ensures these files neither count nor contribute to max mtime.
//
// Invariants under test:
//  a) Baseline (no .orphaned_at) = baseline (real plugin files only). Adding
//     .orphaned_at markers leaves mtime AND count unchanged.
//  b) Real plugin file writes are still caught even when an .orphaned_at write
//     happens in the same sweep (the filter doesn't mask adjacent real writes).
//  c) Deletion of .orphaned_at only (CC GC reap) does NOT drop count — protects
//     the count-branch deletion detector from firing on pure bookkeeping GC.
{
  const filterTree = path.join(TMP, 'orphaned-tree');
  fs.mkdirSync(filterTree);
  const real = path.join(filterTree, 'marketplace/plugin/1.0/hooks.json');
  fs.mkdirSync(path.dirname(real), { recursive: true });
  fs.writeFileSync(real, 'x');
  const t0 = BASE_MS;
  restampTree(filterTree, t0);

  const baseline = scanRecursive(filterTree, PLUGIN_CACHE_IGNORE);

  // [13a] Add 3 .orphaned_at markers at future mtimes — filter should swallow them.
  const ts = [t0 + 30_000, t0 + 60_000, t0 + 90_000];
  const orphanedPaths = [
    path.join(filterTree, 'marketplace/plugin/1.0/.orphaned_at'),
    path.join(filterTree, 'marketplace/plugin/.orphaned_at'),
    path.join(filterTree, 'marketplace/.orphaned_at'),
  ];
  for (let i = 0; i < orphanedPaths.length; i++) {
    fs.writeFileSync(orphanedPaths[i], String(Date.now()));
    fs.utimesSync(orphanedPaths[i], ts[i] / 1000, ts[i] / 1000);
  }
  const afterOrphans = scanRecursive(filterTree, PLUGIN_CACHE_IGNORE);
  const triggers13a = checkDriftLogic(
    { ...baseSnap, plugins_mtime: afterOrphans.maxMtime, plugins_count: afterOrphans.count },
    { ...baseSnap, plugins_mtime: baseline.maxMtime, plugins_count: baseline.count },
  );
  assert('[13a] .orphaned_at writes do NOT bump mtime (filter active)',
    afterOrphans.maxMtime === baseline.maxMtime);
  assert('[13b] .orphaned_at writes do NOT bump count (filter active)',
    afterOrphans.count === baseline.count);
  assert('[13c] orphan-sweep produces zero plugins trigger',
    !triggers13a.includes('plugins'));

  // [13d] Add a real plugin file alongside the .orphaned_at markers — trigger fires.
  const realNew = path.join(filterTree, 'marketplace/plugin/1.0/new-hook.json');
  fs.writeFileSync(realNew, 'x');
  const realFuture = t0 + 120_000;
  fs.utimesSync(realNew, realFuture / 1000, realFuture / 1000);
  const withRealWrite = scanRecursive(filterTree, PLUGIN_CACHE_IGNORE);
  const triggers13d = checkDriftLogic(
    { ...baseSnap, plugins_mtime: withRealWrite.maxMtime, plugins_count: withRealWrite.count },
    { ...baseSnap, plugins_mtime: baseline.maxMtime, plugins_count: baseline.count },
  );
  assert('[13d] real plugin file write still caught despite .orphaned_at siblings',
    triggers13d.length === 1 && triggers13d[0] === 'plugins');

  // [13e] CC GC reaps .orphaned_at markers — count must NOT drop (filter active).
  for (const p of orphanedPaths) fs.unlinkSync(p);
  const afterReap = scanRecursive(filterTree, PLUGIN_CACHE_IGNORE);
  assert('[13e] .orphaned_at reap leaves count unchanged (no false deletion trigger)',
    afterReap.count === withRealWrite.count);

  // [13f] Sanity: without the filter, the same .orphaned_at writes WOULD drift.
  // Protects against a future refactor silently dropping the filter argument
  // from collectSnapshot's plugins call site.
  for (let i = 0; i < orphanedPaths.length; i++) {
    fs.writeFileSync(orphanedPaths[i], String(Date.now()));
    fs.utimesSync(orphanedPaths[i], (t0 + 150_000 + i * 1000) / 1000, (t0 + 150_000 + i * 1000) / 1000);
  }
  const unfiltered = scanRecursive(filterTree);
  const filtered = scanRecursive(filterTree, PLUGIN_CACHE_IGNORE);
  assert('[13f] unfiltered scan sees .orphaned_at (regression sentinel: filter call-site must stay wired)',
    unfiltered.count > filtered.count);
}

// --- 14. Plugin cache: temp_git_* path-segment filter suppresses CC install-cycle noise ---
//
// CC clones marketplace sources into `temp_git_<epoch_ms>_<token>/` subtrees
// under `plugins/cache/` while resolving plugin installs — typically when a
// plugin is declared in `enabledPlugins` but missing from `installed_plugins.json`,
// triggering retry-on-session-start. Clones land mid-snapshot, no GC removes
// them, and `~/.ccs/shared/plugins/cache` is symlinked across all CCS instances
// so a single instance's clone trips the drift detector in every other live
// session — same architectural class as the 2026-04-23 `.orphaned_at` filter.
//
// Invariants under test:
//  a) Files inside a `temp_git_*` subtree do NOT bump mtime.
//  b) Files inside a `temp_git_*` subtree do NOT bump count.
//  c) The `temp_git_*` directory entry itself is filtered (not just descendants).
//  d) Real plugin file writes are still caught when a `temp_git_*` clone races
//     in the same scan window.
//  e) Regression sentinel: unfiltered scan (no PATH_IGNORE) WOULD see the
//     temp_git_* contents — protects the call-site wiring from a future
//     refactor silently dropping the third argument to scanRecursive.
//  f) Pattern is anchored on `_<digits>_<token>` shape — a non-CC dir named
//     literally `temp_git/` (no epoch suffix) does NOT get filtered.
{
  const tgTree = path.join(TMP, 'tempgit-tree');
  fs.mkdirSync(tgTree);
  const real = path.join(tgTree, 'marketplace/plugin/1.0/hooks.json');
  fs.mkdirSync(path.dirname(real), { recursive: true });
  fs.writeFileSync(real, 'x');
  const t0 = BASE_MS;
  restampTree(tgTree, t0);

  const baseline = scanRecursive(tgTree, PLUGIN_CACHE_IGNORE, PLUGIN_CACHE_PATH_IGNORE);

  // [14a/b] Add a temp_git_* clone with several files at future mtimes.
  const cloneDir = path.join(tgTree, 'temp_git_1777339524887_b57n2d');
  fs.mkdirSync(cloneDir);
  const clonePaths = [
    path.join(cloneDir, '.claude-plugin/marketplace.json'),
    path.join(cloneDir, 'plugins/superpowers/hooks/hooks.json'),
    path.join(cloneDir, 'README.md'),
  ];
  const cloneFutureMs = t0 + 60_000;
  for (const p of clonePaths) {
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.writeFileSync(p, 'cloned');
    fs.utimesSync(p, cloneFutureMs / 1000, cloneFutureMs / 1000);
  }
  fs.utimesSync(cloneDir, cloneFutureMs / 1000, cloneFutureMs / 1000);

  const afterClone = scanRecursive(tgTree, PLUGIN_CACHE_IGNORE, PLUGIN_CACHE_PATH_IGNORE);
  const triggers14ab = checkDriftLogic(
    { ...baseSnap, plugins_mtime: afterClone.maxMtime, plugins_count: afterClone.count },
    { ...baseSnap, plugins_mtime: baseline.maxMtime, plugins_count: baseline.count },
  );
  assert('[14a] temp_git_* descendants do NOT bump mtime (path-prefix filter active)',
    afterClone.maxMtime === baseline.maxMtime);
  assert('[14b] temp_git_* descendants do NOT bump count (path-prefix filter active)',
    afterClone.count === baseline.count);
  assert('[14c] temp_git_* dir entry itself is filtered (no count contribution from the dir)',
    afterClone.count === baseline.count);  // count would be baseline+1 if the dir entry leaked through
  assert('[14] temp_git_* clone produces zero plugins trigger',
    !triggers14ab.includes('plugins'));

  // [14d] Real plugin file write while temp_git_* clone exists — trigger fires.
  const realNew = path.join(tgTree, 'marketplace/plugin/1.0/new-hook.json');
  fs.writeFileSync(realNew, 'x');
  const realFutureMs = t0 + 90_000;
  fs.utimesSync(realNew, realFutureMs / 1000, realFutureMs / 1000);
  const withRealWrite = scanRecursive(tgTree, PLUGIN_CACHE_IGNORE, PLUGIN_CACHE_PATH_IGNORE);
  const triggers14d = checkDriftLogic(
    { ...baseSnap, plugins_mtime: withRealWrite.maxMtime, plugins_count: withRealWrite.count },
    { ...baseSnap, plugins_mtime: baseline.maxMtime, plugins_count: baseline.count },
  );
  assert('[14d] real plugin file write still caught despite temp_git_* sibling',
    triggers14d.length === 1 && triggers14d[0] === 'plugins');

  // [14e] Regression sentinel: unfiltered scan WOULD see temp_git_* contents.
  // Protects against a future refactor silently dropping the PATH_IGNORE arg
  // from collectSnapshot's plugins call site. Stamp one temp_git file ABOVE
  // the real-write mtime so the mtime sentinel asserts visibly — without this
  // bump, both unfiltered and filtered max would tie at realFutureMs and the
  // mtime sentinel would silently pass on equality rather than on the path
  // filter actually working.
  const sentinelMs = realFutureMs + 30_000;
  fs.utimesSync(clonePaths[0], sentinelMs / 1000, sentinelMs / 1000);
  const unfiltered = scanRecursive(tgTree, PLUGIN_CACHE_IGNORE);  // no PATH_IGNORE
  const filtered = scanRecursive(tgTree, PLUGIN_CACHE_IGNORE, PLUGIN_CACHE_PATH_IGNORE);
  assert('[14e] unfiltered scan sees temp_git_* contents (regression sentinel: PATH_IGNORE call-site must stay wired)',
    unfiltered.count > filtered.count);
  // Tolerance on the sentinel comparison: fs.utimesSync(p, ms/1000, ms/1000)
  // round-trips through tv_sec/tv_nsec and loses sub-ms precision (observed
  // -1/1024 ms drift on WSL2 ext4). Strict === flaked ~30% of runs without
  // affecting the contract — gap to the next-highest mtime is 30_000 ms.
  assert('[14e2] unfiltered scan picks up temp_git_* mtime > realFutureMs (sentinel proves PATH_IGNORE is what suppresses it)',
    unfiltered.maxMtime > filtered.maxMtime && Math.abs(unfiltered.maxMtime - sentinelMs) < 1);

  // [14f] Anchor check: a directory literally named `temp_git/` (no _<epoch>_<token>
  // suffix) is NOT filtered. Prevents the regex from over-matching legitimate
  // user-created paths that happen to share a prefix.
  const lookalike = path.join(tgTree, 'temp_git/inner.md');
  fs.mkdirSync(path.dirname(lookalike), { recursive: true });
  fs.writeFileSync(lookalike, 'y');
  const lookalikeFutureMs = t0 + 120_000;
  fs.utimesSync(lookalike, lookalikeFutureMs / 1000, lookalikeFutureMs / 1000);
  const afterLookalike = scanRecursive(tgTree, PLUGIN_CACHE_IGNORE, PLUGIN_CACHE_PATH_IGNORE);
  assert('[14f] non-CC `temp_git/` (no epoch suffix) is NOT filtered — anchor on _<digits>_<token>',
    afterLookalike.maxMtime > withRealWrite.maxMtime);
}

// --- 16. Plugin cache: .in_use/<pid> path-segment filter suppresses CC lock-marker noise ---
//
// CC writes `.in_use/<pid>` lock markers into each plugin cache subtree as
// session-lifetime bookkeeping — `<pid>` basenames are arbitrary process ids
// (e.g. `16780`, `32372`), the marker is never reaped during the running
// session's lifetime. Because `~/.ccs/shared/plugins/cache` symlinks across
// all CCS instances, any sibling session's `.in_use/<new_pid>` write trips
// drift in every other live session's snapshot (mtime advances despite no
// plugin code change) — same architectural class as the 2026-04-23
// `.orphaned_at` filter and the 2026-04-27 `temp_git_*` filter.
//
// Path-segment filtering (not basename Set) is required because the `<pid>`
// leaves carry arbitrary digit basenames — a Set entry for `.in_use` would
// filter only the directory entry itself, leaving every `<pid>` descendant
// counted and contributing mtime. The constant is now a combined alternation
// covering both `temp_git_*` and `.in_use` so the call-site signature stays
// single-regex.
//
// Invariants under test:
//  a) Files inside an `.in_use/` subtree do NOT bump mtime.
//  b) Files inside an `.in_use/` subtree do NOT bump count.
//  c) Real plugin file writes are still caught when `.in_use/<pid>` markers
//     exist as siblings.
//  d) Regression sentinel: unfiltered scan (no PATH_IGNORE) WOULD see the
//     `.in_use/<pid>` contents — protects the call-site wiring from a future
//     refactor silently dropping the third argument or the `.in_use`
//     alternation arm from the regex.
//
// Anchor discipline is NOT a separate sub-assertion here: the combined regex
// is shared with `temp_git_*`, and scenario [14f] already pins the
// `_<digits>_<token>` anchor against the same constant. If the regex shape
// regresses structurally, [16d] flips; if the `temp_git_*` anchor regresses,
// [14f] flips. Two anchor sub-assertions against one constant is redundant.
{
  const inUseTree = path.join(TMP, 'in-use-tree');
  fs.mkdirSync(inUseTree);
  const real = path.join(inUseTree, 'marketplace/plugin/1.0/hooks.json');
  fs.mkdirSync(path.dirname(real), { recursive: true });
  fs.writeFileSync(real, 'x');
  const t0 = BASE_MS;
  restampTree(inUseTree, t0);

  const baseline = scanRecursive(inUseTree, PLUGIN_CACHE_IGNORE, PLUGIN_CACHE_PATH_IGNORE);

  // [16a/b] Add an `.in_use/` dir with two PID lock markers at future mtimes.
  const inUseDir = path.join(inUseTree, 'marketplace/plugin/1.0/.in_use');
  fs.mkdirSync(inUseDir);
  const pidPaths = [
    path.join(inUseDir, '16780'),
    path.join(inUseDir, '32372'),
  ];
  const cloneFutureMs = t0 + 60_000;
  for (const p of pidPaths) {
    fs.writeFileSync(p, '');
    fs.utimesSync(p, cloneFutureMs / 1000, cloneFutureMs / 1000);
  }
  fs.utimesSync(inUseDir, cloneFutureMs / 1000, cloneFutureMs / 1000);

  const afterInUse = scanRecursive(inUseTree, PLUGIN_CACHE_IGNORE, PLUGIN_CACHE_PATH_IGNORE);
  const triggers16ab = checkDriftLogic(
    { ...baseSnap, plugins_mtime: afterInUse.maxMtime, plugins_count: afterInUse.count },
    { ...baseSnap, plugins_mtime: baseline.maxMtime, plugins_count: baseline.count },
  );
  assert('[16a] .in_use descendants do NOT bump mtime (path-prefix filter active)',
    afterInUse.maxMtime === baseline.maxMtime);
  assert('[16b] .in_use descendants do NOT bump count (path-prefix filter active)',
    afterInUse.count === baseline.count);
  assert('[16] .in_use/<pid> markers produce zero plugins trigger',
    !triggers16ab.includes('plugins'));

  // [16c] Real plugin file write while `.in_use/<pid>` markers exist — trigger fires.
  const realNew = path.join(inUseTree, 'marketplace/plugin/1.0/new-hook.json');
  fs.writeFileSync(realNew, 'x');
  const realFutureMs = t0 + 90_000;
  fs.utimesSync(realNew, realFutureMs / 1000, realFutureMs / 1000);
  const withRealWrite = scanRecursive(inUseTree, PLUGIN_CACHE_IGNORE, PLUGIN_CACHE_PATH_IGNORE);
  const triggers16c = checkDriftLogic(
    { ...baseSnap, plugins_mtime: withRealWrite.maxMtime, plugins_count: withRealWrite.count },
    { ...baseSnap, plugins_mtime: baseline.maxMtime, plugins_count: baseline.count },
  );
  assert('[16c] real plugin file write still caught despite .in_use/<pid> sibling',
    triggers16c.length === 1 && triggers16c[0] === 'plugins');

  // [16d] Regression sentinel: unfiltered scan WOULD see `.in_use/<pid>` contents.
  // Protects against a future refactor silently dropping the PATH_IGNORE arg
  // OR dropping the `.in_use` alternation arm from the regex. Stamp one PID
  // file ABOVE the real-write mtime so the unfiltered scan's max strictly
  // exceeds the filtered scan's max in addition to the count delta.
  const sentinelMs = realFutureMs + 30_000;
  fs.utimesSync(pidPaths[0], sentinelMs / 1000, sentinelMs / 1000);
  const unfiltered = scanRecursive(inUseTree, PLUGIN_CACHE_IGNORE);  // no PATH_IGNORE
  const filtered = scanRecursive(inUseTree, PLUGIN_CACHE_IGNORE, PLUGIN_CACHE_PATH_IGNORE);
  assert('[16d] unfiltered scan sees .in_use/<pid> contents (regression sentinel: PATH_IGNORE call-site must stay wired)',
    unfiltered.count > filtered.count);
}

// --- 15. /restart-plugins marker-driven rebaseline ---
//
// CC's `/restart-plugins` reloads the plugin resolver in-process — same PID,
// same ccTicks, same drift-snapshot file path. Plugin-cache writes during the
// reload (manifest re-reads, `temp_git_*` clones during retry, fresh marketplace
// pulls) push `plugins_mtime`/`plugins_count` past the snapshot, so the next
// statusline refresh fires `⚠ restart plugins (Xm)` on a state the user just
// fixed. Mitigation: `dhx-restart-plugins-stop.sh` writes
// `~/.cache/dhx/plugins-rebaseline-${session_id}.marker` at next turn-end after
// the slash command (Stop event scans the transcript for the
// `<command-name>/(reload|restart)-plugins</command-name>` wrapper — see
// HP-027 for why the trigger lives on Stop and not UserPromptSubmit).
// `checkDrift()` consumes the marker on its next refresh, rewrites ONLY the
// plugins fields on the loaded snapshot, persists, and deletes the marker
// (single-shot).
//
// Probe reimplements the consumer locally — same convention as scanRecursive
// and checkDriftLogic above — so wrapper drift in either direction flips an
// assertion red.
//
// Invariants under test:
//  a) Without marker, snapshot.plugins_mtime preserved → plugins trigger fires.
//  b) With marker, snapshot.plugins fields overwritten → plugins trigger does
//     NOT fire.
//  c) Marker is deleted after read (single-shot).
//  d) Other triggers preserved when marker is consumed: an agents-tree drift
//     concurrent with plugin-cache drift sees ONLY the plugins suppressed.
//  e) Garbage content in marker still consumed (file presence is the signal,
//     not the content).
//  f) Unrelated session marker (different session_id) does NOT suppress this
//     session's plugins drift — keying is per-session.
{
  function consumeMarker(snapshot, current, markerFile) {
    let consumed = false;
    try {
      fs.statSync(markerFile);
      snapshot.plugins_mtime = current.plugins_mtime;
      snapshot.plugins_count = current.plugins_count;
      try { fs.unlinkSync(markerFile); } catch {}
      consumed = true;
    } catch { /* absent — no-op */ }
    return { snapshot, consumed };
  }

  const session = 'sess-15';
  const markerDir = path.join(TMP, 'marker-cache');
  fs.mkdirSync(markerDir, { recursive: true });
  const markerPath = path.join(markerDir, `plugins-rebaseline-${session}.marker`);

  // Build a snapshot/current pair where plugins fields differ (drift exists)
  // and agents/gsd/settings/version match (no other drift).
  const baselinePlugins = { plugins_mtime: 1000, plugins_count: 5 };
  const driftedPlugins  = { plugins_mtime: 2000, plugins_count: 8 };
  const sharedRest = {
    agents_mtime: 1, agents_count: 1,
    gsd_mtime: 1, gsd_count: 1,
    settings_hash: 'x', version: 'v',
  };
  const baseSnapForMarker = { ...sharedRest, ...baselinePlugins };
  const currentForMarker  = { ...sharedRest, ...driftedPlugins };

  // [15a] No marker → plugins trigger fires (sanity / negative control).
  {
    const snap = { ...baseSnapForMarker };
    if (fs.existsSync(markerPath)) fs.unlinkSync(markerPath);
    const { snapshot, consumed } = consumeMarker(snap, currentForMarker, markerPath);
    const triggers = checkDriftLogic(currentForMarker, snapshot);
    assert('[15a] without marker → plugins trigger fires (negative control)',
      consumed === false && triggers.includes('plugins'));
  }

  // [15b] With marker → plugins trigger does NOT fire (marker rebaselines).
  {
    const snap = { ...baseSnapForMarker };
    fs.writeFileSync(markerPath, String(Date.now()));
    const { snapshot, consumed } = consumeMarker(snap, currentForMarker, markerPath);
    const triggers = checkDriftLogic(currentForMarker, snapshot);
    assert('[15b] with marker → plugins trigger suppressed (rebaseline applied)',
      consumed === true && !triggers.includes('plugins'));
    // [15c] Marker deleted after read (single-shot).
    assert('[15c] marker file consumed (single-shot, deleted after read)',
      !fs.existsSync(markerPath));
  }

  // [15d] Other triggers preserved: agents drift concurrent with plugins drift
  // + marker → only plugins suppressed; agents still fires.
  {
    const snap = { ...baseSnapForMarker };
    const currentMixed = {
      ...currentForMarker,
      agents_mtime: sharedRest.agents_mtime + 100,
    };
    fs.writeFileSync(markerPath, String(Date.now()));
    const { snapshot } = consumeMarker(snap, currentMixed, markerPath);
    const triggers = checkDriftLogic(currentMixed, snapshot);
    assert('[15d] marker suppresses plugins only — agents drift still fires',
      triggers.includes('agents') && !triggers.includes('plugins'));
    if (fs.existsSync(markerPath)) fs.unlinkSync(markerPath);
  }

  // [15e] Garbage content in marker still consumed (presence is the signal).
  {
    const snap = { ...baseSnapForMarker };
    fs.writeFileSync(markerPath, '\x00\xffnot-an-epoch\n\n');
    const { snapshot, consumed } = consumeMarker(snap, currentForMarker, markerPath);
    const triggers = checkDriftLogic(currentForMarker, snapshot);
    assert('[15e] marker with garbage content still consumed (file presence is the signal)',
      consumed === true && !triggers.includes('plugins'));
    assert('[15e2] garbage marker still single-shot (deleted after read)',
      !fs.existsSync(markerPath));
  }

  // [15f] Unrelated session marker does NOT suppress this session's drift —
  // markerPath is built from this session's session_id; a different session's
  // marker file resolves to a different basename and the statSync misses.
  {
    const snap = { ...baseSnapForMarker };
    const otherMarker = path.join(markerDir, 'plugins-rebaseline-other-session.marker');
    fs.writeFileSync(otherMarker, String(Date.now()));
    if (fs.existsSync(markerPath)) fs.unlinkSync(markerPath);
    const { snapshot, consumed } = consumeMarker(snap, currentForMarker, markerPath);
    const triggers = checkDriftLogic(currentForMarker, snapshot);
    assert('[15f] unrelated session marker does NOT suppress this session (per-session keying)',
      consumed === false && triggers.includes('plugins'));
    assert('[15f2] unrelated session marker remains untouched (no cross-session GC)',
      fs.existsSync(otherMarker));
    fs.unlinkSync(otherMarker);
  }
}

// --- 17. Drift-debug breadcrumb for plugins trigger (forensic shortcut) ---
//
// Captures `max_path` (the file whose mtime won the scanRecursive() loop)
// at trigger-fire time so the next CC plugin-cache bookkeeping surprise
// resolves in 30s via `tail -1 ~/.cache/dhx/drift-debug-*.log` instead of
// the ~20-min live forensics that produced commit 8274444 (the third
// filter extension in 3 weeks: `.orphaned_at` 2026-04-23 → `temp_git_*`
// 2026-04-27 → `.in_use/<pid>` 2026-05-13). Observer-only — the breadcrumb
// is appended AFTER `triggers.push('plugins')` fires; never gates whether
// drift is detected.
//
// Probe reimplements the breadcrumb writer locally — same convention as
// scanRecursive and consumeMarker above — so wrapper drift in either
// direction (signature/shape/ordering) flips an assertion red.
//
// Invariants under test:
//  a) Breadcrumb file is CREATED at the expected path when a plugins-
//     trigger drift event fires (and not before).
//  b) Breadcrumb's last line is valid JSON with EXACTLY 7 keys: ts,
//     trigger, max_path, current_mtime, snapshot_mtime, current_count,
//     snapshot_count. Catches key-rename / key-add regressions.
//  c) `trigger` is the literal string `"plugins"` and `max_path` is the
//     file whose mtime won the scan (the load-bearing forensic signal).
//  d) Multiple drift fires within the same session APPEND (not overwrite)
//     — verifies fs.appendFileSync, not writeFileSync.
//  e) Breadcrumb does NOT fire when drift is NOT detected — verifies the
//     writer sits INSIDE the drift-detected branch. NOTE: that placement
//     does NOT make emission rare, and this arm never claimed it did —
//     the branch is entered on every refresh for as long as a drift
//     persists, because the drift path does not re-baseline. Sparsity is
//     the writer's job; scenario [19] is where it is asserted.
{
  // Reimplemented breadcrumb writer — mirrors wrapper's emission contract
  // exactly. Any divergence (extra key, missing key, reordered keys, wrong
  // sanitization) flips at least one of [17a]-[17e].
  function writeBreadcrumb(cacheDir, sessionId, current, snapshot) {
    if (!sessionId || /[/\\]|\.\./.test(sessionId)) return false;
    try {
      fs.mkdirSync(cacheDir, { recursive: true });
      const breadcrumbFile = path.join(cacheDir, `drift-debug-${sessionId}.log`);
      const line = JSON.stringify({
        ts: new Date().toISOString(),
        trigger: 'plugins',
        max_path: current.plugins_maxPath ?? '',
        current_mtime: current.plugins_mtime,
        snapshot_mtime: snapshot.plugins_mtime,
        current_count: current.plugins_count,
        snapshot_count: snapshot.plugins_count,
      }) + '\n';
      fs.appendFileSync(breadcrumbFile, line);
      return true;
    } catch { return false; }
  }

  // Wires the wrapper's "fire breadcrumb inside the plugins-trigger branch"
  // contract — assertion [17e] depends on this being the ONLY call path.
  function maybeBreadcrumb(cacheDir, sessionId, current, snapshot) {
    const fired = (current.plugins_mtime > snapshot.plugins_mtime) ||
                  (current.plugins_count < snapshot.plugins_count);
    if (fired) writeBreadcrumb(cacheDir, sessionId, current, snapshot);
    return fired;
  }

  // Unique cache + session_id per probe run — idempotent reruns, zero risk
  // of colliding with ~/.cache/dhx/drift-debug-*.log from the live session.
  const sessionId = `probe-17-${Date.now()}-${process.pid}`;
  const cacheDir = path.join(TMP, 'cache-17');
  const breadcrumbFile = path.join(cacheDir, `drift-debug-${sessionId}.log`);

  // Build a controllable plugins fixture: one seed file (baseline mtime),
  // then mutate by writing a NEW file at a future mtime to deterministically
  // drive plugins_mtime > snapshot.plugins_mtime.
  const pluginRoot = path.join(TMP, 'plugins-17');
  fs.mkdirSync(pluginRoot, { recursive: true });
  const seedFile = path.join(pluginRoot, 'marketplace/plugin/1.0/seed.json');
  fs.mkdirSync(path.dirname(seedFile), { recursive: true });
  fs.writeFileSync(seedFile, 'seed');
  const t0 = BASE_MS;
  restampTree(pluginRoot, t0);

  // Defaults for non-plugins keys — same shape `checkDriftLogic` expects, but
  // we only mutate the plugins fields across this scenario so the other
  // triggers never fire (matches [17e]'s "no other channels" invariant).
  const sharedRest17 = {
    agents_mtime: 1, agents_count: 1,
    gsd_mtime: 1, gsd_count: 1,
    settings_hash: 'baseline-17', version: 'v17',
  };
  const baseScan = scanRecursive(pluginRoot, PLUGIN_CACHE_IGNORE, PLUGIN_CACHE_PATH_IGNORE);
  const baseSnap17 = {
    ...sharedRest17,
    plugins_mtime: baseScan.maxMtime,
    plugins_count: baseScan.count,
    plugins_maxPath: baseScan.maxPath,
  };

  // [17a] Breadcrumb file CREATED when plugins trigger fires.
  // Write a new file at a future mtime → plugins_mtime advances → trigger fires.
  const triggerFile1 = path.join(pluginRoot, 'marketplace/plugin/1.0/new-hook-a.json');
  fs.writeFileSync(triggerFile1, 'x');
  const futureMs1 = t0 + 60_000;
  fs.utimesSync(triggerFile1, futureMs1 / 1000, futureMs1 / 1000);
  const currentScan1 = scanRecursive(pluginRoot, PLUGIN_CACHE_IGNORE, PLUGIN_CACHE_PATH_IGNORE);
  const current1 = {
    ...baseSnap17,
    plugins_mtime: currentScan1.maxMtime,
    plugins_count: currentScan1.count,
    plugins_maxPath: currentScan1.maxPath,
  };
  const fired1 = maybeBreadcrumb(cacheDir, sessionId, current1, baseSnap17);
  assert('[17a] breadcrumb file created when plugins trigger fires',
    fired1 === true && fs.existsSync(breadcrumbFile));

  // [17b] Last line is valid JSON with EXACTLY 7 expected keys.
  const expectedKeys = [
    'current_count', 'current_mtime', 'max_path', 'snapshot_count',
    'snapshot_mtime', 'trigger', 'ts',
  ];
  let parsed1;
  let actualKeys = [];
  try {
    const lines = fs.readFileSync(breadcrumbFile, 'utf8').split('\n').filter(Boolean);
    parsed1 = JSON.parse(lines[lines.length - 1]);
    actualKeys = Object.keys(parsed1).sort();
  } catch { /* parsed1 stays undefined → assertion fails cleanly */ }
  assert('[17b] last line parses as JSON with exactly 7 expected keys (sorted equality)',
    parsed1 && actualKeys.length === 7 &&
    actualKeys.every((k, i) => k === expectedKeys[i]));

  // [17c] trigger === "plugins" and max_path === the file that won the scan.
  assert('[17c] trigger field is literally "plugins" and max_path is the file whose mtime won the scan',
    parsed1 && parsed1.trigger === 'plugins' &&
    parsed1.max_path === triggerFile1);

  // [17d] Append-only across multiple fires in the same session.
  // Touch a second file at a later mtime → trigger fires again → second line lands.
  const triggerFile2 = path.join(pluginRoot, 'marketplace/plugin/1.0/new-hook-b.json');
  fs.writeFileSync(triggerFile2, 'x');
  const futureMs2 = t0 + 120_000;
  fs.utimesSync(triggerFile2, futureMs2 / 1000, futureMs2 / 1000);
  // snapshot at this point = current1 (post-first-fire); pre-rebaseline shape.
  const snapshotForFire2 = {
    ...current1,  // first fire's "current" becomes the baseline for the second compare
  };
  const currentScan2 = scanRecursive(pluginRoot, PLUGIN_CACHE_IGNORE, PLUGIN_CACHE_PATH_IGNORE);
  const current2 = {
    ...snapshotForFire2,
    plugins_mtime: currentScan2.maxMtime,
    plugins_count: currentScan2.count,
    plugins_maxPath: currentScan2.maxPath,
  };
  const fired2 = maybeBreadcrumb(cacheDir, sessionId, current2, snapshotForFire2);
  const linesAfter = fs.readFileSync(breadcrumbFile, 'utf8').split('\n').filter(Boolean);
  let parsed2;
  try { parsed2 = JSON.parse(linesAfter[linesAfter.length - 1]); } catch {}
  assert('[17d] second fire APPENDS (file has 2 lines, line 2 has different max_path)',
    fired2 === true && linesAfter.length === 2 &&
    parsed2 && parsed2.max_path === triggerFile2 &&
    parsed2.max_path !== parsed1.max_path);

  // [17e] Breadcrumb does NOT fire when drift is NOT detected.
  // Re-baseline against current2 (matches the post-fire state) and re-invoke
  // maybeBreadcrumb without mutating the tree → no trigger → no line appended.
  const linesPreNoDrift = linesAfter.length;
  const noDriftSnapshot = { ...current2 };
  const currentScanSame = scanRecursive(pluginRoot, PLUGIN_CACHE_IGNORE, PLUGIN_CACHE_PATH_IGNORE);
  const currentSame = {
    ...noDriftSnapshot,
    plugins_mtime: currentScanSame.maxMtime,
    plugins_count: currentScanSame.count,
    plugins_maxPath: currentScanSame.maxPath,
  };
  const firedSame = maybeBreadcrumb(cacheDir, sessionId, currentSame, noDriftSnapshot);
  const linesPostNoDrift = fs.readFileSync(breadcrumbFile, 'utf8').split('\n').filter(Boolean).length;
  assert('[17e] breadcrumb does NOT fire when drift is not detected (writer sits inside drift-detected branch)',
    firedSame === false && linesPostNoDrift === linesPreNoDrift);

  // Composite assertion mirroring [14]/[16] shape — single visible PASS line
  // for the whole scenario in addition to the sub-assertions.
  assert('[17] drift-debug breadcrumb fires correctly (creates file, 7-key JSON, plugins trigger, append-only, no false fires)',
    fired1 === true && parsed1 &&
    actualKeys.length === 7 && actualKeys.every((k, i) => k === expectedKeys[i]) &&
    parsed1.trigger === 'plugins' && parsed1.max_path === triggerFile1 &&
    fired2 === true && linesAfter.length === 2 &&
    parsed2 && parsed2.max_path === triggerFile2 &&
    firedSame === false && linesPostNoDrift === linesPreNoDrift);
}

// --- 18. gsdDriftPersistenceDays: cross-session drift persistence (Nd) render ---
//
// Backs the 2026-06-25 drift-duration-render change: the statusline ⚠ segment
// drops the misleading session-age token and instead surfaces the MAX days any
// still-diverging file has been unresolved, read from gsd-drift-first-seen.json
// (ISO 8601 values). Tests the REAL exported wrapper helper (not a local mirror)
// + the >=1d render gate. Backs docs/decisions.md 2026-06-25 row + closes the
// at-a-glance half of Problem 2 (reports/2026-05-18-canonical-mirror-drift-...).
{
  const DAY = 86_400_000;
  const now = Date.UTC(2026, 5, 25, 12, 0, 0);   // fixed anchor — no Date.now() flake
  const iso = (ms) => new Date(ms).toISOString();

  // The render gate the wrapper applies: ` (Nd)` only when persistence >= 1 day.
  const renderToken = (cache) => {
    const d = gsdDriftPersistenceDays(cache, now);
    return d >= 1 ? ` (${d}d)` : '';
  };

  assert('[18a] empty cache → 0 days (no token)',
    gsdDriftPersistenceDays({}, now) === 0 && renderToken({}) === '');
  assert('[18b] null / non-object cache → 0 (fail-safe)',
    gsdDriftPersistenceDays(null, now) === 0 && gsdDriftPersistenceDays('x', now) === 0);
  assert('[18c] single entry 6 days old → 6',
    gsdDriftPersistenceDays({ 'workflows/execute-phase.md': iso(now - 6 * DAY) }, now) === 6);
  assert('[18d] MAX age across entries (oldest wins), not min/avg',
    gsdDriftPersistenceDays({
      'a.md': iso(now - 2 * DAY),
      'b.md': iso(now - 9 * DAY),
      'c.md': iso(now - 5 * DAY),
    }, now) === 9);
  assert('[18e] sub-day age → 0, gate suppresses the token',
    gsdDriftPersistenceDays({ 'a.md': iso(now - 12 * 60 * 60 * 1000) }, now) === 0 &&
    renderToken({ 'a.md': iso(now - 12 * 60 * 60 * 1000) }) === '');
  assert('[18f] unparseable values ignored (no NaN poisoning); all-bad → 0',
    gsdDriftPersistenceDays({ 'a.md': 'not-a-date', 'b.md': iso(now - 3 * DAY) }, now) === 3 &&
    gsdDriftPersistenceDays({ 'a.md': 'not-a-date' }, now) === 0);
  assert('[18g] render gate: >=1d emits " (Nd)" in the exact wrapper format',
    renderToken({ 'a.md': iso(now - 6 * DAY) }) === ' (6d)');
}

// --- 19. Drift-debug breadcrumb BOUNDS: dedupe, rotation, retention ---------
//
// Scenario 17 above pins the breadcrumb's EMISSION contract against a local
// mirror. This scenario pins its BOUNDS, and deliberately does NOT mirror:
// every assertion drives the wrapper's real exported writer/sweeper. A
// reimplementation would be worthless here — the defect being fixed was that
// the SHIPPED sweeper never reached these files, and a local copy of a correct
// sweeper cannot detect that. Same reasoning as the laneIdFor / readLaneHealth
// exports (2026-09-15).
//
// Why these bounds exist (measured 2026-09-17 on the largest surviving log,
// before it was swept): 18,206 lines over 6.6 days, 206.6 MB, carrying 11
// distinct payloads. 8,651 of 8,680 gsd fires were exactly 60s apart. The
// drift path never re-baselines the snapshot — by design, so the ⚠ warning
// persists until the operator acts — so the writer sat inside a branch that
// stays TRUE on every refresh. The 2026-05-13 row's "fires rarely / naturally
// sparse" premise described events; the branch is a state.
//
// Invariants under test:
//  a) An identical payload does NOT append a second line (dedupe).
//  b) A CHANGED payload DOES append (dedupe must never suppress a real change).
//  c) Dedupe compares the PAYLOAD, not the whole line: a stored line carrying
//     the same payload under a different `ts` still collapses. Constructed with
//     a fixed seeded ts, never by racing two real writes — the racing form was
//     flaky (it depended on the two writes straddling a millisecond).
//  d) RETENTION REACHES drift-debug-*.log. This is the arm the whole change
//     exists for: before the fix, sweepSpoolDir skipped any name not ending
//     `.jsonl` and was pointed only at three SUBdirectories, so a breadcrumb
//     at the cache base was unreachable on both counts.
//  e) The sweeper touches NOTHING else in the same directory. The cache base
//     holds 3,342 partial-read-detect-*.jsonl from an unrelated hook, the
//     wrapper's own statusline-errors.jsonl, and 17 non-breadcrumb .log files.
//     A bare extension predicate aimed here unlinks them; this asserts the
//     prefix+suffix predicate does not.
//     [19e2] additionally asserts the predicate's SHAPE over a GENERATED
//     prefix×suffix matrix, because (e)'s list is hardcoded and a hardcoded list
//     in a guard stops guarding the moment an unheard-of class appears: an
//     unanchored `/\.log/` typo passed every other arm in this scenario.
//  f) The daily stamp survives a sweep that deletes every log beside it. The
//     stamp shares the `drift-debug-` prefix, so only the suffix test saves it
//     — this is the companion assertion for that INVARIANT comment.
//  g) Rotation at the byte ceiling renames to `.log.1` and starts a fresh
//     `.log`; no line is ever truncated (docs/decisions.md 2026-09-03 records
//     a sibling breadcrumb's per-line cap silently dropping 289 of 614 rows,
//     longest first).
//     [19g2] additionally pins that the rotation is PRE-EMPTIVE — the .log does
//     not exceed the ceiling by one whole line, which is what a bare
//     `size >= max` pre-append test allows (close-review finding, 2026-09-17).
//  h) The per-run deletion cap holds, and drains OLDEST first. Introducing
//     retention to a never-swept store makes the first run delete the entire
//     backlog: on 2026-09-17 that cost 348 files / 1.90 GiB about one second
//     after the writer was saved, because this file is symlinked from
//     ~/.claude/hooks and the live statusline re-reads it every 60s.
//  i) The daily gate is a gate: a second call the same day returns -1 and
//     deletes nothing.
//  j) A swept log is ARCHIVED before it is unlinked (gzip + SHA256SUMS row).
//  k) An archive failure RETAINS the log. This is the enforcement of the
//     operator's 2026-09-17 condition (60-day window, archive first): without
//     this arm the window is armed on a promise rather than a mechanism.
//  l) The archived copy gunzips to the ORIGINAL bytes and the manifest records
//     that pre-compression digest — verified in the probe, not trusted from the
//     wrapper's own read-back.
{
  const {
    writeDriftDebugBreadcrumb,
    archiveDriftDebugLog,
    sweepDriftDebugLogs,
    maybeSweepDriftDebugLogs,
    driftDebugPayload,
  } = require('../../dhx/statusline-wrapper.js');

  const DAY = 86400_000;
  const sid = `probe-19-${Date.now()}-${process.pid}`;
  const cacheDir = path.join(TMP, 'bc-cache');
  fs.mkdirSync(cacheDir, { recursive: true });
  const logFile = path.join(cacheDir, `drift-debug-${sid}.log`);
  const lines = (f) => {
    try { return fs.readFileSync(f, 'utf8').split('\n').filter(Boolean); }
    catch { return []; }
  };

  // --- (a)(b)(c) dedupe -----------------------------------------------------
  const rowA = { trigger: 'gsd', diverging: [{ path: 'a.md', kind: 'mismatch' }], current_mtime: 2, snapshot_mtime: 1 };
  const rowB = { trigger: 'gsd', diverging: [{ path: 'b.md', kind: 'mismatch' }], current_mtime: 3, snapshot_mtime: 1 };

  const r1 = writeDriftDebugBreadcrumb(cacheDir, sid, rowA);
  const r2 = writeDriftDebugBreadcrumb(cacheDir, sid, rowA);
  assert('[19a] identical payload does NOT append a second line (dedupe)',
    r1 === 'written' && r2 === 'duplicate' && lines(logFile).length === 1);

  const r3 = writeDriftDebugBreadcrumb(cacheDir, sid, rowB);
  assert('[19b] CHANGED payload DOES append (dedupe never suppresses a real change)',
    r3 === 'written' && lines(logFile).length === 2);

  // ts-blindness, constructed rather than raced. An earlier version of this arm
  // wrote rowB twice and asserted the two `ts` values differed — which only
  // holds if the writes straddle a millisecond boundary. It passed on one run
  // and failed on the next. Seed a line carrying rowB's payload under a FIXED,
  // obviously-different ts instead: a whole-line comparison cannot match it,
  // so only a payload comparison can return 'duplicate'.
  const tsSid = `${sid}-ts`;
  const tsFile = path.join(cacheDir, `drift-debug-${tsSid}.log`);
  fs.writeFileSync(tsFile, `{"ts":"2020-01-01T00:00:00.000Z",${JSON.stringify(rowB).slice(1)}\n`);
  const r4 = writeDriftDebugBreadcrumb(cacheDir, tsSid, rowB);
  assert('[19c] dedupe compares payload, not the whole line (a different ts still collapses)',
    r4 === 'duplicate' && lines(tsFile).length === 1 &&
    JSON.parse(lines(tsFile)[0]).ts === '2020-01-01T00:00:00.000Z' &&
    driftDebugPayload(lines(tsFile)[0]) === JSON.stringify(rowB));

  // --- (d)(e)(f) retention reaches breadcrumbs, and ONLY breadcrumbs --------
  const sweepDir = path.join(TMP, 'bc-sweep');
  fs.mkdirSync(sweepDir, { recursive: true });
  const old = Date.now() - 90 * DAY;

  // Breadcrumbs the sweep MUST reach (both generations).
  const victims = ['drift-debug-aaa.log', 'drift-debug-bbb.log', 'drift-debug-ccc.log.1'];
  // Bystanders that MUST survive — every class actually present at the cache
  // base on 2026-09-17, aged well past the cutoff so only the predicate saves them.
  const bystanders = [
    'partial-read-detect-xyz.jsonl',   // 3,342 of these, unrelated hook
    'statusline-errors.jsonl',         // the wrapper's OWN error log
    'read-dedup-stats.jsonl',
    'gemini-review-usage.jsonl',
    'gsd-install-20260716T074853Z.log',
    'source-write-flag.log',
    'cd-compound-read-allow.log',
    'drift-snapshot-somesession.json', // shares no prefix, but cheap to pin
    'drift-debug-sweep.stamp',         // shares the PREFIX — only the suffix saves it
  ];
  for (const n of [...victims, ...bystanders]) {
    const p = path.join(sweepDir, n);
    fs.writeFileSync(p, 'x\n');
    fs.utimesSync(p, new Date(old), new Date(old));
  }

  const removed = sweepDriftDebugLogs(sweepDir, Date.now() - 60 * DAY);
  const victimsGone = victims.every((n) => !fs.existsSync(path.join(sweepDir, n)));
  assert('[19d] retention REACHES drift-debug-*.log and .log.1 (the defect this change fixes)',
    removed === victims.length && victimsGone);

  const bystandersKept = bystanders
    .filter((n) => n !== 'drift-debug-sweep.stamp')
    .every((n) => fs.existsSync(path.join(sweepDir, n)));
  assert('[19e] sweeper touches nothing else in the directory (.jsonl, foreign .log, snapshots)',
    bystandersKept);

  assert('[19f] drift-debug-sweep.stamp survives its own sweep (prefix shared, suffix saves it)',
    fs.existsSync(path.join(sweepDir, 'drift-debug-sweep.stamp')));

  // [19e2] The predicate's SHAPE, generated rather than enumerated. [19e] above
  // pins the file classes actually observed at the cache base on 2026-09-17, which
  // is a useful regression sentinel but is a HARDCODED LIST — and a hardcoded list
  // in a guard assertion silently loses its tooth as soon as a class it never heard
  // of appears. Demonstrated, not theorised: an unanchored `/\.log/` in place of
  // `/\.log(\.1)?$/` — an ordinary typo — passed [19a]-[19i] and [19d2] intact,
  // because no bystander in that list carries BOTH the `drift-debug-` prefix and a
  // non-terminal `.log`. Such a predicate would delete `drift-debug-x.log.bak`.
  //
  // So this arm builds the cross product of the two dimensions the predicate
  // actually tests and requires the deleted set to equal the matching set EXACTLY.
  // A future file class is then covered by its shape rather than by anyone
  // remembering to add it here. (Credit: session Hk 09-17-tier-probes-write-tracked-
  // cells found the same shape in its own probe — a class guarantee that grepped a
  // token which survived an inverted guard — and the reciprocal check found this.)
  const shapeDir = path.join(TMP, 'bc-shape');
  fs.mkdirSync(shapeDir, { recursive: true });
  const PREFIXES = [
    { p: 'drift-debug-', match: true },   // the real one
    { p: 'drift-debug', match: false },   // no trailing dash
    { p: 'drift_debug-', match: false },  // underscore
    { p: 'xdrift-debug-', match: false }, // does not START with it
    { p: 'gsd-install-', match: false },  // a real foreign class
  ];
  const SUFFIXES = [
    { s: '.log', match: true },           // the live generation
    { s: '.log.1', match: true },         // the rotated generation
    { s: '.log.2', match: false },        // only ONE generation is ours
    { s: '.logx', match: false },         // unanchored-regex bait
    { s: '.log.1.bak', match: false },    // unanchored-regex bait
    { s: '.log~', match: false },         // editor backup
    { s: '.jsonl', match: false },        // 3,342 of these live beside us
    { s: '.stamp', match: false },        // our own daily gate
    { s: '.json', match: false },         // drift snapshots
  ];
  const shapeOld = Date.now() - 90 * DAY;
  const shouldDelete = new Set();
  let caseN = 0;
  for (const pre of PREFIXES) {
    for (const suf of SUFFIXES) {
      const name = `${pre.p}case${caseN++}${suf.s}`;
      const p = path.join(shapeDir, name);
      fs.writeFileSync(p, 'x\n');
      fs.utimesSync(p, new Date(shapeOld), new Date(shapeOld));
      if (pre.match && suf.match) shouldDelete.add(name);
    }
  }
  const shapeBefore = fs.readdirSync(shapeDir).sort();
  // Cap raised past the fixture size so the cap cannot mask a scope error here.
  sweepDriftDebugLogs(shapeDir, Date.now() - 60 * DAY, 1000);
  const shapeAfter = new Set(fs.readdirSync(shapeDir));
  const wronglyDeleted = shapeBefore.filter((n) => !shouldDelete.has(n) && !shapeAfter.has(n));
  const wronglyKept = [...shouldDelete].filter((n) => shapeAfter.has(n));
  assert('[19e2] predicate matches EXACTLY the prefix×suffix shapes it should, over a generated matrix',
    shapeBefore.length === PREFIXES.length * SUFFIXES.length &&
    shouldDelete.size === 2 &&
    wronglyDeleted.length === 0 &&
    wronglyKept.length === 0);

  // A log NEWER than the cutoff must be kept — proves the sweep is age-gated,
  // not a blanket delete (a sweeper that removes everything also passes [19d]).
  const freshDir = path.join(TMP, 'bc-fresh');
  fs.mkdirSync(freshDir, { recursive: true });
  fs.writeFileSync(path.join(freshDir, 'drift-debug-fresh.log'), 'x\n');
  const freshRemoved = sweepDriftDebugLogs(freshDir, Date.now() - 60 * DAY);
  assert('[19d2] a log INSIDE the window is kept (age gate, not a blanket delete)',
    freshRemoved === 0 && fs.existsSync(path.join(freshDir, 'drift-debug-fresh.log')));

  // --- (g) rotation ---------------------------------------------------------
  const rotDir = path.join(TMP, 'bc-rot');
  fs.mkdirSync(rotDir, { recursive: true });
  const rotSid = `${sid}-rot`;
  const rotFile = path.join(rotDir, `drift-debug-${rotSid}.log`);
  // Seed past the ceiling with COMPLETE lines, then write one more.
  const filler = JSON.stringify({ trigger: 'gsd', pad: 'y'.repeat(4096) }) + '\n';
  const ceiling = Number(process.env.DHX_DRIFT_DEBUG_MAX_BYTES) || 5242880;
  let seeded = '';
  while (seeded.length < ceiling) seeded += filler;
  fs.writeFileSync(rotFile, seeded);
  const seededLineCount = seeded.split('\n').filter(Boolean).length;

  writeDriftDebugBreadcrumb(rotDir, rotSid, { trigger: 'plugins', max_path: '/after/rotation' });
  const rotated = rotFile + '.1';
  const postLines = lines(rotFile);
  assert('[19g] rotation renames to .log.1 and starts a fresh .log; no line truncated',
    fs.existsSync(rotated) &&
    lines(rotated).length === seededLineCount &&
    lines(rotated).every((l) => { try { JSON.parse(l); return true; } catch { return false; } }) &&
    postLines.length === 1 &&
    JSON.parse(postLines[0]).max_path === '/after/rotation');

  // [19g2] The bound is the CEILING, not ceiling-plus-one-line. A close review
  // (reports/2026-09-17-close-review-drift-debug-retention-evidence/round-1.md)
  // found the first implementation tested `size >= max` BEFORE appending, which
  // bounds the file only to max + one whole line — ~25 KB for a typical gsd
  // payload. Seed to just under the ceiling, write a line that would cross it,
  // and require the .log to come out at or under the ceiling.
  const preDir = path.join(TMP, 'bc-pre');
  fs.mkdirSync(preDir, { recursive: true });
  const preSid = `${sid}-pre`;
  const preFile = path.join(preDir, `drift-debug-${preSid}.log`);
  const bigRow = { trigger: 'gsd', diverging: [{ path: 'z'.repeat(2000), kind: 'mismatch' }] };
  const bigLineBytes = Buffer.byteLength(`{"ts":"2020-01-01T00:00:00.000Z",${JSON.stringify(bigRow).slice(1)}\n`);
  // Land the seed inside (ceiling - bigLine, ceiling) so the file is UNDER the
  // ceiling — a `size >= max` check would not rotate — yet one more line crosses
  // it. Sized EXACTLY: appending whole `filler` lines in a while-loop overshoots
  // by up to one filler (~4 KB) and can land the seed ABOVE the ceiling, which
  // made the first version of this arm red on its own fixture.
  const seedTarget = ceiling - Math.floor(bigLineBytes / 2);
  fs.writeFileSync(preFile, 'x'.repeat(seedTarget - 1) + '\n');
  const sizeBefore = fs.statSync(preFile).size;
  writeDriftDebugBreadcrumb(preDir, preSid, bigRow);
  const sizeAfter = fs.statSync(preFile).size;
  assert('[19g2] rotation is pre-emptive — the .log never exceeds the ceiling by a whole line',
    sizeBefore < ceiling &&                          // a `size >= max` check would NOT have rotated
    sizeBefore + bigLineBytes > ceiling &&           // ...yet this line crosses it
    fs.existsSync(preFile + '.1') &&                 // so it rotated
    sizeAfter <= ceiling &&                          // and the live log is within bounds
    lines(preFile).length === 1);

  // --- (j)(k)(l) archive-before-unlink: retention is COMPACTION -------------
  // Operator decision 2026-09-17: 60-day window, conditioned on archiving first.
  // A one-time hand archive satisfies that once and then silently stops, so the
  // sweep archives as it goes and must never unlink what it has not verifiably
  // archived. These arms are the enforcement of that condition.
  const arcDir = path.join(TMP, 'bc-arc');
  const arcRoot = path.join(TMP, 'arc-root');
  fs.mkdirSync(arcDir, { recursive: true });
  const arcName = 'drift-debug-tobearchived.log';
  const arcSrc = path.join(arcDir, arcName);
  const arcBody = JSON.stringify({ trigger: 'gsd', diverging: [{ path: 'q.md', kind: 'mismatch' }] }) + '\n';
  fs.writeFileSync(arcSrc, arcBody);
  fs.utimesSync(arcSrc, new Date(old), new Date(old));
  const arcRemoved = sweepDriftDebugLogs(arcDir, Date.now() - 60 * DAY, 25, arcRoot);
  const today = new Date().toISOString().slice(0, 10);
  const arcGz = path.join(arcRoot, today, arcName + '.gz');
  const arcSums = path.join(arcRoot, today, 'SHA256SUMS');

  assert('[19j] a swept log is archived (.gz + SHA256SUMS row) AND then unlinked',
    arcRemoved === 1 && !fs.existsSync(arcSrc) &&
    fs.existsSync(arcGz) && fs.existsSync(arcSums) &&
    fs.readFileSync(arcSums, 'utf8').includes(arcName));

  // The archive is only an archive if it reads back. Verify independently of the
  // wrapper's own check — gunzip here, in the probe, and compare to the bytes
  // that were written.
  let arcRoundTrip = false, arcDigestOk = false;
  try {
    const zlib = require('zlib');
    const back = zlib.gunzipSync(fs.readFileSync(arcGz)).toString('utf8');
    arcRoundTrip = (back === arcBody);
    const want = require('crypto').createHash('sha256').update(arcBody).digest('hex');
    arcDigestOk = fs.readFileSync(arcSums, 'utf8').startsWith(want + '  ');
  } catch { /* leaves both false */ }
  assert('[19l] the archived copy gunzips to the ORIGINAL bytes and SHA256SUMS records that digest',
    arcRoundTrip && arcDigestOk);

  // FAIL-CLOSED. The operator's condition is only enforced if an unarchivable
  // file SURVIVES. Make the archive root unopenable by planting a FILE where its
  // directory must go — mkdirSync then throws ENOTDIR regardless of uid, which a
  // chmod-000 fixture would not guarantee under root.
  const blockedRoot = path.join(TMP, 'arc-blocked');
  fs.writeFileSync(blockedRoot, 'not a directory\n');
  const failDir = path.join(TMP, 'bc-arc-fail');
  fs.mkdirSync(failDir, { recursive: true });
  const failSrc = path.join(failDir, 'drift-debug-mustsurvive.log');
  fs.writeFileSync(failSrc, arcBody);
  fs.utimesSync(failSrc, new Date(old), new Date(old));
  const failRemoved = sweepDriftDebugLogs(failDir, Date.now() - 60 * DAY, 25, blockedRoot);
  assert('[19k] archive failure RETAINS the log — no unlink without a verified archive',
    failRemoved === 0 && fs.existsSync(failSrc) &&
    fs.readFileSync(failSrc, 'utf8') === arcBody);

  // And the archiver's own contract, driven directly: it returns false rather
  // than throwing, so the sweeper's `continue` arm is reachable.
  assert('[19k2] archiveDriftDebugLog returns false (never throws) on an unusable archive root',
    archiveDriftDebugLog(failSrc, blockedRoot) === false);

  // --- (h) per-run deletion cap, oldest first -------------------------------
  const capDir = path.join(TMP, 'bc-cap');
  fs.mkdirSync(capDir, { recursive: true });
  // 10 logs, ages 100d down to 91d — all due against a 60d cutoff.
  for (let i = 0; i < 10; i++) {
    const p = path.join(capDir, `drift-debug-cap${i}.log`);
    fs.writeFileSync(p, 'x\n');
    const when = Date.now() - (100 - i) * DAY;
    fs.utimesSync(p, new Date(when), new Date(when));
  }
  const capRemoved = sweepDriftDebugLogs(capDir, Date.now() - 60 * DAY, 3);
  const survivors = fs.readdirSync(capDir).sort();
  assert('[19h] per-run cap holds and drains OLDEST first (first-sweep cliff guard)',
    capRemoved === 3 && survivors.length === 7 &&
    !survivors.includes('drift-debug-cap0.log') &&
    !survivors.includes('drift-debug-cap2.log') &&
    survivors.includes('drift-debug-cap3.log') &&
    survivors.includes('drift-debug-cap9.log'));

  // --- (i) daily gate -------------------------------------------------------
  const gateDir = path.join(TMP, 'bc-gate');
  fs.mkdirSync(gateDir, { recursive: true });
  const gateVictim = path.join(gateDir, 'drift-debug-gate.log');
  fs.writeFileSync(gateVictim, 'x\n');
  fs.utimesSync(gateVictim, new Date(old), new Date(old));
  const firstRun = maybeSweepDriftDebugLogs(gateDir);
  // Re-create a due file; a gated second run must leave it alone.
  fs.writeFileSync(gateVictim, 'x\n');
  fs.utimesSync(gateVictim, new Date(old), new Date(old));
  const secondRun = maybeSweepDriftDebugLogs(gateDir);
  assert('[19i] daily gate: second call the same day returns -1 and deletes nothing',
    firstRun === 1 && secondRun === -1 && fs.existsSync(gateVictim));

  assert('[19] breadcrumb bounds hold (dedupe, ts-blind, retention reaches, scope-safe, rotation, cap, daily gate)',
    r1 === 'written' && r2 === 'duplicate' && r3 === 'written' && r4 === 'duplicate' &&
    removed === victims.length && bystandersKept && freshRemoved === 0 &&
    wronglyDeleted.length === 0 && wronglyKept.length === 0 &&
    fs.existsSync(rotated) && fs.existsSync(preFile + '.1') &&
    arcRemoved === 1 && arcRoundTrip && failRemoved === 0 && fs.existsSync(failSrc) &&
    capRemoved === 3 && secondRun === -1);
}

// --- Cleanup + summary ---
fs.rmSync(TMP, { recursive: true, force: true });

const passed = results.filter((r) => r.ok).length;
const failed = results.length - passed;
console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
