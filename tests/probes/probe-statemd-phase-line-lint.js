// Probe: dhx-statemd-phase-line-lint.js warns ONLY when gsd-core's parser would
//   harvest a name that differs from current_phase_name at aligned phase numbers,
//   never blocks, and stays silent on every sibling-repo STATE.md shape surveyed
//   in reports/done/2026-06-25-statemd-phase-line-current-phase-name-lint.md.
//   NOT "first-paren-≠-name" any more: gsd-core 1.9.1 (#2736) inverted the
//   parser's precedence to status-keyword-aware dash-over-paren, which fixed the
//   original hazard and created its mirror image. Fixture expectations were
//   re-derived from the live parser 2026-07-31 — 11 of 17 corpus phase-lines
//   changed meaning across that bump. Do not reason from the old threat model.
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

  // ---- PASS — shapes gsd-core #2736 FIXED (these were the original WARN set) ----
  // Re-derived 2026-07-31 against 1.9.1. `N — Name (status aside)` was THE hazard
  // this lint was built for: the pre-#2736 parser took the parenthetical, so the
  // status clobbered the curated name. The 1.9.1 parser prefers the em-dash name
  // unless it reads as a status annotation, so it now harvests the NAME and there
  // is nothing to warn about. Kept (not deleted) as the regression witness: if a
  // future bump reverts the precedence, these three go red first.
  { name: 'PASS #2736-fixed: name after dash, status aside in paren (ttsfilter)',
    content: STATE(16, '"Native Global Hotkey + Selection Capture + Speak"',
      'Phase: 16 — Native Global Hotkey + Selection Capture + Speak (next; Phase 15 landed, UAT deferred)'),
    warn: false },
  { name: 'PASS #2736-fixed: name after dash, parenthesised progress note',
    content: STATE(7, 'auth-foundation',
      'Phase: 7 — auth-foundation (in progress; blocked on operator gate)'),
    warn: false },

  // ---- WARN — the hazard that SURVIVES 1.9.1 ----
  // The mirror image of the fixed shape: `N (Real Name) — <multi-word status tail>`.
  // The tail escapes STATUSY_TAIL_RE (multi-word) and the lone-ALL-CAPS rule
  // (more than one token), so the dash branch wins and harvests the STATUS as the
  // name — clobbering the curated one. This is now the lint's whole reason to exist.
  { name: 'WARN leading-zero body phase aligns via int fallback (05 == 5)',
    // Prose re-shaped, expectation NOT merely flipped: this case exists to cover
    // the 05==5 leading-zero alignment path, and that coverage is only reached
    // when the lint gets past Gate 1 AND actually warns. Under 1.9.1 the old
    // `05 — real-name (aside text)` prose stops warning, which would have retired
    // the alignment coverage silently. Same phase tokens, hazardous shape.
    content: STATE(5, 'real-name',
      'Phase: 05 (real-name) — AWAITING OPERATOR HOST TRIP'),
    warn: true },

  // ---- WARN (cont.) — formerly "safe name-in-first-paren", now the hazard ----
  // Every case below was expected PASS before 1.9.1 on the reasoning that a name
  // in the FIRST paren always won. #2736 inverted that. Each now harvests its
  // dash tail; the curated name would be clobbered on the next rebuild.
  { name: 'WARN paren name loses to multi-word ALL-CAPS tail (relater)',
    content: STATE(13, 'speaker-aware-render-integration',
      'Phase: 13 (speaker-aware-render-integration) — AUTONOMOUS SCOPE + LIVE GPU RUNBOOK DONE, human_needed'),
    warn: true },
  { name: 'PASS markdown-bold phase number (inkling)',
    content: STATE(1, 'Submission Pipeline',
      'Phase: **1 of 4 CLOSED** (Submission Pipeline) — 11/11 plans complete; D-24 exit gate GREEN.'),
    warn: false },
  { name: 'WARN decimal phase id, paren name loses to caps tail (xpression-ndi 03.1)',
    content: STATE('03.1', 'accuweather-chrome-removal',
      'Phase: 03.1 (accuweather-chrome-removal) — AWAITING OPERATOR HOST TRIP'),
    warn: true },
  { name: 'WARN dash name wins over the curated paren token (ncaa Slice C)',
    content: STATE(54, 'Slice C',
      'Phase: 54 — Migrate `--remote` Default onto the API — BROADCAST PATH (Slice C)'),
    warn: true },
  { name: 'WARN the OLD advisory\'s own recommended shape now clobbers (ttsfilter worktree)',
    content: STATE(16, '"Native Global Hotkey + Selection Capture + Speak"',
      'Phase: 16 (Native Global Hotkey + Selection Capture + Speak) — EXECUTED; code-complete; operator UAT pending'),
    warn: true },

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

  // ---- Anchored-parser cases (gsd-core 1.7.0 #2111/#2125 — added 2026-07-16) ----
  // Old unanchored regex mined a stray numeral from these ("v1.8" → "8",
  // "**1 …" → "1") which could coincidentally align with the frontmatter and
  // false-warn; the anchored parser yields phase:null → Gate 1 suppresses,
  // matching gsd-core's own #905 preserve-guard.
  { name: 'PASS anchored: milestone line w/ paren aside, fm coincidentally "aligned" (old parser would false-warn)',
    content: STATE(8, 'curated-name',
      'Phase: Milestone v1.8 complete (junk aside)'),
    warn: false },
  { name: 'PASS anchored: bold-marker phase line w/ mismatched paren (old parser would false-warn)',
    content: STATE(1, 'Submission Pipeline',
      'Phase: **1 of 4 CLOSED** (Some Aside) — wrap-up notes.'),
    warn: false },
  { name: 'WARN anchored: project-code prefix still parses at aligned phase (positive control)',
    content: STATE(32, 'curated-name',
      'Phase: XR-32 — real-name (aside text)'),
    warn: true },

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

  // Round-trip EVERY warn case, not just the first. Sampling one is how a wrong
  // advisory survives: the retired first-paren advice still round-trips against a
  // lone ALL-CAPS status tail (`— EXECUTING`, where the ALL-CAPS rule hands the
  // name back to the parenthetical) and only breaks on MULTI-WORD tails. Checking
  // a single case therefore certifies advice that is wrong for most real STATE.md
  // lines. Measured 2026-07-31 while building this assertion.
  for (const c of CASES.filter((x) => x.warn)) {
    const rc = h.lintStateMd(c.content);
    const advc = h.buildAdvisory(rc);
    const line = advc.split('\n').find((l) => l.includes('Fix:') && l.includes('Phase:'));
    if (!line) {
      ok(advc.includes('cannot survive any prose shape'),
        `${c.name} → advisory offers a shape or explains why none exists`);
      continue;
    }
    // Substitute BOTH a lone ALL-CAPS status and a realistic multi-word tail.
    // Testing only `EXECUTING` certifies the retired first-paren advice as sound:
    // a lone ALL-CAPS token trips the parser's lone-caps rule and hands the name
    // back to the parenthetical, so the bad advice round-trips. It is exactly the
    // multi-word tails that real STATE.md lines carry which break it, so a
    // single friendly placeholder is a false-green generator, not a test.
    for (const status of ['EXECUTING', 'EXECUTED; code-complete; operator UAT pending']) {
      const fixed = c.content.replace(/^Phase:.*$/m,
        line.slice(line.indexOf('Phase:')).replace('<status>', status));
      ok(h.lintStateMd(fixed).shouldWarn === false,
        `${c.name} → advised shape stops the warning [status: ${status.slice(0, 18)}]`);
    }
  }
  ok(adv.includes(r.harvested) && adv.includes(r.curated),
    'advisory text names both the harvested and the curated name');
  // The advisory must not merely be well-formed — the shape it RECOMMENDS has to
  // survive the live parser. The pre-1.9.1 advisory hard-coded "put the name in
  // the FIRST paren", which #2736 turned into the hazard itself: it kept passing
  // a substring assertion while telling operators to do the one thing that
  // clobbers their name. Assert the OUTCOME instead of the wording — extract the
  // suggested Phase line and run it back through the lint.
  // Match on `Fix:` + `Phase:` independently, NOT the literal `Fix: Phase:`.
  // Pinning the joined form makes a reworded advisory (e.g. the retired
  // "Fix: put the name in the FIRST paren — Phase: …") fall out of the finder
  // and silently skip the round-trip below, downgrading a behavioural failure
  // to a presence failure. Loose match keeps the round-trip armed.
  const suggested = adv.split('\n').find((l) => l.includes('Fix:') && l.includes('Phase:'));
  ok(!!suggested, 'advisory carries a concrete suggested Phase line');
  if (suggested) {
    const line = suggested.slice(suggested.indexOf('Phase:')).replace('<status>', 'EXECUTING');
    const fixedState = warnCase.content.replace(/^Phase:.*$/m, line);
    ok(h.lintStateMd(fixedState).shouldWarn === false,
      'the shape the advisory recommends actually stops the warning (round-trip)');
  }
  ok(!adv.includes('FIRST paren'),
    'advisory no longer recommends the retired first-paren shape (now the hazard)');
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
// Every mirrored literal is pinned against the gsd-core module that OWNS it
// (gsd-core 1.7.0 homes). Widened 2026-07-16 after the #2125 rewrite moved the
// parser regexes to phase-id.cjs and the #2143 dedup moved stripFrontmatter to
// frontmatter.cjs — the old parser-only, state.cjs-only pins missed the
// stripFrontmatter move entirely. If a gsd-core bump changes OR moves any of
// these, the assertion goes red and forces a re-verify of the lint's mirrors.
// NOTE: pin strings for template-literal sources use single quotes so `${…}`
// stays a literal byte sequence (no interpolation outside backticks).
const GSD_LIB = path.join(os.homedir(), '.claude/gsd-core/bin/lib');
const MIRROR_PINS = [
  // parsePhaseFromProse — the load-bearing parser mirror (anchored token,
  // length-capped names, status reject-guard)
  ['phase-id.cjs', String.raw`/^\s*(?:Phase\s+)?(?:[A-Z][A-Z0-9_]*-)?(\d+[A-Z]?(?:\.\d+)*)\b/i`],
  ['phase-id.cjs', String.raw`/\(([^)]{1,200})\)/`],
  // #2736 re-harvest (1.9.1): the dash branch now searches a paren-STRIPPED
  // copy and is gated by a status-keyword vocabulary. Pin the three literals
  // that carry that precedence — the old single dash regex is gone upstream.
  ['phase-id.cjs', String.raw`/—\s*([^(\n]{1,200}?)\s*$/`],
  ['phase-id.cjs', String.raw`str.replace(/\([^)\n]{0,200}\)/g, ' ')`],
  ['phase-id.cjs', 'const STATUSY_TAIL_RE ='],
  ['phase-id.cjs', String.raw`/^(?:complete|executing|not started)$/i`],
  // state.cjs parseProsePhaseField must still DELEGATE to the canonical parser —
  // a re-inlined divergent regex would keep the phase-id pins green while the
  // actual STATE.md reader drifts.
  ['state.cjs', 'return parsePhaseFromProse(value);'],
  // stateExtractField precedence chain (bold → plain → pipe-table)
  ['state-document.cjs', '\\\\*\\\\*${escaped}:\\\\*\\\\*[ \\\\t]*(.+)'],
  ['state-document.cjs', '^${escaped}:[ \\\\t]*(.+)'],
  // The pipe-table leg is NO LONGER a regex upstream: stateExtractField now
  // delegates to locateFieldRow(), a character scanner that is not exported.
  // So there is no literal left to mirror. The hook keeps its own table
  // implementation DELIBERATELY (vendoring the closure would pull three
  // helpers across two modules); what is pinned instead is that upstream
  // still routes through that delegation, so a future re-inlining is seen.
  // Behavioral parity for this leg is asserted by the table fixtures below,
  // not by text matching -- see docs/decisions.md 2026-07-31.
  ['state-document.cjs', 'const hit = locateFieldRow(content, fieldName);'],
  // stripFrontmatter (frontmatter.cjs since #2143) + scalar quote-strip
  ['frontmatter.cjs', String.raw`/^\s*---\r?\n[\s\S]*?\r?\n---\s*/`],
  ['frontmatter.cjs', String.raw`/^["']|["']$/g`],
];
if (fs.existsSync(GSD_LIB)) {
  const srcCache = new Map();
  for (const [mod, lit] of MIRROR_PINS) {
    const p = path.join(GSD_LIB, mod);
    if (!srcCache.has(p))
      srcCache.set(p, fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : null);
    const src = srcCache.get(p);
    ok(src !== null && src.includes(lit),
      `gsd-core ${mod} still contains mirrored literal ${lit}`);
  }
} else {
  skip('gsd-core lib dir absent — mirror drift check skipped');
}

// ── Summary ───────────────────────────────────────────────────────────────────
console.log(`\n${passed} passed, ${failed} failed${skipped ? `, ${skipped} skipped` : ''}`);
process.exit(failed > 0 ? 1 : 0);
