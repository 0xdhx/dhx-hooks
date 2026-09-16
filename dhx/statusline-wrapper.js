#!/usr/bin/env node
// gsd-hook-version: 1.14.0
//   ^ MIRRORS live gsd-core VERSION (~/.claude/gsd-core/VERSION) — do NOT hand-bump
//     on wrapper edits. Only /dhx:sym gsd-update (step 9) sets this; it is a
//     reconciliation-lineage stamp, NOT a wrapper-content version. A hand-bump
//     overshoots the real gsd-core line (1.4.6 overshot live 1.4.5, 2026-06-15).
//     Guard: tests/probes/probe-gsd-hook-version-mirrors-runtime.sh
// Patterns: HP-013, HP-014, HP-016, HP-019, HP-025, HP-026, HP-031, HP-032, HP-034, HP-053, HP-054, HP-056
// Statusline wrapper — pipes stdin through dhx-statusline.js, appends git/cache/burn.
// Previously delegated to gsd-statusline.js; switched 2026-04-18 to dhx-owned renderer
// so dhx-specific segments (compact model, CCS letter, conditional line 2, repo signals)
// can evolve without coupling to /gsd-update's install path.

const { execFile, spawn } = require('child_process');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const os = require('os');

// Resolve renderer via ~/.claude/hooks/ (not __dirname, which follows symlinks)
const STATUSLINE_SCRIPT = path.join(os.homedir(), '.claude', 'hooks', 'dhx-statusline.js');

// Repo-signals (R/T/B) computation moved out of the renderer on 2026-04-28 so
// the wrapper can place signals AFTER cache/git on line 1 (live-signal cluster
// reads cache → git → signals left-to-right). require()ing the renderer module
// is safe — its top-level runStatusline() is gated by `require.main === module`.
const { getRepoSignals, formatLine2Signals } = require(STATUSLINE_SCRIPT);

// Gate top-level stdin wiring on direct invocation so probe-harness
// require()s don't hang waiting for stdin to close.
if (require.main === module) runMain();

function runMain() {
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => input += chunk);
process.stdin.on('end', () => {
  // PROBE-01 capture branch (D-16) — file-gated; no-op when ${XDG_RUNTIME_DIR:-/tmp}/dhx-statusline-stdin-probe absent.
  // Run-id propagation channel: flag file content (env var doesn't reach this sibling subprocess from the probe's bash).
  const probeDir = (process.env.XDG_RUNTIME_DIR || '/tmp') + '/dhx-statusline-stdin-probe';
  const flagPath = probeDir + '/flag';
  if (fs.existsSync(flagPath)) {
    try {
      let runId = 'latest';
      try { const c = fs.readFileSync(flagPath, 'utf8').trim(); if (c) runId = c; } catch { /* fall back to latest */ }
      const captureFile = probeDir + '/capture-' + runId + '.json';
      fs.writeFileSync(captureFile, input);
    } catch { /* probe-only */ }
  }

  let data = {};
  let cwd;
  try {
    data = JSON.parse(input);
    cwd = data.workspace?.current_dir || process.cwd();
  } catch {
    cwd = process.cwd();
  }

  // ONE bounded transcript-tail parse per refresh (arc N7, f30) — shared by the
  // cache-TTL segment, the bust classifier, and the telemetry writers. Sync +
  // fail-soft: a parse error yields null (segment hides, telemetry skips).
  let transcriptTail = null;
  try {
    if (data.transcript_path) transcriptTail = parseTranscriptTail(data.transcript_path);
  } catch { transcriptTail = null; }

  // Telemetry writes happen BEFORE the async render fan-out: statusline
  // processes are cancellation-prone and an event lost mid-render is a gap in
  // the spool. Sync, advance-gated (at most one write per completed API call),
  // fail-soft via the statusline error log — never blocks the render.
  try {
    recordCacheTelemetry(data, transcriptTail);
  } catch (e) {
    appendStatuslineError({
      ts: new Date().toISOString(),
      segment: 'cacheTelemetry',
      error_message: String((e && e.message) || e),
      error_stack_first_line: ((e && e.stack) || '').split('\n')[0],
      cwd,
    });
  }

  // Run the dhx renderer, git info, cache-age, ccburn, health cache, and drift check in parallel.
  // ccburn renders synchronously from the stdin rate_limits payload — no subprocess (2026-05-29).
  // Each branch is wrapped via withSegmentDiag so a thrown exception in any one
  // segment yields a red `⚠ <segment>?` sigil + a JSONL log line instead of
  // collapsing the entire statusline to silent empty (2026-04-26 #4 self-diag).
  Promise.all([
    withSegmentDiag('renderer',   runRenderer(input)),
    withSegmentDiag('git',        getGitInfo(cwd)),
    withSegmentDiag('cacheAge',   getCacheAge(data, transcriptTail)),
    withSegmentDiag('ccburn',     buildCcburnFromStdin(input)),
    withSegmentDiag('firstPrompt', getFirstUserPrompt(data)),
    withSegmentDiag('health',     readHealthCache(data && data.session_id)),
    withSegmentDiag('drift',      checkDrift(data)),
    withSegmentDiag('fleet',      readFleetFeed()),
    withSegmentDiag('watch',      readWatchHealth()),
    withSegmentDiag('skillPressure', readSkillPressure()),  // D-01/D-02/D-03: fail-silent, not sigil-generating
    withSegmentDiag('wslPressure',   readWslPressure()),    // wsl-pressure cadence alarm: fail-silent, not sigil-generating
    withSegmentDiag('wslProbeBroken', readWslProbeBroken()), // wsl-pressure PROBE-BROKEN (dead-monitor): fail-silent, not sigil-generating
    withSegmentDiag('claudeCapBypass', readClaudeCapBypass()), // claude-cap bypass (census flag): fail-silent, not sigil-generating
    withSegmentDiag('wslMonitor', readWslMonitorState()),   // wsl-stack producer-liveness: fail-silent, not sigil-generating
  ]).then(([rendererR, gitInfoR, cacheAgeR, burnOutputR, firstPromptR, healthR, driftR, fleetR, watchR, skillPressureR, wslPressureR, wslProbeBrokenR, claudeCapBypassR, wslMonitorR]) => {
    // Process each segment — fire the sigil + log if it threw, else pass-through.
    const ts = new Date().toISOString();
    function unwrap(result, fallback) {
      if (!result.error) return result.value;
      appendStatuslineError({
        ts,
        segment: result.segmentName,
        error_message: String((result.error && result.error.message) || result.error),
        error_stack_first_line: ((result.error && result.error.stack) || '').split('\n')[0],
        cwd,
      });
      return fallback(result.segmentName);
    }
    const sigil = computeSegmentSigil;
    const rendererOutput = unwrap(rendererR,   name => sigil(name)); // string carrying the sigil; split below yields [sigil, ''].
    const gitInfo        = unwrap(gitInfoR,    name => sigil(name));
    const cacheAge       = unwrap(cacheAgeR,   name => sigil(name));
    const burnOutput     = unwrap(burnOutputR, name => sigil(name));
    const firstPrompt    = unwrap(firstPromptR, name => sigil(name));
    const health         = unwrap(healthR,     name => ({ front: sigil(name), tail: '' }));
    const driftWarning   = unwrap(driftR,      name => sigil(name));
    // fleet is fail-silent (D-03d): its own try/catch returns '' on ANY error,
    // so the rejection arm here uses a '' fallback (NOT a sigil) as defense in
    // depth. A `⚠ fleet?` sigil would be the OPPOSITE of silence — fleet must
    // never reach the sigil path. Deliberately omitted from sigilCount below so
    // a (theoretically impossible) fleet rejection can't bump the meta-glyph either.
    const fleetWarning   = unwrap(fleetR,      () => '');
    // watch-health is fail-silent (D-09) exactly like fleet: its own try/catch
    // returns '' on ANY error, so the rejection arm uses a '' fallback (NOT a
    // sigil) — a `⚠ watch?` sigil would be the opposite of silence. Deliberately
    // omitted from sigilCount below so a (theoretically impossible) rejection
    // can't bump the meta-glyph either.
    const watchWarning   = unwrap(watchR,      () => '');
    // skillPressure is fail-silent (D-01): own try/catch → '' on ANY error.
    // Do NOT add to sigilCount — a `⚠ skillPressure?` sigil contradicts fail-silent.
    const skillPressureWarning = unwrap(skillPressureR, () => '');
    // wsl-pressure is fail-silent like fleet/watch/skillPressure: own try/catch → '' on ANY
    // error. Deliberately omitted from sigilCount — a `⚠ wslPressure?` sigil would contradict
    // fail-silent (and the segment already renders its own ⚠ on a real trip).
    const wslPressureWarning = unwrap(wslPressureR, () => '');
    // wsl-pressure probe-broken (dead-monitor) is fail-silent exactly like the trip reader:
    // own try/catch → '' on ANY error. Deliberately omitted from sigilCount — a
    // `⚠ wslProbeBroken?` sigil would contradict fail-silent (the segment renders its own
    // ⚠ on a real break, and an absent flag is the healthy/silent state).
    const wslProbeBrokenWarning = unwrap(wslProbeBrokenR, () => '');
    // claude-cap bypass is fail-silent exactly like the wsl readers: own try/catch → ''
    // on ANY error. Deliberately omitted from sigilCount — a `⚠ claudeCapBypass?` sigil
    // would contradict fail-silent (the segment renders its own token on a real bypass,
    // and an absent flag is the healthy/silent state).
    const claudeCapBypassWarning = unwrap(claudeCapBypassR, () => '');
    // wsl-stack producer-liveness is fail-silent exactly like the three flag readers: own
    // try/catch → { token: '', kind: null } on ANY error. Deliberately omitted from
    // sigilCount — a `⚠ wslMonitor?` sigil would contradict fail-silent. NOTE the fallback
    // shape: this segment returns an OBJECT (token + state kind), not a bare string, because
    // composeWslFront below needs the kind to arbitrate which stale flags to suppress.
    const wslMonitor = unwrap(wslMonitorR, () => ({ token: '', kind: null }));
    // sigilCount is the count of segments that crashed this refresh — fed to
    // computeMetaGlyph below as one of its OR-aggregated inputs.
    const sigilCount = [rendererR, gitInfoR, cacheAgeR, burnOutputR, firstPromptR, healthR, driftR]
      .filter(r => r.error).length;
    // The renderer may emit one or two lines. Line 1 carries identity +
    // runtime telemetry (model, ctx bar, dir, repo signals); line 2, when
    // present, carries GSD state. Cache/git append to line 1; ccburn now
    // prepends line 2 (2026-04-27 quick task 260427-u89). Advisory health
    // lands on whichever line is last so it never scrolls out of the user's
    // eye line — line 2 when we have one, line 1 otherwise.
    const [rendererLine1, rendererLine2 = ''] = rendererOutput.trimEnd().split('\n');

    // Line 1 append order (locked 2026-04-28):
    //   model → ctx → cache → git → signals
    // - cacheAge BEFORE gitInfo so static budget signal precedes live VCS state.
    // - signals (R/T/B) come from getRepoSignals + formatLine2Signals (imported
    //   from the renderer module so the helpers stay single-source-of-truth).
    //   Placed AFTER git so the live-signal cluster reads left→right by recency.
    // - ccburn (burnOutput) moves OFF line 1 entirely; it prepends line 2
    //   below to group with the other budget/context signals.
    let line1 = rendererLine1;
    if (cacheAge) line1 += ` \x1b[2m│\x1b[0m ${cacheAge}`;
    if (gitInfo)  line1 += ` \x1b[2m│\x1b[0m ${gitInfo}`;
    const signals = formatLine2Signals(getRepoSignals(cwd));
    if (signals)  line1 += ` \x1b[2m│\x1b[0m ${signals}`;

    // Front-of-stack (orange 208, left of Claude/cwd): drift + critical health
    // (session-wiring degraded: plugin_keys, settings_chain). Separate segments
    // keep concerns distinct — drift says "restart", health says "/dhx:sym repair".
    // Order: drift first (session identity), then health (session wiring).
    const front = [];
    // The wsl cluster (trip → producer-liveness → probe-broken → cap-bypass) is composed by
    // the pure composeWslFront() rather than pushed member-by-member, because the liveness
    // state ARBITRATES: a flag whose producer is confirmed stale is an unvouched last-known
    // state and must not keep rendering as a current RED verdict. The trip always survives
    // (durable by decision); pressure-stale suppresses probe-broken; census-stale suppresses
    // cap-bypass. See composeWslFront for the full rationale and the ordering lock.
    for (const token of composeWslFront({
      trip: wslPressureWarning,
      monitor: wslMonitor,
      broken: wslProbeBrokenWarning,
      bypass: claudeCapBypassWarning,
    })) front.push(token);
    if (driftWarning) front.push(driftWarning);
    if (health.front) front.push(health.front);
    // Fleet drift (SURF-02): a third orange-208 front member, additive only.
    // Order: drift (session identity) → health (session wiring) → fleet
    // (cross-repo convention drift). Local-session warnings precede the broader
    // fleet signal. Silent at zero / stale / error (readFleetFeed returns '').
    if (fleetWarning) front.push(fleetWarning);
    // Watch-health (cross-repo D-08): a fourth orange-208 front member, additive.
    // Order placed after fleet — both are cross-repo signals; watch:stale /
    // watch:Nfail report upstream-watch checker health. Silent when healthy /
    // stale / error (readWatchHealth returns '').
    if (watchWarning) front.push(watchWarning);
    // Skill-pressure (D-03, R-05): fifth orange-208 front member. Aggregate token
    // ⚑N — silent at zero pressure. Order: drift → health → fleet → watch →
    // skill-pressure (local-session warnings precede cross-repo, then skill state).
    if (skillPressureWarning) front.push(skillPressureWarning);
    if (front.length > 0) {
      line1 = front.join(' \x1b[2m|\x1b[0m ') + ' \x1b[2m|\x1b[0m ' + line1;
    }

    // Meta-glyph (2026-04-26 #2b; input set re-derived from the stated contract
    // 2026-08-15). Leftmost ∙/⌃. Prepend AFTER the front composition above so the
    // full leftmost order is:
    //   meta-glyph SP <front-with-pipes> SP <renderer-line1>...
    // Existing detail unchanged — this only adds one glyph + space at column 0.
    //
    // CLASSIFICATION SITE. Every front contributor is either in this array or named
    // in computeMetaGlyph's "DOES NOT PARTICIPATE" block with a reason — adding a
    // front member without doing one or the other fails
    // probe-statusline-metaglyph-front-agreement.js. Read the contract there first.
    //
    // These are the READER OUTPUTS, not composeWslFront's rendered tokens: that
    // function suppresses probe-broken/cap-bypass when their producer is stale, and
    // a suppressed-but-real fault must still warn. Presentation suppression must
    // never manufacture a false green.
    const currentFaults = [
      wslMonitor.token,        // wsl:monitor-dead    — wsl telemetry unvouchable now
      wslProbeBrokenWarning,   // wsl:probe-broken    — pressure unknowable now
      claudeCapBypassWarning,  // claude:seam-broken  — cap bypassed now
      driftWarning,            // session stale now
      health.front,            // session wiring degraded now
      // NOT wslPressureWarning   — a LATCH over a frozen count, not a current reading.
      // NOT fleetWarning         — cross-repo convention drift (boundary held 2026-05-23).
      // NOT watchWarning         — cross-repo watch-checker health, its own channel.
      // NOT skillPressureWarning — workflow backlog, not current session health.
    ];
    const metaGlyph = computeMetaGlyph(currentFaults, health.tail, sigilCount);
    line1 = metaGlyph + ' ' + line1;

    // ccburn (2026-04-27 quick task 260427-u89): moves to line 2 head — the
    // budget/context row groups with GSD state. firstPrompt (2026-05-20 quick
    // task 260520-34p, replaces 2026-04-27 lastPrompt) slots between ccburn and
    // the GSD block — frozen session anchor (first non-synthetic user prompt)
    // next to budget signals, before live GSD state. Gate semantics preserved:
    // line 2 emits when ANY of {burnOutput, firstPrompt, rendererLine2,
    // health.tail} is present. The filter+join idiom keeps an empty piece from
    // leaving a stray dim pipe in front of the next.
    const line2Pieces = [];
    if (burnOutput)    line2Pieces.push(burnOutput);
    if (firstPrompt)   line2Pieces.push(firstPrompt);
    if (rendererLine2) line2Pieces.push(rendererLine2);
    let line2 = line2Pieces.join(' \x1b[2m│\x1b[0m ');

    // Advisory health (fork/symlink state) — red tail, session still works.
    // Prefer line 2 so it sits next to ccburn/GSD rather than crowding line 1.
    // Tail-health falls back to line 1 only when line 2 would otherwise be
    // empty (no ccburn, no GSD content).
    if (health.tail) {
      if (line2) line2 += ` \x1b[2m│\x1b[0m ${health.tail}`;
      else       line1 += ` \x1b[2m│\x1b[0m ${health.tail}`;
    }

    // Single-line collapse for narrow terminals (mobile termius/mosh/tmux):
    // CC reserves N rows above the prompt for statusline; on small mobile screens
    // there isn't enough free height for both rows and line 2 silently drops.
    // Setting DHX_STATUSLINE_SINGLELINE=1 in the shell that launches `claude`
    // joins both lines with the same dim pipe used between segments instead of
    // emitting `\n`. Set per-profile (e.g. mobile CCS profile env) so desktop
    // sessions retain the two-row layout.
    const singleLine = process.env.DHX_STATUSLINE_SINGLELINE === '1';
    const sep = singleLine ? ' \x1b[2m│\x1b[0m ' : '\n';
    process.stdout.write(line2 ? `${line1}${sep}${line2}` : line1);
  }).catch(() => {
    // If everything fails, output nothing — don't break the statusline
  });
});
} // runMain

// Pipe the raw stdin JSON into the dhx renderer and capture stdout
function runRenderer(stdinData) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [STATUSLINE_SCRIPT], {
      stdio: ['pipe', 'pipe', 'ignore'],
    });
    let out = '';
    child.stdout.on('data', chunk => out += chunk);
    child.on('close', () => resolve(out));
    child.on('error', () => resolve(''));
    child.stdin.write(stdinData);
    child.stdin.end();
  });
}

// ccburn segment — rendered directly from the statusline stdin's rate_limits.
//
// 2026-05-29 rewrite: dropped the ccburn subprocess + the global
// ~/.cache/dhx/ccburn-json.json cache + `ccburn collect`. Root cause of the
// "wrong / fluctuating between windows" reports: that cache was GLOBAL, but the
// ccburn store it cached is PER-CCS-PROFILE (ccburn keys its data dir on
// CLAUDE_CONFIG_DIR → .ccburna / .ccburnb / .ccburnc). Single-flight meant
// whichever profile's window won the 30s race wrote ITS profile's reading into the
// one shared cache, so every window displayed one random profile's number, flipping
// each refresh. Compounded inside ccburn: it prefers its newest SQLite row when
// <120s old (fed by per-window `collect`) over the live API, so an idle window
// poisoned the shared store with its frozen-stale rate_limits. See
// docs/statusline-wrapper.md § ccburn segment + docs/decisions.md 2026-05-29 row.
//
// CC already ships authoritative usage in stdin's `rate_limits` (same source as
// /usage), so we render it ourselves — no subprocess, no cache, no collect, just
// arithmetic on data runMain already parsed. Each window shows ITS OWN
// account-accurate usage. The 2026-05-25 storm/orphan class (D-14) is now
// structurally impossible for this segment: there is nothing to spawn.
//
//   rate_limits.five_hour = { used_percentage, resets_at }   → session (5h window)
//   rate_limits.seven_day = { used_percentage, resets_at }   → weekly  (7d, all models)
//
// `resets_at` is epoch-seconds today; ISO strings are tolerated for forward-compat
// (ccburn's own collector normalized both, so CC has emitted both across versions).
//
// Pace → color: ccburn derived pace from burn-rate history we don't hold
// in-process, so we reconstruct it as utilization-vs-fraction-of-window-elapsed
// (the 5h / 7d window lengths are fixed by limit type). behind = under the clock
// (conserving), ahead = over it (will deplete early), within tolerance = on pace.
// Two symmetric floor overrides bypass pace: a near-exhausted limit
// (≥ DHX_CCBURN_RED_AT, default 90%) is forced to `ahead` so it never reads calm,
// and a barely-used limit (≤ DHX_CCBURN_BLUE_AT, default 5%) is forced to `behind`
// so low/zero usage always reads as conserving rather than neutral-dim at a fresh
// window's start. A side whose resets_at is already in the past is window-expired
// (an idle window CC hasn't refreshed yet) → skipped, never shown stale.

// Pace palette: behind / on-pace / ahead colors. DHX_CCBURN_PALETTE picks one;
// default is the user-chosen mix (cyan / dim / red). All switchable live, no edit.
const CCBURN_PALETTES = {
  default:    { behind: '\x1b[36m',      on: '\x1b[2m',        ahead: '\x1b[31m' },
  'ice-fire': { behind: '\x1b[36m',      on: '\x1b[2m',        ahead: '\x1b[38;5;208m' },
  traffic:    { behind: '\x1b[32m',      on: '\x1b[33m',       ahead: '\x1b[31m' },
  quiet:      { behind: '\x1b[2;32m',    on: '\x1b[2m',        ahead: '\x1b[31m' },
  gradient:   { behind: '\x1b[38;5;75m', on: '\x1b[38;5;179m', ahead: '\x1b[38;5;203m' },
  'bold-hot': { behind: '\x1b[32m',      on: '\x1b[2m',        ahead: '\x1b[1;31m' },
};
// Utilization at/above this forces `ahead` (red) regardless of pace. 0-100 → fraction.
const CCBURN_RED_AT = (() => {
  const v = Number(process.env.DHX_CCBURN_RED_AT);
  return Number.isFinite(v) && v > 0 && v <= 100 ? v / 100 : 0.90;
})();
// Utilization at/below this forces `behind` (conserving) regardless of pace. 0-100 → fraction.
const CCBURN_BLUE_AT = (() => {
  const v = Number(process.env.DHX_CCBURN_BLUE_AT);
  return Number.isFinite(v) && v >= 0 && v <= 100 ? v / 100 : 0.05;
})();
const CCBURN_PACE_TOL = 0.05;                                  // ± band around budget pace for `on`
const CCBURN_WINDOW_SECS = { five_hour: 5 * 3600, seven_day: 7 * 86400 };

