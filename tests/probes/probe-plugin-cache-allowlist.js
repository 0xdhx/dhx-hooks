#!/usr/bin/env node
// SAFE_FOR_LIVE: yes   (pure-unit: require()s the shared module + asserts; no fs, no subprocess, no live mutation)
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
const classifyEntry = mod.classifyEntry;

// ---- structural shape ----
ok('[shape] isAllowlisted is a function', typeof isAllowlisted === 'function');
ok('[shape] classifyEntry is a function', typeof classifyEntry === 'function');
ok('[shape] gitInternalsPathPattern is a RegExp', A.gitInternalsPathPattern instanceof RegExp);
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
// `legitContentSegments` recognizes the DIRECTORY segment. Under the Phase 18
// D-24d leaf rule the leaf basename no longer has to be in
// `legitContentBasenames` — once the intermediate segment is recognized, an
// arbitrary leaf classifies `content` (see the [leaf] block below). Here the
// leaf is still a known legit leaf (SKILL.md) — recognized either way.
for (const seg of ['skills', 'spec', 'template', 'templates', 'canvas-fonts', '.claude-plugin']) {
  ok(`[segment] ${seg}/ directory segment is recognized`,
    isAllowlisted(`dhx-local/dhx/1.0.0/${seg}/SKILL.md`, 'SKILL.md'));
}

// ---- D-24d leaf rule: an arbitrary leaf inside a RECOGNIZED segment is now
//      content (Phase 18 behavior change — pre-Phase-18 this was novel) ----
// This assertion was inverted by the D-24d leaf rule: `skills/` is a recognized
// intermediate segment, so `mystery.bin` (the leaf) classifies `content`, NOT
// `novel`. This is the intended 39.1%-gap fix (RESEARCH.md FINDING-1) — trust
// is scoped to recognized ancestry, not a leaf-basename allowlist. The novel
// signal now lives on UNRECOGNIZED INTERMEDIATE segments (see the [leaf] novel
// boundary assertion below), not on arbitrary leaf basenames.
ok('[D-24d leaf] arbitrary leaf under recognized segment skills/ is allowlisted (content)',
  isAllowlisted('dhx-local/dhx/1.0.0/skills/mystery.bin', 'mystery.bin') === true);

// ---- the three seeded marketplaces allowlisted ----
for (const mp of ['anthropic-agent-skills', 'claude-plugins-official', 'dhx-local']) {
  ok(`[marketplace] seeded ${mp} is allowlisted`,
    isAllowlisted(`${mp}/some-plugin/1.0.0/plugin.json`, 'plugin.json'));
}

// ---- D-15: unknown 4th marketplace surfaces as novel ----
ok('[D-15] unknown marketplace mystery-marketplace is NOT allowlisted',
  isAllowlisted('mystery-marketplace/foo/1.0.0/x.md', 'x.md') === false);

// ---- D-24d: a leaf basename directly under a recognized version dir is now
//      content (Phase 18 behavior change — pre-Phase-18 an unknown leaf
//      basename here was novel) ----
// `anthropic-agent-skills/p/1.0.0/mystery-manifest.bin`: marketplace + plugin +
// `1.0.0` (recognized version-dir intermediate) all pass, so the leaf
// classifies `content` under the D-24d leaf rule. The novel signal moved to
// unrecognized INTERMEDIATE segments — see [novel segment] below.
ok('[D-24d leaf] arbitrary leaf under recognized version dir is allowlisted (content)',
  isAllowlisted('anthropic-agent-skills/p/1.0.0/mystery-manifest.bin', 'mystery-manifest.bin') === true);

// ---- novel path segment surfaces (unrecognized INTERMEDIATE → novel) ----
// `weird-new-dir` is an unrecognized INTERMEDIATE segment (NOT the leaf —
// `inner.md` is the leaf), so the entry classifies novel. This is the intended
// post-D-24d signal: novel fires on a new structural class, not a leaf name.
ok('[novel segment] weird-new-dir is NOT allowlisted',
  isAllowlisted('anthropic-agent-skills/p/1.0.0/weird-new-dir/inner.md', 'inner.md') === false);

// ============================================================================
// Phase 18 — classifyEntry 3-state primitive (D-02) + D-24d leaf rule
// ============================================================================

// ---- [classify] all three states explicitly (D-02 SC2 3-state model) ----
// bookkeeping (silent pass)
ok('[classify] .orphaned_at basename -> bookkeeping',
  classifyEntry('anthropic-agent-skills/p/abc12345/.orphaned_at', '.orphaned_at') === 'bookkeeping');
