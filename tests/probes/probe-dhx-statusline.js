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
  renderEffort, getEffortFromPane, parsePaneEffort,
  EFFORT_RENDER, KNOWN_EFFORT_LEVELS,
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

// parsePaneEffort: regex-scan pane scrollback for CC's own effort markers.
// Both the session banner ("Opus 4.7 ... with xhigh effort · Claude Max")
// and every thinking spinner line ("thinking with xhigh effort") embed the
// level verbatim — parser returns the most-recent match (bottom-up scan),
// validates against KNOWN_EFFORT_LEVELS to reject random word matches from
// user chat, null if nothing hits.
ok('parsePaneEffort: banner variant',
  parsePaneEffort('▝▜█████▛▘  Opus 4.7 (1M context) with xhigh effort · Claude Max'),
  'xhigh');
ok('parsePaneEffort: banner without 1M context',
  parsePaneEffort('▝▜█████▛▘  Opus 4.7 with high effort · Claude Max'),
  'high');
ok('parsePaneEffort: banner without splash prefix rejected',
  parsePaneEffort('Opus 4.7 (1M context) with high effort · Claude Max'),
  null);
ok('parsePaneEffort: thinking spinner — ✻',
  parsePaneEffort('✻ Simmering… (13m 12s · ↓ 3.7k tokens · thinking with max effort)'),
  'max');
ok('parsePaneEffort: thinking spinner — · middle-dot',
  parsePaneEffort('· Whirring… (thinking with medium effort)'),
  'medium');
ok('parsePaneEffort: thinking spinner — * asterisk',
  parsePaneEffort('* Pondering… (thinking with low effort)'),
  'low');
ok('parsePaneEffort: thinking spinner — ✢',
  parsePaneEffort('✢ Swooping… (31s · ↑ 241 tokens · thinking with medium effort)'),
  'medium');
ok('parsePaneEffort: thinking spinner — ✶',
  parsePaneEffort('✶ Running… (41s · ↓ 378 tokens · thinking with high effort)'),
  'high');
ok('parsePaneEffort: thinking line without spinner prefix rejected',
  parsePaneEffort('X Simmering… (thinking with max effort)'),
  null);

// Bottom-up scan: most-recent match wins. Simulates a pane where the banner
// was at top (older session start) and a newer thinking line is below.
const MIXED = [
  '▝▜█████▛▘  Opus 4.7 (1M context) with medium effort · Claude Max',
  'some intermediate output line',
  '✻ Simmering… (13m · ↓ 3.7k tokens · thinking with xhigh effort)',
  'more output after thinking finished',
].join('\n');
ok('parsePaneEffort: mixed — picks most recent (thinking beats banner)',
  parsePaneEffort(MIXED),
  'xhigh');

// Reverse order: thinking was earlier, banner reprinted on /resume.
const RESUMED = [
  '✻ Simmering… (13m · ↓ 3.7k tokens · thinking with low effort)',
  '▝▜█████▛▘  Opus 4.7 (1M context) with max effort · Claude Max',
].join('\n');
ok('parsePaneEffort: reprinted banner wins when it is newest',
  parsePaneEffort(RESUMED),
  'max');

// Validation gate — random chat text should not match.
ok('parsePaneEffort: chat "with low effort" phrase rejected (no Claude/thinking anchor)',
  parsePaneEffort('the user achieved this with low effort overall'),
  null);

// End-of-line anchor guards against false positives from code/doc quoting.
// Real CC lines END with the marker; anything echoing these strings in a
// diff, string literal, or chat reply has trailing characters (`,`, `'`, `"`).
// These came from actual live pane capture during debugging — the regex
// without anchors would incorrectly match them.
ok('parsePaneEffort: code fixture rejected — trailing quote+paren after effort)',
  parsePaneEffort(`          +7k tokens · thinking with max effort)'),`),
  null);
ok('parsePaneEffort: JS string literal with banner text rejected',
  parsePaneEffort(`          +high effort · Claude Max\\n',`),
  null);
ok('parsePaneEffort: doc prose with full banner substring rejected',
  parsePaneEffort('banner (`Opus 4.7 (1M context) with xhigh effort · Claude Max`, prints on startup)'),
  null);
ok('parsePaneEffort: git diff prefix + banner text still matches if line actually ends at Max',
  parsePaneEffort('+  ▝▜█████▛▘  Opus 4.7 (1M context) with xhigh effort · Claude Max'),
  'xhigh');
