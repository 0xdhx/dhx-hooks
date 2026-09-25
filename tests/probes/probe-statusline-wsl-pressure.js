#!/usr/bin/env node
// Exercises statusline-wrapper's readWslPressure() — the consumer half of the
// wsl-pressure.timer tripwire (producer: ~/scripts/health/wsl-pressure-check.sh,
// which writes ~/.local/state/wsl-stack/wsl-pressure-trip.flag on a `!!` bash-leak
// trip). The flag was write-only until this segment; the probe asserts the render
// contract that closes that gap:
//   - flag present w/ `bash=N` line → RED `\x1b[31m⚠ wsl:bash=N\x1b[0m` token renders
//   - flag present w/ no `bash=N`   → RED `\x1b[31m⚠ wsl:pressure\x1b[0m` fallback label
//   - flag present but empty        → fallback renders (flag EXISTENCE is the signal —
//                                     durable until the operator rm's it, NOT content-gated)
//   - absent flag                   → segment is SILENT (no `wsl:` token)
//   - FIRST in front                → with a coexisting fleet token, the wsl token's
//                                     index precedes the fleet token's (placed before
//                                     driftWarning, ahead of all orange-208 members)
//   - the fail-silent invariant     → a `⚠ wslPressure?` sigil NEVER renders, any state
//                                     (mirrors fleet/watch/skillPressure — own try/catch → '')
//
// Side-effects on real $HOME are zero — each spawn runs in an isolated tmpdir.
//
// write-only-flag-gap fix). Same runtime-assumption class as readFleetFeed /
// readWatchHealth / readSkillPressure (cache-read segment, no new HP). Structural
// twin of probe-fleet-statusline-render.js.
// Run: node tests/probes/probe-statusline-wsl-pressure.js
//
// SAFE_FOR_LIVE: yes   (uses `_make-fake-home` (mktemp + HOME + CLAUDE_CONFIG_DIR override per spawn); flag + fleet fixtures planted inside the tmp home; never touches live ~/.local/state/wsl-stack or ~/.cache/dhx)
const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const WRAPPER = path.resolve(__dirname, '..', '..', 'dhx', 'statusline-wrapper.js');
const { makeFakeHome } = require('./_make-fake-home');

// The wsl-pressure token is uniquely identified by its `wsl:` label (no other
// segment emits it) wrapped in RED (\x1b[31m) — deliberately NOT the orange-208
// (\x1b[38;5;208m) the other front members use: a !! trip is imminent-OOM, not
// advisory. The forbidden render is the fail-silent-violating sigil.
const WSL_LABEL = 'wsl:';
const RED = '\x1b[31m';
const RESET = '\x1b[0m';
const WSL_SIGIL = '⚠ wslPressure?'; // the forbidden render — must NEVER appear

// Fleet token markers (used only by the FIRST-in-front coexistence case).
const FLEET_GLYPH = '▼';
const FLEET_LABEL = 'conv';
const FRESH = () => new Date().toISOString();

