#!/usr/bin/env node
// probe-watch-health-render.js — exercises the watch-health CACHE CONSUMERS
// (cross-repo D-08 CONTRACT-01 producer: scripts/watch/dhx-watch-health.cjs) on
// BOTH hooks-repo render surfaces against fixtured ~/.cache/dhx/dhx-watch-health.json:
//   - dhx/dhx-watch-digest.sh        — the SessionStart banner (timer_stale /
//                                       polls_degraded / failing-items sections)
//   - dhx/statusline-wrapper.js      — the front-stack tokens (watch:stale /
//                                       watch:${N}fail) via readWatchHealth()
//
// Both are thin, FAIL-SILENT consumers (D-06 read-not-recompute, D-09 fail-silent).
// Each spawn runs under an isolated fake $HOME (mktemp), so both surfaces read the
// SAME fixture cache file from one write; side-effects on real $HOME are zero.
//
// renderer freshness gate (1h, HEALTH_CACHE_STALE_MS / HEALTH_CACHE_STALE_SECONDS)
// is DISTINCT from the cache's internal timer_stale_threshold_hours (3h) — a fresh
// cache with timer_stale:true SHOWS, a >1h cache HIDES everything regardless.
// Run: node tests/probes/probe-watch-health-render.js
//
// SAFE_FOR_LIVE: yes   (uses `_make-fake-home` (mktemp + HOME override per spawn); fully sandboxed)
const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const WRAPPER = path.resolve(__dirname, '..', '..', 'dhx', 'statusline-wrapper.js');
const BANNER = path.resolve(__dirname, '..', '..', 'dhx', 'dhx-watch-digest.sh');
const { makeFakeHome } = require('./_make-fake-home');

// Banner section markers (unique substrings, schema-stable).
const BANNER_TIMER_STALE = 'watch checker stale';
const BANNER_FAILING = 'watch item(s) failing';
// Statusline token markers (no other segment emits `watch:`).
const TOKEN_STALE = 'watch:stale';
const WATCH_SIGIL = '⚠ watch?'; // the forbidden render — fail-silent must never produce it

const FRESH = () => new Date().toISOString();
const STALE = () => new Date(Date.now() - 2 * 3600 * 1000).toISOString(); // 2h > 1h gate
const j = (o) => JSON.stringify(o);

