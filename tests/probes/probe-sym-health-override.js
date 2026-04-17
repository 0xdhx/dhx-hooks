#!/usr/bin/env node
// Probe: readHealthCache() split — { front, tail } tiered by operational
// consequence. Validates publisher override, TTL, fallback, and correct tier
// classification across all health classes.

const fs = require('fs');
const os = require('os');
const path = require('path');

const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'probe-sym-'));
const healthFile = path.join(tmpDir, 'health.json');
const symFile = path.join(tmpDir, 'sym-health.json');

function readHealthCache() {
  return new Promise((resolve) => {
    const empty = { front: '', tail: '' };
    fs.readFile(healthFile, 'utf8', (err, data) => {
      if (err) return resolve(empty);
      try {
        const h = JSON.parse(data);
        try {
          const sym = JSON.parse(fs.readFileSync(symFile, 'utf8'));
          const ageMs = Date.now() - Date.parse(sym.checked_at || '');
          if (Number.isFinite(ageMs) && ageMs >= 0 && ageMs < 3600 * 1000 && sym.plugin_keys) {
            h.plugin_keys = sym.plugin_keys;
          }
        } catch { /* defer */ }

        const critical = [];
        if (h.settings_chain && h.settings_chain !== 'ok')
          critical.push(`settings:${h.settings_chain}`);
        if (h.plugin_keys && h.plugin_keys !== 'ok')
          critical.push(`plugin-keys:${h.plugin_keys}`);

        const advisory = [];
        if (h.worktree_patches && h.worktree_patches !== 'patched')
          advisory.push(`patches:${h.worktree_patches}`);
        if (h.read_guard && h.read_guard !== 'patched')
          advisory.push(`read-guard:${h.read_guard}`);
        if (h.missing_symlinks > 0)
          advisory.push(`${h.missing_symlinks} broken symlink${h.missing_symlinks > 1 ? 's' : ''}`);

        const front = critical.length
          ? `\x1b[38;5;208m⚠ ${critical.join(' ')} — /dhx:sym repair\x1b[0m`
          : '';
        const tail = advisory.length
          ? `\x1b[31m⚠ ${advisory.join(' ')} — /dhx:sym repair\x1b[0m`
          : '';
        resolve({ front, tail });
      } catch { resolve(empty); }
    });
  });
}

const iso = (msAgo) => new Date(Date.now() - msAgo).toISOString();
const healthy = { worktree_patches: 'patched', read_guard: 'patched', missing_symlinks: 0, settings_chain: 'ok', plugin_keys: 'ok', checked: 0 };

const scenarios = [
  {
    name: 'healthy → both empty',
    health: healthy,
    sym: { plugin_keys: 'ok', checked_at: iso(60000) },
    expectFront: '',
    expectTail: '',
  },
  {
    name: 'plugin-keys MISSING → front only, orange 208',
    health: { ...healthy, plugin_keys: 'MISSING' },
    sym: null,
    expectFrontContains: ['\x1b[38;5;208m', 'plugin-keys:MISSING', '/dhx:sym repair'],
    expectTail: '',
  },
  {
    name: 'settings REAL_FILE → front only, orange 208',
    health: { ...healthy, settings_chain: 'REAL_FILE' },
    sym: null,
    expectFrontContains: ['\x1b[38;5;208m', 'settings:REAL_FILE'],
    expectTail: '',
  },
  {
    name: 'patches REGRESSED → tail only, red',
    health: { ...healthy, worktree_patches: 'REGRESSED' },
    sym: null,
    expectFront: '',
    expectTailContains: ['\x1b[31m', 'patches:REGRESSED', '/dhx:sym repair'],
  },
  {
    name: 'read-guard REGRESSED → tail only',
    health: { ...healthy, read_guard: 'REGRESSED' },
    sym: null,
    expectFront: '',
    expectTailContains: ['read-guard:REGRESSED'],
  },
  {
    name: 'missing_symlinks=2 → tail only',
    health: { ...healthy, missing_symlinks: 2 },
    sym: null,
    expectFront: '',
    expectTailContains: ['2 broken symlinks'],
  },
  {
    name: 'all 5 wrong → both populated, correct partition',
    health: { worktree_patches: 'REGRESSED', read_guard: 'REGRESSED', missing_symlinks: 1, settings_chain: 'REAL_FILE', plugin_keys: 'MISSING', checked: 0 },
    sym: null,
    expectFrontContains: ['settings:REAL_FILE', 'plugin-keys:MISSING'],
    expectFrontNotContains: ['patches', 'read-guard', 'broken symlink'],
    expectTailContains: ['patches:REGRESSED', 'read-guard:REGRESSED', '1 broken symlink'],
    expectTailNotContains: ['settings:', 'plugin-keys:'],
  },
  {
    name: 'fresh sym override: plugin-keys MISSING (health.json says ok) → front fires',
    health: healthy,
    sym: { plugin_keys: 'MISSING', checked_at: iso(60000) },
    expectFrontContains: ['plugin-keys:MISSING'],
    expectTail: '',
  },
  {
    name: 'fresh sym override: plugin-keys ok (health.json says MISSING) → front clears',
    health: { ...healthy, plugin_keys: 'MISSING' },
    sym: { plugin_keys: 'ok', checked_at: iso(60000) },
    expectFront: '',
    expectTail: '',
  },
  {
    name: 'stale sym (2h), health.json MISSING → publisher ignored, front fires from health.json',
    health: { ...healthy, plugin_keys: 'MISSING' },
    sym: { plugin_keys: 'ok', checked_at: iso(2 * 3600 * 1000) },
    expectFrontContains: ['plugin-keys:MISSING'],
    expectTail: '',
  },
  {
    name: 'single suffix per tier (not per class)',
    health: { worktree_patches: 'REGRESSED', read_guard: 'REGRESSED', missing_symlinks: 3, settings_chain: 'REAL_FILE', plugin_keys: 'MISSING', checked: 0 },
    sym: null,
    expectFrontSuffixCount: 1,
    expectTailSuffixCount: 1,
  },
];