ok('[classify] temp_git_* path -> bookkeeping',
  classifyEntry('claude-plugins-official/p/temp_git_1700000000_abc/x.bin', 'x.bin') === 'bookkeeping');
ok('[classify] .in_use path -> bookkeeping',
  classifyEntry('anthropic-agent-skills/p/.in_use/12345', '12345') === 'bookkeeping');
ok('[classify] .git/ internals path -> bookkeeping (separator-agnostic D-26)',
  classifyEntry('claude-plugins-official/superpowers/5.0.7/.git/HEAD', 'HEAD') === 'bookkeeping');
ok('[classify] .git/objects bare-hex object hash -> bookkeeping (not leaf-trusted)',
  classifyEntry('claude-plugins-official/superpowers/5.0.7/.git/objects/10/99984abcdef0123456789abcdef0123456789ab', '99984abcdef0123456789abcdef0123456789ab') === 'bookkeeping');
// content (fires drift)
ok('[classify] plugin.json under known marketplace -> content',
  classifyEntry('dhx-local/dhx/1.0.0/plugin.json', 'plugin.json') === 'content');
ok('[classify] file under widened office/ segment -> content',
  classifyEntry('claude-plugins-official/document-skills/1.0.0/office/word.xml', 'word.xml') === 'content');
ok('[classify] file under widened schemas/ segment -> content',
  classifyEntry('claude-plugins-official/document-skills/1.0.0/schemas/a.xsd', 'a.xsd') === 'content');
// novel (routes to novel-pattern detector)
ok('[classify] unknown 4th marketplace -> novel (D-15)',
  classifyEntry('mystery-marketplace/foo/1.0.0/x.md', 'x.md') === 'novel');
ok('[classify] unrecognized INTERMEDIATE segment -> novel',
  classifyEntry('claude-plugins-official/p/1.0.0/weird-intermediate/x.bin', 'x.bin') === 'novel');

// ---- [CR-01 / WR-02] D-15 marketplace gate must NOT be bypassed by the
//      legitContentBasenames fast-path (260521-tj5) -------------------------
// WR-02 surfaced that the prior D-15 assertions only used non-allowlisted leaf
// basenames (x.md), so they exercised the segment-0 gate via leaves that never
// hit the fast-content short-circuit — passing even though CR-01 was present. A
// brand-new marketplace's plugin.json (the realistic case — every plugin ships
// one) was never tested. These assertions FAIL on the pre-CR-01 code (legit
// basename under an unknown marketplace returned 'content') and PASS after the
// SEG0-GATED guard. plugin.json / README.md / LICENSE under an unknown
// marketplace are the D-15 novel signal, not 'content'.
ok('[CR-01] plugin.json under UNKNOWN marketplace -> novel (gate not bypassed)',
  classifyEntry('mystery-marketplace/foo/1.0.0/plugin.json', 'plugin.json') === 'novel');
ok('[CR-01] README.md under UNKNOWN marketplace -> novel (gate not bypassed)',
  classifyEntry('mystery-marketplace/foo/1.0.0/README.md', 'README.md') === 'novel');
ok('[CR-01] LICENSE under UNKNOWN marketplace -> novel (gate not bypassed)',
  classifyEntry('totally-fake-mp/x/y/z/q/LICENSE', 'LICENSE') === 'novel');
// CR-01 REGRESSION GUARD: a legit basename under a KNOWN marketplace (even with
// an unrecognized intermediate ancestor) must still classify 'content' — the
// SEG0-GATED guard only fires the gate on an unrecognized segment 0, it does NOT
// re-open the 39.1%-gap fix. This is the single most important check.
ok('[CR-01 guard] package.json under KNOWN mp + weird intermediate stays content',
  classifyEntry('claude-plugins-official/superpowers/5.0.7/weird-intermediate/package.json', 'package.json') === 'content');
ok('[CR-01 guard] plugin.json under KNOWN marketplace stays content',
  classifyEntry('dhx-local/dhx/1.0.0/plugin.json', 'plugin.json') === 'content');

// ---- [leaf] the D-24d leaf rule — the test-time proof the 39.1% gap closes --
// An arbitrary leaf basename under FULLY-RECOGNIZED intermediate ancestry
// classifies `content` (NOT requiring the basename in legitContentBasenames).
ok('[leaf] office/index.js (arbitrary leaf under recognized ancestry) -> content',
  classifyEntry('claude-plugins-official/document-skills/1.0.0/office/index.js', 'index.js') === 'content');
ok('[leaf] schemas/docx/a.xsd (the codex-flagged .xsd case) -> content',
  classifyEntry('claude-plugins-official/document-skills/1.0.0/schemas/docx/a.xsd', 'a.xsd') === 'content');
