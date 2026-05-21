#!/usr/bin/env node
// Probe: exercises the shared plugin-cache allowlist module
// (scripts/lib/plugin-cache-allowlist.js) — the D-06 + D-14 consolidation.
//
// Backs: 17-01-PLAN.md Task 1 (RAT-04 allowlist). The module is the single
// source of truth for "is this plugins/cache leaf basename / path segment a
// known-safe pattern, or a novel hit worth surfacing?" — consumed by the
// wrapper (enumeration) and by the renderer (Plan 03 render-time re-filter).
//
// Run: node tests/probes/probe-plugin-cache-allowlist.js
//
// Strategy: pure-unit assertions against the module's exported predicate +
// the PLUGIN_CACHE_ALLOWLIST structure. No fs, no subprocess — the module
// itself is pure JS (D-12), so the probe is too.

'use strict';
const path = require('path');

const REPO_ROOT = path.join(__dirname, '..', '..');
const MOD = path.join(REPO_ROOT, 'scripts', 'lib', 'plugin-cache-allowlist.js');

let PASS = 0;
let FAIL = 0;
function ok(name, cond) {
  if (cond) { console.log(`OK   ${name}`); PASS++; }
  else { console.log(`FAIL ${name}`); FAIL++; }
}

const mod = require(MOD);
const A = mod.PLUGIN_CACHE_ALLOWLIST;
const isAllowlisted = mod.isAllowlisted;

// ---- structural shape ----
ok('[shape] isAllowlisted is a function', typeof isAllowlisted === 'function');
ok('[shape] PLUGIN_CACHE_ALLOWLIST is an object', A && typeof A === 'object');
ok('[shape] bookkeepingBasenames is a Set', A.bookkeepingBasenames instanceof Set);
ok('[shape] bookkeepingPathPattern is a RegExp', A.bookkeepingPathPattern instanceof RegExp);
ok('[shape] legitContentBasenames is a Set', A.legitContentBasenames instanceof Set);
ok('[shape] legitContentSegments is a Set', A.legitContentSegments instanceof Set);
ok('[shape] versionDirPattern is a RegExp', A.versionDirPattern instanceof RegExp);
ok('[shape] marketplaceTopLevel is a Set', A.marketplaceTopLevel instanceof Set);

// ---- bookkeeping basename allowlisted ----
ok('[bookkeeping basename] .orphaned_at is allowlisted',
  isAllowlisted('anthropic-agent-skills/p/abc123def456/.orphaned_at', '.orphaned_at'));

// ---- bookkeeping path segment allowlisted ----
ok('[bookkeeping segment] temp_git_* path is allowlisted',
  isAllowlisted('temp_git_1700000000_abc/foo.bin', 'foo.bin'));
ok('[bookkeeping segment] .in_use path is allowlisted',
  isAllowlisted('anthropic-agent-skills/p/.in_use/12345', '12345'));

// ---- git-hash directory segment allowlisted via versionDirPattern ----
ok('[git-hash dir] 12-hex git-hash dir is allowlisted',
  isAllowlisted('anthropic-agent-skills/document-skills/690f15cac7f7/README.md', 'README.md'));

// ---- dotted-semver version directory allowlisted ----
ok('[version dir] 1.0.0 is allowlisted',
  isAllowlisted('dhx-local/dhx/1.0.0/plugin.json', 'plugin.json'));
ok('[version dir] v2.1.146 is allowlisted',
  isAllowlisted('dhx-local/dhx/v2.1.146/plugin.json', 'plugin.json'));

// ---- D-16: prerelease/canary version directory allowlisted ----
ok('[D-16 canary] versionDirPattern matches 2.1.146-canary.2',
  A.versionDirPattern.test('2.1.146-canary.2'));
ok('[D-16 beta] versionDirPattern matches 1.0.0-beta.1',
  A.versionDirPattern.test('1.0.0-beta.1'));
ok('[D-16 canary] canary version dir is allowlisted via isAllowlisted',
  isAllowlisted('claude-plugins-official/p/2.1.146-canary.2/plugin.json', 'plugin.json'));

// ---- known leaf files allowlisted ----
for (const leaf of ['plugin.json', 'README.md', 'THIRD_PARTY_NOTICES.md', 'LICENSE.txt', 'SKILL.md', '.gitignore']) {
  ok(`[leaf] ${leaf} is allowlisted`,
    isAllowlisted(`dhx-local/dhx/1.0.0/${leaf}`, leaf));
}

// ---- known directory segments allowlisted ----
for (const seg of ['skills', 'spec', 'template', 'templates', 'canvas-fonts', '.claude-plugin']) {
  ok(`[segment] ${seg}/ is allowlisted`,
    isAllowlisted(`dhx-local/dhx/1.0.0/${seg}/inner.md`, 'inner.md'));
}

// ---- the three seeded marketplaces allowlisted ----
for (const mp of ['anthropic-agent-skills', 'claude-plugins-official', 'dhx-local']) {
  ok(`[marketplace] seeded ${mp} is allowlisted`,
    isAllowlisted(`${mp}/some-plugin/1.0.0/plugin.json`, 'plugin.json'));
}

// ---- D-15: unknown 4th marketplace surfaces as novel ----
ok('[D-15] unknown marketplace mystery-marketplace is NOT allowlisted',
  isAllowlisted('mystery-marketplace/foo/1.0.0/x.md', 'x.md') === false);

// ---- novel basename surfaces ----
ok('[novel basename] mystery-manifest.bin is NOT allowlisted',
  isAllowlisted('anthropic-agent-skills/p/1.0.0/mystery-manifest.bin', 'mystery-manifest.bin') === false);

// ---- novel path segment surfaces ----
ok('[novel segment] weird-new-dir is NOT allowlisted',
  isAllowlisted('anthropic-agent-skills/p/1.0.0/weird-new-dir/inner.md', 'inner.md') === false);

console.log('---');
console.log(`${PASS} passed, ${FAIL} failed`);
process.exit(FAIL > 0 ? 1 : 0);
