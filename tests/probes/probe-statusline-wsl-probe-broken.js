#!/usr/bin/env node
// Exercises statusline-wrapper's readWslProbeBroken() — the SECOND, distinct
// wsl-pressure consumer. Producer: ~/scripts/health/wsl-pressure-check.sh, which
// writes ~/.local/state/wsl-stack/wsl-pressure-broken.flag when the monitor ITSELF
// fails (probe errored / bash-count unparseable → exit 3, NO trip flag) and rm's it
// on the next healthy classify (ok/warn/crit). The trip reader says "a real leak was
// detected"; THIS says "the monitor is DEAD — no detection at all." The probe asserts
// the render contract:
//   - broken flag present (any content) → RED `\x1b[31m⚠ wsl:probe-broken\x1b[0m` renders
//   - broken flag present but empty      → renders (flag EXISTENCE is the signal)
//   - absent flag                        → SILENT (no `wsl:` token) — this IS the
//                                          auto-recovered / healthy-monitor state
//   - DISTINCT from the trip token       → with BOTH flags planted, `wsl:probe-broken`
//                                          and `wsl:bash=N` both render and are distinct
//   - TRIP FIRST, BROKEN SECOND          → with both, the trip token's index precedes
//                                          the broken token's (locked: trip is FIRST in
//                                          front[]; broken slots in right after it)
//   - FIRST among present members        → broken alone (no trip) precedes a coexisting
//                                          fleet token (it's pushed ahead of driftWarning)
//   - the fail-silent invariant          → a `⚠ wslProbeBroken?` sigil NEVER renders,
//                                          any state (own try/catch → '')
//
// Side-effects on real $HOME are zero — each spawn runs in an isolated tmpdir.
//
// Backs docs/decisions.md 2026-06-15 wsl-pressure probe-broken signal row (the
// dead-monitor push-surface gap fix, extending the same-day trip-flag alarm). Same
// runtime-assumption class as readWslPressure / readWatchHealth / readFleetFeed
// (cache/file-read segment, no new HP). Structural twin of
// probe-statusline-wsl-pressure.js.
// Run: node tests/probes/probe-statusline-wsl-probe-broken.js
//
// SAFE_FOR_LIVE: yes   (uses `_make-fake-home` (mktemp + HOME + CLAUDE_CONFIG_DIR override per spawn); broken/trip/fleet fixtures planted inside the tmp home; never touches live ~/.local/state/wsl-stack or ~/.cache/dhx)
const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const WRAPPER = path.resolve(__dirname, '..', '..', 'dhx', 'statusline-wrapper.js');
const { makeFakeHome } = require('./_make-fake-home');

// The probe-broken token is uniquely identified by its `wsl:probe-broken` label
// wrapped in RED (\x1b[31m) — the same imminent-OOM severity class as the trip token
// (blind ≥ tripped), deliberately NOT the orange-208 the advisory front members use.
const WSL_LABEL = 'wsl:';
const RED = '\x1b[31m';
const RESET = '\x1b[0m';
const BROKEN_TOKEN = `${RED}⚠ wsl:probe-broken${RESET}`;
const BROKEN_SIGIL = '⚠ wslProbeBroken?'; // the forbidden render — must NEVER appear

// Fleet token markers (used only by the FIRST-among-present coexistence case).
const FLEET_GLYPH = '▼';
const FLEET_LABEL = 'conv';
const FRESH = () => new Date().toISOString();
const j = (o) => JSON.stringify(o);

// Trip-flag content (reused by the distinct-from-trip + ordering case). Mirrors the
// producer's $FLAG line-1 format; the trip reader renders `\x1b[31m⚠ wsl:bash=N\x1b[0m`.
const TRIP = (n) => `2026-06-15T09:14:02-04:00 !! WSL process-pressure CRITICAL: bash=${n} (>400) climbing toward .wslconfig ceiling`;
const TRIP_TOKEN = (n) => `${RED}⚠ wsl:bash=${n}${RESET}`;