(async () => {
  let pass = 0, fail = 0;
  for (const s of scenarios) {
    fs.writeFileSync(healthFile, JSON.stringify(s.health));
    if (s.sym === null) {
      try { fs.unlinkSync(symFile); } catch {}
    } else if (s.sym !== undefined) {
      fs.writeFileSync(symFile, JSON.stringify(s.sym));
    }

    const { front, tail } = await readHealthCache();
    const fp = front.replace(/\x1b\[[0-9;]*m/g, '');
    const tp = tail.replace(/\x1b\[[0-9;]*m/g, '');

    let ok = true;
    const fails = [];
    if ('expectFront' in s && front !== s.expectFront) { ok = false; fails.push(`front !== "${s.expectFront}", got "${front}"`); }
    if ('expectTail' in s && tail !== s.expectTail) { ok = false; fails.push(`tail !== "${s.expectTail}", got "${tail}"`); }
    if ('expectFrontContains' in s) for (const n of s.expectFrontContains) if (!front.includes(n)) { ok = false; fails.push(`front missing "${n}"`); }
    if ('expectFrontNotContains' in s) for (const n of s.expectFrontNotContains) if (fp.includes(n)) { ok = false; fails.push(`front leaked "${n}"`); }
    if ('expectTailContains' in s) for (const n of s.expectTailContains) if (!tail.includes(n)) { ok = false; fails.push(`tail missing "${n}"`); }
    if ('expectTailNotContains' in s) for (const n of s.expectTailNotContains) if (tp.includes(n)) { ok = false; fails.push(`tail leaked "${n}"`); }
    if ('expectFrontSuffixCount' in s) {
      const n = (fp.match(/\/dhx:sym repair/g) || []).length;
      if (n !== s.expectFrontSuffixCount) { ok = false; fails.push(`front suffix count ${n} !== ${s.expectFrontSuffixCount}`); }
    }
    if ('expectTailSuffixCount' in s) {
      const n = (tp.match(/\/dhx:sym repair/g) || []).length;
      if (n !== s.expectTailSuffixCount) { ok = false; fails.push(`tail suffix count ${n} !== ${s.expectTailSuffixCount}`); }
    }

    console.log(`${ok ? 'PASS' : 'FAIL'}  ${s.name}`);
    if (!ok) fails.forEach(f => console.log(`       ${f}`));
    ok ? pass++ : fail++;
  }
  console.log(`\n${pass}/${pass + fail} passed`);
  try { fs.rmSync(tmpDir, { recursive: true, force: true }); } catch {}
  process.exit(fail === 0 ? 0 : 1);
})();
