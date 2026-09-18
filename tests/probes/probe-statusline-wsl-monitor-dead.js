#!/usr/bin/env node
// Exercises statusline-wrapper's wsl-stack PRODUCER-LIVENESS guard — the dead-man's switch
// the three wsl flag readers structurally cannot be. All three flags under
// ~/.local/state/wsl-stack/ are driven by wsl-pressure.timer; every reader keys on flag
// existence/contents, so a dead/masked timer freezes all three and each keeps rendering its
// frozen state as current. wsl-pressure-broken.flag cannot cover this — the producer writes
// it on its OWN exit-3 path ("ran and failed"), never "never ran".
//
// The guard keys on the two producers' rolling-log MTIMES (pressure.log, claude-cap-census.log),
// never on flag mtime (for wsl-pressure-trip.flag the mtime IS the trip time and that flag is
// durable by the 2026-06-15 decision — an mtime window would silence exactly the flag whose
// staleness is intentional).
//
// The probe asserts the render contract:
//   - both logs stale, NO flags present  → RED `⚠ wsl:monitor-dead <age>` (THE NEGATIVE CONTROL:
//                                          this is the silent-and-dangerous case the whole
//                                          feature exists for — absent claude-cap-bypass.flag
//                                          reads as "cap applying" while nothing has run. It
//                                          renders NOTHING against the pre-change wrapper.)
//   - pressure log stale only            → RED `⚠ wsl:pressure-dead <age>`
//   - census log stale only              → RED `⚠ wsl:census-dead <age>`
//   - both logs fresh                    → SILENT
//   - both logs ABSENT                   → SILENT (absent is indistinguishable from
//                                          never-installed; documented coverage hole)
//   - boot grace                         → logs hours old but uptime < 8min → SILENT. This is
//                                          the measured post-boot false positive: WSL2 booted
//                                          2026-08-13 07:40:57, first pressure.log line landed
//                                          07:47:09 (boot+6m12s via OnBootSec=5min +
//                                          RandomizedDelaySec). Without the grace, EVERY
//                                          firing the guard would have produced in 44 days of
//                                          real logs would have been a false positive.
//   - ARBITRATION                        → a flag whose producer is confirmed stale is an
//                                          unvouched last-known state and must not keep
//                                          rendering as a current RED verdict:
//                                            pressure stale → probe-broken suppressed
//                                            census stale   → cap-bypass suppressed
//                                            trip ALWAYS survives (durable by decision)
//   - ordering                           → trip → monitor-liveness → probe-broken → cap-bypass
//   - the fail-silent invariant          → a `⚠ wslMonitor?` sigil NEVER renders, any state
//
// Boundary + classification cases run against the EXPORTED pure functions
// (classifyWslMonitorState / composeWslFront) so 94:59.999-vs-95:00.000 and boot-grace
// 7:59-vs-8:00 are exact rather than racy; the render cases spawn the real wrapper.
//
// Also carries a direct wrapper benchmark. probe-statusline-load.js does NOT cover this
// surface — it spawns dhx/dhx-statusline.js (the renderer), never statusline-wrapper.js where
// these readers live, so it cannot vouch for the readers' cost.
//
// Side-effects on real $HOME are zero — each spawn runs in an isolated tmpdir.
//
// Backs docs/decisions.md 2026-08-15 wsl-stack producer-liveness row.
// Structural sibling of probe-statusline-wsl-pressure.js / probe-statusline-wsl-probe-broken.js
// / probe-statusline-claude-cap-bypass.js.
// Run: node tests/probes/probe-statusline-wsl-monitor-dead.js
//
// SAFE_FOR_LIVE: yes   (uses `_make-fake-home` (mktemp + HOME + CLAUDE_CONFIG_DIR override per
//                       spawn); logs/flags planted inside the tmp home and aged with utimesSync;
//                       DHX_WSL_UPTIME_MS pins the boot grace so /proc/uptime is never consulted;
//                       never touches live ~/.local/state/wsl-stack)
const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const WRAPPER = path.resolve(__dirname, '..', '..', 'dhx', 'statusline-wrapper.js');
const { makeFakeHome } = require('./_make-fake-home');
const { classifyWslMonitorState, composeWslFront } = require(WRAPPER);

const RED = '\x1b[31m';
const RESET = '\x1b[0m';
const MONITOR_SIGIL = '⚠ wslMonitor?'; // the forbidden render — must NEVER appear
const WSL_LABEL = 'wsl:';
const CLAUDE_LABEL = 'claude:';

