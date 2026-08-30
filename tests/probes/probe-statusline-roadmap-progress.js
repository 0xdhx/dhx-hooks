// Probe: statusline milestone count derived from the ROADMAP progress table.
//
// Locks: parseRoadmapProgress (NAME-based column lookup, milestone-scoped
// Complete/total counting, ^999 backlog exclusion) and readGsdState's source
// preference — the ROADMAP progress table overrides the STATE.md progress:
// block when present, and falls back to the STATE block cleanly on any miss
// (no ROADMAP, no table, unscopable table, unreadable).
//
// Why: the STATE progress: block is orphan-prone (only verb-written, so
// hand-completed phases freeze it) and carries two gsd-core bugs — 999.x
// rows inflate the total, and a don't-regress ratchet cements a stale-high
// total. This change sources the count from the verb-/human-maintained
// ROADMAP table instead. The discriminating test is the DISAGREEMENT case:
// STATE says 3/6, table says 5/5 → the table must win. (Asserting only
// "statforge reads 5/5" proves nothing once its STATE block is hand-patched
// to 5/5 — both sources agree. The fixture forces them to disagree.)
//
// Pairs with: docs/decisions.md 2026-06-18 statusline-roadmap-progress row and
// the 2026-08-29 name-based-columns + milestone-scoping row;
// dhx/dhx-statusline.js parseRoadmapProgress + findProgressTable + readGsdState.
//
// INVARIANT: the ^999 exclusion must apply IDENTICALLY to numerator and
// denominator. A 999.x backlog row is neither a completed phase nor a
// milestone phase; counting it in either place reintroduces gsd-core bug #1.
//
// INVARIANT: the exclusion is 999-ONLY, and Phase 0 COUNTS. That divergence
// from upstream is SETTLED and DELIBERATE (2026-08-29), not a lag — do not
// "align" it. Resolve the canonical upstream form by SYMBOL, never by line:
// `isSentinelPhaseId` in bin/lib/phase-id.cjs, backed by
// `SENTINEL_RANGES = Object.freeze([0, 999])`, applied to progress by
// `deriveProgressFromRoadmap` in bin/lib/phase-lifecycle.cjs. (The originating
// spec cited `init.cjs:1211`; that literal no longer exists upstream.) In GSD's
// canon `0` is the backlog range; in this fleet `Phase 0` is a validation
// spike / fork skeleton — a real phase. Three of 17 tables carry one, and
// adopting {0, 999} moves xpression-ndi 3/5 -> 2/4, dropping a Complete 6-plan
// phase from a CONTROL repo. The § 1 Phase-0 cell below is what makes a silent
// re-alignment impossible; see docs/decisions.md 2026-08-29 sentinel-divergence
// row and .planning/backlog/shipped/2026-08-29-statusline-sentinel-phase-zero-
// divergence.md.
//
// INVARIANT: columns are read by NAME, never by position. 12 of the 17 repos
// carrying a progress table use a 5-column shape with a Milestone column, so
// `split('|')[3]` is the Plans cell on most of the fleet, not Status. § 3's
// column-order permutation case is the discriminating test: it passes only on
// a name→index map.
//
// INVARIANT: when the table has a Milestone column, counting MUST be scoped to
// the active milestone, and a table that cannot be scoped MUST be withheld
// (null → STATE fallback) rather than widened. These tables are whole-project
// and mixed-granularity — historical milestones as collapsed range rows beside
// per-phase rows for the live one — so an unscoped count is a fraction
// belonging to no milestone (sideline: 11/16).
//
// Run: node tests/probes/probe-statusline-roadmap-progress.js
//
// SAFE_FOR_LIVE: yes   (re-implements helpers via require; all fixtures under a mktemp dir, removed on exit; no writes to live .planning/ or any path outside tmp)
const fs = require('fs');
const os = require('os');
const path = require('path');

const SCRIPT = path.join(__dirname, '..', '..', 'dhx', 'dhx-statusline.js');
const { parseRoadmapProgress, readGsdState } = require(SCRIPT);

