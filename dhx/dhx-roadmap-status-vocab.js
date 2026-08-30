#!/usr/bin/env node
// dhx-roadmap-status-vocab.js — SessionStart hook
// Patterns: HP-009, HP-015
//
// Warns when this repo's .planning/ROADMAP.md carries a Progress-table Status
// cell outside the vocabulary its consumers recognize. Read-only, non-blocking,
// silent on the happy path. Fires once per session.
//
// Replaces a crude detector with a diagnosis. Before this, the only thing
// standing between the fleet and a silent recurrence was dhx-statusline.js's
// strict /^Complete$/i numerator: a malformed cell showed up as a milestone
// fraction low by exactly one, and tracing `2/5` back to a parenthesis took a
// dedicated investigation. See docs/decisions.md 2026-08-29 (the five cells,
// four months, three repos) and 2026-08-30 (this hook).
//
// The rule and every false-positive trap live in the module's header:
//   scripts/lib/roadmap-status-vocab.js
// Read it before changing anything here. In particular: the check is on SET
// MEMBERSHIP, never on parentheses — `Planned` and `Checkpoint` are both
// out-of-vocabulary today with no paren in sight, and a paren-hunting regex
// would encode the 2026-08-29 symptom instead of the rule.
//
// ---------------------------------------------------------------------------
// SCOPE: PER-REPO, and the fleet sweep is a CLI, not this hook
//
// Every dhx SessionStart hook is per-repo — it fires in whatever repo the
// session opened and inspects that one; nothing in dhx/ enumerates ~/repos/*
// (verified 2026-08-29: dhx-dirty-tree.sh's DHX_DIRTY_TREE_ALLOWLIST gates
// richer attribution rather than enumerating anything, and
// dhx-gsd-drift-surface.sh reads a cache the statusline writes). This hook
// keeps that shape: one read of one file, no walk, no repo list to rot.
//
// The real counter-argument — a malformed cell in a repo you rarely open is
// exactly the one that sits for four months — is answered by the CLI half of
// the module rather than by widening this hook:
//     node scripts/lib/roadmap-status-vocab.js --fleet
// Same pure function, same verdicts, run on demand. Widening a SessionStart
// hook into a fleet walk would put ~20 file reads and a per-repo git probe on
// every session start in every repo, to report on repos the session cannot act
// in — cross-repo fleet drift is its own channel, not this one.
//
// ---------------------------------------------------------------------------
// LINKED WORKTREES ARE SKIPPED
//
// A worktree's ROADMAP is transient branch state that converges on merge, and
// one logical malformed row appears in every checkout of its repo (alembic
// alone carried eight live worktrees on 2026-08-29; the fleet carried three
// duplicate copies of rows already normalized in their main trees). Flagging
// the same inherited row once per checkout is noise on a path with no action.
//
// Residual, named rather than hidden: a bad cell WRITTEN in a worktree is not
// caught until it merges and a session opens the main tree. Accepted — this is
// a warn-only detector whose failure mode is latency, and the merge lands in
// main where the next session start catches it.
//
// ---------------------------------------------------------------------------
// FAIL-OPEN
//
// Every failure path exits 0 with no output: no ROADMAP, unreadable file,
// oversize file, not a git repo, bad stdin JSON, or any throw at all. Hook
// stdout becomes Claude's context, so a broken check must cost nothing rather
// than emit a diagnostic nobody asked for.
//
// Suppression:     DHX_SKIP_ROADMAP_VOCAB=1
// Source-of-truth: ~/repos/hooks/dhx/dhx-roadmap-status-vocab.js
// Symlinked to:    ~/.claude/hooks/dhx-roadmap-status-vocab.js
// Probe:           tests/probes/probe-roadmap-status-vocab.js
//
// TEST SEAMS (default-preserving; production sets none):
//   DHX_ROADMAP_VOCAB_MAX   findings listed before the "+N more" roll-up (default 5)

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { findInvalidStatusCells, READER_RECOGNIZED } = require('../scripts/lib/roadmap-status-vocab.js');

