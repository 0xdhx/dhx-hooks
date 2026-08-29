#!/usr/bin/env node
// DHX Statusline renderer — fork of gsd-statusline.js v1.37.1 baseline.
//
// Called by dhx/statusline-wrapper.js. Wrapper appends git/cache/ccburn
// and prepends drift/critical-health around this output. This renderer
// owns: compact model name, CCS profile letter, 5-seg context bar,
// conditional line 2 (GSD state + repo signals), advisory-health tail.
//
// Owned by the hooks repo (not by /gsd-update). Kept byte-distinct from
// gsd-statusline.js so GSD updates never alter our rendering.
// See docs/statusline-wrapper.md for segment table and color semantics.
// Patterns: HP-032

const fs = require('fs');
const path = require('path');
const os = require('os');

// Shared plugins/cache allowlist (D-14) — the RAT-04 `⚠ cc-novel` segment
// re-applies isAllowlisted to cc-novel-patterns.json entries AT RENDER TIME so
// a widened allowlist clears the warning on the next ~1Hz refresh without a
// re-enumeration. The require is try/catch-wrapped: a missing module degrades
// the segment to inert (it hides) rather than throwing. The module is pure JS
// — no fs, no subprocess — so the render-time re-filter keeps STATUS-06 (D-12).
let pluginCacheAllowlist = null;
try {
  pluginCacheAllowlist = require('../scripts/lib/plugin-cache-allowlist.js');
} catch (e) { /* module absent → cc-novel segment stays inert */ }

// cc-warning snooze (shared module — single source of truth for the snooze file
// path/format/predicate). When `/dhx:statusline snooze cc <dur>` is active, the
// cc version-drift cluster below collapses to a dim countdown token. try/catch
// require so a missing module degrades to "no snooze" (warnings always show)
// rather than throwing — fail-OPEN, since a snooze hides a real signal. See
// scripts/lib/cc-snooze.js.
let ccSnooze = null;
try {
  ccSnooze = require('../scripts/lib/cc-snooze.js');
} catch (e) { /* module absent → cc warnings never snooze (fail-open) */ }

// --- Model + CCS identity ----------------------------------------------------

// Compact display_name to "<lowercase-letter><version>[+]".
//   "Opus 4.7 (1M context)"  → "o4.7+"
//   "Opus 4.7"               → "o4.7"
//   "Sonnet 4.6"             → "s4.6"
//   "Haiku 4.5"              → "h4.5"
//   "claude-opus-4-8[1m]"    → "o4.8+"   (raw model-id, e.g. a /model override)
//   "claude-sonnet-4-6"      → "s4.6"
//   "claude-haiku-4-5-20251001" → "h4.5"
// Lowercase reads quieter next to the dim model color; `+` replaces "(1M)"
// so the segment stays 5 chars vs the old 10-13. Unrecognized shapes pass
// through verbatim so we never hide the identity on a new model ship.
//
// The raw-model-id branch exists because `/model <id>` overrides make CC ship
// the literal id (e.g. "claude-opus-4-8[1m]") as display_name instead of the
// friendly "Opus 4.8" form — without it the segment shows the full 18-char id.
function compactModel(displayName) {
  if (!displayName) return 'Claude';
  // 1M-context marker in either form: friendly "(1M context)" or raw id "[1m]".
  const has1M = /\(1M context\)|\[1m\]/i.test(displayName);
  // Friendly form: "Opus 4.7 (1M context)".
  let m = displayName.match(/^(Opus|Sonnet|Haiku)\s+([\d.]+)/);
  if (m) return `${m[1][0].toLowerCase()}${m[2]}${has1M ? '+' : ''}`;
  // Raw model-id form: "claude-<family>-<major>-<minor>[...]" (major/minor
  // hyphen-joined; trailing date suffix / "[1m]" ignored by the un-anchored end).
  m = displayName.match(/^claude-(opus|sonnet|haiku)-(\d+)-(\d+)/i);
  if (m) return `${m[1][0].toLowerCase()}${m[2]}.${m[3]}${has1M ? '+' : ''}`;
  return displayName;
}

// Effort level → colored braille-density glyph (set B from menu: both-column
// bottom-up fill). Read from the statusline stdin payload (data.effort?.level);
// CC emits effort per-session and refreshes it on /effort, so the next render
// reflects the change. Absent/unknown level → glyph hidden. (Source pivoted
// settings.json → tmux pane-scrape → stdin; pane-scrape retired ad9cf44.)
//
// States + colors track the context-bar ramp so both meters read with the
// same "hotter = more burn" polarity. Unknown / missing → '' (hide segment).
const EFFORT_RENDER = {
  low:    { glyph: '⡀', color: '\x1b[2m' },           // dim gray — spark
  medium: { glyph: '⣀', color: '\x1b[36m' },          // cyan — warming up
  high:   { glyph: '⣤', color: '\x1b[33m' },          // yellow — active
  xhigh:  { glyph: '⣶', color: '\x1b[38;5;208m' },    // orange 208 — hot
  max:    { glyph: '⣿', color: '\x1b[31m' },          // red — all-in
};

function renderEffort(level) {
  const r = EFFORT_RENDER[level];
  return r ? `${r.color}${r.glyph}\x1b[0m` : '';
}

// Return the CCS profile letter when CLAUDE_CONFIG_DIR resolves to a CCS
// instance path (`~/.ccs/instances/<letter>`). Empty string otherwise —
// e.g., on a non-CCS install where CLAUDE_CONFIG_DIR is absent or points
// at the default `~/.claude`.
function getCcsProfile() {
  const configDir = process.env.CLAUDE_CONFIG_DIR || '';
  const m = configDir.match(/\.ccs\/instances\/([^/]+)\/?$/);
  return m ? m[1] : '';
}

