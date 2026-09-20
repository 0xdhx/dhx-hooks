#!/usr/bin/env node
// Exercises statusline-wrapper's readClaudeCapBypass() — the consumer for the
// claude-cap census flag. Producer: cross-repo health/scripts/claude-cap-census.sh
// (rides wsl-pressure.timer every 30 min), which writes
// ~/.local/state/wsl-stack/claude-cap-bypass.flag when the Claude memory cap is NOT
// applying and rm's it on a clean run (NON-STICKY, unlike the operator-cleared trip
// flag). The flag's machine line carries `capped=N uncapped=N seam_ok=K`. The probe
// asserts the render contract:
//   - seam_ok=0                    → RED `⚠ claude:seam-broken uncapped=N` (the seam is
//                                    dead for every FUTURE launch — blind ≥ tripped)
//   - seam_ok=1, uncapped>0        → orange-208 `claude:uncapped=N` (roots outside the
//                                    cap, healthy seam — advisory, NOT act-now)
//   - appended fields (2026-09-18) → the census appends ` misplaced=P scopes=S` after
//                                    seam_ok; the first three arms render byte-identically
//   - seam_ok=1, uncapped=0,       → DIM `claude:misplaced=P`, never a bypass label. That
//     misplaced=P>0                  it is NOT a meta-glyph fault is asserted where the glyph
//                                    has a clean baseline: probe-statusline-metaglyph-front-
//                                    agreement.js § 2 ('cap misplaced alone' → ∙). This
//                                    probe's fake home carries a standing tail token, so a
//                                    glyph comparison here is vacuous (measured: ⌃ with no flag).
//   - unparseable flag content     → orange-208 `claude:bypass` (never go silent on a
//                                    real bypass; mirrors readWslPressure's fallback)
//   - pre-seam_ok-format flag      → `claude:bypass` (a lingering old-format flag has
//                                    uncapped=N but no seam_ok= — degrades, not crashes)
//   - absent flag                  → SILENT (census-clean / healthy state)
//   - ordering                     → with wsl trip + wsl broken + cap-bypass all planted,
//                                    the cap token renders THIRD (after both wsl REDs)
//   - FIRST-class severity slot    → seam-broken alone precedes a coexisting fleet token
//   - the fail-silent invariant    → a `⚠ claudeCapBypass?` sigil NEVER renders (own
//                                    try/catch → '')
//
// Side-effects on real $HOME are zero — each spawn runs in an isolated tmpdir.
//
// Backs docs/decisions.md 2026-08-12 claude-cap-bypass statusline consumer row (closes
// cross-repo .planning/backlog/2026-08-11-claude-cap-bypass-flag-statusline-consumer.md).
// Same runtime-assumption class as readWslPressure / readWslProbeBroken / readWatchHealth
// (cache/file-read segment, no new HP). Structural twin of
// probe-statusline-wsl-probe-broken.js.
// Run: node tests/probes/probe-statusline-claude-cap-bypass.js
//
// SAFE_FOR_LIVE: yes   (uses `_make-fake-home` (mktemp + HOME + CLAUDE_CONFIG_DIR override per spawn); bypass/trip/broken/fleet fixtures planted inside the tmp home; pins the boot grace out with DHX_WSL_UPTIME_MS so /proc/uptime is never consulted; never touches live ~/.local/state/wsl-stack or ~/.cache/dhx)
const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const WRAPPER = path.resolve(__dirname, '..', '..', 'dhx', 'statusline-wrapper.js');
const { makeFakeHome } = require('./_make-fake-home');

const RED = '\x1b[31m';
const ORANGE = '\x1b[38;5;208m';
const RESET = '\x1b[0m';
const SEAM_TOKEN = (n) => `${RED}⚠ claude:seam-broken uncapped=${n}${RESET}`;
const RESIDUE_TOKEN = (n) => `${ORANGE}claude:uncapped=${n}${RESET}`;
const FALLBACK_TOKEN = `${ORANGE}claude:bypass${RESET}`;
const CAP_SIGIL = '⚠ claudeCapBypass?'; // the forbidden render — must NEVER appear
const ANY_CAP_LABELS = ['claude:seam-broken', 'claude:uncapped=', 'claude:bypass'];

// wsl fixtures (reused by the ordering case). Mirror the wsl producers' formats.
const TRIP = (n) => `2026-08-12T02:14:02-04:00 !! WSL process-pressure CRITICAL: bash=${n} (>400) climbing toward .wslconfig ceiling`;
const TRIP_TOKEN = (n) => `${RED}⚠ wsl:bash=${n}${RESET}`;
const BROKEN_TOKEN = `${RED}⚠ wsl:probe-broken${RESET}`;
const FLEET_GLYPH = '▼';
const FLEET_LABEL = 'conv';
const FRESH = () => new Date().toISOString();
const j = (o) => JSON.stringify(o);

