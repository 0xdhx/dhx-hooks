// Probe: dhx-statemd-phase-line-lint.js warns ONLY on a genuine
//   first-paren-≠-current_phase_name mismatch at aligned phase numbers, never
//   blocks, and stays silent on every sibling-repo STATE.md shape surveyed in
//   reports/done/2026-06-25-statemd-phase-line-current-phase-name-lint.md.
// Backs docs/decisions.md 2026-06-25 STATE.md phase-line lint row.
// Run: node tests/probes/probe-statemd-phase-line-lint.js
// SAFE_FOR_LIVE: yes   (requires the hook module + writes fixtures only under an
//   mktemp dir; reads `~/.claude/gsd-core/bin/lib/*.cjs` READ-ONLY for the
//   mirror-drift assertions and SKIPS them cleanly when gsd-core is absent;
//   no live mutation)

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const HOOK = path.resolve(__dirname, '../../dhx/dhx-statemd-phase-line-lint.js');
const h = require(HOOK);

let passed = 0;
let failed = 0;
let skipped = 0;
function ok(cond, label) {
  if (cond) { passed++; console.log(`OK   ${label}`); }
  else { failed++; console.log(`FAIL ${label}`); }
}
function skip(label) { skipped++; console.log(`SKIP ${label}`); }

// ── Fixtures (synthetic, mirroring the real sibling-repo shapes surveyed) ──────
// Each: { name, fm_phase, fm_name (raw frontmatter, '' = omit key), prose, warn }
const FM = (phase, name) => {
  const lines = ['---'];
  if (phase !== null) lines.push(`current_phase: ${phase}`);
  if (name !== null) lines.push(`current_phase_name: ${name}`);
  lines.push('---', '');
  return lines.join('\n');
};
const STATE = (phase, name, prose) =>
  `${FM(phase, name)}\n## Current Position\n\n${prose}\n`;

const CASES = [
  // ---- SUPPRESSED — the load-bearing guard (body phase ≠ frontmatter phase) ----
  { name: 'SUPPRESSED cross-repo mid-transition (body 32, fm 33)',
    content: STATE(33, 'doctrine-correction',
      'Phase: XR-32 (authorization-floor) — EXECUTING (all 4 plans authored+verified; at final operator gates)'),
    warn: false },

  // ---- WARN — genuine first-paren-≠-name clobber at aligned phase numbers ----
  { name: 'WARN ttsfilter pre-fix (status in first paren, name after dash)',
    content: STATE(16, '"Native Global Hotkey + Selection Capture + Speak"',
      'Phase: 16 — Native Global Hotkey + Selection Capture + Speak (next; Phase 15 landed, UAT deferred)'),
    warn: true },
  { name: 'WARN synthetic aligned clobber (name after dash, aside in paren)',
    content: STATE(7, 'auth-foundation',
      'Phase: 7 — auth-foundation (in progress; blocked on operator gate)'),
    warn: true },
  { name: 'WARN leading-zero body phase aligns via int fallback (05 == 5)',
    content: STATE(5, 'real-name',
      'Phase: 05 — real-name (aside text)'),
    warn: true },

  // ---- PASS — safe name-in-first-paren shapes ----
  { name: 'PASS safe name-in-first-paren (relater)',
    content: STATE(13, 'speaker-aware-render-integration',
      'Phase: 13 (speaker-aware-render-integration) — AUTONOMOUS SCOPE + LIVE GPU RUNBOOK DONE, human_needed'),
    warn: false },
  { name: 'PASS markdown-bold phase number (inkling)',
    content: STATE(1, 'Submission Pipeline',
      'Phase: **1 of 4 CLOSED** (Submission Pipeline) — 11/11 plans complete; D-24 exit gate GREEN.'),
    warn: false },
  { name: 'PASS decimal/leading-zero phase id (xpression-ndi 03.1)',
    content: STATE('03.1', 'accuweather-chrome-removal',
      'Phase: 03.1 (accuweather-chrome-removal) — AWAITING OPERATOR HOST TRIP'),
    warn: false },
  { name: 'PASS name-after-dash but matching token in paren (ncaa Slice C)',
    content: STATE(54, 'Slice C',
      'Phase: 54 — Migrate `--remote` Default onto the API — BROADCAST PATH (Slice C)'),
    warn: false },
  { name: 'PASS post-fix name-in-paren with 2nd-paren aside (ttsfilter worktree)',
    content: STATE(16, '"Native Global Hotkey + Selection Capture + Speak"',
      'Phase: 16 (Native Global Hotkey + Selection Capture + Speak) — EXECUTED; code-complete; operator UAT pending'),
    warn: false },

  // ---- PASS — terminal / no-harvestable-name shapes ----
  { name: 'PASS milestone-terminal no paren (skills)',
    content: STATE(35, 'Drain + Vet Backstops', 'Phase: Milestone v1.7 complete'),
    warn: false },
  { name: 'PASS milestone-terminal paren junk but misaligned number (forgefinder)',
    content: STATE(52, null,
      'Phase: Milestone v1.8 complete (Phases 43-52 shipped, archived to `milestones/v1.8-*`)'),
    warn: false },
  { name: 'PASS reject-guard drops bare status token in paren (executing)',
    content: STATE(16, '"Native Global Hotkey + Selection Capture + Speak"',
      'Phase: 16 (executing)'),
    warn: false },

  // ---- PASS — no frontmatter to clobber ----
  { name: 'PASS no frontmatter current_phase (shortlist stock form)',
    content: '## Current Position\n\nPhase: 5 of 9 (Design Foundation)\n',
    warn: false },
  { name: 'PASS double-hyphen separator, no frontmatter (sigil)',
    content: '## Current Position\n\nPhase: 21 (Baseball/Softball Pipeline Extraction) -- second of 4 in v2.2\n',
    warn: false },

  // ---- PASS — frontmatter name absent / null ----
  { name: 'PASS frontmatter current_phase_name: null + bold no-number prose (alembic)',
    content: STATE(58, 'null', '**Phase:** none active — between milestones.'),
    warn: false },
  { name: 'PASS frontmatter name empty → nothing to clobber',
    content: STATE(9, '""', 'Phase: 9 — something real (aside)'),
    warn: false },
];

