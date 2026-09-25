#!/usr/bin/env node
// Probe: dhx-statusline.js resolves the gsd-update cache filename from
// package-identity.cjs (package-namespaced), NOT a hardcoded generic name.
//
// Guards the 2026-06-05 regression: @opengsd/gsd-core@1.3.1 renamed the
// update-check cache from the generic `gsd-update-check.json` to a
// package-namespaced `gsd-update-check-opengsd-gsd-core.json` (written by
// gsd-check-update.js via package-identity.cjs). The renderer hardcoded the
// generic name, so its shared-cache lookup missed and it fell back to a STALE
// legacy profile cache holding pre-migration get-shit-done-cc data
// (update_available:true, 1.30.0→1.42.3) → a false `⬆ /gsd-update` while the
// authoritative checker said no update. The fix requires package-identity by
// ABSOLUTE path (the renderer's realpath is the repo, not ~/.claude) and reads
// the resolved name; require-failure degrades to the generic name for
// backward-compat with pre-namespace checkers.
//
// INVARIANT (cross-process): the renderer's cache filename MUST track the
// checker's package-identity output. A future package rename re-breaks this
// the same silent way if the renderer ever re-hardcodes the name.
//
//
// Run: node tests/probes/probe-gsd-update-cache-name-resolves.js
// SAFE_FOR_LIVE: yes  (each case builds a throwaway mktemp HOME and points the
//   child renderer's HOME + CLAUDE_CONFIG_DIR at it; fixture caches +
//   package-identity stub live ONLY under that temp dir; the live ~/.cache and
//   ~/.claude are never written; child-spawn render is read-only.)
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const REPO_ROOT = path.join(__dirname, '..', '..');
const SCRIPT = path.join(REPO_ROOT, 'dhx', 'dhx-statusline.js');

let pass = 0;
let fail = 0;
function ok(label, cond) {
  if (cond) { console.log('OK   ' + label); pass++; }
  else { console.log('FAIL ' + label); fail++; }
}

const homes = [];
function mkHome() {
  const h = fs.mkdtempSync(path.join(os.tmpdir(), 'dhx-gsdupd-'));
  homes.push(h);
  return h;
}
process.on('exit', () => {
  for (const h of homes) { try { fs.rmSync(h, { recursive: true, force: true }); } catch (e) {} }
});

function writeJson(p, obj) {
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, typeof obj === 'string' ? obj : JSON.stringify(obj));
}

// Stub package-identity.cjs under <home>/gsd-core/bin/lib so the renderer
// (claudeDir = CLAUDE_CONFIG_DIR = home) resolves it by absolute path.
function stubPackageIdentity(home, name) {
  const p = path.join(home, 'gsd-core', 'bin', 'lib', 'package-identity.cjs');
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p,
    'module.exports = Object.freeze({ updateCacheFileName: ' + JSON.stringify(name) +
    ", packageName: '@test/pkg' });\n");
}

function render(home) {
  const fixture = {
    model: { display_name: 'Opus 4.8' },
    workspace: { current_dir: home },
    session_id: 'gsdupd-probe',
  };
  const r = spawnSync(process.execPath, [SCRIPT], {
    input: JSON.stringify(fixture),
    encoding: 'utf8',
    timeout: 5000,
    env: { ...process.env, HOME: home, CLAUDE_CONFIG_DIR: home, DHX_DISABLE_HOOKS: '1' },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  return r.stdout || '';
}

// The token is the only place the literal "/gsd-update" appears in output.
const hasGsdUpdate = out => out.indexOf('/gsd-update') !== -1;

const NS = 'gsd-update-check-test-pkg.json'; // namespaced name the stub returns

// Case 1 — THE regression guard: package-identity resolves to a namespaced
// name; NO namespaced cache exists anywhere; only a STALE GENERIC legacy cache
// (update_available:true) is present. The renderer must look for the namespaced
// name (absent) and NOT read the stale generic → segment hides → no token.
{
  const home = mkHome();
  stubPackageIdentity(home, NS);
  writeJson(path.join(home, 'cache', 'gsd-update-check.json'),
    { update_available: true, installed: '1.30.0', latest: '1.42.3' });
  const out = render(home);
  ok('case1: namespaced resolved + only stale GENERIC legacy(true) → no false ⬆ /gsd-update', !hasGsdUpdate(out));
}

// Case 2 — namespaced shared cache says NO update while a stale generic legacy
// says update: the namespaced (authoritative) read wins → no token.
{
  const home = mkHome();
  stubPackageIdentity(home, NS);
  writeJson(path.join(home, '.cache', 'gsd', NS),
    { update_available: false, installed: '1.3.1', latest: '1.3.1' });
  writeJson(path.join(home, 'cache', 'gsd-update-check.json'),
    { update_available: true, installed: '1.30.0', latest: '1.42.3' });
  const out = render(home);
  ok('case2: namespaced shared(false) wins over stale generic legacy(true) → no token', !hasGsdUpdate(out));
}

// Case 3 — namespaced shared cache says update_available:true → token shows.
{
  const home = mkHome();
  stubPackageIdentity(home, NS);
  writeJson(path.join(home, '.cache', 'gsd', NS),
    { update_available: true, installed: '1.3.0', latest: '1.3.1' });
  const out = render(home);
  ok('case3: namespaced shared(true) → ⬆ /gsd-update shows', hasGsdUpdate(out));
}

// Case 4 — namespaced LEGACY cache only (shared absent) says true: proves the
// legacy fallback path also uses the namespaced name (not the generic).
{
  const home = mkHome();
  stubPackageIdentity(home, NS);
  writeJson(path.join(home, 'cache', NS),
    { update_available: true, installed: '1.3.0', latest: '1.3.1' });
  const out = render(home);
  ok('case4: namespaced legacy(true), shared absent → ⬆ /gsd-update shows', hasGsdUpdate(out));
}

// Case 5 — package-identity ABSENT (require fails) → generic-name fallback;
// a generic shared cache(true) is honored (backward-compat with pre-namespace
// checkers that wrote the generic name). Documents the fallback contract.
{
  const home = mkHome();
  // no package-identity stub → require throws → updateCacheName stays generic
  writeJson(path.join(home, '.cache', 'gsd', 'gsd-update-check.json'),
    { update_available: true, installed: '1.0.0', latest: '1.0.1' });
  const out = render(home);
  ok('case5: no package-identity → generic fallback reads generic shared(true) → ⬆ /gsd-update', hasGsdUpdate(out));
}

console.log('\n' + pass + ' passed, ' + fail + ' failed');
process.exit(fail === 0 ? 0 : 1);
