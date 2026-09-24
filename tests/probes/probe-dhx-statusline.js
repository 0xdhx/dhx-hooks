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
  refineDiscussStatus,
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
// Raw model-id form (a /model <id> override ships the literal id as display_name).
ok('compactModel: claude-opus-4-8[1m] → o4.8+', compactModel('claude-opus-4-8[1m]'), 'o4.8+');
ok('compactModel: claude-opus-4-8 (no 1M) → o4.8', compactModel('claude-opus-4-8'), 'o4.8');
ok('compactModel: claude-sonnet-4-6 → s4.6', compactModel('claude-sonnet-4-6'), 's4.6');
ok('compactModel: claude-haiku-4-5-20251001 (date suffix) → h4.5', compactModel('claude-haiku-4-5-20251001'), 'h4.5');

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

// CRLF frontmatter — an LF-only fence regex drops the ENTIRE frontmatter on a
// CRLF STATE.md, so the GSD segment renders silently empty. Derived from
// FIXTURE_MODERN by line-ending substitution ONLY, so "identical content,
// different EOL" is structural rather than transcribed (a hand-copied CRLF
// fixture can drift from its LF twin and assert nothing).
const FIXTURE_CRLF = FIXTURE_MODERN.replace(/\n/g, '\r\n');
const sCrlf = parseStateMd(FIXTURE_CRLF);
ok('parseStateMd CRLF: fixture really is CRLF', /\r\n/.test(FIXTURE_CRLF), true);
ok('parseStateMd CRLF: frontmatter not dropped', sCrlf.milestone, 'v1.4');
ok('parseStateMd CRLF: milestone_name unpolluted by \\r', sCrlf.milestoneName, 'Research Orchestration');
ok('parseStateMd CRLF: status', sCrlf.status, 'executing');
ok('parseStateMd CRLF: completedPhases', sCrlf.completedPhases, 7);
ok('parseStateMd CRLF: totalPhases', sCrlf.totalPhases, 10);
ok('parseStateMd CRLF: phaseName unpolluted by \\r', sCrlf.phaseName, 'Hub Eviction Redesign');
ok('parseStateMd CRLF: parsed state identical to LF twin',
   JSON.stringify(sCrlf), JSON.stringify(sModern));

// Unterminated frontmatter — the fence never closes. Frontmatter must be
// dropped (no closing marker to bound it) but the body `Status:` fallback must
// still fire; this is the pre-existing behavior the CRLF fix must not disturb.
const FIXTURE_UNTERMINATED = `---
milestone: v1.4
status: executing

Phase: 5 (No Fence Close)
Status: executing
`;

const sUnterm = parseStateMd(FIXTURE_UNTERMINATED);
ok('parseStateMd unterminated: frontmatter dropped', sUnterm.milestone, undefined);
ok('parseStateMd unterminated: body Status fallback still fires', sUnterm.status, 'executing');
ok('parseStateMd unterminated: phase line still parsed', sUnterm.phaseNum, '5');

