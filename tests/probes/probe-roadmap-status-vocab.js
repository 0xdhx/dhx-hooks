// Probe: ROADMAP Progress-table Status vocabulary validator.
//
// Locks: scripts/lib/roadmap-status-vocab.js (findInvalidStatusCells, the
// accepted set), scripts/lib/markdown-progress-table.js (the ONE parser both
// consumers use), and dhx/dhx-roadmap-status-vocab.js (the SessionStart hook —
// per-repo, linked-worktree skip, fail-open, silent-on-clean).
//
// Why: `templates/roadmap.md` declares a CLOSED four-token Status vocabulary and
// until 2026-08-30 nothing validated it. Both consumers exact-match the cell, so
// an out-of-vocabulary value reads as NOT complete in the dhx statusline AND in
// gsd-core's whole-table rollup behind /gsd-next's milestone-complete gate. Five
// such cells accumulated across three repos over ~4 months and surfaced only as a
// milestone fraction low by one. See docs/decisions.md 2026-08-29 + 2026-08-30.
//
// INVARIANT (§ 1): both consumers locate tables and split rows through
// markdown-progress-table.js. A validator reading rows the statusline never
// sees — or missing rows it does — would be protecting a different file than the
// one whose strict `/^Complete$/i` numerator it was built to replace. § 1 drives
// ONE fixture through both and asserts they agree on the row set. Do not
// re-implement either helper in a consumer.
//
// INVARIANT (§ 5): the check is on SET MEMBERSHIP, never on parentheses. The
// 2026-08-29 instances all looked like `Complete (<caveat>)` and a `(`-hunting
// regex would encode that symptom rather than the rule — it would pass
// `Checkpoint` (live in sigil) and `Planned` (emitted by gsd-core's own
// `cmdRoadmapUpdatePlanProgress`), neither of which contains a paren. § 5's
// paren-free cells are RED under any punctuation-keyed detector.
//
// INVARIANT (§ 3): the alembic range-row shape must NOT fire. `| Phases 42-48 |
// v3.0 | 22/22 | Complete (Ph46 gate-deferred) |` was excluded from the
// 2026-08-29 normalization ON THE RECORD — a milestone-RANGE summary with no
// `- [x]` twin, invisible to BOTH parsers (its Phase cell fails the leading-digit
// data-row test). A validator that flagged it produces a false positive on day
// one. The exclusion is STRUCTURAL (non-data rows are skipped), deliberately
// chosen over a suppression path so it needs no per-repo state and no annotation
// inside a file gsd-core's verbs rewrite.
//
// INVARIANT (§ 4): the validator's scope is deliberately WIDER than the
// statusline's counting scope in two ways — ALL tables (not just the active
// milestone's; an archived malformed cell is the four-month case AND still
// corrupts upstream's whole-table rollup) and 999.x sentinel rows INCLUDED
// (parseRoadmapProgress excludes them from its count, upstream's derive does
// not, so their vocabulary still matters).
//
// Run: node tests/probes/probe-roadmap-status-vocab.js
//
// SAFE_FOR_LIVE: yes   (pure function driven with in-memory fixtures; the hook cells run against a throwaway git repo + worktree created under a mktemp dir and removed on exit; no writes to any live .planning/, repo, or config path)

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.join(__dirname, '..', '..');
const MOD = path.join(ROOT, 'scripts', 'lib', 'roadmap-status-vocab.js');
const HOOK = path.join(ROOT, 'dhx', 'dhx-roadmap-status-vocab.js');
const STATUSLINE = path.join(ROOT, 'dhx', 'dhx-statusline.js');

const { findInvalidStatusCells, ACCEPTED, READER_RECOGNIZED, WRITER_EMITTED } = require(MOD);
const { parseRoadmapProgress } = require(STATUSLINE);
const { findProgressTables } = require(path.join(ROOT, 'scripts', 'lib', 'markdown-progress-table.js'));

let pass = 0;
let fail = 0;