ok('parsePaneEffort: trailing whitespace after Max allowed',
  parsePaneEffort('▝▜█████▛▘  Opus 4.7 with high effort · Claude Max   '),
  'high');
ok('parsePaneEffort: trailing whitespace after thinking ) allowed',
  parsePaneEffort('· Simmering… (1m · ↓ 500 tokens · thinking with max effort)   '),
  'max');
ok('parsePaneEffort: wrapped source comment with spinner-like text rejected',
  parsePaneEffort('     78 +//   - Spinner:  `...thinking with xhigh effort)'),
  null);
ok('parsePaneEffort: indented JS string literal form rejected',
  parsePaneEffort("    parsePaneEffort('· Simmering… (thinking with max effort)'),"),
  null);

// Unknown level — a future CC level we haven't mapped yet. Parser returns
// null until KNOWN_EFFORT_LEVELS is extended; honest "I don't know" beats
// rendering an unmapped glyph.
ok('parsePaneEffort: unknown level (not in KNOWN_EFFORT_LEVELS)',
  parsePaneEffort('thinking with ultraplus effort'),
  null);

// Empty / null input — failure modes.
ok('parsePaneEffort: empty string → null',     parsePaneEffort(''),        null);
ok('parsePaneEffort: null → null',             parsePaneEffort(null),      null);
ok('parsePaneEffort: undefined → null',        parsePaneEffort(undefined), null);
ok('parsePaneEffort: no effort line → null',   parsePaneEffort('just some\nrandom\noutput'), null);

// KNOWN_EFFORT_LEVELS must stay aligned with EFFORT_RENDER keys, else the
// parser could return a level renderEffort can't render. Pin both sides.
okObj('KNOWN_EFFORT_LEVELS matches EFFORT_RENDER keys',
  [...KNOWN_EFFORT_LEVELS].sort(),
  Object.keys(EFFORT_RENDER).sort());

// getEffortFromPane: integration. TMUX_PANE absent → null (no subprocess).
const prevPane = process.env.TMUX_PANE;
delete process.env.TMUX_PANE;
ok('getEffortFromPane: no TMUX_PANE → null', getEffortFromPane('probe-no-tmux'), null);

// Per-test session_ids isolate the on-disk cache file at /tmp/claude-effort-${id}
// so a successful capture in one assertion can't shadow the next assertion's
// live read. Each id gets unlinked at the end of the try.
const cachePathFor = (id) => path.join(os.tmpdir(), `claude-effort-${id}`);
const trackedCacheIds = [];
const trackId = (id) => { trackedCacheIds.push(id); return id; };

