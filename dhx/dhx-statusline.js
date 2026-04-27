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

const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFileSync } = require('child_process');

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

// Known effort-level strings. Rejects random word matches from user chat
// that happen to fit the "with X effort" regex — only CC-generated effort
// strings pass. New levels CC adds in the future must be added here to
// render; until then they silently fall through to empty (honest).
const KNOWN_EFFORT_LEVELS = new Set(['low', 'medium', 'high', 'xhigh', 'max']);

// Extract the most recent effort-level from CC's own pane output. Matches:
//   "Opus 4.7 (1M context) with xhigh effort · Claude Max"    — session banner
//   "✻ Simmering… (13m · ↓ 3.7k tokens · thinking with xhigh effort)" — spinner
// Either of those persists in scrollback — banner prints on
// startup/resume/clear, thinking spinner leaves its final line when the turn
// settles. Bottom-up scan returns the most-recent mention; after Alt+P the
// glyph lags until the next thinking-capable turn writes a new marker.
//
// Regex is two alternatives joined with `|` so one scan covers both lines.
// Each alternative requires BOTH a CC-specific prefix AND an end-of-line
// anchor to reject scrollback that quotes these strings — source diffs,
// doc edits containing code like `"thinking with max effort)'"`, chat
// transcripts echoed back. Real CC output has a fixed visual prefix; any
// quoting of that text in pane scrollback comes with leading indent +
// diff markers + line numbers instead.
//   - Banner:   `▝▜█████▛▘  Opus 4.7 (1M) with xhigh effort · Claude Max`
//                splash-logo prefix + ends at "Claude Max"
//   - Spinner:  `✻ Simmering… (1m · ↓ 339 tokens · thinking with max effort)`
//                CC-rotation spinner glyph at line start + ends at `)`
//
// Spinner glyph whitelist derived from observed CC output across 14 live
// panes: ✻ ✽ · ✶ ✢ ✸ * ⏵ ◉ ◐ ◈ ◆ ♦. If CC adds new rotation glyphs,
// spinner matches degrade to the banner fallback (still correct at session
// start / resume / clear). Whitelist update is a one-line change.
const PANE_EFFORT_RE =
  /(?:▝▜█████▛▘.*with (\w+) effort\s+\S\s+Claude Max\s*$|(?:^|\s)[✻✽·✶✢✸⏵*◉◐◈◆♦]\s.*?thinking with (\w+) effort\)\s*$)/;

function parsePaneEffort(paneText) {
  if (!paneText) return null;
  const lines = paneText.split('\n');
  for (let i = lines.length - 1; i >= 0; i--) {
    const m = lines[i].match(PANE_EFFORT_RE);
    if (m) {
      const level = m[1] || m[2];
      if (KNOWN_EFFORT_LEVELS.has(level)) return level;
    }
  }
  return null;
}

