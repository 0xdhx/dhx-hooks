#!/usr/bin/env node
// Probe: dhx-statusline.js issues ZERO subprocess invocations across 100
// child-spawned renders. Backs decisions.md 2026-05-02 Phase 5 D-03 (retire
// baseline) — STATUS-06 + STATUS-07.
//
// PROBE-01 (2026-04-30 exit 1) showed CC ships effort.level in stdin so
// the renderer no longer needs `tmux capture-pane`. This probe asserts the
// apparatus stays gone — any regression re-introducing a subprocess (tmux,
// git, anything) flips this red on the next run.
//
// Mechanism: Node `--require` preloader (lib/no-subprocess-shim.js) mon-
// keypatches `child_process` to exit-on-call (D-14 wording) BEFORE the
// renderer's own requires resolve. Each render runs in a FRESH child Node
// process (avoids the renderer's 3s `setTimeout(() => process.exit(0))`
// from terminating the test process mid-run; `clearTimeout(stdinTimeout)`
// cancels that timer on stdin-close so children exit promptly). Any
// subprocess attempt → shim calls `process.exit(2)` → child exits non-0
// → probe counts. Child-spawn over in-process require because runStatus-
// line's setTimeout + async stdin listeners are hostile to in-process
// 100× iteration (plan-check 2026-05-02 Dimension 10 BLOCKER). D-12
// single-render benchmark below verifies spawnSync overhead empirically.
//
// Run: node tests/probes/probe-statusline-load.js
// (D-13 fix: NOT `bash ...` — this is a Node script.)
// SAFE_FOR_LIVE: yes  (read-only renderer invocation via child-spawn; child
// stdout captured via stdio:'pipe'; renderer's bridge-file write lands at
// /tmp/claude-ctx-probe-load.json — predictable path, conventional fixture
// per SAFE_FOR_LIVE.md heuristic note on probe-settings-hash.js)

'use strict';

const path = require('path');
const os = require('os');
const { spawnSync } = require('child_process');

// --- Assertion harness (copied from probe-dhx-statusline.js:34-50) ----------

let pass = 0;
let fail = 0;

function ok(label, got, want) {
  if (got === want) { console.log(`OK   ${label}`); pass++; }
  else { console.log(`FAIL ${label}\n  got:  ${JSON.stringify(got)}\n  want: ${JSON.stringify(want)}`); fail++; }
}

