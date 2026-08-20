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
// MIRROR PROVENANCE (last re-verified against gsd-core 1.11.0, 2026-08-19 —
// re-verify on gsd-core bumps). Resolve every entry by SYMBOL, never by line
// number: these modules are build artifacts compiled from src/*.cts and replaced
// wholesale on every install, so a line cite here is stale the moment it is
// written. `grep -n '<symbol>' <file>` is the resolution step.
//   parsePhaseFromProse   @ ~/.claude/gsd-core/bin/lib/phase-id.cjs (canonical,
//                           #2121/#2125; state.cjs's own parseProsePhaseField is
//                           a one-line delegation to it)
//   stateExtractField     @ ~/.claude/gsd-core/bin/lib/state-document.cjs
//   stripFrontmatter      @ ~/.claude/gsd-core/bin/lib/frontmatter.cjs (moved
//                           from state.cjs in the #2143 dedup; byte-identical logic)
//   extractFrontmatter    @ ~/.claude/gsd-core/bin/lib/frontmatter.cjs (scalar form)
//   stripFencedCode       @ ~/.claude/gsd-core/bin/lib/markdown-sectionizer.cjs
//   tokenizeHeadings      @ ~/.claude/gsd-core/bin/lib/markdown-sectionizer.cjs
//   collectSection        @ ~/.claude/gsd-core/bin/lib/markdown-sectionizer.cjs
//   matchCurrentPositionSection @ ~/.claude/gsd-core/bin/lib/state.cjs (#2956,
//                           added 1.10.0 — see the sectionizer mirror block below)
// The regexes below are COPIED VERBATIM — the lint MUST agree with the
// reader it protects. Do NOT "improve" them (e.g. teach dashName to accept `--`):
// any divergence makes the lint disagree with the very harvest it warns about.
// tests/probes/probe-statemd-phase-line-lint.js asserts the copies still match
// the live gsd-core source per-module (skips when gsd-core is absent) — a
// gsd-core bump that changes or moves them flips that assertion red, forcing a
// re-verify (fired 2026-07-16 on the 1.6.0→1.7.0 #2125 rewrite, as designed).
//
// A MIRROR IS NOT ONLY ITS FUNCTION BODIES — it is also the COMPOSITION at the
// call site. gsd-core 1.10.0 (#2956) changed no mirrored function body at all;
// it changed which CONTENT `stateExtractField` is handed for `Phase` (the
// `## Current Position` section, not the whole body). Every per-function
// differential stayed green through that bump while the lint silently disagreed
// with the harvest it warns about. The probe now pins the composition too
// (§4f/§4g) — when adding a mirror, ask what CALLS it, not just what it is.
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

// ── MIRROR: gsd-core stateExtractField (state-document.cjs) — VERBATIM ─────────
// Bold `**Field:**` first, then line-start `^Field:`, then pipe-table, over
// whatever CONTENT it is handed — first match wins. This function is unchanged
// since 1.7.0. What changed in gsd-core 1.10.0 (#2956) is the SCOPE its callers
// hand it for `Phase`: no longer the whole body, but the `## Current Position`
// section. See matchCurrentPositionSection below; the scoping lives at the CALL
// SITE in lintStateMd, which is where the 1.10.0 break actually was.
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

// ── MIRROR: gsd-core stripFrontmatter (frontmatter.cjs) — VERBATIM ─────────────
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