// Palette resolution — file trumps env trumps default. The statusline runs as a
// child of `claude` and inherits its launch-time env, so DHX_CCBURN_PALETTE only
// applies if exported BEFORE `claude` started (a restart). The override file is
// re-read every refresh, so it's the LIVE switch: `echo traffic >
// ~/.config/dhx/ccburn-palette` flips the palette on the next refresh, no restart.
// Both the path-env and the file contents are read per call so the override is
// fully live (and probe-overridable). Unknown names in either source → default.
function resolveCcburnPalette() {
  const file = process.env.DHX_CCBURN_PALETTE_FILE
    || path.join(process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config'), 'dhx', 'ccburn-palette');
  try {
    const name = fs.readFileSync(file, 'utf8').trim();
    if (CCBURN_PALETTES[name]) return CCBURN_PALETTES[name];
  } catch { /* no override file (ENOENT) — fall through to env/default */ }
  return CCBURN_PALETTES[process.env.DHX_CCBURN_PALETTE] || CCBURN_PALETTES.default;
}

// resets_at → epoch seconds. Accepts an epoch number (seconds) or an ISO string;
// returns null on anything else so the caller skips that side.
function ccburnResetSecs(v) {
  if (typeof v === 'number' && Number.isFinite(v)) return v;
  if (typeof v === 'string') {
    const t = Date.parse(v);
    if (!Number.isNaN(t)) return Math.floor(t / 1000);
  }
  return null;
}

// Classify pace from utilization (0-1) vs the fraction of the window elapsed.
// Symmetric floor overrides short-circuit pace: ≥ CCBURN_RED_AT → 'ahead'
// (near-exhaustion), ≤ CCBURN_BLUE_AT → 'behind' (barely used / conserving).
// Red is checked first so it wins a (misconfigured) overlap. Returns one of
// 'behind' | 'on' | 'ahead' — the palette keys.
function ccburnPace(util, secsToReset, windowSecs) {
  if (util >= CCBURN_RED_AT) return 'ahead';
  if (util <= CCBURN_BLUE_AT) return 'behind';
  if (!Number.isFinite(windowSecs) || windowSecs <= 0) return 'on';
  const budgetPace = 1 - secsToReset / windowSecs;             // fraction of window elapsed
  if (util > budgetPace + CCBURN_PACE_TOL) return 'ahead';
  if (util < budgetPace - CCBURN_PACE_TOL) return 'behind';
  return 'on';
}

// Render-path entry (sync): build the ccburn line straight from the stdin payload.
// `nowSecs` is injectable for probes; defaults to wall clock. Returns '' when
// rate_limits is absent/empty or every side is window-expired — the segment hides,
// matching the prior no-data behavior. No I/O, no subprocess.
function buildCcburnFromStdin(stdinData, nowSecs) {
  let data;
  try { data = typeof stdinData === 'string' ? JSON.parse(stdinData) : stdinData; }
  catch { return ''; }
  const rl = data && data.rate_limits;
  if (!rl || typeof rl !== 'object') return '';

  const pal = resolveCcburnPalette();
  const now = Number.isFinite(nowSecs) ? nowSecs : Date.now() / 1000;
  const DIM = '\x1b[2m', R = '\x1b[0m';
  const parts = [];

  for (const key of ['five_hour', 'seven_day']) {
    const lim = rl[key];
    if (!lim || typeof lim !== 'object') continue;
    const pctRaw = Number(lim.used_percentage);
    if (!Number.isFinite(pctRaw)) continue;
    const resetSecs = ccburnResetSecs(lim.resets_at);
    // Already reset, but this (idle) window's rate_limits hasn't refreshed → skip.
    // Never render an expired side — that was the cross-profile "100%" staleness bug.
    if (resetSecs == null || resetSecs <= now) continue;
    const secsToReset = resetSecs - now;
    const util = Math.max(0, Math.min(1, pctRaw / 100));
    const pace = ccburnPace(util, secsToReset, CCBURN_WINDOW_SECS[key]);
    const dur = formatBurnDuration(secsToReset / 60);
    parts.push(`${pal[pace]}${Math.round(pctRaw)}%${R}${dur ? ` ${DIM}(${dur})${R}` : ''}`);
  }
  if (parts.length === 0) return '';
  return parts.join(` ${DIM}·${R} `);
}

// --- Per-segment self-diagnosis (2026-04-26 statusline observability bundle #4) ---
//
// Promise.all in runMain previously had a single outer .catch() that swallowed
// any thrown exception inside ANY of the 6 branches and emitted "" — a silent
// empty statusline indistinguishable from "no segments to show." Crash diagnosis
// required mid-incident shell instrumentation. The wrap below converts each
// branch into a {value, error, segmentName} envelope so the wrapper can:
//
//   1. Substitute a red `⚠ <segment>?` sigil where the segment's output would
//      have been (preserves layout — sigil sits in the same column).
//   2. Append a structured JSON line to ~/.cache/dhx/statusline-errors.jsonl
//      so the operator can replay the crash off-line.
//   3. Continue rendering the OTHER 5 segments — a single segment's failure no
//      longer collapses the entire render.
//
// INVARIANT: Log writer failure (mocked appendFile/statSync/renameSync throw)
// MUST NOT propagate out of appendStatuslineError. The outer try/catch swallows
// EVERYTHING — disk-full, permission-denied, or any unforeseen I/O error must
// not block the render path.
//
// INVARIANT: A structured warning that bubbles through readHealthCache (e.g.,
// {front: "plugin-keys:MISSING", tail: ""}) is NOT a thrown exception and MUST
// NOT trigger the sigil — that would be double-reporting the same condition.
// Only thrown rejections inside the Promise.all branch fire the sigil.
//
// Probe: tests/probes/probe-statusline-self-diag.js exercises the rotation,
// log-writer-failure resilience, clean-path no-write, and shape contract.
const STATUSLINE_ERROR_FILE = path.join(os.homedir(), '.cache', 'dhx', 'statusline-errors.jsonl');
const STATUSLINE_ERROR_MAX_BYTES = 1_000_000;

function appendStatuslineError(entry) {
  try {
    const line = JSON.stringify(entry) + '\n';
    try {
      const st = fs.statSync(STATUSLINE_ERROR_FILE);
      if (st.size + line.length > STATUSLINE_ERROR_MAX_BYTES) {
        fs.renameSync(STATUSLINE_ERROR_FILE, STATUSLINE_ERROR_FILE + '.prev');
      }
    } catch { /* first write — file absent, nothing to rotate */ }
    fs.appendFile(STATUSLINE_ERROR_FILE, line, () => {});
  } catch { /* writer failure must never block the statusline */ }
}

// Wrap a segment promise so it always resolves to {value, error, segmentName}.
// Never rejects — caller can destructure without try/catch noise.
function withSegmentDiag(segmentName, promise) {
  return Promise.resolve(promise).then(
    value => ({ value, error: null, segmentName }),
    error => ({ value: null, error, segmentName })
  );
}

// Build the canonical sigil string for a crashed segment. Exposed so probes can
// pin the format without re-parsing the wrapper source. Format:
// `\x1b[31m⚠ <name>?\x1b[0m` — red `⚠ name?` reset.
function computeSegmentSigil(segmentName) {
  return `\x1b[31m⚠ ${segmentName}?\x1b[0m`;
}

// --- Meta-glyph composition (2026-04-26 statusline observability bundle #2b) ---
//
// THE CONTRACT (stated as a proposition, 2026-08-15 — read this before adding an input):
//
//   Dim green ∙  = this session, and the telemetry needed to assess it, are
//                  CURRENTLY trustworthy.
//   Bright yellow ⌃ = a CURRENT condition makes this session unsafe, stale,
//                  degraded, or materially untrustworthy.
//
// Latched history and workflow backlogs DO NOT participate — they keep their own
// front tokens. This is a proposition, not an enumeration, precisely because the
// prior four-input enumeration (drift + health.front + health.tail + sigilCount)
// was written when the front stack had two members and was never revisited as it
// grew to nine. Four members joined the front stack across two later arcs without
// ever being checked against it; three of them belonged. Classify against the
// proposition; `probe-statusline-metaglyph-front-agreement.js` fails the suite if
// a front contributor is left unclassified.
//
// PARTICIPATES (current-truth):
//   wsl:monitor-dead   — the producer vouching for the wsl flags is dead; current
//                        wsl safety state is unknowable
//   wsl:probe-broken   — the pressure probe itself is broken; same
//   claude:seam-broken — the concurrent-claude cap is bypassed NOW
//   driftWarning       — the CC install advanced under a live session; stale now
//   health.front       — session wiring degraded now
//   health.tail        — session advisory now (renders on line 2, not in front)
//   sigilCount         — a statusline segment threw on THIS refresh
//
// DOES NOT PARTICIPATE, and why (do not re-litigate without reading these):
//   wsl:bash=N trip    — a LATCH, not a current reading. readWslPressure() parses a
//                        FROZEN capture written at trip time and renders it until the
//                        operator clears the flag; the count in the token is the count
//                        AT TRIP. Current pressure is deliberately unavailable here —
//                        pressure.log is read for mtime only (74KB+ and growing; parsing
//                        it per-refresh is the D-14 hot-path spend that caused the
//                        2026-04-26 capture-pane wedge). A latch cannot establish current
//                        state, so wiring it would redefine green from "currently healthy"
//                        to "no uncleared records". Making live pressure participate needs
//                        a producer-side `pressureActive` field — filed, not dropped.
//   fleet / watch /    — cross-repo and workflow-backlog signals, not this session's
//   skillPressure        health. Boundary affirmed 2026-05-23; each is its own channel.
//
// WHY THE INPUTS ARE SOURCE VALUES, NOT RENDERED TOKENS (load-bearing): composeWslFront()
// SUPPRESSES probe-broken/cap-bypass when their producer is stale. Deriving glyph state
// from what got rendered would let presentation suppression manufacture a false green.
// The call site passes the reader outputs, so a suppressed-but-real fault still warns.
//
// Why a meta-glyph at all: a session with no health warnings shows nothing in the
// front-of-stack zone — users can't distinguish "all good" from "statusline broken /
// not running". An explicit dim green ∙ confirms the pipeline is alive AND clean.
// It must therefore RENDER IN EVERY STATE — presence-vs-absence is the only detector
// for "the watcher itself is dead" (2026-04-26; never conditionally emit it).
//
// Color non-collision: meta-glyph green 70 + yellow 220 are distinct from
// critical 208 + advisory red 31 + sigil red 31. (Sigil and advisory share the
// red palette but never co-locate — sigil sits where the segment's normal
// output would have been; advisory sits at the tail.)
//
// `currentFaults` is an ARRAY of participating front-member source values (falsy ==
// not firing) rather than N positional scalars: the seven-argument signature this
// replaces is what made the drift possible, and the array gives the classification a
// single site the probe can assert against.
function computeMetaGlyph(currentFaults, healthTail, sigilCount) {
  const warn = (currentFaults || []).some(Boolean) || !!healthTail || sigilCount > 0;
  // Hairline glyphs: ∙ (U+2219 bullet operator, dim green) for clean / ⌃ (U+2303
  // up arrowhead, bright yellow) for warn. Chosen 2026-04-26 over solid ● / ▲ to
  // recede on the clean path while preserving the third-state distinction —
  // presence-vs-absence still detects "watcher dead." Colors unchanged.
  return warn ? '\x1b[38;5;220m⌃\x1b[0m' : '\x1b[2;38;5;70m∙\x1b[0m';
}

// Minutes → compact duration. Rules:
//   <1m   → "<1m"
//   <1h   → "XXm"        (e.g. "47m")
//   <6h   → "XhXXm"      (e.g. "1h58m") — minute zero-padded for alignment
//   <24h  → "Xh"         (drop minutes, long-tail reads don't need them)
//   ≥24h  → "Nd"         (days, no hours — weekly reset is often multi-day)
// null/undefined/negative → '' so the segment hides the duration entirely.
function formatBurnDuration(minutes) {
  if (minutes == null || !Number.isFinite(minutes) || minutes < 0) return '';
  if (minutes < 1) return '<1m';
  if (minutes < 60) return `${Math.floor(minutes)}m`;
  if (minutes < 360) {
    const h = Math.floor(minutes / 60);
    const m = Math.floor(minutes % 60);
    return `${h}h${String(m).padStart(2, '0')}m`;
  }
  if (minutes < 1440) return `${Math.floor(minutes / 60)}h`;
  return `${Math.floor(minutes / 1440)}d`;
}

// Plugin-registry drift detector. Catches clobber of the downstream registry
// files CC's plugin resolver reads at session start — `plugins/known_marketplaces.json`
// and `plugins/installed_plugins.json` — distinct from the settings-key clobber
// class (HP-017) that `plugin_keys` already covers. Those two registry files
// sit under `$CLAUDE_CONFIG_DIR/plugins/`; settings.json is where the user
// *declares* a marketplace, but the resolver reads the downstream files to
// *locate* it. When they drift out of sync, every new session's plugin hooks
// silently fail to load. The 2026-04-24 incident: dhx-local was absent from
// known_marketplaces.json for ~50 min despite settings declaring it; dhx-plugin
// SessionStart hooks didn't fire; the existing plugin_keys check passed because
// settings was fine.
//
// Runs inline in the statusline — not via a plugin hook — so the detector is
// immune to the exact failure mode it catches (statusline is registered via
// statusLine.command in settings.json and loaded at CC startup, not through
// the plugin resolver). See HP-025.
//
// Scope: dhx-local marketplace + dhx@dhx-local plugin only. Broader coverage
// across all enabled plugins is tempting but noisy — CC sometimes leaves
// official plugins in transient orphan states that heal on the next session.
// Widen after the narrow detector proves stable.
//
// Returns the first-matched state token (priority order below) or '' when
// clean. Simultaneous faults collapse to the highest-priority token;
// recovery is `/dhx:sym repair` regardless.
//
// Priority:
//   1. UNREADABLE:<basename>      ENOENT or EACCES on km or installed_plugins
//   2. BADJSON:<basename>         JSON.parse failure on km or installed_plugins
//   3. MISSING:dhx-local          km lacks the extraKnownMarketplaces entry
//   4. PATH:dhx-local             realpath mismatch across
//                                 settings.extraKnownMarketplaces.dhx-local.source.path,
//                                 km.dhx-local.source.path, km.dhx-local.installLocation
//                                 (only checked when source.source === "directory")
//   5. UNINSTALLED:dhx@dhx-local  installed_plugins.json lacks the plugin
//   6. DISABLED:dhx@dhx-local     settings.enabledPlugins[x] !== true but plugin
//                                 present in installed_plugins
//
// INVARIANT: 6 drift states + clean. Probe:
// tests/probes/probe-plugin-registry.sh exercises every negative state plus a
// clean-state assertion against the live registry files.
//
// STARTUP SUPPRESSION WINDOW (added 2026-04-28). CC's plugin resolver runs
// asynchronously during session-init and may not have written
// known_marketplaces.json by the time the first statusline refresh fires —
// producing a transient `registry:MISSING:dhx-local` warning that resolves
// itself within ~5-15s. Suppress for `REGISTRY_STARTUP_SUPPRESS_MS` (default
// 30s) anchored on the drift snapshot file's mtime (≈ session start; written
// by checkDrift's first invocation). Persistent failures still surface after
// the window — the suppression is bounded, not absolute. Snapshot absent →
// first refresh → in startup → suppress (race fail-safe; self-resolves on
// the next refresh once checkDrift writes the file). Env override
// `DHX_REGISTRY_SUPPRESS_MS=0` disables the window entirely (used by probes
// that test the detector itself; users who want strict immediate firing can
// set it too).
const REGISTRY_STARTUP_SUPPRESS_MS = (() => {
  const raw = parseInt(process.env.DHX_REGISTRY_SUPPRESS_MS, 10);
  return Number.isFinite(raw) && raw >= 0 ? raw : 30_000;
})();
function checkPluginRegistry(configDir, sessionId) {
  const MK = 'dhx-local';
  const PLUGIN = 'dhx@dhx-local';

  // Startup suppression — see REGISTRY_STARTUP_SUPPRESS_MS comment above.
  // Skip the check when sessionId absent (caller didn't pass — probably an
  // ad-hoc invocation; keep historical behavior of firing immediately) or
  // when the env override is 0 (probes/strict mode).
  if (sessionId && REGISTRY_STARTUP_SUPPRESS_MS > 0) {
    try {
      const cacheDir = path.join(os.homedir(), '.cache', 'dhx');
      const ccTicks = findCCTicks(process.ppid);
      const suffix = ccTicks ? `-p${ccTicks}` : '';
      const snapshotFile = path.join(cacheDir, `drift-snapshot-${sessionId}${suffix}.json`);
      const ageMs = Date.now() - fs.statSync(snapshotFile).mtimeMs;
      if (ageMs >= 0 && ageMs < REGISTRY_STARTUP_SUPPRESS_MS) return '';
    } catch {
      return ''; // snapshot absent → in startup window
    }
  }

  // Settings is the declaring source — this is the gate. If settings is
  // unreadable/unparseable, or doesn't declare dhx-local, we skip silently:
  //   (a) settings_chain and plugin_keys already cover settings-side faults,
  //   (b) a fresh environment with no dhx declaration shouldn't trip
  //       UNREADABLE/BADJSON on downstream registry files that wouldn't
  //       matter to a resolver that never looks for dhx-local anyway.
  // This ordering is what makes the detector scope-safe in probe harnesses
  // (probe-health-suffix.js runs with an empty fake HOME + empty
  // CLAUDE_CONFIG_DIR and must not fire registry warnings).
  let settings;
  try {
    const settingsReal = fs.realpathSync(path.join(configDir, 'settings.json'));
    settings = JSON.parse(fs.readFileSync(settingsReal, 'utf8'));
  } catch { return ''; }

  const declared = (settings.extraKnownMarketplaces || {})[MK];
  if (!declared) return ''; // nothing declared — nothing to verify

  const kmPath = path.join(configDir, 'plugins', 'known_marketplaces.json');
  const ipPath = path.join(configDir, 'plugins', 'installed_plugins.json');

  // Distinguish UNREADABLE (file gone / permission denied) from BADJSON (file
  // present, parse fails) — operator needs to know whether to rebuild the
  // file or repair its content.
  let km, ip;
  for (const [p, label] of [[kmPath, 'known_marketplaces.json'], [ipPath, 'installed_plugins.json']]) {
    let raw;
    try { raw = fs.readFileSync(p, 'utf8'); }
    catch { return `UNREADABLE:${label}`; }
    try {
      const parsed = JSON.parse(raw);
      if (p === kmPath) km = parsed; else ip = parsed;
    } catch { return `BADJSON:${label}`; }
  }

  if (!(MK in km)) return `MISSING:${MK}`;

  // Path equality only applies to directory-source marketplaces. Github-source
  // marketplaces are tracked via the repo and installLocation is CC-managed;
  // comparing paths would false-positive on every refresh.
  if (declared.source && declared.source.source === 'directory') {
    const entry = km[MK];
    const settingsPath = declared.source.path;
    const kmSourcePath = entry.source && entry.source.path;
    const kmInstallLocation = entry.installLocation;
    let rSettings, rKmSource, rKmInstall;
    try { rSettings = fs.realpathSync(settingsPath); } catch { rSettings = settingsPath; }
    try { rKmSource = kmSourcePath ? fs.realpathSync(kmSourcePath) : ''; } catch { rKmSource = kmSourcePath; }
    try { rKmInstall = kmInstallLocation ? fs.realpathSync(kmInstallLocation) : ''; } catch { rKmInstall = kmInstallLocation; }
    if (!rSettings || !rKmSource || !rKmInstall ||
        rSettings !== rKmSource || rSettings !== rKmInstall) {
      return `PATH:${MK}`;
    }
  }

  // Enablement side: settings.enabledPlugins declares intent,
  // installed_plugins.json records the install. Both must line up.
  const enabled = settings.enabledPlugins && settings.enabledPlugins[PLUGIN];
  const plugins = (ip && ip.plugins) || {};
  if (!(PLUGIN in plugins)) return `UNINSTALLED:${PLUGIN}`;
  if (enabled !== true) return `DISABLED:${PLUGIN}`;

  return '';
}

// Read health cache written by dhx-health-check.sh (SessionStart).
// Returns { front, tail } — each is a rendered warning segment or empty string.
//
// Two tiers by operational consequence:
//   CRITICAL (orange 208, front-of-stack): session-wiring degraded. plugin_keys
//     MISSING ⇒ plugin hooks silently not firing; settings_chain non-ok ⇒
//     ~/.claude/settings.json stopped tracking CCS. Either of these means the
//     session's mutation pipeline is partially broken — deserves the same
//     visual weight as the drift "restart" warning, next to CC's always-visible
//     permission-bypass banner.
//   ADVISORY (red, appended): fork/symlink state — patches REGRESSED,
//     read-guard REGRESSED, missing_symlinks > 0. The session still works;
//     these are long-term maintenance signals. Appended red matches their
//     lower priority.
// Both tiers share `/dhx:sym repair` as the recovery command, so each gets its
// own trailing suffix — the segments are visually distinct and users may only
// glance at one, so duplicating the direction outweighs the 15-char savings.
//
// Publisher override: sym-health.json is written by the skills-repo `/dhx:sym`
// status/audit/repair commands — the authoritative source for plugin_keys
// (same process that runs `claude plugin enable` publishes the result). When
// fresh (<1h via checked_at) AND STAMPED FOR THIS LANE, its plugin_keys
// replaces health.json's. This lets mid-session `/dhx:sym repair` clear the
// warning within 60s instead of waiting for the next SessionStart.
// Stale/missing/malformed/foreign → defer to health.json, which already carries
// the SessionStart-time direct jq check.
//
// The stamp gate is load-bearing (2026-09-15). That publisher computes its
// verdict from a PER-LANE input — $CLAUDE_CONFIG_DIR/settings.json — and writes
// it to one $HOME-anchored file every CCS lane shares. Freshness alone let the
// last lane to run /dhx:sym win, and this reader applied the foreign answer a
// SECOND time at render, after dhx-health-check.sh had already taken it. The
// failure is a FALSE-CLEAN: lanes normally link settings.json to the same
// ~/.ccs/shared/settings.json and agree, so it costs nothing until the one case
// the detector exists for — a lane whose own link has broken, masked by a
// healthy lane's `ok`.
//
// Deferring to health.json is genuinely lane-local now, which is what makes the
// refusal cheap rather than a downgrade: dhx-health-check.sh applies the same
// stamp gate, so the value it wrote is either this lane's own jq check or a
// publish stamped for this lane. The accepted cost is freshness, not
// correctness — a lane that did not itself run the repair clears at its next
// SessionStart rather than within 60s. Computing a live lane-local verdict here
// instead was considered and rejected: it would mint a SECOND bash/JS predicate
// pair to keep in agreement, to buy back a window the brief deliberately scoped
// to the repairing lane.
// Producer + schema: ~/repos/skills/docs/decisions/2026-09-15-sym-health-lane-stamp.md
//
// CORRECTED 2026-09-15 — this used to read "INVARIANT: sole runtime reader of
// ~/.cache/dhx/health.json", and that was false. A source sweep across both repos
// (anchored on the exact basename, since `health.json` as a substring also matches
// the unrelated dhx-watch-health.json and dhx-selftest-health.json) found a SECOND
// runtime reader: the skills repo's dhx/sym/references/sym-gsd-update-report.md
// runs `jq` against this file in two blocks — step 12.45(c) and step 12.5 check 2 —
// and hard-exits on .settings_chain, .read_guard, .plugin_keys and .hooks_wiring.
// So a schema change here reaches a consumer in another repo.
//
// The live rule, which is what the old invariant was reaching for: the four fields
// that reader gates on are all MACHINE-WIDE and all stay at the top level of
// health.json. Removing or renaming any of them breaks `/dhx:sym gsd-update`
// post-install verification in a way no probe in this repo would catch. Before
// extending or moving a field, grep BOTH repos for the exact basename and open
// every hit — a hit count is not a reading.
//
// Per-lane fields live in ~/.cache/dhx/health-lane-<id>.json instead; see
// readLaneHealth() below and dhx-health-check.sh's lane-identity block.

// Derive a CCS lane id from a config dir, mirroring dhx-health-check.sh.
//
// INVARIANT: this MUST agree with the lane-identity block in dhx-health-check.sh.
// Two implementations in two languages, so the agreement is enforced two ways —
// the sidecar records the config_dir it was computed for and readLaneHealth()
// refuses a mismatch (a derivation drift renders unknown rather than serving
// another lane's reading), and tests/probes/probe-health-lane-scoping.sh asserts
// the producer and this consumer resolve the same id for the same input.
//
// Allowlist, not sanitization: $CLAUDE_CONFIG_DIR is untrusted (a sandboxed CC has
// previously reached live cache files through a symlink chain — see the shipped
// 2026-04-27 config-dir write-hardening brief). Anything outside $HOME/.claude or
// a single-segment child of $HOME/.ccs/instances resolves to null, and a null id
// reads as "no reading for this lane".
// Does a published sym-health.json verdict belong to THIS lane?
//
// INVARIANT (cross-repo, unenforceable by code): the stamp this compares is written
// by ~/repos/skills/scripts/lib/doctor.sh::cmd_health_export as `readlink -f` of its
// own $CLAUDE_CONFIG_DIR. Both sides must normalise, and both sides do — a lexical
// comparison here would rebuild the exact bug a close-gate reviewer refuted in the
// parallel health.json arc, where a lane symlinked to canonical (or merely named
// with an internal double slash) compared unequal to itself.
//
// Returns false for a missing or empty stamp, which is the deliberate reading of an
// UNSTAMPED file: written before 2026-09-15, provenance unknown, and unknown
// provenance is the thing the stamp exists to end. Refusal is cheap — the caller
// falls back to health.json's lane-local value. realpathSync throws for a config dir
// deleted mid-session; that is also a refusal, not a crash.
function symHealthIsForThisLane(symConfigDir, configDir) {
  if (typeof symConfigDir !== 'string' || symConfigDir === '') return false;
  try { return symConfigDir === fs.realpathSync(configDir); } catch { return false; }
}

function laneIdFor(configDir, home) {
  try {
    const real = (p) => { try { return fs.realpathSync(p); } catch { return String(p).replace(/\/+$/, ''); } };
    const cfg = real(configDir);
    if (cfg === real(path.join(home, '.claude'))) return 'default';
    const instances = real(path.join(home, '.ccs', 'instances'));
    if (cfg.startsWith(instances + path.sep)) {
      const candidate = cfg.slice(instances.length + 1);
      // `default` is reserved for canonical ~/.claude — see the producer's matching
      // refusal. This clause exists for the AGREEMENT, not for safety: the config_dir
      // stamp below would already refuse to serve canonical's reading to an instance
      // named `default`. But the producer writes no sidecar for that name, so a reader
      // that still resolved it would disagree with the producer on the same input, and
      // that divergence is exactly what probe case [7] is built to catch.
      if (/^[A-Za-z0-9_-]+$/.test(candidate) && candidate !== 'default') return candidate;
    }
  } catch { /* fall through to null */ }
  return null;
}

// Read the per-lane sidecar for the lane this statusline is rendering for.
// Returns the lane's missing_symlinks count, or undefined when there is no
// trustworthy reading — absent file, malformed JSON, a config dir outside the
// allowlist, a non-integer count, or a sidecar whose recorded config_dir is not
// this lane's. undefined is NOT zero: the advisory handler renders it as
// `symlinks:?` so an absent reading can never present as a clean one.
function readLaneHealth(configDir, home) {
  try {
    const id = laneIdFor(configDir, home);
    if (!id) return undefined;
    const laneFile = path.join(home, '.cache', 'dhx', `health-lane-${id}.json`);
    const lane = JSON.parse(fs.readFileSync(laneFile, 'utf8'));
    if (!lane || lane.config_dir !== fs.realpathSync(configDir)) return undefined;
    if (!Number.isInteger(lane.missing_symlinks) || lane.missing_symlinks < 0) return undefined;
    return lane.missing_symlinks;
  } catch {
    return undefined;
  }
}

function readHealthCache(sessionId) {
  return new Promise((resolve) => {
    const cacheFile = path.join(os.homedir(), '.cache', 'dhx', 'health.json');
    fs.readFile(cacheFile, 'utf8', (err, data) => {
      // Start from an empty object so downstream detectors (sym-health
      // override, plugin_registry) still fire even when health.json is missing
      // or unparseable — those paths don't depend on SessionStart having run.
      let h = {};
      if (!err) {
        try { h = JSON.parse(data); } catch { h = {}; }
      }

      try {
        const symFile = path.join(os.homedir(), '.cache', 'dhx', 'sym-health.json');
        const sym = JSON.parse(fs.readFileSync(symFile, 'utf8'));
        const ageMs = Date.now() - Date.parse(sym.checked_at || '');
        const symConfigDir = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
        if (Number.isFinite(ageMs) && ageMs >= 0 && ageMs < 3600 * 1000 && sym.plugin_keys
            && symHealthIsForThisLane(sym.config_dir, symConfigDir)) {
          h.plugin_keys = sym.plugin_keys;
        }
      } catch { /* absent/malformed/foreign — defer to health.json's value */ }

      // Plugin-registry drift runs inline every refresh (no SessionStart
      // publisher) — it's the only class of clobber that can take out the
      // plugin hooks that would otherwise write it. See checkPluginRegistry().
      try {
        const configDir = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
        const state = checkPluginRegistry(configDir, sessionId);
        if (state) h.plugin_registry = state;
      } catch { /* detector errors never block the statusline */ }

      // Per-lane reading (2026-09-15). missing_symlinks is computed against
      // $CLAUDE_CONFIG_DIR, so it belongs to the lane that computed it, not to
      // the machine. It now lives in ~/.cache/dhx/health-lane-<id>.json and is
      // resolved for THIS lane here.
      //
      // The assignment is UNCONDITIONAL and that is load-bearing: a legacy
      // health.json still carrying a top-level missing_symlinks (written by a
      // pre-2026-09-15 hook, or by any lane that has not started a session since)
      // must not leak its value into this render. Overwriting with undefined is
      // what makes an old cross-lane count unreachable rather than merely
      // deprioritised — the stale trap the split exists to remove.
      //
      // undefined reaches ADVISORY_HANDLERS.missing_symlinks below and renders
      // `symlinks:?`. It does NOT render as a clean line: an absent reading
      // presenting as healthy is the same silent-zero class as a stale list
      // producing a permanently-false count.
      h.missing_symlinks = readLaneHealth(
        process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude'),
        os.homedir(),
      );

      // Tier classification — field set comes from scripts/lib/tiers.json (D-07
      // Phase 5 migration; Phase 4 D-02 source-of-truth lock). Comparator + format
      // are heterogeneous per-field, so they live in JS handler tables alongside
      // the JSON-iterated array. The iteration order follows the JSON array
      // order — predictable, parity-checked by probe-tiers-parity.sh.
      // Backward-compat: `h.X && h.X !== 'ok'` guard pattern preserved (legacy
      // health.json files lacking newer fields fall through silently).
      // D-08 try/catch fallback: missing/corrupt tiers.json → empty arrays
      // (iterable default) so `for (const k of TIERS.critical)` is a silent
      // no-op rather than `TypeError: not iterable`. UI hot path stays alive.
      // D-10 runtime guards: critical fails closed if CRITICAL_PREFIX[k] missing
      // (treats unknown field as if absent — no `undefined:<value>` output);
      // advisory skips silently if handler missing. Probe checks current keys
      // only; runtime guard is second-line defense against future tiers.json
      // additions where someone forgets paired handler updates.
      let TIERS = { critical: [], advisory: [] };
      try {
        TIERS = require('../scripts/lib/tiers.json');
      } catch (e) {
        // Fall back gracefully if scripts/lib/tiers.json is missing or unparseable.
        // The empty arrays keep `for (const k of TIERS.critical)` loops below
        // as a silent no-op (NO TypeError: not iterable), so the statusline
        // still renders the rest of the line — just with no tier glyph.
        // This defends the UI hot path on the consumer side; drift detection
        // lives in tests/probes/probe-tiers-parity.sh.
      }
      const CRITICAL_PREFIX = {
        settings_chain:   'settings',
        plugin_keys:      'plugin-keys',
        plugin_registry:  'registry',
        hooks_wiring:     'hooks-wiring',
      };
      const ADVISORY_HANDLERS = {
        worktree_patches: (v) => v && v !== 'patched' ? `patches:${v}` : null,
        read_guard:       (v) => v && v !== 'patched' ? `read-guard:${v}` : null,
        // Three states, not two. `undefined` means no trustworthy reading exists
        // for THIS lane (no sidecar yet, malformed, or one recorded against a
        // different config dir) and renders `symlinks:?` — deliberately NOT null,
        // because null is silence and silence reads as healthy. 0 still renders
        // null: a lane that WAS checked and found clean has nothing to say.
        // `symlinks:?` over a longer phrase on width grounds: the advisory tail
        // joins every token then appends one `— /dhx:sym repair`, and at the 76-char
        // content ceiling a worst-case line carrying two real faults alongside it
        // measures 67 chars with `symlinks:?` and 80 (wrapping, with no hanging
        // indent, so the continuation lands at column 0) with the spelled-out form.
        //
        // `symlinks:N`, NOT `N broken symlink(s)` (renamed 2026-09-15). The producer
        // folds FOUR causes into this one integer — absent item, real dir standing in
        // for a link, link resolving to the wrong target, link dangling — and "broken"
        // names only the last. It was already false for the real-dir case, which is
        // exactly why docs/troubleshooting.md carries a section titled "`missing_symlinks
        // > 0` ... But `find -xtype l` Shows Zero": an operator read the word, ran the
        // matching command, got zero, and had to be told the word was wrong. The
        // destination check added the same day made that a fourth cause, so the wording
        // is now cause-neutral. It also matches the `subject:state` shape every sibling
        // token uses (`patches:`, `read-guard:`, `settings:`, `plugin-keys:`) and makes
        // `symlinks:?` a sibling of `symlinks:2` instead of an odd one out — and it is
        // NARROWER than the phrase it replaces, so the width budget above only improves.
        // Cause detail belongs where it can be acted on: the per-item diagnose snippet
        // names the ITEM, which a count can never do.
        missing_symlinks: (v) => {
          if (v === undefined) return 'symlinks:?';
          return v > 0 ? `symlinks:${v}` : null;
        },
        // config-symlink integrity: $HOME/.claude/CLAUDE.md drifted off its
        // dotfiles-canonical symlink (producer: dhx-health-check.sh; states
        // REAL_FILE | WRONG_TARGET | MISSING). A human phrase (not the raw
        // state) keeps the advisory tail scannable; unknown states fall back to
        // `CLAUDE.md:<state>` so a future producer value never renders blank.
        // Legacy-tolerant `!v || v==='ok'` guard: caches predating this field
        // flow through to null (no warning, no crash) — same contract as the
        // hooks_wiring add (2026-04-26). Recovery shares the tier's trailing
        // `— /dhx:sym repair`, which now restores the link (skills 5547627c — a
        // diverged regular file is backed up + operator-gated, never clobbered).
        claude_md:        (v) => {
          if (!v || v === 'ok') return null;
          const PHRASE = { REAL_FILE: 'CLAUDE.md unlinked', WRONG_TARGET: 'CLAUDE.md mislinked', MISSING: 'CLAUDE.md missing' };
          return PHRASE[v] || `CLAUDE.md:${v}`;
        },
      };

      const critical = [];
      for (const k of TIERS.critical) {
        if (!CRITICAL_PREFIX[k]) continue; // D-10 fail-closed: unknown field treated as absent
        if (h[k] && h[k] !== 'ok') critical.push(`${CRITICAL_PREFIX[k]}:${h[k]}`);
      }

      const advisory = [];
      for (const k of TIERS.advisory) {
        if (!ADVISORY_HANDLERS[k]) continue; // D-10 skip silently: unknown advisory field
        const piece = ADVISORY_HANDLERS[k](h[k]);
        if (piece) advisory.push(piece);
      }

      const front = critical.length
        ? `\x1b[38;5;208m⚠ ${critical.join(' ')} — /dhx:sym repair\x1b[0m`
        : '';
      const tail = advisory.length
        ? `\x1b[31m⚠ ${advisory.join(' ')} — /dhx:sym repair\x1b[0m`
        : '';
      resolve({ front, tail });
    });
  });
}

// --- Fleet drift front-stack segment (SURF-02 render half, phase-10) ---
//
// Surfaces an always-visible orange-208 token (▼N conv) when `required`-level
// conventions went NEWLY-MISSING in the latest cross-repo fleet scan. Silent at
// zero, silent on stale, silent on ANY error — the always-visible surface stays
// trustworthy by showing nothing when there is nothing to act on. The pull
// surface (/dhx:watch list) shows a clean-state line; the statusline does not.
//
// RESOURCE SAFETY (load-bearing — D-14). A SINGLE synchronous read of one thin
// cache file, cloning the sym-health reader pattern above (readFileSync in a
// try/catch). This path NEVER spawns a subprocess — no tmux, git, node-child,
// and it NEVER invokes the scanner. The 2026-04-26 tmux capture-pane wedge
// (reports/done/2026-04-26-statusline-capture-pane-wedge.md) was caused by a
// subprocess spawned per-refresh across 17 concurrent sessions overwhelming the
// single tmux server; a cache-file read is that report's recommended mitigation,
// not the hazard. The expensive scan stays on the daily systemd cadence (Phase 9),
// fully off this render hot path — this fn only reads a number a daily job
// already computed.
//
// FAIL-SILENT (load-bearing — D-03d). The whole body is wrapped in try/catch and
// returns '' on ANY error path: absent file / malformed JSON / NaN or non-finite
// date / unexpected schema_version / stale / non-integer / negative / zero count.
// A '' RETURN renders nothing. A THROW would land in withSegmentDiag's rejection
// arm → computeSegmentSigil → a red `⚠ fleet?` sigil, the OPPOSITE of silence,
// polluting the always-visible surface. This fn must NEVER throw; the call-site
// unwrap also uses a '' fallback as a second line of defense.
//
// Feed contract (producer: cross-repo scripts/fleet/emit-statusline-feed.cjs):
//   { schema_version: 1, required_newly_missing: <non-neg int>, computed_at: <full ISO-8601> }
// computed_at is the emitter's own write-time (hour-resolution ISO), which is
// what lets the ~48h freshness gate work — NOT SUMMARY.json's date-only stamp.
// Counts required_newly_missing ONLY (D-07): the all-enforce-levels view is the
// watch-list's job (SURF-01); the statusline stays required-only because it is
// always-visible. Probe: tests/probes/probe-fleet-statusline-render.js (5 states).
const FLEET_FEED_FILE = path.join(os.homedir(), '.cache', 'dhx', 'fleet-statusline.json');
// ~48h: covers 2 daily scan cycles + RandomizedDelaySec + a sleep grace, with the
// timer's Persistent=true self-healing on wake. newly_missing is inherently
// per-scan, so a stale feed must not assert "newly" drift that should have aged out.
const FLEET_STALE_MS = 48 * 3600 * 1000;

function readFleetFeed() {
  try {
    const feed = JSON.parse(fs.readFileSync(FLEET_FEED_FILE, 'utf8'));
    if (!feed || feed.schema_version !== 1) return '';
    const n = feed.required_newly_missing;
    if (!Number.isInteger(n) || n < 0) return '';
    const ageMs = Date.now() - Date.parse(feed.computed_at);
    if (!Number.isFinite(ageMs) || ageMs < 0 || ageMs >= FLEET_STALE_MS) return '';
    if (n === 0) return ''; // silent at zero
    return `\x1b[38;5;208m▼${n} conv\x1b[0m`;
  } catch {
    return '';
  }
}

// Watch-health front-stack tokens (cross-repo D-08 CONTRACT-01 producer:
// scripts/watch/dhx-watch-health.cjs). Reads the precomputed health verdict — NEVER
// recomputes (D-06). Structural twin of readFleetFeed (own try/catch → '' on ANY
// error, schema-version gate, computed_at freshness gate, silent when healthy) so a
// `⚠ watch?` sigil can never render — but its freshness window is DELIBERATELY 1h,
// NOT FLEET_STALE_MS (48h). The cache is recomputed every SessionStart (the
// dispatcher runs the computer), so computed_at older than 1h means the computer
// didn't run / the symlink is broken — show NOTHING rather than a stale verdict.
// This 1h window is the RENDERER freshness gate; it is distinct from the cache's
// own internal timer_stale_threshold_hours (3h, cross-repo D-04) verdict we read below.
const WATCH_HEALTH_FILE = path.join(os.homedir(), '.cache', 'dhx', 'dhx-watch-health.json');
const HEALTH_CACHE_STALE_MS = 3600 * 1000; // 1h — NOT FLEET_STALE_MS

function readWatchHealth() {
  try {
    const feed = JSON.parse(fs.readFileSync(WATCH_HEALTH_FILE, 'utf8'));
    if (!feed || feed.schema_version !== 1) return '';
    const ageMs = Date.now() - Date.parse(feed.computed_at);
    if (!Number.isFinite(ageMs) || ageMs < 0 || ageMs >= HEALTH_CACHE_STALE_MS) return '';
    const tokens = [];
    // timer_stale: the dead-man's-switch verdict (window #2) — read, not recomputed.
    if (feed.timer_stale === true) tokens.push('watch:stale');
    // failing-items: count interpolated (D-22d — NOT the literal `watch:Nfail`).
    const failing = Array.isArray(feed.failing_items) ? feed.failing_items.length : 0;
    if (failing > 0) tokens.push(`watch:${failing}fail`);
    if (tokens.length === 0) return ''; // silent when healthy
    return `\x1b[38;5;208m${tokens.join(' ')}\x1b[0m`;
  } catch {
    return '';
  }
}

// wsl-pressure alarm flag: written by ~/scripts/health/wsl-pressure-check.sh on a
// `!!` bash-leak trip (>400 bash procs climbing toward the .wslconfig memory ceiling).
// The flag was write-only until readWslPressure() below became its consumer.
const WSL_PRESSURE_FLAG = path.join(os.homedir(), '.local', 'state', 'wsl-stack', 'wsl-pressure-trip.flag');

// wsl-pressure alarm: consumer for the wsl-pressure.timer tripwire (the flag was
// write-only until this segment). RED front member — a !! bash-leak trip is imminent-OOM,
// categorically more severe than the orange-208 advisory members. DURABLE: no staleness
// window, shown until the operator clears WSL_PRESSURE_FLAG after reading the frozen
// capture in ~/.local/state/wsl-stack/pressure.log. Fail-silent: any error → ''.
function readWslPressure() {
  try {
    const first = (fs.readFileSync(WSL_PRESSURE_FLAG, 'utf8').split('\n')[0]) || '';
    // Line 1: "<ISO-ts> !! WSL process-pressure CRITICAL: bash=N (>400) …"
    const m = first.match(/bash=(\d+)/);
    const label = m ? `wsl:bash=${m[1]}` : 'wsl:pressure';
    return `\x1b[31m⚠ ${label}\x1b[0m`;
  } catch {
    return ''; // no flag = no trip = silent
  }
}

// wsl-pressure PROBE-BROKEN flag: written by ~/scripts/health/wsl-pressure-check.sh when
// the monitor ITSELF fails (probe errored / bash-count unparseable → exit 3, NO trip flag).
// The SECOND distinct wsl signal: the trip reader above says "a real leak was detected";
// this says "the monitor is DEAD — you have no detection at all, drifting blind toward the
// same OOM ceiling." A dead monitor is a pull-only fault (systemctl / pressure.log / unit
// failed-state); this surfaces it on the always-visible push surface within ~60s.
const WSL_PRESSURE_BROKEN_FLAG = path.join(os.homedir(), '.local', 'state', 'wsl-stack', 'wsl-pressure-broken.flag');

// wsl-pressure probe-broken alarm. RED — same imminent-OOM severity class as the trip
// (blind ≥ tripped: a trip means the monitor WORKED). EXISTENCE is the signal (the flag's
// content is forensic only), mirroring the trip reader's empty-flag handling. AUTO-RECOVERS:
// the producer rm's this flag on the next healthy classify (ok/warn/crit), so — unlike the
// durable, operator-cleared trip flag — a recovered monitor self-clears (it is not a forensic
// artifact). Fail-silent: any error → '' (absent flag = healthy monitor = silent).
function readWslProbeBroken() {
  try {
    fs.accessSync(WSL_PRESSURE_BROKEN_FLAG);
    return `\x1b[31m⚠ wsl:probe-broken\x1b[0m`;
  } catch {
    return ''; // no flag = monitor healthy = silent
  }
}

// claude-cap bypass flag: written by cross-repo health/scripts/claude-cap-census.sh
// (riding wsl-pressure.timer, every 30 min) when the Claude memory-cap is NOT applying —
// claude procs outside claude-cap-*.scope and/or a login shell no longer resolving
// `claude` to ~/.local/capbin. The flag was write-only until readClaudeCapBypass()
// below became its consumer (the seam was silently bypassed twice in four days, both
// found by hand — cross-repo .planning/debug/resolved/claude-cap-uncapped-launch.md).
const CLAUDE_CAP_BYPASS_FLAG = path.join(os.homedir(), '.local', 'state', 'wsl-stack', 'claude-cap-bypass.flag');

// claude-cap bypass alarm. TWO severity classes, split by CAUSE (the flag's machine
// line carries `capped=N uncapped=N seam_ok=K`):
//   seam_ok=0      → RED `⚠ claude:seam-broken uncapped=N` — the control is dead for
//                    every FUTURE launch (structurally wsl:probe-broken: blind ≥ tripped).
//   seam_ok=1,N>0  → orange-208 `claude:uncapped=N` — historical residue with a healthy
//                    seam; drains on its own as sessions turn over. Advisory, not act-now
//                    (RED here would train the operator to ignore the badge).
//   unparseable    → orange-208 `claude:bypass` — never go silent on a real bypass
//                    (mirrors readWslPressure's `wsl:pressure` fallback; also covers a
//                    lingering pre-seam_ok-format flag).
// NON-STICKY, unlike the operator-cleared trip flag: the census rewrites the flag every
// run and rm's it on a clean one, so absence = census-clean and no rm instruction is
// rendered. Fail-silent: any error → '' (absent flag = cap applying = silent).
function readClaudeCapBypass() {
  try {
    const body = fs.readFileSync(CLAUDE_CAP_BYPASS_FLAG, 'utf8');
    const seam = body.match(/\bseam_ok=([01])\b/);
    const un = body.match(/\buncapped=(\d+)\b/);
    const uncapped = un ? parseInt(un[1], 10) : 0;
    if (seam && seam[1] === '0') return `\x1b[31m⚠ claude:seam-broken uncapped=${uncapped}\x1b[0m`;
    if (seam && uncapped > 0) return `\x1b[38;5;208mclaude:uncapped=${uncapped}\x1b[0m`;
    return `\x1b[38;5;208mclaude:bypass\x1b[0m`;
  } catch {
    return ''; // no flag = cap applying = silent
  }
}

// wsl-stack PRODUCER-LIVENESS guard: the dead-man's switch the three flag readers above
// structurally CANNOT be. All three flags are driven by wsl-pressure.timer; every reader
// keys on flag existence/contents, so a dead/masked timer freezes all three in their last
// state and each reader keeps rendering it as current. wsl-pressure-broken.flag cannot
// cover this — the producer writes it on its OWN exit-3 path, so it means "ran and failed",
// never "never ran". The dangerous case is the SILENT one: claude-cap-bypass.flag ABSENT +
// producer dead reads as "cap applying" when nothing has checked in hours. No per-flag
// staleness window can cover that (there is no flag to hang a window on), which is why this
// is one shared segment keyed on the producers' LOGS, independent of every flag.
//
// Keyed on log MTIME, not on the logs' contents: the two producers write INCOMPATIBLE
// timestamp formats (pressure.log is ISO-8601 UTC `2026-08-15T11:15:16Z`; the census log is
// local-naive `2026-08-15 06:15:16`, no zone), so last-line parsing would need two parsers
// plus a timezone assumption. mtime needs neither — and pressure.log is 74KB+ and growing,
// so a readFileSync here would put an unbounded read on the render path. statSync is O(1).
//
// NOT keyed on FLAG mtime (the trap): for wsl-pressure-trip.flag the mtime IS the trip time,
// and that flag is durable by the 2026-06-15 decision that considered and REJECTED
// auto-clear-on-recovery. An mtime window would silence exactly the flag whose staleness is
// the intended behavior.
const WSL_PRESSURE_LOG = path.join(os.homedir(), '.local', 'state', 'wsl-stack', 'pressure.log');
const WSL_CENSUS_LOG   = path.join(os.homedir(), '.local', 'state', 'wsl-stack', 'claude-cap-census.log');

// 95min. DERIVED, not guessed. The unit is OnUnitActiveSec=30min + RandomizedDelaySec=60s,
// AccuracySec defaulting to 1min → 32min nominal max interval, so two missed opportunities
// are 64min. But measured reality is looser than the schedule: across 44 days / 1999
// intervals of pressure.log the max gap that was NOT downtime is 60.2min (p99 31.3min), so a
// 65min threshold would have carried under 5min of headroom. The guard's job is to report a
// dead monitor in time to MATTER, and that is bounded by the ~18h OOM runway the unit's own
// comment cites — not by two cadences. 95min buys ~35min of headroom over the observed max
// while still consuming under 9% of the runway. Trading detection latency for false-positive
// immunity is nearly free here; a RED that cries wolf would degrade the two real RED alarms
// beside it.
const WSL_MONITOR_DEAD_MS = 95 * 60 * 1000;

// Boot grace CEILING — a backstop, no longer the primary mechanism. After every WSL2 start
// the logs are legitimately as old as the downtime until the first run lands, so the segment
// must stay silent until the producer has had its chance. The question that actually matters
// is "has the timer fired yet this boot?", and systemd answers it directly (see
// WSL_PRESSURE_TIMER_STAMP below) — this constant only bounds how long we wait for that
// answer, so an absent or frozen stamp can never suppress the guard forever.
//
// WHY THIS IS NOT AN ELAPSED-TIME GATE ANY MORE. It was, keyed on /proc/uptime, and that was
// wrong by construction: `OnBootSec=5min` on a systemd USER manager is anchored to MANAGER
// START, while /proc/uptime is anchored to KERNEL BOOT, and the gap between them is the
// manager's own startup latency. Measured across 16 boots of user-journal data:
//   manager start after kernel boot   2.99s .. 134.05s   (the unbounded term)
//   first run after MANAGER start   316.5s .. 362.3s     (tight — 45.8s = RandomizedDelaySec)
//   first run after KERNEL boot     332.9s .. 490.0s     (loose — inherits the latency above)
// On boot -6 the manager came up at 134.05s and the first run landed at 489.976s, past the
// then-480s grace: a ~10s window rendering a RED on a healthy box (2026-08-07). No constant
// fixes that class — the manager-start term has no upper bound — which is why the gate now
// keys on the event instead of on elapsed time. 12min is chosen only to clear the observed
// 490.0s worst case with ~47% headroom while a stamp is unavailable.
//
// RESIDUAL (stated, not implied away): a host SUSPEND still defeats this. `man systemd.timer`
// is explicit that without WakeSystem= a monotonic timer's clock pauses while suspended, so on
// a sleeping host the schedule freezes while log mtime keeps aging — the guard could
// false-positive for up to one cadence after resume, and the stamp would be equally stale
// because the timer genuinely did not fire. It does not bite here: CLOCK_BOOTTIME minus
// CLOCK_MONOTONIC measured 0.000s over 48.51h, and `journalctl -b all` across 17 boots shows
// zero suspend events. If a sleeping host ever enters scope the lever is the UNIT, not this
// file — `OnCalendar=` makes Persistent= catch-up live (the unit's own comment names it).
// Contract + re-derivation procedure: cross-repo docs/coupling/wsl-monitor-liveness-thresholds.md.
const WSL_MONITOR_BOOT_GRACE_MS = 12 * 60 * 1000;

// systemd writes this stamp on EVERY trigger of wsl-pressure.timer — its mtime IS the last
// trigger time, maintained by the scheduler itself rather than inferred from a producer's
// side effects. Verified ordering on a live run: stamp 09:50:17.444, then the census log at
// .947 and pressure.log at .951 — the stamp leads the producers by ~0.5s.
//
// The unit's own comment calls its `Persistent=true` INERT, and that is true of CATCH-UP
// (monotonic triggers only) but NOT of the stamp: systemd maintains the file regardless, so
// this signal costs nothing and needs no unit change.
//
// It proves the TIMER fired, never that the producer COMPLETED — which is exactly why it
// anchors the grace and does not replace the log-mtime staleness check. (The pair is strictly
// more expressive than either alone: fresh stamp + stale log = ran-but-did-not-finish, a
// distinction this segment cannot currently draw. Filed, not built here.)
//
// Bonus the /proc/uptime anchor could never have: this path is under $HOME, so makeFakeHome()
// fixtures drive it directly — the exact limitation readUptimeMs() documents below.
const WSL_PRESSURE_TIMER_STAMP = path.join(
  os.homedir(), '.local', 'share', 'systemd', 'timers', 'stamp-wsl-pressure.timer');

// Seconds-since-boot as ms. Own try/catch → null (unreadable /proc/uptime must not be able to
// suppress the guard AND must not be able to fabricate one) — null means "cannot apply the
// boot grace", and classify below treats that as "grace does not apply" rather than as fresh.
function readUptimeMs() {
  // Probe hook, mirroring REGISTRY_STARTUP_SUPPRESS_MS's DHX_WSL_UPTIME_MS-style override:
  // /proc/uptime is not under $HOME, so a makeFakeHome() fixture cannot control it and a
  // render-level probe would behave differently on a freshly-booted machine. Validated, not
  // blindly trusted — a non-numeric or negative value falls through to the real read.
  const override = parseFloat(process.env.DHX_WSL_UPTIME_MS);
  if (Number.isFinite(override) && override >= 0) return override;
  try {
    const secs = parseFloat(String(fs.readFileSync('/proc/uptime', 'utf8')).split(/\s+/)[0]);
    return (Number.isFinite(secs) && secs >= 0) ? secs * 1000 : null;
  } catch {
    return null;
  }
}

// Age of a producer log in ms, or null when it cannot be judged (absent / unreadable /
// future mtime). null is deliberately NOT "stale": an ABSENT log is indistinguishable from
// never-installed, and every reader in this family treats absent as silent. That is a real
// coverage hole, documented rather than hidden.
function wslLogAgeMs(file, now) {
  try {
    const ageMs = now - fs.statSync(file).mtimeMs;
    return (Number.isFinite(ageMs) && ageMs >= 0) ? ageMs : null;
  } catch {
    return null;
  }
}

// FOUR-state classification, exported for deterministic tests. NOT a first-match priority:
// pressure-stale does not prove "the timer stopped". The census rides the pressure script's
// tail via `[ -x "$CAPCENSUS" ] && { "$CAPCENSUS" --quiet || true; }` — a missing or
// non-executable script is skipped SILENTLY and a failure is swallowed, so the census can
// freeze while pressure stays fresh. And the pressure log is written BEFORE the census is
// invoked, so the converse (pressure log write fails, census still runs) is reachable too.
// Each label therefore names the producer observed stale; none asserts an unproved cause.
//   both stale     → 'monitor'  (nothing in the stack has checked in)
//   pressure only  → 'pressure' (trip + probe-broken flags unvouched)
//   census only    → 'census'   (claude-cap-bypass flag unvouched)
//   neither        → null       (silent)
// Has wsl-pressure.timer fired since THIS boot? Compares the systemd stamp's mtime against
// boot wall-time (now - uptime). Own try/catch → false, and false means "grace still applies",
// which is safe precisely because the grace is now ceiling-bounded: an absent stamp (timer
// never installed) or an unreadable one delays the guard by at most WSL_MONITOR_BOOT_GRACE_MS
// rather than suppressing it indefinitely. A stamp left over from a PREVIOUS boot correctly
// reads as "not yet fired" — its mtime predates boot wall-time.
function readTimerFiredSinceBoot(uptimeMs, now) {
  if (uptimeMs === null) return false; // cannot locate boot; let the ceiling govern
  try {
    return fs.statSync(WSL_PRESSURE_TIMER_STAMP).mtimeMs > (now - uptimeMs);
  } catch {
    return false;
  }
}

function classifyWslMonitorState(pressureAgeMs, censusAgeMs, uptimeMs, timerFiredSinceBoot) {
  // Post-boot grace: suppress only while the scheduler has NOT yet fired this boot, and only
  // up to the ceiling. Once the timer has fired, a stale log is real evidence, not boot lag.
  if (!timerFiredSinceBoot && uptimeMs !== null && uptimeMs < WSL_MONITOR_BOOT_GRACE_MS) return null;
  const stale = (a) => a !== null && a >= WSL_MONITOR_DEAD_MS;
  const p = stale(pressureAgeMs);
  const c = stale(censusAgeMs);
  // NEWER of the two, not older. The token renders `wsl:monitor-dead <age>`, and the pull
  // surface renders it as the sentence "no producer has checked in for <age>" — which is only
  // true of the MOST RECENT write across both producers. Math.max named the oldest producer's
  // downtime and asserted it as the coverage gap: 2h-stale pressure + 9h-stale census claimed
  // "no producer has checked in for 9h" when one had checked in 2h ago.
  // WHY the worst-case age is not the thing to report here: 'monitor' fires only once BOTH are
  // stale, so a long-dark producer was already on screen as 'census-dead 9h' (or 'pressure-dead')
  // the whole time it was dark. The new fact at this transition is total blindness, which began
  // when the newer producer went quiet. Reporting max re-reports the old outage under a new label.
  // The per-producer detail is not lost — the /dhx:infra pull surface prints both ages beneath
  // the headline (surface-monitor-liveness.sh, monitor branch), per the push/pull split this
  // family already follows: push carries the actionable now-state, pull carries the forensics.
  // INVARIANT: the bash twin wsl_state() in ~/repos/skills/dhx/infra/references/
  // wsl-monitor-liveness.sh MUST select the same end of the range (`p < c ? p : c`). Two
  // different ages for one condition trains distrust in the guard. Pinned from both sides:
  // this probe's newer-age assertion, and scenario 10 of skills' probe-infra-monitor-liveness.sh.
  if (p && c) return { kind: 'monitor', ageMs: Math.min(pressureAgeMs, censusAgeMs) };
  if (p) return { kind: 'pressure', ageMs: pressureAgeMs };
  if (c) return { kind: 'census', ageMs: censusAgeMs };
  return null;
}

const WSL_MONITOR_LABELS = { monitor: 'wsl:monitor-dead', pressure: 'wsl:pressure-dead', census: 'wsl:census-dead' };

// Producer-liveness reader. RED — same imminent-OOM severity class as the trip and
// probe-broken tokens (blind >= tripped), and broader than either: a dead producer
// invalidates all three flags at once. Returns BOTH the token and the state kind, because
// the front-stack composition below needs the kind to arbitrate which stale flags to
// suppress. Fail-silent: any error → { token: '', kind: null }.
// Age rendered via formatBurnDuration (already in-file: `<1m` / `47m` / `1h58m` / `Xh` / `Nd`) —
// 5min-over-threshold and 3-days-dead are different situations and the operator should not
// have to go pull a log to tell them apart.
function readWslMonitorState() {
  try {
    const now = Date.now();
    const uptimeMs = readUptimeMs();
    const state = classifyWslMonitorState(
      wslLogAgeMs(WSL_PRESSURE_LOG, now),
      wslLogAgeMs(WSL_CENSUS_LOG, now),
      uptimeMs,
      readTimerFiredSinceBoot(uptimeMs, now),
    );
    if (!state) return { token: '', kind: null };
    const age = formatBurnDuration(state.ageMs / 60000);
    const label = WSL_MONITOR_LABELS[state.kind];
    return { token: `\x1b[31m⚠ ${label}${age ? ' ' + age : ''}\x1b[0m`, kind: state.kind };
  } catch {
    return { token: '', kind: null }; // fail-silent, exactly like the three flag readers
  }
}

// Front-stack composition for the wsl cluster — a PURE function so the arbitration is
// testable without a render. The three flag readers stay byte-for-byte untouched; arbitration
// happens here at composition time, which is where runMain already orders and joins results.
//
// WHY arbitrate at all: the invariant this whole family serves is "never assert a verdict you
// cannot vouch for". When a producer is confirmed stale, ITS flag is an unvouched last-known
// state — continuing to render it as a current RED verdict violates the same invariant the
// liveness guard exists to enforce. So suppress exactly the flag whose producer is stale,
// and no more:
//   - trip ALWAYS survives. It is durable and operator-cleared by decision; its whole point is
//     that it outlives the incident, so staleness is a feature and suppression would be a bug.
//   - pressure stale → suppress probe-broken (same producer).
//   - census stale   → suppress claude-cap-bypass (same producer).
// The suppressed detail is not lost — the /dhx:infra pull surface reports it as "last known,
// stale". Push shows the actionable now-state; pull carries the forensics.
// Order: trip → monitor-liveness → probe-broken → cap-bypass (trip's FIRST slot is a locked
// do-not-re-litigate decision; liveness slots in second because a dead producer is broader
// than a broken probe — it invalidates the census and the cap flag too).
function composeWslFront({ trip, monitor, broken, bypass }) {
  const out = [];
  if (trip) out.push(trip);
  if (monitor && monitor.token) out.push(monitor.token);
  const kind = monitor && monitor.kind;
  const pressureStale = kind === 'monitor' || kind === 'pressure';
  const censusStale   = kind === 'monitor' || kind === 'census';
  if (broken && !pressureStale) out.push(broken);
  if (bypass && !censusStale) out.push(bypass);
  return out;
}

// ---------------------------------------------------------------------------
// Skill-pressure segment (D-01/D-02/D-03, Phase 24)
// Reads reports/skills/*/actionable/*.md from the skills repo, counts files
// whose `status` ∈ PRESSURE_STATUSES, and returns a compact ⚑N token (or ''
// at zero). All errors are swallowed — this segment is fully fail-silent.
// ---------------------------------------------------------------------------

// Mirror _OPEN_STATUSES from tests/lib/skills_report_lint.py exactly.
const PRESSURE_STATUSES = new Set(['active', 'needs-verify', 'regressed']);

// D-02: resolve the skills-repo root. Returns null if no candidate passes
// existence-validation against reports/skills/. Never throws.
function resolveSkillsRoot() {
  const candidates = [];
  // Step 1: env override — enables worktrees, alternate layouts, test harnesses.
  // Validated candidate, not unconditional: a valid path wins; an invalid value
  // falls through to Steps 2-3. You cannot force resolveSkillsRoot→null via a bad
  // DHX_SKILLS_REPO alone — all three tiers must fail accessSync(reports/skills).
  if (process.env.DHX_SKILLS_REPO) {
    candidates.push(process.env.DHX_SKILLS_REPO);
  }
  // Step 2: symlink-derive — realpath dhx-plugin/plugins/dhx/skills → parent.
  // The symlink resolves to ~/repos/skills/dhx; its PARENT is the repo root.
  // The PARENT correction is load-bearing: realpathing the marketplace path
  // alone lands in the hooks repo, not the skills repo. (Verified 2026-05-29.)
  try {
    const pluginSkillsLink = path.join(__dirname, '..', 'dhx-plugin', 'plugins', 'dhx', 'skills');
    const realSkills = fs.realpathSync(pluginSkillsLink);
    candidates.push(path.dirname(realSkills));
  } catch { /* broken symlink — fall through to hardcode */ }
  // Step 3: hardcoded fallback.
  candidates.push(path.join(os.homedir(), 'repos', 'skills'));

  for (const c of candidates) {
    try {
      fs.accessSync(path.join(c, 'reports', 'skills'));
      return c;
    } catch { /* ENOENT or broken — try next */ }
  }
  return null; // no valid candidate
}

// Inline status-only frontmatter parser (R-01: do NOT require()
// backlog-frontmatter-validator.cjs — it is not exported and calls
// main()+process.exit() at line 244, which would terminate the statusline
// process at require time). Logic copied from
// ~/repos/hooks/scripts/lib/backlog-frontmatter-validator.cjs lines 86-133.
// Returns only the `status` string, or null on parse failure.
function parseStatusFromFrontmatter(raw) {
  if (typeof raw !== 'string') return null;
  if (!raw.startsWith('---')) return null;
  const lines = raw.split(/\r?\n/);
  let end = -1;
  for (let i = 1; i < lines.length; i++) {
    if (lines[i] === '---') { end = i; break; }
  }
  if (end === -1) return null;
  for (const line of lines.slice(1, end)) {
    const m = line.match(/^status:\s*(.*)$/);
    if (!m) continue;
    let val = m[1].trim();
    // Strip outer single OR double quotes (WR-03 logic from validator).
    if (val.length >= 2) {
      const first = val[0];
      const last = val[val.length - 1];
      if ((first === '"' && last === '"' && !val.slice(1, -1).includes('"')) ||
          (first === "'" && last === "'" && !val.slice(1, -1).includes("'"))) {
        val = val.slice(1, -1);
      }
    }
    return val;
  }
  return null; // no status key found
}

const SKILL_PRESSURE_SIZE_CAP = 64 * 1024; // R-04: skip files >64 KB

// D-01: count files in reports/skills/*/actionable/ whose status ∈ PRESSURE_STATUSES.
// Returns {pressure, parseMs}. Fail-silent per-file and per-dir.
function countSkillPressure(skillsRoot) {
  const t0 = Date.now();
  let pressure = 0;
  try {
    const reportsSkills = path.join(skillsRoot, 'reports', 'skills');
    const skillDirs = fs.readdirSync(reportsSkills, { withFileTypes: true })
      .filter(e => e.isDirectory())
      .map(e => path.join(reportsSkills, e.name, 'actionable'));
    for (const actionDir of skillDirs) {
      try {
        const files = fs.readdirSync(actionDir).filter(f => f.endsWith('.md'));
        for (const f of files) {
          const filePath = path.join(actionDir, f);
          try {
            // R-04: size cap — skip files larger than SKILL_PRESSURE_SIZE_CAP.
            const stat = fs.statSync(filePath);
            if (stat.size > SKILL_PRESSURE_SIZE_CAP) continue;
            // R-04: leading-frontmatter-only scan — read up to 4 KB (ample for
            // any frontmatter block) rather than the whole file body.
            const fd = fs.openSync(filePath, 'r');
            const buf = Buffer.alloc(4096);
            const bytesRead = fs.readSync(fd, buf, 0, 4096, 0);
            fs.closeSync(fd);
            const raw = buf.slice(0, bytesRead).toString('utf8');
            const status = parseStatusFromFrontmatter(raw);
            if (status && PRESSURE_STATUSES.has(status)) pressure++;
          } catch { /* unreadable file — D-01 fail-silent, skip */ }
        }
      } catch { /* missing actionable/ dir — expected for skills with no items */ }
    }
  } catch { /* reportsSkills unreadable — D-01 fail-silent */ }
  return { pressure, parseMs: Date.now() - t0 };
}

// D-01: read skill pressure, return '' on zero or any error (fail-silent).
// Logs to STATUSLINE_ERROR_FILE only on error or slow parse (R-03: NOT
// unconditionally on every refresh — hot-path I/O noise).
function readSkillPressure() {
  try {
    const skillsRoot = resolveSkillsRoot();
    if (!skillsRoot) return '';
    const { pressure, parseMs } = countSkillPressure(skillsRoot);
    // R-03: log only on slow parse (≥50 ms) — revisit trigger per D-01.
    if (parseMs >= 50) {
      try {
        const ts = new Date().toISOString();
        const line = JSON.stringify({ ts, segment: 'skillPressure', slow: true, skillsRoot, pressure, parseMs }) + '\n';
        fs.appendFile(STATUSLINE_ERROR_FILE, line, () => {});
      } catch { /* log failure must never block statusline */ }
    }
    if (pressure === 0) return ''; // D-03: silent at zero
    return `\x1b[38;5;208m⚑${pressure}\x1b[0m`; // D-03: aggregate token, orange 208
  } catch {
    return ''; // D-01: fail-silent on any error
  }
}

// Process start-time in clock ticks since boot, read from /proc/<pid>/stat field 22.
// Stable per-process within a boot (immune to PID reuse). Returns null on
// non-Linux / unreadable.
function getProcessStartTicks(pid) {
  try {
    const stat = fs.readFileSync(`/proc/${pid}/stat`, 'utf8');
    // "comm" field can contain spaces/parens; canonical parse is split after last ')'
    const after = stat.substring(stat.lastIndexOf(')') + 2);
    return after.split(' ')[19] || null; // starttime = field 22 (1-indexed) = index 19 after comm
  } catch { return null; }
}

// CC wraps statusLine.command in a shell because the command string contains $HOME,
// so process.ppid is an ephemeral shell whose start-ticks rotate per refresh. Walk
// past shells to the first non-shell ancestor — that's the CC process — and key
// drift snapshots on its start-ticks. Stable for the CC process's life, distinct
// across /resume (which spawns a new CC process). Returns null on non-Linux,
// unreadable /proc, or if every ancestor within MAX_HOPS is a shell (caller falls
// back to session_id-only keying, accepting the stale-snapshot risk).
const SHELL_COMMS = new Set(['sh', 'bash', 'zsh', 'dash', 'fish', 'tcsh', 'ksh']);
function findCCTicks(startPpid) {
  const MAX_HOPS = 5;
  let pid = startPpid;
  for (let i = 0; i < MAX_HOPS && pid > 1; i++) {
    try {
      const stat = fs.readFileSync(`/proc/${pid}/stat`, 'utf8');
      const comm = stat.substring(stat.indexOf('(') + 1, stat.lastIndexOf(')'));
      const after = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
      if (!SHELL_COMMS.has(comm)) {
        return after[19] || null; // starttime = field 22
      }
      pid = parseInt(after[1]); // ppid
    } catch { return null; }
  }
  return null;
}

// Top-level settings.json keys whose mutations invalidate the CC session.
// Everything else (effortLevel, model, outputStyle, theme, permissions,
// statusLine, cleanupPeriodDays, skipDangerousModePermissionPrompt) is
// session-safe and must stay out of the drift hash — otherwise /effort,
// /model, permission-grant writes all trip the warning every 60s and train
// users to ignore the signal. `agents/` drift is a separate `agents_mtime`
// path; `env` may be absent from live settings (handled by projection).
const SETTINGS_WARN_KEYS = ['hooks', 'enabledPlugins', 'extraKnownMarketplaces', 'env'];

// Recursively sort object keys so JSON.stringify produces byte-stable output
// regardless of which CC writer last serialized the file. Arrays preserve
// order — `.hooks[event][*]` sequence is semantic.
function canonicalize(value) {
  if (value === null || typeof value !== 'object') return value;
  if (Array.isArray(value)) return value.map(canonicalize);
  const out = {};
  for (const key of Object.keys(value).sort()) {
    out[key] = canonicalize(value[key]);
  }
  return out;
}

// SHA-256 over the canonicalized WARN-set projection of settings.json. Used
// as the drift snapshot's settings signal. Missing keys are simply omitted
// from the projection (not null-substituted) so a file with no `env` key
// produces the same hash whether or not the writer ever touched `env`.
// Unreadable/unparseable settings collapse to '' — consistent-bad state is
// stable, so no false drift on a persistently missing file.
function hashWarnSettings(settingsReal) {
  try {
    const parsed = JSON.parse(fs.readFileSync(settingsReal, 'utf8'));
    const projection = {};
    for (const key of SETTINGS_WARN_KEYS) {
      if (key in parsed) projection[key] = parsed[key];
    }
    return crypto.createHash('sha256').update(JSON.stringify(canonicalize(projection))).digest('hex');
  } catch { return ''; }
}

// Helper: resolve a recursive-readdir Dirent to its parent directory.
//
// LOAD-BEARING ENGINE CONTRACT. `fs.readdirSync(dir, {withFileTypes:true,
// recursive:true})` reports each entry's parent directory ON the Dirent, but the
// property was renamed across Node majors: `dirent.path` (Node 20.1-23,
// deprecated DEP0178) -> `dirent.parentPath` (Node >= 20.12). Node 24 REMOVED
// `dirent.path` outright.
//
// Reading `entry.path` alone with a `join(scanRoot, entry.name)` fallback is NOT
// a safe default. On Node 24 the ternary takes the fallback for EVERY entry, so
// every nested path collapses to `<root>/<basename>`: the walk flattens, statSync
// 404s on nested files (mtime 0 / kind 'unreadable'), and any caller keying on
// path SEGMENTS -- classifyEntry's segment-0 marketplace check -- sees the bare
// filename and classifies everything `novel`. The result is a total drift
// FALSE-NEGATIVE, not a crash: the statusline renders clean and detects nothing.
// This is precisely the failure mode scanRecursive's own D-20 comment predicts.
//
// Observed 2026-08-23: the host's `nvm alias default` moved 22 -> 24 on
// 2026-08-19 18:18 and six probes went red at an UNCHANGED HEAD. Peer precedent
// for the correct idiom predates it by four months -- forgefinder
// `scripts/hub.js` `d.parentPath ?? d.path` (9294e138, 2026-04-23).
// See docs/decisions.md 2026-08-23 row and HP-056.
//
// Order is load-bearing: `parentPath` first (the surviving property), `path`
// second (pre-20.12 engines), scan root last (top-level-only fallback).
function direntParent(entry, root) {
  return entry.parentPath || entry.path || root;
}

// Helper: recursively scan a directory, returning both max mtime AND entry count.
// Count is zero extra I/O — readdirSync({recursive:true}) enumerates everything
// anyway, so counting the returned array is free. Both signals feed checkDrift()'s
// compare — mtime catches new/modified files; count catches deletions that would
// otherwise shrink the recursive max below the snapshot and silently slip past the
// strict `>` comparison. See docs/decisions.md 2026-04-18 drift-bundle row.
//
// INVARIANT: POSIX directory mtime does NOT bump on descendant writes — only on
// direct-child add/remove. A plugin version update writing into
// marketplace/plugin/1.0/hook.json leaves marketplace's own mtime frozen, so any
// shallow scan of plugins/cache misses the drift. This is why the scan must
// recurse even for plugins (where the prior shallow scan was specifically
// broken).
//
// `ignoreBasenames` (optional Set<string>): filter CC-internal bookkeeping files
// that churn without reflecting user-actionable state. Currently used for the
// plugins/cache scan to drop `.orphaned_at` markers — CC writes these during
// session-start orphan sweeps and periodic GC, and because `~/.ccs/shared/plugins/cache`
// is shared across all CCS instances, any sibling session's sweep false-positives
// every running session's drift signal. Filtering affects both mtime and count,
// so an orphan sweep is invisible to checkDrift while real plugin writes are still
// caught. See docs/decisions.md 2026-04-23 orphaned_at filter row.
function scanRecursive(dir, keepPredicate) {
  let maxMtime = 0;
  let count = 0;
  // `maxPath` is the file path whose mtime won the scan — additive forensic
  // signal for the drift-debug breadcrumb (plugins trigger only; see
  // checkDrift() and docs/statusline-wrapper.md § "Debug breadcrumb").
  // Always paired with maxMtime inside the same conditional so the path
  // never desyncs from the mtime it describes. Callers that don't read
  // `.maxPath` are unaffected (agents/gsd consumers).
  let maxPath = '';
  try {
    const entries = fs.readdirSync(dir, { withFileTypes: true, recursive: true });
    for (const entry of entries) {
      // Allowlist inversion (D-04): a single optional `keepPredicate(rel, basename)
      // -> bool` replaces the former two denylist params (ignoreBasenames /
      // ignorePathPattern). The agents/gsd callers pass nothing → undefined →
      // every entry is kept (unchanged behavior). The `plugins` caller passes
      // (rel,b) => classifyEntryFn(rel,b) === 'content', so only content-
      // classified entries advance the drift mtime/count (D-03).
      //
      // D-20 (LOAD-BEARING): keepPredicate MUST receive a CACHE-ROOT-RELATIVE,
      // forward-slash-normalized path — NOT the absolute `full`. classifyEntry
      // checks segment 0 against marketplaceTopLevel; feeding the absolute path
      // makes segment 0 = `home`/`.ccs` → marketplaceTopLevel never matches →
      // every entry classifies `novel` → `=== 'content'` never true → the
      // `plugins` trigger silently never fires (total drift false-negative).
      // This mirrors enumerateNovelPatterns' rel-normalization at :911-912.
      if (keepPredicate) {
        const full = path.join(direntParent(entry, dir), entry.name);
        const rel = path.relative(dir, full).split(path.sep).join('/');
        if (!keepPredicate(rel, entry.name)) continue;
      }
      count++;
      // Skip directory mtimes: POSIX bumps a dir's mtime on any direct-child
      // add/remove, which leaks through the ignoreBasenames filter (creating
      // a filtered-basename file still touches its parent dir). Directories
      // contribute nothing the file-level scan doesn't already capture — a
      // new file carries its own fresh mtime, and deletions are caught by
      // the count branch, not by mtime. Skipping dirs is safe across all
      // three trees (agents/gsd/plugins) — see probe scenarios [2]-[4].
      if (entry.isDirectory && entry.isDirectory()) continue;
      try {
        const full = path.join(direntParent(entry, dir), entry.name);
        const st = fs.statSync(full);
        if (st.mtimeMs > maxMtime) {
          maxMtime = st.mtimeMs;
          maxPath = full;
        }
      } catch { /* skip */ }
    }
  } catch { /* missing dir */ }
  return { maxMtime, count, maxPath };
}

// Shared plugins/cache allowlist module (RAT-04, D-06 + D-14). Consolidates
// the former inline `PLUGIN_CACHE_IGNORE` (bookkeeping basename Set) and
// `PLUGIN_CACHE_PATH_IGNORE` (bookkeeping path-segment RegExp) constants into
// one documented in-code allowlist that is ALSO consumed by the renderer
// (dhx-statusline.js, Plan 03's render-time re-filter) — it cannot stay inline.
// `scripts/lib/` is the established shared-code home (tiers.json `require` at
// :641). Wrapped in the same try/catch-fallback discipline as tiers.json: a
// missing/unparseable module falls back to the historical bookkeeping
// constants so the `plugins` drift trigger keeps filtering — the UI hot path
// stays alive. `PLUGIN_CACHE_ALLOWLIST.bookkeepingBasenames` /
// `.bookkeepingPathPattern` drive `scanRecursive`'s `ignoreBasenames` /
// `ignorePathPattern` filter (the dual-use members; the rest of the allowlist
// — legitContentBasenames/Segments, versionDirPattern, marketplaceTopLevel,
// the isAllowlisted predicate — backs RAT-04 novel-pattern enumeration).
// See docs/decisions.md 2026-04-23 (.orphaned_at), 2026-04-27 (temp_git_*),
// 2026-05-13 (.in_use/<pid>) rows for the filter lineage this consolidates.
let PLUGIN_CACHE_ALLOWLIST = {
  bookkeepingBasenames: new Set(['.orphaned_at']),
  bookkeepingPathPattern: /(^|\/)(temp_git_\d+_[a-z0-9]+|\.in_use)(\/|$)/,
};
// Default predicate when the shared module is unavailable: treat everything as
// novel-candidate-free (return true) so a missing module never produces a
// flood of false `⚠ cc-novel` hits — RAT-04 degrades to "detector inert", not
// "detector noisy". The bookkeeping fallback above still drives the drift
// filter. Replaced by the real predicate on a successful require.
let isAllowlistedPattern = () => true;
// Default classifier when the shared module is unavailable (D-08 / D-23). The
// `plugins` drift trigger's keepPredicate (collectSnapshot, Site 2) tests
// `classifyEntryFn(rel,b) === 'content'`, so a missing/bad module MUST still
// have a working 2-state classifier — otherwise the predicate would crash or
// silence drift entirely. This inline fallback degrades to TODAY'S DENYLIST
// behavior: it returns 'bookkeeping' for the inline bookkeeping constants
// (`.orphaned_at` basename; `temp_git_*` / `.in_use` path segments) and
// 'content' for everything else. It NEVER returns 'novel' (D-08: a missing
// module must never manufacture novel hits — the inverse of the
// `isAllowlistedPattern = () => true` "detector inert, never noisy" posture for
// enumeration) and NEVER throws (D-23 / ASVS V5: same `typeof` input guards as
// the real classifyEntry, so a non-string / null / empty filePath or basename
// returns a string instead of crashing `.test()` / `.has()`). Replaced by the
// real classifyEntry on a successful, complete require (the typeof gate below).
let classifyEntryFn = function (filePath, basename) {
  if (typeof basename === 'string') {
    if (PLUGIN_CACHE_ALLOWLIST.bookkeepingBasenames.has(basename)) return 'bookkeeping';
  }
  if (typeof filePath === 'string') {
    if (PLUGIN_CACHE_ALLOWLIST.bookkeepingPathPattern.test(filePath)) return 'bookkeeping';
  }
  // Everything else is content — denylist-equivalent degradation; the fallback
  // never manufactures a novel hit (D-08).
  return 'content';
};
try {
  const allowlistMod = require('../scripts/lib/plugin-cache-allowlist.js');
  PLUGIN_CACHE_ALLOWLIST = allowlistMod.PLUGIN_CACHE_ALLOWLIST;
  isAllowlistedPattern = allowlistMod.isAllowlisted;
  // D-23 typeof gate: adopt the real classifier ONLY when it is actually a
  // function. A partial / bad module load (export missing or non-function)
  // RETAINS the inline fallback above rather than setting classifyEntryFn =
  // undefined, which would crash the keepPredicate path in collectSnapshot.
  if (typeof allowlistMod.classifyEntry === 'function') {
    classifyEntryFn = allowlistMod.classifyEntry;
  }
} catch (e) {
  // Fall back gracefully if the shared module is missing or unparseable. The
  // inline default above keeps the `plugins` drift filter behaving exactly as
  // the pre-consolidation constants did — drift detection never regresses on
  // a bad module load. RAT-04 enumeration degrades to "no allowlist module"
  // (isAllowlistedPattern returns true → zero novel hits) and is itself
  // try/catch-guarded at its call site. classifyEntryFn keeps the inline
  // denylist-equivalent fallback (D-08 — never 'novel', never throws).
}

// RAT-04 novel-pattern enumeration (D-02 / D-13a / D-14). Walks the
// `plugins/cache` tree once and returns the leaf entries whose path + basename
// match NO member of the shared allowlist — "novel" file classes that appeared
// under `plugins/cache` and warrant operator attention after a CC upgrade.
//
// fs-ONLY (D-12) — no subprocess. Reuses the same
// `fs.readdirSync(dir, {withFileTypes:true, recursive:true})` walk shape as
// `scanRecursive` (deliberately not a hand-rolled recursion). For each
// non-directory entry, the relative path (forward-slash joined, relative to
// `pluginsCacheRoot`) + the leaf basename are tested against
// `isAllowlistedPattern`; an entry that is NOT allowlisted is collected as
// `{ path, basename, first_seen_mtime }` (mtime in ms).
//
// `pluginsCacheRoot` is an optional fixture-root arg (D-11) — defaults to the
// live `plugins/cache` path the `plugins` drift trigger derives
// (`$CLAUDE_CONFIG_DIR/plugins/cache`). The whole walk is wrapped in
// `try { } catch { return []; }` so an unreadable / poisoned `plugins/cache`
// yields no novel signal rather than throwing out of `checkDrift` (T-17-02).
//
// CRITICAL: this is invoked ONLY from `checkDrift`'s `version`-change branch
// (once per CC version transition — Pattern 4 / Pitfall 2). It is NOT called
// from `collectSnapshot` (which runs every refresh — calling it there would
// re-walk the tree ~1Hz and defeat the once-per-cohort contract). It also does
// NOT reuse `collectSnapshot`'s `scanRecursive` result — that call produces
// the snapshot's mtime/count for the `plugins` trigger; enumeration needs
// per-entry path + basename, so it does its own scan inside the version branch.
function enumerateNovelPatterns(pluginsCacheRoot) {
  const root = pluginsCacheRoot || path.join(
    process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude'),
    'plugins', 'cache',
  );
  const novel = [];
  try {
    const entries = fs.readdirSync(root, { withFileTypes: true, recursive: true });
    for (const entry of entries) {
      if (entry.isDirectory && entry.isDirectory()) continue;
      // Engine-portable parent dir (see direntParent above: Node 24 removed
      // `entry.path`; `parentPath` is the surviving property).
      const absParent = direntParent(entry, root);
      const absFull = path.join(absParent, entry.name);
      // Relative-to-cache-root path, forward-slash normalized — the shape the
      // allowlist predicate's per-segment logic expects.
      const rel = path.relative(root, absFull).split(path.sep).join('/');
      if (isAllowlistedPattern(rel, entry.name)) continue;
      let mtime = 0;
      try { mtime = fs.statSync(absFull).mtimeMs; } catch { /* unreadable — keep 0 */ }
      novel.push({ path: rel, basename: entry.name, first_seen_mtime: mtime });
    }
  } catch {
    return []; // unreadable plugins/cache → no novel signal (T-17-02 graceful path)
  }
  return novel;
}

// GSD fork-aware drift suppression roots. Live tree is the install snapshot
// `/gsd:update` rewrites; canonical fork mirror holds the user's local patches
// re-applied by the fork-sync command. See `isGsdDriftFromForkSync()` below
// and docs/statusline-wrapper.md § "Fork-aware suppression (gsd trigger only)".
//
// INVARIANT: both roots MUST track the live gsd install dir name. 2026-06-05
// `@opengsd/gsd-core@1.3.1` renamed `get-shit-done/` -> `gsd-core/` (live) and
// migrated the fork mirror to `gsd-local-patches/gsd-core/` (backup-meta.json
// keys files as `gsd-core/workflows/*`; correction doc §9.11, commit 387179f).
// A stale name makes scanRecursive(missing dir) return gsd_mtime/count=0 — the
// gsd drift trigger then never fires (silent death), exactly the state these
// constants were in 2026-06-04..06-05. Guarded by
// tests/probes/probe-gsd-roots-resolve.sh. See docs/decisions.md 2026-06-05 row.
const GSD_LIVE_ROOT = path.join(os.homedir(), '.claude', 'gsd-core');
const GSD_FORK_ROOT = path.join(os.homedir(), '.claude', 'gsd-local-patches', 'gsd-core');

// Collect current snapshot for all 5 watched paths + version. `settings` is
// hashed over the WARN-set projection rather than mtime'd — see HP-014's
// hot-reload note in the wrapper doc for why /effort, /model, /output-style,
// permission-grant mutations MUST NOT trip drift. All three filesystem trees
// (agents, gsd, plugins) scan recursively via scanRecursive() — plugins was
// shallow pre-2026-04-18, missed nested writes. See docs/decisions.md drift-
// bundle row.
function collectSnapshot(data) {
  const configDir = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');

  const agents = scanRecursive(path.join(os.homedir(), '.claude', 'agents'));
  const gsd = scanRecursive(GSD_LIVE_ROOT);
  // Allowlist inversion (D-03 / D-04): count only `content`-classified entries.
  // keepPredicate receives the cache-root-relative normalized `rel` (D-20) that
  // scanRecursive computes per entry. `bookkeeping` (silent) and `novel`
  // (routed to the ⚠ cc-novel detector) entries are excluded from the plugins
  // drift mtime/count. classifyEntryFn is the fallback-aware reference (D-08 /
  // D-23) — the real classifyEntry when the module loads, an inline denylist-
  // equivalent fallback otherwise. agents/gsd pass no predicate (scan all).
  const plugins = scanRecursive(
    path.join(configDir, 'plugins', 'cache'),
    (rel, b) => classifyEntryFn(rel, b) === 'content',
  );

  const snapshot = {
    agents_mtime: agents.maxMtime,
    agents_count: agents.count,
    settings_hash: '',
    gsd_mtime: gsd.maxMtime,
    gsd_count: gsd.count,
    plugins_mtime: plugins.maxMtime,
    plugins_count: plugins.count,
    // `plugins_maxPath` is observer-only: emitted in the breadcrumb when the
    // plugins trigger fires (see checkDrift). Pre-breadcrumb snapshot files on
    // disk lack this key; readers default it via `?? ''` at the JSON.stringify
    // site so old snapshots are forward-compatible (one-round grace, same
    // pattern as the 2026-04-18 *_count fields' schema migration).
    plugins_maxPath: plugins.maxPath,
    version: data.version || '',
    // schema_version (D-07 / D-25) — explicit integer that re-baselines on
    // mismatch. The Phase 18 inversion changed plugins_count's VALUE SEMANTICS
    // (all-minus-denylist -> content-only) on an always-present key, which the
    // existing presence-sniff migration guard cannot see. Injected here in the
    // plain object construction (outside any try/catch) so it ALWAYS serializes.
    // Both writers that serialize `current` (writeBaselineAndReturnClean and the
    // gsdSuppressed rebaseline) get the field for free; the marker-driven
    // rebaseline writer (which serializes the LOADED snapshot) sets it explicitly.
    schema_version: CURRENT_SCHEMA_VERSION,
  };

  // Active settings.json — follow symlinks, hash WARN-set keys only
  try {
    const settingsReal = fs.realpathSync(path.join(configDir, 'settings.json'));
    snapshot.settings_hash = hashWarnSettings(settingsReal);
  } catch { /* missing or unresolvable — hash stays '' */ }

  return snapshot;
}

// Fork-aware suppression filter for the gsd drift trigger. Returns true iff
// every file under `liveRoot` whose mtimeMs > snapshot.gsd_mtime is byte-equal
// to its counterpart under `forkRoot` — meaning the post-snapshot writes are
// the user's own fork-sync re-applying canonicals, not a real upstream change.
//
// Returns false (so the caller fires the gsd trigger as today) on:
//   - canonical fork tree missing or unreadable (no fork system installed)
//   - any newer-than-snapshot live file has NO canonical counterpart
//     (genuine upstream update touching an unforked file)
//   - any fork-tracked file's live bytes differ from canonical bytes
//     (genuine local edit, or upstream touched a fork-tracked file)
//   - any per-file read/stat error (fail-open)
//   - any uncaught throw inside the helper (single try/catch wraps the body)
//
// Returns true (suppress) iff every newer-than-snapshot file has a byte-equal
// canonical OR there are no newer-than-snapshot files at all (vacuously true;
// in production this branch is unreachable because checkDrift() only invokes
// the helper after the gsd mtime branch fired).
//
// Performance: invoked at most once per refresh, only when the gsd trigger
// has fired AND the count branch did NOT fire. Reuses the same recursive
// readdirSync walk shape as scanRecursive() to avoid double-traversal.
//
// liveRoot/forkRoot default to the production paths and are overridable so
// tests/probes/probe-gsd-fork-aware-drift.sh can fixture isolated trees.
function isGsdDriftFromForkSync(snapshot, liveRoot = GSD_LIVE_ROOT, forkRoot = GSD_FORK_ROOT) {
  try {
    // Canonical tree must exist and be readable; otherwise fail-open.
    try {
      const st = fs.statSync(forkRoot);
      if (!st.isDirectory()) return false;
    } catch { return false; }

    const entries = fs.readdirSync(liveRoot, { withFileTypes: true, recursive: true });
    for (const entry of entries) {
      if (entry.isDirectory && entry.isDirectory()) continue;
      const full = path.join(direntParent(entry, liveRoot), entry.name);
      let liveStat;
      try { liveStat = fs.statSync(full); } catch { return false; }
      if (liveStat.mtimeMs <= snapshot.gsd_mtime) continue;

      // Newer-than-snapshot live file — must have a byte-equal canonical.
      const rel = path.relative(liveRoot, full);
      const canonical = path.join(forkRoot, rel);
      let canonicalBytes;
      try { canonicalBytes = fs.readFileSync(canonical); } catch { return false; }
      let liveBytes;
      try { liveBytes = fs.readFileSync(full); } catch { return false; }
      if (!liveBytes.equals(canonicalBytes)) return false;
    }
    return true;
  } catch {
    return false;
  }
}

// Cross-session GSD-drift persistence in whole days: the MAX age across every
// still-diverging file's first-seen timestamp in gsd-drift-first-seen.json (ISO
// 8601 values — the same cache the triad's days_unresolved() and the SessionStart
// drift block read). Returns 0 for an empty/invalid cache, unparseable values, or
// any age under a day, so the statusline render gates the (Nd) token on >= 1
// (mirrors the triad's N >= 1 gate). Pure + exported for probe coverage
// (probe-drift-detection.js scenario [18]). Drift-duration-render todo (2026-06-25);
// backs Problem 2 in reports/2026-05-18-canonical-mirror-drift-from-unmirrored-edit.md.
function gsdDriftPersistenceDays(firstSeenCache, nowMs = Date.now()) {
  if (!firstSeenCache || typeof firstSeenCache !== 'object') return 0;
  let oldestMs = Infinity;
  for (const iso of Object.values(firstSeenCache)) {
    const t = new Date(iso).getTime();
    if (!Number.isNaN(t) && t < oldestMs) oldestMs = t;
  }
  if (oldestMs === Infinity) return 0;
  const days = Math.floor((nowMs - oldestMs) / 86_400_000);
  return days > 0 ? days : 0;
}

// Sibling to isGsdDriftFromForkSync — when the boolean says "fire", this walks the
// same tree and accumulates the list of newer-than-snapshot files that broke
// byte-equality. Used by checkDrift() to (a) inject diverging-file detail into
// the visible `⚠ restart gsd:<basename>` trigger label and (b) write a forensic
// breadcrumb to ~/.cache/dhx/drift-debug-<session>.log mirroring the plugins
// pattern. Backs Problem 2 in reports/2026-05-18-canonical-mirror-drift-from-
// unmirrored-edit.md.
//
// Returns an array of `{ path, kind }` entries (path relative to liveRoot).
// `kind` values:
//   'mismatch'           — canonical exists but bytes differ from live
//   'no-canonical'       — canonical counterpart missing (genuine upstream addition)
//   'unreadable'         — live or canonical read/stat threw
//   'fork-tree-missing'  — canonical fork root absent; single entry with no path
//
// Never throws — partial list on inner failure, empty list on outer failure.
// Performance: invoked at most once per refresh, only when checkDrift has
// already confirmed gsd drift fired (rare event); cost matches isGsdDriftFromForkSync.
function collectGsdDriftDivergingFiles(snapshot, liveRoot = GSD_LIVE_ROOT, forkRoot = GSD_FORK_ROOT) {
  const diverging = [];
  try {
    try {
      const st = fs.statSync(forkRoot);
      if (!st.isDirectory()) return [{ kind: 'fork-tree-missing' }];
    } catch { return [{ kind: 'fork-tree-missing' }]; }

    const entries = fs.readdirSync(liveRoot, { withFileTypes: true, recursive: true });
    for (const entry of entries) {
      if (entry.isDirectory && entry.isDirectory()) continue;
      const full = path.join(direntParent(entry, liveRoot), entry.name);
      let liveStat;
      try { liveStat = fs.statSync(full); } catch {
        diverging.push({ path: path.relative(liveRoot, full), kind: 'unreadable' });
        continue;
      }
      if (liveStat.mtimeMs <= snapshot.gsd_mtime) continue;

      const rel = path.relative(liveRoot, full);
      const canonical = path.join(forkRoot, rel);
      let canonicalBytes;
      try { canonicalBytes = fs.readFileSync(canonical); } catch {
        diverging.push({ path: rel, kind: 'no-canonical' });
        continue;
      }
      let liveBytes;
      try { liveBytes = fs.readFileSync(full); } catch {
        diverging.push({ path: rel, kind: 'unreadable' });
        continue;
      }
      if (!liveBytes.equals(canonicalBytes)) {
        diverging.push({ path: rel, kind: 'mismatch' });
      }
    }
  } catch { /* fail-silent — partial list is fine */ }
  return diverging;
}

// Drift detection (D-02 through D-05): snapshot comparison.
// First invocation: snapshots all 5 path mtimes + version into a single cache file.
// Subsequent invocations: compares current state against snapshot, warns on change.
// Age timer uses the snapshot file's own mtime (written ≈ session start).
// Drift-snapshot schema version (D-07 / D-25). Phase 17 baseline is implicitly
// `1`; Phase 18 bumps to `2` because the inversion changed plugins_count's value
// semantics (all-minus-denylist -> content-only). A snapshot whose
// schema_version !== CURRENT_SCHEMA_VERSION re-baselines (the migration guard in
// checkDrift), so no operator with a live session spanning the deploy gets a
// false `⚠ restart plugins` on the first post-deploy refresh.
const CURRENT_SCHEMA_VERSION = 2;

// Atomic write: serialize `dataObj` to a per-pid tmp sibling, then rename onto
// the target. Single source of truth for the `.tmp.<pid>` suffix + the leaked-
// tmp cleanup (IN-03). Before this helper, the six atomic-write sites in
// checkDrift each open-coded the tmp+rename; the three catch blocks that bothered
// to clean up RECONSTRUCTED `target + '.tmp.' + process.pid` (one even via a
// divergent path.join) because the try-scoped const was out of scope, and the
// other three leaked the tmp on a post-write renameSync failure. Computing `tmp`
// once here makes write and unlink reference the same path by construction.
// INVARIANT: every atomic snapshot/cache write in checkDrift routes through this
// helper — do not re-introduce open-coded tmp+rename (probe-writeatomic-leak-cleanup.js).
function writeAtomic(targetPath, dataObj) {
  const tmp = targetPath + '.tmp.' + process.pid;
  try {
    fs.writeFileSync(tmp, JSON.stringify(dataObj));
    fs.renameSync(tmp, targetPath);
  } catch (e) {
    // renameSync may have thrown after a successful write — unlink the leaked tmp.
    try { fs.unlinkSync(tmp); } catch { /* may not exist */ }
    throw e; // preserve each caller's existing skip-on-failure handling
  }
}

function checkDrift(data) {
  return new Promise((resolve) => {
    if (!data.session_id) return resolve('');

    const cacheDir = path.join(os.homedir(), '.cache', 'dhx');
    // Key by (session_id, CC's process start-ticks) so /resume into a new CC
    // process gets a fresh snapshot — eliminates the "stale snapshot from previous
    // process life" failure mode without depending on SessionStart hook firing.
    // Walks past the ephemeral shell CC inserts around statusLine.command (because
    // $HOME forces shell expansion); plain process.ppid would rotate per refresh
    // and reproduce the ~1k-file thrash that motivated this fix. Non-Linux fallback
    // (null ticks) collapses to legacy session-id-only keying.
    const ccTicks = findCCTicks(process.ppid);
    const suffix = ccTicks ? `-p${ccTicks}` : '';
    const snapshotFile = path.join(cacheDir, `drift-snapshot-${data.session_id}${suffix}.json`);

    // Collect current state
    const current = collectSnapshot(data);

    const writeBaselineAndReturnClean = () => {
      try {
        writeAtomic(snapshotFile, current);
      } catch {
        // write failed — skip drift this invocation. writeAtomic already
        // unlinked any leaked tmp before re-throwing (WR-03 / IN-03).
      }
      return resolve('');
    };

    // Try to read existing snapshot
    let snapshot;
    try {
      snapshot = JSON.parse(fs.readFileSync(snapshotFile, 'utf8'));
    } catch {
      // First invocation for this session — write snapshot, return clean
      return writeBaselineAndReturnClean();
    }

    // Schema migration: pre-hash snapshots lack `settings_hash`; pre-count
    // snapshots (2026-04-18 drift bundle) lack `agents_count`. Either absence
    // re-baselines as a first-invocation so mixed-format fields never compare.
    // Unified guard = one round of grace per upgrade, not two.
    //
    // D-07 / D-25 schema_version clause: a pre-Phase-18 snapshot has
    // schema_version === undefined !== CURRENT_SCHEMA_VERSION, so it re-baselines
    // clean. This catches the plugins_count VALUE-SEMANTICS change (all-minus-
    // denylist -> content-only) that a presence-sniff cannot see (the key was
    // always present). This guard PRECEDES the marker-rebaseline block below
    // (D-25 ordering invariant) — short-circuiting here means a pre-Phase-18
    // snapshot re-baselines even when a /restart-plugins marker is present,
    // rather than the marker writer preserving its stale schema.
    if (!('settings_hash' in snapshot) || !('agents_count' in snapshot) ||
        snapshot.schema_version !== CURRENT_SCHEMA_VERSION) {
      return writeBaselineAndReturnClean();
    }

    // Marker-driven rebaseline: when the user runs `/restart-plugins` (or
    // `/reload-plugins`), `dhx/dhx-restart-plugins-marker.sh` writes a
    // `plugins-rebaseline-${session_id}.marker` in this same cacheDir.
    // CC's in-process plugin reload runs against the same PID+ccTicks, so
    // the snapshot file persists and CC's plugin-cache writes look like
    // drift on the next refresh. Surgical fix: rewrite ONLY the plugins
    // fields (mtime + count) on the loaded snapshot to current values, then
    // delete the marker (single-shot semantics). Other triggers (agents,
    // settings, gsd, version) flow through unchanged.
    const markerFile = path.join(cacheDir, `plugins-rebaseline-${data.session_id}.marker`);
    try {
      fs.statSync(markerFile);  // throws ENOENT if absent
      snapshot.plugins_mtime = current.plugins_mtime;
      snapshot.plugins_count = current.plugins_count;
      // D-25: keep schema_version current on this in-place rewrite. This writer
      // serializes the LOADED snapshot (not `current`), so without this line a
      // marker-rebaselined snapshot would lack the field. Placed OUTSIDE the
      // inner try/catch (alongside the plugins-fields rewrite above) so it
      // always assigns before serialization. Only reachable for an already-
      // current snapshot — a pre-Phase-18 one re-baselined via the guard above.
      snapshot.schema_version = current.schema_version;
      try {
        writeAtomic(snapshotFile, snapshot);
      } catch {
        // best-effort persistence; in-memory snapshot still rebaselined.
        // writeAtomic already unlinked any leaked tmp before re-throwing (WR-03 / IN-03).
      }
      try { fs.unlinkSync(markerFile); } catch { /* concurrent refresh consumed it first; harmless */ }
    } catch { /* marker absent or unreadable — no-op, normal drift compare follows */ }

    // Compare: collect which paths drifted (short labels match snapshot keys).
    // Exposing triggers enables tuning — without this, every false positive
    // looks identical and there's no way to diagnose which signal is noisy.
    // Each tree fires on mtime INCREASE or count DECREASE — the count branch
    // catches deletion-only updates that leave a smaller max mtime than the
    // snapshot (strict `>` alone would miss them).
    const triggers = [];
    if (current.agents_mtime > snapshot.agents_mtime ||
        current.agents_count < snapshot.agents_count) triggers.push('agents');
    if (current.settings_hash !== snapshot.settings_hash) triggers.push('settings');

    // gsd branch — split mtime and count so the count branch is non-suppressible.
    // A deletion cannot be validated by byte-equal, so the helper is only invoked
    // when the mtime branch fired alone. See `isGsdDriftFromForkSync` above and
    // docs/statusline-wrapper.md § "Fork-aware suppression (gsd trigger only)".
    const gsdMtimeFired = current.gsd_mtime > snapshot.gsd_mtime;
    const gsdCountFired = current.gsd_count < snapshot.gsd_count;
    let gsdSuppressed = false;
    if (gsdMtimeFired || gsdCountFired) {
      if (gsdMtimeFired && !gsdCountFired) {
        gsdSuppressed = isGsdDriftFromForkSync(snapshot);
      }
      if (!gsdSuppressed) triggers.push('gsd');
    }

    if (current.plugins_mtime > snapshot.plugins_mtime ||
        current.plugins_count < snapshot.plugins_count) {
      triggers.push('plugins');
      // Forensic breadcrumb — plugins trigger only (YAGNI: not extended to
      // other triggers). Fires INSIDE the drift-detected branch; not on every
      // refresh. The signal is `max_path`: which file's mtime won the scan
      // (the data point that took ~20 minutes to recover in the 2026-05-13
      // .in_use/<pid> forensics). See docs/statusline-wrapper.md § "Debug
      // breadcrumb" and docs/decisions.md 2026-05-13 row for the filter-
      // extension lineage (.orphaned_at → temp_git_* → .in_use/<pid>) that
      // motivated this. Sanitize session_id mirroring dhx-restart-plugins-
      // stop.sh:43-48 — reject path separators / `..` so a malicious id can't
      // escape ~/.cache/dhx via the log basename. Cache-write failures are
      // silent: drift detection takes priority over breadcrumb.
      try {
        const sessionId = data.session_id;
        if (sessionId && !/[/\\]|\.\./.test(sessionId)) {
          fs.mkdirSync(cacheDir, { recursive: true });
          const breadcrumbFile = path.join(cacheDir, `drift-debug-${sessionId}.log`);
          const line = JSON.stringify({
            ts: new Date().toISOString(),
            trigger: 'plugins',
            max_path: current.plugins_maxPath ?? '',
            current_mtime: current.plugins_mtime,
            snapshot_mtime: snapshot.plugins_mtime,
            current_count: current.plugins_count,
            snapshot_count: snapshot.plugins_count,
          }) + '\n';
          fs.appendFileSync(breadcrumbFile, line);
        }
      } catch { /* breadcrumb failure must not affect drift detection */ }
    }
    if (current.version !== snapshot.version) {
      triggers.push('version');
      // RAT-04 (D-02 / D-13a) — post-CC-upgrade novel-pattern enumeration.
      // Gated on the version-change branch so it runs exactly once per CC
      // version transition (Pattern 4 / Pitfall 2): the snapshot rebaselines
      // on this same drift-detected refresh, so the next refresh's
      // `current.version === snapshot.version` and enumeration does not
      // re-fire. Writes the novel hits to ~/.cache/dhx/cc-novel-patterns.json
      // via the atomic temp+rename pattern (the gsd-drift-first-seen.json
      // writer precedent). The whole side-effect is try/catch-wrapped — a
      // cache or walk failure must never affect drift detection (T-17-02);
      // same discipline as the breadcrumb writer above.
      try {
        const novelPatterns = enumerateNovelPatterns();
        const ccNovelCache = {
          detected_at: new Date().toISOString(),
          cc_version: current.version,
          novel_patterns: novelPatterns,
        };
        fs.mkdirSync(cacheDir, { recursive: true });
        const ccNovelFile = path.join(cacheDir, 'cc-novel-patterns.json');
        writeAtomic(ccNovelFile, ccNovelCache);
      } catch {
        // cache failure must not affect drift detection. writeAtomic already
        // unlinked any leaked tmp before re-throwing (WR-03 / IN-03) — passing
        // the real ccNovelFile var eliminates the prior path.join reconstruction.
      }
    }

    // GSD-specific first-seen cache clearance (Phase 16, D-22 — HP-031).
    // The cross-session cache ~/.cache/dhx/gsd-drift-first-seen.json is keyed on
    // GSD-trigger state, NOT the global trigger count. When the gsd trigger is
    // absent from the union, GSD drift has resolved — atomically truncate the
    // cache to {}. This MUST run before the `triggers.length === 0` early-return
    // so it fires both when no triggers exist at all AND when only non-gsd
    // triggers (agents/plugins/version) are present. Replaces the prior
    // global-union-keyed clearance shape (per D-22).
    if (!triggers.includes('gsd')) {
      try {
        const cacheFile = path.join(cacheDir, 'gsd-drift-first-seen.json');
        if (fs.existsSync(cacheFile)) {
          writeAtomic(cacheFile, {});
        }
      } catch { /* cleanup failure non-fatal */ }
    }

    if (triggers.length === 0) {
      // Re-baseline if a suppression occurred so we don't repeat the byte-compare
      // every refresh. Without this, the post-fork-sync newer-than-snapshot files
      // keep firing the gsd mtime branch (and the byte-compare) on every refresh
      // until some other trigger forces a baseline write. (No effect when no
      // triggers were ever raised — the snapshot already matches current.)
      if (gsdSuppressed) {
        try {
          writeAtomic(snapshotFile, current);
        } catch { /* best-effort; suppression still holds for this refresh */ }
      }
      return resolve('');
    }

    // Drift detected. The old session-age token (time since the snapshot mtime)
    // was dropped 2026-06-25: it re-baselined every session and ACTIVELY under-
    // stated how long a drift had persisted — the exact blind spot behind the
    // 2026-05-12 6-day mask. The visible segment now carries the cross-session
    // persistence (Nd) from gsd-drift-first-seen.json instead (gsdPersistDays,
    // computed below). See docs/decisions.md 2026-06-25 row + the drift-duration-
    // render todo.

    // Gsd-trigger detail injection (Problem 2 in reports/2026-05-18-canonical-
    // mirror-drift-from-unmirrored-edit.md). Only meaningful when the gsd mtime
    // branch fired alone — count branch is a deletion, no diverging-file list
    // applies. Render `gsd:execute-phase.md` for single-file drift, `gsd:3files`
    // for multi-file. Empty suffix when no detail is computable (fork-tree-
    // missing or zero-length list).
    let gsdDetail = '';
    let gsdDiverging = null;
    let gsdPersistDays = 0;   // cross-session drift persistence in days; 0 = sub-day or no cache
    if (triggers.includes('gsd') && gsdMtimeFired && !gsdCountFired) {
      gsdDiverging = collectGsdDriftDivergingFiles(snapshot);
      const named = gsdDiverging.filter(d => d.path);
      if (named.length === 1) {
        gsdDetail = `:${path.basename(named[0].path)}`;
      } else if (named.length > 1) {
        gsdDetail = `:${named.length}files`;
      }
    }

    // Forensic breadcrumb — mirrors the plugins-trigger pattern (above). Writes
    // the full diverging-file list to ~/.cache/dhx/drift-debug-<session>.log
    // so the next /dhx:statusline debug session can read it without re-walking
    // the live tree. Silent on cache-write failure: drift detection takes
    // priority over breadcrumb (same discipline as plugins branch).
    if (gsdDiverging) {
      try {
        const sessionId = data.session_id;
        if (sessionId && !/[/\\]|\.\./.test(sessionId)) {
          fs.mkdirSync(cacheDir, { recursive: true });
          const breadcrumbFile = path.join(cacheDir, `drift-debug-${sessionId}.log`);
          const line = JSON.stringify({
            ts: new Date().toISOString(),
            trigger: 'gsd',
            diverging: gsdDiverging,
            current_mtime: current.gsd_mtime,
            snapshot_mtime: snapshot.gsd_mtime,
          }) + '\n';
          fs.appendFileSync(breadcrumbFile, line);
        }
      } catch { /* breadcrumb failure must not affect drift detection */ }

      // Cross-session first-seen cache writer (Phase 16, D-16/D-17/D-22/D-25 —
      // HP-031). gsdDiverging is the AUTHORITATIVE drift state: build the new
      // cache object purely from the current diverging set, so any entry that
      // is no longer diverging is dropped by construction (this IS resolution
      // semantics — no separate per-key removal pass needed). Subsequent fires
      // for the same path preserve the original first-seen timestamp; a path
      // not yet cached gets a fresh ISO 8601 stamp. Filter is `d => d.path`
      // (D-25) — covers the path-bearing kinds 'mismatch', 'no-canonical',
      // 'unreadable'; 'fork-tree-missing' carries no path and is excluded
      // naturally. Atomic temp+rename mirrors the snapshot writer precedent.
      try {
        const cacheFile = path.join(cacheDir, 'gsd-drift-first-seen.json');
        let existingCache = {};
        try {
          existingCache = JSON.parse(fs.readFileSync(cacheFile, 'utf8'));
          if (!existingCache || typeof existingCache !== 'object') existingCache = {};
        } catch { existingCache = {}; }   // silent rebuild on parse failure (A1 / HP-015 discipline)

        const now = new Date().toISOString();
        const currentPaths = new Set(gsdDiverging.filter(d => d.path).map(d => d.path));
        const newCache = {};
        for (const p of currentPaths) {
          newCache[p] = existingCache[p] || now;   // preserve first-seen; stamp on first detection
        }

        // newCache is the authoritative preserved-or-fresh first-seen per still-
        // diverging path — the exact input for the visible persistence (Nd) token.
        // Computed before writeAtomic so a write failure still surfaces the age.
        gsdPersistDays = gsdDriftPersistenceDays(newCache);

        fs.mkdirSync(cacheDir, { recursive: true });
        writeAtomic(cacheFile, newCache);
      } catch { /* cache failure must not affect drift detection */ }
    }

    const triggersStr = triggers.map(t => t === 'gsd' ? `gsd${gsdDetail}` : t).join('+');
    // Persistence (Nd) gated on >= 1 day (mirrors the triad's N >= 1 gate): a
    // fresh same-session drift shows no duration; a genuinely persisted one flags
    // its age. gsdPersistDays is 0 for any non-gsd-only / count-branch / sub-day case.
    const driftAge = gsdPersistDays >= 1 ? ` (${gsdPersistDays}d)` : '';
    resolve(`\x1b[38;5;208m⚠ restart ${triggersStr}${driftAge}\x1b[0m`);
  });
}

// --- Shared main-chain tail parse (arc N7, 2026-08-15) -----------------------
//
// ONE bounded tail read feeds three consumers: the cache-TTL countdown, the
// bust/cold classifier, and the telemetry writers (manifest Item C f30 — never
// add an independent second/third transcript scan to this hot path). Replaces
// readCacheAnchor (2026-04-17 → 2026-08-15), whose read-only anchor predicate
// self-inflicted a one-turn lag after cold writes (N5 review f21): the anchor
// now also latches on a substantial cache_creation, sharing constants with
// dhx-cold-return-gate.sh (WINDOW 256KB, CRT_MIN 10000, 60s disorder tolerance).
//
// Record selection (f25/f26): only TERMINAL records classify — group by
// (requestId, message.id), require stop_reason (streaming repeats share one
// message.id with cumulative usage; a stop_reason record carries the max in
// 541,427/541,427 measured groups — D-10). Ancestry: uuid dedup (fork replays),
// isSidechain exclusion (separate API conversation, own prefix), timestamp
// ordering with a corruption flag when file order disagrees >60s (HP-019).
//
// Why not mtime for the anchor: away_summary writes (HP-019) bump JSONL mtime
// without a type=assistant entry — billed calls the countdown must not chase.
// usage-block timestamps come from the same block billing is computed from.
//
// INVARIANT: depends on JSONL transcript schema (HP-019). type=assistant
// entries carry .timestamp, .requestId, top-level .effort, .message.{id,model,
// stop_reason,usage,diagnostics}; subagent entries are flagged isSidechain.
// Probes: tests/probes/probe-cache-age-anchor.js (parse + anchor),
//         tests/probes/probe-cache-event-classifier.js (classification),
//         tests/probes/probe-cache-telemetry-spools.js (writers).
const TAIL_WINDOW = 262144;          // matches DHX_COLD_RETURN_WINDOW default
const ANCHOR_CREATION_MIN = 10000;   // matches cold-return gate CRT_MIN
const DISORDER_TOLERANCE_MS = 60000; // matches cold-return gate's 60s slack

function parseTranscriptTail(transcriptPath) {
  let fd;
  try {
    fd = fs.openSync(transcriptPath, 'r');
    const size = fs.fstatSync(fd).size;
    if (size === 0) return null;
    const len = Math.min(TAIL_WINDOW, size);
    const buf = Buffer.alloc(len);
    fs.readSync(fd, buf, 0, len, size - len);
    const lines = buf.toString('utf8').split('\n');
    // Skip the first split when the window starts mid-record — partial line.
    const startIdx = size > TAIL_WINDOW ? 1 : 0;

    const seenUuids = new Set();
    const groups = new Map();     // key → terminal-group summary (file order)
    let compactTsMs = null;       // newest compact-boundary marker in window
    let maxTs = -Infinity;
    let corrupt = false;

    for (let i = startIdx; i < lines.length; i++) {
      const line = lines[i];
      if (!line) continue;
      let r;
      try { r = JSON.parse(line); } catch { continue; }
      if (r.isSidechain === true) continue;
      // /compact writes a system boundary record — expected-cold cause marker.
      if (r.type === 'system' && typeof r.subtype === 'string' && r.subtype.includes('compact')) {
        const t = Date.parse(r.timestamp || '');
        if (Number.isFinite(t) && (compactTsMs == null || t > compactTsMs)) compactTsMs = t;
        continue;
      }
      if (r.type !== 'assistant') continue;
      const m = r.message;
      if (!m || !m.usage) continue;
      if (r.uuid) {
        if (seenUuids.has(r.uuid)) continue; // fork-replay double-count
        seenUuids.add(r.uuid);
      }
      const tsMs = Date.parse(r.timestamp || '');
      if (!Number.isFinite(tsMs)) continue;
      const key = `${r.requestId || ''}:${(m.id || '')}`;
      // Terminal record only (stop_reason present); later file-order wins.
      if (!m.stop_reason) continue;
      if (tsMs < maxTs - DISORDER_TOLERANCE_MS) corrupt = true;
      if (tsMs > maxTs) maxTs = tsMs;
      const u = m.usage;
      groups.set(key, {
        key,
        tsMs,
        model: m.model || null,
        effort: typeof r.effort === 'string' ? r.effort : null,
        version: r.version || null,
        read: u.cache_read_input_tokens || 0,
        creation: u.cache_creation_input_tokens || 0,
        input: u.input_tokens || 0,
        e1h: (u.cache_creation && u.cache_creation.ephemeral_1h_input_tokens) || 0,
        e5m: (u.cache_creation && u.cache_creation.ephemeral_5m_input_tokens) || 0,
        output: u.output_tokens || 0,
        stop: m.stop_reason || null,
        diag: (m.diagnostics && m.diagnostics.cache_miss_reason) || null,
      });
    }

    if (groups.size === 0) return null;
    const ordered = [...groups.values()].sort((a, b) => a.tsMs - b.tsMs);
    const newest = ordered[ordered.length - 1];
    const prev = ordered.length > 1 ? ordered[ordered.length - 2] : null;

    // Anchor: newest completion whose usage proves the server touched (read) or
    // rebuilt (substantial creation) the warm prefix — f21 creation-anchoring.
    let anchor = null;
    for (let i = ordered.length - 1; i >= 0; i--) {
      const g = ordered[i];
      if (g.read > 0 || g.creation >= ANCHOR_CREATION_MIN) { anchor = g; break; }
    }

    // TTL bucket from the newest bucketed write (f20): observed beats assumed.
    let ttlSecs = null;
    for (let i = ordered.length - 1; i >= 0; i--) {
      const g = ordered[i];
      if (g.e1h + g.e5m > 0) { ttlSecs = g.e1h >= g.e5m ? 3600 : 300; break; }
    }

    return { newest, prev, anchor, ttlSecs, corrupt, compactTsMs };
  } catch {
    return null;
  } finally {
    if (fd !== undefined) { try { fs.closeSync(fd); } catch { /* nothing */ } }
  }
}

// --- Cache-event classifier (arc N7; manifest Item C as amended by N5) -------
//
// Diagnostics-first (f4): the server's stored message.diagnostics.cache_miss_reason
// is authoritative (it knows actual cache state); the read/creation ratio
// signatures survive only as an explicitly-labeled fallback for the ~26% blind
// categories and pre-diagnostics records. Planned invalidations classify as
// EXPECTED_COLD:<cause> (f27) and never feed the bust glyph; only
// UNEXPECTED_BUST does. Below the ~30k separability floor the heuristic emits
// UNKNOWN_SMALL, never BUST/COLD from fixed thresholds (f24).
//
// Classes: WARM | UNKNOWN_SMALL | UNKNOWN | EXPECTED_COLD:<cause> | UNEXPECTED_BUST
// Causes:  first | compact | model | effort | cc-upgrade (structural, from the
//          adjacent terminal records) or the server's diag type / ratio-bust /
//          ratio-cold on the unexpected path.
const HEUR_SMALL_FLOOR = 30000;      // below: base ≈ whole prefix, no separation
const HEUR_BUST_BASE_MAX = 30000;    // collapsed-read ceiling (~20k fleet-warm base + slack)
const HEUR_BUST_CREATION_MIN = 50000;
const HEUR_COLD_CREATION_MIN = 10000;

function classifyCacheEvent(tail) {
  if (!tail || !tail.newest) return null;
  const { newest, prev, compactTsMs } = tail;
  const read = newest.read, creation = newest.creation;
  const gapS = prev ? Math.round((newest.tsMs - prev.tsMs) / 1000) : null;

  // Structural expected-cold causes, visible from the adjacent records.
  let cause = null;
  if (!prev) cause = 'first';
  else if (compactTsMs != null && compactTsMs > prev.tsMs && compactTsMs <= newest.tsMs) cause = 'compact';
  else if (prev.model && newest.model && prev.model !== newest.model) cause = 'model';
  else if (prev.effort && newest.effort && prev.effort !== newest.effort) cause = 'effort';
  else if (prev.version && newest.version && prev.version !== newest.version) cause = 'cc-upgrade';

  const base = { gapS, read, creation, corrupt: !!tail.corrupt };

  // Blind categories (`unavailable` / `previous_message_not_found`, ~26% of
  // sampled verdicts) are the server saying "can't diagnose", NOT a bust
  // verdict — observed live on a fully-warm turn (read 447k, creation <1k,
  // type unavailable). They fall through to the structural causes + ratio
  // heuristic, with the diag type preserved as provenance. This is exactly why
  // the heuristic survives as fallback (f4's blind-category rate).
  const diag = newest.diag;
  const diagBlind = diag && (diag.type === 'unavailable' || diag.type === 'previous_message_not_found');
  if (diag && typeof diag.type === 'string' && !diagBlind) {
    if (diag.type === 'model_changed' && !cause) cause = 'model';
    const missed = Number.isFinite(diag.cache_missed_input_tokens) ? diag.cache_missed_input_tokens : null;
    if (cause) return { ...base, cls: `EXPECTED_COLD:${cause}`, cause, heuristic: false, diagType: diag.type, missed };
    return { ...base, cls: 'UNEXPECTED_BUST', cause: diag.type, heuristic: false, diagType: diag.type, missed };
  }
  const diagType = diag && typeof diag.type === 'string' ? diag.type : null;

  // No usable server verdict — a fully-warm turn carries none (diagnosis-
  // engine readout) and blind categories land here too, so a warm-looking
  // geometry is genuinely quiet and anything else falls to the explicitly-
  // labeled ratio heuristic.
  if (cause) return { ...base, cls: `EXPECTED_COLD:${cause}`, cause, heuristic: false, diagType, missed: null };

  const prior = prev ? prev.input + prev.read + prev.creation : null;
  const h = { ...base, heuristic: true, diagType, missed: null };
  if (prior != null && prior < HEUR_SMALL_FLOOR) {
    // Below the separability floor: warm-shaped geometry stays quiet, anything
    // bust/cold-shaped is undecidable — never BUST/COLD from thresholds here.
    if (read >= prior * 0.8) return { ...h, cls: 'WARM', cause: null };
    return { ...h, cls: 'UNKNOWN_SMALL', cause: null };
  }
  if (prior != null && read >= prior * 0.8) return { ...h, cls: 'WARM', cause: null };
  if (read === 0 && creation >= HEUR_COLD_CREATION_MIN) return { ...h, cls: 'UNEXPECTED_BUST', cause: 'ratio-cold' };
  if (read > 0 && read <= HEUR_BUST_BASE_MAX && creation >= HEUR_BUST_CREATION_MIN) {
    return { ...h, cls: 'UNEXPECTED_BUST', cause: 'ratio-bust' };
  }
  if (prior == null && read > 0) return { ...h, cls: 'WARM', cause: null };
  return { ...h, cls: 'UNKNOWN', cause: null };
}

// Cache-TTL countdown + bust glyph. Always-on segment: green ≥30m, yellow <30m,
// orange 208 <15m, red EXPIRED. TTL source (f20): DHX_CACHE_TTL env override →
// observed cache-write bucket from the transcript (1h/5m) → 3600 assumed.
//
// TTL-clock invalidation (Item C enhancement, f5): when the stdin's stable
// model ID (data.model.id) or effort level (data.effort.level) differs from the
// ANCHOR turn's, the countdown is lying — the next call rewrites the prefix
// regardless of the clock. Render dim `ttl?` (unknown), never a fake countdown;
// the next completed call re-anchors with matching identity and the clock
// resumes. `/login` with unchanged model remains undetectable — represented as
// nothing rather than faked (N5 review round).
//
// Bust glyph: red `✸bust[:Nk]` appended when the NEWEST terminal record
// classifies UNEXPECTED_BUST (diagnostics-first; N missed-input-kilotokens when
// the server quantified it). Self-clears when the next completed call
// classifies warm. EXPECTED_COLD causes stay quiet by design (f27). Local
// session health only — never folded into cross-repo fleet channels.
// Strip a trailing bracketed context-window variant tag from a model id:
// `claude-opus-5[1m]` -> `claude-opus-5`. Non-strings pass through untouched so
// the caller's "both sides present" guard keeps working on undefined.
function baseModelId(id) {
  return typeof id === 'string' ? id.replace(/\[[^\]]*\]$/, '') : id;
}