// Thresholds mirrored from the wrapper. Mirrored deliberately (not imported) so a silent
// constant change in the wrapper fails this probe instead of silently redefining the contract.
const DEAD_MS = 95 * 60 * 1000;
// Grace is now a CEILING, not the primary gate — the gate is "has the timer fired this boot?",
// read from the systemd stamp. 12min (was 8) clears the measured worst-case first run of
// 489.976s (boot -6, 2026-08-07) which the old 480s constant did NOT, by ~10s.
const GRACE_MS = 12 * 60 * 1000;

// Long-past uptime: well beyond the boot grace, so the grace never masks a render case.
const UP_OLD = String(72 * 3600 * 1000);

const BROKEN_TOKEN = `${RED}⚠ wsl:probe-broken${RESET}`;
const TRIP = (n) => `2026-08-15T09:14:02Z !! WSL process-pressure CRITICAL: bash=${n} (>400) climbing toward .wslconfig ceiling`;
const TRIP_TOKEN = (n) => `${RED}⚠ wsl:bash=${n}${RESET}`;
// seam_ok=0 → the RED cap-bypass variant (the one that coexists with other REDs).
const BYPASS_SEAM_BROKEN = 'capped=0 uncapped=4 seam_ok=0';
const BYPASS_TOKEN = `${RED}⚠ claude:seam-broken uncapped=4${RESET}`;

