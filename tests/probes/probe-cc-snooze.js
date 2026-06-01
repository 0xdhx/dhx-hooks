#!/usr/bin/env node
// Probe: cc-warning snooze (scripts/lib/cc-snooze.js + renderer suppression).
//
// Invariant exercised:
//   1. parseDuration accepts Xh / Xd / perma; rejects junk and non-positive.
//   2. writeSnooze → snoozeState round-trips; expiry flips active→false on the
//      time axis (injected `now`); perma never expires.
//   3. snoozeState FAILS OPEN — a corrupt/absent/scope-mismatched file yields
//      {active:false} (never throws), so a bug can't silently hide a real signal.
//   4. formatRemaining renders the dim-countdown text (Nd / Nh / <1h / ∞ / '').
//   5. INTEGRATION: dhx/dhx-statusline.js collapses the cc version cluster
//      (bright ⬆ cc / ⚠ cc-autoupd) into a single dim "⚠ cc <rem>" token while
//      snoozed, and restores the bright warnings once cleared. cc-novel scope
//      is untouched (not asserted here — separate detector).
//
// Backs: docs/statusline-wrapper.md § "CC version-drift segments" (snooze
// suppression) + the /dhx:statusline snooze subcommand. Integration probe per
// tests/probes/README.md § "Integration probes" (module writer + renderer reader).
//
// Run: node tests/probes/probe-cc-snooze.js
// SAFE_FOR_LIVE: yes — runs entirely under a throwaway $HOME (os.tmpdir mkdtemp);
// never reads or writes the operator's real ~/.cache/dhx.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

// Isolate HOME *before* requiring the module so its SNOOZE_FILE const (computed
// from os.homedir() at load) points inside the throwaway dir.
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'cc-snooze-probe-'));
process.env.HOME = TMP;
delete process.env.CLAUDE_CONFIG_DIR;

const REPO_ROOT = path.resolve(__dirname, '..', '..');
const MODULE = path.join(REPO_ROOT, 'scripts', 'lib', 'cc-snooze.js');
const RENDERER = path.join(REPO_ROOT, 'dhx', 'dhx-statusline.js');
const snz = require(MODULE);

let passed = 0, failed = 0;
function ok(cond, label) {
  if (cond) { console.log(`OK   ${label}`); passed++; }
  else      { console.log(`FAIL ${label}`); failed++; }
}
function throws(fn, label) {
  let threw = false;
  try { fn(); } catch { threw = true; }
  ok(threw, label);
}

const T = 1_800_000_000_000; // fixed epoch-ms anchor for deterministic time axis
const DAY = 86400000, HOUR = 3600000;

// --- 1. parseDuration --------------------------------------------------------
ok(snz.parseDuration('7d').ms === 7 * DAY, 'parseDuration 7d → 7 days');
ok(snz.parseDuration('12h').ms === 12 * HOUR, 'parseDuration 12h → 12 hours');
ok(snz.parseDuration('PERMA').perma === true, 'parseDuration PERMA → perma (case-insensitive)');
ok(snz.parseDuration('permanent').perma === true, 'parseDuration permanent → perma');
throws(() => snz.parseDuration('7x'), 'parseDuration 7x throws (bad unit)');
throws(() => snz.parseDuration('0d'), 'parseDuration 0d throws (non-positive)');
throws(() => snz.parseDuration(''), 'parseDuration "" throws (empty)');
throws(() => snz.parseDuration('d'), 'parseDuration "d" throws (no number)');

// --- 2. write/read round-trip + expiry --------------------------------------
snz.writeSnooze('cc', '7d', T);
let st = snz.snoozeState('cc', T);
ok(st.active === true && st.perma === false, 'snooze 7d → active at write time');
ok(st.remainingMs === 7 * DAY, 'snooze 7d → 7 days remaining at write time');
ok(snz.snoozeState('cc', T + 7 * DAY - 1000).active === true, 'still active 1s before expiry');
ok(snz.snoozeState('cc', T + 7 * DAY + 1000).active === false, 'inactive 1s after expiry');
ok(snz.snoozeState('cc', T + 8 * DAY).active === false, 'inactive well past expiry');

snz.writeSnooze('cc', 'perma', T);
st = snz.snoozeState('cc', T + 9999 * DAY);
ok(st.active === true && st.perma === true, 'perma snooze never expires');

// scope mismatch: a file scoped to something else must not snooze "cc"
fs.writeFileSync(snz.SNOOZE_FILE, JSON.stringify({ scope: 'other', until: T + DAY, perma: false }));
ok(snz.snoozeState('cc', T).active === false, 'scope mismatch → cc not snoozed');

