// Probe: dhx-statemd-phase-line-lint.js warns ONLY when gsd-core's parser would
//   harvest a name that differs from current_phase_name at aligned phase numbers,
//   never blocks, and stays silent on every sibling-repo STATE.md shape surveyed
//   in private report 2026-06-25-statemd-phase-line-current-phase-name-lint.
//   NOT "first-paren-≠-name" any more: gsd-core 1.9.1 (#2736) inverted the
//   parser's precedence to status-keyword-aware dash-over-paren, which fixed the
//   original hazard and created its mirror image. Fixture expectations were
//   re-derived from the live parser 2026-07-31 — 11 of 17 corpus phase-lines
//   changed meaning across that bump. Do not reason from the old threat model.
//
//   Section 4 is a BEHAVIOURAL DIFFERENTIAL, not a set of text pins (replaced
//   2026-07-31). It runs the hook's four mirrored functions and gsd-core's live
//   originals over shared corpora and reds only on behavioural divergence — so
//   a cosmetic upstream reformat no longer blocks every commit in the repo, and
//   a semantic change inside unchanged literals no longer passes silently. One
//   structural pin survives, for the one leg no export reaches. Read section 4's
//   own header before changing it: the gsd-core-absent SKIP and the corpus-size
//   floors are deliberate, and each has a failure mode behind it.
//
//   Section 1b + 4f + 4g were added 2026-08-08 for gsd-core 1.10.0 (#2956). That
//   bump changed NO mirrored function body — it changed the CONTENT handed to
//   stateExtractField for `Phase` (the `## Current Position` section, not the
//   whole body). Every per-function differential stayed green (61/61) while the
//   lint silently disagreed with the harvest it warns about. The lesson is that a
//   body-only oracle cannot see a composition change: 4f mirrors the new scoper
//   behaviourally, 4g pins the call sites that apply it, and 1b carries the
//   first fixtures in this file with TWO `Phase:` lines — a scoping bug is
//   invisible to any fixture that only ever carries one.
//
//   Section 4g is RETIRED (2026-08-19) and replaced by 4h, which RUNS gsd-core's
//   exported write path instead of text-scanning its source. 4g's premise — that
//   both seams are unexported, so text is the only instrument — was simply false:
//   `syncStateFrontmatter` is exported and reaches buildStateFrontmatter. A text
//   pin on a BUILD ARTIFACT reds on any emit change and blocks every commit in
//   the repo, and it can also false-GREEN (its regexes were not function-scoped).
//   Read 4h's own header before touching it; the read-seam assertion was dropped
//   deliberately, not lost.
//
//   Section 1c was added 2026-08-19 for the two-rung write ladder. The hook had
//   mirrored only the PROSE rung since the day it shipped, while upstream reads a
//   whole-body `Current Phase` / `Current Phase Name` FIELD first — leaving the
//   lint wrong in both directions, the phase rung's failure being the BLIND one.
//   The suite was fully green across that entire span because no fixture carried
//   either field. Third instance of one pattern: a rung, a scope, or a caller that
//   no fixture exercises is one no assertion protects. See docs/decisions.md
//   2026-08-19.
//   2026-07-31 differential-oracle row.
// Run: node tests/probes/probe-statemd-phase-line-lint.js
// SAFE_FOR_LIVE: yes   (requires the hook module + writes fixtures only under an
// LIVE_RUNTIME: yes  (section 4h differentials the hook mirror against the LIVE gsd-core write seam; an install can flip it with the repo unchanged)
// LIVE_SUBJECT: dhx/dhx-statemd-phase-line-lint.js
//   mktemp dir; require()s `~/.claude/gsd-core/bin/lib/{phase-id,state-document,
//   frontmatter,markdown-sectionizer,state}.cjs` to differential-test the mirrors, and SKIPS
//   that section cleanly when gsd-core is absent. Those imports are side-effect-free —
//   re-verified 2026-08-19 after state.cjs joined the set for §4h: requiring all
//   five AND calling `syncStateFrontmatter(doc, undefined)` over three documents
//   under a scratch cwd and a fake $HOME created zero files. The undefined `cwd`
//   is load-bearing — it is what keeps the write seam off every disk path. Note
//   state.cjs has a WIDER footprint than the other four: it resolves
//   `bin/shared/config-defaults.manifest.json` at module load, so a gsd-core tree
//   carrying `bin/lib` alone throws on require. That lands on the deliberate
//   present-but-broken FAIL branch, not the absent-gsd-core SKIP. No live mutation.)

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
  { name: 'PASS milestone-terminal paren junk but misaligned number (acme-app)',
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

// ── 1b. Section scoping — ## Current Position (#2956, gsd-core 1.10.0) ────────
// 1.10.0 stopped harvesting `Phase:` from the whole body and scoped it to the
// `## Current Position` section, at the write seam (buildStateFrontmatter) and
// the read seam (inline in cmdStateSnapshot then, resolveStatePhase since 1.11.0).
// Resolve both by SYMBOL — state.cjs is a build artifact and line cites go stale.
// Until the hook followed, a historical `Phase:` line in an archive section was
// harvested instead of the live one, failing in TWO directions — both reproduced
// live on 1.10.0 before the fix, both fixtured here:
//   FALSE WARN — archive phase == current_phase but an older name: the lint
//                reported a clobber that could not happen.
//   BLIND      — archive phase != current_phase: Gate 1's alignment check
//                suppressed, so a GENUINE clobber on the Current Position line
//                was never examined. Silent, and indistinguishable from a pass.
//
// Every fixture in CASES above is built by STATE(), which already nests its prose
// under `## Current Position` — which is precisely why the whole suite stayed
// green through the break. These are the first fixtures in this file carrying TWO
// `Phase:` lines. Keep that property: a scoping bug cannot be seen by a fixture
// that only ever carries one.
const ARCHIVE = (proseLine) => `## Session Continuity Archive\n\n${proseLine}\n\n`;
const TWO_PHASE = (fmPhase, fmName, archiveLine, currentLine) =>
  `${FM(fmPhase, fmName)}\n${ARCHIVE(archiveLine)}## Current Position\n\n${currentLine}\n`;

const SCOPE_CASES = [
  { name: 'archive line at the SAME phase with a stale name → no false warn',
    content: TWO_PHASE(7, 'Loupe Detachable',
      'Phase: 7 (Stale Renamed Thing) — COMPLETE',
      'Phase: 7 (Loupe Detachable) — EXECUTING'),
    warn: false },
  { name: 'archive line at a DIFFERENT phase must not blind a genuine clobber',
    content: TWO_PHASE(7, 'Loupe Detachable',
      'Phase: 3 (Ghost Key Feel) — COMPLETE',
      'Phase: 7 (Wrong Name) — EXECUTING'),
    warn: true },
  { name: 'archive line at a DIFFERENT phase, Current Position agrees → silent',
    content: TWO_PHASE(7, 'Loupe Detachable',
      'Phase: 3 (Ghost Key Feel) — COMPLETE',
      'Phase: 7 (Loupe Detachable) — EXECUTING'),
    warn: false },
  // Level-flexible: canonical template is h2, bootstrap template h3 (state.cjs:1189).
  { name: 'h3 ### Current Position is scoped too (bootstrap template)',
    content: `${FM(7, 'Loupe Detachable')}\n${ARCHIVE('Phase: 7 (Stale) — COMPLETE')}### Current Position\n\nPhase: 7 (Loupe Detachable) — EXECUTING\n`,
    warn: false },
  // The fallback leg: no such section → whole body, i.e. pre-1.10.0 behaviour.
  { name: 'no Current Position section → full-body fallback still warns',
    content: `${FM(7, 'Loupe Detachable')}\nPhase: 7 (Wrong Name) — EXECUTING\n`,
    warn: true },
  // Why the verbatim fence-aware tokenizer is load-bearing rather than ceremony:
  // a regex heading scan would match the FENCED heading first and harvest
  // "Doc Example", producing a false warn on a STATE.md that merely documents a
  // template. This fixture reds under any non-fence-aware slicer.
  { name: 'a ## Current Position inside a fenced block is not a real heading',
    content: `${FM(7, 'Loupe Detachable')}\n## Notes\n\n\`\`\`markdown\n## Current Position\n\nPhase: 7 (Doc Example) — EXECUTING\n\`\`\`\n\n## Current Position\n\nPhase: 7 (Loupe Detachable) — EXECUTING\n`,
    warn: false },
];

for (const c of SCOPE_CASES) {
  ok(h.lintStateMd(c.content).shouldWarn === c.warn,
    `[scope] ${c.name}`);
}

// The scoper's own contract, asserted directly rather than only through the lint.
ok(h.matchCurrentPositionSection('## Other\n\nbody\n') === null,
  '[scope] matchCurrentPositionSection returns null when the section is absent');
ok((h.matchCurrentPositionSection('## Current Position\n\nPhase: 7 (X) — GO\n') || '')
     .includes('Phase: 7 (X) — GO'),
  '[scope] matchCurrentPositionSection returns the section body when present');
ok(!(h.matchCurrentPositionSection(
       '## Current Position\n\nPhase: 7 (X) — GO\n\n## Later\n\nPhase: 9 (Y) — NO\n') || '')
     .includes('Phase: 9'),
  '[scope] section body is level-bounded — stops at the next h2');

// ── 1c. The two-rung write ladder — whole-body FIELDS (2026-08-19) ───────────
// buildStateFrontmatter resolves BOTH values through a two-rung ladder:
//     currentPhase     = stateExtractField(bodyContent, 'Current Phase')      ?? prosePhase.phase
//     currentPhaseName = stateExtractField(bodyContent, 'Current Phase Name') ?? prosePhase.name
// The first rung reads the WHOLE body; only the prose `Phase:` line is scoped to
// `## Current Position`. The hook mirrored the prose rung ONLY, from the day it
// shipped (2026-06-25) until 2026-08-19 — and the whole suite stayed green the
// entire time, because NO fixture above carries either field. Same structural
// blindness as §1b: a rung no fixture exercises is a rung no assertion protects.
//
// Both failure directions are reproduced live against gsd-core 1.11.0 (see
// docs/decisions.md 2026-08-19); the BLIND one is the reason this section exists.
// Keep the property that every fixture here carries a `Current Phase` or a
// `Current Phase Name` field — that is what makes the section load-bearing.
const FIELD_CASES = [
  // THE FALSE NEGATIVE. Upstream takes the FIELD for phase (7 — aligned) and the
  // PROSE for name ("Wrong"), so it clobbers. The pre-fix lint compared
  // frontmatter 7 against the PROSE phase 9, read a forward transition, and went
  // silent — a genuine clobber, invisible. RED against the pre-fix hook.
  { name: 'BLIND: Current Phase field aligns while the prose phase does not',
    content: `${FM(7, 'Curated')}\n## Session Continuity Archive\n\nPhase: 9 (Wrong) — NO\n\n`
      + '## Current Position\n\nCurrent Phase: 7\nPhase: 9 (Wrong) — DEFERRED PENDING REVIEW\n',
    warn: true },
  // THE FALSE WARN. Upstream takes the Current Phase Name FIELD, which already
  // equals the curated value, so nothing is clobbered. The pre-fix lint read the
  // prose dash-tail and warned. RED against the pre-fix hook.
  { name: 'Current Phase Name field already matches curated → nothing to clobber',
    content: `${FM(7, 'Curated')}\n## Current Position\n\n`
      + 'Current Phase Name: Curated\nPhase: 7 (Different) — AWAITING OPERATOR HOST TRIP\n',
    warn: false },
  // The field rung is WHOLE-BODY, not section-scoped: a field OUTSIDE
  // ## Current Position still wins. Scoping the field rung to the section (the
  // obvious wrong fix) turns this green-by-accident, so it is the control that
  // pins the ladder's scope ASYMMETRY rather than merely its existence.
  { name: 'Current Phase Name field OUTSIDE the section still wins (whole-body rung)',
    content: `${FM(3, 'Curated')}\n## Meta\n\nCurrent Phase Name: FromField\n\n`
      + '## Current Position\n\nPhase: 3 (Prose) — AWAITING OPERATOR HOST TRIP\n',
    warn: true },
  // Control — the field rung must not resurrect the forward-transition warn that
  // Gate 1 deliberately suppresses. Field phase 32 vs frontmatter 33: still silent.
  { name: 'Current Phase field at a DIFFERENT phase stays a forward transition',
    content: `${FM(33, 'doctrine-correction')}\n## Current Position\n\n`
      + 'Current Phase: 32\nPhase: 32 (authorization-floor) — AWAITING OPERATOR HOST TRIP\n',
    warn: false },
  // Control — absent fields must leave the prose rung's behaviour untouched.
  // This is the regression guard on §1/§1b: if mirroring the ladder had changed
  // the no-field path, this fixture would flip.
  { name: 'no fields present → prose rung unchanged (regression guard)',
    content: STATE(13, 'speaker-aware-render-integration',
      'Phase: 13 (speaker-aware-render-integration) — AUTONOMOUS SCOPE + LIVE GPU RUNBOOK DONE, human_needed'),
    warn: true },
];

for (const c of FIELD_CASES) {
  ok(h.lintStateMd(c.content).shouldWarn === c.warn,
    `[field-rung] ${c.name}`);
}

// The harvested value itself, not just the warn/suppress verdict — a lint that
// warns for the right reason but reports the wrong name emits a useless advisory.
ok(h.lintStateMd(FIELD_CASES[0].content).harvested === 'DEFERRED PENDING REVIEW',
  '[field-rung] BLIND case reports the name upstream would actually write');
ok(h.lintStateMd(FIELD_CASES[2].content).harvested === 'FromField',
  '[field-rung] whole-body field rung reports the FIELD value, not the prose tail');

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

// ── 4. Behavioural mirror-drift differential against live gsd-core ────────────
// Replaced the text-literal MIRROR_PINS array 2026-07-31 (see docs/decisions.md).
//
// A pin fires on TEXTUAL upstream change, which is wrong in both directions: too
// loud (a cosmetic reformat or a renamed local inside an unchanged regex reds the
// gate and blocks every commit in the repo for no behavioural reason) and too
// quiet (a semantic change that leaves the pinned literals intact passes
// silently). What this hook actually owes gsd-core is BEHAVIOURAL parity on the
// surfaces it mirrors, so assert that directly: run both implementations over a
// corpus and compare results.
//
// Design decisions — deliberate, do not "fix" by reflex:
//
//  * gsd-core ABSENT → SKIP, not FAIL. The hook is a standalone runtime mirror
//    with zero require() of gsd-core, so on a machine without gsd-core there is
//    nothing to diverge FROM and the lint still works. A hard FAIL would be
//    correct only under the REJECTED require()-at-runtime design, where an
//    absent gsd-core means a silently dead lint.
//  * gsd-core PRESENT but a module or export is missing → FAIL, not SKIP. That
//    is real drift (a rename or a reorg), and a SKIP would swallow exactly the
//    signal this section exists to raise.
//  * A green differential proves the hook AGREES with gsd-core. It does NOT
//    prove the lint is CORRECT. Whether the fixtures and the advisory still
//    encode a live threat model is a separate question — and it is the one that
//    actually went wrong at the 1.9.1 bump, where the pins went red, the
//    re-copy made them green, and the entire warn set had silently inverted
//    underneath. Sections 1-3 carry that half; this section cannot.
//
// One structural pin SURVIVES (below): state.cjs's delegation to the canonical
// parser. state.cjs does not export its own parseProsePhaseField wrapper, so no
// differential can reach it — a divergent re-inlining there would keep every
// behavioural check green while the actual STATE.md reader drifts.
const GSD_LIB = path.join(os.homedir(), '.claude/gsd-core/bin/lib');

// Compare hook vs upstream across a corpus; report every divergence, assert zero.
// `pick` returns [hookResult, upstreamResult] for one corpus entry.
function differential(label, corpus, minSize, pick) {
  ok(corpus.length >= minSize,
    `${label} corpus is non-vacuous (${corpus.length} >= ${minSize})`);
  let diverged = 0;
  for (const entry of corpus) {
    let a, b;
    try { [a, b] = pick(entry); }
    catch (e) { diverged++; console.log(`  THREW [${label}] ${entry.label}: ${e.message}`); continue; }
    if (JSON.stringify(a) !== JSON.stringify(b)) {
      diverged++;
      console.log(`  DIVERGE [${label}] ${entry.label}`);
      console.log(`     hook = ${JSON.stringify(a)}`);
      console.log(`     ups  = ${JSON.stringify(b)}`);
    }
  }
  ok(diverged === 0,
    `${label}: hook mirror agrees with live gsd-core (${diverged} diverge of ${corpus.length})`);
}

if (!fs.existsSync(GSD_LIB)) {
  skip('gsd-core lib dir absent — behavioural mirror differential skipped');
} else {
  // SMOD (state.cjs) joined this list 2026-08-19 for §4h, which RUNS the exported
  // write path instead of text-scanning it. `syncStateFrontmatter(content, cwd)`
  // is content->content and takes no I/O path when cwd is undefined, which is how
  // §4h calls it — see the SAFE_FOR_LIVE note in this file's header.
  let PI = null, SD = null, FMOD = null, MS = null, SMOD = null, loadErr = null;
  try {
    PI = require(path.join(GSD_LIB, 'phase-id.cjs'));
    SD = require(path.join(GSD_LIB, 'state-document.cjs'));
    FMOD = require(path.join(GSD_LIB, 'frontmatter.cjs'));
    MS = require(path.join(GSD_LIB, 'markdown-sectionizer.cjs'));
    SMOD = require(path.join(GSD_LIB, 'state.cjs'));
  } catch (e) { loadErr = e.message; }
  const exportsPresent = !loadErr
    && typeof (PI || {}).parsePhaseFromProse === 'function'
    && typeof (SD || {}).stateExtractField === 'function'
    && typeof (FMOD || {}).stripFrontmatter === 'function'
    && typeof (FMOD || {}).parseFrontmatter === 'function'
    && typeof (MS || {}).collectSection === 'function'
    && typeof (MS || {}).tokenizeHeadings === 'function'
    // The §4h oracle's whole premise: this seam IS reachable. If a future bump
    // un-exports it, FAIL here rather than silently losing the differential.
    && typeof (SMOD || {}).syncStateFrontmatter === 'function';
  ok(exportsPresent,
    `gsd-core is present and still exports every mirrored surface${loadErr ? ` (load error: ${loadErr})` : ''}`);

  if (exportsPresent) {
    // ── 4a. parsePhaseFromProse — the load-bearing parser mirror ──────────────
    // The corpus is HARVESTED OUT OF THIS FILE'S OWN FIXTURE LIST rather than
    // written as a separate named list. That is deliberate: it guarantees the
    // differential and the behavioural fixtures can never fall out of sync, and
    // adding a fixture automatically extends the differential. Keep that
    // property. (Explicit would be clearer to read; harvested cannot silently
    // under-sample. The under-sampling risk is the one that bites.)
    //
    // Compare the FULL parse result, not just `.name`: the retired pins covered
    // the anchored phase-token regex too, so a name-only comparison would drop
    // coverage the pins had.
    const selfSrc = fs.readFileSync(__filename, 'utf8');
    const PHASE_LINE_RE = /'((?:\*\*)?Phase:\*{0,2} ?[^'\n]*)'/g;
    const phaseLines = [...new Set([...selfSrc.matchAll(PHASE_LINE_RE)].map((m) => m[1]))]
      // Drop source strings carrying escape sequences (`\n`, `\r`, `\t`): those
      // are multi-line document fixtures from 4b-4d, not phase-line values, and
      // harvesting them would feed both parsers a literal backslash-n tail.
      .filter((v) => typeof v === 'string' && !/\\[nrt]/.test(v))
      .map((raw) => ({ label: raw, value: raw.replace(/^\*{0,2}Phase:\*{0,2}\s*/, '') }));
    // Floor of 15, not 1. The first version of this harvest used a wrong regex,
    // matched nothing, and reported "0 diverge of 0" — indistinguishable from
    // success. 18 lines at authoring; treat anything under 15 as a BROKEN
    // HARVEST, not a shrunken corpus.
    differential('parsePhaseFromProse', phaseLines, 15,
      (e) => [h.parseProsePhaseField(e.value), PI.parsePhaseFromProse(e.value)]);

    // ── 4b. stateExtractField — bold → plain → pipe-table precedence chain ────
    // Covers what three retired pins covered, including the leg that had no
    // literal left to pin: upstream's pipe-table branch is now a delegation to
    // locateFieldRow(), an unexported character scanner. Text-matching could
    // only assert the delegation still existed; this asserts the hook's own
    // table implementation still AGREES with it.
    const FIELD_DOCS = [
      { label: 'bold', doc: '**Phase:** 3 (alpha) — EXECUTING\n', field: 'Phase' },
      { label: 'plain', doc: 'Phase: 4 (beta) — DONE\n', field: 'Phase' },
      { label: 'pipe table', doc: '| Field | Value |\n|---|---|\n| Phase | 7 (tabled) |\n', field: 'Phase' },
      { label: 'precedence bold over plain', doc: 'Phase: plainval\n**Phase:** boldval\n', field: 'Phase' },
      { label: 'precedence plain over table', doc: '| Phase | tableval |\nPhase: plainval\n', field: 'Phase' },
      { label: 'field absent', doc: 'Nothing here\n', field: 'Phase' },
      { label: 'regex-special field name', doc: '**Phase (v1.8):** 9\n', field: 'Phase (v1.8)' },
      { label: 'CRLF bold', doc: '**Phase:** 3 (alpha)\r\n', field: 'Phase' },
      { label: 'CRLF table', doc: '| Phase | 7 |\r\n', field: 'Phase' },
      { label: 'padded table cells', doc: '|   Phase   |   7 (pad)   |\n', field: 'Phase' },
      { label: 'table with extra column', doc: '| Phase | 7 | extra |\n', field: 'Phase' },
      { label: 'value carries em-dashes', doc: 'Phase: 12 — Name — Tail\n', field: 'Phase' },
      { label: 'empty value', doc: 'Phase:\n', field: 'Phase' },
      { label: 'tab after colon', doc: 'Phase:\t8 (tabbed)\n', field: 'Phase' },
      { label: 'suffix must not match prefix', doc: 'Subphase: 3\n', field: 'Phase' },
      { label: 'unterminated bold', doc: '**Phase: 3\n', field: 'Phase' },
      { label: 'first occurrence wins', doc: 'Phase: one\nPhase: two\n', field: 'Phase' },
      { label: 'different field', doc: '**Status:** EXECUTING\n', field: 'Status' },
    ];
    differential('stateExtractField', FIELD_DOCS, 15,
      (e) => [h.stateExtractField(e.doc, e.field), SD.stateExtractField(e.doc, e.field)]);

    // ── 4c. stripFrontmatter — the fence ─────────────────────────────────────
    const FENCE_DOCS = [
      { label: 'LF frontmatter', doc: '---\na: 1\n---\n\nbody\n' },
      { label: 'CRLF frontmatter', doc: '---\r\na: 1\r\n---\r\n\r\nbody\r\n' },
      { label: 'no frontmatter', doc: 'just body\n' },
      { label: 'unterminated fence', doc: '---\na: 1\nbody with no close\n' },
      { label: 'empty frontmatter', doc: '---\n---\nbody\n' },
      { label: 'fence-like line in body', doc: '---\na: 1\n---\nbody\n---\nmore\n' },
      { label: 'leading blank line', doc: '\n---\na: 1\n---\nbody\n' },
      { label: 'frontmatter only', doc: '---\na: 1\n---\n' },
      { label: 'empty document', doc: '' },
      { label: 'four dashes is not a fence', doc: '----\na: 1\n----\nbody\n' },
    ];
    differential('stripFrontmatter', FENCE_DOCS, 8,
      (e) => [h.stripFrontmatter(e.doc), FMOD.stripFrontmatter(e.doc)]);

    // ── 4d. Frontmatter scalar read — the quote-strip leg ─────────────────────
    // NOT a verbatim mirror, so this differential is normalized at the boundary.
    // The hook's extractFrontmatterScalar is a narrow scalar reader with its own
    // deliberate null contract (docs/decisions.md 2026-06-25: a name of
    // null/~/empty means "no curated name" → stay silent, which is what holds
    // false positives at zero). Upstream's parseFrontmatter is a general map
    // builder and spells "no scalar" two other ways: `undefined` for an absent
    // key, and `{}` — its object-list placeholder — for a present-but-empty
    // value. Those are REPRESENTATION differences, not drift.
    //
    // So collapse every "no scalar" spelling on BOTH sides to one sentinel and
    // keep the comparison strict everywhere else. This still reds if either side
    // starts returning a real value where the other returns none; what it will
    // not do is red on the three shapes where the hook's null contract and
    // upstream's placeholder vocabulary have always disagreed on purpose.
    const ABSENT = '<absent>';
    const normScalar = (v) => {
      if (v === null || v === undefined) return ABSENT;
      if (typeof v === 'object') return ABSENT;
      if (typeof v === 'string' && v.trim() === '') return ABSENT;
      return v;
    };
    const SCALAR_DOCS = [
      { label: 'bare scalar', doc: '---\ncurrent_phase: 3\n---\nb\n', key: 'current_phase' },
      { label: 'double-quoted', doc: '---\ncurrent_phase_name: "quoted name"\n---\nb\n', key: 'current_phase_name' },
      { label: 'single-quoted', doc: "---\ncurrent_phase_name: 'sq name'\n---\nb\n", key: 'current_phase_name' },
      { label: 'literal null', doc: '---\ncurrent_phase_name: null\n---\nb\n', key: 'current_phase_name' },
      { label: 'tilde', doc: '---\ncurrent_phase_name: ~\n---\nb\n', key: 'current_phase_name' },
      { label: 'empty value', doc: '---\ncurrent_phase_name:\n---\nb\n', key: 'current_phase_name' },
      { label: 'absent key', doc: '---\na: 1\n---\nb\n', key: 'current_phase_name' },
      { label: 'no frontmatter', doc: 'body only\n', key: 'current_phase_name' },
      { label: 'CRLF', doc: '---\r\ncurrent_phase_name: "crlf"\r\n---\r\nb\r\n', key: 'current_phase_name' },
      { label: 'value contains a colon', doc: '---\ncurrent_phase_name: a: b\n---\nb\n', key: 'current_phase_name' },
      { label: 'trailing spaces', doc: '---\ncurrent_phase_name: name   \n---\nb\n', key: 'current_phase_name' },
    ];
    differential('frontmatter scalar (normalized)', SCALAR_DOCS, 8, (e) => {
      let map;
      try { map = FMOD.parseFrontmatter(e.doc); } catch { map = {}; }
      return [normScalar(h.extractFrontmatterScalar(e.doc, e.key)),
        normScalar(map ? map[e.key] : undefined)];
    });

    // The normalization above is only safe if the hook's OWN null contract still
    // holds — otherwise a regression there would hide inside the sentinel. Pin
    // it directly, on the exact three shapes 4d normalizes.
    for (const label of ['empty value', 'absent key', 'no frontmatter']) {
      const e = SCALAR_DOCS.find((x) => x.label === label);
      ok(h.extractFrontmatterScalar(e.doc, e.key) === null,
        `hook null contract holds for frontmatter shape: ${label}`);
    }

    // ── 4e. The one surviving structural pin ─────────────────────────────────
    // state.cjs's parseProsePhaseField wrapper is NOT exported, so no
    // differential can reach it. If a future bump re-inlines a divergent regex
    // there, every check above stays green — phase-id.cjs would still agree
    // with the hook — while the module that actually reads STATE.md drifts.
    // Text-matching is the only instrument left for this one leg.
    const stateSrc = fs.existsSync(path.join(GSD_LIB, 'state.cjs'))
      ? fs.readFileSync(path.join(GSD_LIB, 'state.cjs'), 'utf8') : null;
    ok(stateSrc !== null && stateSrc.includes('return parsePhaseFromProse(value);'),
      'state.cjs still DELEGATES to the canonical parser (unexported — no differential reaches this)');

    // ── 4f. matchCurrentPositionSection — the section scope (#2956) ───────────
    // The hook mirrors collectSection + tokenizeHeadings verbatim, so compare the
    // composed scoper against upstream's own collectSection over documents built
    // to hit the parts a naive slicer gets wrong: fenced headings, h2-vs-h3,
    // level bounding, ATX closing hashes, CRLF, and absence.
    const isCP = (x) => (x.level === 2 || x.level === 3)
      && x.text.trim().toLowerCase() === 'current position';
    const F = '```';
    const SECTION_DOCS = [
      { label: 'h2 present', doc: '## Current Position\n\nPhase: 7 (A) — GO\n' },
      { label: 'h3 present', doc: '### Current Position\n\nPhase: 7 (A) — GO\n' },
      { label: 'absent', doc: '## Other\n\nbody\n' },
      { label: 'level-bounded, stops at next h2', doc: '## Current Position\n\nPhase: 7 (A) — GO\n\n## Later\n\nPhase: 9 (B) — NO\n' },
      { label: 'h3 section does NOT stop at a deeper h4', doc: '### Current Position\n\nPhase: 7 (A) — GO\n\n#### Sub\n\nmore\n' },
      { label: 'heading inside a fence is not a heading', doc: '## Notes\n\n' + F + 'md\n## Current Position\n\nPhase: 9 (X) — NO\n' + F + '\n\n## Current Position\n\nPhase: 7 (A) — GO\n' },
      { label: 'preceded by an archive section', doc: '## Session Continuity Archive\n\nPhase: 3 (Old) — DONE\n\n## Current Position\n\nPhase: 7 (A) — GO\n' },
      { label: 'ATX closing hashes', doc: '## Current Position ##\n\nPhase: 7 (A) — GO\n' },
      { label: 'CRLF document', doc: '## Current Position\r\n\r\nPhase: 7 (A) — GO\r\n' },
      { label: 'case-insensitive heading text', doc: '## CURRENT POSITION\n\nPhase: 7 (A) — GO\n' },
      { label: 'similar-but-different heading', doc: '## Current Positions\n\nPhase: 7 (A) — GO\n' },
      { label: 'empty section body', doc: '## Current Position\n\n## Later\n\nx\n' },
      { label: 'empty document', doc: '' },
      { label: 'section is the whole document', doc: '## Current Position\nPhase: 7 (A) — GO' },
    ];
    differential('matchCurrentPositionSection', SECTION_DOCS, 12, (e) => {
      const upsSection = MS.collectSection(e.doc, isCP, { levelBounded: true });
      return [h.matchCurrentPositionSection(e.doc), upsSection ? upsSection.body : null];
    });

    // ── 4h. The COMPOSITION oracle — behavioural, over the PUBLIC write path ──
    // REPLACES the 4g text pin (retired 2026-08-19). 4g counted call shapes in
    // state.cjs source because the seams were believed unexported. They are not:
    // `syncStateFrontmatter` is exported (module.exports, state.cjs) and reaches
    // buildStateFrontmatter, so the composition this hook mirrors can be checked
    // by RUNNING it. Every objection to the text pin is structural and none of
    // them apply here:
    //   - state.cjs is a BUILD ARTIFACT (compiled from src/*.cts, replaced
    //     wholesale on every install). Any emit change — a helper-import style,
    //     a reflow inside an argument list, a minifier — reds a text pin for no
    //     behavioural reason, and a red here blocks EVERY commit in the repo.
    //   - the counted regexes were not function-scoped: an unrelated helper
    //     reusing the callee and variable names could supply the expected count
    //     while the real call site was gone. A false GREEN, not just a red.
    //   - comment-stripping was required to keep state.cjs's own JSDoc from
    //     satisfying the pin, and a naive stripper can be fed by a template
    //     literal in the emit.
    // The read seam is deliberately NOT asserted any more. This hook mirrors the
    // WRITE seam; whether gsd-core keeps its own read seam scoped the same way is
    // gsd-core's invariant, not one this repo consumes — the same reasoning that
    // already excluded resolveCurrentPhaseId. Pinning it bought a red we could
    // not act on.
    //
    // The corpus is HARVESTED from the fixture arrays above, so adding a fixture
    // automatically extends this differential and the two can never fall out of
    // sync (same design as §4a). The expectation is DERIVED from upstream's own
    // output rather than hand-written — the pre-fix session wrote a wrong literal
    // expectation for exactly this reason.
    const ORACLE_DOCS = [...CASES, ...SCOPE_CASES, ...FIELD_CASES].map((c) => c.content);
    ok(ORACLE_DOCS.length >= 20,
      `write-seam oracle corpus is non-vacuous (${ORACLE_DOCS.length} >= 20)`);

    let oracleDiverge = 0;
    let oracleRan = 0;
    for (const doc of ORACLE_DOCS) {
      let rebuiltName;
      let rebuiltPhase;
      try {
        const synced = SMOD.syncStateFrontmatter(doc, undefined);
        const rebuilt = FMOD.parseFrontmatter(synced);
        rebuiltName = rebuilt ? rebuilt.current_phase_name : undefined;
        rebuiltPhase = rebuilt ? rebuilt.current_phase : undefined;
      } catch {
        // A throw is itself divergence — the hook is pure and never throws.
        oracleDiverge++;
        continue;
      }
      oracleRan++;
      // Re-express the hook's CONTRACT in terms of what upstream actually wrote.
      // Gate 1's alignment guard is a DELIBERATE divergence from upstream (a
      // forward transition is legitimate and must stay silent), so it is part of
      // the expectation rather than something the oracle flags.
      const curatedRaw = h.extractFrontmatterScalar(doc, 'current_phase_name');
      const fmPhaseTok = h.normalizePhaseToken(h.extractFrontmatterScalar(doc, 'current_phase'));
      const wroteTok = h.normalizePhaseToken(rebuiltPhase == null ? null : String(rebuiltPhase));
      const wroteName = rebuiltName == null ? null : String(rebuiltName);
      const expectWarn = h.phasesAligned(wroteTok, fmPhaseTok)
        && h.isPresentName(curatedRaw)
        && !!wroteName
        && wroteName.trim() !== curatedRaw.trim();
      const actual = h.lintStateMd(doc);
      const verdictAgrees = actual.shouldWarn === expectWarn;
      // When it warns, the NAME it reports must be the name upstream would write.
      // A lint that warns for the right reason but names the wrong value emits an
      // advisory the operator cannot act on.
      const nameAgrees = !expectWarn || actual.harvested === wroteName.trim();
      if (!verdictAgrees || !nameAgrees) {
        oracleDiverge++;
        console.log(`     ↳ oracle divergence: expectWarn=${expectWarn} got=${actual.shouldWarn}`
          + ` upstreamName=${JSON.stringify(wroteName)} harvested=${JSON.stringify(actual.harvested)}`);
      }
    }
    ok(oracleRan === ORACLE_DOCS.length,
      `write-seam oracle ran every corpus document (${oracleRan} of ${ORACLE_DOCS.length})`);
    ok(oracleDiverge === 0,
      `lint agrees with the LIVE write seam over the whole corpus (${oracleDiverge} diverge of ${ORACLE_DOCS.length})`);
  }
}

// ── Summary ───────────────────────────────────────────────────────────────────
console.log(`\n${passed} passed, ${failed} failed${skipped ? `, ${skipped} skipped` : ''}`);
process.exit(failed > 0 ? 1 : 0);