function ok(label, got, want) {
  const gs = JSON.stringify(got);
  const ws = JSON.stringify(want);
  if (gs === ws) { console.log(`OK   ${label}`); pass++; }
  else { console.log(`FAIL ${label}\n  got:  ${gs}\n  want: ${ws}`); fail++; }
}

/** Statuses flagged by the checker, in document order. */
function flagged(md) {
  return findInvalidStatusCells(md).findings.map((f) => f.status);
}

/** Build a single-table ROADMAP fixture from `| Phase | Status |` pairs. */
function table(rows, opts) {
  const o = opts || {};
  const head = o.milestone
    ? '| Phase | Milestone | Status |\n|-------|-----------|--------|'
    : '| Phase | Status |\n|-------|--------|';
  const body = rows.map(([p, s]) => (o.milestone ? `| ${p} | ${o.milestone} | ${s} |` : `| ${p} | ${s} |`));
  return `# Roadmap\n\n## Progress\n\n${head}\n${body.join('\n')}\n`;
}

// ===========================================================================
// § 1 — Cross-consumer parser agreement (the markdown-progress-table INVARIANT)
// ===========================================================================
{
  // One table, no sentinel rows, no Milestone column: the two consumers' scope
  // choices coincide here, so any disagreement is a PARSER disagreement.
  const md = table([
    ['1. Alpha', 'Complete'],
    ['2. Beta', 'In progress'],
    ['3. Gamma', 'Not started'],
    ['Phases 1-3 (rollup)', 'Complete'],   // non-data row: invisible to BOTH
  ]);
  const sl = parseRoadmapProgress(md, undefined);
  const vv = findInvalidStatusCells(md);
  ok('§1 statusline counts 3 data rows (rollup row excluded)', sl, { completedPhases: 1, totalPhases: 3 });
  ok('§1 validator checked the SAME 3 data rows', vv.rowsChecked, 3);
  ok('§1 validator flags nothing on an all-valid table', vv.findings, []);

  // Column-order permutation: name-based lookup, not positional. If the
  // validator ever forked its own splitter this is where it diverges.
  const perm = '# R\n\n| Phase | Status | Plans Complete |\n|---|---|---|\n| 1. A | Bogus | 1/1 |\n';
  ok('§1 name-based column lookup (Status before Plans)', flagged(perm), ['Bogus']);

  // Both consumers see one table object for one table.
  ok('§1 findProgressTables sees exactly 1 table', findProgressTables(md).length, 1);
}

// ===========================================================================
// § 2 — The accepted set: what passes, and how it normalizes
// ===========================================================================
{
  ok('§2 reader-recognized set is exactly the template four',
    READER_RECOGNIZED.slice(), ['not started', 'in progress', 'complete', 'deferred']);
  ok('§2 writer-emitted suppression is exactly `planned`', WRITER_EMITTED.slice(), ['planned']);
  ok('§2 ACCEPTED is the union', ACCEPTED.slice(),
    ['not started', 'in progress', 'complete', 'deferred', 'planned']);

  const good = table([
    ['1. A', 'Not started'],
    ['2. B', 'In progress'],
    ['3. C', 'Complete'],
    ['4. D', 'Deferred'],
    ['5. E', 'Planned'],
  ]);
  ok('§2 all five accepted values pass', flagged(good), []);

  // Case and surrounding whitespace are normalized away — both readers do
  // trim + lowercase before comparing, so the validator must too.
  const cased = table([
    ['1. A', 'COMPLETE'],
    ['2. B', 'in progress'],
    ['3. C', '   Complete   '],
    ['4. D', 'NoT StArTeD'],
  ]);
  ok('§2 case- and whitespace-insensitive', flagged(cased), []);

  // `Planned` is accepted because gsd-core's own cmdRoadmapUpdatePlanProgress
  // writes it and the operator cannot correct it in the file — flagging it is
  // the cry-wolf case. The writer/reader gap is the sibling brief's, not this
  // hook's. If that lands upstream, drop 'planned' from WRITER_EMITTED and this
  // cell flips by design.
  ok('§2 `Planned` accepted (gsd-core writer emits it)', flagged(table([['9. X', 'Planned']])), []);
}

