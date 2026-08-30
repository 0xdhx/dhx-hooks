#!/usr/bin/env node
// roadmap-status-vocab.js — validate a ROADMAP "## Progress" table's Status
// column against the vocabulary its consumers actually recognize.
//
// Pure module + operator CLI. The SessionStart hook that drives it per-repo is
// dhx/dhx-roadmap-status-vocab.js; the probe is
// tests/probes/probe-roadmap-status-vocab.js. Nothing here touches the
// filesystem except the CLI half at the bottom, which is what makes the check
// hermetically probe-able against fixtures (brief design question 3).
//
// ---------------------------------------------------------------------------
// WHY THIS EXISTS
//
// `templates/roadmap.md` declares a CLOSED four-token vocabulary for the Status
// cell, and until 2026-08-30 nothing anywhere validated it. Both consumers test
// the cell with an EXACT match:
//   - gsd-core `deriveProgressFromRoadmap` (bin/lib/phase-lifecycle.cjs):
//     /^complete$/i after trim
//   - gsd-core `PHASE_STATUS_RANKS` (bin/lib/plan-drift-guard.cjs): a property
//     lookup after trim+lowercase, no paren strip
//   - dhx/dhx-statusline.js `parseRoadmapProgress`: /^Complete$/i after trim
// Resolve all three by SYMBOL, never by line — gsd-core is a separately
// versioned tree (VERSION 1.11.0 as measured 2026-08-30) and its line numbers
// move every release.
//
// So any value outside the recognized set reads as "not complete" everywhere,
// silently. Five such cells accumulated across three repos over ~4 months and
// were found only because a milestone fraction was low by one — see
// docs/decisions.md 2026-08-29.
//
// ---------------------------------------------------------------------------
// SCOPE: THE WHOLE VOCABULARY, NOT THE PARENTHESES
//
// The 2026-08-29 instances all looked like `Complete (<caveat>)`, and a
// detector keyed on `(` would encode that symptom instead of the rule. It would
// also miss the two out-of-vocabulary values that already exist without a
// paren: gsd-core's own writer emits `Planned`, and sigil hand-wrote
// `Checkpoint`. Match on SET MEMBERSHIP, never on punctuation.
//
// ---------------------------------------------------------------------------
// WHY `planned` IS ACCEPTED THOUGH NO READER KNOWS IT
//
// `cmdRoadmapUpdatePlanProgress` (gsd-core bin/lib/roadmap.cjs) writes
// `isComplete ? 'Complete' : summaryCount > 0 ? 'In Progress' : 'Planned'`.
// `planned` is in neither the template's four nor PHASE_STATUS_RANKS, so it is
// a genuine writer/reader mismatch — but it is UPSTREAM's mismatch, emitted by
// a verb the operator invokes and cannot correct in the file (the next verb
// write puts it back). Flagging it would fire on gsd-core's own output with no
// local action available: the cry-wolf failure. It is suppressed HERE and owned
// THERE, by .planning/backlog/2026-08-29-gsd-roadmap-status-writer-reader-
// vocabulary-gap.md. If that brief lands an upstream fix, drop `planned` from
// WRITER_EMITTED and this checker tightens to the four with no other edit.
// ---------------------------------------------------------------------------

const { findProgressTables } = require('./markdown-progress-table.js');

/**
 * The four tokens BOTH readers recognize — `templates/roadmap.md`'s
 * <status_values> block, which is exactly the ROADMAP half of gsd-core's
 * PHASE_STATUS_RANKS (`not started` / `in progress` / `complete` / `deferred`;
 * the map's other four keys are STATE.md "Current Position" vocabulary and
 * never appear in this column). Stored normalized: trim + lowercase, matching
 * how both readers normalize before comparing.
 */
const READER_RECOGNIZED = Object.freeze(['not started', 'in progress', 'complete', 'deferred']);

/** Written by a gsd-core verb, recognized by no reader — see header. */
const WRITER_EMITTED = Object.freeze(['planned']);