// ── 1. Pure-logic assertions (lintStateMd) ────────────────────────────────────
for (const c of CASES) {
  const r = h.lintStateMd(c.content);
  ok(r.shouldWarn === c.warn,
    `${c.name} → shouldWarn=${r.shouldWarn} (expected ${c.warn})`);
}

// Warn payload carries the harvested + curated names (operator-actionable text)
{
  const warnCase = CASES.find((c) => c.warn);
  const r = h.lintStateMd(warnCase.content);
  const adv = h.buildAdvisory(r);
  ok(adv.includes(r.harvested) && adv.includes(r.curated) && adv.includes('FIRST paren'),
    'advisory text names harvested + curated + the FIRST-paren fix');
}

// ── 2. Path matcher ───────────────────────────────────────────────────────────
ok(h.isStateMdPath('/x/y/.planning/STATE.md'), 'isStateMdPath matches absolute .planning/STATE.md');
ok(h.isStateMdPath('.planning/STATE.md'), 'isStateMdPath matches relative .planning/STATE.md');
ok(!h.isStateMdPath('/x/.planning/STATE.md.bak'), 'isStateMdPath rejects STATE.md.bak');
ok(!h.isStateMdPath('/x/milestones/v1.8/STATE.md'), 'isStateMdPath rejects archived milestone STATE.md');
ok(!h.isStateMdPath('/x/.planning/ROADMAP.md'), 'isStateMdPath rejects sibling .planning file');

