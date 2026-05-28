#!/usr/bin/env node
// gsd-hook-version: 1.42.3
// Patterns: HP-013, HP-014, HP-016, HP-019, HP-025, HP-026, HP-031, HP-032, HP-034
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

  // Run the dhx renderer, git info, cache-age, ccburn, health cache, and drift check in parallel.
  // ccburn collect silently feeds its database; compact output goes in the statusline.
  // Each branch is wrapped via withSegmentDiag so a thrown exception in any one
  // segment yields a red `⚠ <segment>?` sigil + a JSONL log line instead of
  // collapsing the entire statusline to silent empty (2026-04-26 #4 self-diag).
  Promise.all([
    withSegmentDiag('renderer',   runRenderer(input)),
    withSegmentDiag('git',        getGitInfo(cwd)),
    withSegmentDiag('cacheAge',   getCacheAge(data)),
    withSegmentDiag('ccburn',     runCcburn(input)),
    withSegmentDiag('firstPrompt', getFirstUserPrompt(data)),
    withSegmentDiag('health',     readHealthCache(data && data.session_id)),
    withSegmentDiag('drift',      checkDrift(data)),
    withSegmentDiag('fleet',      readFleetFeed()),
    withSegmentDiag('watch',      readWatchHealth()),
  ]).then(([rendererR, gitInfoR, cacheAgeR, burnOutputR, firstPromptR, healthR, driftR, fleetR, watchR]) => {
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
    if (front.length > 0) {
      line1 = front.join(' \x1b[2m|\x1b[0m ') + ' \x1b[2m|\x1b[0m ' + line1;
    }

    // Meta-glyph (2026-04-26 #2b): purely additive leftmost ∙/⌃ aggregating
    // drift + health.front + health.tail + sigilCount. Prepend AFTER the front
    // composition above so the full leftmost order is:
    //   meta-glyph SP <front-with-pipes> SP <renderer-line1>...
    // Existing detail unchanged — this only adds one glyph + space at column 0.
    const metaGlyph = computeMetaGlyph(driftWarning, health.front, health.tail, sigilCount);
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

// ccburn segment — stale-while-revalidate cache (2026-05-25 ccburn-storm fix).
//
// `ccburn --json --once` is a HEAVY usage scan: measured ~4.5-8s/call on this box
// (it scans usage/JSONL to compute session+weekly limits). It is NOT the ~15ms the
// incident triage reported — that benchmark unknowingly timed the no-op shim, not
// real ccburn. Running this scan on EVERY statusline refresh (~24/min × N sessions)
// was the incident's real amplifier: the "high-RAM JSONL search" was ccburn itself.
// So we keep the scan OFF the render hot path:
//
//   • render path reads a cached segment — a single readFileSync, instant;
//   • at most once per TTL, ONE detached, timeout-bounded refresher recomputes the
//     cache in the background.
//
// The refresher is `detached:true` + `unref()` so it OUTLIVES this wrapper (which
// exits in ms) and can finish the ~5s scan — but every ccburn invocation inside it
// is wrapped in coreutil `timeout`, so it self-terminates and can NEVER orphan into
// a storm. That preserves the D-14 "no unbounded subprocess on the render hot path"
// rule (2026-04-26 capture-pane precedent; docs/statusline-wrapper.md § Fleet D-14)
// while fixing the deeper problem the timeout alone didn't: the per-refresh scan
// frequency. Single-flight is enforced by bumping the cache mtime BEFORE spawning,
// so concurrent refreshes — and other sessions sharing ~/.cache/dhx — skip.
//
// Cache: ~/.cache/dhx/ccburn-json.json holds raw `--json --once` output; the wrapper
// builds the segment at read time. This file also supersedes the old rolling
// statusline-trace.jsonl for raw-json anomaly inspection.
// Probe: tests/probes/probe-ccburn-no-orphan.sh. Tunables are env-overridable.
const CCBURN_CACHE = process.env.DHX_CCBURN_CACHE
  || path.join(os.homedir(), '.cache', 'dhx', 'ccburn-json.json');
const CCBURN_TTL_MS = Number(process.env.DHX_CCBURN_TTL_MS) || 30_000;
const CCBURN_REFRESH_TIMEOUT = process.env.DHX_CCBURN_REFRESH_TIMEOUT || '10s';
const CCBURN_COLLECT_TIMEOUT = process.env.DHX_CCBURN_COLLECT_TIMEOUT || '2s';
const CCBURN_KILL_AFTER = process.env.DHX_CCBURN_KILL_AFTER || '2s';

// Detached, timeout-bounded background refresh of the ccburn cache. Fire-and-forget:
// it survives this wrapper's exit (detached+unref) to finish the slow scan, but each
// ccburn invocation is `timeout`-bounded so it cannot orphan indefinitely.
function refreshCcburnCache(stdinData) {
  try {
    fs.mkdirSync(path.dirname(CCBURN_CACHE), { recursive: true });
    const tmp = `${CCBURN_CACHE}.${process.pid}.tmp`;
    // collect (cheap, ~0.03s) populates ccburn's DB; then the heavy read. Atomic
    // publish via rename; tmp cleaned on failure. Paths are fixed/internal — the
    // only external value (stdinData) is fed via stdin, never interpolated.
    const sh =
      `timeout -k ${CCBURN_KILL_AFTER} ${CCBURN_COLLECT_TIMEOUT} ccburn collect >/dev/null 2>&1; ` +
      `timeout -k ${CCBURN_KILL_AFTER} ${CCBURN_REFRESH_TIMEOUT} ccburn --json --once > '${tmp}' 2>/dev/null ` +
      `&& mv -f '${tmp}' '${CCBURN_CACHE}' || rm -f '${tmp}'`;
    const child = spawn('bash', ['-c', sh], { detached: true, stdio: ['pipe', 'ignore', 'ignore'] });
    child.stdin.on('error', () => {}); // EPIPE if `collect` exits before reading
    child.stdin.end(stdinData);        // fed to `ccburn collect`
    child.unref();
  } catch { /* best-effort; the render still shows the last cached value */ }
}

// Render-path entry: returns the cached segment instantly; triggers a single
// background refresh when the cache is older than the TTL. Never blocks on ccburn.
async function runCcburn(stdinData) {
  let raw = '';
  let mtimeMs = 0;
  try {
    const st = fs.statSync(CCBURN_CACHE);
    mtimeMs = st.mtimeMs;
    raw = fs.readFileSync(CCBURN_CACHE, 'utf8');
  } catch { /* no cache yet — first run renders nothing, populates for the next refresh */ }

  if (Date.now() - mtimeMs >= CCBURN_TTL_MS) {
    // Claim the refresh slot by bumping mtime FIRST, so concurrent refreshes and
    // other sessions sharing this cache don't all spawn (single-flight).
    try {
      const now = new Date();
      try {
        fs.utimesSync(CCBURN_CACHE, now, now);
      } catch {
        fs.mkdirSync(path.dirname(CCBURN_CACHE), { recursive: true });
        fs.writeFileSync(CCBURN_CACHE, '');
      }
    } catch { /* claim failed; still attempt the refresh below */ }
    refreshCcburnCache(stdinData);
  }

  return buildCcburnSegment(raw) || '';
}

// Rolling ccburn trace — ~/.cache/dhx/statusline-trace.jsonl (+ .prev on rotation).
// Captures raw --json output + composed segment per refresh so a recurrence of
// the 2026-04-23 "1h298" anomaly (duration ending in a digit — not producible
// by formatBurnDuration()) can be replayed off-line: either ccburn emitted
// malformed JSON-adjacent bytes or our composition went wrong. Size-bounded at
// 1MB → rotate to .prev (~2MB disk ceiling). Append via fs.appendFile
// fire-and-forget so the statusline refresh stays non-blocking. Retire by
// 2026-06-01 if no matching anomaly lands in the trace — tracked by
// docs/backlog.md::ccburn-trace-retire.
const TRACE_FILE = path.join(os.homedir(), '.cache', 'dhx', 'statusline-trace.jsonl');
const TRACE_MAX_BYTES = 1_000_000;
function appendTrace(entry) {
  try {
    const line = JSON.stringify(entry) + '\n';
    try {
      const st = fs.statSync(TRACE_FILE);
      if (st.size + line.length > TRACE_MAX_BYTES) {
        fs.renameSync(TRACE_FILE, TRACE_FILE + '.prev');
      }
    } catch { /* first write — file absent, nothing to rotate */ }
    fs.appendFile(TRACE_FILE, line, () => {});
  } catch { /* trace must never block the statusline */ }
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
// not block the render path. Mirrors appendTrace exactly.
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
// Aggregates the four "something needs attention" signals — drift warning,
// critical health (front), advisory health (tail), per-segment crash sigils —
// into a single leftmost glyph. Dim green ∙ (color 70) means the pipeline is
// running AND every signal is clean; bright yellow ⌃ (color 220) means at
// least one signal is firing (the user reads the existing detail to know which).
//
// Purely additive: prepended BEFORE the existing front composition so the full
// leftmost order becomes meta-glyph → drift → critical-health → renderer-line1.
// Existing detail (drift text, critical/advisory health text, sigils) renders
// unchanged after the glyph.
//
// Why a meta-glyph at all: today, a session with no health warnings shows
// nothing in the front-of-stack zone — users can't distinguish "all good" from
// "statusline broken / not running". An explicit dim green ∙ confirms the pipeline
// is alive AND clean, distinct from segment-specific signals which only appear
// during faults.
//
// Color non-collision: meta-glyph green 70 + yellow 220 are distinct from
// critical 208 + advisory red 31 + sigil red 31. (Sigil and advisory share the
// red palette but never co-locate — sigil sits where the segment's normal
// output would have been; advisory sits at the tail.)
function computeMetaGlyph(driftWarning, healthFront, healthTail, sigilCount) {
  const warn = !!driftWarning || !!healthFront || !!healthTail || sigilCount > 0;
  // Hairline glyphs: ∙ (U+2219 bullet operator, dim green) for clean / ⌃ (U+2303
  // up arrowhead, bright yellow) for warn. Chosen 2026-04-26 over solid ● / ▲ to
  // recede on the clean path while preserving the third-state distinction —
  // presence-vs-absence still detects "watcher dead." Colors unchanged.
  return warn ? '\x1b[38;5;220m⌃\x1b[0m' : '\x1b[2;38;5;70m∙\x1b[0m';
}

// Map ccburn's pace status → status glyph. `status` reflects utilization-vs-
// budget-pace (behind = conserving, ahead = burning hot), which is what the
// user actually reads at a glance — not raw % alone. Unknown statuses
// collapse to empty so the segment still renders a pct without a misleading
// icon.
//
// `on_pace` uses a dim `✓` (1 column, muted) instead of 🟢 (2 columns, full
// weight). Rationale: `on_pace` carries no action — nothing to fix, nothing
// to watch — so a muted glyph matches the signal's urgency; the original 🟢
// was oversized relative to the surrounding monochrome text. `behind_pace`
// (🧊) and `ahead_of_pace` (🚨) keep emoji because those states carry real
// informational weight (conserving / burning hot) and the distinctive shape
// earns the extra column. Tradeoff: segment width jitters by one column when
// session transitions into/out of on_pace. Acceptable — status transitions
// are rare (minutes/hours apart) vs. the timer's per-refresh tick.
//
// INVARIANT: ccburn's get_status() returns exactly one of
// {ahead_of_pace, on_pace, behind_pace} — see
// ccburn/utils/calculator.py:203 (the only producer). Expired limits get
// coerced to behind_pace in ccburn/app.py:677/693, so `exhausted` is never
// emitted and doesn't need a branch here. Prior map carried `at_pace`/
// `exhausted` — stale from an older ccburn; silently dropped session emoji
// across every refresh once ccburn renamed to `on_pace`.
function statusEmoji(status) {
  switch (status) {
    case 'behind_pace':   return '🧊';
    case 'on_pace':       return '\x1b[2m✓\x1b[0m';
    case 'ahead_of_pace': return '🚨';
    default:              return '';
  }
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

// Build the ccburn status segment from parsed JSON. ccburn exposes one
// reset field populated per limit (minutes for short horizons, hours for
// long ones); we normalize to minutes before formatting. Partial limits
// (session present, weekly absent, or vice versa) render whichever side
// has data — resilient to ccburn shape drift.
//
// Example: `{limits:{session:{utilization:0.09,status:"behind_pace",resets_in_minutes:118},
// weekly:{utilization:0.47,status:"ahead_of_pace",resets_in_hours:72}}}`
// →       `S:🧊 9% (1h58m) · W:🚨 47% (3d)`
function buildCcburnSegment(jsonText) {
  if (!jsonText) return '';
  let data;
  try { data = JSON.parse(jsonText); } catch { return ''; }
  const limits = data && data.limits;
  if (!limits) return '';
  const parts = [];
  for (const [key, prefix] of [['session', 'S'], ['weekly', 'W']]) {
    const limit = limits[key];
    if (!limit) continue;
    const pct = Math.round((limit.utilization || 0) * 100);
    const emoji = statusEmoji(limit.status);
    const mins = limit.resets_in_minutes != null
      ? limit.resets_in_minutes
      : limit.resets_in_hours != null
        ? limit.resets_in_hours * 60
        : null;
    const dur = formatBurnDuration(mins);
    const pctLabel = emoji ? `${emoji} ${pct}%` : `${pct}%`;
    parts.push(`${prefix}:${pctLabel}${dur ? ` (${dur})` : ''}`);
  }
  return parts.join(' · ');
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
// fresh (<1h via checked_at), its plugin_keys replaces health.json's. This
// lets mid-session `/dhx:sym repair` clear the warning within 60s instead of
// waiting for the next SessionStart. Stale/missing/malformed → defer to
// health.json, which already carries the SessionStart-time direct jq check.
//
// INVARIANT: sole runtime reader of ~/.cache/dhx/health.json. Atomic schema
// extension (new field in same commit as new reader branch) is safe only
// while this holds — grep hooks+skills repos for readers before extending.
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
        if (Number.isFinite(ageMs) && ageMs >= 0 && ageMs < 3600 * 1000 && sym.plugin_keys) {
          h.plugin_keys = sym.plugin_keys;
        }
      } catch { /* absent/malformed — defer to health.json's value */ }

      // Plugin-registry drift runs inline every refresh (no SessionStart
      // publisher) — it's the only class of clobber that can take out the
      // plugin hooks that would otherwise write it. See checkPluginRegistry().
      try {
        const configDir = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
        const state = checkPluginRegistry(configDir, sessionId);
        if (state) h.plugin_registry = state;
      } catch { /* detector errors never block the statusline */ }

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
        missing_symlinks: (v) => v > 0 ? `${v} broken symlink${v > 1 ? 's' : ''}` : null,
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
        const full = entry.path ? path.join(entry.path, entry.name) : path.join(dir, entry.name);
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
        const full = entry.path ? path.join(entry.path, entry.name) : path.join(dir, entry.name);
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
      // `entry.path` is the absolute parent dir (Node ≥ 20); fall back to the
      // scan root for top-level entries.
      const absParent = entry.path || root;
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
const GSD_LIVE_ROOT = path.join(os.homedir(), '.claude', 'get-shit-done');
const GSD_FORK_ROOT = path.join(os.homedir(), '.claude', 'gsd-local-patches', 'get-shit-done');

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
      const full = entry.path ? path.join(entry.path, entry.name) : path.join(liveRoot, entry.name);
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
      const full = entry.path ? path.join(entry.path, entry.name) : path.join(liveRoot, entry.name);
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

    // Drift detected — age from snapshot file's own mtime (≈ session start)
    let ageMs = 0;
    try {
      ageMs = Date.now() - fs.statSync(snapshotFile).mtimeMs;
    } catch { /* fallback to 0 */ }

    let ageStr;
    if (ageMs < 60 * 1000) {
      ageStr = '<1m';
    } else if (ageMs < 60 * 60 * 1000) {
      ageStr = `${Math.floor(ageMs / (60 * 1000))}m`;
    } else {
      const h = Math.floor(ageMs / (60 * 60 * 1000));
      const m = Math.floor((ageMs % (60 * 60 * 1000)) / (60 * 1000));
      ageStr = `${h}h ${m}m`;
    }

    // Gsd-trigger detail injection (Problem 2 in reports/2026-05-18-canonical-
    // mirror-drift-from-unmirrored-edit.md). Only meaningful when the gsd mtime
    // branch fired alone — count branch is a deletion, no diverging-file list
    // applies. Render `gsd:execute-phase.md` for single-file drift, `gsd:3files`
    // for multi-file. Empty suffix when no detail is computable (fork-tree-
    // missing or zero-length list).
    let gsdDetail = '';
    let gsdDiverging = null;
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

        fs.mkdirSync(cacheDir, { recursive: true });
        writeAtomic(cacheFile, newCache);
      } catch { /* cache failure must not affect drift detection */ }
    }

    const triggersStr = triggers.map(t => t === 'gsd' ? `gsd${gsdDetail}` : t).join('+');
    resolve(`\x1b[38;5;208m⚠ restart ${triggersStr} (${ageStr})\x1b[0m`);
  });
}

