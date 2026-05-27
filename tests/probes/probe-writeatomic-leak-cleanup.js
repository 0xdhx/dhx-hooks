#!/usr/bin/env node
// Probe: exercises the IN-03 writeAtomic() helper in dhx/statusline-wrapper.js.
// writeAtomic centralizes the `.tmp.<pid>` atomic write (write tmp → rename onto
// target) + the leaked-tmp cleanup that the six former open-coded sites in
// checkDrift each reconstructed (or, at three sites, omitted entirely).
//
// The load-bearing invariant this probe guards: when renameSync throws AFTER a
// successful writeFileSync, the per-pid tmp sibling MUST be unlinked — no leak.
// Because the helper computes `tmp` once and reuses it for both write and unlink,
// write/cleanup can never disagree on the path (the divergence the Phase 18
// review flagged at the cc-novel site). This probe drives the REAL exported
// helper (not a reimplementation) under a mocked fs.renameSync so the assertion
// fails red if a future edit drops the catch-block unlink or re-introduces a
// path-reconstruction divergence.
//
// Run: node tests/probes/probe-writeatomic-leak-cleanup.js
//
// Backs:
//   - docs/decisions.md — 2026-05-21 IN-03 atomic-write consolidation row
//   - Phase 18 18-REVIEW.md finding IN-03 (write-path tmp-leak fragility)
//
// SAFE_FOR_LIVE: yes   (mkdtempSync fixtures + require of live wrapper; mocks
//   fs.renameSync then restores it; no live ~/.cache/dhx or ~/.claude writes)

const fs = require('fs');
const os = require('os');
const path = require('path');

const { writeAtomic } = require('../../dhx/statusline-wrapper.js');

const results = [];
const assert = (name, cond) => {
  results.push({ name, ok: !!cond });
  console.log(`${cond ? 'OK  ' : 'FAIL'} ${name}`);
};

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'probe-writeatomic-'));

function tmpSibling(target) {
  return target + '.tmp.' + process.pid;
}

// --- Positive control: happy-path write leaves target, no tmp sibling ---
{
  const target = path.join(dir, 'happy.json');
  const obj = { a: 1, nested: { b: [2, 3] } };
  let threw = false;
  try { writeAtomic(target, obj); } catch { threw = true; }

  assert('[1a] happy path does not throw', !threw);
  assert('[1b] target file exists after write', fs.existsSync(target));
  assert('[1c] target content is exact JSON.stringify (no pretty-print)',
    fs.existsSync(target) && fs.readFileSync(target, 'utf8') === JSON.stringify(obj));
  assert('[1d] no leaked .tmp.<pid> sibling on success', !fs.existsSync(tmpSibling(target)));
}

// --- Forced rename failure: tmp written, rename throws → tmp MUST be cleaned ---
{
  const target = path.join(dir, 'fail.json');
  const realRename = fs.renameSync;
  let threw = false;
  let renameWasCalled = false;
  // Mock at call time — the wrapper invokes fs.renameSync (property access on the
  // shared module object), so patching the property reaches the helper too.
  fs.renameSync = () => { renameWasCalled = true; throw new Error('induced ENOSPC'); };
  try {
    try { writeAtomic(target, { will: 'leak?' }); }
    catch { threw = true; }
  } finally {
    fs.renameSync = realRename; // restore before any assertion can early-exit
  }

  assert('[2a] renameSync was actually exercised (mock fired)', renameWasCalled);
  assert('[2b] writeAtomic re-throws the rename failure (caller skip-on-failure preserved)', threw);
  assert('[2c] NO leaked .tmp.<pid> sibling after forced rename failure', !fs.existsSync(tmpSibling(target)));
  assert('[2d] target NOT created when rename failed', !fs.existsSync(target));
}

// --- Cleanup ---
try { fs.rmSync(dir, { recursive: true, force: true }); } catch { /* best-effort */ }

const passed = results.filter(r => r.ok).length;
const failed = results.length - passed;
console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