// Flag fixture mirroring the producer's real bypass-branch output (census.sh writes
// REASONS on line 1, the machine line second, prose after).
const FLAG = ({ capped = 9, uncapped = 0, seam_ok = 1 }) => [
  `=== 2026-08-12 02:19:40 !! CLAUDE CAP BYPASS: login shell resolves claude to '/home/dhx/.local/bin/claude' not '/home/dhx/.local/capbin/claude'; `,
  `  capped=${capped} uncapped=${uncapped} seam_ok=${seam_ok}`,
  '  seam: login-shell `claude` -> /home/dhx/.local/bin/claude  (want /home/dhx/.local/capbin/claude)',
  '  Do NOT kill it to clear this flag — it holds a user\'s work.',
].join('\n');

const DIM = '\x1b[2m';
const MISPLACED_TOKEN = (n) => `${DIM}claude:misplaced=${n}${RESET}`;
// Current producer shape (cross-repo claude-cap-census.sh c6cf10ba1): appended fields.
const FLAG2 = ({ capped = 18, uncapped = 0, seam_ok = 1, misplaced = 0, scopes = 10 }) => [
  `=== 2026-09-18 04:44:30 !! CLAUDE CAP ${uncapped > 0 || seam_ok === 0 ? 'BYPASS' : 'MISPLACED'}: reasons; `,
  `  capped=${capped} uncapped=${uncapped} seam_ok=${seam_ok} misplaced=${misplaced} scopes=${scopes}`,
  '  misplaced roots (background role in an interactive session\'s scope):',
  '    pid=55834 role=daemon scope=claude-cap-88372.scope unit_rss_kb=4719324 children: bg-host=11',
].join('\n');

// Pre-seam_ok producer format (before cross-repo 02dc97bf): machine line lacks seam_ok=.
const OLD_FLAG = '=== 2026-08-11 20:00:00 !! CLAUDE CAP BYPASS: 1 claude proc(s) outside claude-cap-*.scope; \n  capped=42 uncapped=1\n  seam: login-shell `claude` -> /home/dhx/.local/capbin/claude  (want /home/dhx/.local/capbin/claude)';

