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

// --- Model + CCS identity ----------------------------------------------------

// Compact display_name to "<lowercase-letter><version>[+]".
//   "Opus 4.7 (1M context)" → "o4.7+"
//   "Opus 4.7"              → "o4.7"
//   "Sonnet 4.6"            → "s4.6"
//   "Haiku 4.5"             → "h4.5"
// Lowercase reads quieter next to the dim model color; `+` replaces "(1M)"
// so the segment stays 5 chars vs the old 10-13. Unrecognized shapes pass
// through verbatim so we never hide the identity on a new model ship.
function compactModel(displayName) {
  if (!displayName) return 'Claude';
  const m = displayName.match(/^(Opus|Sonnet|Haiku)\s+([\d.]+)/);
  if (!m) return displayName;
  const has1M = /\(1M context\)/.test(displayName);
  return `${m[1][0].toLowerCase()}${m[2]}${has1M ? '+' : ''}`;
}

// Effort level → colored braille-density glyph (set B from menu: both-column
// bottom-up fill). Read from settings.json's effortLevel key; CC updates
// this atomically on /effort so the next refresh reflects the change.
// effortLevel is session-safe (NOT in WARN set) so changes don't trip drift.
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
// pending/ for active with done/ + completed/ as archived siblings.
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
        return parseStateMd(fs.readFileSync(candidate, 'utf8'));
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
 * Parse STATE.md frontmatter + Phase line from body.
 * Returns { status, milestone, milestoneName, phaseNum, phaseTotal, phaseName,
 *           completedPhases, totalPhases }
 */
function parseStateMd(content) {
  const state = {};

  // YAML frontmatter between --- markers
  const fmMatch = content.match(/^---\n([\s\S]*?)\n---/);
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

// --- Line 2 assembly ---------------------------------------------------------

// Status short-form map + color accent. Fallback keeps unknown states
// visible (dim gray) rather than swallowing them.
const STATUS_RENDER = {
  executing: { short: 'exec', color: '\x1b[33m' },       // yellow — active
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
    // Check shared cache first (#1421), fall back to runtime-specific cache for
    // backward compatibility with older gsd-check-update.js versions.
    let gsdUpdate = '';
    const sharedCacheFile = path.join(homeDir, '.cache', 'gsd', 'gsd-update-check.json');
    const legacyCacheFile = path.join(claudeDir, 'cache', 'gsd-update-check.json');
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
    // Reads ~/.cache/cc/cc-update-check.json ({latest, checked_at} — Plan 02)
    // and COMPUTES update_available renderer-side (D-08): the cache carries
    // only `latest`; the installed version is the stdin `data.version` the
    // renderer already has free. parseV strips a prerelease/build suffix
    // (`.split('-')[0]`) before the numeric compare (D-16) so a canary
    // `latest` does not produce NaN — the dev-install compare degrades to a
    // base-version compare on canary builds (documented, acceptable).
    //   latest base > installed base → `⬆ cc`
    //   installed base > latest base → `⚠ cc dev install`
    //   equal / 'unknown' / null      → neither
    // Malformed/missing cache → segment hides (D-13a).
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
          const installedNewer =
            ai > an || (ai === an && bi > bn) || (ai === an && bi === bn && ci > cn);
          if (latestNewer) {
            ccUpdate = '\x1b[33m⬆ cc\x1b[0m \x1b[2m│\x1b[0m ';
          } else if (installedNewer) {
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
    const ccAutoupd = process.env.DISABLE_AUTOUPDATER === '1'
      ? '\x1b[33m⚠ cc-autoupd\x1b[0m \x1b[2m│\x1b[0m '
      : '';

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
    // segments don't visually merge. Hidden when settings.json has no
    // effortLevel (e.g. CCS instance swap before first /effort).
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
  readGsdState, parseStateMd, formatGsdState,
  compactModel, getCcsProfile,
  renderEffort,
  EFFORT_RENDER,
  truncate, findRepoRoot, getRepoSignals,
  getActiveTask,
  formatLine2Gsd, formatLine2Signals,
};

if (require.main === module) runStatusline();
