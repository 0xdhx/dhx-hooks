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
// Phase 17 (RAT-04 + RAT-06) extension — 2026-05-21:
// The renderer gained three line-1 segments — `⚠ cc-novel` (RAT-04),
// `⬆ cc` / `⚠ cc dev install` (RAT-06), `⚠ cc-autoupd` (RAT-06). This probe
// now also covers: malformed-cache tolerance for both new cache files
// (D-13a — renderer never throws), the RAT-06 segment matrix
// (update / dev-install / equal / canary / suppression), and the D-14
// render-time re-filter (an all-allowlisted cc-novel-patterns.json clears
// the warning; a genuinely-novel entry shows it). Fixtures are injected via
// a HOME override in the renderer child-spawn env (D-18) — os.homedir()
// honors $HOME on POSIX, so fixture caches land under $HOME/.cache/cc/ and
// $HOME/.cache/dhx/ with ZERO renderer code change. The live ~/.cache/cc
// and ~/.cache/dhx are never written — SAFE_FOR_LIVE stays true.
//
// Run: node tests/probes/probe-statusline-load.js
// (D-13 fix: NOT `bash ...` — this is a Node script.)
// SAFE_FOR_LIVE: yes  (read-only renderer invocation via child-spawn; child
// stdout captured via stdio:'pipe'; renderer's bridge-file write lands at
// /tmp/claude-ctx-probe-load.json — predictable path, conventional fixture
// per SAFE_FOR_LIVE.md heuristic note on probe-settings-hash.js. Phase 17:
// fixture caches written ONLY under per-test mktemp HOME overrides — the
// live ~/.cache is never touched.)

'use strict';

const fs = require('fs');
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
//
// opts.env  — extra env vars merged into the child env (e.g. HOME override
//             for D-18 fixture injection, DISABLE_AUTOUPDATER for RAT-06).
function renderOnce(fixture, opts = {}) {
  const env = { ...process.env, DHX_DISABLE_HOOKS: '1', ...(opts.env || {}) }; // defensive
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

// --- D-18 HOME-override fixture harness -------------------------------------
// Build a throwaway HOME dir, write fixture caches under its .cache tree, and
// hand the override back so renderOnce can point the child's os.homedir() at
// it. The live ~/.cache is never written. Each call gets its own mktemp dir.
//
//   novelPatterns : array | string | undefined — written verbatim as the
//                   cc-novel-patterns.json `novel_patterns` value when an
//                   array; a string is written as raw (malformed-JSON) file
//                   content; undefined → no cc-novel-patterns.json file.
//   updateCheck   : object | string | undefined — written as cc-update-check
//                   .json; a string is written raw (malformed); undefined →
//                   no file.
function makeFixtureHome({ novelPatterns, updateCheck } = {}) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'dhx-probe-home-'));
  if (novelPatterns !== undefined) {
    const dhxCache = path.join(home, '.cache', 'dhx');
    fs.mkdirSync(dhxCache, { recursive: true });
    const file = path.join(dhxCache, 'cc-novel-patterns.json');
    if (typeof novelPatterns === 'string') {
      fs.writeFileSync(file, novelPatterns);
    } else {
      fs.writeFileSync(file, JSON.stringify({
        detected_at: '2026-05-21T00:00:00Z',
        cc_version: '2.1.146',
        novel_patterns: novelPatterns,
      }));
    }
  }
  if (updateCheck !== undefined) {
    const ccCache = path.join(home, '.cache', 'cc');
    fs.mkdirSync(ccCache, { recursive: true });
    const file = path.join(ccCache, 'cc-update-check.json');
    fs.writeFileSync(file,
      typeof updateCheck === 'string' ? updateCheck : JSON.stringify(updateCheck));
  }
  return home;
}

// Track every fixture HOME so the EXIT trap can clean them all up.
const fixtureHomes = [];
function fixtureHome(spec) {
  const h = makeFixtureHome(spec);
  fixtureHomes.push(h);
  return h;
}
process.on('exit', () => {
  for (const h of fixtureHomes) {
    try { fs.rmSync(h, { recursive: true, force: true }); } catch (e) {}
  }
});

// Allowlisted novel-pattern entry — passes isAllowlisted (segment 0 is a
// seeded marketplace, every later segment recognized). A stale cache full of
// these must NOT render the warning after the D-14 render-time re-filter.
const ALLOWLISTED_ENTRY = {
  path: 'anthropic-agent-skills/document-skills/690f15cac7f7/skills/SKILL.md',
  basename: 'SKILL.md',
  first_seen_mtime: 1779000000000,
};
// Genuinely-novel entry — segment 0 is an unknown marketplace, so
// isAllowlisted returns false; the warning MUST render.
const NOVEL_ENTRY = {
  path: 'rogue-marketplace/evil-plugin/deadbeef/payload.sh',
  basename: 'payload.sh',
  first_seen_mtime: 1779000000000,
};

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