function runWith({ bypass = null, trip = null, broken = null, fleet = null }) {
  const tmp = makeFakeHome('dhx-claude-cap-bypass-');
  try {
    const dir = path.join(tmp, '.local', 'state', 'wsl-stack');
    fs.mkdirSync(dir, { recursive: true });
    if (bypass !== null) fs.writeFileSync(path.join(dir, 'claude-cap-bypass.flag'), bypass);
    if (trip !== null) fs.writeFileSync(path.join(dir, 'wsl-pressure-trip.flag'), trip);
    if (broken !== null) fs.writeFileSync(path.join(dir, 'wsl-pressure-broken.flag'), broken);
    if (fleet) fs.writeFileSync(path.join(tmp, '.cache', 'dhx', 'fleet-statusline.json'), fleet);
    const res = spawnSync(process.execPath, [WRAPPER], {
      input: JSON.stringify({ session_id: 'probe-claude-cap-bypass', version: '2.1.227' }),
      // DHX_WSL_UPTIME_MS pins the boot grace OUT (72h). Load-bearing since 2026-09-19: the
      // grace now classifies as kind='warming', which suppresses probe-broken AND cap-bypass
      // (a producer-self-clearing flag that survived a reboot is unvouched by construction).
      // Unpinned, this fixture reads the HOST's /proc/uptime — so every assertion below would
      // silently invert for the first 12 minutes after a WSL2 reboot, and the suite would be
      // green on any other day. /proc/uptime is not under $HOME, so makeFakeHome cannot reach
      // it; this override is the only lever.
      env: { ...process.env, HOME: tmp, CLAUDE_CONFIG_DIR: path.join(tmp, '.claude'), DHX_WSL_UPTIME_MS: String(72 * 3600 * 1000) },
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

// --- seam_ok=0 → RED seam-broken token with the parsed uncapped count ---
{
  const out = runWith({ bypass: FLAG({ capped: 9, uncapped: 1, seam_ok: 0 }) });
  check('seam_ok=0 → RED ⚠ claude:seam-broken uncapped=1',
    out.includes(SEAM_TOKEN(1)) && !out.includes(CAP_SIGIL),
    `expected ${JSON.stringify(SEAM_TOKEN(1))} + no sigil; output: ${JSON.stringify(out)}`);
}

// --- seam_ok=1, uncapped>0 → orange residue token (advisory, NOT RED) ---
{
  const out = runWith({ bypass: FLAG({ capped: 40, uncapped: 2, seam_ok: 1 }) });
  check('seam_ok=1 uncapped=2 → orange claude:uncapped=2 (no RED)',
    out.includes(RESIDUE_TOKEN(2)) && !out.includes('claude:seam-broken') && !out.includes(CAP_SIGIL),
    `expected ${JSON.stringify(RESIDUE_TOKEN(2))}, no seam-broken; output: ${JSON.stringify(out)}`);
}

// --- unparseable flag content → orange fallback (never silent on a real bypass) ---
{
  const out = runWith({ bypass: 'some future format this reader does not know' });
  check('unparseable flag → orange claude:bypass fallback',
    out.includes(FALLBACK_TOKEN) && !out.includes(CAP_SIGIL),
    `expected ${JSON.stringify(FALLBACK_TOKEN)}; output: ${JSON.stringify(out)}`);
}

// --- lingering pre-seam_ok-format flag → fallback, not a crash or a wrong class ---
{
  const out = runWith({ bypass: OLD_FLAG });
  check('old-format flag (no seam_ok=) → claude:bypass (graceful degrade)',
    out.includes(FALLBACK_TOKEN) && !out.includes('claude:seam-broken') && !out.includes(CAP_SIGIL),
    `expected ${JSON.stringify(FALLBACK_TOKEN)}; output: ${JSON.stringify(out)}`);
}

// --- absent flag → SILENT (census-clean) ---
{
  const out = runWith({ bypass: null });
  check('absent flag → segment silent (cap applying)',
    ANY_CAP_LABELS.every(l => !out.includes(l)) && !out.includes(CAP_SIGIL),
    `expected no claude-cap token + no sigil; output: ${JSON.stringify(out)}`);
}

// --- ordering: trip FIRST, probe-broken SECOND, cap-bypass THIRD ---
{
  const out = runWith({ bypass: FLAG({ uncapped: 1, seam_ok: 0 }), trip: TRIP(447), broken: 'fresh break' });
  const tripIdx = out.indexOf(TRIP_TOKEN(447));
  const brokenIdx = out.indexOf(BROKEN_TOKEN);
  const capIdx = out.indexOf(SEAM_TOKEN(1));
  const ok = tripIdx >= 0 && brokenIdx >= 0 && capIdx >= 0 && tripIdx < brokenIdx && brokenIdx < capIdx && !out.includes(CAP_SIGIL);
  check('all three planted → trip < probe-broken < cap-bypass (severity-sorted front)', ok,
    ok ? '' : `tripIdx=${tripIdx} brokenIdx=${brokenIdx} capIdx=${capIdx}; output: ${JSON.stringify(out)}`);
}

// --- seam-broken alone precedes a coexisting orange fleet token ---
{
  const out = runWith({ bypass: FLAG({ uncapped: 1, seam_ok: 0 }), fleet: j({ schema_version: 1, required_newly_missing: 3, computed_at: FRESH() }) });
  const capIdx = out.indexOf(SEAM_TOKEN(1));
  const fleetIdx = out.indexOf(`${FLEET_GLYPH}3 ${FLEET_LABEL}`);
  const ok = capIdx >= 0 && fleetIdx >= 0 && capIdx < fleetIdx && !out.includes(CAP_SIGIL);
  check('seam-broken alone precedes coexisting fleet token', ok,
    ok ? '' : `capIdx=${capIdx} fleetIdx=${fleetIdx}; output: ${JSON.stringify(out)}`);
}

// --- appended fields: the first three arms render byte-identically ---
{
  const out = runWith({ bypass: FLAG2({ uncapped: 2, misplaced: 3 }) });
  check('appended fields, uncapped=2 misplaced=3 → orange claude:uncapped=2 (byte-identical)',
    out.includes(RESIDUE_TOKEN(2)) && !out.includes('claude:misplaced') && !out.includes(CAP_SIGIL),
    `expected ${JSON.stringify(RESIDUE_TOKEN(2))}; output: ${JSON.stringify(out)}`);
}
{
  const out = runWith({ bypass: FLAG2({ uncapped: 0, seam_ok: 0, misplaced: 3 }) });
  check('appended fields, seam_ok=0 → RED seam-broken (byte-identical)',
    out.includes(SEAM_TOKEN(0)) && !out.includes(CAP_SIGIL),
    `expected ${JSON.stringify(SEAM_TOKEN(0))}; output: ${JSON.stringify(out)}`);
}

// --- misplaced only → DIM token, no bypass claim ---
{
  const out = runWith({ bypass: FLAG2({ uncapped: 0, misplaced: 9 }) });
  check('misplaced only → dim claude:misplaced=9, never claude:bypass / uncapped / seam-broken',
    out.includes(MISPLACED_TOKEN(9)) && !out.includes('claude:bypass') && !out.includes('claude:uncapped=')
      && !out.includes('claude:seam-broken') && !out.includes(CAP_SIGIL),
    `expected ${JSON.stringify(MISPLACED_TOKEN(9))}; output: ${JSON.stringify(out)}`);
}

console.log('---');
console.log(`PASS: ${pass}  FAIL: ${fail}`);
process.exit(fail);