let pass = 0;
let fail = 0;

function okObj(label, got, want) {
  const gs = JSON.stringify(got);
  const ws = JSON.stringify(want);
  if (gs === ws) { console.log(`OK   ${label}`); pass++; }
  else { console.log(`FAIL ${label}\n  got:  ${gs}\n  want: ${ws}`); fail++; }
}

// --- fixtures ---------------------------------------------------------------

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'probe-roadmap-progress-'));
process.on('exit', () => { try { fs.rmSync(TMP, { recursive: true, force: true }); } catch {} });

let nDir = 0;
// Write a .planning/ fixture and return its containing dir (what readGsdState
// walks up from). roadmapMd === null → no ROADMAP.md is written at all.
function mkFixture(stateMd, roadmapMd) {
  const dir = path.join(TMP, `f${nDir++}`);
  fs.mkdirSync(path.join(dir, '.planning'), { recursive: true });
  fs.writeFileSync(path.join(dir, '.planning', 'STATE.md'), stateMd);
  if (roadmapMd !== null) fs.writeFileSync(path.join(dir, '.planning', 'ROADMAP.md'), roadmapMd);
  return dir;
}

const state = (completed, total) => `---
gsd_state_version: 1.0
milestone: vT
status: executing
progress:
  total_phases: ${total}
  completed_phases: ${completed}
---

# Project State
Phase: ${completed} (fixture)
`;

const tableFiveComplete = `**Active milestone: vT**

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 46. Pre-flight | 6/6 | Complete | 2026-06-16 |
| 47. Debt Paydown | 3/3 | Complete    | 2026-06-17 |
| 48. Core Extraction | 5/5 | Complete | 2026-06-17 |
| 49. Rewire | 8/8 | Complete   | 2026-06-18 |
| 50. Verification | 6/6 | Complete | 2026-06-18 |
`;

// --- § 1 parseRoadmapProgress (unit) ---------------------------------------

okObj('parse: five Complete rows → 5/5',
  parseRoadmapProgress(tableFiveComplete), { completedPhases: 5, totalPhases: 5 });

okObj('parse: mixed Status — In Progress/Pending count in total, not completed',
  parseRoadmapProgress(`| Phase | Plans Complete | Status | Completed |
|---|---|---|---|
| 1. A | 2/2 | Complete | 2026-01-01 |
| 2. B | 1/2 | In Progress |  |
| 3. C | 0/1 | Pending |  |
`), { completedPhases: 1, totalPhases: 3 });

okObj('parse: 999.x backlog row excluded from BOTH numerator and total',
  parseRoadmapProgress(`| Phase | Plans Complete | Status | Completed |
|---|---|---|---|
| 1. A | 2/2 | Complete | 2026-01-01 |
| 2. B | 1/2 | In Progress |  |
| 999.1 Backlog | 0/1 | Pending |  |
`), { completedPhases: 1, totalPhases: 2 });

okObj('parse: 999.x row marked Complete still excluded (no numerator inflation)',
  parseRoadmapProgress(`| Phase | Plans Complete | Status | Completed |
|---|---|---|---|
| 1. A | 2/2 | Complete | 2026-01-01 |
| 999.4 Backlog shipped | 1/1 | Complete | 2026-06-05 |
`), { completedPhases: 1, totalPhases: 1 });

// The mirror image of the two cells above, and the reason they are 999-only.
// Modelled on xpression-ndi's real shape (4-column, no Milestone column) so it
// exercises the UNSCOPED path — nothing else can remove the row. Under the
// shipped 999-only predicate this is 2/3; under gsd-core's {0, 999} it would be
// 1/2. A cell that passes under both predicates asserts nothing.
okObj('parse: Phase 0 COUNTS (deliberate divergence from gsd-core SENTINEL_RANGES)',
  parseRoadmapProgress(`| Phase | Plans Complete | Status | Completed |
|---|---|---|---|
| 0. Fork + CI Skeleton | 6/6 | Complete | 2026-06-19 |
| 1. A | 2/2 | Complete | 2026-01-01 |
| 2. B | 1/2 | In Progress |  |
| 999.1 Backlog | 0/1 | Pending |  |
`), { completedPhases: 2, totalPhases: 3 });