// Cache-TTL countdown. Anchors on the most recent assistant entry whose
// usage block reports cache_read_input_tokens > 0 — that timestamp is when
// the warm prefix was last touched on the server, which is what actually
// keeps the cache TTL alive. Always-on segment: green ≥30m, yellow <30m,
// orange 208 <15m, red EXPIRED. Default TTL 3600s matches Max plan
// (verified 2026-04-17, docs/research/economics/session-cost-mechanics.md);
// DHX_CACHE_TTL env overrides for Pro/API (300).
//
// Why not mtime: away_summary writes (HP-019 / docs/research/economics/away-summary-billing.md)
// bump JSONL mtime without producing a type=assistant entry — and they're
// billed inference calls. Anchoring on mtime would make the countdown
// "reset" every ~3-15 min during idle while the user silently pays for
// each recap, training the signal to lie. cache_read timestamps come from
// the same `usage` block billing is computed from, so the countdown can't
// drift from cost reality. Active streaming still reads near full TTL —
// each chunk lands as a cache_read entry.
//
// Resume re-anchors automatically: post-/resume sessions see one re-cache
// turn (~70k cache_creation, GH #42338) and then the next turn lands as a
// fresh cache_read entry — the new anchor.
//
// 64KB tail-read sized for typical assistant entries (~1-5KB each); a
// degenerate 64KB+ tool_use_result blocking every entry resolves to ''
// (segment hides for one render, returns on next turn).
function getCacheAge(data) {
  return new Promise((resolve) => {
    const transcriptPath = data.transcript_path;
    if (!transcriptPath) return resolve('');
    const ttl = parseInt(process.env.DHX_CACHE_TTL, 10) || 3600;
    const anchorMs = readCacheAnchor(transcriptPath);
    if (anchorMs == null) return resolve('');
    const elapsed = (Date.now() - anchorMs) / 1000;
    // Clamp upward to absorb clock skew / pre-write stat.
    const remaining = Math.min(ttl, Math.floor(ttl - elapsed));
    if (remaining <= 0) return resolve('\x1b[31mEXPIRED\x1b[0m');
    const mins = Math.floor(remaining / 60);
    const label = mins < 1 ? '<1m' : `${mins}m`;
    let color;
    if (remaining < 15 * 60) color = '\x1b[38;5;208m'; // orange 208
    else if (remaining < 30 * 60) color = '\x1b[33m';  // yellow
    else color = '\x1b[32m';                            // green
    resolve(`${color}${label}\x1b[0m`);
  });
}

