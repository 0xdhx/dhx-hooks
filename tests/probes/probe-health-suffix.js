#!/usr/bin/env node
// Exercises statusline-wrapper's readHealthCache() against fixture health.json
// files by spawning the wrapper with HOME pointed at a temp dir. Verifies:
//   - healthy cache → no warning
//   - each warning class → correct token + ` — /dhx:sym repair` suffix in its tier
//   - all-five → one suffix per tier (critical + advisory), tokens split correctly
// Side-effects on real $HOME are zero — each spawn runs in an isolated tmpdir.
//
// Backs docs/decisions.md 2026-04-16 actionable-hints row + 2026-04-17 critical/
// advisory split row. sym-health.json precedence lives in
// probe-sym-health-override.js — this file stays scoped to warning-format contract.
// Run: node tests/probes/probe-health-suffix.js

const { spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const WRAPPER = path.resolve(__dirname, '..', '..', 'dhx', 'statusline-wrapper.js');
// Fake-$HOME setup centralized in _make-fake-home.js — see that module's
// header for the wrapper require-boundary rationale (2026-04-28 commit
// 30893e3 + same-day silent-red repair + centralization rows).
const { makeFakeHome } = require('./_make-fake-home');
const SUFFIX_REGEX = /— \/dhx:sym repair/g;

function runWith(healthJson) {
  const tmp = makeFakeHome('dhx-probe-');
  try {
    if (healthJson !== null) {
      fs.writeFileSync(path.join(tmp, '.cache', 'dhx', 'health.json'), healthJson);
    }
    const res = spawnSync(process.execPath, [WRAPPER], {
      input: JSON.stringify({ session_id: 'probe-suffix', version: '2.1.112' }),
      env: { ...process.env, HOME: tmp, CLAUDE_CONFIG_DIR: path.join(tmp, '.claude') },
      encoding: 'utf8',
      timeout: 5000,
    });
    return res.stdout || '';
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

const cases = [
  { name: 'healthy (all ok)',
    cache: { worktree_patches: 'patched', read_guard: 'patched', missing_symlinks: 0, settings_chain: 'ok', plugin_keys: 'ok', checked: 0 },
    expectSuffix: 0, expectTokens: [] },
  { name: 'plugin-keys MISSING',
    cache: { worktree_patches: 'patched', read_guard: 'patched', missing_symlinks: 0, settings_chain: 'ok', plugin_keys: 'MISSING', checked: 0 },
    expectSuffix: 1, expectTokens: ['plugin-keys:MISSING'] },
  { name: 'settings chain REAL_FILE',
    cache: { worktree_patches: 'patched', read_guard: 'patched', missing_symlinks: 0, settings_chain: 'REAL_FILE', plugin_keys: 'ok', checked: 0 },
    expectSuffix: 1, expectTokens: ['settings:REAL_FILE'] },
  { name: 'worktree patches REGRESSED',
    cache: { worktree_patches: 'REGRESSED', read_guard: 'patched', missing_symlinks: 0, settings_chain: 'ok', plugin_keys: 'ok', checked: 0 },
    expectSuffix: 1, expectTokens: ['patches:REGRESSED'] },
  { name: 'read-guard REGRESSED',
    cache: { worktree_patches: 'patched', read_guard: 'REGRESSED', missing_symlinks: 0, settings_chain: 'ok', plugin_keys: 'ok', checked: 0 },
    expectSuffix: 1, expectTokens: ['read-guard:REGRESSED'] },
  { name: 'missing symlinks (2)',
    cache: { worktree_patches: 'patched', read_guard: 'patched', missing_symlinks: 2, settings_chain: 'ok', plugin_keys: 'ok', checked: 0 },
    expectSuffix: 1, expectTokens: ['2 broken symlinks'] },
  { name: 'all five classes at once (front+tail — 2 suffixes, one per tier)',
    cache: { worktree_patches: 'REGRESSED', read_guard: 'REGRESSED', missing_symlinks: 3, settings_chain: 'WRONG_TARGET', plugin_keys: 'MISSING', checked: 0 },
    expectSuffix: 2, expectTokens: ['patches:REGRESSED', 'read-guard:REGRESSED', '3 broken symlinks', 'settings:WRONG_TARGET', 'plugin-keys:MISSING'] },
  { name: 'legacy schema (no plugin_keys field)',
    cache: { worktree_patches: 'patched', read_guard: 'patched', missing_symlinks: 0, settings_chain: 'ok', checked: 0 },
    expectSuffix: 0, expectTokens: [] },
  { name: 'missing cache file',
    raw: null, expectSuffix: 0, expectTokens: [] },
];

let pass = 0, fail = 0;
for (const c of cases) {
  const cacheStr = c.raw === null ? null : JSON.stringify(c.cache);
  const out = runWith(cacheStr);
  const suffixes = (out.match(SUFFIX_REGEX) || []).length;
  const tokensOk = c.expectTokens.every(t => out.includes(t));
  const ok = suffixes === c.expectSuffix && tokensOk;
  if (ok) {
    console.log(`  \u2713 ${c.name} (suffixes=${suffixes}, tokens match)`);
    pass++;
  } else {
    console.log(`  \u2717 ${c.name}`);
    console.log(`      expected suffix count: ${c.expectSuffix}, got: ${suffixes}`);
    console.log(`      expected tokens: ${JSON.stringify(c.expectTokens)}`);
    console.log(`      output: ${JSON.stringify(out)}`);
    fail++;
  }
}

console.log('---');
console.log(`PASS: ${pass}  FAIL: ${fail}`);
process.exit(fail);