// Read the current session's effort from tmux pane scrollback. This is the
// only per-session surface we've found in CC 2.1.112 — settings.json is
// shared (multiple sessions overwrite each other) and the statusline stdin
// JSON has no effort field (confirmed via 379-refresh live probe across 5+
// sessions, plus 8+ open GH issues asking for one).
//
// Returns null when:
//   - not running inside tmux (TMUX_PANE unset)
//   - tmux binary missing or capture-pane call fails
//   - no banner or thinking line in the captured window
// All failure modes hide the glyph silently — honest > wrong.
//
// `-S -500 -E -` captures the last 500 lines of scrollback+viewport.
// Sized empirically: a heavy session (94k-line scrollback) observed in
// live probe pushed banner + last real thinking-with-effort line ~400
// lines above the viewport bottom — 200 missed them, 500 catches them
// comfortably. Still well inside one-read budget (~15ms vs ~40ms for
// full scrollback). 500ms timeout absorbs pathological tmux server
// slowness without blocking the renderer indefinitely.
//
// Cache layer (added 2026-04-26 after tmux-server wedge incident — see
// statusline capture-pane wedge incident class). Per-session file
// at /tmp/claude-effort-${sessionId} with 30s TTL. The renderer fires per-
// refresh × N concurrent sessions; the 500ms client-side timeout bounds
// renderer wait but NOT server-side load — by the time it fires the request
// has already queued in tmux's epoll set. Cache drops aggregate IPC ~93%
// in steady state. Glyph lags up to 30s after /effort (Alt+P) — acceptable
// because effort changes are uncommon. Future P3 (hook-driven invalidation)
// restores per-turn freshness without polling.
function getEffortFromPane(sessionId) {
  const pane = process.env.TMUX_PANE;
  if (!pane) return null;

  // Sanitize session_id. Mirrors the context-bridge fence-post in
  // runStatusline (~L420). Three states:
  //   - unset/empty (caller had no session_id)  → cache disabled, live capture still runs
  //   - non-empty + safe (normal CC UUID)        → cache enabled
  //   - non-empty + unsafe (path sep or `..`)    → reject outright (return null,
  //                                                no tmux call, no cache touch)
  // The reject branch is hardening: a malicious id should not get a free
  // tmux IPC call as a side effect of "cache lookup failed".
  const hasSession = sessionId != null && sessionId !== '';
  const sessionSafe = hasSession && !/[/\\]|\.\./.test(sessionId);
  if (hasSession && !sessionSafe) return null;

  const cachePath = sessionSafe
    ? path.join(os.tmpdir(), `claude-effort-${sessionId}`)
    : null;
  const CACHE_TTL_MS = 30_000;

  if (cachePath) {
    try {
      const stat = fs.statSync(cachePath);
      if (Date.now() - stat.mtimeMs < CACHE_TTL_MS) {
        const cached = fs.readFileSync(cachePath, 'utf8').trim();
        if (KNOWN_EFFORT_LEVELS.has(cached)) return cached;
      }
    } catch { /* cache miss — fall through to live capture */ }
  }

  let effort = null;
  try {
    const out = execFileSync(
      'tmux',
      ['capture-pane', '-p', '-S', '-500', '-E', '-', '-t', pane],
      { encoding: 'utf8', timeout: 500, stdio: ['ignore', 'pipe', 'ignore'] },
    );
    effort = parsePaneEffort(out);
  } catch {
    return null;
  }

  // Write-through on success only. Failed reads (effort === null) must NOT
  // pollute the cache — they'd mask a real value already on disk and pin
  // the segment to "hidden" until the next live recapture succeeds.
  if (effort && cachePath) {
    try { fs.writeFileSync(cachePath, effort); } catch { /* best-effort */ }
  }
  return effort;
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

// Count open repo signals: reports/*.md (non-done), .planning/todos/*.md,
// .planning/backlog/*.md. Each class contributes an integer; 0 for absent
// dirs. Zero-count classes render nothing on line 2, so empty repos pay
// nothing for this read.
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
  for (const [name, subdir] of [['todos', '.planning/todos'], ['backlog', '.planning/backlog']]) {
    try {
      const full = path.join(root, subdir);
      if (fs.existsSync(full)) {
        counts[name] = fs.readdirSync(full).filter(f => f.endsWith('.md')).length;
      }
    } catch { /* unreadable — leave 0 */ }
  }
  return counts;
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

  // Milestone group: version + truncated name + completion.
  const msPieces = [];
  if (s.milestone) msPieces.push(`\x1b[2m${s.milestone}\x1b[0m`);
  if (s.milestoneName && s.milestoneName !== 'milestone') {
    msPieces.push(`\x1b[2m${truncate(s.milestoneName, NAME_MAX)}\x1b[0m`);
  }
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
    const effort = renderEffort(getEffortFromPane(session));
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

    // Current task from todos
    let task = '';
    const homeDir = os.homedir();
    // Respect CLAUDE_CONFIG_DIR for custom config directory setups (#870)
    const claudeDir = process.env.CLAUDE_CONFIG_DIR || path.join(homeDir, '.claude');
    const todosDir = path.join(claudeDir, 'todos');
    if (session && fs.existsSync(todosDir)) {
      try {
        const files = fs.readdirSync(todosDir)
          .filter(f => f.startsWith(session) && f.includes('-agent-') && f.endsWith('.json'))
          .map(f => ({ name: f, mtime: fs.statSync(path.join(todosDir, f)).mtime }))
          .sort((a, b) => b.mtime - a.mtime);

        if (files.length > 0) {
          try {
            const todos = JSON.parse(fs.readFileSync(path.join(todosDir, files[0].name), 'utf8'));
            const inProgress = todos.find(t => t.status === 'in_progress');
            if (inProgress) task = inProgress.activeForm || '';
          } catch (e) {}
        }
      } catch (e) {
        // Silently fail on file system errors - don't break statusline
      }
    }

    // GSD state + repo signals are assembled for line 2 (below). The legacy
    // single-line formatGsdState() is retained for the module export and
    // unit tests, but is no longer rendered inline — its information now
    // lives on line 2 next to repo signals.
    const gsdState = readGsdState(dir) || {};
    const repoSignals = getRepoSignals(dir);

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
            const parseV = v => v.replace(/^v/, '').split('.').map(Number);
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

    // --- Line 1: model + CCS + [task |] dir + ctx ---
    const dirname = path.basename(dir);
    // CCS profile letter — dim yellow, slight accent so active profile is
    // visible without overpowering the dim model name it sits next to.
    const profileSegment = ccsProfile ? ` \x1b[2;33m${ccsProfile}\x1b[0m` : '';
    // Active todo task bubbles to line 1 (bold) so the "what am I doing?"
    // signal stays where the eye lands first. Line 2 carries GSD+signals.
    const taskSegment = task ? ` \x1b[1m${task}\x1b[0m │` : '';
    // Effort glyph sits after the model, separated by a space so the two
    // segments don't visually merge. Hidden when settings.json has no
    // effortLevel (e.g. CCS instance swap before first /effort).
    const effortSeg = effort ? ` ${effort}` : '';
    const line1 = `${gsdUpdate}\x1b[2m${model}\x1b[0m${effortSeg}${profileSegment} │${taskSegment} \x1b[2m${dirname}\x1b[0m${ctx}`;

    // --- Line 2: GSD state │ repo signals (conditional) ---
    // Gate: any of milestone/phase/status present OR any repo signal > 0.
    // Separator between the two groups is a pipe, matching the existing
    // line-1 convention (pipes between groups, dots within a group).
    const gsdLine2 = formatLine2Gsd(gsdState);
    const signalsLine2 = formatLine2Signals(repoSignals);
    const line2Pieces = [gsdLine2, signalsLine2].filter(Boolean);
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
  renderEffort, getEffortFromPane, parsePaneEffort,
  EFFORT_RENDER, KNOWN_EFFORT_LEVELS,
  truncate, findRepoRoot, getRepoSignals,
  formatLine2Gsd, formatLine2Signals,
};

if (require.main === module) runStatusline();