// Each spawn plants `flag` (string) at <home>/.local/state/wsl-stack/wsl-pressure-trip.flag
// unless `flag === null` (absent state — nothing written), and optionally a fresh fleet
// feed at <home>/.cache/dhx/fleet-statusline.json when `fleet` is provided.
function runWith(flag, fleet) {
  const tmp = makeFakeHome('dhx-wsl-pressure-probe-');
  try {
    if (flag !== null) {
      const dir = path.join(tmp, '.local', 'state', 'wsl-stack');
      fs.mkdirSync(dir, { recursive: true });
      fs.writeFileSync(path.join(dir, 'wsl-pressure-trip.flag'), flag);
    }
    if (fleet) {
      fs.writeFileSync(path.join(tmp, '.cache', 'dhx', 'fleet-statusline.json'), fleet);
    }
    const res = spawnSync(process.execPath, [WRAPPER], {
      input: JSON.stringify({ session_id: 'probe-wsl-pressure', version: '2.1.177' }),
      env: { ...process.env, HOME: tmp, CLAUDE_CONFIG_DIR: path.join(tmp, '.claude') },
      encoding: 'utf8',
      timeout: 5000,
    });
    return res.stdout || '';
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

const j = (o) => JSON.stringify(o);
const TRIP = (n) => `2026-06-15T09:14:02-04:00 !! WSL process-pressure CRITICAL: bash=${n} (>400) climbing toward .wslconfig ceiling`;

const cases = [
  // --- trip present: RED token with the leaked-bash count ---
  { name: 'trip fresh (bash=447)',
    flag: TRIP(447),
    expectToken: `${RED}⚠ wsl:bash=447${RESET}` },
  { name: 'trip fresh (bash=405, just over the 400 gate)',
    flag: TRIP(405),
    expectToken: `${RED}⚠ wsl:bash=405${RESET}` },

  // --- trip present but no `bash=N` on line 1 → fallback label ---
  { name: 'trip line without bash=N → wsl:pressure fallback',
    flag: '2026-06-15T09:14:02-04:00 !! WSL process-pressure CRITICAL (count unavailable)',
    expectToken: `${RED}⚠ wsl:pressure${RESET}` },

  // --- flag exists but empty → existence is the signal (durable, content-agnostic) ---
  { name: 'empty flag file → wsl:pressure (flag EXISTENCE is the alarm)',
    flag: '',
    expectToken: `${RED}⚠ wsl:pressure${RESET}` },

  // --- absent flag → SILENT ---
  { name: 'absent flag → segment silent',
    flag: null,
    expectToken: null },
];

let pass = 0, fail = 0;

function check(name, ok, detail) {
  if (ok) { console.log(`  ✓ ${name}`); pass++; }
  else { console.log(`  ✗ ${name}`); if (detail) console.log(`      ${detail}`); fail++; }
}

for (const c of cases) {
  const out = runWith(c.flag, null);
  // The forbidden sigil must NEVER appear, in EVERY state (fail-silent invariant).
  const sigilAbsent = !out.includes(WSL_SIGIL);
  let ok, detail;
  if (c.expectToken) {
    ok = out.includes(c.expectToken) && sigilAbsent;
    detail = `expected token ${JSON.stringify(c.expectToken)} present + no sigil; output: ${JSON.stringify(out)}`;
  } else {
    // Silent: no `wsl:` label anywhere, and no sigil.
    ok = !out.includes(WSL_LABEL) && sigilAbsent;
    detail = `expected NO wsl: token + no sigil; output: ${JSON.stringify(out)}`;
  }
  check(c.name, ok, ok ? '' : detail);
}

// --- FIRST in front: with a coexisting fleet token (a known orange-208 front
// member, placed 5th), the wsl token must render BEFORE the fleet token. The
// wsl push is the FIRST line of the front[] assembly (before driftWarning), so
// its join-index precedes every other front member. ---
{
  const out = runWith(TRIP(512), j({ schema_version: 1, required_newly_missing: 3, computed_at: FRESH() }));
  const wslIdx = out.indexOf(`${RED}⚠ wsl:bash=512${RESET}`);
  const fleetIdx = out.indexOf(`${FLEET_GLYPH}3 ${FLEET_LABEL}`);
  const sigilAbsent = !out.includes(WSL_SIGIL);
  const ok = wslIdx >= 0 && fleetIdx >= 0 && wslIdx < fleetIdx && sigilAbsent;
  check('FIRST in front (wsl token precedes coexisting fleet token)', ok,
    ok ? '' : `wslIdx=${wslIdx} fleetIdx=${fleetIdx} sigilAbsent=${sigilAbsent}; output: ${JSON.stringify(out)}`);
}

console.log('---');
console.log(`PASS: ${pass}  FAIL: ${fail}`);
process.exit(fail);