/** Largest ROADMAP this hook will parse. Real ones are 10-40 KB; anything past
 *  this is not a ROADMAP and is not worth a session-start stall. */
const MAX_BYTES = 2 * 1024 * 1024;

/** Untrusted text from a file, rendered into Claude's context: strip control
 *  characters and bound the length. Mirrors dhx-dirty-tree.sh's
 *  `tr -cd '[:print:]' | head -c` treatment of the dhx-who payload. */
function safe(s, cap) {
  const clean = String(s).replace(/[\u0000-\u001F\u007F]/g, ' ').trim();
  return clean.length > cap ? clean.slice(0, cap - 1) + '…' : clean;
}

function gitOut(dir, args) {
  return execFileSync('git', ['-C', dir].concat(args),
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 3000 }).trim();
}

function main(input) {
  if (process.env.DHX_SKIP_ROADMAP_VOCAB === '1') return;

  let cwd = '';
  try { cwd = (JSON.parse(input).cwd || '').trim(); } catch { cwd = ''; }
  if (!cwd) cwd = process.env.CLAUDE_PROJECT_DIR || '';
  if (!cwd) return;

  // Repo root, then the linked-worktree test. A non-repo, or a git missing or
  // slow enough to throw, degrades to silence.
  let toplevel = '';
  try { toplevel = gitOut(cwd, ['rev-parse', '--show-toplevel']); } catch { return; }
  if (!toplevel) return;

  try {
    const gitDir = gitOut(toplevel, ['rev-parse', '--absolute-git-dir']);
    const commonDir = gitOut(toplevel, ['rev-parse', '--git-common-dir']);
    // In a LINKED worktree these differ (.git/worktrees/<name> vs .git); in the
    // main worktree they resolve to the same directory.
    if (path.resolve(toplevel, gitDir) !== path.resolve(toplevel, commonDir)) return;
  } catch { return; }

  const roadmap = path.join(toplevel, '.planning', 'ROADMAP.md');
  let content = '';
  try {
    if (fs.statSync(roadmap).size > MAX_BYTES) return;
    content = fs.readFileSync(roadmap, 'utf8');
  } catch { return; }

  const { findings } = findInvalidStatusCells(content);
  if (findings.length === 0) return;

  const maxRaw = parseInt(process.env.DHX_ROADMAP_VOCAB_MAX || '5', 10);
  const max = Number.isFinite(maxRaw) && maxRaw > 0 ? maxRaw : 5;

  const n = findings.length;
  const out = [];
  out.push(
    'ROADMAP Status vocabulary: ' + n + ' cell' + (n === 1 ? '' : 's') +
    ' outside the recognized set in .planning/ROADMAP.md. Both readers exact-match this ' +
    'column, so each such row counts as NOT complete — in the statusline milestone ' +
    "fraction and in gsd-core's whole-table rollup behind /gsd-next's milestone-complete gate."
  );
  for (const f of findings.slice(0, max)) {
    out.push('  line ' + (f.line + 1) + ' · `' + safe(f.status, 56) + '` · ' + safe(f.phase, 48));
  }
  if (n > max) {
    out.push('  …and ' + (n - max) + ' more (node ~/repos/hooks/scripts/lib/roadmap-status-vocab.js .)');
  }
  out.push('Recognized: ' + READER_RECOGNIZED
    .map((v) => v.replace(/^./, (c) => c.toUpperCase())).join(' · '));
  process.stdout.write(out.join('\n') + '\n');
}

let stdin = '';
process.stdin.on('data', (d) => { stdin += d; });
process.stdin.on('end', () => {
  try { main(stdin); } catch { /* fail-open: never block or speak on error */ }
  process.exit(0);
});
process.stdin.on('error', () => process.exit(0));
