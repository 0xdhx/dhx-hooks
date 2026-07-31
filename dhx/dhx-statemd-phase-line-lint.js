#!/usr/bin/env node
// dhx-statemd-phase-line-lint.js — PostToolUse hook (Write|Edit matcher)
// Patterns: HP-003, HP-009, HP-017, HP-038, HP-039
//
// WARN-only lint for GSD `.planning/STATE.md` writes. Catches the shape that
// silently corrupts the curated frontmatter `current_phase_name`: one where
// gsd-core's frontmatter rebuild harvests a DIFFERENT name out of the
// `## Current Position` `Phase:` prose line than the one curated in frontmatter.
// See reports/done/2026-06-25-statemd-phase-line-current-phase-name-lint.md.
//
// WHICH shape that is has INVERTED — 2026-07-31, gsd-core 1.9.1 (#2736). It was
// `N — Name (status aside)`, because the old parser took the first parenthetical.
// The current parser prefers the em-dash name unless it reads as a status
// annotation, so that shape is now parsed correctly and the hazard is its mirror:
// `N (Real Name) — <multi-word status tail>`, where the tail escapes both the
// status-word vocabulary and the lone-ALL-CAPS rule and is harvested as the name.
// The lint tracks whatever the mirrored parser does — it does not encode a fixed
// shape — but any PROSE here that names a specific hazard shape is version-bound.
// Re-derive against the live parser before trusting it; do not hand-edit the
// mirror to match a remembered threat model.
//
// WARNS, NEVER BLOCKS. PostToolUse cannot block (HP-009); always exit 0. STATE.md
// prose is human-authored and mid-transition states are legitimate.
//
// LOAD-BEARING GUARD — phase-number alignment.  The naive check
// (first-paren ≠ current_phase_name → warn) FALSE-POSITIVES on legitimate
// forward-transition states where the frontmatter has already advanced past the
// body (cross-repo at audit time: body `Phase: XR-32 …`, frontmatter
// `current_phase: 33`). The name compare ONLY fires when the body Phase number
// equals the frontmatter `current_phase`. A lint that fired on the forward
// transition would train the operator to ignore it — worse than no lint.
//
// MIRROR PROVENANCE (gsd-core 1.7.0 — re-verify on gsd-core bumps):
//   parsePhaseFromProse   @ ~/.claude/gsd-core/bin/lib/phase-id.cjs:281 (canonical,
//                           #2121/#2125; state.cjs:1100 parseProsePhaseField is now
//                           a one-line delegation to it)
//   stateExtractField     @ ~/.claude/gsd-core/bin/lib/state-document.cjs:60
//   stripFrontmatter      @ ~/.claude/gsd-core/bin/lib/frontmatter.cjs:536 (moved
//                           from state.cjs in the #2143 dedup; byte-identical logic)
//   extractFrontmatter    @ ~/.claude/gsd-core/bin/lib/frontmatter.cjs (scalar form)
// The regexes below are COPIED VERBATIM — the lint MUST agree with the
// reader it protects. Do NOT "improve" them (e.g. teach dashName to accept `--`):
// any divergence makes the lint disagree with the very harvest it warns about.
// tests/probes/probe-statemd-phase-line-lint.js asserts the copies still match
// the live gsd-core source per-module (skips when gsd-core is absent) — a
// gsd-core bump that changes or moves them flips that assertion red, forcing a
// re-verify (fired 2026-07-16 on the 1.6.0→1.7.0 #2125 rewrite, as designed).
//
// CHANNEL (dual, per HP-038/HP-039): stderr (human, terminal) + stdout JSON
// {hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext}} (Claude
// inline as <system-reminder>). Same text on both. Silent on every non-warn path.

'use strict';