// --- § 5 getRepoSignals (fixture repo) --------------------------------------

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'dhx-sl-probe-'));
try {
  execFileSync('git', ['init', '--quiet', tmp], { stdio: 'ignore' });
  fs.mkdirSync(path.join(tmp, 'reports'));
  fs.mkdirSync(path.join(tmp, 'reports', 'done'));
  fs.mkdirSync(path.join(tmp, '.planning', 'todos', 'pending'), { recursive: true });
  fs.mkdirSync(path.join(tmp, '.planning', 'todos', 'completed'), { recursive: true });
  fs.mkdirSync(path.join(tmp, '.planning', 'todos', 'done'), { recursive: true });
  fs.mkdirSync(path.join(tmp, '.planning', 'backlog'), { recursive: true });

  fs.writeFileSync(path.join(tmp, 'reports', 'r1.md'), '');
  fs.writeFileSync(path.join(tmp, 'reports', 'r2.md'), '');
  // done/ files don't count
  fs.writeFileSync(path.join(tmp, 'reports', 'done', 'old.md'), '');
  fs.writeFileSync(path.join(tmp, '.planning', 'todos', 'pending', 't1.md'), '');
  // Archived todos MUST NOT count — convention asymmetry vs reports/.
  // completed/ is the canonical archive dir (GSD-core cmdTodoComplete writes
  // there); done/ is the retired GSD name still present in older repos.
  // Both are seeded so the exclusion is locked for either layout.
  fs.writeFileSync(path.join(tmp, '.planning', 'todos', 'completed', 'old1.md'), '');
  fs.writeFileSync(path.join(tmp, '.planning', 'todos', 'completed', 'old2.md'), '');
  fs.writeFileSync(path.join(tmp, '.planning', 'todos', 'done', 'legacy1.md'), '');
  // top-level .planning/todos/*.md is NOT counted (archived sibling pattern)
  fs.writeFileSync(path.join(tmp, '.planning', 'todos', 'stale-flat.md'), '');
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

// --- § 5b getActiveTask (CC tasks/ layout post-2026-05) ---------------------
// CC migrated TodoWrite → TaskCreate/TaskUpdate, replacing the single-array
// <claudeDir>/todos/<session>-agent-<session>.json with one file per task at
// <claudeDir>/tasks/<session>/<id>.json. The renderer pin must read the new
// layout — a regression here silently empties line 1's bold task segment.
const { getActiveTask } = require(SCRIPT);
const taskHome = fs.mkdtempSync(path.join(os.tmpdir(), 'dhx-sl-tasks-'));
try {
  const session = 'sess-abc';
  const tasksDir = path.join(taskHome, 'tasks', session);

  // Missing dir → ''
  ok('getActiveTask: missing tasksDir → empty', getActiveTask(taskHome, session), '');
  ok('getActiveTask: empty session → empty', getActiveTask(taskHome, ''), '');

  fs.mkdirSync(tasksDir, { recursive: true });

  // Empty dir → ''
  ok('getActiveTask: empty tasksDir → empty', getActiveTask(taskHome, session), '');

  // Pending + completed only → ''
  fs.writeFileSync(path.join(tasksDir, '1.json'), JSON.stringify({
    id: '1', subject: 'Plan', activeForm: 'Planning', status: 'pending',
  }));
  fs.writeFileSync(path.join(tasksDir, '2.json'), JSON.stringify({
    id: '2', subject: 'Read docs', activeForm: 'Reading docs', status: 'completed',
  }));
  ok('getActiveTask: no in_progress → empty', getActiveTask(taskHome, session), '');

  // Add an in_progress task → its activeForm
  fs.writeFileSync(path.join(tasksDir, '3.json'), JSON.stringify({
    id: '3', subject: 'Patch issue body', activeForm: 'Patching issue body', status: 'in_progress',
  }));
  ok('getActiveTask: in_progress → activeForm',
    getActiveTask(taskHome, session), 'Patching issue body');

  // Malformed JSON file is skipped, not fatal
  fs.writeFileSync(path.join(tasksDir, '4.json'), '{not valid json');
  ok('getActiveTask: malformed file skipped, still finds in_progress',
    getActiveTask(taskHome, session), 'Patching issue body');

  // Non-.json sibling ignored
  fs.writeFileSync(path.join(tasksDir, 'README.txt'), 'ignore me');
  ok('getActiveTask: non-.json ignored',
    getActiveTask(taskHome, session), 'Patching issue body');

  // activeForm absent on the in_progress task → '' (mirrors prior behavior)
  fs.rmSync(path.join(tasksDir, '3.json'));
  fs.writeFileSync(path.join(tasksDir, '5.json'), JSON.stringify({
    id: '5', subject: 'No activeForm', status: 'in_progress',
  }));
  ok('getActiveTask: in_progress with no activeForm → empty',
    getActiveTask(taskHome, session), '');

  // Legacy todos/<session>-agent-<session>.json is NOT consulted (post-migration).
  const legacyTodosDir = path.join(taskHome, 'todos');
  fs.mkdirSync(legacyTodosDir, { recursive: true });
  fs.writeFileSync(
    path.join(legacyTodosDir, `${session}-agent-${session}.json`),
    JSON.stringify([{ status: 'in_progress', activeForm: 'LEGACY should not show' }]),
  );
  // Drop the new tasks dir entirely so the legacy path is the only source.
  fs.rmSync(tasksDir, { recursive: true, force: true });
  ok('getActiveTask: legacy todos/ path is dead, not consulted',
    getActiveTask(taskHome, session), '');
} finally {
  fs.rmSync(taskHome, { recursive: true, force: true });
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
  context_window: ccContextWindow(150000, 1_000_000), // CC's real shape (§ 8)
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
  context_window: ccContextWindow(150000, 1_000_000), // CC's real shape (§ 8)
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

// --- refineDiscussStatus: planning → discuss when no CONTEXT.md -------------
// dhx-side stage refinement (2026-07-18): GSD's `planning` status cannot
// distinguish "not yet discussed" from "ready to plan"; the phase CONTEXT.md
// (written by /dhx:discuss) is the canonical discuss-has-run signal.
{
  const t = fs.mkdtempSync(path.join(os.tmpdir(), 'dhx-sl-disc-'));
  const phaseDir = path.join(t, 'phases', '48-closer-ruling');
  fs.mkdirSync(phaseDir, { recursive: true });
  const mk = (status, phaseNum) => ({ status, phaseNum });
  ok('discuss: planning + no CONTEXT.md → discuss',
     refineDiscussStatus(mk('planning', '48'), t).status, 'discuss');
  fs.writeFileSync(path.join(phaseDir, '48-CONTEXT.md'), '');
  ok('discuss: planning + CONTEXT.md present → stays planning',
     refineDiscussStatus(mk('planning', '48'), t).status, 'planning');
  ok('discuss: unscaffolded phase (no phases/49-* dir) → discuss',
     refineDiscussStatus(mk('planning', '49'), t).status, 'discuss');
  ok('discuss: decimal phase does not inherit parent phase CONTEXT (48.1 vs 48-)',
     refineDiscussStatus(mk('planning', '48.1'), t).status, 'discuss');
  ok('discuss: non-planning status untouched',
     refineDiscussStatus(mk('executing', '48'), t).status, 'executing');
  ok('discuss: phases/ dir absent → keeps planning (no false alarm on bad reads)',
     refineDiscussStatus(mk('planning', '48'), path.join(t, 'nope')).status, 'planning');
  fs.rmSync(t, { recursive: true, force: true });
}

// --- § 8 ctx meter: 100% is the auto-compact point, in CC's real payload shape
//
// The bar's 100% is where Claude Code auto-compacts, and the bridge's
// remaining_percentage counts down to that same point, so
// gsd-context-monitor's warnings fire before compaction (not at a
// model-window percentage compaction always beats). Fixtures carry CC's REAL
// statusline `context_window` (built by Uwe() in the CC 2.1.281 binary). It
// has no `total_tokens`: the pre-2026-09-24 fixtures sent one because they
// were shaped to the meter rather than to CC, so they proved only that the
// meter agreed with itself. Arithmetic: .planning/backlog/ brief
// "statusline-ctx-meter-ignores-autocompactwindow" § CC's actual arithmetic.
//
// Every case runs in its own scratch CLAUDE_CONFIG_DIR / project / TMPDIR,
// with the four compaction env vars cleared unless the case sets them, so
// neither the operator's live settings nor this shell's env leak in.

const AC_ENV_KEYS = [
  'CLAUDE_CODE_AUTO_COMPACT_WINDOW', 'CLAUDE_AUTOCOMPACT_PCT_OVERRIDE',
  'DISABLE_COMPACT', 'DISABLE_AUTO_COMPACT',
];
const ctxRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'dhx-sl-ctx-'));
let ctxN = 0;