const ACCEPTED = Object.freeze([...READER_RECOGNIZED, ...WRITER_EMITTED]);

/**
 * Normalize a raw Status cell for lookup — trim and lowercase, and NOTHING
 * else.
 *
 * INVARIANT: this must stay byte-equivalent to how the readers normalize, or
 * the validator green-lights cells they reject. gsd-core's
 * `normalizePhaseStatus` (plan-drift-guard.cjs) trims and lowercases; its
 * `deriveProgressFromRoadmap` trims and matches case-insensitively. Neither
 * collapses internal whitespace, strips markdown emphasis, or strips
 * parentheses — so `Not  started` and `**Complete**` really do fail upstream,
 * and this checker must flag them rather than be "helpful".
 */
function normalizeStatus(raw) {
  return String(raw == null ? '' : raw).trim().toLowerCase();
}

/**
 * True for a cell that carries no value at all. An unset cell is not a
 * misspelled one: both readers resolve '' to "no status" cleanly (gsd-core's
 * normalizePhaseStatus returns null; derive's regex simply fails), and the
 * `-` / en-dash placeholders are the house convention for "not applicable yet".
 * Flagging these would fire on every not-yet-filled row.
 */
function isBlankStatus(norm) {
  return norm === '' || norm === '-' || norm === '--' || norm === '–' || norm === '—';
}

/**
 * Validate every progress table in `content`.
 *
 * @param {string} content  ROADMAP.md text.
 * @returns {{findings: Array, tables: number, ragged: number, rowsChecked: number}}
 *          findings: `{ phase, status, line }` — `line` is 0-based.
 *
 * Three deliberate scope choices, each of which is a false-positive trap:
 *
 * 1. ALL tables, not just the active milestone's. `parseRoadmapProgress`
 *    anchors on the `**Active milestone:**` marker and counts one table,
 *    because a fraction for a milestone you are not on is meaningless. The
 *    opposite is true for validation: a malformed cell in an archived table is
 *    precisely the one that sits unnoticed for four months, and it still
 *    corrupts gsd-core's WHOLE-TABLE rollup, which feeds /gsd-next's
 *    milestone-complete parity gate.
 *
 * 2. NON-DATA ROWS ARE SKIPPED — a Phase cell not starting with a digit. This
 *    is the same data-row test both readers use (`/^\d/` here and in
 *    parseRoadmapProgress; upstream's derive filters equivalently), so a row
 *    neither reader parses is a row neither reader can mis-parse. It is also
 *    the structural reason alembic's deliberately-retained
 *    `| Phases 42-48 | v3.0 | 22/22 | Complete (Ph46 gate-deferred) |` does not
 *    fire: it is a milestone-RANGE summary with no `- [x]` twin, excluded from
 *    the 2026-08-29 normalization ON THE RECORD, and invisible to both parsers.
 *    A validator that flagged it would be producing a false positive on day one.
 *    Chosen over a suppression path deliberately: this needs no per-repo state,
 *    no ignore file, and no annotation inside a file gsd-core's verbs rewrite.
 *
 * 3. SENTINEL ROWS ARE **NOT** SKIPPED. parseRoadmapProgress excludes `999.x`
 *    backlog rows from its count; upstream's derive does not. Since the cell is
 *    still read upstream, its vocabulary still matters — the validator's scope
 *    is deliberately WIDER than the statusline's counting scope.
 *
 * A ragged table (a data row whose cell count disagrees with the header — an
 * unescaped pipe) is WITHHELD, not guessed at, exactly as both readers withhold
 * it. Counted in `ragged` so a caller can say so rather than silently report 0.
 */
