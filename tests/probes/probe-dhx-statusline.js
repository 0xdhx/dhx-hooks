// Probe: dhx-statusline.js rendering contract.
//
// Locks: compact model names, CCS profile extraction, name truncation,
// STATE.md parsing (progress: block + multi-shape Phase line), repo
// signal counting, line-2 assembly, conditional multi-line output.
//
// Why: the renderer composes several separate pieces of signal into one
// compact status bar. Each piece has its own edge (malformed input,
// absent dir, unknown model). Regressions in any one of them show up
// silently — the statusline keeps rendering, just with wrong data.
// Probe pins each transform so a future refactor can't ship a silent
// miscompute.
//
// Pairs with: docs/decisions.md 2026-04-18 statusline-line2 row, and the
// 2026-04-18 renames/extensions in dhx/dhx-statusline.js (compactModel,
// getCcsProfile, truncate, getRepoSignals, formatLine2Gsd,
// formatLine2Signals).

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const SCRIPT = path.join(__dirname, '..', '..', 'dhx', 'dhx-statusline.js');
const {
  compactModel, getCcsProfile,
  truncate, findRepoRoot, getRepoSignals,
  parseStateMd, formatLine2Gsd, formatLine2Signals,
} = require(SCRIPT);

let pass = 0;
let fail = 0;

function ok(label, got, want) {
  if (got === want) { console.log(`OK   ${label}`); pass++; }
  else { console.log(`FAIL ${label}\n  got:  ${JSON.stringify(got)}\n  want: ${JSON.stringify(want)}`); fail++; }
}

function okObj(label, got, want) {
  const gs = JSON.stringify(got);
  const ws = JSON.stringify(want);
  if (gs === ws) { console.log(`OK   ${label}`); pass++; }
  else { console.log(`FAIL ${label}\n  got:  ${gs}\n  want: ${ws}`); fail++; }
}

// --- § 1 compactModel -------------------------------------------------------

ok('compactModel: Opus 4.7 (1M context)', compactModel('Opus 4.7 (1M context)'), 'O-4.7 (1M)');
ok('compactModel: Sonnet 4.6', compactModel('Sonnet 4.6'), 'S-4.6');
ok('compactModel: Haiku 4.5', compactModel('Haiku 4.5'), 'H-4.5');
ok('compactModel: Sonnet 4.6 (1M context)', compactModel('Sonnet 4.6 (1M context)'), 'S-4.6 (1M)');
ok('compactModel: unknown shape passes through', compactModel('SomeNewModel 5.0'), 'SomeNewModel 5.0');
ok('compactModel: empty → Claude', compactModel(''), 'Claude');
ok('compactModel: null → Claude', compactModel(null), 'Claude');

// --- § 2 getCcsProfile ------------------------------------------------------

const prevConfigDir = process.env.CLAUDE_CONFIG_DIR;
process.env.CLAUDE_CONFIG_DIR = '/home/dhx/.ccs/instances/b';
ok('getCcsProfile: instance b', getCcsProfile(), 'b');
process.env.CLAUDE_CONFIG_DIR = '/home/dhx/.ccs/instances/alpha';
ok('getCcsProfile: multi-char instance name', getCcsProfile(), 'alpha');
process.env.CLAUDE_CONFIG_DIR = '/home/dhx/.claude';
ok('getCcsProfile: default dir → empty', getCcsProfile(), '');
delete process.env.CLAUDE_CONFIG_DIR;
ok('getCcsProfile: env unset → empty', getCcsProfile(), '');
if (prevConfigDir !== undefined) process.env.CLAUDE_CONFIG_DIR = prevConfigDir;

// --- § 3 truncate -----------------------------------------------------------

ok('truncate: short pass-through', truncate('short', 20), 'short');
ok('truncate: exact cap', truncate('12345678901234567890', 20), '12345678901234567890');
ok('truncate: over cap gets ellipsis', truncate('Research Orchestration & Hub Intelligence', 20), 'Research Orchestrat…');
ok('truncate: ellipsis within cap', truncate('Hub Eviction Redesign & Project Status', 20).length, 20);
ok('truncate: empty string', truncate('', 20), '');

