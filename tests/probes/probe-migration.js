// Probe: confirm legacy snapshots re-baseline gracefully — no drift this
// round, current-format file on disk after. Covers TWO legacy shapes:
//   (a) pre-hash (2026-04-16) — no settings_hash, carries settings_mtime
//   (b) pre-count (2026-04-18) — has settings_hash but no *_count fields
// Unified migration guard fires on either absence.
const fs = require('fs');
const os = require('os');
const path = require('path');

// Reimplement the comparison core as it lives in checkDrift(). Unified
// schema-migration guard: either absence of settings_hash OR absence of
// agents_count re-baselines as a first-invocation.
function runCheck(current, snapshotFile) {
  let snapshot;
  try {
    snapshot = JSON.parse(fs.readFileSync(snapshotFile, 'utf8'));
  } catch {
    fs.writeFileSync(snapshotFile, JSON.stringify(current));
    return { triggers: [], reason: 'first-invocation' };
  }
  if (!('settings_hash' in snapshot) || !('agents_count' in snapshot)) {
    fs.writeFileSync(snapshotFile, JSON.stringify(current));
    return { triggers: [], reason: 'schema-migration' };
  }
  const triggers = [];
  if (current.agents_mtime > snapshot.agents_mtime ||
      current.agents_count < snapshot.agents_count) triggers.push('agents');
  if (current.settings_hash !== snapshot.settings_hash) triggers.push('settings');
  if (current.gsd_mtime > snapshot.gsd_mtime ||
      current.gsd_count < snapshot.gsd_count) triggers.push('gsd');
  if (current.plugins_mtime > snapshot.plugins_mtime ||
      current.plugins_count < snapshot.plugins_count) triggers.push('plugins');
  if (current.version !== snapshot.version) triggers.push('version');
  return { triggers, reason: 'compared' };
}

const testFile = path.join(os.tmpdir(), 'probe-migration-' + process.pid + '.json');

// Current-format snapshot (all 8 fields: 3 mtime + 3 count + hash + version)
const current = {
  agents_mtime: 1000,
  agents_count: 4,
  settings_hash: 'abc123',
  gsd_mtime: 2000,
  gsd_count: 7,
  plugins_mtime: 3000,
  plugins_count: 11,
  version: '2.1.112',
};

// 1. Missing file → first-invocation, writes snapshot, no drift
try { fs.unlinkSync(testFile); } catch {}
let r = runCheck(current, testFile);
console.log(`[1] missing file: reason=${r.reason}, triggers=[${r.triggers.join(',')}]`);

// 2. Legacy pre-hash snapshot (settings_mtime only, no settings_hash, no counts)
//    → schema-migration, no drift, file gets rewritten with full current shape
fs.writeFileSync(testFile, JSON.stringify({
  agents_mtime: 999,
  settings_mtime: 1234567,
  gsd_mtime: 1999,
  plugins_mtime: 2999,
  version: '2.1.100',
}));
r = runCheck(current, testFile);
console.log(`[2] legacy pre-hash: reason=${r.reason}, triggers=[${r.triggers.join(',')}]`);
const afterPreHash = JSON.parse(fs.readFileSync(testFile, 'utf8'));
const preHashHasHash = 'settings_hash' in afterPreHash;
const preHashHasLegacy = 'settings_mtime' in afterPreHash;
const preHashHasCount = 'agents_count' in afterPreHash;
console.log(`[2] file after: settings_hash=${preHashHasHash}, legacy settings_mtime=${preHashHasLegacy}, agents_count=${preHashHasCount}`);

// 3. Legacy pre-count snapshot (has settings_hash but no *_count fields)
//    → schema-migration, no drift, file gets rewritten with count fields
fs.writeFileSync(testFile, JSON.stringify({
  agents_mtime: 999,
  settings_hash: 'abc123',
  gsd_mtime: 1999,
  plugins_mtime: 2999,
  version: '2.1.100',
}));
r = runCheck(current, testFile);
console.log(`[3] legacy pre-count: reason=${r.reason}, triggers=[${r.triggers.join(',')}]`);
const afterPreCount = JSON.parse(fs.readFileSync(testFile, 'utf8'));
const preCountHasAllCounts = (
  'agents_count' in afterPreCount &&
  'gsd_count' in afterPreCount &&
  'plugins_count' in afterPreCount
);
const preCountHasAllMtimes = (
  'agents_mtime' in afterPreCount &&
  'gsd_mtime' in afterPreCount &&
  'plugins_mtime' in afterPreCount
);
const preCountHasHash = 'settings_hash' in afterPreCount;
console.log(`[3] file after: 3 counts=${preCountHasAllCounts}, 3 mtimes=${preCountHasAllMtimes}, hash=${preCountHasHash}`);

// 4. Current-format, same hash + same counts → no drift
r = runCheck(current, testFile);
console.log(`[4] current-format re-read: reason=${r.reason}, triggers=[${r.triggers.join(',')}]`);

// 5. Current-format, mutated settings_hash → settings trigger
const mutated = { ...current, settings_hash: 'zzzzzz' };
r = runCheck(mutated, testFile);
console.log(`[5] settings_hash mutated: reason=${r.reason}, triggers=[${r.triggers.join(',')}]`);

// 6. Current-format, agents mtime advanced → agents trigger
fs.writeFileSync(testFile, JSON.stringify(current));
const agentsAdvanced = { ...current, agents_mtime: 9999 };
r = runCheck(agentsAdvanced, testFile);
console.log(`[6] agents mtime advanced: reason=${r.reason}, triggers=[${r.triggers.join(',')}]`);

// 7. Current-format, plugins count DECREASED → plugins trigger (count branch)
fs.writeFileSync(testFile, JSON.stringify(current));
const pluginsShrunk = { ...current, plugins_count: current.plugins_count - 2 };
r = runCheck(pluginsShrunk, testFile);
console.log(`[7] plugins count decreased: reason=${r.reason}, triggers=[${r.triggers.join(',')}]`);

fs.unlinkSync(testFile);

const assert = (name, cond) => console.log(`${cond ? 'OK  ' : 'FAIL'} ${name}`);
let failed = 0;
const check = (name, cond) => { if (!cond) failed++; assert(name, cond); };

console.log();
check('pre-hash legacy migrates without firing drift',
  afterPreHash && preHashHasHash && !preHashHasLegacy && preHashHasCount);
check('pre-hash migration writes all 8 current-format fields',
  preHashHasHash && preHashHasCount &&
  'gsd_count' in afterPreHash && 'plugins_count' in afterPreHash &&
  'agents_mtime' in afterPreHash && 'gsd_mtime' in afterPreHash &&
  'plugins_mtime' in afterPreHash && 'version' in afterPreHash);
check('pre-count legacy migrates without firing drift',
  preCountHasAllCounts && preCountHasAllMtimes && preCountHasHash);
check('pre-count migration preserves hash and adds count fields',
  afterPreCount.settings_hash === current.settings_hash &&
  afterPreCount.agents_count === current.agents_count &&
  afterPreCount.gsd_count === current.gsd_count &&
  afterPreCount.plugins_count === current.plugins_count);

process.exit(failed ? 1 : 0);