okObj('parse: no progress table → null', parseRoadmapProgress(`# Roadmap

- [x] Phase 1: did a thing
- [ ] Phase 2: pending thing
`), null);

okObj('parse: empty content → null', parseRoadmapProgress(''), null);

// Active-milestone marker anchoring: an archived table precedes the marker;
// the active table follows it. Must count the ACTIVE one (1/3), not the
// archived one (2/2).
okObj('parse: anchors on **Active milestone:** marker, skips archived table',
  parseRoadmapProgress(`## Shipped Milestones

| Phase | Plans Complete | Status | Completed |
|---|---|---|---|
| 1. old | 2/2 | Complete | 2025-01-01 |
| 2. old | 2/2 | Complete | 2025-01-02 |

## Progress

**Active milestone: vT**

| Phase | Plans Complete | Status | Completed |
|---|---|---|---|
| 10. new | 1/1 | Complete | 2026-01-01 |
| 11. new | 0/1 | In Progress |  |
| 12. new | 0/1 | Pending |  |
`), { completedPhases: 1, totalPhases: 3 });

// --- § 2 readGsdState source preference (integration) ----------------------

// THE discriminating test: STATE and ROADMAP disagree → the table wins.
{
  const dir = mkFixture(state(3, 6), tableFiveComplete);
  const s = readGsdState(dir);
  okObj('readGsdState: STATE 3/6 vs table 5/5 → table wins (5/5)',
    { completedPhases: s.completedPhases, totalPhases: s.totalPhases },
    { completedPhases: 5, totalPhases: 5 });
}

// No progress table in ROADMAP → STATE block is the fallback (unchanged behavior).
{
  const dir = mkFixture(state(3, 6), `# Roadmap

- [x] Phase 1
- [ ] Phase 2
`);
  const s = readGsdState(dir);
  okObj('readGsdState: ROADMAP has no table → STATE block fallback (3/6)',
    { completedPhases: s.completedPhases, totalPhases: s.totalPhases },
    { completedPhases: 3, totalPhases: 6 });
}

// No ROADMAP.md at all → STATE block (the majority-of-repos case).
{
  const dir = mkFixture(state(3, 6), null);
  const s = readGsdState(dir);
  okObj('readGsdState: no ROADMAP.md → STATE block fallback (3/6)',
    { completedPhases: s.completedPhases, totalPhases: s.totalPhases },
    { completedPhases: 3, totalPhases: 6 });
}

// Malformed ROADMAP (table header but garbage body) → no valid parse → STATE block.
{
  const dir = mkFixture(state(7, 7), `garbage | Phase | not | a | table\n   not markdown`);
  const s = readGsdState(dir);
  okObj('readGsdState: malformed ROADMAP → STATE block preserved (7/7)',
    { completedPhases: s.completedPhases, totalPhases: s.totalPhases },
    { completedPhases: 7, totalPhases: 7 });
}

// 999 in the table must not inflate the count even when STATE disagrees.
{
  const dir = mkFixture(state(9, 9), `**Active milestone: vT**

| Phase | Plans Complete | Status | Completed |
|---|---|---|---|
| 1. A | 1/1 | Complete | 2026-01-01 |
| 2. B | 1/1 | Complete | 2026-01-02 |
| 999.1 Backlog | 0/1 | Pending |  |
`);
  const s = readGsdState(dir);
  okObj('readGsdState: table with 999.x row → 2/2 (999 excluded, table wins over STATE 9/9)',
    { completedPhases: s.completedPhases, totalPhases: s.totalPhases },
    { completedPhases: 2, totalPhases: 2 });
}

// --- summary ----------------------------------------------------------------


