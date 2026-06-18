// Probe: statusline milestone count derived from the ROADMAP progress table.
//
// Locks: parseRoadmapProgress (table-scoped Complete/total counting with the
// ^999 backlog exclusion) and readGsdState's source preference — the ROADMAP
// progress table overrides the STATE.md progress: block when present, and
// falls back to the STATE block cleanly on any miss (no ROADMAP, no table,
// unreadable).
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
// Pairs with: docs/decisions.md 2026-06-18 statusline-roadmap-progress row;
// dhx/dhx-statusline.js parseRoadmapProgress + readGsdState.
//
// INVARIANT: the ^999 exclusion must apply IDENTICALLY to numerator and
// denominator — it is the table-row form of gsd-core init.cjs:1211's
// `!/^999(?:\.|$)/`. A 999.x backlog row is neither a completed phase nor a
// milestone phase; counting it in either place reintroduces gsd-core bug #1.
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

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