function getCacheAge(data, tail) {
  return new Promise((resolve) => {
    if (!tail || !tail.anchor) return resolve('');
    const ttl = parseInt(process.env.DHX_CACHE_TTL, 10) || tail.ttlSecs || 3600;

    // Bust glyph (independent of clock validity — a bust already happened).
    let glyph = '';
    const ev = classifyCacheEvent(tail);
    if (ev && ev.cls === 'UNEXPECTED_BUST') {
      const kt = ev.missed != null && ev.missed > 0 ? `:${Math.round(ev.missed / 1000)}k` : '';
      glyph = ` \x1b[31m✸bust${kt}\x1b[0m`;
    }

    // Model/effort invalidation vs the anchor turn (both compared only when
    // both sides are present — absence is unknown, not mismatch).
    //
    // baseModelId: statusline stdin tags the CONTEXT-WINDOW VARIANT into the id
    // (`claude-opus-5[1m]`) while the API echoes only the base model back in each
    // assistant record's `message.model` (`claude-opus-5`). The two never compare
    // equal on a long-context session, so every such session read as a permanent
    // model change and the countdown rendered `ttl?` forever — measured live
    // 2026-08-15, 7 of 10 concurrent sessions on `[1m]`. Strip a trailing
    // bracketed variant tag from BOTH sides; a genuine opus->fable switch still
    // mismatches, and the f5 stable-id discipline is unchanged (this is not a
    // retreat to display-name comparison).
    // INVARIANT: the variant tag is a client-side decoration, not a cache-key
    // input — same base model + same effort = same prefix cache identity.
    const sModel = baseModelId(data.model && data.model.id);
    const sEffort = data.effort && data.effort.level;
    const invalidated =
      (sModel && tail.anchor.model && sModel !== baseModelId(tail.anchor.model)) ||
      (sEffort && tail.anchor.effort && sEffort !== tail.anchor.effort);
    if (invalidated) return resolve(`\x1b[2mttl?\x1b[0m${glyph}`);

    const elapsed = (Date.now() - tail.anchor.tsMs) / 1000;
    // Clamp upward to absorb clock skew / pre-write stat.
    const remaining = Math.min(ttl, Math.floor(ttl - elapsed));
    if (remaining <= 0) return resolve(`\x1b[31mEXPIRED\x1b[0m${glyph}`);
    const mins = Math.floor(remaining / 60);
    const label = mins < 1 ? '<1m' : `${mins}m`;
    let color;
    if (remaining < 15 * 60) color = '\x1b[38;5;208m'; // orange 208
    else if (remaining < 30 * 60) color = '\x1b[33m';  // yellow
    else color = '\x1b[32m';                            // green
    resolve(`${color}${label}\x1b[0m${glyph}`);
  });
}

