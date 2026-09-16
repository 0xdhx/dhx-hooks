'use strict';
// probe-statusline-metaglyph-front-agreement.js
//
// Pins the meta-glyph's CONTRACT against the front stack (docs/decisions.md 2026-08-15
// "meta-glyph input set re-derived from a stated contract").
//
// THE CONTRACT (see computeMetaGlyph's header for the full statement):
//   dim green ∙ = this session, and the telemetry needed to assess it, are CURRENTLY
//                 trustworthy. bright yellow ⌃ = a CURRENT condition makes it unsafe,
//                 stale, degraded, or materially untrustworthy. Latched history and
//                 workflow backlogs do NOT participate — they keep their own tokens.
//
// WHY THIS PROBE EXISTS. The glyph shipped 2026-04-26 reading an ENUMERATION of four
// inputs, written when the front stack had two members. The stack grew to nine across
// later arcs; four members were added without ever being checked against the glyph, and
// nothing failed — no probe asserted glyph-vs-front-member agreement in either direction,
// which is exactly why it went unnoticed for months. Three of those four belonged.
//
// So § 1 is the real anti-drift device: it is a STRUCTURAL check that every front
// contributor is explicitly classified — either present in the `currentFaults` array or
// named in a `// NOT <identifier>` exclusion beside it. A tenth front member added
// without a ruling fails this probe instead of silently inheriting "not wired".
//
// § 2 is the behavioral truth table, and § 3 is its NEGATIVE CONTROL. The control is
// load-bearing and non-obvious: the exported helper alone CANNOT prove this change. Over
// the normal input domain the old 4-arg and new 3-arg calls are observationally
// equivalent (`undefined > 0` is false, so both reduce to an OR of the same truths) — a
// rewritten unit assertion passes against both signatures while the wiring stays wrong.
// Only driving the whole wrapper distinguishes them, so § 3 spawns the PRE-CHANGE wrapper
// (git show HEAD~ / the recorded pre-change blob) against identical fixtures and asserts
// it renders the OLD answer. A green test that would pass either way proves nothing.
//
// SAFE_FOR_LIVE: yes   (uses `_make-fake-home` (mktemp + HOME + CLAUDE_CONFIG_DIR override
//                       per spawn); wsl logs/flags planted inside the tmp home and aged with
//                       utimesSync; DHX_WSL_UPTIME_MS pins the boot grace so /proc/uptime is
//                       never consulted; the pre-change wrapper is materialized via
//                       `git show` into a mktemp file; never touches live
//                       ~/.local/state/wsl-stack, ~/.cache/dhx, or the repo worktree)

