#!/usr/bin/env node
// probe-watch-action-render.js — exercises the AWAITING-US ACTION INBOX section
// of dhx/dhx-watch-digest.sh (the SessionStart banner). The action section is a
// READ-ONLY, FAIL-SILENT consumer of the cross-repo Phase-21 action-state surface
// in watchlist.json (producer: scripts/watch/dhx-watch-check.cjs computes
// action_state; dhx-watch-driver.cjs writes ack/snooze). It is DISTINCT from the
// Phase-20 12-key health cache (D-05) and from the edge-triggered digest delta block.
//
// What this proves (the grep-can't-give-it behavioral proof, D-25):
//   1. TWO-SESSION RENDER — the section is LEVEL-triggered: an awaiting_us non-snoozed
//      item renders in BOTH consecutive SessionStart runs (it persists until ack/snooze
//      clears it), unlike an edge-triggered delta that fires once and is gone.
//   2. FILTER CONTRACT across snooze_until — the D-13 DEFENSIVE parse:
//        null / missing / expired-ISO / malformed  -> RENDER (banner never throws)
//        future-ISO / "perma"                       -> HIDE
//      and WR-04: status != "active" HIDES even when action_state == "awaiting_us"
//      (action_state is not re-cleared on status change).
//   3. GATE TAG — a tag:"gate" awaiting_us non-snoozed item still renders (the banner
//      is a renderer; the gate-confirm guard lives in the driver/skill, not here).
//   4. FAIL-SILENT — absent / empty / non-JSON watchlist renders nothing + exits 0.
//   5. NOT BARE IDS — each rendered item carries the copy-ready ack/snooze shortcuts.
//
// Hermetic: each spawn points DHX_WATCH_DIR at a throwaway mktemp dir holding only a
// fixtured watchlist.json, and DHX_WATCH_HEALTH_CACHE at a nonexistent path — so the
// banner reads ONLY the fixture (no live ~/repos/cross-repo/watch, no live health
// cache, no digest/pointer). The only write the banner can make (pointer.txt) requires
// surfaced digest events; there is no digest, so nothing is written anywhere.
// Run: node tests/probes/probe-watch-action-render.js
//
// SAFE_FOR_LIVE: yes   (mktemp watch dir + DHX_WATCH_DIR/DHX_WATCH_HEALTH_CACHE env
//                       overrides; reads only the fixture, never live state)
const { spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const BANNER = path.resolve(__dirname, '..', '..', 'dhx', 'dhx-watch-digest.sh');
const SECTION = 'Action required'; // unique header substring
const j = (o) => JSON.stringify(o);
const FUTURE = () => new Date(Date.now() + 8 * 3600 * 1000).toISOString(); // still snoozed
const EXPIRED = () => new Date(Date.now() - 8 * 3600 * 1000).toISOString(); // snooze elapsed

// Run the banner against a watchlist.json holding `items` (or, if `raw` is a string,
// that literal file content — for the non-JSON / empty cases). Returns {stdout, status}.
function runBanner(items, raw) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'dhx-watch-action-probe-'));
  try {
    const content = raw !== undefined ? raw : j({ schema_version: 1, items });
    fs.writeFileSync(path.join(tmp, 'watchlist.json'), content);
    const res = spawnSync('bash', [BANNER], {
      input: '',
      env: {
        ...process.env,
        DHX_WATCH_DIR: tmp,
        DHX_WATCH_HEALTH_CACHE: path.join(tmp, 'no-health-cache.json'), // guaranteed absent
      },
      encoding: 'utf8',
      timeout: 5000,
    });
    return { stdout: res.stdout || '', status: res.status };
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

// A canonical awaiting_us, never-snoozed, active item.
const item = (over) => Object.assign({
  id: 'o-r-1', url: 'https://github.com/o/r/issues/1', tag: 'claude-code',
  status: 'active', action_state: 'awaiting_us', snooze_until: null,
  last_seen_labels: ['bug', 'area:core'],
}, over || {});

let pass = 0, fail = 0;
function check(name, cond, detail) {
  if (cond) { console.log(`OK   ${name}`); pass++; }
  else { console.log(`FAIL ${name}`); if (detail) console.log(`      ${detail}`); fail++; }
}

// ── (1) TWO-SESSION RENDER — level-triggered persistence across consecutive runs ──
{
  const items = [item({ id: 'persist-1' })];
  const r1 = runBanner(items);
  const r2 = runBanner(items); // same fixture, second session
  check('(1) session-1 renders Action required section', r1.stdout.includes(SECTION), `s1=${j(r1.stdout)}`);
  check('(1) session-1 renders the awaiting_us item', r1.stdout.includes('persist-1'), `s1=${j(r1.stdout)}`);
  check('(1) session-2 STILL renders it (level-triggered, not edge)',
    r2.stdout.includes(SECTION) && r2.stdout.includes('persist-1'), `s2=${j(r2.stdout)}`);
  check('(1) both sessions exit 0', r1.status === 0 && r2.status === 0, `s1=${r1.status} s2=${r2.status}`);
}

// ── (2) FILTER CONTRACT — every snooze_until disposition + WR-04 status clause ──
const RENDER_CASES = [
  { name: 'null snooze_until',     over: { id: 'render-null', snooze_until: null } },
  { name: 'missing snooze_until',  over: { id: 'render-missing' }, drop: ['snooze_until'] },
  { name: 'expired ISO',           over: { id: 'render-expired', snooze_until: EXPIRED() } },
  { name: 'malformed snooze_until', over: { id: 'render-malformed', snooze_until: 'not-a-date' } },
];
const HIDE_CASES = [
  { name: 'future ISO (still snoozed)', over: { id: 'hide-future', snooze_until: FUTURE() } },
  { name: '"perma" snooze',             over: { id: 'hide-perma', snooze_until: 'perma' } },
  { name: 'awaiting_them (not us)',     over: { id: 'hide-them', action_state: 'awaiting_them' } },
  { name: 'WR-04 status=closed',        over: { id: 'hide-closed', status: 'closed' } },
];
function build(spec) {
  const it = item(spec.over);
  for (const k of (spec.drop || [])) delete it[k];
  return it;
}
for (const c of RENDER_CASES) {
  const r = runBanner([build(c)]);
  check(`(2) RENDER: ${c.name}`,
    r.status === 0 && r.stdout.includes(SECTION) && r.stdout.includes(c.over.id),
    `status=${r.status} out=${j(r.stdout)}`);
}
for (const c of HIDE_CASES) {
  const r = runBanner([build(c)]);
  check(`(2) HIDE: ${c.name}`,
    r.status === 0 && !r.stdout.includes(c.over.id),
    `status=${r.status} out=${j(r.stdout)}`);
}
// Combined fixture: 4 render + 4 hide → count is exactly 4, no hidden id leaks.
{
  const items = [...RENDER_CASES, ...HIDE_CASES].map(build);
  const r = runBanner(items);
  check('(2) combined: header reports count 4', r.stdout.includes('Action required (4)'), `out=${j(r.stdout)}`);
  check('(2) combined: all 4 render ids present',
    RENDER_CASES.every((c) => r.stdout.includes(c.over.id)), `out=${j(r.stdout)}`);
  check('(2) combined: no hide id leaks',
    HIDE_CASES.every((c) => !r.stdout.includes(c.over.id)), `out=${j(r.stdout)}`);
  check('(2) combined: banner does not throw', r.status === 0, `status=${r.status}`);
}

// ── (3) GATE TAG — gate-tagged awaiting_us non-snoozed item still renders ──
{
  const r = runBanner([item({ id: 'gate-item', tag: 'gate' })]);
  check('(3) gate-tagged item renders (banner is a renderer, not the gate-confirm guard)',
    r.stdout.includes(SECTION) && r.stdout.includes('gate-item'), `out=${j(r.stdout)}`);
}

// ── (4) FAIL-SILENT — absent / empty / non-JSON watchlist → silent + exit 0 ──
const SILENT_CASES = [
  { name: 'no items (empty array)', items: [] },
  { name: 'non-JSON garbage', raw: 'not json at all {{{' },
  { name: 'empty file', raw: '' },
  { name: 'object missing items', raw: j({ schema_version: 1 }) },
];
for (const c of SILENT_CASES) {
  const r = runBanner(c.items, c.raw);
  check(`(4) fail-silent: ${c.name} → no section + exit 0`,
    r.status === 0 && !r.stdout.includes(SECTION),
    `status=${r.status} out=${j(r.stdout)}`);
}

// ── (5) NOT BARE IDS — rendered item carries copy-ready ack + snooze shortcuts ──
{
  const r = runBanner([item({ id: 'shortcut-1' })]);
  check('(5) renders copy-ready ack shortcut', r.stdout.includes('ack shortcut-1'), `out=${j(r.stdout)}`);
  check('(5) renders copy-ready snooze shortcut', r.stdout.includes('snooze shortcut-1 8h'), `out=${j(r.stdout)}`);
  check('(5) renders the url (openable identity)',
    r.stdout.includes('https://github.com/o/r/issues/1'), `out=${j(r.stdout)}`);
}

console.log('');
console.log(`${pass} passed, ${fail} failed`);
process.exit(fail);