// --- § 3 name-based columns + milestone scoping (2026-08-29) ---------------
//
// Everything above § 3 uses a 4-column table, which is why this file was green
// on a defect present since the day it shipped: an ABSENT FIXTURE, not a weak
// assertion. 12 of the 17 repos carrying a progress table use a 5-column shape
// with a Milestone column, and both the old header regex (which pinned cell 3
// to Status) and the old `row.split('|')[3]` status read were positional.

const fiveCol = `| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 10. A | v2.0 | 2/2 | Complete | 2026-01-01 |
| 11. B | v2.0 | 0/3 | In progress | - |
| 12. C | v2.0 | 0/TBD | Not started | - |
`;

okObj('parse: 5-column (Milestone) table parses when scoped',
  parseRoadmapProgress(fiveCol, 'v2.0'), { completedPhases: 1, totalPhases: 3 });

// THE discriminating case: passes only on a name→index map. Any positional
// implementation reads the wrong cell for Status and returns 0 completed.
okObj('parse: column-order permutation (Status before Plans Complete) → same result',
  parseRoadmapProgress(`| Phase | Milestone | Status | Plans Complete | Completed |
|-------|-----------|--------|----------------|-----------|
| 10. A | v2.0 | Complete | 2/2 | 2026-01-01 |
| 11. B | v2.0 | In progress | 0/3 | - |
| 12. C | v2.0 | Not started | 0/TBD | - |
`, 'v2.0'), { completedPhases: 1, totalPhases: 3 });

// alembic names the plans column `Plans`; everyone else `Plans Complete`.
// Neither is required — only Phase and Status are.
okObj("parse: `Plans` (alembic) and `Plans Complete` both parse",
  parseRoadmapProgress(fiveCol.replace('Plans Complete', 'Plans'), 'v2.0'),
  { completedPhases: 1, totalPhases: 3 });

okObj('parse: plans column absent entirely → still parses (Phase+Status only)',
  parseRoadmapProgress(`| Phase | Milestone | Status | Completed |
|---|---|---|---|
| 10. A | v2.0 | Complete | 2026-01-01 |
| 11. B | v2.0 | Not started | - |
`, 'v2.0'), { completedPhases: 1, totalPhases: 2 });

okObj('parse: unrecognized extra columns are ignored, not fatal',
  parseRoadmapProgress(`| Phase | Owner | Milestone | Risk | Plans Complete | Status | Completed |
|---|---|---|---|---|---|---|
| 10. A | dhx | v2.0 | low | 2/2 | Complete | 2026-01-01 |
| 11. B | dhx | v2.0 | high | 0/3 | Not started | - |
`, 'v2.0'), { completedPhases: 1, totalPhases: 2 });

okObj('parse: column names match case-insensitively and trimmed',
  parseRoadmapProgress(`|  PHASE  |  milestone  |  Status  |
|---|---|---|
| 10. A | v2.0 | Complete |
| 11. B | v2.0 | Not started |
`, 'v2.0'), { completedPhases: 1, totalPhases: 2 });

// --- milestone scoping ------------------------------------------------------
//
// These tables are ONE whole-project table of mixed granularity: historical
// milestones collapsed to range rows, plus per-phase rows for the live one.
// Counting every row yields a fraction belonging to no milestone.

const mixedGranularity = `| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1-4 | v1.0 | 9/9 | Complete | 2026-02-27 |
| 5-11 | v1.0 | 7/7 | Complete | 2026-03-09 |
| 12-22 | v1.5 | 15/15 | Complete | 2026-03-10 |
| 61. Evidence Base | v2.0 | 2/2 | Complete | 2026-08-28 |
| 62. Vocabulary Tuning | v2.0 | 0/11 | In progress | - |
| 63. Per-Section Batching | v2.0 | 0/1 | Not started | - |
`;

okObj('parse: mixed-granularity table counts ONLY the active milestone (v2.0 → 1/3)',
  parseRoadmapProgress(mixedGranularity, 'v2.0'), { completedPhases: 1, totalPhases: 3 });

