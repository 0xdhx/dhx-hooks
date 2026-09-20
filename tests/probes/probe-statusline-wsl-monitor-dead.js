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
//   - both logs ABSENT, no stamp         → SILENT (no install evidence = never-installed)
//   - MISSING with install evidence      → (2026-09-19) a missing log beside a FRESH sibling,
//                                          or both missing with a stamp fired THIS boot,
//                                          renders RED `wsl:pressure-log-missing` /
//                                          `wsl:census-log-missing` / `wsl:monitor-logs-missing`
//                                          with NO age — never an invented duration
//   - RUN-COMPLETION ALLOWANCE           → (2026-09-19) stamp age < 360 s + a non-fresh log
//                                          → `inflight`: no token, both self-clearing flags
//                                          suppressed like warming. Stamp past the allowance
//                                          but alive, ONE log stale + sibling fresh →
//                                          `wsl:pressure-unfinished` / `wsl:census-unfinished`
//                                          (the producer, not the timer). BOTH stale beside an
//                                          alive stamp → `wsl:monitor-unfinished` (round 2,
//                                          2026-09-19: the service is ONE process, so a hang
//                                          most plausibly hangs whole — neither log written).
//                                          Plain `wsl:monitor-dead` is now reachable ONLY with
//                                          a dead / absent / previous-boot stamp.
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
// Backs docs/decisions.md 2026-08-15 wsl-stack producer-liveness row, the 2026-09-19 warming
// row, and the 2026-09-19 run-completion-allowance / missing-arms row.
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
// Run-completion allowance (2026-09-19): 240 s structural bound (census seam probe 30 s + two
// `timeout 10 systemctl` + swap capture `timeout -k 10 180`) × 1.5, the grace ceiling's own
// ratio. Under it a fresh stamp beside a stale log is `inflight`, not dead.
const ALLOW_MS = 6 * 60 * 1000;

// Long-past uptime: well beyond the boot grace, so the grace never masks a render case.
const UP_OLD = String(72 * 3600 * 1000);

const BROKEN_TOKEN = `${RED}⚠ wsl:probe-broken${RESET}`;
const TRIP = (n) => `2026-08-15T09:14:02Z !! WSL process-pressure CRITICAL: bash=${n} (>400) climbing toward .wslconfig ceiling`;
const TRIP_TOKEN = (n) => `${RED}⚠ wsl:bash=${n}${RESET}`;
// seam_ok=0 → the RED cap-bypass variant (the one that coexists with other REDs).
const BYPASS_SEAM_BROKEN = 'capped=0 uncapped=4 seam_ok=0';
const BYPASS_TOKEN = `${RED}⚠ claude:seam-broken uncapped=4${RESET}`;