// --- Phase 17: RAT-04 + RAT-06 renderer-segment scenarios -------------------
// Every scenario below injects fixture caches via a HOME override (D-18) and
// asserts on the stripped (ANSI-free) line-1 text. The no-subprocess shim is
// still active for each render — any spawn from the new segments flips the
// child to exit 2, which `status === 0` catches.

// Scenario 1 — malformed cc-novel-patterns.json → renderer tolerates it.
{
  const home = fixtureHome({ novelPatterns: '{ this is not valid json' });
  const r = renderOnce(baseFixture, { env: { HOME: home } });
  ok('RAT-04 malformed cc-novel-patterns.json → exit 0, line-1 non-empty',
    r.status === 0 && strip(r.stdout).trim().length > 0, true);
}

// Scenario 2 — malformed cc-update-check.json → renderer tolerates it.
{
  const home = fixtureHome({ updateCheck: '}{ broken' });
  const r = renderOnce(baseFixture, { env: { HOME: home } });
  ok('RAT-06 malformed cc-update-check.json → exit 0, line-1 non-empty',
    r.status === 0 && strip(r.stdout).trim().length > 0, true);
}

// Scenario 3 — latest ahead of data.version → `⬆ cc` segment present.
{
  const home = fixtureHome({ updateCheck: { latest: '2.1.150', checked_at: '2026-05-21T00:00:00Z' } });
  const r = renderOnce({ ...baseFixture, version: '2.1.146' }, { env: { HOME: home } });
  const l1 = strip(r.stdout);
  ok('RAT-06 latest>installed → `⬆ cc` present', r.status === 0 && /⬆ cc(\b|[^-])/.test(l1), true);
  ok('RAT-06 latest>installed → no dev-install marker', /cc dev install/.test(l1), false);
}

// Scenario 4 — data.version ahead of latest → dev-install marker, NOT `⬆ cc`.
{
  const home = fixtureHome({ updateCheck: { latest: '2.1.140', checked_at: '2026-05-21T00:00:00Z' } });
  const r = renderOnce({ ...baseFixture, version: '2.1.146' }, { env: { HOME: home } });
  const l1 = strip(r.stdout);
  ok('RAT-06 installed>latest → dev-install marker present', r.status === 0 && /cc dev install/.test(l1), true);
  ok('RAT-06 installed>latest → `⬆ cc` absent', /⬆ cc(\b|[^-])/.test(l1), false);
}

// Scenario 5 — latest === data.version → neither cc marker.
{
  const home = fixtureHome({ updateCheck: { latest: '2.1.146', checked_at: '2026-05-21T00:00:00Z' } });
  const r = renderOnce({ ...baseFixture, version: '2.1.146' }, { env: { HOME: home } });
  const l1 = strip(r.stdout);
  ok('RAT-06 latest===installed → no `⬆ cc`, no dev-install',
    r.status === 0 && !/⬆ cc(\b|[^-])/.test(l1) && !/cc dev install/.test(l1), true);
}

// Scenario 6 — DISABLE_AUTOUPDATER=1 → suppression marker present; unset → absent.
{
  const r1 = renderOnce(baseFixture, { env: { DISABLE_AUTOUPDATER: '1' } });
  ok('RAT-06 DISABLE_AUTOUPDATER=1 → `cc-autoupd` marker present',
    r1.status === 0 && strip(r1.stdout).includes('cc-autoupd'), true);
  const r2 = renderOnce(baseFixture);
  ok('RAT-06 DISABLE_AUTOUPDATER unset → `cc-autoupd` marker absent',
    !strip(r2.stdout).includes('cc-autoupd'), true);
}

// Scenario 7 — D-14 render-time re-filter.
// 7a: cc-novel-patterns.json whose entries ALL pass the CURRENT allowlist
//     (operator widened the allowlist mid-cohort; cache is stale) →
//     the renderer re-filters → `⚠ cc-novel` marker ABSENT.
{
  const home = fixtureHome({ novelPatterns: [ALLOWLISTED_ENTRY, ALLOWLISTED_ENTRY] });
  const r = renderOnce(baseFixture, { env: { HOME: home } });
  ok('RAT-04 D-14: all-allowlisted stale cache → `cc-novel` marker ABSENT (re-filter cleared it)',
    r.status === 0 && !strip(r.stdout).includes('cc-novel'), true);
}
// 7b: at least one genuinely-novel entry survives the re-filter →
//     `⚠ cc-novel` marker PRESENT.
{
  const home = fixtureHome({ novelPatterns: [ALLOWLISTED_ENTRY, NOVEL_ENTRY] });
  const r = renderOnce(baseFixture, { env: { HOME: home } });
  ok('RAT-04 D-14: a surviving novel entry → `cc-novel` marker PRESENT',
    r.status === 0 && strip(r.stdout).includes('cc-novel'), true);
}
// 7c: empty novel_patterns array → marker absent.
{
  const home = fixtureHome({ novelPatterns: [] });
  const r = renderOnce(baseFixture, { env: { HOME: home } });
  ok('RAT-04 empty novel_patterns → `cc-novel` marker absent',
    r.status === 0 && !strip(r.stdout).includes('cc-novel'), true);
}