// --- Shared helpers ----------------------------------------------------------

const NAME_MAX = 20; // char cap for milestone + phase names on line 2

// Truncate with ellipsis when needed; … counts as 1 char so output width
// stays at `max`. Strings at or below the cap pass through unchanged.
function truncate(str, max) {
  if (!str) return '';
  return str.length <= max ? str : str.slice(0, max - 1) + '…';
}

// Walk up from dir looking for .git/ — the repo root anchor. Returns null
// outside any repo (statusline then skips repo-signal reading).
function findRepoRoot(dir) {
  const home = os.homedir();
  let current = dir;
  for (let i = 0; i < 10; i++) {
    if (fs.existsSync(path.join(current, '.git'))) return current;
    const parent = path.dirname(current);
    if (parent === current || current === home) break;
    current = parent;
  }
  return null;
}

// Count open repo signals: reports/*.md (non-done, top-level only),
// .planning/todos/pending/*.md, .planning/backlog/*.md (top-level only).
// Each class contributes an integer; 0 for absent dirs. Zero-count classes
// render nothing on line 2, so empty repos pay nothing for this read.
// Convention asymmetry: reports/ + backlog/ use flat-active with archived
// siblings (reports/done/, backlog/shipped/ etc.); todos/ uses nested
// pending/ for active with completed/ as the archived sibling (GSD-core
// canonical — `bin/lib/commands.cjs cmdTodoComplete` writes there). `done/`
// is a retired GSD name that may still exist in older repos; neither
// archive dir is counted here, so both are inert for this reader.
function getRepoSignals(dir) {
  const counts = { reports: 0, todos: 0, backlog: 0 };
  const root = findRepoRoot(dir);
  if (!root) return counts;
  try {
    const reportsDir = path.join(root, 'reports');
    if (fs.existsSync(reportsDir)) {
      const entries = fs.readdirSync(reportsDir, { withFileTypes: true });
      counts.reports = entries.filter(e => e.isFile() && e.name.endsWith('.md')).length;
    }
  } catch { /* unreadable — leave 0 */ }
  for (const [name, subdir] of [['todos', '.planning/todos/pending'], ['backlog', '.planning/backlog']]) {
    try {
      const full = path.join(root, subdir);
      if (fs.existsSync(full)) {
        counts[name] = fs.readdirSync(full).filter(f => f.endsWith('.md')).length;
      }
    } catch { /* unreadable — leave 0 */ }
  }
  return counts;
}

// Read the current session's in-progress task title. CC writes one JSON file
// per task at <claudeDir>/tasks/<session>/<id>.json with the shape
// {id, subject, description, activeForm, status, blocks, blockedBy}.
// Pre-2026-05 the layout was a single array file at <claudeDir>/todos/
// <session>-agent-<session>.json — that path is now dead and not consulted.
// Returns the activeForm string, or '' if no task is in_progress.
function getActiveTask(claudeDir, session) {
  if (!session) return '';
  const tasksDir = path.join(claudeDir, 'tasks', session);
  if (!fs.existsSync(tasksDir)) return '';
  try {
    for (const f of fs.readdirSync(tasksDir)) {
      if (!f.endsWith('.json')) continue;
      try {
        const t = JSON.parse(fs.readFileSync(path.join(tasksDir, f), 'utf8'));
        if (t && t.status === 'in_progress') return t.activeForm || '';
      } catch { /* malformed file — skip */ }
    }
  } catch { /* unreadable dir — fall through */ }
  return '';
}

// --- GSD state reader -------------------------------------------------------

/**
 * Walk up from dir looking for .planning/STATE.md.
 * Returns parsed state object or null.
 */
function readGsdState(dir) {
  const home = os.homedir();
  let current = dir;
  for (let i = 0; i < 10; i++) {
    const candidate = path.join(current, '.planning', 'STATE.md');
    if (fs.existsSync(candidate)) {
      try {
        const state = parseStateMd(fs.readFileSync(candidate, 'utf8'));
        // Prefer the sibling ROADMAP progress table for the milestone phase
        // count — the STATE progress: block (already parsed into `state`) is
        // orphan-prone and carries gsd-core's 999/ratchet bugs (see
        // parseRoadmapProgress). Override only on a successful table parse;
        // any miss (no ROADMAP, no table, unreadable) keeps the STATE-block
        // count, so table-less repos behave exactly as before.
        try {
          const roadmap = path.join(path.dirname(candidate), 'ROADMAP.md');
          if (fs.existsSync(roadmap)) {
            const rp = parseRoadmapProgress(fs.readFileSync(roadmap, 'utf8'), state.milestone);
            if (rp) {
              state.completedPhases = rp.completedPhases;
              state.totalPhases = rp.totalPhases;
            }
          }
        } catch (e) { /* ROADMAP unreadable/malformed — keep STATE-block count */ }
        refineDiscussStatus(state, path.dirname(candidate));
        return state;
      } catch (e) {
        return null;
      }
    }
    const parent = path.dirname(current);
    if (parent === current || current === home) break;
    current = parent;
  }
  return null;
}

/**
 * Downgrade `planning` to `discuss` when the current phase has no CONTEXT.md.
 *
 * dhx-side refinement: GSD's own vocabulary has no discuss stage — its
 * `planning` status is set at phase transition and spans everything from
 * "phase just transitioned" to "PLAN.md ready". dhx runs /dhx:discuss before
 * /gsd-plan-phase, and its canonical artifact is the phase's
 * phases/{N}-<slug>/{N}-CONTEXT.md. So `planning` with no CONTEXT.md means
 * the actionable next step is discuss, not plan.
 *
 * Existence check only — content is not validated (a partial CONTEXT.md
 * reads as discussed). An unscaffolded phase (no phases/{N}-<slug> dir) also
 * reads as discuss: discuss is the step that scaffolds it. Any FS error
 * keeps `planning` — the refinement never invents a state on bad reads.
 */