const strip = (s) => s.replace(/\x1b\[[0-9;]*m/g, '');

// --- Paths ------------------------------------------------------------------

const REPO_ROOT = path.resolve(__dirname, '..', '..');
const SCRIPT = path.join(REPO_ROOT, 'dhx', 'dhx-statusline.js');
const SHIM = path.join(REPO_ROOT, 'tests', 'probes', 'lib', 'no-subprocess-shim.js');

// --- Fixture ----------------------------------------------------------------

const baseFixture = {
  session_id: 'probe-load',
  model: { display_name: 'Opus 4.7 (1M context)' },
  workspace: { current_dir: os.tmpdir() },
  context_window: { total_tokens: 1_000_000, remaining_percentage: 85 },
  effort: { level: 'xhigh' },
};

// --- Render harness via child-spawn -----------------------------------------
// Fresh child Node per render with the no-subprocess shim preloaded.
// status = 0 → no subprocess attempt; non-0 → shim's process.exit fired.
function renderOnce(fixture, opts = {}) {
  const env = { ...process.env, DHX_DISABLE_HOOKS: '1' }; // defensive
  const result = spawnSync(process.execPath, ['--require', SHIM, SCRIPT], {
    input: JSON.stringify(fixture),
    encoding: 'utf8',
    timeout: opts.timeout || 5000,
    env,
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  return {
    status: result.status,
    stdout: result.stdout || '',
    stderr: result.stderr || '',
    error: result.error,
  };
}

// --- D-12 single-render benchmark (due-diligence; added 2026-05-02 review) ---
// One child render before the 100× loop; fail fast if wall-time >100ms.
// Empirical backstop against per-machine spawnSync variance — surfaces
// regressions before run-probes.sh hits the D-16 30s per-probe budget.

const benchStart = process.hrtime.bigint();
const benchRun = renderOnce(baseFixture);
const benchMs = Number(process.hrtime.bigint() - benchStart) / 1_000_000;
console.log(`bench: single-render wall-time = ${benchMs.toFixed(2)}ms (D-12 due-diligence; budget 100ms)`);
if (benchRun.status !== 0) {
  console.log(`FAIL bench: single-render child exited ${benchRun.status} (expected 0)`);
  console.log(`  stderr (first 200): ${benchRun.stderr.slice(0, 200)}`);
  fail++;
} else if (benchMs > 100) {
  console.log(`FAIL bench: single-render wall-time ${benchMs.toFixed(2)}ms exceeds 100ms budget`);
  console.log(`  100 renders would take ~${(benchMs * 100 / 1000).toFixed(1)}s — risks D-16 30s probe budget`);
  console.log(`  remediation: parallelize children with a bounded pool, OR reduce iteration count, OR investigate why clearTimeout(stdinTimeout) is not firing`);
  fail++;
} else {
  console.log(`OK   bench: single-render under 100ms (D-12 spawnSync overhead verified)`);
  pass++;
}

// --- Test cases -------------------------------------------------------------

// 1. 100× renders, assert all children exit 0 (no subprocess attempt)
const start = process.hrtime.bigint();
let badRenders = 0;
let firstBadStderr = '';
let firstBadStatus = null;
for (let i = 0; i < 100; i++) {
  const r = renderOnce(baseFixture);
  if (r.status !== 0) {
    badRenders++;
    if (!firstBadStderr) { firstBadStderr = r.stderr.slice(0, 200); firstBadStatus = r.status; }
  }
}
const totalMs = Number(process.hrtime.bigint() - start) / 1_000_000;
const medianMs = totalMs / 100;
if (badRenders > 0) {
  // Distinguish exit 2 (subprocess attempt — STATUS-06 regression) from
  // exit 1 (renderer error / syntax error) per Gemini review suggestion.
  console.log(`  first bad child status: ${firstBadStatus} (2=subprocess attempt; 1=renderer error)`);
  console.log(`  first bad child stderr: ${firstBadStderr}`);
}
ok('100 child renders → 0 with non-zero exit (no subprocess attempt)', badRenders, 0);

// 2. Positive assertion: effort.level=xhigh → ⣶ glyph rendered (#21)
const xhighRun = renderOnce({ ...baseFixture, effort: { level: 'xhigh' } });
ok('xhigh child exits 0', xhighRun.status, 0);
ok('effort.level=xhigh → ⣶ glyph rendered', strip(xhighRun.stdout).includes('⣶'), true);

// 3. Malformed-input cases (#22): all children exit 0 AND stdout contains no glyph
const malformedCases = [
  { name: 'level=ultra',     mutate: (f) => { f.effort = { level: 'ultra' }; } },
  { name: 'effort=null',     mutate: (f) => { f.effort = null; } },
  { name: 'effort={}',       mutate: (f) => { f.effort = {}; } },
  { name: 'level=null',      mutate: (f) => { f.effort = { level: null }; } },
  { name: 'no effort key',   mutate: (f) => { delete f.effort; } },
];
for (const c of malformedCases) {
  const f = JSON.parse(JSON.stringify(baseFixture));
  c.mutate(f);
  const r = renderOnce(f);
  const hasGlyph = /[⡀⣀⣤⣶⣿]/.test(strip(r.stdout));
  // Combined assertion: child exits 0 AND no glyph rendered
  ok(`malformed ${c.name} → exit 0, no glyph`, r.status === 0 && !hasGlyph, true);
}

// 4. Wall-time emission (informational only — D-03/D-06 lock; NO hard threshold)
console.log();
console.log(`info: median wall-time per render = ${medianMs.toFixed(2)}ms (informational; no gate)`);
console.log(`info: total wall-time for 100 renders = ${totalMs.toFixed(2)}ms`);
console.log();
console.log(`${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