const { spawnSync, execFileSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const REPO = path.resolve(__dirname, '..', '..');
const WRAPPER = path.join(REPO, 'dhx', 'statusline-wrapper.js');
const REL_WRAPPER = 'dhx/statusline-wrapper.js';
const { makeFakeHome } = require('./_make-fake-home');

const GREEN_DOT = '\x1b[2;38;5;70m∙\x1b[0m';
const YELLOW_UP = '\x1b[38;5;220m⌃\x1b[0m';

// Thresholds mirrored from the wrapper (deliberately mirrored, not imported — a silent
// constant change there must fail here rather than silently redefine the fixture).
const DEAD_MS = 95 * 60 * 1000;
const DEAD_MIN = DEAD_MS / 60000;
const UP_OLD = String(72 * 3600 * 1000); // well past the boot grace

const TRIP_BODY = '2026-08-15T09:14:02Z !! WSL process-pressure CRITICAL: bash=500 (>400) climbing toward .wslconfig ceiling';
const BYPASS_BODY = 'capped=0 uncapped=4 seam_ok=0';

let pass = 0, fail = 0;
function check(name, ok, detail) {
  if (ok) { console.log(`OK   ${name}`); pass++; }
  else { console.log(`FAIL ${name}`); if (detail) console.log(`       ${detail}`); fail++; }
}

// ---------------------------------------------------------------------------
// § 1 — Classification completeness (the anti-drift device)
// ---------------------------------------------------------------------------
// Derive the front-contributor set from the wrapper SOURCE, then assert each one is
// explicitly classified at the single classification site. This is what makes a tenth
// member's omission loud instead of silent.

const src = fs.readFileSync(WRAPPER, 'utf8');

// (a) The wsl cluster reaches `front` through composeWslFront's four named slots.
const wslCall = src.match(/composeWslFront\(\{([\s\S]*?)\}\)/);
const wslMembers = wslCall
  ? [...wslCall[1].matchAll(/\b(?:trip|monitor|broken|bypass)\s*:\s*([A-Za-z_$][\w$.]*)/g)].map(m => m[1])
  : [];

// (b) Everything else is pushed individually.
const pushed = [...src.matchAll(/if\s*\(([A-Za-z_$][\w$.]*)\)\s*front\.push\(/g)].map(m => m[1]);

const contributors = [...new Set([...wslMembers, ...pushed])];

check('§1 front contributors discovered from source (expect 9)',
  contributors.length === 9,
  `found ${contributors.length}: ${contributors.join(', ')}`);

// The classification site: the `currentFaults` array literal plus its `// NOT <id>` lines.
const blockMatch = src.match(/const currentFaults = \[([\s\S]*?)\n\s*\];/);
check('§1 classification site `const currentFaults = [...]` exists', !!blockMatch);

const block = blockMatch ? blockMatch[1] : '';
// Entries are the non-comment lines; exclusions are the `// NOT <identifier>` lines.
const included = [...block.matchAll(/^\s*([A-Za-z_$][\w$.]*)\s*,/gm)].map(m => m[1]);
const excluded = [...block.matchAll(/\/\/\s*NOT\s+([A-Za-z_$][\w$.]*)/g)].map(m => m[1]);

// A contributor matches a classification entry when they name the same member. The two
// can differ by ONE property hop: composeWslFront takes the whole `wslMonitor` object
// while the glyph consumes its `.token` field. Anything looser would let an unrelated
// identifier satisfy the check, which is the whole point of § 1.
const names = (entry, c) => entry === c || entry.startsWith(c + '.') || c.startsWith(entry + '.');

for (const c of contributors) {
  const inSet = included.some(e => names(e, c));
  const outSet = excluded.some(e => names(e, c));
  check(`§1 front member '${c}' is explicitly classified (in currentFaults, or // NOT)`,
    inSet !== outSet, // exactly one — never both, never neither
    inSet && outSet ? 'classified BOTH ways' : `included=${inSet} excluded=${outSet}`);
}

// The ruling itself, pinned by identity so a future edit can't quietly flip a member.
check('§1 wslPressureWarning (the durable trip LATCH) is excluded',
  excluded.includes('wslPressureWarning'));
check('§1 the three cross-repo/backlog members are excluded',
  ['fleetWarning', 'watchWarning', 'skillPressureWarning'].every(m => excluded.includes(m)),
  `excluded = ${excluded.join(', ')}`);
check('§1 the three current-fault wsl/seam members are included',
  ['wslMonitor.token', 'wslProbeBrokenWarning', 'claudeCapBypassWarning'].every(m => included.includes(m)),
  `included = ${included.join(', ')}`);

// INVARIANT: the glyph reads READER OUTPUTS, never composeWslFront's rendered tokens.
// composeWslFront suppresses probe-broken/cap-bypass when their producer is stale; if the
// glyph were derived from what got rendered, presentation suppression would manufacture a
// false green. Assert the call site does not pass the composed/rendered array.
check('§1 INVARIANT: glyph inputs are reader outputs, not the rendered front array',
  !/computeMetaGlyph\(\s*front\b/.test(src),
  'computeMetaGlyph must not be handed the rendered `front` array');

// ---------------------------------------------------------------------------
// § 2 + § 3 — Behavioral truth table, and the negative control
// ---------------------------------------------------------------------------

// The PRE-CHANGE wrapper for the negative control, pinned to a FIXED commit.
//
// DO NOT change this to `HEAD`. It was HEAD while the change was uncommitted, and the moment
// the change landed HEAD became the POST-change wrapper — the control compared the new code
// against itself, every fixture agreed, and § 3 went red. That red was correct: a control
// that cannot discriminate is not a control. The baseline is a fixed historical fact, so it
// gets a fixed ref.
//
// 303e264 = the commit immediately before df8c7e3 (the contract change). Anything at or after
// df8c7e3 is post-change and will collapse the control again.
const PRE_CHANGE_REF = '303e264';

function preChangeWrapper() {
  let blob;
  try {
    blob = execFileSync('git', ['-C', REPO, 'show', `${PRE_CHANGE_REF}:${REL_WRAPPER}`], {
      encoding: 'utf8', maxBuffer: 8 * 1024 * 1024, stdio: ['ignore', 'pipe', 'ignore'],
    });
  } catch {
    return null; // ref unreachable (shallow clone, or the filter-repo'd public mirror)
  }
  const f = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'dhx-metaglyph-prechange-')), 'statusline-wrapper.js');
  fs.writeFileSync(f, blob);
  return f;
}