function refineDiscussStatus(state, planningDir) {
  if (state.status !== 'planning' || !state.phaseNum) return state;
  try {
    const phasesDir = path.join(planningDir, 'phases');
    const prefix = `${state.phaseNum}-`;
    const entry = fs.readdirSync(phasesDir).find(d => d.startsWith(prefix));
    const hasContext = !!entry && fs.readdirSync(path.join(phasesDir, entry))
      .some(f => f.endsWith('-CONTEXT.md') || f === 'CONTEXT.md');
    if (!hasContext) state.status = 'discuss';
  } catch (e) { /* phases/ absent or unreadable — keep planning */ }
  return state;
}

/**
 * Parse STATE.md frontmatter + Phase line from body.
 * Returns { status, milestone, milestoneName, phaseNum, phaseTotal, phaseName,
 *           completedPhases, totalPhases }
 */
function parseStateMd(content) {
  const state = {};

  // YAML frontmatter between --- markers
  // CRLF-tolerant fence: an LF-only `^---\n` drops the ENTIRE frontmatter on a
  // CRLF STATE.md (silent empty GSD segment). Mirrors the upstream gsd-core fix
  // (#2754/#2865) verbatim — see check-command-router.cjs / install-profiles.cjs.
  const fmMatch = content.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  if (fmMatch) {
    const fmBody = fmMatch[1];
    for (const line of fmBody.split('\n')) {
      const m = line.match(/^(\w+):\s*(.+)/);
      if (!m) continue;
      const [, key, val] = m;
      const v = val.trim().replace(/^["']|["']$/g, '');
      if (key === 'status') state.status = v === 'null' ? null : v;
      if (key === 'milestone') state.milestone = v === 'null' ? null : v;
      if (key === 'milestone_name') state.milestoneName = v === 'null' ? null : v;
    }
    // progress: block — nested YAML. Read completed_phases/total_phases from
    // indented lines beneath it. Ignore total_plans/completed_plans: phase
    // completion is the milestone denominator the user picked (7/10), not the
    // plan-level breakdown.
    const cp = fmBody.match(/^\s+completed_phases:\s*(\d+)/m);
    const tp = fmBody.match(/^\s+total_phases:\s*(\d+)/m);
    if (cp) state.completedPhases = parseInt(cp[1], 10);
    if (tp) state.totalPhases = parseInt(tp[1], 10);
  }

  // Phase line — three shapes observed in the wild:
  //   "Phase: 1 of 5 (name)"          — legacy GSD
  //   "Phase: 24.1 (name) — STATUS"   — current GSD (decimal phase, inline status)
  //   "Phase: none active (...)"      — placeholder when no phase is set
  // Single regex covers all three. The "of M" is optional; completion
  // count comes from the progress: block on line 2 regardless.
  const phaseMatch = content.match(/^Phase:\s*(\S+)(?:\s+of\s+(\d+))?(?:\s+\(([^)]+)\))?/m);
  if (phaseMatch && phaseMatch[1] !== 'none') {
    state.phaseNum = phaseMatch[1];
    state.phaseTotal = phaseMatch[2] || null;
    state.phaseName = phaseMatch[3] || null;
  }

  // Fallback: parse Status: from body when frontmatter is absent
  if (!state.status) {
    const bodyStatus = content.match(/^Status:\s*(.+)/m);
    if (bodyStatus) {
      const raw = bodyStatus[1].trim().toLowerCase();
      if (raw.includes('ready to plan') || raw.includes('planning')) state.status = 'planning';
      else if (raw.includes('execut')) state.status = 'executing';
      else if (raw.includes('complet') || raw.includes('archived')) state.status = 'complete';
    }
  }

  return state;
}

/**
 * Derive the active-milestone phase count from the ROADMAP progress table.
 * Returns { completedPhases, totalPhases } or null when no parseable table.
 *
 * Why prefer this over STATE.md's progress: block (see readGsdState): that
 * block is orphan-prone — only GSD's complete-phase/milestone.complete verb
 * writes it, so hand-completed phases leave it frozen — and it carries two
 * gsd-core bugs: it counts 999.x backlog rows into the total, and a
 * don't-regress ratchet cements a stale-high total. The ROADMAP progress
 * table is verb-/human-maintained and stays current.
 *
 * The table is NOT active-scoped on its own. Measured 2026-08-29 across the
 * 17 repos under ~/repos that carry one: 12 are whole-project tables of mixed
 * granularity — historical milestones collapsed to range rows (`| 52-60.1 |
 * v4.0 | 28/28 | Complete |`) alongside per-phase rows for the live one — and
 * the only thing separating them is a `Milestone` column. Counting every row
 * yields a fraction belonging to no milestone (sideline: 11/16). So when that
 * column is present the caller's active milestone is REQUIRED, and a table we
 * cannot scope is withheld (null → STATE fallback) rather than widened. The
 * remaining 5 tables have no Milestone column and are counted whole, exactly
 * as before.
 *
 * @param {string} content            ROADMAP.md text.
 * @param {string} [activeMilestone]  STATE frontmatter's `milestone:` value.
 *                                    Required whenever the table has a
 *                                    Milestone column; ignored when it doesn't.
 *
 * Mirrors gsd-core's deriveProgressFromRoadmap (phase-lifecycle.cjs), which
 * moved to name-based column lookup under ADR-2143 §3 — read by column NAME so
 * the parse is order- and injection-invariant. Deliberately NOT a require() of
 * that module: gsd-core is a separately-versioned tree and a hard dependency
 * would break the statusline on its upgrades (D-14 class). Two intentional
 * divergences from upstream: only `Phase` + `Status` are required (upstream
 * also demands `Plans Complete`, which is why its own derive returns null on
 * alembic, whose column is named `Plans`), and the sentinel exclusion is
 * applied at the table parse (upstream's derive omits it — the bug this
 * read-time fix references).
 */
function parseRoadmapProgress(content, activeMilestone) {
  if (typeof content !== 'string' || content === '') return null;

  // Locate the active progress table. If archived-milestone tables are also
  // present, anchor on the **Active milestone:** marker that precedes the live
  // one; otherwise take the first table.
  let scope = content;
  const activeIdx = content.search(/\*\*Active milestone:/i);
  if (activeIdx !== -1) scope = content.slice(activeIdx);
  const table = findProgressTable(scope) ||
                (scope === content ? null : findProgressTable(content));
  if (!table) return null;

  const { columns, rows } = table;
  const phaseAt = columns.indexOf('phase');
  const statusAt = columns.indexOf('status');
  const msAt = columns.indexOf('milestone');

  // Milestone scoping — load-bearing, not polish. Withhold rather than guess:
  // a Milestone column with no milestone to match it, or one matching no row,
  // returns null so the STATE block answers instead. Silently widening to the
  // unscoped count is the 11/16 failure by another route.
  let want = null;
  if (msAt !== -1) {
    want = (activeMilestone == null ? '' : String(activeMilestone)).trim().toLowerCase();
    if (want === '') return null;
  }

  // Sentinel backlog rows count toward neither numerator nor total. gsd-core's
  // canonical form is `isSentinelPhaseId` (bin/lib/phase-id.cjs), backed by
  // SENTINEL_RANGES = [0, 999]; this parser deliberately still excludes 999.x
  // only. Widening to admit phase 0 is a real behaviour change with no repo
  // affected today — tracked in .planning/backlog/, not smuggled in here.
  const isSentinel = (phase) => /^999(?:\.|\s|$)/.test(phase);

  let total = 0;
  let completed = 0;
  for (const cells of rows) {
    const phase = (cells[phaseAt] || '').trim();
    if (!/^\d/.test(phase)) continue;   // data row: phase cell starts with a number
    if (isSentinel(phase)) continue;
    if (msAt !== -1 && (cells[msAt] || '').trim().toLowerCase() !== want) continue;
    total++;
    if (/^Complete$/i.test((cells[statusAt] || '').trim())) completed++;
  }
  if (total === 0) return null;
  return { completedPhases: completed, totalPhases: total };
}

/**
 * Split a markdown table row into trimmed cells: `| a | b |` → ['a', 'b'].
 * The leading and trailing pipes are stripped first so the cell list carries
 * no phantom empties — that is what lets a name→index map built from the
 * header line index straight into every data row.
 */
function splitTableRow(line) {
  let s = line.trim();
  if (s.startsWith('|')) s = s.slice(1);
  if (s.endsWith('|')) s = s.slice(0, -1);
  return s.split('|').map((c) => c.trim());
}

/**
 * Locate the progress table and return { columns, rows } — `columns` being
 * lowercased/trimmed names, `rows` being cell arrays indexed the same way.
 *
 * Located by column NAME: the first table row whose cells include both `Phase`
 * and `Status` (case-insensitive), followed by a matching delimiter row. The
 * delimiter requirement is what keeps a prose row that happens to mention both
 * words from being read as a header.
 *
 * Returns null if no such table exists, or if any data row's cell count
 * disagrees with the header — an unescaped pipe shifts every cell after it, so
 * the honest answer there is "don't know", which falls back to STATE.
 */
function findProgressTable(text) {
  const isDelimiterCell = (c) => /^:?-{1,}:?$/.test(c);
  const lines = text.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const t = lines[i].trim();
    if (!t.startsWith('|') || t.indexOf('|', 1) === -1) continue;
    const columns = splitTableRow(lines[i]).map((c) => c.toLowerCase());
    if (columns.indexOf('phase') === -1 || columns.indexOf('status') === -1) continue;
    if (lines[i + 1] === undefined) continue;
    const delim = splitTableRow(lines[i + 1]);
    if (delim.length !== columns.length || !delim.every(isDelimiterCell)) continue;
    const rows = [];
    for (let j = i + 2; j < lines.length; j++) {
      if (!lines[j].trim().startsWith('|')) break;
      const cells = splitTableRow(lines[j]);
      if (cells.length !== columns.length) return null;
      rows.push(cells);
    }
    return { columns, rows };
  }
  return null;
}