// Extract the liveness token's label+age from a render, or '' when absent.
function livenessToken(out) {
  const m = out.match(/\x1b\[31m⚠ (wsl:(?:monitor|pressure|census)-dead[^\x1b]*)\x1b\[0m/);
  return m ? m[1] : '';
}

// Plant logs aged by `ageMin` minutes (null → do not create the log at all), plus optional
// flags, then spawn the real wrapper under an isolated $HOME.
// `stampMin` plants the systemd last-trigger stamp aged that many minutes (null = absent, the
// never-installed case). It lives under $HOME, so unlike /proc/uptime the fixture controls it
// directly — the stamp counts as "fired this boot" iff its age is less than the pinned uptime.
function runWith({ pressureMin = null, censusMin = null, uptimeMs = UP_OLD, trip = null, broken = null, bypass = null, stampMin = null } = {}) {
  const tmp = makeFakeHome('dhx-wsl-monitor-dead-');
  try {
    const dir = path.join(tmp, '.local', 'state', 'wsl-stack');
    fs.mkdirSync(dir, { recursive: true });
    if (stampMin !== null) {
      const sdir = path.join(tmp, '.local', 'share', 'systemd', 'timers');
      fs.mkdirSync(sdir, { recursive: true });
      const sf = path.join(sdir, 'stamp-wsl-pressure.timer');
      fs.writeFileSync(sf, '');
      const swhen = new Date(Date.now() - stampMin * 60 * 1000);
      fs.utimesSync(sf, swhen, swhen); // mtime IS the last-trigger time
    }
    const plant = (name, ageMin, body) => {
      if (ageMin === null) return; // absent log — the never-installed / not-judgeable state
      const f = path.join(dir, name);
      fs.writeFileSync(f, body);
      const when = new Date(Date.now() - ageMin * 60 * 1000);
      fs.utimesSync(f, when, when); // mtime IS the liveness key — age it explicitly
    };
    plant('pressure.log', pressureMin, '2026-08-15T11:15:16Z   ok    bash=33\n');
    plant('claude-cap-census.log', censusMin, '2026-08-15 06:15:16   ok    capped=3 uncapped=0 seam=capbin\n');
    if (trip !== null) fs.writeFileSync(path.join(dir, 'wsl-pressure-trip.flag'), trip);
    if (broken !== null) fs.writeFileSync(path.join(dir, 'wsl-pressure-broken.flag'), broken);
    if (bypass !== null) fs.writeFileSync(path.join(dir, 'claude-cap-bypass.flag'), bypass);
    const res = spawnSync(process.execPath, [WRAPPER], {
      input: JSON.stringify({ session_id: 'probe-wsl-monitor-dead', version: '2.1.177' }),
      env: { ...process.env, HOME: tmp, CLAUDE_CONFIG_DIR: path.join(tmp, '.claude'), DHX_WSL_UPTIME_MS: String(uptimeMs) },
      encoding: 'utf8',
      timeout: 5000,
    });
    return res.stdout || '';
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

let pass = 0, fail = 0;
function check(name, ok, detail) {
  if (ok) { console.log(`  ✓ ${name}`); pass++; }
  else { console.log(`  ✗ ${name}`); if (detail) console.log(`      ${detail}`); fail++; }
}

// =========================================================================
// Pure-function classification — exact boundaries, no spawn, no clock race
// =========================================================================
{
  // 4th arg = timerFiredSinceBoot; defaults false so the existing cases keep asserting the
  // ceiling behaviour (no stamp = wait out the grace).
  const k = (p, c, u, fired = false) => { const s = classifyWslMonitorState(p, c, u, fired); return s ? s.kind : null; };
  const UP = 1e9;
  check('classify: both fresh → null (silent)', k(1000, 1000, UP) === null);
  check('classify: both stale → monitor', k(DEAD_MS, DEAD_MS, UP) === 'monitor');
  check('classify: pressure stale only → pressure', k(DEAD_MS, 1000, UP) === 'pressure');
  check('classify: census stale only → census', k(1000, DEAD_MS, UP) === 'census');
  check('classify: both logs absent (null ages) → null (never-installed is silent)', k(null, null, UP) === null);
  check('classify: absent census + stale pressure → pressure (absent ≠ stale)', k(DEAD_MS, null, UP) === 'pressure');
  check('classify: boundary 94:59.999 → null (under threshold)', k(DEAD_MS - 1, DEAD_MS - 1, UP) === null);
  check('classify: boundary 95:00.000 → monitor (at threshold)', k(DEAD_MS, DEAD_MS, UP) === 'monitor');
  check('classify: boot grace 11:59.999 + timer not yet fired → null (post-boot suppression)',
    k(DEAD_MS, DEAD_MS, GRACE_MS - 1) === null);
  check('classify: boot grace 12:00.000 → monitor (ceiling reached, stamp never arrived)',
    k(DEAD_MS, DEAD_MS, GRACE_MS) === 'monitor');
  // THE REGRESSION CASE. Boot -6 (2026-08-07): user manager started at 134.05s, first producer
  // run landed at 489.976s. Under the old 480s kernel-boot-anchored grace this rendered a RED
  // on a healthy box for ~10s. The ceiling now covers it, and the stamp ends the grace the
  // instant the timer actually fires rather than at a guessed elapsed time.
  check('classify: 490s uptime, timer NOT yet fired → null (the boot -6 false positive, fixed)',
    k(DEAD_MS, DEAD_MS, 489.976 * 1000) === null);
  check('classify: 490s uptime, timer HAS fired → monitor (stale logs are real evidence now)',
    k(DEAD_MS, DEAD_MS, 489.976 * 1000, true) === 'monitor');
  check('classify: timer fired ends the grace early — 1min uptime + fired → monitor',
    k(DEAD_MS, DEAD_MS, 60 * 1000, true) === 'monitor');
  check('classify: timer fired does NOT manufacture a verdict — fresh logs stay silent',
    k(0, 0, 60 * 1000, true) === null);
  check('classify: unreadable uptime (null) → grace does NOT apply, still reports',
    k(DEAD_MS, DEAD_MS, null) === 'monitor');
  // The both-stale age is the NEWER log — the most recent sign of life across both producers.
  // This inverts a prior assertion that pinned Math.max (the OLDER log): the pull surface renders
  // this age as "no producer has checked in for <age>", which max made false (2h-stale pressure +
  // 9h-stale census claimed 9h of total silence when one producer wrote 2h ago). See the rationale
  // block at classifyWslMonitorState. 4th arg passed explicitly — the old call site omitted it and
  // leaned on `undefined` being falsy, so the assertion only held because 1e9 clears the ceiling.
  check('classify: monitor age is the NEWER of the two logs (most recent sign of life)',
    classifyWslMonitorState(DEAD_MS, DEAD_MS * 3, 1e9, false).ageMs === DEAD_MS);
  // Argument-order guard: without this, "always return arg 1" would satisfy the assertion above.
  check('classify: monitor age is order-independent (newer wins from either position)',
    classifyWslMonitorState(DEAD_MS * 3, DEAD_MS, 1e9, false).ageMs === DEAD_MS);
}

// =========================================================================
// Pure-function arbitration — which stale flags get suppressed
// `bypass` is the readClaudeCapBypass() OBJECT ({ token, fault }) since 2026-09-18, like
// `monitor`: composeWslFront renders its `.token`; the meta-glyph reads its `.fault`.
// =========================================================================
{
  const c = (kind, tok) => composeWslFront({
    trip: 'TRIP', monitor: { token: tok || (kind ? 'DEAD' : ''), kind }, broken: 'BROKEN', bypass: { token: 'BYPASS', fault: 'BYPASS' },
  });
  check('arbitrate: no liveness state → all three flag tokens render',
    JSON.stringify(c(null, '')) === JSON.stringify(['TRIP', 'BROKEN', 'BYPASS']));
  check('arbitrate: monitor dead → both flag tokens suppressed, trip + dead remain',
    JSON.stringify(c('monitor')) === JSON.stringify(['TRIP', 'DEAD']));
  check('arbitrate: pressure dead → probe-broken suppressed, cap-bypass KEPT (different producer)',
    JSON.stringify(c('pressure')) === JSON.stringify(['TRIP', 'DEAD', 'BYPASS']));
  check('arbitrate: census dead → cap-bypass suppressed, probe-broken KEPT (different producer)',
    JSON.stringify(c('census')) === JSON.stringify(['TRIP', 'DEAD', 'BROKEN']));
  check('arbitrate: trip ALWAYS survives (durable by decision, never suppressed)',
    composeWslFront({ trip: 'TRIP', monitor: { token: 'DEAD', kind: 'monitor' }, broken: '', bypass: { token: '', fault: '' } })[0] === 'TRIP');
  check('arbitrate: ordering is trip → liveness → broken → bypass',
    JSON.stringify(composeWslFront({ trip: 'T', monitor: { token: 'D', kind: null }, broken: 'B', bypass: { token: 'Y', fault: 'Y' } }))
      === JSON.stringify(['T', 'D', 'B', 'Y']) || // kind null ⇒ no suppression
    JSON.stringify(c(null, 'D')) === JSON.stringify(['TRIP', 'D', 'BROKEN', 'BYPASS']));
}

// =========================================================================
// Render contract — real wrapper, isolated $HOME
// =========================================================================

// --- THE NEGATIVE CONTROL: both logs stale, NO flags at all. This is the silent-and-dangerous
// --- case (absent claude-cap-bypass.flag reads as "cap applying" while nothing has run).
// --- Renders NOTHING against the pre-change wrapper.
{
  const out = runWith({ pressureMin: 100.5, censusMin: 100.5 });
  const tok = livenessToken(out);
  check('NEGATIVE CONTROL: both logs stale + all flags absent → ⚠ wsl:monitor-dead renders',
    tok.startsWith('wsl:monitor-dead') && !out.includes(MONITOR_SIGIL),
    `expected wsl:monitor-dead token + no sigil; got ${JSON.stringify(tok)}; output: ${JSON.stringify(out)}`);
  check('NEGATIVE CONTROL: age is interpolated (1h40m for a 100.5-min-old log)',
    tok === 'wsl:monitor-dead 1h40m', `got ${JSON.stringify(tok)}`);
}

// --- The newer-age selection SURVIVES the render, not just the classifier. ---
// Every other render fixture in this file plants two EQUALLY stale logs, so all of them pass
// under either end of the range: the pure-classifier assertions above pin the selection, but
// nothing pinned that readWslMonitorState() actually propagates it into the rendered token.
// Asymmetric, both orders — a single order cannot tell "reports the newer" from "reports
// whichever argument came first". 96 min -> 1h36m (newer), 285 min -> 4h45m (older).
{
  const a = livenessToken(runWith({ pressureMin: 96, censusMin: 285 }));
  check('render: both-stale token carries the NEWER log age (1h36m, not 4h45m)',
    a === 'wsl:monitor-dead 1h36m', `got ${JSON.stringify(a)}`);
  const b = livenessToken(runWith({ pressureMin: 285, censusMin: 96 }));
  check('render: newer-age selection is order-independent through the render path',
    b === 'wsl:monitor-dead 1h36m', `got ${JSON.stringify(b)}`);
}

// --- pressure stale only ---
{
  const out = runWith({ pressureMin: 100.5, censusMin: 1 });
  check('pressure log stale only → ⚠ wsl:pressure-dead (does NOT assert the timer stopped)',
    livenessToken(out).startsWith('wsl:pressure-dead') && !out.includes(MONITOR_SIGIL),
    `got ${JSON.stringify(livenessToken(out))}`);
}

// --- census stale only (reachable: the census rides pressure's tail behind `[ -x ] && … || true`) ---
{
  const out = runWith({ pressureMin: 1, censusMin: 100.5 });
  check('census log stale only → ⚠ wsl:census-dead (independent producer failure)',
    livenessToken(out).startsWith('wsl:census-dead') && !out.includes(MONITOR_SIGIL),
    `got ${JSON.stringify(livenessToken(out))}`);
}

// --- both fresh → silent ---
{
  const out = runWith({ pressureMin: 1, censusMin: 1 });
  check('both logs fresh → segment silent',
    livenessToken(out) === '' && !out.includes(MONITOR_SIGIL),
    `output: ${JSON.stringify(out)}`);
}

// --- both absent → silent (never-installed) ---
{
  const out = runWith({ pressureMin: null, censusMin: null });
  check('both logs absent → segment silent (never-installed, documented hole)',
    livenessToken(out) === '' && !out.includes(MONITOR_SIGIL),
    `output: ${JSON.stringify(out)}`);
}

// --- BOOT GRACE: logs hours old but the box just booted → silent ---
// This is the measured real-world false positive (boot+6m12s to first run). Without the grace
// this exact fixture renders a RED that is pure noise.
{
  const out = runWith({ pressureMin: 540, censusMin: 540, uptimeMs: String(5 * 60 * 1000) });
  check('boot grace: 9h-old logs + 5min uptime → SILENT (post-boot false positive suppressed)',
    livenessToken(out) === '' && !out.includes(MONITOR_SIGIL),
    `output: ${JSON.stringify(out)}`);
}
{
  const out = runWith({ pressureMin: 540, censusMin: 540, uptimeMs: String(13 * 60 * 1000) });
  check('boot grace ceiling reached: 9h-old logs + 13min uptime, no stamp → ⚠ wsl:monitor-dead renders',
    livenessToken(out).startsWith('wsl:monitor-dead'),
    `got ${JSON.stringify(livenessToken(out))}`);
}

// --- STAMP-ANCHORED GRACE (live render). The systemd stamp, not elapsed time, is the gate. ---
// Regression fixture for the boot -6 defect: 490s uptime is PAST the old 480s grace, so the
// pre-change wrapper rendered a RED here on a healthy box.
{
  const out = runWith({ pressureMin: 540, censusMin: 540, uptimeMs: String(490 * 1000) });
  check('stamp absent + 490s uptime → SILENT (boot -6 false positive, fixed at render level)',
    livenessToken(out) === '' && !out.includes(MONITOR_SIGIL),
    `output: ${JSON.stringify(out)}`);
}
{
  // Stamp aged 1min against 490s uptime → fired THIS boot → grace ends, stale logs count.
  const out = runWith({ pressureMin: 540, censusMin: 540, uptimeMs: String(490 * 1000), stampMin: 1 });
  check('stamp fired this boot + stale logs → ⚠ wsl:monitor-dead renders (grace ended early)',
    livenessToken(out).startsWith('wsl:monitor-dead'),
    `got ${JSON.stringify(livenessToken(out))}`);
}
{
  // Stamp aged 60min against 5min uptime → predates boot → LAST boot's stamp, not this one.
  const out = runWith({ pressureMin: 540, censusMin: 540, uptimeMs: String(5 * 60 * 1000), stampMin: 60 });
  check('stamp from a PREVIOUS boot → still suppressed (mtime predates boot wall-time)',
    livenessToken(out) === '' && !out.includes(MONITOR_SIGIL),
    `output: ${JSON.stringify(out)}`);
}
{
  // The stamp must not manufacture a verdict — it ends the grace, it does not assert staleness.
  const out = runWith({ pressureMin: 1, censusMin: 1, uptimeMs: String(490 * 1000), stampMin: 1 });
  check('stamp fired + FRESH logs → segment silent (stamp ends grace, never asserts a fault)',
    livenessToken(out) === '' && !out.includes(MONITOR_SIGIL),
    `output: ${JSON.stringify(out)}`);
}

// --- ARBITRATION, live: monitor dead suppresses BOTH stale flags, trip survives ---
{
  const out = runWith({
    pressureMin: 100.5, censusMin: 100.5,
    trip: TRIP(447), broken: 'stale break', bypass: BYPASS_SEAM_BROKEN,
  });
  const tripIdx = out.indexOf(TRIP_TOKEN(447));
  const deadIdx = out.indexOf('wsl:monitor-dead');
  const ok = tripIdx >= 0 && deadIdx >= 0 && tripIdx < deadIdx
    && !out.includes(BROKEN_TOKEN) && !out.includes(BYPASS_TOKEN) && !out.includes(MONITOR_SIGIL);
  check('arbitration (live): monitor dead → trip survives FIRST, dead SECOND, both stale flags suppressed', ok,
    ok ? '' : `tripIdx=${tripIdx} deadIdx=${deadIdx} brokenPresent=${out.includes(BROKEN_TOKEN)} bypassPresent=${out.includes(BYPASS_TOKEN)}; output: ${JSON.stringify(out)}`);
}

// --- ARBITRATION, live: census dead suppresses ONLY cap-bypass; probe-broken still renders ---
{
  const out = runWith({ pressureMin: 1, censusMin: 100.5, broken: 'fresh break', bypass: BYPASS_SEAM_BROKEN });
  const ok = out.includes(BROKEN_TOKEN) && !out.includes(BYPASS_TOKEN)
    && livenessToken(out).startsWith('wsl:census-dead') && !out.includes(MONITOR_SIGIL);
  check('arbitration (live): census dead → cap-bypass suppressed, probe-broken UNAFFECTED', ok,
    ok ? '' : `broken=${out.includes(BROKEN_TOKEN)} bypass=${out.includes(BYPASS_TOKEN)} tok=${JSON.stringify(livenessToken(out))}`);
}

// --- ARBITRATION, live: pressure dead suppresses ONLY probe-broken; cap-bypass still renders ---
{
  const out = runWith({ pressureMin: 100.5, censusMin: 1, broken: 'stale break', bypass: BYPASS_SEAM_BROKEN });
  const ok = !out.includes(BROKEN_TOKEN) && out.includes(BYPASS_TOKEN)
    && livenessToken(out).startsWith('wsl:pressure-dead') && !out.includes(MONITOR_SIGIL);
  check('arbitration (live): pressure dead → probe-broken suppressed, cap-bypass UNAFFECTED', ok,
    ok ? '' : `broken=${out.includes(BROKEN_TOKEN)} bypass=${out.includes(BYPASS_TOKEN)} tok=${JSON.stringify(livenessToken(out))}`);
}

// --- fresh logs must not disturb the existing readers (no-regression guard) ---
{
  const out = runWith({ pressureMin: 1, censusMin: 1, trip: TRIP(500), broken: 'x', bypass: BYPASS_SEAM_BROKEN });
  const ok = out.includes(TRIP_TOKEN(500)) && out.includes(BROKEN_TOKEN) && out.includes(BYPASS_TOKEN)
    && livenessToken(out) === '';
  check('live producers: all three legacy flag tokens render unchanged, liveness silent', ok,
    ok ? '' : `output: ${JSON.stringify(out)}`);
}

// --- fail-silent: an unreadable state dir must never produce a sigil ---
{
  const out = runWith({ pressureMin: null, censusMin: null, uptimeMs: 'not-a-number' });
  check('fail-silent: garbage DHX_WSL_UPTIME_MS falls through, no `⚠ wslMonitor?` sigil',
    !out.includes(MONITOR_SIGIL) && !out.includes(WSL_LABEL) && !out.includes(CLAUDE_LABEL),
    `output: ${JSON.stringify(out)}`);
}

// =========================================================================
// Wrapper benchmark — probe-statusline-load.js does NOT cover this surface
// (it spawns dhx/dhx-statusline.js, never statusline-wrapper.js).
// Informational, no gate: absolute wall-time is machine-dependent.
// =========================================================================
{
  const N = 20;
  const t0 = process.hrtime.bigint();
  for (let i = 0; i < N; i++) runWith({ pressureMin: 100.5, censusMin: 100.5 });
  const ms = Number(process.hrtime.bigint() - t0) / 1e6 / N;
  console.log(`\ninfo: median wrapper render incl. 2 statSync + /proc/uptime read = ${ms.toFixed(2)}ms/render (informational; no gate)`);
  console.log('info: this is the FULL wrapper spawn, unlike probe-statusline-load.js which spawns only the renderer');
}

console.log('---');
console.log(`PASS: ${pass}  FAIL: ${fail}`);
process.exit(fail);