// Scenario 8 — canary `latest` vs base `data.version` (D-16).
// `2.1.146-canary.2` strips to base `2.1.146`; equal-base → neither marker.
{
  const home = fixtureHome({ updateCheck: { latest: '2.1.146-canary.2', checked_at: '2026-05-21T00:00:00Z' } });
  const r = renderOnce({ ...baseFixture, version: '2.1.146' }, { env: { HOME: home } });
  const l1 = strip(r.stdout);
  ok('RAT-06 D-16: canary latest strips to equal base → no `⬆ cc`, no dev-install',
    r.status === 0 && !/⬆ cc(\b|[^-])/.test(l1) && !/cc dev install/.test(l1), true);
}

// Scenario 9 — cache.latest === 'unknown' (npm view failed) → neither marker.
{
  const home = fixtureHome({ updateCheck: { latest: 'unknown', checked_at: '2026-05-21T00:00:00Z' } });
  const r = renderOnce({ ...baseFixture, version: '2.1.146' }, { env: { HOME: home } });
  const l1 = strip(r.stdout);
  ok('RAT-06 latest==="unknown" → no cc marker',
    r.status === 0 && !/⬆ cc(\b|[^-])/.test(l1) && !/cc dev install/.test(l1), true);
}

// --- RAT-06b: dev-install guard (installed_at_check) -------------------------
// The `⚠ cc dev install` branch fires when installed > cache.latest. That is a
// FALSE POSITIVE when the auto-updater bumped the installed binary past the
// cache's `latest` WITHIN the ~6h TTL window (the cache still names the older
// `latest` it checked against). The guard: only fire when cache.installed_at_check
// matches the running installed version — i.e. npm `latest` was confirmed
// against THIS binary, not a since-replaced one. See decisions.md 2026-05-21
// RAT-06b row + HP-033 invariant 7.

// Scenario 10 — installed > latest BUT installed_at_check ≠ installed (the
// auto-updater raced the TTL) → dev-install SUPPRESSED. This is the live
// 2026-05-21 incident in miniature (checked against 2.1.140, now on 2.1.147).
{
  const home = fixtureHome({ updateCheck: {
    latest: '2.1.140', installed_at_check: '2.1.140', checked_at: '2026-05-21T00:00:00Z' } });
  const r = renderOnce({ ...baseFixture, version: '2.1.147' }, { env: { HOME: home } });
  const l1 = strip(r.stdout);
  ok('RAT-06b installed≠installed_at_check (auto-updater race) → dev-install SUPPRESSED',
    r.status === 0 && !/cc dev install/.test(l1), true);
}

// Scenario 11 — installed > latest AND installed_at_check === installed (npm
// `latest` was confirmed against the running binary) → genuine dev install,
// marker FIRES.
{
  const home = fixtureHome({ updateCheck: {
    latest: '2.1.140', installed_at_check: '2.1.147', checked_at: '2026-05-21T00:00:00Z' } });
  const r = renderOnce({ ...baseFixture, version: '2.1.147' }, { env: { HOME: home } });
  const l1 = strip(r.stdout);
  ok('RAT-06b installed===installed_at_check (genuine dev install) → dev-install PRESENT',
    r.status === 0 && /cc dev install/.test(l1), true);
}

// Scenario 12 — installed > latest, installed_at_check ABSENT (old cache schema
// or worker probe failed) → fall back to prior unguarded behavior, marker FIRES.
{
  const home = fixtureHome({ updateCheck: {
    latest: '2.1.140', checked_at: '2026-05-21T00:00:00Z' } });
  const r = renderOnce({ ...baseFixture, version: '2.1.147' }, { env: { HOME: home } });
  const l1 = strip(r.stdout);
  ok('RAT-06b installed_at_check absent → fallback fires dev-install (backward-compat)',
    r.status === 0 && /cc dev install/.test(l1), true);
}

// 4. Wall-time emission (informational only — D-03/D-06 lock; NO hard threshold)
console.log();
console.log(`info: median wall-time per render = ${medianMs.toFixed(2)}ms (informational; no gate)`);
console.log(`info: total wall-time for 100 renders = ${totalMs.toFixed(2)}ms`);
console.log();
console.log(`${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
