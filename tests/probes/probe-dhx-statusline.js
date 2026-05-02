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

// SAFE_FOR_LIVE: yes   (re-implements helpers via require; no FS writes outside whatever the renderer does internally on tmp paths)
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const SCRIPT = path.join(__dirname, '..', '..', 'dhx', 'dhx-statusline.js');
const {
  compactModel, getCcsProfile,
  renderEffort,
  EFFORT_RENDER,
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

// ANSI-stripped projection for readable asserts across sections
const strip = (s) => s.replace(/\x1b\[[0-9;]*m/g, '');

// --- § 1 compactModel -------------------------------------------------------

ok('compactModel: Opus 4.7 (1M context)', compactModel('Opus 4.7 (1M context)'), 'o4.7+');
ok('compactModel: Opus 4.7 (no 1M)', compactModel('Opus 4.7'), 'o4.7');
ok('compactModel: Sonnet 4.6', compactModel('Sonnet 4.6'), 's4.6');
ok('compactModel: Haiku 4.5', compactModel('Haiku 4.5'), 'h4.5');
ok('compactModel: Sonnet 4.6 (1M context)', compactModel('Sonnet 4.6 (1M context)'), 's4.6+');
ok('compactModel: unknown shape passes through', compactModel('SomeNewModel 5.0'), 'SomeNewModel 5.0');
ok('compactModel: empty → Claude', compactModel(''), 'Claude');
ok('compactModel: null → Claude', compactModel(null), 'Claude');

// --- § 1b renderEffort + getEffortLevel ------------------------------------

// Each level maps to a distinct glyph + color. Probe pins the glyph bytes
// so a future refactor can't silently swap the set without updating docs.
ok('renderEffort: low',    strip(renderEffort('low')),    '⡀');
ok('renderEffort: medium', strip(renderEffort('medium')), '⣀');
ok('renderEffort: high',   strip(renderEffort('high')),   '⣤');
ok('renderEffort: xhigh',  strip(renderEffort('xhigh')),  '⣶');
ok('renderEffort: max',    strip(renderEffort('max')),    '⣿');
ok('renderEffort: unknown → empty',  renderEffort('weird'), '');
ok('renderEffort: null → empty',     renderEffort(null),    '');
ok('renderEffort: undefined → empty', renderEffort(undefined), '');

// Color carries the meter ramp — confirm each level wears its band.
ok('renderEffort: low is dim',       renderEffort('low').includes('\x1b[2m'),     true);
ok('renderEffort: medium is cyan',   renderEffort('medium').includes('\x1b[36m'), true);
ok('renderEffort: high is yellow',   renderEffort('high').includes('\x1b[33m'),   true);
ok('renderEffort: xhigh is orange',  renderEffort('xhigh').includes('\x1b[38;5;208m'), true);
ok('renderEffort: max is red',       renderEffort('max').includes('\x1b[31m'),    true);

// Ordered set check — prevents accidental reordering of the fill progression.
okObj('EFFORT_RENDER glyph progression',
  ['low','medium','high','xhigh','max'].map(k => EFFORT_RENDER[k].glyph),
  ['⡀', '⣀', '⣤', '⣶', '⣿']);

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
  'v1.4 (7/10) · exec · 24.1 Hub Eviction Redesi…');

ok('formatLine2Gsd: empty state → empty', formatLine2Gsd({}), '');
ok('formatLine2Gsd: null state → empty', formatLine2Gsd(null), '');

ok('formatLine2Gsd: partial (no status/phase)',
  strip(formatLine2Gsd({ milestone: 'v1.0', milestoneName: 'Init' })),
  'v1.0');

// Milestone-name drop end-to-end gate (2026-04-27 quick task 260427-u89): a
// state carrying ONLY a milestone_name must produce empty output — the name
// is no longer rendered. The `hasContent` gate keeps milestoneName as a
// content trigger so legacy state shapes don't render an empty separator
// row, but the milestone-name piece itself never lands in `parts`.
ok('formatLine2Gsd: name-only state → empty (name no longer rendered)',
  strip(formatLine2Gsd({ milestoneName: 'Some Long Project Name' })),
  '');

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

// Render with a stubbed tmux so the effort glyph renders deterministically
// regardless of the host's live tmux scrollback. The stub prints whatever
// we put in DHX_TMUX_STUB_OUT.
const e2eStubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'dhx-sl-e2e-stub-'));
fs.writeFileSync(
  path.join(e2eStubDir, 'tmux'),
  '#!/bin/sh\nprintf "%s" "$DHX_TMUX_STUB_OUT"\n',
);
fs.chmodSync(path.join(e2eStubDir, 'tmux'), 0o755);

function renderWithFixtures(stdin) {
  return execFileSync(process.execPath, [SCRIPT], {
    input: JSON.stringify(stdin),
    encoding: 'utf8',
    env: {
      ...process.env,
      PATH: `${e2eStubDir}:${process.env.PATH}`,
      TMUX_PANE: '%99',
      DHX_TMUX_STUB_OUT:
        '▝▜█████▛▘  Opus 4.7 (1M context) with high effort · Claude Max\n',
    },
  });
}

// Non-GSD dir with no repo signals → single line (no \n)
// effort.level injected into stdin so the post-retire renderer (Phase 5 D-02)
// produces the same `o4.7+ ⣤` glyph the assertion below expects — sourced
// from data.effort.level rather than the (now-deleted) tmux pane scrape.
const outSingle = renderWithFixtures({
  session_id: 'probe',
  model: { display_name: 'Opus 4.7 (1M context)' },
  workspace: { current_dir: os.tmpdir() },
  context_window: { total_tokens: 1_000_000, remaining_percentage: 85 },
  effort: { level: 'high' },
});
ok('e2e: single line when no GSD + no signals (no newline)',
  outSingle.includes('\n'), false);
ok('e2e: single line has compact model',
  outSingle.includes('o4.7+'), true);
ok('e2e: effort glyph renders with space after model',
  strip(outSingle).includes('o4.7+ ⣤'), true);

// hooks repo (GSD frontmatter present + signals on disk) → two lines
// effort.level injected to keep parity with the single-line fixture above
// (Phase 5 D-02 stdin-driven path).
const outHooks = renderWithFixtures({
  session_id: 'probe',
  model: { display_name: 'Opus 4.7 (1M context)' },
  workspace: { current_dir: '/home/dhx/repos/hooks' },
  context_window: { total_tokens: 1_000_000, remaining_percentage: 85 },
  effort: { level: 'high' },
});
const [hLine1, hLine2] = outHooks.split('\n');
// Repo signals (R/T/B) computation moved OUT of the renderer on 2026-04-28 —
// the wrapper imports formatLine2Signals/getRepoSignals via require() and
// appends after git. Renderer in isolation must NOT emit signals on either
// line; line 2 carries GSD state only.
ok('e2e: hooks repo produces two lines', outHooks.includes('\n'), true);
ok('e2e: renderer line 1 does NOT emit signals (wrapper owns)', strip(hLine1).match(/R\d+/) === null, true);
ok('e2e: renderer line 2 does NOT emit signals (wrapper owns)', strip(hLine2 || '').match(/R\d+/) === null, true);

// Clean up e2e tmux stub after all renderWithFixtures calls complete.
fs.rmSync(e2eStubDir, { recursive: true, force: true });

// --- Summary ----------------------------------------------------------------

console.log();
console.log(`${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