// ── MIRROR: gsd-core section scoping (#2956, gsd-core 1.10.0) — VERBATIM ───────
// 1.10.0 stopped reading `Phase:` from the whole STATE.md body and scoped it to
// the `## Current Position` section, at BOTH seams:
//   buildStateFrontmatter — the WRITE seam, and the ONLY one this lint mirrors
//   resolveStatePhase     — the READ seam (called by cmdStateSnapshot and
//                           cmdStateValidate; it lived inline in cmdStateSnapshot
//                           until gsd-core 1.11.0 / #3208 extracted it)
// Both still spell the scope `matchCurrentPositionSection(<body>) ?? <body>`, so
// one mirrored scoper serves both — but they no longer share a CALL shape, and
// more importantly they no longer share a PRECEDENCE. resolveStatePhase reads
// frontmatter FIRST (`current_phase` / `current_phase_name`), falling through to
// the scoped prose only when frontmatter is absent; buildStateFrontmatter reads
// the body ONLY, because frontmatter is its output. This lint mirrors the WRITE
// seam deliberately and must keep doing so: a lint that followed the read seam's
// ladder would compare `current_phase_name` against itself, always agree, and
// never warn. The precedence split is also WHY the lint still earns its keep —
// a body/frontmatter disagreement is invisible to every read until the next
// frontmatter rebuild flips it. Do not "re-sync" this to the read seam.
// gsd-core also carries a THIRD scoped `Phase` read, resolveCurrentPhaseId
// (#3208), which is strict (no `?? body` fallback) because its callers persist
// durable records. It is not a seam this lint mirrors; state.cjs documents the
// divergence as deliberate.
//
// Without the scope the lint reads a historical `Phase:` line out of an archive
// section and fails in one of two directions:
//   FALSE WARN — archive phase number happens to equal current_phase but carries
//                an older name: the lint reports a clobber that cannot happen.
//   BLIND      — archive phase differs from current_phase: Gate 1's alignment
//                check suppresses, and the real Current Position line is never
//                examined. Silent, and indistinguishable from a clean pass.
//
// collectSection + tokenizeHeadings + stripFencedCode are copied VERBATIM from
// markdown-sectionizer.cjs (a pure, dependency-free seam — zero require()s).
// stripFencedCode is unreachable on this hook's only call path:
// matchCurrentPositionSection passes {levelBounded:true}, leaving collectSection's
// `stripFences` default false. It is mirrored anyway because collectSection's
// verbatim body references it — omitting it would leave a latent ReferenceError
// for any future caller. Do NOT "simplify" the three into a regex heading scan:
// one that disagrees on fenced-code headings or ATX closing hashes reintroduces
// precisely the divergence class this lint exists to warn about.