// --- Rolling cache telemetry (arc N7; manifest Item C as amended) ------------
//
// Two spool families under ~/.cache/dhx (override: DHX_CACHE_TELEMETRY_DIR):
//
//   cache-events/<profile>-<session>.jsonl   one row per completed main-chain
//     call (all classes — WARM rows are the denominator the secular-ramp watch
//     needs). Per-session spool files, NOT one shared rolling file (f28):
//     concurrent statusline processes race rotation and duplicate events.
//   quota-snapshots/<profile>-<YYYYMMDD>.jsonl   one row per MAIN-CHAIN ADVANCE
//     (f16 — an unchanged utilization after a completed call is informative
//     censoring Item A needs; timer-only refreshes are suppressed by the
//     advance key, not by value comparison). Tagged {profile, session,
//     resets_at} — the profile letter is the load-bearing discriminator
//     (measured: write-on-change alone collapsed only 17.21% of the ccburn
//     corpus) but is insufficient without session + window (f15/29).
//
// Deterministic event id (f28/f32): `<session>:<requestId>:<message.id>` —
// offline merges dedupe on it; re-observation after a crash is idempotent.
// Writes are SYNCHRONOUS single-line appends (statusline processes are
// cancellation-prone; an async write dies with the process), fire at most once
// per completed API call (advance-gated via the per-session state file), and
// are fail-soft: a writer error logs one statusline-errors.jsonl line and never
// blocks the render.
//
// Schema discipline (Item C amendment): rows carry v:1; schema changes are
// ADDITIVE or come with a real offline migration — never rebuild()-on-drift,
// quota snapshots are not re-derivable. Mode 0600 files / 0700 dirs (f31/f61).
// Retention: files older than DHX_CACHE_TELEMETRY_RETENTION_DAYS (default 400,
// was 30 until 2026-09-16) are swept opportunistically at most once per day per
// session. The default moved because the spools became the 7d-ratio and
// request-unit INSTRUMENT (proposal v2 § 3, Design A / P0-b): a 30-day sweep was
// deleting the record (the 2026-08-16 file was lost from the live spool before
// the 09-15 archive caught it). The default lives HERE, not in settings.json
// `env`, because the wrapper hot-loads on the next refresh in EVERY running
// session (HP-014) while an env change reaches only sessions launched after it
// — an old session would keep sweeping at 30 days. ≈ 115 MB/month at current
// traffic; archive both spool dirs with SHA256SUMS to
// ~/.local/share/dhx/quota-snapshots-archive/<date>/ before any reduction.
//
// 2026-09-16 additive fields (P0-b provenance; Design A's REWRITE hypothesis
// needs c5m, its coverage audit needs output — F7: neither spool carried them):
//   event row   + input (uncached input tokens), output (output tokens),
//                 c1h / c5m (cache_creation split by TTL bucket), stop (stop_reason)
//   snapshot row + rl_keys (every key present on stdin `rate_limits`, sorted —
//                 records ABSENCE of a scoped bucket as a fact: CC 2.1.273 sends
//                 only five_hour + seven_day, and the docs define only those two
//                 plus a gateway-only spend_limit), rl_extra (any key beyond
//                 five_hour/seven_day, stored raw; present only when non-empty)
// Percent values are stored AS RECEIVED: the client emits floats such as
// 28.999999999999996 for 29. The writer preserves the raw value (a consumer
// cannot tell a float artefact from a genuinely fractional meter after the
// fact); every CONSUMER rounds to the nearest integer within a declared
// epsilon (qs-7d-ratio.py / qs-request-units.py: 1e-6) — never int()/floor.
const TELEMETRY_RETENTION_DAYS = (() => {
  const raw = parseInt(process.env.DHX_CACHE_TELEMETRY_RETENTION_DAYS, 10);
  return Number.isFinite(raw) && raw > 0 ? raw : 400;
})();