// Extract the liveness token's label+age from a render, or '' when absent. Matches every
// Position-2 label family — `-dead`, `-log-missing` / `-logs-missing`, `-unfinished` — and
// nothing else in the front (`wsl:bash=` is the trip, `wsl:probe-broken` has no family prefix).
function livenessToken(out) {
  const m = out.match(/\x1b\[31m⚠ (wsl:(?:monitor|pressure|census)-[^\x1b]*)\x1b\[0m/);
  return m ? m[1] : '';
}
// A render must never carry a JS hole. `*-missing` kinds have ageMs null and no label lookup
// may miss — either would interpolate into the token as literal text.
const NO_HOLES = (out) => !out.includes('undefined') && !out.includes('NaN');

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
  check('classify: boot grace 11:59.999 + timer not yet fired → warming (post-boot suppression)',
    k(DEAD_MS, DEAD_MS, GRACE_MS - 1) === 'warming');
  check('classify: boot grace 12:00.000 → monitor (ceiling reached, stamp never arrived)',
    k(DEAD_MS, DEAD_MS, GRACE_MS) === 'monitor');
  // THE REGRESSION CASE. Boot -6 (2026-08-07): user manager started at 134.05s, first producer
  // run landed at 489.976s. Under the old 480s kernel-boot-anchored grace this rendered a RED
  // on a healthy box for ~10s. The ceiling now covers it, and the stamp ends the grace the
  // instant the timer actually fires rather than at a guessed elapsed time.
  check('classify: 490s uptime, timer NOT yet fired → warming (the boot -6 false positive, fixed)',
    k(DEAD_MS, DEAD_MS, 489.976 * 1000) === 'warming');
  // The grace means UNPROVEN, not TRUSTED (2026-09-19). Both assertions above read `null`
  // until this change — that null is exactly what left composeWslFront with no kind to
  // derive suppression from, so the two producer-self-clearing flags rendered as current
  // REDs for up to the full ceiling. The rendered contract is unchanged: warming carries
  // token '' and WSL_MONITOR_LABELS has no entry for it, pinned directly below.
  check('classify: warming carries NO age and NO token (nothing red may render in the grace)',
    (() => { const st = classifyWslMonitorState(DEAD_MS, DEAD_MS, GRACE_MS - 1, false);
             // `!!st` is load-bearing, not defensive noise: pre-change this returns null, and
             // an unguarded property read THROWS — killing the process before the render-path
             // assertions below ever run, which is exactly the arm the negative control needs.
             return !!st && st.kind === 'warming' && st.ageMs === null && st.token === ''; })());
  check('classify: fresh logs inside the grace are ALSO warming (trust is unproven either way)',
    k(0, 0, GRACE_MS - 1) === 'warming');
  check('classify: absent logs inside the grace are ALSO warming (nothing has run yet)',
    k(null, null, GRACE_MS - 1) === 'warming');
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
// RUN-COMPLETION ALLOWANCE + MISSING / UNFINISHED ARMS (2026-09-19) — pure classifier, 5 args.
// Required rows from the shared design brief (cross-repo briefs
// 2026-08-15-wsl-monitor-{absent-vs-never-installed,stamp-leads-producer-writes,
// stamp-vs-log-ran-but-did-not-finish}); the cross-repo coupling probe re-pins the same rows
// against the bash twin. Fixture ages in SECONDS as the brief states them: stale = DEAD+60 =
// 5760, fresh = 60; uptime far past the grace unless stated; stamp fired this boot unless
// stated. `k5` returns `kind age` as the coupling tuple does ('-' for a null age).
// =========================================================================
{
  const S = 1000;
  const FRESH = 60 * S, STALE = 5760 * S, STALE2 = 17100 * S;
  const UP = 1e9;
  const k5 = (p, c, u, fired, st) => {
    const s = classifyWslMonitorState(p, c, u, fired, st);
    if (s === null) return '-';
    return `${s.kind} ${s.ageMs === null ? '-' : s.ageMs / S}`;
  };
  // --- missing arms: install evidence is a FRESH sibling or a stamp fired THIS boot ---
  check('classify5: pressure fresh + census ABSENT + stamp fired 3600 s ago → census-missing, NO age',
    k5(FRESH, null, UP, true, 3600 * S) === 'census-missing -', `got ${k5(FRESH, null, UP, true, 3600 * S)}`);
  check('classify5: pressure ABSENT + census fresh + stamp fired 3600 s ago → pressure-missing, NO age',
    k5(null, FRESH, UP, true, 3600 * S) === 'pressure-missing -', `got ${k5(null, FRESH, UP, true, 3600 * S)}`);
  check('classify5: both absent + NO stamp → silent (never-installed)',
    k5(null, null, UP, false, undefined) === '-', `got ${k5(null, null, UP, false, undefined)}`);
  check('classify5: both absent + stamp from a PREVIOUS boot → silent (not install evidence)',
    k5(null, null, UP, false, 7200 * S) === '-', `got ${k5(null, null, UP, false, 7200 * S)}`);
  check('classify5: both absent + stamp fired THIS boot 3600 s ago → monitor-missing, NO age',
    k5(null, null, UP, true, 3600 * S) === 'monitor-missing -', `got ${k5(null, null, UP, true, 3600 * S)}`);
  // --- allowance boundary: 490 s uptime (past the boot -6 worst case), stamp fired, stale
  // --- asymmetric logs 5760 / 17100, BOTH producer orders ---
  check('classify5: uptime 490 s + stamp age 0 + stale logs (5760/17100) → inflight',
    k5(STALE, STALE2, 490 * S, true, 0) === 'inflight -', `got ${k5(STALE, STALE2, 490 * S, true, 0)}`);
  check('classify5: … mirror order (17100/5760) → inflight',
    k5(STALE2, STALE, 490 * S, true, 0) === 'inflight -', `got ${k5(STALE2, STALE, 490 * S, true, 0)}`);
  check('classify5: stamp age 359 s (allowance − 1) → inflight',
    k5(STALE, STALE2, 490 * S, true, 359 * S) === 'inflight -', `got ${k5(STALE, STALE2, 490 * S, true, 359 * S)}`);
  check('classify5: … mirror order → inflight',
    k5(STALE2, STALE, 490 * S, true, 359 * S) === 'inflight -', `got ${k5(STALE2, STALE, 490 * S, true, 359 * S)}`);
  check('classify5: stamp age 360 s (= allowance) → monitor-unfinished 5760 (the failure verdict: the run had its time and neither log moved)',
    k5(STALE, STALE2, 490 * S, true, ALLOW_MS) === 'monitor-unfinished 5760', `got ${k5(STALE, STALE2, 490 * S, true, ALLOW_MS)}`);
  check('classify5: … mirror order → monitor-unfinished 5760 (coverage age = the NEWER log, either position)',
    k5(STALE2, STALE, 490 * S, true, ALLOW_MS) === 'monitor-unfinished 5760', `got ${k5(STALE2, STALE, 490 * S, true, ALLOW_MS)}`);
  // --- unfinished arms: stamp alive (< DEAD) and past the allowance, ONE stale + ONE fresh ---
  check('classify5: stamp 600 s + pressure stale 5760 + census fresh 60 → pressure-unfinished 5760',
    k5(STALE, FRESH, UP, true, 600 * S) === 'pressure-unfinished 5760', `got ${k5(STALE, FRESH, UP, true, 600 * S)}`);
  check('classify5: stamp 600 s + pressure fresh 60 + census stale 5760 → census-unfinished 5760',
    k5(FRESH, STALE, UP, true, 600 * S) === 'census-unfinished 5760', `got ${k5(FRESH, STALE, UP, true, 600 * S)}`);
  // --- monitor-unfinished (round 2, 2026-09-19): stamp alive + past the allowance + BOTH stale.
  // --- The reviewer's counterexample: a fresh stamp proves the scheduler is fine, so sending
  // --- the operator to restart the timer was wrong. Age = the NEWER log, as 'monitor' does.
  check('classify5: stamp 600 s + BOTH stale → monitor-unfinished 5760 (the producer hung whole; the timer is fine)',
    k5(STALE, STALE, UP, true, 600 * S) === 'monitor-unfinished 5760', `got ${k5(STALE, STALE, UP, true, 600 * S)}`);
  check('classify5: … asymmetric (5760/17100) → monitor-unfinished 5760 (age = the NEWER log)',
    k5(STALE, STALE2, UP, true, 600 * S) === 'monitor-unfinished 5760', `got ${k5(STALE, STALE2, UP, true, 600 * S)}`);
  check('classify5: stamp 6000 s (DEAD) + BOTH stale → monitor 5760 (monitor-dead stays reachable: the timer itself has not fired)',
    k5(STALE, STALE, UP, true, 6000 * S) === 'monitor 5760', `got ${k5(STALE, STALE, UP, true, 6000 * S)}`);
  check('classify5: stamp 5699 s (dead − 1) + BOTH stale → monitor-unfinished 5760 (boundary: stamp still alive)',
    k5(STALE, STALE, UP, true, 5699 * S) === 'monitor-unfinished 5760', `got ${k5(STALE, STALE, UP, true, 5699 * S)}`);
  check('classify5: stamp 5700 s (= dead) + BOTH stale → monitor 5760 (boundary: stamp dead, the timer is the story)',
    k5(STALE, STALE, UP, true, 5700 * S) === 'monitor 5760', `got ${k5(STALE, STALE, UP, true, 5700 * S)}`);
  // --- stampAlive CLASS (round 3, 2026-09-20): every `*-unfinished` arm requires a stamp that
  // --- fired THIS boot AND is younger than the dead threshold. Enumerated, not sampled: three
  // --- not-alive stamp forms × three stale-log shapes = 9 cells, every one today's verdict.
  // --- The previous-boot form is the reviewer's counterexample — uptime 900 s (past the 720 s
  // --- grace), stamp 901 s (older than uptime → predates boot → never fired this boot), which
  // --- round 2's age-only predicate read as alive and returned `monitor-unfinished`.
  {
    const forms = [
      ['absent (no stamp)',                 UP,      false, null],
      ['this boot but DEAD (6000 s)',       UP,      true,  6000 * S],
      ['previous boot, aged 901 s @ up 900', 900 * S, false, 901 * S],
    ];
    const shapes = [
      ['both stale',          STALE, STALE, 'monitor 5760'],
      ['pressure stale only', STALE, FRESH, 'pressure 5760'],
      ['census stale only',   FRESH, STALE, 'census 5760'],
    ];
    for (const [fname, up, fired, st] of forms) {
      for (const [sname, p, c, want] of shapes) {
        const got = k5(p, c, up, fired, st);
        check(`stampalive-class: ${fname} × ${sname} → ${want} (no *-unfinished without a this-boot stamp)`,
          got === want, `got ${got}`);
      }
    }
  }
  check('stampalive-class boundary: uptime 900 s + stamp 899 s (THIS boot, alive) + BOTH stale → monitor-unfinished 5760',
    k5(STALE, STALE, 900 * S, true, 899 * S) === 'monitor-unfinished 5760', `got ${k5(STALE, STALE, 900 * S, true, 899 * S)}`);
  check('stampalive-class boundary: uptime 900 s + stamp 901 s (PREVIOUS boot) + BOTH stale → monitor 5760 (the scheduler is the story)',
    k5(STALE, STALE, 900 * S, false, 901 * S) === 'monitor 5760', `got ${k5(STALE, STALE, 900 * S, false, 901 * S)}`);
  check('classify5: stamp 6000 s (stamp itself stale) + pressure stale + census fresh → pressure (today\'s verdict)',
    k5(STALE, FRESH, UP, true, 6000 * S) === 'pressure 5760', `got ${k5(STALE, FRESH, UP, true, 6000 * S)}`);
  // --- contract edges the brief fixes ---
  check('classify5: inflight carries NO age and NO token (same shape as warming)',
    (() => { const st = classifyWslMonitorState(STALE, STALE2, 490 * S, true, 0);
             return !!st && st.kind === 'inflight' && st.ageMs === null && st.token === ''; })());
  check('classify5: two FRESH logs under the allowance are NOT inflight (nothing to wait for) → silent',
    k5(FRESH, FRESH, UP, true, 0) === '-', `got ${k5(FRESH, FRESH, UP, true, 0)}`);
  check('classify5: missing beside a STALE sibling falls through to the sibling\'s verdict (not *-missing)',
    k5(null, STALE, UP, true, 3600 * S) === 'census 5760', `got ${k5(null, STALE, UP, true, 3600 * S)}`);
  check('classify5: the grace still wins over the allowance (step 1 before step 2)',
    k5(STALE, STALE, 100 * S, false, 0) === 'warming -', `got ${k5(STALE, STALE, 100 * S, false, 0)}`);
  check('classify5: 4-arg legacy call (stampAgeMs undefined) behaves exactly as null — never inflight / unfinished',
    k5(STALE, FRESH, UP, true, undefined) === 'pressure 5760' && k5(STALE, FRESH, UP, true, null) === 'pressure 5760',
    `got ${k5(STALE, FRESH, UP, true, undefined)} / ${k5(STALE, FRESH, UP, true, null)}`);
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
  // WARMING — the boot grace. Suppresses BOTH flags like 'monitor', but renders no token of
  // its own, so the front carries the trip alone. Inversion guard: the two assertions below
  // differ in WHICH tokens survive, so a `warming` arm that suppressed nothing fails the
  // first and a blanket suppression fails the 'arbitrate: no liveness state' case above.
  // Built explicitly, NOT via c(): that helper substitutes a 'DEAD' token whenever `kind` is
  // truthy, and warming's defining property is that its token is EMPTY.
  check('arbitrate: warming → BOTH self-clearing flags suppressed, trip alone remains',
    JSON.stringify(composeWslFront({ trip: 'TRIP', monitor: { token: '', kind: 'warming' }, broken: 'BROKEN', bypass: { token: 'BYPASS', fault: 'BYPASS' } })) === JSON.stringify(['TRIP']));
  check('arbitrate: warming renders NO liveness token even if one were somehow handed in',
    JSON.stringify(composeWslFront({ trip: '', monitor: { token: '', kind: 'warming' }, broken: 'BROKEN', bypass: { token: 'BYPASS', fault: 'BYPASS' } })) === JSON.stringify([]));
  // SUPPRESSION TABLE for the 2026-09-19 kinds (brief § 4). Keyed on `kind`, never on
  // per-producer status. inflight is built explicitly like warming (empty token).
  check('arbitrate: inflight → BOTH self-clearing flags suppressed, trip alone remains, no token',
    JSON.stringify(composeWslFront({ trip: 'TRIP', monitor: { token: '', kind: 'inflight' }, broken: 'BROKEN', bypass: { token: 'BYPASS', fault: 'BYPASS' } })) === JSON.stringify(['TRIP']));
  check('arbitrate: monitor-missing → both suppressed (both producers implicated)',
    JSON.stringify(c('monitor-missing')) === JSON.stringify(['TRIP', 'DEAD']));
  check('arbitrate: monitor-unfinished → both suppressed (both producers implicated — the one process hung whole)',
    JSON.stringify(c('monitor-unfinished')) === JSON.stringify(['TRIP', 'DEAD']));
  check('arbitrate: pressure-missing → probe-broken suppressed, cap-bypass KEPT',
    JSON.stringify(c('pressure-missing')) === JSON.stringify(['TRIP', 'DEAD', 'BYPASS']));
  check('arbitrate: pressure-unfinished → probe-broken suppressed, cap-bypass KEPT',
    JSON.stringify(c('pressure-unfinished')) === JSON.stringify(['TRIP', 'DEAD', 'BYPASS']));
  check('arbitrate: census-missing → cap-bypass suppressed, probe-broken KEPT',
    JSON.stringify(c('census-missing')) === JSON.stringify(['TRIP', 'DEAD', 'BROKEN']));
  check('arbitrate: census-unfinished → cap-bypass suppressed, probe-broken KEPT',
    JSON.stringify(c('census-unfinished')) === JSON.stringify(['TRIP', 'DEAD', 'BROKEN']));
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
  // Stamp aged 7min against 490s (8.17min) uptime → fired THIS boot → grace ends, stale logs
  // count. 7min, not 1min (re-pinned 2026-09-19): a 1-min-old stamp is INSIDE the 6-min
  // run-completion allowance and now classifies `inflight` (that fixture lives in the inflight
  // render block below); the assertion here is "stamp fired ends the grace", which needs the
  // stamp past the allowance but still younger than uptime. The verdict that renders is
  // `wsl:monitor-unfinished` (round 2): an alive stamp beside two stale logs is the producer
  // that hung whole, not a dead timer — `wsl:monitor-dead` needs a stamp that itself is dead,
  // which a stamp fired inside a 490 s uptime cannot be.
  const out = runWith({ pressureMin: 540, censusMin: 540, uptimeMs: String(490 * 1000), stampMin: 7 });
  check('stamp fired this boot + stale logs → ⚠ wsl:monitor-unfinished renders (grace ended early; alive stamp → not monitor-dead)',
    livenessToken(out).startsWith('wsl:monitor-unfinished'),
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

// =========================================================================
// THE BOOT GRACE MEANS "NOT YET VOUCHED", NOT "TRUSTED" (2026-09-19)
// Required behaviour from .planning/backlog/2026-08-15-wsl-monitor-boot-grace-means-trusted.md
// (cross-repo): uptime INSIDE the grace + no stamp + both logs stale + an old broken flag +
// an old bypass flag + a trip flag  =>  trip token RENDERS, broken and bypass are SUPPRESSED,
// and NO liveness token is emitted. Both flags are producer-self-clearing, so one that
// survived the reboot is unvouched by construction — the producer would have rewritten or
// removed it on a healthy run, and no producer has run yet.
//
// Driven THROUGH THE RENDER PATH (real wrapper spawn), not the pure classifier: the pure
// arbitration cases above pin composeWslFront, but only a render proves readWslMonitorState
// actually propagates kind='warming' into it with an empty token.
// =========================================================================
{
  const out = runWith({
    pressureMin: 540, censusMin: 540, uptimeMs: String(5 * 60 * 1000), stampMin: null,
    trip: TRIP(447), broken: 'stale break', bypass: BYPASS_SEAM_BROKEN,
  });
  const ok = out.includes(TRIP_TOKEN(447))
    && !out.includes(BROKEN_TOKEN) && !out.includes(BYPASS_TOKEN)
    && livenessToken(out) === '' && !out.includes(MONITOR_SIGIL);
  check('warming (live): in-grace + all three flags → trip renders, broken + bypass SUPPRESSED, no liveness token', ok,
    ok ? '' : `trip=${out.includes(TRIP_TOKEN(447))} broken=${out.includes(BROKEN_TOKEN)} bypass=${out.includes(BYPASS_TOKEN)} liveness=${JSON.stringify(livenessToken(out))}; output: ${JSON.stringify(out)}`);
}

// --- NEGATIVE ARM (a): the same fixture with a stamp newer than boot. The grace ends, the
// --- stale logs become real evidence, and a RED liveness verdict renders. Without this, "no
// --- liveness token" above is satisfied by a wrapper that never renders one at all. Re-pinned
// --- 2026-09-19 from (5 min uptime, 1 min stamp) to (8 min uptime, 7 min stamp): the stamp
// --- must be past the 6-min run-completion allowance to assert a verdict, and still younger
// --- than uptime to count as fired this boot; 8 min is still inside the 12-min grace ceiling,
// --- so the stamp is what ends the grace. The verdict is `wsl:monitor-unfinished` (round 2):
// --- a 7-min stamp is alive, so two stale logs are the run that hung, not a dead timer.
{
  const out = runWith({
    pressureMin: 540, censusMin: 540, uptimeMs: String(8 * 60 * 1000), stampMin: 7,
    trip: TRIP(447), broken: 'stale break', bypass: BYPASS_SEAM_BROKEN,
  });
  const ok = out.includes(TRIP_TOKEN(447))
    && livenessToken(out).startsWith('wsl:monitor-unfinished') && !out.includes(MONITOR_SIGIL);
  check('warming NEGATIVE ARM: stamp newer than boot + stale logs → grace over, ⚠ wsl:monitor-unfinished renders', ok,
    ok ? '' : `trip=${out.includes(TRIP_TOKEN(447))} liveness=${JSON.stringify(livenessToken(out))}; output: ${JSON.stringify(out)}`);
}

// --- NEGATIVE ARM (b): stamp newer than boot + FRESH logs + all three flags. Nothing is
// --- stale, so nothing is suppressed and all three flag tokens render. This is the arm that
// --- catches a blanket suppression: a `warming` implementation that suppressed on every
// --- in-grace-capable path, or one keyed on uptime rather than on the classified kind,
// --- passes the required-behaviour case above and fails here.
{
  const out = runWith({
    pressureMin: 1, censusMin: 1, uptimeMs: String(5 * 60 * 1000), stampMin: 1,
    trip: TRIP(447), broken: 'fresh break', bypass: BYPASS_SEAM_BROKEN,
  });
  const ok = out.includes(TRIP_TOKEN(447)) && out.includes(BROKEN_TOKEN) && out.includes(BYPASS_TOKEN)
    && livenessToken(out) === '' && !out.includes(MONITOR_SIGIL);
  check('warming NEGATIVE ARM: stamp fired + fresh logs → all three flag tokens render (suppression is not blanket)', ok,
    ok ? '' : `trip=${out.includes(TRIP_TOKEN(447))} broken=${out.includes(BROKEN_TOKEN)} bypass=${out.includes(BYPASS_TOKEN)} liveness=${JSON.stringify(livenessToken(out))}; output: ${JSON.stringify(out)}`);
}

// =========================================================================
// RUN-COMPLETION ALLOWANCE + MISSING / UNFINISHED ARMS — RENDER PATH (2026-09-19)
// Real wrapper spawn under _make-fake-home: proves readWslMonitorState reads the stamp's AGE,
// propagates the new kinds into the token + composeWslFront, and never interpolates a hole
// (`undefined` / `NaN`) or an invented age for a missing log. Each fixture plants all three
// flags so the suppression table (brief § 4) is observed, not inferred.
// =========================================================================

// --- census-missing: pressure fresh, census log ABSENT, stamp fired 60 min ago. The fresh
// --- sibling is the install evidence. Token has NO age; probe-broken stays CURRENT (pressure
// --- is fine), cap-bypass is SUPPRESSED (census un-vouched), trip renders.
{
  const out = runWith({
    pressureMin: 1, censusMin: null, stampMin: 60,
    trip: TRIP(447), broken: 'fresh break', bypass: BYPASS_SEAM_BROKEN,
  });
  const tok = livenessToken(out);
  const ok = tok === 'wsl:census-log-missing'
    && out.includes(TRIP_TOKEN(447)) && out.includes(BROKEN_TOKEN) && !out.includes(BYPASS_TOKEN)
    && NO_HOLES(out) && !out.includes(MONITOR_SIGIL);
  check('render: census log MISSING + pressure fresh → ⚠ wsl:census-log-missing with NO age; bypass suppressed, broken CURRENT, trip renders, no holes', ok,
    ok ? '' : `tok=${JSON.stringify(tok)} trip=${out.includes(TRIP_TOKEN(447))} broken=${out.includes(BROKEN_TOKEN)} bypass=${out.includes(BYPASS_TOKEN)} holes=${!NO_HOLES(out)}; output: ${JSON.stringify(out)}`);
}

// --- pressure-unfinished: stamp fired 10 min ago (past the 6-min allowance, well under the
// --- 95-min dead threshold), pressure log 96 min stale, census fresh. The timer is fine; the
// --- pressure producer ran and did not finish. Token carries the PRESSURE log's own age
// --- (96 min → 1h36m); probe-broken SUPPRESSED, cap-bypass CURRENT, trip renders.
{
  const out = runWith({
    pressureMin: 96, censusMin: 1, stampMin: 10,
    trip: TRIP(447), broken: 'stale break', bypass: BYPASS_SEAM_BROKEN,
  });
  const tok = livenessToken(out);
  const ok = tok === 'wsl:pressure-unfinished 1h36m'
    && out.includes(TRIP_TOKEN(447)) && !out.includes(BROKEN_TOKEN) && out.includes(BYPASS_TOKEN)
    && NO_HOLES(out) && !out.includes(MONITOR_SIGIL);
  check('render: stamp 10 min + pressure stale + census fresh → ⚠ wsl:pressure-unfinished 1h36m; broken suppressed, bypass CURRENT, trip renders', ok,
    ok ? '' : `tok=${JSON.stringify(tok)} trip=${out.includes(TRIP_TOKEN(447))} broken=${out.includes(BROKEN_TOKEN)} bypass=${out.includes(BYPASS_TOKEN)}; output: ${JSON.stringify(out)}`);
}

// --- monitor-unfinished (round 2, 2026-09-19): stamp fired 10 min ago (alive, past the
// --- allowance), BOTH logs 96 min stale, all three flags. The reviewer's counterexample —
// --- against the round-1 wrapper this rendered `wsl:monitor-dead 1h36m` and the pull twin sent
// --- the operator to restart a timer that had demonstrably just fired. Token carries the NEWER
// --- log age exactly as monitor-dead does; broken AND bypass SUPPRESSED (both producers
// --- implicated: one process, hung whole); trip renders.
{
  const out = runWith({
    pressureMin: 96, censusMin: 96, stampMin: 10,
    trip: TRIP(447), broken: 'stale break', bypass: BYPASS_SEAM_BROKEN,
  });
  const tok = livenessToken(out);
  const ok = tok === 'wsl:monitor-unfinished 1h36m'
    && out.includes(TRIP_TOKEN(447)) && !out.includes(BROKEN_TOKEN) && !out.includes(BYPASS_TOKEN)
    && NO_HOLES(out) && !out.includes(MONITOR_SIGIL);
  check('render: stamp 10 min + BOTH stale → ⚠ wsl:monitor-unfinished 1h36m; broken AND bypass suppressed, trip renders', ok,
    ok ? '' : `tok=${JSON.stringify(tok)} trip=${out.includes(TRIP_TOKEN(447))} broken=${out.includes(BROKEN_TOKEN)} bypass=${out.includes(BYPASS_TOKEN)}; output: ${JSON.stringify(out)}`);
}

// --- monitor-dead CONTROL: the same fixture with the stamp itself DEAD (100 min = 6000 s ≥ the
// --- 95-min threshold, still younger than the 72 h uptime so it counts as fired this boot).
// --- `wsl:monitor-dead` must stay reachable — this is the timer's story, and the reviewer must
// --- be able to see the round-2 arm did not swallow it. Same suppression, same NEWER-log age.
{
  const out = runWith({
    pressureMin: 96, censusMin: 96, stampMin: 100,
    trip: TRIP(447), broken: 'stale break', bypass: BYPASS_SEAM_BROKEN,
  });
  const tok = livenessToken(out);
  const ok = tok === 'wsl:monitor-dead 1h36m'
    && out.includes(TRIP_TOKEN(447)) && !out.includes(BROKEN_TOKEN) && !out.includes(BYPASS_TOKEN)
    && NO_HOLES(out) && !out.includes(MONITOR_SIGIL);
  check('render (control): stamp 100 min (DEAD) + BOTH stale → ⚠ wsl:monitor-dead 1h36m still renders; both flags suppressed, trip renders', ok,
    ok ? '' : `tok=${JSON.stringify(tok)} trip=${out.includes(TRIP_TOKEN(447))} broken=${out.includes(BROKEN_TOKEN)} bypass=${out.includes(BYPASS_TOKEN)}; output: ${JSON.stringify(out)}`);
}

// --- PREVIOUS-BOOT stamp (round 3, 2026-09-20): uptime 900 s (past the 720 s grace), stamp
// --- aged 901 s — older than uptime, so its mtime predates boot wall-time and the timer has
// --- NOT fired this boot — both logs 96 min stale, all three flags. The stamp is younger than
// --- the dead threshold, which round 2's age-only `stampAlive` read as alive and rendered
// --- `wsl:monitor-unfinished`; the scheduler never ran this boot, so it IS the story:
// --- `wsl:monitor-dead`, both flags suppressed, trip renders. (The wrapper derives
// --- fired-this-boot from mtime vs boot wall-time; spawn latency only ages the stamp further.)
{
  const out = runWith({
    pressureMin: 96, censusMin: 96, uptimeMs: String(900 * 1000), stampMin: 901 / 60,
    trip: TRIP(447), broken: 'stale break', bypass: BYPASS_SEAM_BROKEN,
  });
  const tok = livenessToken(out);
  const ok = tok === 'wsl:monitor-dead 1h36m'
    && out.includes(TRIP_TOKEN(447)) && !out.includes(BROKEN_TOKEN) && !out.includes(BYPASS_TOKEN)
    && NO_HOLES(out) && !out.includes(MONITOR_SIGIL);
  check('render (stampalive-class): previous-boot stamp 901 s @ uptime 900 s + BOTH stale → ⚠ wsl:monitor-dead 1h36m; both flags suppressed, trip renders', ok,
    ok ? '' : `tok=${JSON.stringify(tok)} trip=${out.includes(TRIP_TOKEN(447))} broken=${out.includes(BROKEN_TOKEN)} bypass=${out.includes(BYPASS_TOKEN)}; output: ${JSON.stringify(out)}`);
}

// --- inflight: 490 s uptime, stamp fired 1 min ago (inside the allowance), stale asymmetric
// --- logs, all three flags. This is the fixture that used to render `wsl:monitor-dead` the
// --- instant the stamp landed — before the producers could possibly have written. Now: trip
// --- renders, broken + bypass SUPPRESSED (awaiting the in-flight run), NO liveness token.
{
  const out = runWith({
    pressureMin: 96, censusMin: 285, uptimeMs: String(490 * 1000), stampMin: 1,
    trip: TRIP(447), broken: 'stale break', bypass: BYPASS_SEAM_BROKEN,
  });
  const ok = out.includes(TRIP_TOKEN(447))
    && !out.includes(BROKEN_TOKEN) && !out.includes(BYPASS_TOKEN)
    && livenessToken(out) === '' && NO_HOLES(out) && !out.includes(MONITOR_SIGIL);
  check('inflight (live): stamp 1 min + stale logs + all three flags → trip renders, broken + bypass SUPPRESSED, no liveness token', ok,
    ok ? '' : `trip=${out.includes(TRIP_TOKEN(447))} broken=${out.includes(BROKEN_TOKEN)} bypass=${out.includes(BYPASS_TOKEN)} liveness=${JSON.stringify(livenessToken(out))}; output: ${JSON.stringify(out)}`);
}

// --- inflight, FLAGS ABSENT (control): same fixture with no flags at all. The push surface is
// --- silent — no liveness token, no wsl:/claude: token of any kind, no sigil. Against the
// --- pre-change wrapper this renders `wsl:monitor-dead`, which is what makes the case
// --- non-vacuous; the pull surface's "IN FLIGHT" informational line is the bash twin's job.
{
  const out = runWith({ pressureMin: 96, censusMin: 285, uptimeMs: String(490 * 1000), stampMin: 1 });
  const ok = livenessToken(out) === '' && !out.includes(WSL_LABEL) && !out.includes(CLAUDE_LABEL)
    && NO_HOLES(out) && !out.includes(MONITOR_SIGIL);
  check('inflight (live, flags absent): stamp 1 min + stale logs, no flags → push silent (no token, no sigil)', ok,
    ok ? '' : `liveness=${JSON.stringify(livenessToken(out))}; output: ${JSON.stringify(out)}`);
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