// Tail-read last 64KB of the JSONL transcript and return ms-epoch of the
// most recent type=assistant entry whose usage.cache_read_input_tokens > 0.
// Returns null on missing file, unreadable file, no match in window, or
// unparseable timestamps. Tail-read (not readFileSync) because transcripts
// grow without bound — a 50MB session pulled into memory every refresh is
// not acceptable for a 1Hz statusline.
//
// INVARIANT: depends on JSONL transcript schema (HP-019). type=assistant
// entries carry .timestamp (ISO 8601) and .message.usage.cache_read_input_tokens.
// Probe: tests/probes/probe-cache-age-anchor.js.
function readCacheAnchor(transcriptPath) {
  const WINDOW = 65536;
  let fd;
  try {
    fd = fs.openSync(transcriptPath, 'r');
    const size = fs.fstatSync(fd).size;
    if (size === 0) return null;
    const len = Math.min(WINDOW, size);
    const buf = Buffer.alloc(len);
    fs.readSync(fd, buf, 0, len, size - len);
    const lines = buf.toString('utf8').split('\n');
    // Skip the first split when the window starts mid-record — it's a partial
    // line. When the window covers the whole file, byte 0 is a real line head.
    const startIdx = size > WINDOW ? 1 : 0;
    for (let i = lines.length - 1; i >= startIdx; i--) {
      const line = lines[i];
      if (!line) continue;
      let entry;
      try { entry = JSON.parse(line); } catch { continue; }
      if (entry.type !== 'assistant') continue;
      const reads = entry.message && entry.message.usage && entry.message.usage.cache_read_input_tokens;
      if (!reads || reads <= 0) continue;
      const t = Date.parse(entry.timestamp || '');
      if (Number.isFinite(t)) return t;
    }
    return null;
  } catch {
    return null;
  } finally {
    if (fd !== undefined) { try { fs.closeSync(fd); } catch { /* nothing */ } }
  }
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

    // Branch name
    parts.push(`\x1b[36m${branch}\x1b[0m`);

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
  buildCcburnSegment,
  formatBurnDuration,
  statusEmoji,
  hashWarnSettings,
  canonicalize,
  checkPluginRegistry,
  isGsdDriftFromForkSync,
  collectGsdDriftDivergingFiles,
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
  // runCcburn export — lets probe-ccburn-no-orphan.sh drive the real function
  // (not a reimplementation) under a hung fake-ccburn on PATH to assert the
  // 2026-05-25 orphan-prevention invariant (child self-terminates via coreutil
  // `timeout` even after the Node parent is SIGKILLed).
  runCcburn,
  // Per-segment self-diagnosis (2026-04-26 #4)
  withSegmentDiag,
  appendStatuslineError,
  computeSegmentSigil,
  // Meta-glyph composition (2026-04-26 #2b)
  computeMetaGlyph,
};