// ===========================================================================
// § 3 — False-positive traps. Each of these fired in a draft.
// ===========================================================================
{
  // THE alembic shape, verbatim in structure. Phase cell does not start with a
  // digit -> non-data row -> invisible to both parsers -> must not fire.
  const alembic =
    '# Roadmap: alembic\n\n## Progress\n\n' +
    '| Phase | Milestone | Plans | Status | Completed |\n' +
    '|-------|-----------|-------|--------|-----------|\n' +
    '| Phases 42-48 | v3.0 | 22/22 | Complete (Ph46 gate-deferred) | 2026-07-02 |\n' +
    '| 61. Live Phase | v3.3 | 0/3 | Not started | - |\n';
  ok('§3 alembic range-row shape does NOT fire (non-data row)', flagged(alembic), []);
  ok('§3 …and the sibling data row is still checked', findInvalidStatusCells(alembic).rowsChecked, 1);

  // A range row carrying a value that WOULD be flagged on a data row: still
  // silent. Proves the skip is on the Phase cell, not on the Status text.
  const rangeBogus = table([['Phases 1-9', 'Utterly Bogus'], ['1. A', 'Complete']]);
  ok('§3 non-data row is skipped regardless of its Status text', flagged(rangeBogus), []);

  // Unset cells are not misspelled cells. Both readers resolve '' cleanly and
  // `-` is the house placeholder; flagging these fires on every unfilled row.
  const blanks = table([['1. A', ''], ['2. B', '-'], ['3. C', '—'], ['4. D', '--']]);
  ok('§3 blank / dash placeholders do not fire', flagged(blanks), []);
  ok('§3 …and are not counted as checked rows', findInvalidStatusCells(blanks).rowsChecked, 0);

  // A ragged table (unescaped pipe shifts every cell) is WITHHELD, exactly as
  // both readers withhold it — reported as ragged rather than guessed at.
  const ragged =
    '# R\n\n| Phase | Status |\n|---|---|\n| 1. A | Complete |\n| 2. B | Com | plete |\n';
  const rr = findInvalidStatusCells(ragged);
  ok('§3 ragged table withheld, not guessed', rr.findings, []);
  ok('§3 …and the withholding is reported', rr.ragged, 1);

  // No table at all, and non-string input: empty, never a throw.
  ok('§3 no progress table -> no findings', flagged('# Roadmap\n\nProse only.\n'), []);
  ok('§3 empty input -> zero tables', findInvalidStatusCells(''), { findings: [], tables: 0, ragged: 0, rowsChecked: 0 });
  ok('§3 non-string input -> zero tables', findInvalidStatusCells(null), { findings: [], tables: 0, ragged: 0, rowsChecked: 0 });
}