// ── MIRROR: gsd-core parsePhaseFromProse (phase-id.cjs) — VERBATIM ────────────
// Re-harvested 2026-07-31 for gsd-core 1.9.1 (#2736). The precedence INVERTED:
// it was paren-over-dash, it is now status-keyword-aware dash-over-paren — the
// em-dash name wins unless it reads as a status annotation (STATUSY_TAIL_RE, a
// `Milestone:` prefix, or a lone ALL-CAPS token when a parenthetical exists).
// The dash is searched on a paren-STRIPPED copy, so an em-dash inside a
// parenthetical name can no longer be mistaken for the separator.
// #2111/#2125: the phase token is ANCHORED to the start of the value (after an
// optional `Phase ` label and optional project-code prefix), so a narrative line
// like `Milestone v0.5 complete` or a bold-marked `**1 of 4 CLOSED**` yields
// { phase: null } instead of mining a stray numeral. Name quantifiers are
// length-capped {1,200} upstream (regex-backtracking DoS hardening).
//
// THE THREAT MODEL INVERTED WITH IT — do not reason from the old one. The shape
// this lint was built for (`N — name (status aside)`) is now parsed CORRECTLY
// upstream and is no longer a clobber hazard. The surviving hazard is its
// mirror image: `N (Real Name) — <multi-word status tail>`, where the tail
// escapes both STATUSY_TAIL_RE and the lone-ALL-CAPS rule and is harvested as
// the name. Measured 2026-07-31: 11 of 17 corpus phase-lines changed meaning
// across this bump. Any fixture expectation predating it is stale by default.
function parseProsePhaseField(value) {
  if (!value)
    return { phase: null, name: null };
  // Coerce defensively so a non-string caller cannot throw on this canonical
  // surface (mirrors the sibling #2121 functions' String(...) handling).
  const str = String(value);
  const phaseMatch = str.match(/^\s*(?:Phase\s+)?(?:[A-Z][A-Z0-9_]*-)?(\d+[A-Z]?(?:\.\d+)*)\b/i);
  // The name-extraction quantifiers are length-bounded so a crafted long
  // unterminated run (many `(` or `—`) in an untrusted STATE.md field value
  // cannot drive O(n^2) regex backtracking (CPU-exhaustion DoS). A real phase
  // name is far shorter than the cap.
  const parenName = str.match(/\(([^)]{1,200})\)/);
  // #2736 (the #1695 AC #3 residual): status-keyword-aware precedence. The
  // first-party writer shapes are `N — Name (aside)` (completePhaseCore),
  // `N (Name) — EXECUTING` (beginPhaseCore), `N — COMPLETE`, and the
  // gsd2-import `N (slug) — Milestone: Title`. A blind paren-first read
  // harvests the aside as the name on the first shape; a blind dash-first
  // read harvests the status keyword on the others. Prefer the em-dash name
  // when it is a genuine name, else fall back to the parenthetical. Still
  // lossy for names that themselves contain a parenthetical — transitions
  // that hold the exact name bypass this parser entirely via the
  // syncStateFrontmatter authoritative override.
  //
  // The em-dash separator is searched on a paren-stripped copy, so an em-dash
  // INSIDE a parenthetical name (`16 (Native — Global Hotkey) — EXECUTING`)
  // can never be mistaken for the name separator.
  const strNoParens = str.replace(/\([^)\n]{0,200}\)/g, ' ');
  const dashName = strNoParens.match(/—\s*([^(\n]{1,200}?)\s*$/);
  // The precedence-decision vocabulary is deliberately broader than the final
  // name-nulling filter below: a dash tail that merely LOOKS like a status
  // annotation should lose to a parenthetical name, without changing which
  // extracted names are nulled (that set stays the long-standing three).
  const STATUS_WORD_RE = /^(?:complete|executing|not started)$/i;
  const STATUSY_TAIL_RE = /^(?:completed?|executing|not started|planning|planned|ready(?:\s+to\s+\S.{0,50})?|done|in progress|blocked|paused|verifying)$/i;
  const dashRaw = dashName?.[1]?.trim() ?? null;
  const dashIsName = dashRaw !== null && dashRaw.length > 0
    && !STATUSY_TAIL_RE.test(dashRaw)
    && !/^milestone\s*:/i.test(dashRaw)
    // A lone ALL-CAPS token after the dash reads as a status marker whenever a
    // parenthetical name exists to prefer (the beginPhase writer's systematic
    // `(Name) — STATUS` shape); with no parenthetical it stays the best guess.
    && !(parenName && /^[A-Z][A-Z0-9_-]*$/.test(dashRaw));
  const rawName = dashIsName ? dashRaw : (parenName?.[1] ?? dashRaw ?? null);
  const name = rawName && !STATUS_WORD_RE.test(rawName.trim())
    ? rawName.trim()
    : null;
  return {
    phase: phaseMatch ? phaseMatch[1] : null,
    name,
  };
}

