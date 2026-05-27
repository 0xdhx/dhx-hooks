#!/usr/bin/env node
// Exercises statusline-wrapper's readFleetFeed() (SURF-02 render half, phase-10)
// against fixture fleet-statusline.json feeds by spawning the wrapper with HOME
// pointed at a temp dir. Verifies the always-visible fleet-drift segment:
//   - newly-missing fresh → orange-208 ▼N conv token renders, NEVER a ⚠ fleet? sigil
//   - zero-drift / stale / absent / malformed → segment is SILENT (no token), NEVER a sigil
// Side-effects on real $HOME are zero — each spawn runs in an isolated tmpdir.
//
// Backs docs/decisions.md phase-10 SURF-02 render-half row + the D-14 resource-
// safety + D-03d fail-silent invariants on dhx/statusline-wrapper.js::readFleetFeed.
// Feed contract producer: cross-repo scripts/fleet/emit-statusline-feed.cjs.
// Run: node tests/probes/probe-fleet-statusline-render.js
//
// SAFE_FOR_LIVE: yes   (uses `_make-fake-home` (mktemp + HOME override per spawn); fully sandboxed)
const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const WRAPPER = path.resolve(__dirname, '..', '..', 'dhx', 'statusline-wrapper.js');
const { makeFakeHome } = require('./_make-fake-home');

// The fleet token is uniquely identified by its `conv` label (no other segment
// emits it) and the ▼ glyph. The orange code \x1b[38;5;208m alone is NOT a
// reliable marker — drift and critical-health also use orange-208.
const FLEET_LABEL = 'conv';
const FLEET_GLYPH = '▼'; // ▼ U+25BC
const ORANGE_208 = '\x1b[38;5;208m';
const FLEET_SIGIL = '⚠ fleet?'; // ⚠ fleet? — the forbidden render

const FRESH = () => new Date().toISOString();
const STALE = () => new Date(Date.now() - 49 * 3600 * 1000).toISOString(); // 49h > ~48h gate

// Each spawn plants `feed` (string) at <home>/.cache/dhx/fleet-statusline.json,
// unless `feed === null` (absent state — nothing written).
function runWith(feed) {
  const tmp = makeFakeHome('dhx-fleet-probe-');
  try {
    if (feed !== null) {
      fs.writeFileSync(path.join(tmp, '.cache', 'dhx', 'fleet-statusline.json'), feed);
    }
    const res = spawnSync(process.execPath, [WRAPPER], {
      input: JSON.stringify({ session_id: 'probe-fleet', version: '2.1.112' }),
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

const cases = [
  // --- state 1: newly-missing fresh → token RENDERS ---
  { name: 'newly-missing fresh (count 3)',
    feed: j({ schema_version: 1, required_newly_missing: 3, computed_at: FRESH() }),
    expectToken: true, expectCount: '3' },

  { name: 'newly-missing fresh (count 1)',
    feed: j({ schema_version: 1, required_newly_missing: 1, computed_at: FRESH() }),
    expectToken: true, expectCount: '1' },

  // --- state 2: zero-drift → SILENT ---
  { name: 'zero-drift fresh',
    feed: j({ schema_version: 1, required_newly_missing: 0, computed_at: FRESH() }),
    expectToken: false },

  // --- state 3: stale → SILENT ---
  { name: 'stale (computed_at 49h old, count 5)',
    feed: j({ schema_version: 1, required_newly_missing: 5, computed_at: STALE() }),
    expectToken: false },

  // --- state 4: absent → SILENT ---
  { name: 'absent feed file',
    feed: null, expectToken: false },

  // --- state 5: malformed (several sub-variants) → SILENT ---
  { name: 'malformed: non-JSON garbage',
    feed: 'not json at all {{{', expectToken: false },
  { name: 'malformed: wrong schema_version (2)',
    feed: j({ schema_version: 2, required_newly_missing: 4, computed_at: FRESH() }),
    expectToken: false },
  { name: 'malformed: missing schema_version',
    feed: j({ required_newly_missing: 4, computed_at: FRESH() }),
    expectToken: false },
  { name: 'malformed: negative count',
    feed: j({ schema_version: 1, required_newly_missing: -2, computed_at: FRESH() }),
    expectToken: false },
  { name: 'malformed: non-integer count',
    feed: j({ schema_version: 1, required_newly_missing: 2.5, computed_at: FRESH() }),
    expectToken: false },
  { name: 'malformed: count as string',
    feed: j({ schema_version: 1, required_newly_missing: '3', computed_at: FRESH() }),
    expectToken: false },
  { name: 'malformed: NaN date (unparseable computed_at)',
    feed: j({ schema_version: 1, required_newly_missing: 3, computed_at: 'not-a-date' }),
    expectToken: false },
  { name: 'malformed: missing computed_at',
    feed: j({ schema_version: 1, required_newly_missing: 3 }),
    expectToken: false },
  { name: 'malformed: empty object',
    feed: j({}), expectToken: false },
];

let pass = 0, fail = 0;
for (const c of cases) {
  const out = runWith(c.feed);
  // The forbidden sigil must NEVER appear, in EVERY state.
  const sigilAbsent = !out.includes(FLEET_SIGIL);
  // Token presence: the unique `conv` label AND the ▼ glyph AND the orange code.
  const tokenPresent = out.includes(FLEET_LABEL) && out.includes(FLEET_GLYPH) && out.includes(ORANGE_208);
  let ok;
  if (c.expectToken) {
    const countOk = out.includes(`${FLEET_GLYPH}${c.expectCount} ${FLEET_LABEL}`);
    ok = tokenPresent && countOk && sigilAbsent;
  } else {
    // Silent: no `conv` label anywhere, and no sigil.
    ok = !out.includes(FLEET_LABEL) && sigilAbsent;
  }
  if (ok) {
    console.log(`  ✓ ${c.name}`);
    pass++;
  } else {
    console.log(`  ✗ ${c.name}`);
    console.log(`      expectToken=${c.expectToken} tokenPresent=${tokenPresent} sigilAbsent=${sigilAbsent}`);
    console.log(`      output: ${JSON.stringify(out)}`);
    fail++;
  }
}

console.log('---');
console.log(`PASS: ${pass}  FAIL: ${fail}`);
process.exit(fail);