// ===========================================================================
// § 4 — Scope: ALL tables, and sentinel rows are checked
// ===========================================================================
{
  // Two tables, one archived and one active. The statusline anchors on the
  // **Active milestone:** marker and counts ONE; the validator must read BOTH —
  // an archived malformed cell is the four-month case, and it still corrupts
  // gsd-core's whole-table rollup.
  const twoTables =
    '# Roadmap\n\n## Shipped\n\n' +
    '| Phase | Status |\n|---|---|\n| 1. Old | Complete (archived caveat) |\n\n' +
    '**Active milestone: v2.0**\n\n' +
    '| Phase | Status |\n|---|---|\n| 7. New | Checkpoint |\n';
  ok('§4 validator reads BOTH tables', flagged(twoTables), ['Complete (archived caveat)', 'Checkpoint']);
  ok('§4 …while the statusline still counts only the active one',
    parseRoadmapProgress(twoTables, undefined), { completedPhases: 0, totalPhases: 1 });

  // 999.x sentinel rows: excluded from the statusline's COUNT, included in the
  // validator's CHECK. parseRoadmapProgress skips them because a backlog row is
  // not a milestone phase; upstream's derive does not skip them at all, so the
  // cell is still read and its vocabulary still matters.
  const sentinel = table([['1. A', 'Complete'], ['999.1 Icebox', 'Someday']]);
  ok('§4 sentinel row IS vocabulary-checked', flagged(sentinel), ['Someday']);
  ok('§4 …and still excluded from the statusline count',
    parseRoadmapProgress(sentinel, undefined), { completedPhases: 1, totalPhases: 1 });

  // Milestone scoping is the statusline's concern, not the validator's: a
  // malformed cell on a non-active milestone must still fire.
  const scoped = table([['1. A', 'Complete'], ['2. B', 'Bogus']], { milestone: 'v9.9' });
  ok('§4 validator ignores milestone scoping', flagged(scoped), ['Bogus']);
  ok('§4 …while the statusline withholds an unscopable table',
    parseRoadmapProgress(scoped, undefined), null);
}

// ===========================================================================
// § 5 — SET MEMBERSHIP, not parentheses. RED under any punctuation detector.
// ===========================================================================
{
  // The two live paren-free out-of-vocabulary values. A `(`-hunting regex
  // passes both; these cells are what make that implementation impossible to
  // ship green.
  ok('§5 `Checkpoint` fires (no paren — sigil, live)', flagged(table([['21. X', 'Checkpoint']])), ['Checkpoint']);
  ok('§5 `Done` fires (no paren)', flagged(table([['1. X', 'Done']])), ['Done']);
  ok('§5 `Shipped` fires (no paren)', flagged(table([['1. X', 'Shipped']])), ['Shipped']);

  // Nothing is stripped before comparison: both readers compare the trimmed,
  // lowercased cell verbatim, so emphasis and doubled internal whitespace
  // really do fail upstream and must fail here.
  ok('§5 `**Complete**` fires (emphasis is not stripped)', flagged(table([['1. X', '**Complete**']])), ['**Complete**']);
  ok('§5 `Not  started` fires (internal whitespace not collapsed)',
    flagged(table([['1. X', 'Not  started']])), ['Not  started']);

  // The original 2026-08-29 symptom still fires — the rule covers it as one
  // instance, not as the definition.
  const annotated = table([
    ['7. Spike', 'Complete (07-02 spike, no SUMMARY)'],
    ['12. Glue', 'Complete (ACT-03/04 operator-attested)'],
  ]);
  ok('§5 the 2026-08-29 annotated shape still fires',
    flagged(annotated), ['Complete (07-02 spike, no SUMMARY)', 'Complete (ACT-03/04 operator-attested)']);

  // The finding carries the diagnosis the strict-predicate detector could not:
  // which row, which line, which value.
  // The `|| {}` fallback is deliberate: a detector that stops finding this row
  // FAILS these three cells loudly instead of throwing. A crash reads as a
  // broken probe, not a caught regression, and § 5 is exactly where a wrong
  // implementation (a paren-keyed one) lands.
  const one = findInvalidStatusCells(table([['21. Baseball', 'Checkpoint']])).findings[0] || {};
  ok('§5 finding names the phase', one.phase, '21. Baseball');
  ok('§5 finding names the raw value', one.status, 'Checkpoint');
  ok('§5 finding carries a 0-based line index', typeof one.line === 'number' && one.line > 0, true);
}

// ===========================================================================
// § 6 — The hook: per-repo, worktree skip, fail-open, silent on clean
// ===========================================================================
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'probe-roadmap-vocab-'));
process.on('exit', () => { try { fs.rmSync(TMP, { recursive: true, force: true }); } catch {} });