// --- § 4 parseStateMd (progress block + phase shapes) -----------------------

const FIXTURE_MODERN = `---
gsd_state_version: 1.0
milestone: v1.4
milestone_name: Research Orchestration
status: executing
progress:
  total_phases: 10
  completed_phases: 7
  percent: 70
---

# Project State

Phase: 24.1 (Hub Eviction Redesign) — EXECUTING
`;

const sModern = parseStateMd(FIXTURE_MODERN);
ok('parseStateMd modern: milestone', sModern.milestone, 'v1.4');
ok('parseStateMd modern: milestone_name', sModern.milestoneName, 'Research Orchestration');
ok('parseStateMd modern: status', sModern.status, 'executing');
ok('parseStateMd modern: completedPhases', sModern.completedPhases, 7);
ok('parseStateMd modern: totalPhases', sModern.totalPhases, 10);
ok('parseStateMd modern: phaseNum (decimal)', sModern.phaseNum, '24.1');
ok('parseStateMd modern: phaseName', sModern.phaseName, 'Hub Eviction Redesign');

const FIXTURE_LEGACY = `---
milestone: v0.9
status: planning
---

Phase: 3 of 8 (fix-graphiti-deployment)
`;

const sLegacy = parseStateMd(FIXTURE_LEGACY);
ok('parseStateMd legacy: phaseNum', sLegacy.phaseNum, '3');
ok('parseStateMd legacy: phaseTotal', sLegacy.phaseTotal, '8');
ok('parseStateMd legacy: phaseName', sLegacy.phaseName, 'fix-graphiti-deployment');

const FIXTURE_NONE = `---
milestone: v1.0
---

Phase: none active (milestone complete)
`;

const sNone = parseStateMd(FIXTURE_NONE);
ok('parseStateMd none: phase skipped', sNone.phaseNum, undefined);

// --- § 5 getRepoSignals (fixture repo) --------------------------------------

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'dhx-sl-probe-'));
try {
  execFileSync('git', ['init', '--quiet', tmp], { stdio: 'ignore' });
  fs.mkdirSync(path.join(tmp, 'reports'));
  fs.mkdirSync(path.join(tmp, 'reports', 'done'));
  fs.mkdirSync(path.join(tmp, '.planning', 'todos'), { recursive: true });
  fs.mkdirSync(path.join(tmp, '.planning', 'backlog'), { recursive: true });

  fs.writeFileSync(path.join(tmp, 'reports', 'r1.md'), '');
  fs.writeFileSync(path.join(tmp, 'reports', 'r2.md'), '');
  // done/ files don't count
  fs.writeFileSync(path.join(tmp, 'reports', 'done', 'old.md'), '');
  fs.writeFileSync(path.join(tmp, '.planning', 'todos', 't1.md'), '');
  fs.writeFileSync(path.join(tmp, '.planning', 'backlog', 'b1.md'), '');
  fs.writeFileSync(path.join(tmp, '.planning', 'backlog', 'b2.md'), '');
  fs.writeFileSync(path.join(tmp, '.planning', 'backlog', 'b3.md'), '');
  // Non-md sibling shouldn't count
  fs.writeFileSync(path.join(tmp, '.planning', 'backlog', 'README.txt'), '');

  const counts = getRepoSignals(tmp);
  okObj('getRepoSignals: counts', counts, { reports: 2, todos: 1, backlog: 3 });

  // Walk from a subdir must find the same root
  const sub = path.join(tmp, 'a', 'b');
  fs.mkdirSync(sub, { recursive: true });
  const countsFromSub = getRepoSignals(sub);
  okObj('getRepoSignals: walks up from subdir', countsFromSub, { reports: 2, todos: 1, backlog: 3 });

  ok('findRepoRoot: resolves from subdir', findRepoRoot(sub), tmp);
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}