// Each spawn plants the broken flag (string) at
// <home>/.local/state/wsl-stack/wsl-pressure-broken.flag unless `broken === null`
// (absent — the healthy/recovered state), and optionally the trip flag and/or a fresh
// fleet feed.
function runWith({ broken, trip = null, fleet = null }) {
  const tmp = makeFakeHome('dhx-wsl-probe-broken-');
  try {
    const dir = path.join(tmp, '.local', 'state', 'wsl-stack');
    fs.mkdirSync(dir, { recursive: true });
    if (broken !== null) fs.writeFileSync(path.join(dir, 'wsl-pressure-broken.flag'), broken);
    if (trip !== null) fs.writeFileSync(path.join(dir, 'wsl-pressure-trip.flag'), trip);
    if (fleet) fs.writeFileSync(path.join(tmp, '.cache', 'dhx', 'fleet-statusline.json'), fleet);
    const res = spawnSync(process.execPath, [WRAPPER], {
      input: JSON.stringify({ session_id: 'probe-wsl-probe-broken', version: '2.1.177' }),
      env: { ...process.env, HOME: tmp, CLAUDE_CONFIG_DIR: path.join(tmp, '.claude') },
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

// --- broken flag present (with content) → RED token renders ---
{
  const out = runWith({ broken: '2026-06-16T02:00:02Z !! wsl-pressure-check: probe BROKEN (rc=2) — monitor not detecting' });
  check('broken flag (with content) → wsl:probe-broken token',
    out.includes(BROKEN_TOKEN) && !out.includes(BROKEN_SIGIL),
    `expected ${JSON.stringify(BROKEN_TOKEN)} + no sigil; output: ${JSON.stringify(out)}`);
}

// --- broken flag present but EMPTY → existence is the signal ---
{
  const out = runWith({ broken: '' });
  check('empty broken flag → wsl:probe-broken (flag EXISTENCE is the signal)',
    out.includes(BROKEN_TOKEN) && !out.includes(BROKEN_SIGIL),
    `expected ${JSON.stringify(BROKEN_TOKEN)} + no sigil; output: ${JSON.stringify(out)}`);
}

// --- absent broken flag → SILENT (healthy / auto-recovered monitor) ---
{
  const out = runWith({ broken: null });
  check('absent broken flag → segment silent (healthy/recovered monitor)',
    !out.includes(WSL_LABEL) && !out.includes(BROKEN_SIGIL),
    `expected NO wsl: token + no sigil; output: ${JSON.stringify(out)}`);
}

// --- DISTINCT from the trip token, and TRIP FIRST / BROKEN SECOND when both coexist ---
// (a stale durable trip flag outliving a fresh break: both RED tokens render, trip leftmost) ---
{
  const out = runWith({ broken: 'fresh break', trip: TRIP(447) });
  const tripIdx = out.indexOf(TRIP_TOKEN(447));
  const brokenIdx = out.indexOf(BROKEN_TOKEN);
  const ok = tripIdx >= 0 && brokenIdx >= 0 && tripIdx < brokenIdx && !out.includes(BROKEN_SIGIL);
  check('both flags → trip + probe-broken both render, DISTINCT, trip FIRST / broken SECOND', ok,
    ok ? '' : `tripIdx=${tripIdx} brokenIdx=${brokenIdx} (want trip<broken, both >=0); output: ${JSON.stringify(out)}`);
}

// --- broken alone FIRST among present front members: precedes a coexisting fleet token ---
{
  const out = runWith({ broken: 'fresh break', fleet: j({ schema_version: 1, required_newly_missing: 3, computed_at: FRESH() }) });
  const brokenIdx = out.indexOf(BROKEN_TOKEN);
  const fleetIdx = out.indexOf(`${FLEET_GLYPH}3 ${FLEET_LABEL}`);
  const ok = brokenIdx >= 0 && fleetIdx >= 0 && brokenIdx < fleetIdx && !out.includes(BROKEN_SIGIL);
  check('broken alone precedes coexisting fleet token (first among present front members)', ok,
    ok ? '' : `brokenIdx=${brokenIdx} fleetIdx=${fleetIdx}; output: ${JSON.stringify(out)}`);
}

console.log('---');
console.log(`PASS: ${pass}  FAIL: ${fail}`);
process.exit(fail);