// Plant a fixture home and spawn `wrapperPath` against it; return the leading glyph.
// `laneHealth` (2026-09-15): the health cache was split by scope, and `missing_symlinks`
// now lives in a per-lane sidecar whose ABSENCE renders `symlinks:?` in the advisory tail
// — which computeMetaGlyph() folds into `warn` wholesale (`|| !!healthTail`). So a fixture
// with no sidecar carries a standing tail token, and every case below would report ⌃
// regardless of the wsl state it means to exercise. The 'durable trip LATCH alone' case is
// the one that shows why that matters: its whole job is to prove the latch is EXCLUDED
// from the glyph, and a masking tail token would make it pass-by-accident-or-fail-by-
// accident forever after. So the default plants a CLEAN sidecar (checked, zero faults),
// and the one case that means to exercise the unknown passes `laneHealth: null`.
function glyphFrom(wrapperPath, { pressureMin = 5, censusMin = 5, trip = null, broken = null, bypass = null, laneHealth = 0 } = {}) {
  const tmp = makeFakeHome('dhx-metaglyph-agreement-');
  try {
    if (laneHealth !== null) {
      fs.writeFileSync(path.join(tmp, '.cache', 'dhx', 'health-lane-default.json'), JSON.stringify({
        config_dir: fs.realpathSync(path.join(tmp, '.claude')),
        missing_symlinks: laneHealth,
        checked: 0,
      }));
    }
    const dir = path.join(tmp, '.local', 'state', 'wsl-stack');
    fs.mkdirSync(dir, { recursive: true });
    const plant = (name, ageMin, body) => {
      if (ageMin === null) return;
      const f = path.join(dir, name);
      fs.writeFileSync(f, body);
      const when = new Date(Date.now() - ageMin * 60 * 1000);
      fs.utimesSync(f, when, when); // mtime IS the liveness key
    };
    plant('pressure.log', pressureMin, '2026-08-15T11:15:16Z   ok    bash=33\n');
    plant('claude-cap-census.log', censusMin, '2026-08-15 06:15:16   ok    capped=3 uncapped=0 seam=capbin\n');
    if (trip !== null) fs.writeFileSync(path.join(dir, 'wsl-pressure-trip.flag'), trip);
    if (broken !== null) fs.writeFileSync(path.join(dir, 'wsl-pressure-broken.flag'), broken);
    if (bypass !== null) fs.writeFileSync(path.join(dir, 'claude-cap-bypass.flag'), bypass);
    const res = spawnSync(process.execPath, [wrapperPath], {
      input: JSON.stringify({ session_id: 'probe-metaglyph-front-agreement', version: '2.1.177' }),
      env: { ...process.env, HOME: tmp, CLAUDE_CONFIG_DIR: path.join(tmp, '.claude'), DHX_WSL_UPTIME_MS: UP_OLD },
      encoding: 'utf8',
      timeout: 8000,
    });
    const out = res.stdout || '';
    if (out.startsWith(YELLOW_UP)) return '⌃';
    if (out.startsWith(GREEN_DOT)) return '∙';
    return `(none: ${JSON.stringify(out.slice(0, 40))})`;
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

// The fixtures. `expect` is the NEW contract; `was` is the PRE-CHANGE answer. Where they
// differ, that pair IS the negative control — it proves the change is real.
const CASES = [
  { name: 'all clean',                    fx: {},                                   expect: '∙', was: '∙' },
  { name: 'monitor-dead (both logs stale)', fx: { pressureMin: DEAD_MIN + 10, censusMin: DEAD_MIN + 10 }, expect: '⌃', was: '∙' },
  { name: 'probe-broken alone',           fx: { broken: 'x' },                      expect: '⌃', was: '∙' },
  { name: 'cap-bypass (seam broken) alone', fx: { bypass: BYPASS_BODY },            expect: '⌃', was: '∙' },
  { name: 'durable trip LATCH alone',     fx: { trip: TRIP_BODY },                  expect: '∙', was: '∙' },
  { name: 'trip latch + probe-broken',    fx: { trip: TRIP_BODY, broken: 'x' },     expect: '⌃', was: '∙' },
  // 2026-09-15: no health reading for this lane. `was: '∙'` is not a regression — the
  // pre-change wrapper had no concept of a lane sidecar, so the same fixture was simply
  // silent. The new ⌃ is deliberate and follows the ESTABLISHED rule rather than adding a
  // policy: computeMetaGlyph already folds the whole advisory tail into `warn`, and every
  // other advisory member (patches:REGRESSED, CLAUDE.md unlinked) flips the glyph too. An
  // exception for this one token would be the carve-out, not the consistency.
  { name: 'no health reading for this lane', fx: { laneHealth: null },              expect: '⌃', was: '∙' },
];

const PRE = preChangeWrapper();
let controlPairs = 0;

// § 3 needs reachable history. The private repo always has it; the filter-repo'd public
// mirror does not. Announce the skip loudly rather than passing it silently — a control
// that quietly evaporates is worse than one that is absent by declaration.
if (!PRE) {
  console.log(`SKIP §3 negative control — ${PRE_CHANGE_REF} unreachable (shallow clone or rewritten history).`);
  console.log('       § 1 and § 2 still ran; only the old-vs-new discrimination is unavailable here.');
}

for (const c of CASES) {
  const got = glyphFrom(WRAPPER, c.fx);
  check(`§2 ${c.name} → ${c.expect}`, got === c.expect, `got ${got}`);

  if (PRE) {
    const old = glyphFrom(PRE, c.fx);
    check(`§3 negative control — pre-change wrapper on '${c.name}' → ${c.was}`, old === c.was, `got ${old}`);
  }
  if (c.expect !== c.was) controlPairs++;
}

// The control is only meaningful if fixtures actually DISCRIMINATE. Without this a future
// refactor could make every case agree and the suite would stay green while proving nothing
// — which is exactly what happened when this probe was pinned to a moving HEAD.
if (PRE) {
  check('§3 negative control discriminates (≥3 fixtures differ old-vs-new)',
    controlPairs >= 3, `${controlPairs} discriminating fixture(s)`);
  fs.rmSync(path.dirname(PRE), { recursive: true, force: true });
}

// The 2026-04-26 third-state guarantee: the glyph must RENDER in every state, because
// presence-vs-absence is the only detector for "the watcher itself is dead".
check('§4 third state preserved — a glyph renders in every fixture',
  CASES.every(c => ['∙', '⌃'].includes(glyphFrom(WRAPPER, c.fx))));

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
