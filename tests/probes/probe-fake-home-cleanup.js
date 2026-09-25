'use strict';
// probe-fake-home-cleanup.js — _make-fake-home.js removes every fake $HOME it
// hands out, including on signal, and honours the DHX_KEEP_FAKE_HOME escape hatch.
//
// INVARIANT: allocation and cleanup live together. `makeFakeHome()` mkdtemps a tree
// under os.tmpdir(); the module registers each one and removes it on process exit, so
// a caller cannot leak by forgetting to write a `finally`.
//
// SILENT one, which is why it is worth a probe rather than a code review note:
// probe-statusline-self-diag.js allocated five fake homes per run and removed none,
// leaving 41 `selfdiag-*` trees in /tmp — while reporting rc 0, PASS. Nothing about a
// green suite surfaces it; only counting /tmp does. Measured 2026-08-15, fixed the
// same day by moving cleanup into the helper.
//
// Note the assertion set is deliberately two-sided. "The directory is gone afterwards"
// alone would also pass if makeFakeHome had silently stopped creating anything, so
// [1] pins that the tree really exists DURING the run and [4] pins that disabling
// cleanup brings the leak back — together they prove cleanup is what removes it.
//
// SAFE_FOR_LIVE: yes   (writes only under os.tmpdir(): fake homes built by the helper
//                       itself plus one relay file, all removed by this probe. Never
//                       touches the live repo, ~/.claude, ~/.cache/dhx, or ~/.ccs.)
//
// Run: node tests/probes/probe-fake-home-cleanup.js

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const HELPER = path.resolve(__dirname, '_make-fake-home.js');
let pass = 0, fail = 0;
const ok  = (m) => { pass++; console.log(`OK   ${m}`); };
const bad = (m) => { fail++; console.log(`FAIL ${m}`); };

// Run node with an inline script that requires the helper. Returns trimmed stdout.
function child(code, env) {
  const res = spawnSync(process.execPath, ['-e', code], {
    encoding: 'utf8',
    env: { ...process.env, HELPER, ...(env || {}) },
    timeout: 30000,
  });
  return { out: (res.stdout || '').trim(), status: res.status, err: res.stderr || '' };
}

// ── [1] the tree exists during the run, and is gone after ────────────────────────────
{
  const r = child(`
    const { makeFakeHome } = require(process.env.HELPER);
    const fs = require('fs');
    const h = makeFakeHome('probefhc-alive-');
    // Assert from INSIDE the child that the fixture is usable, not merely created:
    // a helper that made an empty dir would satisfy a bare existsSync check.
    const usable = fs.existsSync(h + '/.claude/hooks/dhx-statusline.js');
    console.log(h + '|' + usable);
  `);
  const [home, usable] = r.out.split('|');
  if (home && usable === 'true') ok(`fixture is built and usable during the run (${path.basename(home)})`);
  else bad(`helper did not build a usable fake home (out=${r.out} err=${r.err.slice(0, 200)})`);

  if (home && !fs.existsSync(home)) ok('fake home is removed once the process exits');
  else bad(`fake home SURVIVED process exit at ${home} — this is the leak the helper exists to prevent`);
}

// ── [2] every home is removed, not just the last ─────────────────────────────────────
{
  const r = child(`
    const { makeFakeHome } = require(process.env.HELPER);
    console.log([1,2,3,4,5].map(i => makeFakeHome('probefhc-multi'+i+'-')).join('|'));
  `);
  const homes = r.out ? r.out.split('|') : [];
  if (homes.length === 5) {
    const survivors = homes.filter((h) => fs.existsSync(h));
    if (survivors.length === 0) ok('all five fake homes removed — the registry is per-call, not per-process-last');
    else bad(`${survivors.length} of 5 fake homes survived: ${survivors.map((s) => path.basename(s)).join(', ')}`);
  } else {
    bad(`expected 5 homes, got ${homes.length} (out=${r.out.slice(0, 200)})`);
  }
}