// CC's payload for a context of `tokens` on a model window of `size`.
function ccContextWindow(tokens, size) {
  const current_usage = {
    input_tokens: 2,
    cache_creation_input_tokens: 819,
    cache_read_input_tokens: tokens - 821,
    output_tokens: 412,
  };
  const used = Math.min(100, Math.max(0, Math.round((tokens / size) * 100)));
  return {
    total_input_tokens: tokens,
    total_output_tokens: 412,
    context_window_size: size,
    current_usage,
    used_percentage: used,
    remaining_percentage: 100 - used,
  };
}

function renderCtx({ cw, user, project, local, claudeJson, env = {} }) {
  const root = path.join(ctxRoot, String(++ctxN));
  const cfg = path.join(root, 'cfg');
  const shared = path.join(root, 'shared');
  const proj = path.join(root, 'proj');
  const sub = path.join(proj, 'sub');
  const tmp = path.join(root, 'tmp');
  for (const d of [cfg, shared, path.join(proj, '.claude'), sub, tmp]) {
    fs.mkdirSync(d, { recursive: true });
  }
  // CCS shape: the config dir's settings.json is a symlink into a shared dir.
  if (user) {
    fs.writeFileSync(path.join(shared, 'settings.json'), JSON.stringify(user));
    fs.symlinkSync(path.join(shared, 'settings.json'), path.join(cfg, 'settings.json'));
  }
  if (project) fs.writeFileSync(path.join(proj, '.claude', 'settings.json'), JSON.stringify(project));
  if (local) fs.writeFileSync(path.join(proj, '.claude', 'settings.local.json'), JSON.stringify(local));
  if (claudeJson) fs.writeFileSync(path.join(cfg, '.claude.json'), JSON.stringify(claudeJson));
  const childEnv = { ...process.env, CLAUDE_CONFIG_DIR: cfg, TMPDIR: tmp, ...env };
  for (const k of AC_ENV_KEYS) if (!(k in env)) delete childEnv[k];
  const session = `probe-ctx-${ctxN}`;
  const out = execFileSync(process.execPath, [SCRIPT], {
    input: JSON.stringify({
      session_id: session,
      model: { display_name: 'Opus 5.5 (1M context)' },
      // current_dir is a SUBDIR: project settings come from project_dir.
      workspace: { current_dir: sub, project_dir: proj },
      context_window: cw,
    }),
    encoding: 'utf8',
    env: childEnv,
  });
  const m = strip(out).match(/[█░]{5} (\d+)%(?: (\d+(?:\.\d)?[kM]))?/);
  let bridge = null;
  try {
    bridge = JSON.parse(fs.readFileSync(path.join(tmp, `claude-ctx-${session}.json`), 'utf8'));
  } catch (e) { /* absent bridge → asserts below report null */ }
  return { pct: m ? Number(m[1]) : null, tokens: m ? (m[2] || null) : null, bridge, tmp, session, proj };
}