function telemetryBaseDir() {
  return process.env.DHX_CACHE_TELEMETRY_DIR || path.join(os.homedir(), '.cache', 'dhx');
}

// CCS profile letter — same derivation as dhx-statusline.js::getCcsProfile
// (kept inline: the renderer doesn't export it, and the regex is the contract).
function telemetryProfileLetter() {
  const m = (process.env.CLAUDE_CONFIG_DIR || '').match(/\.ccs\/instances\/([^/]+)\/?$/);
  return m ? m[1] : 'x';
}

function appendSpoolLine(file, row) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const fd = fs.openSync(file, 'a', 0o600);
  try { fs.writeSync(fd, JSON.stringify(row) + '\n'); }
  finally { try { fs.closeSync(fd); } catch { /* nothing */ } }
}

function sweepSpoolDir(dir, cutoffMs) {
  let names;
  try { names = fs.readdirSync(dir); } catch { return; }
  for (const n of names) {
    if (!n.endsWith('.jsonl')) continue;
    const p = path.join(dir, n);
    try { if (fs.statSync(p).mtimeMs < cutoffMs) fs.unlinkSync(p); }
    catch { /* races with a concurrent sweep are fine */ }
  }
}

function recordCacheTelemetry(data, tail, nowMs) {
  if (!tail || !tail.newest) return;
  const sid = data && data.session_id;
  if (!sid || /[/\\]|\.\./.test(sid)) return;  // basename-escape threat model
  const now = Number.isFinite(nowMs) ? nowMs : Date.now();
  const base = telemetryBaseDir();
  const profile = telemetryProfileLetter();
  const stateFile = path.join(base, 'cache-telemetry', `state-${sid}.json`);

  let state = {};
  try { state = JSON.parse(fs.readFileSync(stateFile, 'utf8')) || {}; } catch { state = {}; }
  const key = tail.newest.key;
  if (state.lastEventKey === key) return;  // timer-only refresh — no advance

  const ev = classifyCacheEvent(tail);
  const eventRow = {
    v: 1,
    id: `${sid}:${key}`,
    ts: new Date(tail.newest.tsMs).toISOString(),
    observed_at: new Date(now).toISOString(),
    cc: (data && data.version) || tail.newest.version || null,
    profile,
    session: sid,
    gap_s: ev.gapS,
    read: ev.read,
    creation: ev.creation,
    class: ev.cls,
    cause: ev.cause,
    heuristic: ev.heuristic,
    missed: ev.missed,
    diag_type: ev.diagType,
    model: tail.newest.model,
    effort: tail.newest.effort,
    ttl_bucket: tail.newest.e1h + tail.newest.e5m > 0
      ? (tail.newest.e1h >= tail.newest.e5m ? '1h' : '5m') : null,
    corrupt: ev.corrupt,
    // 2026-09-16 additive (P0-b): the usage fields the transcript already carries.
    input: tail.newest.input || 0,
    output: tail.newest.output || 0,
    c1h: tail.newest.e1h || 0,
    c5m: tail.newest.e5m || 0,
    stop: tail.newest.stop || null,
  };
  appendSpoolLine(path.join(base, 'cache-events', `${profile}-${sid}.jsonl`), eventRow);

  // Quota snapshot rides the same advance gate. Sides are recorded as-is
  // (including expired windows — the consumer filters; censoring is data).
  const rl = data && data.rate_limits;
  if (rl && typeof rl === 'object' && (rl.five_hour || rl.seven_day)) {
    const side = (lim) => (lim && typeof lim === 'object')
      ? { pct: Number(lim.used_percentage), resets_at: lim.resets_at != null ? lim.resets_at : null }
      : null;
    const day = new Date(now).toISOString().slice(0, 10).replace(/-/g, '');
    // Every rate_limits key the client sent (sorted) + any beyond the two we
    // project, raw. Absence is the finding; nothing is synthesised.
    const rlKeys = Object.keys(rl).sort();
    const rlExtra = {};
    for (const k of rlKeys) if (k !== 'five_hour' && k !== 'seven_day') rlExtra[k] = rl[k];
    const snapRow = {
      v: 1,
      id: `${sid}:${key}`,
      ts: new Date(now).toISOString(),
      cc: (data && data.version) || null,
      profile,
      session: sid,
      event_key: key,
      five_hour: side(rl.five_hour),
      seven_day: side(rl.seven_day),
      rl_keys: rlKeys,
    };
    if (Object.keys(rlExtra).length) snapRow.rl_extra = rlExtra;
    appendSpoolLine(path.join(base, 'quota-snapshots', `${profile}-${day}.jsonl`), snapRow);
  }

  // Opportunistic retention sweep, at most once per day per session.
  let lastSweepMs = Number(state.lastSweepMs) || 0;
  if (now - lastSweepMs > 86400_000) {
    const cutoff = now - TELEMETRY_RETENTION_DAYS * 86400_000;
    sweepSpoolDir(path.join(base, 'cache-events'), cutoff);
    sweepSpoolDir(path.join(base, 'quota-snapshots'), cutoff);
    sweepSpoolDir(path.join(base, 'cache-telemetry'), cutoff);
    lastSweepMs = now;
  }
  try {
    fs.mkdirSync(path.join(base, 'cache-telemetry'), { recursive: true, mode: 0o700 });
    writeAtomic(stateFile, { v: 1, lastEventKey: key, lastSweepMs });
  } catch { /* state-write failure → at worst a duplicate row; id dedupes offline */ }
}