// Explicit negative: the unscoped whole-table count (4 Complete of 6 rows) is
// a fraction belonging to no milestone. A name-based fix WITHOUT scoping
// returns it — that is the failure this assertion exists to catch.
{
  const got = parseRoadmapProgress(mixedGranularity, 'v2.0');
  okObj('parse: unscoped whole-table count (4/6) is NOT returned',
    got && got.completedPhases === 4 && got.totalPhases === 6, false);
}

okObj('parse: scoping to a historical milestone counts its range rows (v1.0 → 2/2)',
  parseRoadmapProgress(mixedGranularity, 'v1.0'), { completedPhases: 2, totalPhases: 2 });

okObj('parse: milestone match is case-insensitive and trimmed',
  parseRoadmapProgress(mixedGranularity, '  V2.0  '), { completedPhases: 1, totalPhases: 3 });

// Withhold rather than guess — both misses must fall back to STATE, never
// silently widen to the unscoped count.
okObj('parse: Milestone column present but no active milestone → null',
  parseRoadmapProgress(mixedGranularity, undefined), null);

okObj('parse: Milestone column present, STATE milestone null → null',
  parseRoadmapProgress(mixedGranularity, null), null);

okObj('parse: Milestone column present, milestone matches no row → null',
  parseRoadmapProgress(mixedGranularity, 'v9.9'), null);

// No Milestone column → count all rows exactly as before, milestone ignored.
// This is the 4-column repos' path; their numbers must not move.
okObj('parse: no Milestone column → unscoped count, active milestone irrelevant',
  parseRoadmapProgress(tableFiveComplete, 'v-does-not-matter'),
  { completedPhases: 5, totalPhases: 5 });

okObj('parse: no Milestone column and no milestone argument → unchanged 4-col behaviour',
  parseRoadmapProgress(tableFiveComplete), { completedPhases: 5, totalPhases: 5 });

// The ^999 exclusion still applies identically to numerator and denominator
// INSIDE a milestone-scoped table.
okObj('parse: ^999 exclusion applies within a milestone-scoped table',
  parseRoadmapProgress(`| Phase | Milestone | Status |
|---|---|---|
| 10. A | v2.0 | Complete |
| 11. B | v2.0 | Not started |
| 999.1 Backlog | v2.0 | Complete |
`, 'v2.0'), { completedPhases: 1, totalPhases: 2 });

// Non-numeric phase cells are not data rows (alembic's `Phases 0-6` range
// rows, and the delimiter row itself).
okObj('parse: non-numeric Phase cells are not counted as data rows',
  parseRoadmapProgress(`| Phase | Milestone | Status |
| --- | --- | --- |
| Phases 0-6 | v2.0 | Complete |
| 10. A | v2.0 | Complete |
| 11. B | v2.0 | Not started |
`, 'v2.0'), { completedPhases: 1, totalPhases: 2 });

// A row whose cell count disagrees with the header (an unescaped pipe shifts
// every cell after it) is ambiguous — withhold the whole table.
okObj('parse: cell-count mismatch → null (ambiguous, falls back to STATE)',
  parseRoadmapProgress(`| Phase | Milestone | Status |
|---|---|---|
| 10. A | v2.0 | Complete |
| 11. B | pipe | in | name | v2.0 | Not started |
`, 'v2.0'), null);

// A prose row mentioning both words is not a header — the delimiter row is
// what makes the locate specific.
okObj('parse: Phase/Status row with no delimiter row is not read as a header',
  parseRoadmapProgress(`| Phase | Status | notes about the phase and its status |
| 10. A | Complete | prose |
`, 'v2.0'), null);

// --- § 4 readGsdState threads STATE's milestone through (integration) ------

// End-to-end on the sideline shape: STATE says 0/6 (stale verb-written block),
// the table says the milestone's first phase is Complete. The table wins AND
// is scoped — the unscoped 4/6 must not appear.
{
  const dir = mkFixture(`---
gsd_state_version: 1.0
milestone: v2.0
status: executing
progress:
  total_phases: 6
  completed_phases: 0
---

# Project State
`, mixedGranularity);
  const s = readGsdState(dir);
  okObj('readGsdState: mixed-granularity table scoped by STATE milestone (v2.0 → 1/3)',
    { completedPhases: s.completedPhases, totalPhases: s.totalPhases },
    { completedPhases: 1, totalPhases: 3 });
}