// ── [3] a caller that ALSO cleans up in a finally still composes ─────────────────────
// probe-health-suffix.js and friends remove their own tree eagerly. That must keep
// working: the helper's exit sweep has to tolerate an already-removed path rather than
// throwing and taking the probe's exit code with it.
{
  const r = child(`
    const { makeFakeHome } = require(process.env.HELPER);
    const fs = require('fs');
    const h = makeFakeHome('probefhc-double-');
    fs.rmSync(h, { recursive: true, force: true });   // caller cleans up first
    console.log(h);
  `);
  if (r.status === 0) ok('a caller removing its own tree first does not break the exit sweep (rc 0)');
  else bad(`double-remove made the process exit ${r.status} — eager-cleanup callers would start failing. err=${r.err.slice(0, 200)}`);
}

// ── [4] NEGATIVE CONTROL: disabling cleanup brings the leak back ─────────────────────
// Without this, [1] and [2] would still pass if makeFakeHome stopped creating anything.
{
  const r = child(`
    const { makeFakeHome } = require(process.env.HELPER);
    console.log(makeFakeHome('probefhc-keep-'));
  `, { DHX_KEEP_FAKE_HOME: '1' });
  const home = r.out;
  if (home && fs.existsSync(home)) {
    ok('DHX_KEEP_FAKE_HOME=1 preserves the tree — proves removal is the cleanup path, not an absent allocation');
    fs.rmSync(home, { recursive: true, force: true });
  } else {
    bad(`escape hatch did not preserve the tree (${home}) — either the hatch is broken or the helper stopped creating fixtures, and [1]/[2] cannot tell those apart`);
  }
}

// ── [5] signal path: 'exit' does not fire on SIGTERM by itself ───────────────────────
// A probe killed mid-run is exactly when scratch gets abandoned, so the handler that
// converts a signal into process.exit() is load-bearing, not decoration.
// The child hands its path over through a FILE, not stdout. Polling stdout would need
// the parent's event loop, and this probe waits synchronously — a `spawnSync`-based
// busy-wait blocks the loop so the child's 'data' callback can never fire, and the case
// fails looking like a product defect. (It did, first time.) A file plus a synchronous
// Atomics.wait sleep has no such coupling.
{
  const { spawn } = require('child_process');
  const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
  const relay = path.join(require('os').tmpdir(), `probefhc-relay-${process.pid}.txt`);

  const proc = spawn(process.execPath, ['-e', `
    const { makeFakeHome } = require(process.env.HELPER);
    const fs = require('fs');
    fs.writeFileSync(process.env.RELAY, makeFakeHome('probefhc-signal-'));
    setInterval(() => {}, 1000);   // stay alive until signalled
  `], { env: { ...process.env, HELPER, RELAY: relay }, stdio: 'ignore' });

  let home = '';
  for (let i = 0; i < 100 && !home; i++) {
    sleep(100);
    try { home = fs.readFileSync(relay, 'utf8').trim(); } catch (_) { /* not written yet */ }
  }

  if (home && fs.existsSync(home)) {
    proc.kill('SIGTERM');
    let gone = false;
    for (let i = 0; i < 100 && !gone; i++) { sleep(100); gone = !fs.existsSync(home); }
    if (gone) {
      ok('SIGTERM removes the fake home — the signal handlers are what make this true, `exit` alone never fires on a signal');
    } else {
      bad(`fake home SURVIVED SIGTERM at ${home} — an interrupted probe would leak, and interruption is the most likely time to leak`);
      fs.rmSync(home, { recursive: true, force: true });
    }
  } else {
    bad(`signal case: child never reported a usable fake home (relay=${home || 'empty'})`);
    try { proc.kill('SIGKILL'); } catch (_) { /* already gone */ }
  }
  try { proc.kill('SIGKILL'); } catch (_) { /* already exited */ }
  fs.rmSync(relay, { force: true });
}

console.log('');
console.log(`${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