ok('[leaf] scripts/build.sh (arbitrary leaf under recognized ancestry) -> content',
  classifyEntry('claude-plugins-official/superpowers/5.0.7/scripts/build.sh', 'build.sh') === 'content');
ok('[leaf] helper.py under recognized python/ segment -> content',
  classifyEntry('dhx-local/dhx/1.0.0/python/helper.py', 'helper.py') === 'content');
// The novel boundary: an UNRECOGNIZED intermediate still classifies novel — the
// leaf rule does NOT loosen the intermediate-segment requirement.
ok('[leaf] unrecognized intermediate segment -> novel (boundary holds)',
  classifyEntry('claude-plugins-official/p/1.0.0/weird-intermediate/x.bin', 'x.bin') === 'novel');

// ---- [WR-01] generic plugin sub-tree segments classify content (260521-tj5) --
// A leaf under each newly-widened generic segment classifies `content`, not
// `novel` — so a real plugin file changed under one of these during a no-version-
// change session fires `⚠ restart plugins` (closes the WR-01 drift false-negative).
for (const seg of ['src', 'lib', 'dist', 'bin', 'config']) {
  ok(`[WR-01] leaf under widened ${seg}/ segment -> content`,
    classifyEntry(`claude-plugins-official/superpowers/5.0.7/${seg}/foo.js`, 'foo.js') === 'content');
}
// node_modules is DELIBERATELY EXCLUDED (deps churn would flood drift) — a leaf
// under it stays `novel` and surfaces via `⚠ cc-novel` for triage.
ok('[WR-01] node_modules leaf stays novel (deliberately excluded)',
  classifyEntry('claude-plugins-official/superpowers/5.0.7/node_modules/lodash/index.js', 'index.js') === 'novel');

// ---- [V5] totality — classifyEntry never throws, always returns a state ----
for (const [p, b] of [[null, null], ['', ''], [undefined, undefined], [123, 456], ['/', '/']]) {
  let state, threw = false;
  try { state = classifyEntry(p, b); } catch (e) { threw = true; }
  ok(`[V5] classifyEntry(${JSON.stringify(p)},${JSON.stringify(b)}) returns a state without throwing`,
    !threw && ['bookkeeping', 'content', 'novel'].includes(state));
}

// ---- [equiv] D-02 derived-wrapper equivalence: isAllowlisted === !novel ----
// For every (filePath, basename) tuple covering the branch space, assert the
// derived wrapper reproduces (classifyEntry !== 'novel'). This is the
// structural guarantee against divergence (D-02). Tuples reflect POST-Phase-18
// behavior (the D-24d leaf rule is in effect for both functions).
const equivTuples = [
  ['anthropic-agent-skills/p/abc123def456/.orphaned_at', '.orphaned_at'],
  ['temp_git_1700000000_abc/foo.bin', 'foo.bin'],
  ['anthropic-agent-skills/p/.in_use/12345', '12345'],
  ['claude-plugins-official/superpowers/5.0.7/.git/HEAD', 'HEAD'],
  ['anthropic-agent-skills/document-skills/690f15cac7f7/README.md', 'README.md'],
  ['dhx-local/dhx/1.0.0/plugin.json', 'plugin.json'],
  ['dhx-local/dhx/v2.1.146/plugin.json', 'plugin.json'],
  ['claude-plugins-official/p/2.1.146-canary.2/plugin.json', 'plugin.json'],
  ['dhx-local/dhx/1.0.0/skills/SKILL.md', 'SKILL.md'],
  ['dhx-local/dhx/1.0.0/skills/mystery.bin', 'mystery.bin'],
  ['claude-plugins-official/document-skills/1.0.0/office/index.js', 'index.js'],
  ['claude-plugins-official/document-skills/1.0.0/schemas/docx/a.xsd', 'a.xsd'],
  ['mystery-marketplace/foo/1.0.0/x.md', 'x.md'],
  ['anthropic-agent-skills/p/1.0.0/weird-new-dir/inner.md', 'inner.md'],
  ['claude-plugins-official/p/1.0.0/weird-intermediate/x.bin', 'x.bin'],
  ['', ''],
  [null, null],
];
for (const [p, b] of equivTuples) {
  ok(`[equiv] (classifyEntry !== 'novel') === isAllowlisted for ${JSON.stringify(p)}`,
    (classifyEntry(p, b) !== 'novel') === isAllowlisted(p, b));
}

console.log('---');
console.log(`${PASS} passed, ${FAIL} failed`);
process.exit(FAIL > 0 ? 1 : 0);
