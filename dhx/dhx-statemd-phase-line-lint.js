#!/usr/bin/env node
// dhx-statemd-phase-line-lint.js — PostToolUse hook (Write|Edit matcher)
// Patterns: HP-003, HP-009, HP-017, HP-038, HP-039
//
// WARN-only lint for GSD `.planning/STATE.md` writes. Catches the one shape that
// silently corrupts the curated frontmatter `current_phase_name`: when the
// `## Current Position` `Phase:` prose line puts a status/aside in the FIRST
// parenthetical and the name after the dash. gsd-core's frontmatter rebuild
// harvests the FIRST paren (`parseProsePhaseField`) and clobbers the curated
// name. See reports/done/2026-06-25-statemd-phase-line-current-phase-name-lint.md.
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

// ── MIRROR: gsd-core parsePhaseFromProse (phase-id.cjs:281) — VERBATIM ─────────
// Paren-over-dash precedence; reject-guard drops bare status tokens. The dash
// branch matches the em-dash `—` (U+2014) ONLY — `--` is intentionally not a
// name separator here (it falls through to the paren, exactly as gsd-core reads).
// #2111/#2125: the phase token is ANCHORED to the start of the value (after an
// optional `Phase ` label and optional project-code prefix), so a narrative line
// like `Milestone v0.5 complete` or a bold-marked `**1 of 4 CLOSED**` yields
// { phase: null } instead of mining a stray numeral. Name quantifiers are
// length-capped {1,200} upstream (regex-backtracking DoS hardening).
function parseProsePhaseField(value) {
  if (!value)
    return { phase: null, name: null };
  const str = String(value);
  const phaseMatch = str.match(/^\s*(?:Phase\s+)?(?:[A-Z][A-Z0-9_]*-)?(\d+[A-Z]?(?:\.\d+)*)\b/i);
  const parenName = str.match(/\(([^)]{1,200})\)/);
  const dashName = str.match(/—\s*([^(\n]{1,200}?)(?:\s*\(|$)/);
  const rawName = parenName?.[1] ?? dashName?.[1] ?? null;
  const name = rawName && !/^(?:complete|executing|not started)$/i.test(rawName.trim())
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

function buildAdvisory(result) {
  return [
    `⚠ statemd-phase-line: Current Position harvests "${result.harvested}" but frontmatter current_phase_name is "${result.curated}" (phase ${result.phase})`,
    `  A frontmatter rebuild (gsd-core parseProsePhaseField) will clobber the curated name.`,
    `  Fix: put the name in the FIRST paren — Phase: ${result.phase} (${result.curated}) — <status>`,
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