// ── 3. End-to-end channel (subprocess; real stdin/stdout/exit) ────────────────
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'probe-statemd-'));
function runHook(filePath, toolName) {
  const stdin = JSON.stringify({ tool_name: toolName || 'Write', tool_input: { file_path: filePath } });
  let stdout = '';
  let status = 0;
  try {
    stdout = execFileSync('node', [HOOK], { input: stdin, encoding: 'utf8', stdio: ['pipe', 'pipe', 'ignore'] });
  } catch (e) {
    status = e.status == null ? 1 : e.status;
    stdout = e.stdout || '';
  }
  return { stdout, status };
}
function writeState(sub, content) {
  const dir = path.join(tmp, sub, '.planning');
  fs.mkdirSync(dir, { recursive: true });
  const p = path.join(dir, 'STATE.md');
  fs.writeFileSync(p, content);
  return p;
}
try {
  // 3a. WARN → exit 0 + stdout additionalContext envelope
  const warnPath = writeState('warn', CASES.find((c) => c.warn).content);
  const warnRun = runHook(warnPath);
  ok(warnRun.status === 0, 'e2e WARN exits 0 (never blocks — HP-009)');
  let env = null;
  try { env = JSON.parse(warnRun.stdout); } catch { /* leave null */ }
  ok(env && env.hookSpecificOutput && env.hookSpecificOutput.hookEventName === 'PostToolUse',
    'e2e WARN stdout is the PostToolUse hookSpecificOutput envelope (HP-039)');
  ok(env && /statemd-phase-line/.test(env.hookSpecificOutput.additionalContext || ''),
    'e2e WARN additionalContext carries the ⚠ statemd-phase-line advisory');

  // 3b. SUPPRESSED → exit 0 + empty stdout (silent)
  const supPath = writeState('suppress', CASES.find((c) => /SUPPRESSED/.test(c.name)).content);
  const supRun = runHook(supPath);
  ok(supRun.status === 0 && supRun.stdout.trim() === '', 'e2e SUPPRESSED is silent (exit 0, no stdout)');

  // 3c. Edit tool on a warn fixture also fires (post-edit disk read; HP-039 inherits)
  const editRun = runHook(warnPath, 'Edit');
  ok(editRun.status === 0 && /statemd-phase-line/.test(editRun.stdout), 'e2e Edit tool fires on STATE.md');

  // 3d. Non-STATE.md path → silent
  const otherDir = path.join(tmp, 'other', '.planning');
  fs.mkdirSync(otherDir, { recursive: true });
  const otherPath = path.join(otherDir, 'ROADMAP.md');
  fs.writeFileSync(otherPath, CASES.find((c) => c.warn).content);
  const otherRun = runHook(otherPath);
  ok(otherRun.status === 0 && otherRun.stdout.trim() === '', 'e2e non-STATE.md path is silent');

  // 3e. Non-Write/Edit tool → silent
  const readRun = runHook(warnPath, 'Read');
  ok(readRun.status === 0 && readRun.stdout.trim() === '', 'e2e non-Write/Edit tool is silent');

  // 3f. Bad JSON on stdin → silent exit 0
  let badStatus = 0;
  let badOut = '';
  try { badOut = execFileSync('node', [HOOK], { input: 'not json', encoding: 'utf8', stdio: ['pipe', 'pipe', 'ignore'] }); }
  catch (e) { badStatus = e.status == null ? 1 : e.status; badOut = e.stdout || ''; }
  ok(badStatus === 0 && badOut.trim() === '', 'e2e malformed stdin → silent exit 0');
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}

// ── 4. Mirror-drift detector against live gsd-core (SKIP when absent) ──────────
// The three parseProsePhaseField regexes + reject-guard are COPIED from gsd-core
// (state.cjs:1126). If a gsd-core bump rewrites them, the lint silently disagrees
// with the reader it protects — these assertions go red and force a re-verify.
// (parseProsePhaseField is the report's load-bearing mirror; stateExtractField is
// also mirrored verbatim but the drift detector focuses on the parser.)
const GSD_STATE = path.join(os.homedir(), '.claude/gsd-core/bin/lib/state.cjs');
const STATE_LITERALS = [
  String.raw`/\b(\d+[A-Z]?(?:\.\d+)*)\b/i`,
  String.raw`/\(([^)]+)\)/`,
  '/—\\s*([^(\\n]+?)(?:\\s*\\(|$)/',
  String.raw`/^(?:complete|executing|not started)$/i`,
];
if (fs.existsSync(GSD_STATE)) {
  const src = fs.readFileSync(GSD_STATE, 'utf8');
  for (const lit of STATE_LITERALS) {
    ok(src.includes(lit), `gsd-core state.cjs still contains mirrored literal ${lit}`);
  }
} else {
  skip('gsd-core state.cjs absent — parseProsePhaseField drift check skipped');
}

// ── Summary ───────────────────────────────────────────────────────────────────
console.log(`\n${passed} passed, ${failed} failed${skipped ? `, ${skipped} skipped` : ''}`);
process.exit(failed > 0 ? 1 : 0);