function git(dir, args) {
  return execFileSync('git', ['-C', dir].concat(args),
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
}

/** Run the hook with a synthetic SessionStart payload; return its stdout. */
function runHook(cwd, env) {
  const res = require('child_process').spawnSync('node', [HOOK], {
    input: JSON.stringify({ cwd, session_id: 'probe', source: 'startup', hook_event_name: 'SessionStart' }),
    encoding: 'utf8',
    env: Object.assign({}, process.env, env || {}),
  });
  return { out: res.stdout || '', code: res.status };
}

{
  const main = path.join(TMP, 'repo');
  fs.mkdirSync(path.join(main, '.planning'), { recursive: true });
  git(main, ['init', '-q', '-b', 'main']);
  git(main, ['config', 'user.email', 'probe@example.invalid']);
  git(main, ['config', 'user.name', 'probe']);
  const bad = table([['1. A', 'Complete'], ['2. B', 'Checkpoint']]);
  fs.writeFileSync(path.join(main, '.planning', 'ROADMAP.md'), bad);
  git(main, ['add', '-A']);
  git(main, ['commit', '-q', '-m', 'fixture']);

  const r1 = runHook(main);
  ok('§6 main worktree with a bad cell -> warns', /ROADMAP Status vocabulary: 1 cell/.test(r1.out), true);
  ok('§6 …names the offending value', /`Checkpoint`/.test(r1.out), true);
  ok('§6 …lists the recognized set', /Recognized: Not started · In progress · Complete · Deferred/.test(r1.out), true);
  ok('§6 …and never blocks (exit 0)', r1.code, 0);

  // LINKED WORKTREE: same malformed row, must stay silent. This is the cell
  // that makes the fleet's three duplicate copies non-noise.
  const wt = path.join(TMP, 'wt');
  git(main, ['worktree', 'add', '-q', '-b', 'side', wt]);
  ok('§6 the worktree really carries the same bad row',
    flagged(fs.readFileSync(path.join(wt, '.planning', 'ROADMAP.md'), 'utf8')), ['Checkpoint']);
  const r2 = runHook(wt);
  ok('§6 linked worktree -> SILENT (duplicate that converges on merge)', r2.out, '');
  ok('§6 …and still exit 0', r2.code, 0);

  // Clean ROADMAP -> silent.
  fs.writeFileSync(path.join(main, '.planning', 'ROADMAP.md'), table([['1. A', 'Complete'], ['2. B', 'Not started']]));
  ok('§6 clean ROADMAP -> silent', runHook(main).out, '');

  // Suppression.
  fs.writeFileSync(path.join(main, '.planning', 'ROADMAP.md'), bad);
  ok('§6 DHX_SKIP_ROADMAP_VOCAB=1 -> silent', runHook(main, { DHX_SKIP_ROADMAP_VOCAB: '1' }).out, '');

  // Fail-open: no ROADMAP, not a repo, garbage stdin.
  fs.rmSync(path.join(main, '.planning', 'ROADMAP.md'));
  ok('§6 missing ROADMAP -> silent, exit 0', runHook(main), { out: '', code: 0 });
  const bare = path.join(TMP, 'not-a-repo');
  fs.mkdirSync(bare, { recursive: true });
  ok('§6 non-git dir -> silent, exit 0', runHook(bare), { out: '', code: 0 });
  const junk = require('child_process').spawnSync('node', [HOOK], { input: 'not json', encoding: 'utf8' });
  ok('§6 garbage stdin -> silent, exit 0', { out: junk.stdout, code: junk.status }, { out: '', code: 0 });

  // Findings roll up past the cap rather than flooding SessionStart.
  fs.writeFileSync(path.join(main, '.planning', 'ROADMAP.md'),
    table([['1. A', 'X1'], ['2. B', 'X2'], ['3. C', 'X3'], ['4. D', 'X4']]));
  const capped = runHook(main, { DHX_ROADMAP_VOCAB_MAX: '2' });
  ok('§6 output caps the listing', (capped.out.match(/^ {2}line /gm) || []).length, 2);
  ok('§6 …and rolls up the remainder', /…and 2 more/.test(capped.out), true);
}

// ===========================================================================
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