// Plant `cache` (string) at <home>/.cache/dhx/dhx-watch-health.json (unless null →
// absent), then run BOTH the banner and the statusline wrapper under that fake $HOME.
// Returns { banner, statusline, bannerStatus }.
function runBoth(cache) {
  const tmp = makeFakeHome('dhx-watch-health-probe-');
  try {
    const cachePath = path.join(tmp, '.cache', 'dhx', 'dhx-watch-health.json');
    if (cache !== null) fs.writeFileSync(cachePath, cache);

    // Banner: point DHX_WATCH_DIR at a nonexistent dir so there's no digest/
    // watchlist — isolates the health-cache sections. Cache path defaults to
    // $HOME/.cache/dhx/dhx-watch-health.json (resolves under the fake $HOME).
    const bannerRes = spawnSync('bash', [BANNER], {
      input: '',
      env: {
        ...process.env,
        HOME: tmp,
        DHX_WATCH_DIR: path.join(tmp, 'no-watch-dir'),
      },
      encoding: 'utf8',
      timeout: 5000,
    });

    // Statusline: readWatchHealth() reads os.homedir()/.cache/dhx/... (HOME override).
    const slRes = spawnSync(process.execPath, [WRAPPER], {
      input: j({ session_id: 'probe-watch-health', version: '2.1.112' }),
      env: { ...process.env, HOME: tmp, CLAUDE_CONFIG_DIR: path.join(tmp, '.claude') },
      encoding: 'utf8',
      timeout: 5000,
    });

    return {
      banner: bannerRes.stdout || '',
      bannerStatus: bannerRes.status,
      statusline: slRes.stdout || '',
    };
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

let pass = 0, fail = 0;
function check(name, cond, detail) {
  if (cond) { console.log(`  ✓ ${name}`); pass++; }
  else { console.log(`  ✗ ${name}`); if (detail) console.log(`      ${detail}`); fail++; }
}

// ── (a) timer_stale:true, fresh → banner timer_stale line + statusline watch:stale ──
{
  const r = runBoth(j({
    schema_version: 1, computed_at: FRESH(), timer_fire_at: null,
    timer_stale: true, timer_stale_threshold_hours: 3,
    polls_degraded: false, failing_items: [],
  }));
  check('(a) banner renders timer_stale line',
    r.banner.includes(BANNER_TIMER_STALE), `banner=${JSON.stringify(r.banner)}`);
  check('(a) banner exit 0', r.bannerStatus === 0, `status=${r.bannerStatus}`);
  check('(a) statusline emits watch:stale',
    r.statusline.includes(TOKEN_STALE), `sl=${JSON.stringify(r.statusline)}`);
  check('(a) no ⚠ watch? sigil', !r.statusline.includes(WATCH_SIGIL));
}

// ── (b) failing_items length 2 → banner renders both reasons + statusline watch:2fail ──
{
  const r = runBoth(j({
    schema_version: 1, computed_at: FRESH(),
    timer_stale: false, polls_degraded: false,
    failing_items: [
      { id: 'x1', url: 'https://github.com/o/r/issues/1', tag: 't',
        consecutive_failures: 3, last_check_status: 'transient', last_failure_reason: 'HTTP 500' },
      { id: 'x2', url: 'https://github.com/o/r/issues/2', tag: 't',
        consecutive_failures: 5, last_check_status: 'transient', last_failure_reason: 'connection timeout' },
    ],
  }));
  check('(b) banner renders failing-items header (count 2)',
    r.banner.includes('2 ' + BANNER_FAILING), `banner=${JSON.stringify(r.banner)}`);
  check('(b) banner renders BOTH last_failure_reasons',
    r.banner.includes('HTTP 500') && r.banner.includes('connection timeout'),
    `banner=${JSON.stringify(r.banner)}`);
  check('(b) statusline emits watch:2fail (interpolated count)',
    r.statusline.includes('watch:2fail'), `sl=${JSON.stringify(r.statusline)}`);
  check('(b) statusline does NOT emit watch:stale (timer_stale false)',
    !r.statusline.includes(TOKEN_STALE));
  check('(b) no ⚠ watch? sigil', !r.statusline.includes(WATCH_SIGIL));
}

// ── (c) healthy → BOTH surfaces silent ──
{
  const r = runBoth(j({
    schema_version: 1, computed_at: FRESH(),
    timer_stale: false, polls_degraded: false, failing_items: [],
  }));
  check('(c) banner silent (no health section)',
    !r.banner.includes(BANNER_TIMER_STALE) && !r.banner.includes(BANNER_FAILING)
      && !r.banner.includes('polls degraded'),
    `banner=${JSON.stringify(r.banner)}`);
  check('(c) statusline emits no watch token',
    !r.statusline.includes('watch:'), `sl=${JSON.stringify(r.statusline)}`);
  check('(c) no ⚠ watch? sigil', !r.statusline.includes(WATCH_SIGIL));
}

// ── (d) computed_at > 1h old → BOTH silent (renderer freshness gate) ──
// Cache asserts timer_stale:true + failing_items, but the >1h gate must hide ALL of
// it: the computer itself didn't run recently, so no verdict is trustworthy.
{
  const r = runBoth(j({
    schema_version: 1, computed_at: STALE(),
    timer_stale: true, polls_degraded: true,
    failing_items: [{ url: 'u', last_failure_reason: 'x', consecutive_failures: 9 }],
  }));
  check('(d) banner silent on >1h cache',
    !r.banner.includes(BANNER_TIMER_STALE) && !r.banner.includes(BANNER_FAILING)
      && !r.banner.includes('polls degraded'),
    `banner=${JSON.stringify(r.banner)}`);
  check('(d) statusline silent on >1h cache',
    !r.statusline.includes('watch:'), `sl=${JSON.stringify(r.statusline)}`);
  check('(d) no ⚠ watch? sigil', !r.statusline.includes(WATCH_SIGIL));
}

// ── (e) missing / malformed → BOTH silent, neither throws ──
const malformed = [
  { name: 'missing cache file', cache: null },
  { name: 'non-JSON garbage', cache: 'not json at all {{{' },
  { name: 'wrong schema_version (2)', cache: j({ schema_version: 2, computed_at: FRESH(), timer_stale: true, failing_items: [] }) },
  { name: 'missing schema_version', cache: j({ computed_at: FRESH(), timer_stale: true, failing_items: [] }) },
  { name: 'missing computed_at', cache: j({ schema_version: 1, timer_stale: true, failing_items: [] }) },
  { name: 'empty object', cache: j({}) },
];
for (const m of malformed) {
  const r = runBoth(m.cache);
  check(`(e) [${m.name}] banner silent + exit 0`,
    r.bannerStatus === 0 && !r.banner.includes(BANNER_TIMER_STALE)
      && !r.banner.includes(BANNER_FAILING) && !r.banner.includes('polls degraded'),
    `status=${r.bannerStatus} banner=${JSON.stringify(r.banner)}`);
  check(`(e) [${m.name}] statusline silent + no sigil (no throw)`,
    !r.statusline.includes('watch:') && !r.statusline.includes(WATCH_SIGIL)
      && r.statusline.length > 0,
    `sl=${JSON.stringify(r.statusline)}`);
}

console.log('---');
console.log(`PASS: ${pass}  FAIL: ${fail}`);
process.exit(fail);