// --- Line 2 assembly ---------------------------------------------------------

// Status short-form map + color accent. Fallback keeps unknown states
// visible (dim gray) rather than swallowing them.
const STATUS_RENDER = {
  executing: { short: 'exec', color: '\x1b[33m' },       // yellow — active
  discuss:   { short: 'disc', color: '\x1b[35m' },       // magenta — pre-shaping (no CONTEXT.md yet)
  planning:  { short: 'plan', color: '\x1b[36m' },       // cyan — shaping
  complete:  { short: 'done', color: '\x1b[32m' },       // green — settled
  archived:  { short: 'done', color: '\x1b[32m' },
};

// Build the GSD-state portion of line 2:
//   "v1.4 Research Orchestration… (7/10) · exec · 24.1 Hub Eviction…"
// Pieces join with ` · `. Returns '' when state has nothing worth showing.
function formatLine2Gsd(s) {
  if (!s) return '';
  const hasContent = s.milestone || s.milestoneName || s.phaseNum || s.status;
  if (!hasContent) return '';

  const parts = [];

  // Milestone group: version + completion. Milestone name dropped 2026-04-27
  // (quick task 260427-u89): the 20-char-capped truncation consistently
  // produced an ellipsis that added no diagnostic value at the cost of a
  // line-2 column the budget+context row needed. `truncate` and NAME_MAX stay
  // imported because phase name (line ~376) still uses them.
  const msPieces = [];
  if (s.milestone) msPieces.push(`\x1b[2m${s.milestone}\x1b[0m`);
  if (s.completedPhases != null && s.totalPhases != null) {
    // Color scales with completion: red at 0/N, dim 1–74%, dim-green 75–99%,
    // bright green at 100%. Signals trajectory at a glance.
    const pct = s.totalPhases > 0 ? s.completedPhases / s.totalPhases : 0;
    let color;
    if (s.completedPhases === 0) color = '\x1b[2;31m';
    else if (pct >= 1) color = '\x1b[32m';
    else if (pct >= 0.75) color = '\x1b[2;32m';
    else color = '\x1b[2m';
    msPieces.push(`${color}(${s.completedPhases}/${s.totalPhases})\x1b[0m`);
  }
  if (msPieces.length) parts.push(msPieces.join(' '));

  // Status — color-accented short form.
  if (s.status) {
    const render = STATUS_RENDER[s.status] || { short: s.status, color: '\x1b[2m' };
    parts.push(`${render.color}${render.short}\x1b[0m`);
  }

  // Phase group: bold phase number + truncated phase name.
  if (s.phaseNum) {
    const phasePieces = [`\x1b[1m${s.phaseNum}\x1b[0m`];
    if (s.phaseName) {
      phasePieces.push(`\x1b[2m${truncate(s.phaseName, NAME_MAX)}\x1b[0m`);
    }
    parts.push(phasePieces.join(' '));
  }

  return parts.join(' · ');
}