// First user prompt segment (L2). Head-reads the 64KB window of the JSONL
// transcript and forward-scans for the FIRST non-synthetic type=user entry
// whose message.content is either a string OR an array starting with a
// {type:text} block. tool_result entries (array starting with {type:tool_result})
// are skipped — those are harness-injected responses to assistant tool calls,
// not user-authored prompts. Empty / control-only / parse-fail entries are
// skipped and the scan continues. Slash commands ARE user prompts.
//
// Freezes after first match — once the first non-synthetic user prompt of
// the session is found, the segment shows that text for the entire session's
// duration. The session's opening prompt is a more useful anchor than its
// most-recent prompt — it tells the user what they came here to do, rather
// than restating what they just typed. Also removes the segment's turn-by-turn
// flicker (previous semantics, 2026-04-27 → 2026-05-20).
//
// Returns the cleaned + truncated raw text (no ANSI), or null if no usable
// entry exists in the window. getFirstUserPrompt wraps in dim gray for L2.
//
// Architecturally analogous to readCacheAnchor (same 64KB I/O shape) but
// inverted direction: this helper reads from offset 0 (head), readCacheAnchor
// reads from offset (size - 64KB) (tail). Kept as a separate helper rather
// than consolidating into a shared readTranscriptWindow — the predicates
// differ entirely, and the I/O surface is small enough that the shared layer
// would add indirection without saving substantial code. The OS page cache
// absorbs back-to-back reads of the same path within a single Promise.all
// cycle.
//
// INVARIANT:
// (a) HEAD-read 64KB from offset 0 (NOT tail-read) and forward-scan — freezes
//     after the first non-synthetic user prompt of the session and stays
//     stable across refreshes.
// (b) Forward-scan stops at the first non-synthetic match; if file > 64KB,
//     the last line in the head slice is dropped (potentially truncated).
// (c) `<command-name>/foo</command-name>` extraction: CC wraps CLI slash
//     commands in a multi-tag XML-ish block — `<command-message>foo</...>` +
//     `<command-name>/foo</...>` + `<command-args>...</...>`. The canonical
//     `/foo` form lives in <command-name>; surfacing it (and dropping the
//     wrapper tags + args) makes the segment render as `/foo` instead of the
//     opaque truncated `<command-message>f…`. Extraction runs AFTER the
//     local-command-caveat filter, BEFORE the /clear check, so the /clear
//     comparison can be a plain string equality on the extracted form.
// (d) `/clear` SINGLE-SKIP exception: a leading /clear is skipped so the
//     segment reflects the user's real opening prompt; two consecutive /clear
//     entries return the second (single skip, not unbounded). Matches the
//     intent "if you /cleared to start fresh, freeze on what you actually
//     came here to do".
// (e) `<local-command-caveat>` prefix filter: CC-injected synthetic user
//     entries (string content prefix-matching this tag) are NOT real prompts
//     and are skipped wholesale.
// (f) Depends on JSONL transcript schema (HP-019). type=user entries carry
//     .message.content as either a string OR an array of content blocks
//     (text/tool_result/tool_use). Filtering to text+string is the contract
//     that keeps tool_result responses out of the segment.
// Probe: tests/probes/probe-first-prompt-segment.js.
function readFirstUserPromptText(transcriptPath) {
  const WINDOW = 65536;
  const MAX_CHARS = 20;
  let fd;
  try {
    fd = fs.openSync(transcriptPath, 'r');
    const size = fs.fstatSync(fd).size;
    if (size === 0) return null;
    const len = Math.min(WINDOW, size);
    const buf = Buffer.alloc(len);
    fs.readSync(fd, buf, 0, len, 0);
    const lines = buf.toString('utf8').split('\n');
    // If file fits in window, every line is complete; else the last line
    // in the head slice may be truncated mid-record, so drop it.
    const endIdx = size > WINDOW ? lines.length - 1 : lines.length;
    let clearSkipped = false;
    for (let i = 0; i < endIdx; i++) {
      const line = lines[i];
      if (!line) continue;
      let entry;
      try { entry = JSON.parse(line); } catch { continue; }
      if (entry.type !== 'user') continue;
      const content = entry.message && entry.message.content;
      let raw = null;
      if (typeof content === 'string') {
        raw = content;
      } else if (Array.isArray(content) && content.length > 0
                 && content[0] && content[0].type === 'text') {
        raw = content[0].text;
      }
      if (typeof raw !== 'string' || raw.length === 0) continue;
      // Filter CC-injected synthetic user entries (system caveats, not real
      // prompts). String-prefix check on the raw extracted text.
      if (raw.startsWith('<local-command-caveat>')) continue;
      // Slash-command extraction: when CC writes a CLI slash invocation, the
      // raw text is a multi-tag block; pull the canonical `/foo` form out of
      // <command-name> so the segment renders as "/foo" rather than the
      // opaque truncated "<command-message>f…". No-op for plain prompts that
      // don't carry the tag (regex misses → raw unchanged).
      const cmdName = raw.match(/<command-name>([^<]+)<\/command-name>/);
      if (cmdName) raw = cmdName[1];
      // /clear single-skip exception: first matching /clear is skipped so the
      // following prompt becomes the freeze anchor; if /clear matches AND
      // clearSkipped is already true (two /clear in a row), fall through and
      // return that candidate. After extraction above, the comparison is a
      // plain string equality on the canonical form.
      if (!clearSkipped && raw === '/clear') {
        clearSkipped = true;
        continue;
      }
      // Defensive: strip control chars (incl. ANSI ESC \x1b), collapse \s runs.
      // 20-char preview makes terminal-injection moot, but stripping ESC
      // explicitly defends against pasted ANSI surviving the truncation.
      const cleaned = raw.replace(/[\x00-\x1f\x7f]/g, ' ').replace(/\s+/g, ' ').trim();
      if (!cleaned) continue;
      // Mirrors dhx-statusline.js::truncate(): total width capped at MAX_CHARS,
      // with `…` consuming the last column when truncation occurs.
      return cleaned.length <= MAX_CHARS
        ? cleaned
        : cleaned.slice(0, MAX_CHARS - 1) + '…';
    }
    return null;
  } catch {
    return null;
  } finally {
    if (fd !== undefined) { try { fs.closeSync(fd); } catch { /* nothing */ } }
  }
}