// clear
snz.writeSnooze('cc', '3d', T);
ok(snz.snoozeState('cc', T).active === true, 'pre-clear active');
ok(snz.clearSnooze() === true, 'clearSnooze removes existing file → true');
ok(snz.snoozeState('cc', T).active === false, 'post-clear inactive');
ok(snz.clearSnooze() === false, 'clearSnooze on absent file → false (no throw)');

// --- 3. fail-open ------------------------------------------------------------
fs.writeFileSync(snz.SNOOZE_FILE, '{ this is not json');
ok(snz.snoozeState('cc', T).active === false, 'corrupt JSON → fail-open inactive (no throw)');
snz.clearSnooze();
ok(snz.snoozeState('cc', T).active === false, 'absent file → fail-open inactive');

// --- 4. formatRemaining ------------------------------------------------------
ok(snz.formatRemaining({ active: true, perma: false, remainingMs: 7 * DAY }) === '7d', 'formatRemaining 7d');
ok(snz.formatRemaining({ active: true, perma: false, remainingMs: 12 * HOUR }) === '12h', 'formatRemaining 12h');
ok(snz.formatRemaining({ active: true, perma: false, remainingMs: 1000 }) === '<1h', 'formatRemaining sub-hour → <1h');
ok(snz.formatRemaining({ active: true, perma: true }) === '∞', 'formatRemaining perma → ∞');
ok(snz.formatRemaining({ active: false }) === '', 'formatRemaining inactive → empty');
// ceil semantics: a 7d snooze should still read "7d" a few ms in, never "6d".
ok(snz.formatRemaining({ active: true, perma: false, remainingMs: 7 * DAY - 5 }) === '7d', 'formatRemaining 7d-5ms → 7d (ceil, never undershoots)');

// --- 5. INTEGRATION: renderer suppression ------------------------------------
// Seed a cc-update-check cache where latest >> installed so ⬆ cc would fire.
const ccCacheDir = path.join(TMP, '.cache', 'cc');
fs.mkdirSync(ccCacheDir, { recursive: true });
fs.writeFileSync(path.join(ccCacheDir, 'cc-update-check.json'),
  JSON.stringify({ latest: '9.9.9', checked_at: new Date(T).toISOString(), installed_at_check: '1.0.0', max_published: '9.9.9' }));

const STDIN = JSON.stringify({
  version: '1.0.0',
  model: { display_name: 'Opus 4.7' },
  workspace: { current_dir: REPO_ROOT },
  session_id: 'probe-cc-snooze',
});

function renderLine1() {
  const out = execFileSync(process.execPath, [RENDERER], {
    input: STDIN,
    env: { ...process.env, HOME: TMP, DISABLE_AUTOUPDATER: '1' },
    encoding: 'utf8',
  });
  return out.split('\n')[0];
}

const BRIGHT_UPDATE = '\x1b[33m⬆ cc\x1b[0m';
const BRIGHT_AUTOUPD = '\x1b[33m⚠ cc-autoupd\x1b[0m';
const DIM_TOKEN_RE = /\x1b\[2m⚠ cc \S+\x1b\[0m/;

snz.clearSnooze();
let line = renderLine1();
ok(line.includes(BRIGHT_UPDATE), 'renderer (no snooze): bright ⬆ cc present');
ok(line.includes(BRIGHT_AUTOUPD), 'renderer (no snooze): bright ⚠ cc-autoupd present');
ok(!DIM_TOKEN_RE.test(line), 'renderer (no snooze): no dim collapse token');

snz.writeSnooze('cc', '5d'); // live now() — token shows "5d"
line = renderLine1();
ok(DIM_TOKEN_RE.test(line), 'renderer (snoozed): dim "⚠ cc <rem>" collapse token present');
ok(!line.includes(BRIGHT_UPDATE), 'renderer (snoozed): bright ⬆ cc suppressed');
ok(!line.includes(BRIGHT_AUTOUPD), 'renderer (snoozed): bright ⚠ cc-autoupd suppressed');

snz.clearSnooze();
line = renderLine1();
ok(line.includes(BRIGHT_UPDATE) && line.includes(BRIGHT_AUTOUPD), 'renderer (cleared): bright warnings restored');

// --- cleanup -----------------------------------------------------------------
try { fs.rmSync(TMP, { recursive: true, force: true }); } catch { /* best-effort */ }

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