// ── MIRROR: gsd-core escapeRegex (state-document.cjs) — VERBATIM ───────────────
function escapeRegex(str) {
  return str.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

// ── MIRROR: gsd-core tableRowPattern + isTableSeparatorRow — VERBATIM ──────────
function tableRowPattern(escapedFieldName) {
  return new RegExp(`^(\\|[ \\t]*)(${escapedFieldName})([ \\t]*\\|[ \\t]*)([^|\\n]*?)([ \\t]*\\|[ \\t]*)$`, 'im');
}
function isTableSeparatorRow(firstCell) {
  return /^[\s\-:]+$/.test(firstCell.trim());
}

// ── MIRROR: gsd-core stateExtractField (state-document.cjs:60) — VERBATIM ──────
// Bold `**Field:**` first, then line-start `^Field:`, then pipe-table. Searches
// the whole (frontmatter-stripped) body — the lint extracts the SAME value
// gsd-core would harvest, so the two cannot disagree on which Phase line wins.
function stateExtractField(content, fieldName) {
  const escaped = escapeRegex(fieldName);
  const boldPattern = new RegExp(`\\*\\*${escaped}:\\*\\*[ \\t]*(.+)`, 'i');
  const boldMatch = content.match(boldPattern);
  if (boldMatch)
    return boldMatch[1].trim();
  const plainPattern = new RegExp(`^${escaped}:[ \\t]*(.+)`, 'im');
  const plainMatch = content.match(plainPattern);
  if (plainMatch)
    return plainMatch[1].trim();
  const tableMatch = content.match(tableRowPattern(escaped));
  if (tableMatch && !isTableSeparatorRow(tableMatch[2]))
    return tableMatch[4].trim();
  return null;
}

// ── MIRROR: gsd-core stripFrontmatter (frontmatter.cjs:536) — VERBATIM ─────────
function stripFrontmatter(content) {
  let result = content;
  while (true) {
    const stripped = result.replace(/^\s*---\r?\n[\s\S]*?\r?\n---\s*/, '');
    if (stripped === result)
      break;
    result = stripped;
  }
  return result;
}

// ── Minimal frontmatter scalar reader ─────────────────────────────────────────
// gsd-core's extractFrontmatter (frontmatter.cjs) is a hand-rolled YAML-ish line
// parser that stores every scalar as a STRING (quote-stripped). We only need two
// top-level keys, so we mirror just that branch: byte-0 `---` block, top-level
// `key: value`, single leading/trailing quote stripped. Matches
// `value.replace(/^["']|["']$/g, '')`.
function extractFrontmatterScalar(content, key) {
  const headerEnd = content.startsWith('---\r\n') ? 5 : content.startsWith('---\n') ? 4 : -1;
  if (headerEnd === -1)
    return null;
  const closingLineStart = content.indexOf('\n---', headerEnd);
  if (closingLineStart === -1)
    return null;
  const yamlEnd = content[closingLineStart - 1] === '\r' ? closingLineStart - 1 : closingLineStart;
  const yaml = content.slice(headerEnd, yamlEnd);
  for (const line of yaml.split(/\r?\n/)) {
    // top-level keys only (no leading indent) — current_phase / current_phase_name
    // are always top-level scalars.
    const m = line.match(/^([a-zA-Z0-9_-]+):\s*(.*)$/);
    if (m && m[1] === key) {
      const raw = m[2].trim();
      if (raw === '' || raw === '[')
        return null;
      return raw.replace(/^["']|["']$/g, '');
    }
  }
  return null;
}

// ── Phase-number normalization + alignment ────────────────────────────────────
// Normalize both sides through the SAME anchored token regex gsd-core uses for
// prose AND frontmatter phase values (state.cjs:2825 runs frontmatter `Current
// Phase` raws through parsePhaseFromProse too), so `XR-32` → `32`,
// `03.1` → `03.1` — and junk like `Milestone v1.4` → null (no longer `1.4`),
// which lands on Gate 1's suppress side, matching gsd-core's own #905 guard.
function normalizePhaseToken(value) {
  if (value == null)
    return null;
  const m = String(value).match(/^\s*(?:Phase\s+)?(?:[A-Z][A-Z0-9_]*-)?(\d+[A-Z]?(?:\.\d+)*)\b/i);
  return m ? m[1] : null;
}

function phasesAligned(a, b) {
  if (a == null || b == null)
    return false;
  if (a === b)
    return true;
  // leading-zero / number-vs-string tolerance for pure-integer phases (5 == 05)
  if (/^\d+$/.test(a) && /^\d+$/.test(b))
    return Number(a) === Number(b);
  return false;
}

// YAML null literals — a frontmatter name of `null` / `~` / empty means "no
// curated name", so there is nothing for a rebuild to clobber → stay silent.
function isPresentName(name) {
  if (name == null)
    return false;
  const t = name.trim();
  return t !== '' && !/^(?:null|~)$/i.test(t);
}

// ── Core lint ─────────────────────────────────────────────────────────────────
// Returns { shouldWarn, harvested, curated, phase } — shouldWarn true ONLY for a
// genuine first-paren-≠-current_phase_name mismatch at aligned phase numbers.
function lintStateMd(content) {
  const result = { shouldWarn: false, harvested: null, curated: null, phase: null };
  if (!content)
    return result;

  const body = stripFrontmatter(content);
  const prose = parseProsePhaseField(stateExtractField(body, 'Phase'));
  const fmPhase = normalizePhaseToken(extractFrontmatterScalar(content, 'current_phase'));
  const fmNameRaw = extractFrontmatterScalar(content, 'current_phase_name');

  // Gate 1 — phase-number alignment (the load-bearing guard). Both sides must
  // resolve to a phase number and they must align. A forward transition
  // (body phase ≠ frontmatter phase) is legitimate → suppress.
  if (!prose.phase || !fmPhase || !phasesAligned(normalizePhaseToken(prose.phase), fmPhase))
    return result;

  // Gate 2 — a name was actually harvested (reject-guard already applied in
  // parseProsePhaseField), and the frontmatter carries a curated name to clobber.
  if (!prose.name || !isPresentName(fmNameRaw))
    return result;

  const curated = fmNameRaw.trim();
  if (prose.name === curated)
    return result; // names agree — the SAFE name-in-first-paren shape

  result.shouldWarn = true;
  result.harvested = prose.name;
  result.curated = curated;
  result.phase = fmPhase;
  return result;
}

// Emit a fix the CURRENT parser actually honors, verified per-call rather than
// asserted. The pre-1.9.1 advisory hard-coded "put the name in the FIRST paren";
// #2736 inverted the precedence and that shape became the hazard it was meant to
// cure, so the wrong advice outlived the correct parser by a whole release. No
// fixed string is safe here: which shape round-trips depends on the curated name
// itself (a name that reads as status vocabulary — `Planning`, `DONE` — loses the
// em-dash branch and needs the parenthetical form instead). So propose, run the
// real parser over the proposal, and only suggest what survives.
function suggestFixLine(result) {
  const { phase, curated } = result;
  const shapes = [
    `Phase: ${phase} — ${curated} (<status>)`,   // preferred post-#2736: dash name wins
    `Phase: ${phase} (${curated}) — <status>`,   // for names that read as status words
  ];
  for (const shape of shapes) {
    const probe = shape.replace('Phase: ', '').replace('<status>', 'EXECUTING');
    if (parseProsePhaseField(probe).name === curated)
      return `  Fix: ${shape}`;
  }
  // Neither shape survives: the curated name IS one of gsd-core's rejected status
  // tokens (complete / executing / not started), which the parser nulls outright.
  // No prose arrangement can carry it — the name itself has to change.
  return `  Fix: "${curated}" collides with gsd-core's reserved status vocabulary and cannot survive any prose shape — rename the phase.`;
}

function buildAdvisory(result) {
  return [
    `⚠ statemd-phase-line: Current Position harvests "${result.harvested}" but frontmatter current_phase_name is "${result.curated}" (phase ${result.phase})`,
    `  A frontmatter rebuild (gsd-core parsePhaseFromProse) will clobber the curated name.`,
    suggestFixLine(result),
  ].join('\n');
}

function isStateMdPath(filePath) {
  return typeof filePath === 'string' && /(^|\/)\.planning\/STATE\.md$/.test(filePath);
}

// ── Hook entrypoint ───────────────────────────────────────────────────────────
function runHook() {
  let input = '';
  process.stdin.on('data', (d) => { input += d; });
  process.stdin.on('end', () => {
    let data;
    try { data = JSON.parse(input); } catch { process.exit(0); }

    const toolName = data && data.tool_name;
    if (toolName !== 'Write' && toolName !== 'Edit') process.exit(0);

    const filePath = data.tool_input && data.tool_input.file_path;
    if (!isStateMdPath(filePath)) process.exit(0);

    // PostToolUse fires AFTER the write — read the post-edit content from disk so
    // Write (full content) and Edit (old/new string) are handled uniformly.
    let content;
    try { content = require('fs').readFileSync(filePath, 'utf8'); } catch { process.exit(0); }

    let result;
    try { result = lintStateMd(content); } catch { process.exit(0); }
    if (!result.shouldWarn) process.exit(0);

    const advisory = buildAdvisory(result);
    process.stderr.write(advisory + '\n'); // human, terminal (HP-038: Claude-invisible alone)
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: 'PostToolUse',
        additionalContext: advisory,
      },
    })); // Claude inline as <system-reminder> (HP-039)
    process.exit(0);
  });
}

if (require.main === module) {
  runHook();
} else {
  module.exports = {
    parseProsePhaseField,
    stateExtractField,
    stripFrontmatter,
    extractFrontmatterScalar,
    normalizePhaseToken,
    phasesAligned,
    isPresentName,
    lintStateMd,
    buildAdvisory,
    isStateMdPath,
  };
}