// Format the first-user-prompt text in dim gray for L2 display, or '' to hide.
// Dim gray matches "static identity / de-emphasized" semantics in the color
// table — the prompt is read-only context, not a live signal, and must NOT
// compete with the L1 live cluster (cache → git → signals).
function getFirstUserPrompt(data) {
  return new Promise((resolve) => {
    const transcriptPath = data && data.transcript_path;
    if (!transcriptPath) return resolve('');
    const text = readFirstUserPromptText(transcriptPath);
    if (!text) return resolve('');
    resolve(`\x1b[2m${text}\x1b[0m`);
  });
}

// Branch display + off-main signal. GSD phase lanes compact to gsd/phase-NN[.M]
// (the phase name already renders on line 2); other long branches truncate at
// BRANCH_NAME_MAX (mirrors the renderer's NAME_MAX=20). Off the default branch
// (main/master) → bright magenta as an "off-main" cue; on it → cyan (calm).
// Pure (no fs, no subprocess) so it is probe-lockable as a string contract.
const BRANCH_NAME_MAX = 20;
function formatBranchSegment(branch) {
  if (!branch) return '';
  const gsd = branch.match(/^(gsd\/phase-\d+(?:\.\d+)?)/);
  const display = gsd
    ? gsd[1]
    : (branch.length > BRANCH_NAME_MAX ? branch.slice(0, BRANCH_NAME_MAX - 1) + '…' : branch);
  const onDefault = branch === 'main' || branch === 'master';
  const color = onDefault ? '\x1b[36m' : '\x1b[35m'; // cyan on main/master, magenta off
  return `${color}${display}\x1b[0m`;
}