// STATE declares no milestone but the table has a Milestone column → withhold
// the table and keep the STATE block, rather than widening to 4/6.
{
  const dir = mkFixture(`---
gsd_state_version: 1.0
status: executing
progress:
  total_phases: 6
  completed_phases: 2
---

# Project State
`, mixedGranularity);
  const s = readGsdState(dir);
  okObj('readGsdState: Milestone column but no STATE milestone → STATE block (2/6)',
    { completedPhases: s.completedPhases, totalPhases: s.totalPhases },
    { completedPhases: 2, totalPhases: 6 });
}

// --- § 5 annotated `Complete (…)` cells do NOT count (2026-08-29) ----------
//
// INVARIANT: the Status numerator test is EXACT — `/^Complete$/i` on the
// trimmed cell — and that strictness is DELIBERATE and RETAINED, not an
// oversight to be tidied away. Do NOT loosen it to `/^Complete\b/i` or to a
// parenthetical-tolerant form.
//
// The write-time detector this INVARIANT once named as the precondition HAS
// LANDED (2026-08-30: dhx/dhx-roadmap-status-vocab.js +
// scripts/lib/roadmap-status-vocab.js, brief closed to
// .planning/backlog/shipped/2026-08-29-roadmap-status-vocabulary-validator.md).
// Relaxing was therefore re-decided on the merits, not carried forward: it
// stays strict because the UPSTREAM readers are still exact-match, so loosening
// would make this renderer read correct over data gsd-core's rollup still reads
// wrong — an invisible disagreement, since the two are different quantities —
// and because the annotation is erased by the next verb write regardless. The
// full argument is at the predicate site in dhx/dhx-statusline.js.
//
// Why, precisely: five rows across three repos wrote a parenthetical into the
// Status cell over ~4 months, and BOTH consumers reject it — this predicate
// and gsd-core's own `/^complete$/i` in deriveProgressFromRoadmap
// (bin/lib/phase-lifecycle.cjs — resolve by SYMBOL, never by line). The five
// rows were normalized on 2026-08-29 instead of the predicate being widened,
// because normalization fixes BOTH consumers while loosening fixes only this
// one and leaves upstream's rollup — which feeds /gsd-next's whole-table
// milestone-complete parity gate — still undercounting.
//
// The strictness is therefore load-bearing as a DETECTOR. With the five known
// rows normalized there is no standing noise floor, so the next annotated row
// anyone writes shows up as a milestone fraction low by exactly one against a
// baseline that was right. Loosening deletes that signal before its
// replacement exists. These cells are what makes deleting it impossible in
// silence: both go RED under `/^Complete\b/i`.
//
// Note the second cell. `\b` is the tempting "minimal" loosening, and it
// would silently count `Complete pending review` — prose asserting the exact
// opposite of completion — as a completed phase.
//
// See docs/decisions.md 2026-08-29 annotated-Status-cells row.

okObj('parse: annotated `Complete (partial-by-design, …)` counts in total, NOT numerator',
  parseRoadmapProgress(`| Phase | Plans Complete | Status | Completed |
|---|---|---|---|
| 1. A | 2/2 | Complete | 2026-01-01 |
| 2. B | 7/7 | Complete (partial-by-design, 6/7 reqs) | 2026-08-15 |
`), { completedPhases: 1, totalPhases: 2 });

okObj('parse: trailing prose after Complete does not count either (`\\b` red-test)',
  parseRoadmapProgress(`| Phase | Plans Complete | Status | Completed |
|---|---|---|---|
| 1. A | 2/2 | Complete | 2026-01-01 |
| 2. B | 3/3 | Complete pending review | - |
`), { completedPhases: 1, totalPhases: 2 });

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
