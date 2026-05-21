#!/usr/bin/env node
// SAFE_FOR_LIVE: yes   (mkdtempSync fixture trees + require() of the live wrapper module with explicit fixture-root arg; no live ~/.claude or ~/.cache/dhx access)
// Probe: exercises enumerateNovelPatterns + the scanRecursive export added to
// dhx/statusline-wrapper.js by Plan 17-01 Task 2 (RAT-04 enumeration helper).
//
// Backs: 17-01-PLAN.md Task 2. Asserts the helper enumerates plugins/cache
// leaf basenames + path segments against the shared isAllowlisted predicate,
// returns novel hits as {path, basename, first_seen_mtime}, and that BOTH
// enumerateNovelPatterns AND scanRecursive (D-20) are in module.exports.
//
// Run: node tests/probes/probe-enumerate-novel-patterns.js

'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');

const REPO_ROOT = path.join(__dirname, '..', '..');
const WRAPPER = path.join(REPO_ROOT, 'dhx', 'statusline-wrapper.js');

let PASS = 0;
let FAIL = 0;
function ok(name, cond) {
  if (cond) { console.log(`OK   ${name}`); PASS++; }
  else { console.log(`FAIL ${name}`); FAIL++; }
}

const m = require(WRAPPER);

// ---- exports ----
ok('[export] enumerateNovelPatterns is a function', typeof m.enumerateNovelPatterns === 'function');
ok('[export] scanRecursive is a function (D-20)', typeof m.scanRecursive === 'function');

// fixture helper: builds a plugins/cache tree under a fresh mkdtemp dir
function mkTree(spec) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'rat04-'));
  for (const rel of spec) {
    const full = path.join(root, rel);
    fs.mkdirSync(path.dirname(full), { recursive: true });
    fs.writeFileSync(full, 'x');
  }
  return root;
}

// ---- allowlisted-only → empty ----
{
  const root = mkTree([
    'anthropic-agent-skills/document-skills/690f15cac7f7/README.md',
    'anthropic-agent-skills/document-skills/690f15cac7f7/plugin.json',
    'anthropic-agent-skills/document-skills/690f15cac7f7/skills/SKILL.md',
  ]);
  const res = m.enumerateNovelPatterns(root);
  ok('[allowlisted-only] returns empty array', Array.isArray(res) && res.length === 0);
  fs.rmSync(root, { recursive: true, force: true });
}

// ---- novel basename → surfaces with path + basename ----
{
  const root = mkTree([
    'anthropic-agent-skills/document-skills/690f15cac7f7/README.md',
    'anthropic-agent-skills/document-skills/690f15cac7f7/mystery-manifest.bin',
  ]);
  const res = m.enumerateNovelPatterns(root);
  const hit = res.find(r => r.basename === 'mystery-manifest.bin');
  ok('[novel basename] mystery-manifest.bin surfaces', !!hit);
  ok('[novel basename] hit carries a path', !!hit && typeof hit.path === 'string' && hit.path.length > 0);
  ok('[novel basename] hit carries first_seen_mtime (number)',
    !!hit && typeof hit.first_seen_mtime === 'number');
  fs.rmSync(root, { recursive: true, force: true });
}

// ---- novel intermediate segment → surfaces ----
{
  const root = mkTree([
    'anthropic-agent-skills/document-skills/690f15cac7f7/weird-new-dir/inner.md',
  ]);
  const res = m.enumerateNovelPatterns(root);
  ok('[novel segment] weird-new-dir surfaces ≥1 novel', res.length >= 1);
  fs.rmSync(root, { recursive: true, force: true });
}

// ---- unknown 4th marketplace → surfaces (D-15) ----
{
  const root = mkTree([
    'anthropic-agent-skills/p/690f15cac7f7/README.md',
    'mystery-marketplace/p/1.0.0/x.md',
  ]);
  const res = m.enumerateNovelPatterns(root);
  ok('[D-15] unknown 4th marketplace surfaces ≥1 novel', res.length >= 1);
  fs.rmSync(root, { recursive: true, force: true });
}

// ---- unreadable root → empty (graceful) ----
{
  const res = m.enumerateNovelPatterns(path.join(os.tmpdir(), 'rat04-does-not-exist-' + process.pid));
  ok('[graceful] missing root → empty array', Array.isArray(res) && res.length === 0);
}

console.log('---');
console.log(`${PASS} passed, ${FAIL} failed`);
process.exit(FAIL > 0 ? 1 : 0);