// Build the repo-signals portion of line 2: "R4·T2·B7".
// Classes with 0 count are omitted. Returns '' when all three are 0.
// Letter prefix chosen over color-only distinction so a colorblind user or
// a terminal without 256-color support can still read the classes.
function formatLine2Signals(signals) {
  const pieces = [];
  if (signals.reports > 0) pieces.push(`\x1b[31mR${signals.reports}\x1b[0m`);
  if (signals.todos > 0) pieces.push(`\x1b[33mT${signals.todos}\x1b[0m`);
  if (signals.backlog > 0) pieces.push(`\x1b[2;35mB${signals.backlog}\x1b[0m`);
  return pieces.join('·');
}

/**
 * Format GSD state into display string.
 * Format: "v1.9 Code Quality · executing · fix-graphiti-deployment (1/5)"
 * Gracefully degrades when parts are missing.
 */
function formatGsdState(s) {
  const parts = [];

  // Milestone: version + name (skip placeholder "milestone")
  if (s.milestone || s.milestoneName) {
    const ver = s.milestone || '';
    const name = (s.milestoneName && s.milestoneName !== 'milestone') ? s.milestoneName : '';
    const ms = [ver, name].filter(Boolean).join(' ');
    if (ms) parts.push(ms);
  }

  // Status
  if (s.status) parts.push(s.status);

  // Phase
  if (s.phaseNum && s.phaseTotal) {
    const phase = s.phaseName
      ? `${s.phaseName} (${s.phaseNum}/${s.phaseTotal})`
      : `ph ${s.phaseNum}/${s.phaseTotal}`;
    parts.push(phase);
  }

  return parts.join(' · ');
}

// --- stdin ------------------------------------------------------------------