// Non-repo path → all zeros
const nonRepo = fs.mkdtempSync(path.join(os.tmpdir(), 'dhx-sl-nonrepo-'));
try {
  const counts = getRepoSignals(nonRepo);
  okObj('getRepoSignals: non-repo → zeros', counts, { reports: 0, todos: 0, backlog: 0 });
} finally {
  fs.rmSync(nonRepo, { recursive: true, force: true });
}

// --- § 6 formatLine2Gsd + formatLine2Signals --------------------------------

// ANSI-stripped projection for readable asserts
const strip = (s) => s.replace(/\x1b\[[0-9;]*m/g, '');

const fullState = {
  milestone: 'v1.4',
  milestoneName: 'Research Orchestration',
  status: 'executing',
  phaseNum: '24.1',
  phaseName: 'Hub Eviction Redesign',
  completedPhases: 7,
  totalPhases: 10,
};
ok('formatLine2Gsd: full state',
  strip(formatLine2Gsd(fullState)),
  'v1.4 Research Orchestrat… (7/10) · exec · 24.1 Hub Eviction Redesi…');

ok('formatLine2Gsd: empty state → empty', formatLine2Gsd({}), '');
ok('formatLine2Gsd: null state → empty', formatLine2Gsd(null), '');

ok('formatLine2Gsd: partial (no status/phase)',
  strip(formatLine2Gsd({ milestone: 'v1.0', milestoneName: 'Init' })),
  'v1.0 Init');

ok('formatLine2Gsd: completion green at 100%',
  formatLine2Gsd({ milestone: 'v2.0', completedPhases: 5, totalPhases: 5 }).includes('\x1b[32m('),
  true);

ok('formatLine2Gsd: completion red at 0/N',
  formatLine2Gsd({ milestone: 'v0.1', completedPhases: 0, totalPhases: 5 }).includes('\x1b[2;31m'),
  true);

ok('formatLine2Gsd: completion dim-green at 75–99%',
  formatLine2Gsd({ milestone: 'v1.0', completedPhases: 8, totalPhases: 10 }).includes('\x1b[2;32m'),
  true);

ok('formatLine2Signals: all three classes',
  strip(formatLine2Signals({ reports: 4, todos: 2, backlog: 7 })),
  'R4·T2·B7');

ok('formatLine2Signals: zero classes hidden',
  strip(formatLine2Signals({ reports: 5, todos: 0, backlog: 1 })),
  'R5·B1');

ok('formatLine2Signals: all zero → empty',
  formatLine2Signals({ reports: 0, todos: 0, backlog: 0 }),
  '');

// --- § 7 End-to-end: conditional multi-line output --------------------------

function renderStatusline(stdin) {
  return execFileSync(process.execPath, [SCRIPT], {
    input: JSON.stringify(stdin),
    encoding: 'utf8',
  });
}

// Non-GSD dir with no repo signals → single line (no \n)
const outSingle = renderStatusline({
  session_id: 'probe',
  model: { display_name: 'Opus 4.7 (1M context)' },
  workspace: { current_dir: os.tmpdir() },
  context_window: { total_tokens: 1_000_000, remaining_percentage: 85 },
});
ok('e2e: single line when no GSD + no signals (no newline)',
  outSingle.includes('\n'), false);
ok('e2e: single line has compact model',
  outSingle.includes('O-4.7 (1M)'), true);

// hooks repo (signals only, no GSD frontmatter) → two lines
const outHooks = renderStatusline({
  session_id: 'probe',
  model: { display_name: 'Opus 4.7 (1M context)' },
  workspace: { current_dir: '/home/dhx/repos/hooks' },
  context_window: { total_tokens: 1_000_000, remaining_percentage: 85 },
});
const [hLine1, hLine2] = outHooks.split('\n');
ok('e2e: hooks repo produces two lines', outHooks.includes('\n'), true);
ok('e2e: hooks repo line 2 has R prefix', strip(hLine2 || '').match(/R\d+/) !== null, true);

// --- Summary ----------------------------------------------------------------

console.log();
console.log(`${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