function stripFencedCode(content) {
    if (typeof content !== 'string') {
        return { text: '', unterminatedFence: false };
    }
    const lines = content.split('\n');
    const kept = [];
    let openFence = null;
    // Matches: optional indent (≤3 spaces per CommonMark), fence run, optional info string
    const delimRe = /^( {0,3})(`{3,}|~{3,})(.*)$/;
    for (const rawLine of lines) {
        // Strip trailing \r for delimiter matching (CRLF safety)
        const line = rawLine.replace(/\r$/, '');
        const m = delimRe.exec(line);
        if (m) {
            const char = m[2][0];
            const len = m[2].length;
            const trailing = m[3];
            if (openFence === null) {
                // CommonMark §4.5: backtick fence info string must not contain a backtick.
                // If it does, this line is NOT a valid fence opener (treat as ordinary content).
                if (char === '`' && trailing.includes('`')) {
                    kept.push(rawLine);
                    continue;
                }
                // Opening delimiter — record fence state, drop this line
                openFence = { char, len };
            }
            else if (char === openFence.char && len >= openFence.len && /^\s*$/.test(trailing)) {
                // Closing delimiter (same char, sufficient length, no trailing content) — close and drop
                openFence = null;
            }
            // else: mismatched delimiter inside fence — treat as content, still drop (it's a fence line)
            continue; // all delimiter lines are dropped
        }
        if (openFence === null) {
            kept.push(rawLine); // non-fence content: keep as-is (preserve original \r if any)
        }
        // Lines inside a fence are silently dropped
    }
    return { text: kept.join('\n'), unterminatedFence: openFence !== null };
}

function tokenizeHeadings(content) {
    if (typeof content !== 'string' || content.length === 0)
        return [];
    // Strip fences first so headings inside code blocks are ignored.
    // We need the original line positions, so we map stripped-text line numbers
    // back to original by tracking which original lines survived stripping.
    const originalLines = content.split('\n');
    const tokens = [];
    // We re-run the fence state machine to know which lines are "kept", so we
    // can map line index in original to whether it survived.
    const delimRe = /^( {0,3})(`{3,}|~{3,})(.*)$/;
    let openFence = null;
    // Accumulate character offset as we iterate lines
    let charOffset = 0;
    for (let i = 0; i < originalLines.length; i++) {
        const rawLine = originalLines[i];
        const line = rawLine.replace(/\r$/, '');
        const dm = delimRe.exec(line);
        if (dm) {
            const char = dm[2][0];
            const len = dm[2].length;
            const trailing = dm[3];
            if (openFence === null) {
                // CommonMark §4.5: backtick fence info string must not contain a backtick.
                if (char === '`' && trailing.includes('`')) {
                    // Not a valid fence opener — check for heading on this line (will fall through)
                }
                else {
                    openFence = { char, len };
                    charOffset += rawLine.length + 1;
                    continue;
                }
            }
            else if (char === openFence.char && len >= openFence.len && /^\s*$/.test(trailing)) {
                openFence = null;
                charOffset += rawLine.length + 1;
                continue;
            }
            else {
                // Mismatched/invalid delimiter inside fence — treat as content (still inside fence), skip heading check
                charOffset += rawLine.length + 1;
                continue;
            }
        }
        if (openFence === null) {
            // This line is outside any fence — check for ATX heading.
            // CommonMark: ≤3 leading spaces, then 1–6 `#`, then either EOF (empty heading)
            // or at least one space/tab followed by optional text, with optional closing `#` sequence.
            const headingMatch = /^( {0,3})(#{1,6})([ \t]+.*|[ \t]*)?$/.exec(line);
            if (headingMatch) {
                const hashes = headingMatch[2];
                const rest = headingMatch[3] ?? '';
                // Strip optional closing `#` sequence: trailing whitespace + one or more `#` + optional whitespace
                const rawText = rest.replace(/^[ \t]+/, '').replace(/[ \t]+#+[ \t]*$/, '').replace(/^#+[ \t]*$/, '');
                tokens.push({
                    level: hashes.length,
                    text: rawText.trim(),
                    line: i + 1, // 1-based
                    offset: charOffset,
                });
            }
        }
        charOffset += rawLine.length + 1;
    }
    return tokens;
}

function collectSection(content, headingPredicate, opts = {}) {
    if (typeof content !== 'string' || content.length === 0)
        return null;
    const { levelBounded = true, stopAtLevel, stripFences = false } = opts;
    const headings = tokenizeHeadings(content);
    const targetIdx = headings.findIndex(headingPredicate);
    if (targetIdx === -1)
        return null;
    const target = headings[targetIdx];
    const lines = content.split('\n');
    // Determine which headings act as stops after the target
    const bodyStartLine = target.line + 1; // 1-based, first line of body
    let bodyEndLine = lines.length + 1; // 1-based, exclusive (default: EOF+1)
    for (let j = targetIdx + 1; j < headings.length; j++) {
        const next = headings[j];
        let isStop;
        if (stopAtLevel !== undefined) {
            // stopAtLevel: stop at the next heading whose level <= stopAtLevel
            isStop = next.level <= stopAtLevel;
        }
        else {
            isStop = levelBounded ? next.level <= target.level : true;
        }
        if (isStop) {
            bodyEndLine = next.line; // stop before this line (1-based)
            break;
        }
    }
    // Compute character offsets for bodyStart.
    // lineOffsets[i] = character offset of line (i+1) in content (1-based).
    const lineOffsets = new Array(lines.length);
    let acc = 0;
    for (let i = 0; i < lines.length; i++) {
        lineOffsets[i] = acc;
        acc += lines[i].length + 1; // +1 for the '\n' separator
    }
    const eofOffset = acc; // byte offset past the last line
    // bodyStart: character offset of first line of body (bodyStartLine is 1-based)
    const bodyStartOffset = bodyStartLine <= lines.length ? lineOffsets[bodyStartLine - 1] : eofOffset;
    // Slice body lines (0-based array: bodyStartLine-1 to bodyEndLine-2 inclusive)
    const bodyRaw = lines.slice(bodyStartLine - 1, bodyEndLine - 1).join('\n').trimEnd();
    const body = stripFences ? stripFencedCode(bodyRaw).text : bodyRaw;
    // INVARIANT: content.slice(bodyStart, bodyEnd) === body
    // bodyEnd is derived from body.length so that replaceSection(content, section, section.body) === content.
    return { heading: target, body, bodyStart: bodyStartOffset, bodyEnd: bodyStartOffset + body.length };
}

// matchCurrentPositionSection (state.cjs) — VERBATIM except the module
// qualifier on collectSection, which cannot survive extraction into a standalone
// file (same adaptation the other mirrors make).
function matchCurrentPositionSection(body) {
    const isCurrentPosition = (h) => (h.level === 2 || h.level === 3) && h.text.trim().toLowerCase() === 'current position';
    const section = collectSection(body, isCurrentPosition, { levelBounded: true });
    return section ? section.body : null;
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
// prose AND frontmatter phase values (state.cjs's syncStateFrontmatter runs
// frontmatter `Current Phase` raws through parsePhaseFromProse too), so `XR-32` → `32`,
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
  // #2956 (gsd-core 1.10.0): scope `Phase` to ## Current Position, falling back
  // to the whole body when no such section exists — byte-for-byte the policy at
  // gsd-core's write seam (buildStateFrontmatter). Reading the
  // whole body here is what made this lint disagree with the harvest it warns
  // about; see the mirror block above for the two failure directions.
  const currentPositionScope = matchCurrentPositionSection(body) ?? body;
  const prose = parseProsePhaseField(stateExtractField(currentPositionScope, 'Phase'));
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
    tokenizeHeadings,
    collectSection,
    matchCurrentPositionSection,
    extractFrontmatterScalar,
    normalizePhaseToken,
    phasesAligned,
    isPresentName,
    lintStateMd,
    buildAdvisory,
    isStateMdPath,
  };
}