// Fast git info: branch, dirty count, ahead/behind
function getGitInfo(cwd) {
  const gitOpts = { cwd, timeout: 2000 };
  const git = (args) => new Promise((resolve) => {
    execFile('git', ['--no-optional-locks', ...args], gitOpts, (err, stdout) => {
      resolve(err ? '' : stdout.trim());
    });
  });

  return Promise.all([
    git(['branch', '--show-current']),
    git(['status', '--porcelain']),
    git(['rev-list', '--left-right', '--count', 'HEAD...@{upstream}']),
  ]).then(([branch, porcelain, counts]) => {
    if (!branch) return ''; // not a git repo or detached HEAD

    const parts = [];

    // Branch name — off-main signal + GSD compaction (see formatBranchSegment)
    parts.push(formatBranchSegment(branch));

    // Dirty file count
    const dirty = porcelain ? porcelain.split('\n').filter(Boolean).length : 0;
    if (dirty > 0) {
      parts.push(`\x1b[33m${dirty}\x1b[0m`);
    }

    // Ahead/behind
    if (counts) {
      const [ahead, behind] = counts.split(/\s+/).map(Number);
      if (ahead > 0) parts.push(`\x1b[32m↑${ahead}\x1b[0m`);
      if (behind > 0) parts.push(`\x1b[31m↓${behind}\x1b[0m`);
    }

    return parts.join(' ');
  }).catch(() => '');
}

module.exports = {
  // ccburn segment — stdin-rendered (2026-05-29). buildCcburnFromStdin is the
  // render entry; ccburnPace + ccburnResetSecs are exported so the probe can pin
  // the pace classification + resets_at normalization deterministically.
  buildCcburnFromStdin,
  ccburnPace,
  ccburnResetSecs,
  formatBurnDuration,
  // Branch segment — pure string transform (off-main magenta signal + GSD
  // phase-lane compaction); exported so probe-statusline-wrapper.js can pin the
  // branch → colored-display contract deterministically. See docs/decisions.md
  // 2026-06-10 off-main-magenta row.
  formatBranchSegment,
  // wsl-stack producer-liveness (2026-08-15) — both exported as PURE functions so
  // probe-statusline-wsl-monitor-dead.js can pin the four-state classification and the
  // front-stack arbitration deterministically, without spawning a render or aging a real
  // file. classifyWslMonitorState takes ages in ms (not paths) precisely so the boundary
  // cases (94:59.999 vs 95:00.000, boot grace 7:59 vs 8:00) are exact rather than racy.
  classifyWslMonitorState,
  composeWslFront,
  hashWarnSettings,
  canonicalize,
  checkPluginRegistry,
  // Per-lane health scoping (2026-09-15) — exported as PURE functions so
  // probe-health-lane-scoping.sh can assert this consumer derives the same lane
  // id as the producer (dhx-health-check.sh) for the same config dir, rather
  // than reimplementing the derivation and testing the copy. That two-language
  // agreement is the change's one unenforceable-by-code invariant; both are
  // declared at their definition sites.
  laneIdFor,
  readLaneHealth,
  // Cross-repo lane stamp on sym-health.json (2026-09-15) — exported PURE so
  // probe-sym-health-lane-stamp.sh drives the real predicate rather than a copy.
  symHealthIsForThisLane,
  isGsdDriftFromForkSync,
  collectGsdDriftDivergingFiles,
  // Cross-session drift persistence (Nd) — drift-duration-render (2026-06-25)
  gsdDriftPersistenceDays,
  // RAT-04 novel-pattern detector (Phase 17 Plan 01)
  enumerateNovelPatterns,
  // scanRecursive export (D-20) — required by Plan 04's residual-signal probe;
  // not previously exported despite being the wrapper's core recursive walk.
  scanRecursive,
  // checkDrift export — lets probe-cc-novel-patterns.sh drive the version
  // branch directly with an injected `data` object for the D-22 behavioral
  // assertion ("version-unchanged → no enumeration → cc-novel-patterns.json
  // NOT written"). checkDrift is a pure function of `data` + filesystem;
  // sandbox via HOME + CLAUDE_CONFIG_DIR overrides. Mirrors the
  // fixture-injection rationale behind the isGsdDriftFromForkSync export.
  checkDrift,
  // IN-03 atomic-write helper — exported so probe-writeatomic-leak-cleanup.js
  // can drive the real helper (not a reimplementation) under a mocked
  // fs.renameSync to assert the leaked-tmp cleanup invariant.
  writeAtomic,
  // Cache bust-signal + telemetry (arc N7, 2026-08-15) — exported so the
  // probes drive the REAL implementations against tmp fixtures:
  // probe-cache-age-anchor.js (parse/anchor + getCacheAge render),
  // probe-cache-event-classifier.js, probe-cache-telemetry-spools.js.
  parseTranscriptTail,
  classifyCacheEvent,
  getCacheAge,
  recordCacheTelemetry,
  telemetryProfileLetter,
  // Per-segment self-diagnosis (2026-04-26 #4)
  withSegmentDiag,
  appendStatuslineError,
  computeSegmentSigil,
  // Meta-glyph composition (2026-04-26 #2b)
  computeMetaGlyph,
  // Skill-pressure segment (D-01/D-02/D-03, Phase 24)
  readSkillPressure,
  resolveSkillsRoot,
  countSkillPressure,
  PRESSURE_STATUSES,
};