function findInvalidStatusCells(content) {
  const empty = { findings: [], tables: 0, ragged: 0, rowsChecked: 0 };
  if (typeof content !== 'string' || content === '') return empty;

  const tables = findProgressTables(content);
  let ragged = 0;
  let rowsChecked = 0;
  const findings = [];

  for (const table of tables) {
    if (table.ragged) { ragged++; continue; }
    const phaseAt = table.columns.indexOf('phase');
    const statusAt = table.columns.indexOf('status');
    if (phaseAt === -1 || statusAt === -1) continue;   // unreachable via the locator; belt and braces
    for (const row of table.rows) {
      const phase = (row.cells[phaseAt] || '').trim();
      if (!/^\d/.test(phase)) continue;                // scope choice 2
      const raw = (row.cells[statusAt] || '').trim();
      const norm = normalizeStatus(raw);
      if (isBlankStatus(norm)) continue;
      rowsChecked++;
      if (ACCEPTED.indexOf(norm) !== -1) continue;
      findings.push({ phase, status: raw, line: row.line });
    }
  }
  return { findings, tables: tables.length, ragged, rowsChecked };
}

module.exports = {
  READER_RECOGNIZED,
  WRITER_EMITTED,
  ACCEPTED,
  normalizeStatus,
  isBlankStatus,
  findInvalidStatusCells,
};

// ---------------------------------------------------------------------------
// Operator CLI — the fleet sweep. NOT the hook (that is per-repo, and is
// dhx/dhx-roadmap-status-vocab.js). This half exists because the repo you never
// open is exactly the one whose malformed cell sits for months, and a per-repo
// SessionStart hook by construction never looks there.
//
//   node scripts/lib/roadmap-status-vocab.js --fleet
//   node scripts/lib/roadmap-status-vocab.js <repo-or-ROADMAP-path>...
//
// Exit 0 clean, 1 with findings. --fleet skips LINKED WORKTREES for the same
// reason the hook does (see the hook's header): duplicate copies of one logical
// row that converge on merge.
// ---------------------------------------------------------------------------
if (require.main === module) {
  const fs = require('fs');
  const path = require('path');
  const os = require('os');
  const { execFileSync } = require('child_process');

  const argv = process.argv.slice(2);
  const fleet = argv.indexOf('--fleet') !== -1;
  const targets = argv.filter((a) => a !== '--fleet');

  const roadmaps = [];
  if (fleet) {
    const root = process.env.DHX_FLEET_ROOT || path.join(os.homedir(), 'repos');
    let entries = [];
    try { entries = fs.readdirSync(root).sort(); } catch { entries = []; }
    for (const e of entries) {
      const rm = path.join(root, e, '.planning', 'ROADMAP.md');
      if (fs.existsSync(rm)) roadmaps.push(rm);
    }
  }
  for (const t of targets) {
    roadmaps.push(t.endsWith('.md') ? t : path.join(t, '.planning', 'ROADMAP.md'));
  }

  const isLinkedWorktree = (dir) => {
    try {
      const gd = execFileSync('git', ['-C', dir, 'rev-parse', '--absolute-git-dir'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
      const cd = execFileSync('git', ['-C', dir, 'rev-parse', '--git-common-dir'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
      return path.resolve(dir, gd) !== path.resolve(dir, cd);
    } catch { return false; }
  };

  let total = 0;
  let skipped = 0;
  for (const rm of roadmaps) {
    const repoDir = path.dirname(path.dirname(rm));
    if (fleet && isLinkedWorktree(repoDir)) { skipped++; continue; }
    let content = '';
    try { content = fs.readFileSync(rm, 'utf8'); } catch { continue; }
    const r = findInvalidStatusCells(content);
    for (const f of r.findings) {
      total++;
      console.log(`${rm}:${f.line + 1}  phase=${JSON.stringify(f.phase)}  status=${JSON.stringify(f.status)}`);
    }
    if (r.ragged) console.log(`${rm}  (${r.ragged} table(s) withheld — ragged rows, unescaped pipe)`);
  }
  console.log(`\n${roadmaps.length - skipped} ROADMAP(s) checked, ${skipped} linked worktree(s) skipped, ${total} finding(s).`);
  console.log(`accepted: ${ACCEPTED.join(' | ')}`);
  process.exit(total > 0 ? 1 : 0);
}