const ACW650 = { autoCompactWindow: 650000 };

// (a) settings 650000 on a 1M model → compaction at 650000 − 20000 − 13000 =
//     617,000. 616,927 is the measured preTokens of the 2026-09-24
//     forgefinder compaction (session b9a0a56e) — the meter showed ~74% there.
{
  const r = renderCtx({ cw: ccContextWindow(616927, 1_000_000), user: ACW650 });
  ok('ctx (a): 616,927 against a 617k threshold → ≥ 99%', r.pct !== null && r.pct >= 99, true);
  ok('ctx (a): dim token suffix reads 617k', r.tokens, '617k');
  ok('ctx (a): bridge remaining counts down to compaction (≤ 1)',
     r.bridge !== null && r.bridge.remaining_percentage <= 1, true);
}
// (b) the operator's reading: ~608k, where the meter said 73%.
{
  const r = renderCtx({ cw: ccContextWindow(608000, 1_000_000), user: ACW650 });
  ok('ctx (b): 608k → 98–99%, never 73%', r.pct !== null && r.pct >= 98 && r.pct <= 99, true);
  ok('ctx (b): token suffix reads 608k', r.tokens, '608k');
  ok('ctx (b): bridge used_pct + remaining_percentage = 100 (one scale)',
     r.bridge !== null && r.bridge.used_pct + r.bridge.remaining_percentage, 100);
}
// (c) nothing configured, 200k model → 200000 − 20000 − 13000 = 167,000. The
//     old fixed 16.5% buffer IS 33k/200k, so the old display was right here
//     within rounding; the bridge (raw model-window remaining) was not.
{
  let r = renderCtx({ cw: ccContextWindow(167000, 200000) });
  ok('ctx (c): 167,000 on an unconfigured 200k model → 100%', r.pct, 100);
  r = renderCtx({ cw: ccContextWindow(83500, 200000) });
  ok('ctx (c): 83,500 → 50% (the 100% point is 167k, not 200k)', r.pct, 50);
  r = renderCtx({ cw: ccContextWindow(160000, 200000) });
  ok('ctx (c): 160,000 → bridge remaining 5 (to 167k), not 20 (to 200k)',
     r.bridge && r.bridge.remaining_percentage, 5);
}
// (d) env beats settings: 400000 → 367,000.
{
  const r = renderCtx({ cw: ccContextWindow(183500, 1_000_000), user: ACW650,
                        env: { CLAUDE_CODE_AUTO_COMPACT_WINDOW: '400000' } });
  ok('ctx (d): env 400000 beats settings 650000 → 183.5k is 50% of 367k', r.pct, 50);
  ok('ctx (d): bridge counts down to the env threshold (remaining 50, threshold_tokens 367000)',
     r.bridge && `${r.bridge.remaining_percentage}/${r.bridge.threshold_tokens}`, '50/367000');
}
// Settings chain: user < project < local, read from project_dir.
{
  const r = renderCtx({ cw: ccContextWindow(133500, 1_000_000), user: ACW650,
                        project: { autoCompactWindow: 500000 },
                        local: { autoCompactWindow: 300000 } });
  ok('ctx: project settings.local.json beats project + user → 133.5k is 50% of 267k', r.pct, 50);
  const r2 = renderCtx({ cw: ccContextWindow(233500, 1_000_000), user: ACW650,
                         project: { autoCompactWindow: 500000 } });
  ok('ctx: project settings.json beats user (no local) → 233.5k is 50% of 467k', r2.pct, 50);
  const r3 = renderCtx({ cw: ccContextWindow(83500, 200000), user: ACW650 });
  ok('ctx: settings window above the model window is capped at it → 83.5k is 50% of 167k', r3.pct, 50);
}
// Compaction disabled → 100% is the model window, no compaction scaling.
{
  let r = renderCtx({ cw: ccContextWindow(500000, 1_000_000), user: ACW650,
                      env: { DISABLE_AUTO_COMPACT: '1' } });
  ok('ctx: DISABLE_AUTO_COMPACT=1 → 500k is 50% of the 1M model window', r.pct, 50);
  r = renderCtx({ cw: ccContextWindow(500000, 1_000_000), user: ACW650,
                  env: { DISABLE_COMPACT: 'true' } });
  ok('ctx: DISABLE_COMPACT=true → 50% of the model window', r.pct, 50);
  r = renderCtx({ cw: ccContextWindow(500000, 1_000_000),
                  user: { autoCompactWindow: 650000, autoCompactEnabled: false } });
  ok('ctx: autoCompactEnabled false in settings → 50% of the model window', r.pct, 50);
  r = renderCtx({ cw: ccContextWindow(500000, 1_000_000), user: ACW650,
                  claudeJson: { autoCompactEnabled: false } });
  ok('ctx: autoCompactEnabled false in legacy .claude.json (settings silent) → model window', r.pct, 50);
}
// CLAUDE_AUTOCOMPACT_PCT_OVERRIDE lowers the threshold: floor(630000 × 0.5).
{
  const r = renderCtx({ cw: ccContextWindow(157500, 1_000_000), user: ACW650,
                        env: { CLAUDE_AUTOCOMPACT_PCT_OVERRIDE: '50' } });
  ok('ctx: PCT_OVERRIDE 50 → 157.5k is 50% of 315k', r.pct, 50);
}
// Out-of-range and garbage values are dropped the way CC drops them.
{
  let r = renderCtx({ cw: ccContextWindow(308500, 1_000_000), user: ACW650,
                      env: { CLAUDE_CODE_AUTO_COMPACT_WINDOW: 'abc' } });
  ok('ctx: unparseable env window ignored → settings 650000 applies', r.pct, 50);
  r = renderCtx({ cw: ccContextWindow(33500, 1_000_000),
                  env: { CLAUDE_CODE_AUTO_COMPACT_WINDOW: '50000' } });
  ok('ctx: env window below 100k is clamped up to 100k → 33.5k is 50% of 67k', r.pct, 50);
  r = renderCtx({ cw: ccContextWindow(483500, 1_000_000), user: { autoCompactWindow: 50000 } });
  ok('ctx: settings window below 100k is dropped → model window 1M (967k)', r.pct, 50);
}
// Token suffix formatting.
{
  let r = renderCtx({ cw: ccContextWindow(53000, 1_000_000) });
  ok('ctx: token suffix 53k', r.tokens, '53k');
  r = renderCtx({ cw: ccContextWindow(999700, 1_000_000), env: { DISABLE_COMPACT: '1' } });
  ok('ctx: token suffix at the top reads 1.0M', r.tokens, '1.0M');
}
// Payload without token fields (a CC predating them): CC's own percentage of
// the model window, unscaled — no suffix, nothing invented.
{
  const r = renderCtx({ cw: { remaining_percentage: 85 }, user: ACW650 });
  ok('ctx fallback: no token fields → CC used_percentage 15%, unscaled', r.pct, 15);
  ok('ctx fallback: no token suffix', r.tokens, null);
  ok('ctx fallback: bridge remaining 85', r.bridge && r.bridge.remaining_percentage, 85);
}
// The monitor half: feed the bridge the meter wrote to gsd-context-monitor.js
// and observe its warnings BELOW the 617k compaction point.
{
  const MONITOR = path.join(os.homedir(), '.claude', 'hooks', 'gsd-context-monitor.js');
  const haveMonitor = fs.existsSync(MONITOR);
  ok('ctx monitor: gsd-context-monitor.js is installed (not a silent skip)', haveMonitor, true);
  const monitor = (r) => execFileSync(process.execPath, [MONITOR], {
    input: JSON.stringify({ session_id: r.session, hook_event_name: 'PostToolUse',
                            tool_name: 'Bash', cwd: r.proj }),
    encoding: 'utf8',
    env: { ...process.env, TMPDIR: r.tmp },
  });
  if (haveMonitor) {
    let r = renderCtx({ cw: ccContextWindow(300000, 1_000_000), user: ACW650 });
    ok('ctx monitor: 300k of 617k → silent', monitor(r).includes('CONTEXT'), false);
    r = renderCtx({ cw: ccContextWindow(420000, 1_000_000), user: ACW650 });
    ok('ctx monitor: 420k (< 617k) → CONTEXT WARNING', monitor(r).includes('CONTEXT WARNING'), true);
    r = renderCtx({ cw: ccContextWindow(470000, 1_000_000), user: ACW650 });
    ok('ctx monitor: 470k (< 617k) → CONTEXT CRITICAL', monitor(r).includes('CONTEXT CRITICAL'), true);
  }
}
fs.rmSync(ctxRoot, { recursive: true, force: true });

// --- Summary ----------------------------------------------------------------

console.log();
console.log(`${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