// Stub tmux via a temp shim on PATH that emits whatever DHX_TMUX_STUB_OUT
// env holds. Lets us flip fixture output across assertions without
// rewriting the binary each time.
const tmuxStubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'dhx-tmux-stub-'));
try {
  fs.writeFileSync(
    path.join(tmuxStubDir, 'tmux'),
    '#!/bin/sh\nprintf "%s" "$DHX_TMUX_STUB_OUT"\n',
  );
  fs.chmodSync(path.join(tmuxStubDir, 'tmux'), 0o755);

  const prevPath = process.env.PATH;
  process.env.PATH = `${tmuxStubDir}:${prevPath}`;
  process.env.TMUX_PANE = '%99';

  process.env.DHX_TMUX_STUB_OUT =
    '▝▜█████▛▘  Opus 4.7 (1M context) with xhigh effort · Claude Max\n';
  ok('getEffortFromPane: stub banner → xhigh',
    getEffortFromPane(trackId('probe-banner')), 'xhigh');

  process.env.DHX_TMUX_STUB_OUT =
    '✻ Simmering… (1m · ↓ 500 tokens · thinking with max effort)\n';
  ok('getEffortFromPane: stub thinking → max',
    getEffortFromPane(trackId('probe-thinking')), 'max');

  process.env.DHX_TMUX_STUB_OUT = 'no effort markers here at all\n';
  ok('getEffortFromPane: stub with no markers → null',
    getEffortFromPane(trackId('probe-no-markers')), null);

  process.env.DHX_TMUX_STUB_OUT = '';
  ok('getEffortFromPane: stub empty output → null',
    getEffortFromPane(trackId('probe-empty')), null);

  // Failing binary — shim that exits non-zero should surface as null, not crash.
  fs.writeFileSync(path.join(tmuxStubDir, 'tmux'), '#!/bin/sh\nexit 1\n');
  fs.chmodSync(path.join(tmuxStubDir, 'tmux'), 0o755);
  ok('getEffortFromPane: tmux exits non-zero → null',
    getEffortFromPane(trackId('probe-exit1')), null);

  // Missing binary — PATH with no tmux at all.
  process.env.PATH = '/nonexistent-path-dir';
  ok('getEffortFromPane: tmux not on PATH → null',
    getEffortFromPane(trackId('probe-nopath')), null);

  process.env.PATH = prevPath;
  delete process.env.DHX_TMUX_STUB_OUT;

  // --- Cache layer (added 2026-04-26) ---
  // Restore working stub for cache-layer tests.
  fs.writeFileSync(
    path.join(tmuxStubDir, 'tmux'),
    '#!/bin/sh\nprintf "%s" "$DHX_TMUX_STUB_OUT"\n',
  );
  fs.chmodSync(path.join(tmuxStubDir, 'tmux'), 0o755);
  process.env.PATH = `${tmuxStubDir}:${prevPath}`;

  // 1. Cache hit — pre-populated /tmp/claude-effort-<id> within TTL is
  //    returned verbatim and the live tmux read is skipped. Verified
  //    indirectly by stubbing tmux to emit a *different* level — cache
  //    must win.
  {
    const id = trackId('probe-cache-hit-001');
    fs.writeFileSync(cachePathFor(id), 'high');
    process.env.DHX_TMUX_STUB_OUT =
      '▝▜█████▛▘  Opus 4.7 (1M context) with max effort · Claude Max\n';
    ok('getEffortFromPane: cache hit returns cached, ignores live',
      getEffortFromPane(id), 'high');
  }

  // 2. Cache miss after TTL — same fixture but we age the cache file's
  //    mtime past the 30s TTL via utimes; the live capture must run and
  //    overwrite the cache.
  {
    const id = trackId('probe-cache-stale-001');
    fs.writeFileSync(cachePathFor(id), 'low');
    const past = (Date.now() - 60_000) / 1000;
    fs.utimesSync(cachePathFor(id), past, past);
    process.env.DHX_TMUX_STUB_OUT =
      '✻ Simmering… (1m · ↓ 500 tokens · thinking with medium effort)\n';
    ok('getEffortFromPane: stale cache → live recapture',
      getEffortFromPane(id), 'medium');
    ok('getEffortFromPane: stale cache → file overwritten',
      fs.readFileSync(cachePathFor(id), 'utf8').trim(), 'medium');
    const ageMs = Date.now() - fs.statSync(cachePathFor(id)).mtimeMs;
    ok('getEffortFromPane: stale cache → mtime refreshed (<5s)',
      ageMs < 5000, true);
  }

  // 3. Cache write failure tolerated — pre-create cachePath as a directory
  //    so writeFileSync throws EISDIR. Renderer must still return the
  //    parsed value.
  {
    const id = trackId('probe-cache-noperm-001');
    fs.mkdirSync(cachePathFor(id));
    process.env.DHX_TMUX_STUB_OUT =
      '▝▜█████▛▘  Opus 4.7 (1M context) with high effort · Claude Max\n';
    ok('getEffortFromPane: cache write failure does not break renderer',
      getEffortFromPane(id), 'high');
    fs.rmdirSync(cachePathFor(id));
  }

  // 4. Malicious session_id → null without touching tmux or cache. We
  //    swap the stub binary to one that records invocations to a side
  //    file, then assert nothing was recorded after each bad-id call.
  {
    const invocationLog = path.join(tmuxStubDir, 'invocations.log');
    fs.writeFileSync(
      path.join(tmuxStubDir, 'tmux'),
      `#!/bin/sh\necho "called" >> "${invocationLog}"\nprintf "%s" "$DHX_TMUX_STUB_OUT"\n`,
    );
    fs.chmodSync(path.join(tmuxStubDir, 'tmux'), 0o755);
    process.env.DHX_TMUX_STUB_OUT =
      '▝▜█████▛▘  Opus 4.7 (1M context) with max effort · Claude Max\n';

    const malicious = ['../etc/passwd', 'foo/bar', 'foo\\bar', '..', '.well/then'];
    let allNull = true;
    let anyTmuxCalled = false;
    let anyCacheLeak = false;
    const tmpDir = os.tmpdir();
    const beforeFiles = new Set(
      fs.readdirSync(tmpDir).filter(f => f.startsWith('claude-effort-'))
    );
    for (const id of malicious) {
      const r = getEffortFromPane(id);
      if (r !== null) allNull = false;
      const afterFiles = fs.readdirSync(tmpDir).filter(f => f.startsWith('claude-effort-'));
      for (const f of afterFiles) {
        if (!beforeFiles.has(f)) { anyCacheLeak = true; break; }
      }
    }
    if (fs.existsSync(invocationLog)) anyTmuxCalled = true;
    ok('getEffortFromPane: malicious session_ids → null',
      allNull, true);
    ok('getEffortFromPane: malicious session_ids → no cache file leaked',
      anyCacheLeak, false);
    ok('getEffortFromPane: malicious session_ids → no tmux invocation',
      anyTmuxCalled, false);
    fs.rmSync(invocationLog, { force: true });

    // Restore plain stub for any later tests.
    fs.writeFileSync(
      path.join(tmuxStubDir, 'tmux'),
      '#!/bin/sh\nprintf "%s" "$DHX_TMUX_STUB_OUT"\n',
    );
    fs.chmodSync(path.join(tmuxStubDir, 'tmux'), 0o755);
    delete process.env.DHX_TMUX_STUB_OUT;
  }

  // 5. Empty / null session_id → live capture runs but no cache file is
  //    written. Codifies "cache is an optimization, not a correctness
  //    dependency" — the renderer still works without a session_id.
  {
    const tmpDir = os.tmpdir();
    const before = new Set(
      fs.readdirSync(tmpDir).filter(f => f.startsWith('claude-effort-'))
    );
    process.env.DHX_TMUX_STUB_OUT =
      '▝▜█████▛▘  Opus 4.7 (1M context) with high effort · Claude Max\n';
    ok('getEffortFromPane: empty session_id still parses live value',
      getEffortFromPane(''), 'high');
    ok('getEffortFromPane: null session_id still parses live value',
      getEffortFromPane(null), 'high');
    const after = fs.readdirSync(tmpDir).filter(f => f.startsWith('claude-effort-'));
    let leaked = false;
    for (const f of after) if (!before.has(f)) { leaked = true; break; }
    ok('getEffortFromPane: no cache file when session_id absent',
      leaked, false);
    delete process.env.DHX_TMUX_STUB_OUT;
  }

  process.env.PATH = prevPath;
} finally {
  fs.rmSync(tmuxStubDir, { recursive: true, force: true });
  for (const id of trackedCacheIds) {
    fs.rmSync(cachePathFor(id), { force: true, recursive: true });
  }
  if (prevPane !== undefined) process.env.TMUX_PANE = prevPane;
  else delete process.env.TMUX_PANE;
}

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
const outSingle = renderWithFixtures({
  session_id: 'probe',
  model: { display_name: 'Opus 4.7 (1M context)' },
  workspace: { current_dir: os.tmpdir() },
  context_window: { total_tokens: 1_000_000, remaining_percentage: 85 },
});
ok('e2e: single line when no GSD + no signals (no newline)',
  outSingle.includes('\n'), false);
ok('e2e: single line has compact model',
  outSingle.includes('o4.7+'), true);
ok('e2e: effort glyph renders with space after model',
  strip(outSingle).includes('o4.7+ ⣤'), true);

// hooks repo (signals only, no GSD frontmatter) → two lines
const outHooks = renderWithFixtures({
  session_id: 'probe',
  model: { display_name: 'Opus 4.7 (1M context)' },
  workspace: { current_dir: '/home/dhx/repos/hooks' },
  context_window: { total_tokens: 1_000_000, remaining_percentage: 85 },
});
const [hLine1, hLine2] = outHooks.split('\n');
ok('e2e: hooks repo produces two lines', outHooks.includes('\n'), true);
ok('e2e: hooks repo line 2 has R prefix', strip(hLine2 || '').match(/R\d+/) !== null, true);

// Clean up e2e tmux stub after all renderWithFixtures calls complete.
fs.rmSync(e2eStubDir, { recursive: true, force: true });

// --- Summary ----------------------------------------------------------------

console.log();
console.log(`${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