function runStatusline() {
  let input = '';
  // Timeout guard: if stdin doesn't close within 3s (e.g. pipe issues on
  // Windows/Git Bash), exit silently instead of hanging. See #775.
  const stdinTimeout = setTimeout(() => process.exit(0), 3000);
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', chunk => input += chunk);
  process.stdin.on('end', () => {
  clearTimeout(stdinTimeout);
  try {
    const data = JSON.parse(input);
    const model = compactModel(data.model?.display_name);
    const ccsProfile = getCcsProfile();
    const dir = data.workspace?.current_dir || process.cwd();
    const session = data.session_id || '';
    const effort = renderEffort(data.effort?.level);
    const remaining = data.context_window?.remaining_percentage;

    // Context window display (shows USED percentage scaled to usable context)
    // Claude Code reserves a buffer for autocompact. By default this is ~16.5%
    // of the total window, but users can override it via CLAUDE_CODE_AUTO_COMPACT_WINDOW
    // (a token count). When the env var is set, compute the buffer % dynamically so
    // the meter correctly reflects early-compaction configurations (#2219).
    const totalCtx = data.context_window?.total_tokens || 1_000_000;
    const acw = parseInt(process.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW || '0', 10);
    const AUTO_COMPACT_BUFFER_PCT = acw > 0
      ? Math.min(100, (acw / totalCtx) * 100)
      : 16.5;
    let ctx = '';
    if (remaining != null) {
      // Normalize: subtract buffer from remaining, scale to usable range
      const usableRemaining = Math.max(0, ((remaining - AUTO_COMPACT_BUFFER_PCT) / (100 - AUTO_COMPACT_BUFFER_PCT)) * 100);
      const used = Math.max(0, Math.min(100, Math.round(100 - usableRemaining)));

      // Write context metrics to bridge file for the context-monitor PostToolUse hook.
      // The monitor reads this file to inject agent-facing warnings when context is low.
      // Reject session IDs with path separators or traversal sequences to prevent
      // a malicious session_id from writing files outside the temp directory.
      const sessionSafe = session && !/[/\\]|\.\./.test(session);
      if (sessionSafe) {
        try {
          const bridgePath = path.join(os.tmpdir(), `claude-ctx-${session}.json`);
          const bridgeData = JSON.stringify({
            session_id: session,
            remaining_percentage: remaining,
            used_pct: used,
            timestamp: Math.floor(Date.now() / 1000)
          });
          fs.writeFileSync(bridgePath, bridgeData);
        } catch (e) {
          // Silent fail -- bridge is best-effort, don't break statusline
        }
      }

      // Build progress bar (5 segments — each step = 20%).
      // Round rather than floor so 18% shows 1 bar instead of 0 — a 5-seg
      // floor would hide sub-20% usage entirely, which misleads more than
      // the 2-percentage-point overshoot rounding introduces.
      const filled = Math.min(5, Math.round(used / 20));
      const bar = '█'.repeat(filled) + '░'.repeat(5 - filled);

      // Color based on usable context thresholds
      if (used < 50) {
        ctx = ` \x1b[32m${bar} ${used}%\x1b[0m`;
      } else if (used < 65) {
        ctx = ` \x1b[33m${bar} ${used}%\x1b[0m`;
      } else if (used < 80) {
        ctx = ` \x1b[38;5;208m${bar} ${used}%\x1b[0m`;
      } else {
        ctx = ` \x1b[5;31m💀 ${bar} ${used}%\x1b[0m`;
      }
    }

    // Current task from CC's per-session task store. Layout migrated 2026-05:
    // <claudeDir>/tasks/<session>/<id>.json (one file per task), replacing the
    // single-array <claudeDir>/todos/<session>-agent-<session>.json. The legacy
    // path is no longer consulted — see getActiveTask() comment for details.
    const homeDir = os.homedir();
    // Respect CLAUDE_CONFIG_DIR for custom config directory setups (#870)
    const claudeDir = process.env.CLAUDE_CONFIG_DIR || path.join(homeDir, '.claude');
    const task = getActiveTask(claudeDir, session);

    // GSD state is assembled for line 2 (below). The legacy single-line
    // formatGsdState() is retained for the module export and unit tests but
    // is no longer rendered inline. Repo signals (R/T/B) moved out of the
    // renderer entirely on 2026-04-28: the wrapper imports formatLine2Signals
    // + getRepoSignals via require() and appends signals after git so the L1
    // tail reads cache → git → signals (live signals at the right edge).
    const gsdState = readGsdState(dir) || {};

    // GSD update available?
    // The gsd-core checker (gsd-check-update.js) writes a PACKAGE-NAMESPACED
    // cache filename derived from package-identity.cjs (e.g.
    // gsd-update-check-opengsd-gsd-core.json), NOT the legacy generic
    // gsd-update-check.json. Resolve the live name the same way the checker does
    // so a package rename (get-shit-done-cc → @opengsd/gsd-core, 2026-06-05)
    // can't strand the renderer on a stale wrong-package cache → false
    // ⬆ /gsd-update. INVARIANT: this filename MUST track the checker's
    // package-identity output (see docs/decisions.md 2026-06-05 gsd-update cache
    // row + probe-gsd-update-cache-name-resolves.js). package-identity sits under
    // <gsd-core>/bin/lib and is required by ABSOLUTE path — the renderer's
    // realpath is the repo, not ~/.claude, so a relative require can't reach it.
    // require failure → legacy generic name (degrades, never throws — fail-open;
    // missing cache hides the segment, D-13a).
    let gsdUpdate = '';
    let updateCacheName = 'gsd-update-check.json';
    try {
      const piRel = path.join('gsd-core', 'bin', 'lib', 'package-identity.cjs');
      const piPath = fs.existsSync(path.join(claudeDir, piRel))
        ? path.join(claudeDir, piRel)
        : path.join(homeDir, '.claude', piRel);
      const pi = require(piPath);
      if (pi && pi.updateCacheFileName) updateCacheName = pi.updateCacheFileName;
    } catch (e) { /* package-identity unresolved → legacy generic name */ }
    const sharedCacheFile = path.join(homeDir, '.cache', 'gsd', updateCacheName);
    const legacyCacheFile = path.join(claudeDir, 'cache', updateCacheName);
    const cacheFile = fs.existsSync(sharedCacheFile) ? sharedCacheFile : legacyCacheFile;
    if (fs.existsSync(cacheFile)) {
      try {
        const cache = JSON.parse(fs.readFileSync(cacheFile, 'utf8'));
        if (cache.update_available) {
          gsdUpdate = '\x1b[33m⬆ /gsd-update\x1b[0m │ ';
        }
        if (cache.stale_hooks && cache.stale_hooks.length > 0) {
          // If installed version is ahead of npm latest, this is a dev install.
          // Running /gsd-update would downgrade — show a contextual warning instead.
          const isDevInstall = (() => {
            if (!cache.installed || !cache.latest || cache.latest === 'unknown') return false;
            // Normalize missing segments to 0 (WR-02 shape): without this a
            // 2-segment version destructures its third segment to undefined and
            // the tie-break `ci > cn` (undefined > n) is false — a real patch
            // difference would misreport. Mirrors the cc-update comparator fix.
            const parseV = v => {
              const p = v.replace(/^v/, '').split('.').map(Number);
              return [p[0] || 0, p[1] || 0, p[2] || 0];
            };
            const [ai, bi, ci] = parseV(cache.installed);
            const [an, bn, cn] = parseV(cache.latest);
            return ai > an || (ai === an && bi > bn) || (ai === an && bi === bn && ci > cn);
          })();
          if (isDevInstall) {
            gsdUpdate += '\x1b[33m⚠ dev install — re-run installer to sync hooks\x1b[0m │ ';
          } else {
            gsdUpdate += '\x1b[31m⚠ stale hooks — run /gsd-update\x1b[0m │ ';
          }
        }
      } catch (e) {}
    }

    // --- RAT-04: cc-novel novel-pattern segment (render-time re-filter) ------
    // Reads ~/.cache/dhx/cc-novel-patterns.json (written once per CC version
    // cohort by statusline-wrapper.js's enumeration — Plan 01) and re-applies
    // the shared isAllowlisted predicate to every novel_patterns entry AT
    // RENDER TIME (D-14). Two filters stack: enumeration writes the post-
    // allowlist novel set to the cache; the renderer re-filters against the
    // CURRENT allowlist on top. This is what makes D-13a's contract real —
    // when the operator widens the allowlist mid-cohort, the stale cache
    // survives, but the next ~1Hz refresh re-filters it and the `⚠ cc-novel`
    // warning clears with no re-enumeration. The segment renders iff the
    // post-re-filter surviving count > 0. The re-filter is PURE ARRAY WORK
    // (no fs, no subprocess) so STATUS-06 / D-12 hold. Malformed/missing
    // cache → segment hides (D-13a — mirrors the gsdUpdate block).
    let ccNovel = '';
    const novelFile = path.join(homeDir, '.cache', 'dhx', 'cc-novel-patterns.json');
    if (fs.existsSync(novelFile)) {
      try {
        const c = JSON.parse(fs.readFileSync(novelFile, 'utf8'));
        if (Array.isArray(c.novel_patterns)) {
          let surviving = c.novel_patterns.length;
          // Re-filter against the CURRENT allowlist (D-14) when the shared
          // module loaded. If the module is absent, fall back to the bare
          // cache count — detector degrades to "shows the cohort warning",
          // never to a crash.
          if (pluginCacheAllowlist && typeof pluginCacheAllowlist.isAllowlisted === 'function') {
            surviving = c.novel_patterns.filter(
              (e) => e && !pluginCacheAllowlist.isAllowlisted(e.path, e.basename)
            ).length;
          }
          if (surviving > 0) {
            ccNovel = '\x1b[33m⚠ cc-novel\x1b[0m \x1b[2m│\x1b[0m ';
          }
        }
      } catch (e) {}
    }

    // --- RAT-06: cc-update segment + dev-install branch ---------------------
    // Reads ~/.cache/cc/cc-update-check.json ({latest, checked_at,
    // installed_at_check} — Plan 02 + RAT-06b) and COMPUTES update_available
    // renderer-side (D-08): the cache carries `latest`; the installed version
    // is the stdin `data.version` the renderer already has free. parseV strips
    // a prerelease/build suffix (`.split('-')[0]`) before the numeric compare
    // (D-16) so a canary `latest` does not produce NaN — the dev-install
    // compare degrades to a base-version compare on canary builds (documented,
    // acceptable).
    //   latest base > installed base        → `⬆ cc`
    //   installed base > max_published base  → `⚠ cc dev install` (RAT-06b + RAT-06c guarded)
    //   equal / 'unknown' / null             → neither
    // Malformed/missing cache → segment hides (D-13a).
    //
    // RAT-06b dev-install guard: `installed base > latest base` is a FALSE
    // POSITIVE when the CC auto-updater bumped the installed binary past the
    // cache's `latest` WITHIN the parent's ~6h TTL window (the cache still
    // names the OLDER latest it last checked). The fix: only fire dev-install
    // when `cache.installed_at_check` matches the running `data.version` — i.e.
    // npm `latest` was confirmed against THIS binary, not a since-replaced one.
    // installed_at_check ABSENT (old cache schema / worker probe failed) → fall
    // back to the prior unguarded fire (status-quo, backward-compatible).
    // INVARIANT (cross-process): cc-check-update-worker.js stamps
    // installed_at_check (from `claude --version`) and max_published (the
    // semver-max of `npm view … versions`) to the same bare shape as stdin
    // `data.version`; this read assumes that shape match. Asserted by
    // tests/probes/probe-cc-check-update-worker.sh + probe-statusline-load.js
    // Scenarios 10-15.
    let ccUpdate = '';
    const ccUpdateFile = path.join(homeDir, '.cache', 'cc', 'cc-update-check.json');
    if (fs.existsSync(ccUpdateFile)) {
      try {
        const cache = JSON.parse(fs.readFileSync(ccUpdateFile, 'utf8'));
        const installed = data.version;
        if (installed && cache.latest && cache.latest !== 'unknown') {
          // D-16: strip the prerelease/build suffix before the numeric split.
          // Normalize missing segments to 0 (WR-02): a 2-segment version
          // ("2.1") would otherwise destructure its third segment to
          // `undefined`, and the tie-break `cn > ci` (e.g. `1 > undefined`)
          // is false — so installed "2.1" vs latest "2.1.1" would report NO
          // `⬆ cc` even though an update exists. CC versions are consistently
          // 3-segment so this is latent, but the comparator is written to be
          // defensive against arbitrary `latest` strings from `npm view`.
          const parseV = (v) => {
            const p = v.replace(/^v/, '').split('-')[0].split('.').map(Number);
            return [p[0] || 0, p[1] || 0, p[2] || 0];
          };
          const [ai, bi, ci] = parseV(installed);
          const [an, bn, cn] = parseV(cache.latest);
          const latestNewer =
            an > ai || (an === ai && bn > bi) || (an === ai && bn === bi && cn > ci);
          // RAT-06c: the dev-install reference is `max_published` (the SEMVER-MAX
          // of every published version, stamped by the worker), NOT the `latest`
          // dist-tag. npm moves `latest` separately from (and hours after)
          // publishing a version, and CC auto-updates from a faster channel — so
          // a normally-published binary reads as `installed > latest` for the
          // duration of that lag and false-fired `⚠ cc dev install` across every
          // session. Comparing against max_published flags only a build npm has
          // never published (a genuine dev/canary). Fall back to cache.latest
          // when max_published is absent (pre-RAT-06c cache schema) or 'unknown'
          // — the latter guarded explicitly because parseV('unknown') is [0,0,0],
          // which would make any installed version look "ahead".
          const devRef = (cache.max_published && cache.max_published !== 'unknown')
            ? cache.max_published : cache.latest;
          const [am, bm, cm] = parseV(devRef);
          const installedNewer =
            ai > am || (ai === am && bi > bm) || (ai === am && bi === bm && ci > cm);
          // RAT-06b: was npm `latest` confirmed against the binary running NOW?
          // Absent stamp → fall back to firing (status-quo). Present → require a
          // base-version match (parseV both sides so a canary suffix on either
          // doesn't spuriously break the equality).
          let confirmedAhead = true;
          if (cache.installed_at_check) {
            const [ka, kb, kc] = parseV(cache.installed_at_check);
            confirmedAhead = ai === ka && bi === kb && ci === kc;
          }
          if (latestNewer) {
            ccUpdate = '\x1b[33m⬆ cc\x1b[0m \x1b[2m│\x1b[0m ';
          } else if (installedNewer && confirmedAhead) {
            ccUpdate = '\x1b[33m⚠ cc dev install\x1b[0m \x1b[2m│\x1b[0m ';
          }
        }
      } catch (e) {}
    }

    // --- RAT-06: cc-autoupd auto-update-suppression segment (D-09) -----------
    // A single process.env read — zero subprocess, no cache, no hook. Glyph is
    // `⚠` (U+26A0, BMP single-width) — NOT the U+1F6AB no-entry sign, which is
    // a double-width SMP emoji (RESEARCH Pitfall 3: width bug + status-symbol-
    // set inconsistency — the repo's warning vocabulary is `⚠`/`⬆`).
    let ccAutoupd = process.env.DISABLE_AUTOUPDATER === '1'
      ? '\x1b[33m⚠ cc-autoupd\x1b[0m \x1b[2m│\x1b[0m '
      : '';

    // --- cc-warning snooze: collapse the cc version-drift cluster ------------
    // When `/dhx:statusline snooze cc <dur>` is active, the three cc version
    // segments above (⬆ cc, ⚠ cc dev install, ⚠ cc-autoupd) collapse into ONE
    // DIM countdown token instead of vanishing — a quiet reminder that the
    // (deliberately-chosen, e.g. post-rollback) cc state still exists, plus the
    // time until it auto-reverts to the bright warning. Renders only when the
    // cluster WOULD have shown something; an all-clear cc state stays silent.
    // FAIL-OPEN: any module/read error leaves the bright warnings intact (a
    // snooze must never silently hide a real signal on a bug). Scope is the
    // version cluster ONLY — ⚠ cc-novel (RAT-04 plugin-pattern detector) is
    // untouched. See scripts/lib/cc-snooze.js + docs/statusline-wrapper.md.
    if (ccSnooze && (ccUpdate || ccAutoupd)) {
      try {
        const snz = ccSnooze.snoozeState('cc');
        if (snz.active) {
          const rem = ccSnooze.formatRemaining(snz);
          ccUpdate = `\x1b[2m⚠ cc ${rem}\x1b[0m \x1b[2m│\x1b[0m `;
          ccAutoupd = '';
        }
      } catch (e) { /* fail-open: leave the bright cc warnings as-is */ }
    }

    // --- Line 1: model + CCS + [task |] dir + ctx ---
    // The wrapper appends cache, git, and repo signals (R/T/B) after this
    // base — see statusline-wrapper.js for the L1 tail order. Renderer
    // emits ONLY model/ctx so the wrapper owns the live-signal cluster
    // (cache/git/signals) at the right edge.
    const dirname = path.basename(dir);
    // CCS profile letter — dim yellow, slight accent so active profile is
    // visible without overpowering the dim model name it sits next to.
    const profileSegment = ccsProfile ? ` \x1b[2;33m${ccsProfile}\x1b[0m` : '';
    // Active todo task bubbles to line 1 (bold) so the "what am I doing?"
    // signal stays where the eye lands first. Line 2 carries GSD state only.
    const taskSegment = task ? ` \x1b[1m${task}\x1b[0m │` : '';
    // Effort glyph sits after the model, separated by a space so the two
    // segments don't visually merge. Hidden when the stdin payload omits
    // effort.level (e.g. a CC version or session state that doesn't emit it).
    const effortSeg = effort ? ` ${effort}` : '';

    // RAT-04/RAT-06 segments sit adjacent to gsdUpdate at the line-1 head
    // (cache/env signals cluster together where the operator's eye lands).
    const line1 = `${gsdUpdate}${ccUpdate}${ccAutoupd}${ccNovel}\x1b[2m${model}\x1b[0m${effortSeg}${profileSegment} │${taskSegment} \x1b[2m${dirname}\x1b[0m${ctx}`;

    // --- Line 2: GSD state (conditional) ---
    // Gate: any of milestone/phase/status present. ccburn prepends to this
    // line in statusline-wrapper.js. Filter+join preserved so an empty
    // gsdLine2 still produces empty line2 (the wrapper's burnOutput-prepend
    // then decides whether line 2 emits).
    const gsdLine2 = formatLine2Gsd(gsdState);
    const line2Pieces = [gsdLine2].filter(Boolean);
    const line2 = line2Pieces.length ? line2Pieces.join(' \x1b[2m│\x1b[0m ') : '';

    process.stdout.write(line2 ? `${line1}\n${line2}` : line1);
  } catch (e) {
    // Silent fail - don't break statusline on parse errors
  }
});
}

// Export helpers for unit tests. Harmless when run as a script.
module.exports = {
  readGsdState, parseStateMd, parseRoadmapProgress, formatGsdState,
  refineDiscussStatus,
  compactModel, getCcsProfile,
  renderEffort,
  EFFORT_RENDER,
  truncate, findRepoRoot, getRepoSignals,
  getActiveTask,
  formatLine2Gsd, formatLine2Signals,
};

if (require.main === module) runStatusline();
