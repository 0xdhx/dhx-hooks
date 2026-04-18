#!/usr/bin/env node
// gsd-hook-version: 1.37.1
// Patterns: HP-013, HP-014, HP-016, HP-019
// Statusline wrapper — pipes stdin through GSD's gsd-statusline.js, appends git info.
// GSD script is called by path so GSD updates are picked up automatically.

const { execFile, spawn } = require('child_process');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const os = require('os');

// Resolve GSD script via ~/.claude/hooks/ (not __dirname, which follows symlinks)
const GSD_SCRIPT = path.join(os.homedir(), '.claude', 'hooks', 'gsd-statusline.js');

// Collect stdin
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => input += chunk);
process.stdin.on('end', () => {
  let data = {};
  let cwd;
  try {
    data = JSON.parse(input);
    cwd = data.workspace?.current_dir || process.cwd();
  } catch {
    cwd = process.cwd();
  }

  // Run GSD statusline, git info, cache-age, ccburn, health cache, and drift check in parallel
  // ccburn collect silently feeds its database; compact output goes in the statusline
  Promise.all([
    runGsd(input),
    getGitInfo(cwd),
    getCacheAge(data),
    runCcburn(input),
    readHealthCache(),
    checkDrift(data),
  ]).then(([gsdOutput, gitInfo, cacheAge, burnOutput, health, driftWarning]) => {
    let line = gsdOutput.trimEnd();
    if (gitInfo) {
      line += ` \x1b[2m│\x1b[0m ${gitInfo}`;
    }
    if (cacheAge) {
      line += ` \x1b[2m│\x1b[0m ${cacheAge}`;
    }
    if (burnOutput) {
      line += ` \x1b[2m│\x1b[0m ${burnOutput}`;
    }
    // Advisory health (fork/symlink state) — red tail, session still works
    if (health.tail) {
      line += ` \x1b[2m│\x1b[0m ${health.tail}`;
    }
    // Front-of-stack (orange 208, left of Claude/cwd): drift + critical health
    // (session-wiring degraded: plugin_keys, settings_chain). Separate segments
    // keep concerns distinct — drift says "restart", health says "/dhx:sym repair".
    // Order: drift first (session identity), then health (session wiring).
    const front = [];
    if (driftWarning) front.push(driftWarning);
    if (health.front) front.push(health.front);
    if (front.length > 0) {
      line = front.join(' \x1b[2m|\x1b[0m ') + ' \x1b[2m|\x1b[0m ' + line;
    }
    process.stdout.write(line);
  }).catch(() => {
    // If everything fails, output nothing — don't break the statusline
  });
});

// Pipe the raw stdin JSON into GSD's statusline script and capture stdout
function runGsd(stdinData) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [GSD_SCRIPT], {
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

// ccburn: collect data + return compact status
function runCcburn(stdinData) {
  return new Promise((resolve) => {
    // Feed stdin to ccburn collect (populates its database)
    const collect = spawn('ccburn', ['collect'], {
      stdio: ['pipe', 'ignore', 'ignore'],
    });
    collect.stdin.write(stdinData);
    collect.stdin.end();
    collect.on('error', () => {}); // ccburn not installed — no-op

    // Get compact one-line status
    const compact = spawn('ccburn', ['--compact', '--once'], {
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    let out = '';
    compact.stdout.on('data', chunk => out += chunk);
    compact.on('close', () => resolve(out.trim()));
    compact.on('error', () => resolve(''));
  });
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
function readHealthCache() {
  return new Promise((resolve) => {
    const empty = { front: '', tail: '' };
    const cacheFile = path.join(os.homedir(), '.cache', 'dhx', 'health.json');
    fs.readFile(cacheFile, 'utf8', (err, data) => {
      if (err) return resolve(empty);
      try {
        const h = JSON.parse(data);

        try {
          const symFile = path.join(os.homedir(), '.cache', 'dhx', 'sym-health.json');
          const sym = JSON.parse(fs.readFileSync(symFile, 'utf8'));
          const ageMs = Date.now() - Date.parse(sym.checked_at || '');
          if (Number.isFinite(ageMs) && ageMs >= 0 && ageMs < 3600 * 1000 && sym.plugin_keys) {
            h.plugin_keys = sym.plugin_keys;
          }
        } catch { /* absent/malformed — defer to health.json's value */ }

        const critical = [];
        if (h.settings_chain && h.settings_chain !== 'ok')
          critical.push(`settings:${h.settings_chain}`);
        if (h.plugin_keys && h.plugin_keys !== 'ok')
          critical.push(`plugin-keys:${h.plugin_keys}`);

        const advisory = [];
        if (h.worktree_patches && h.worktree_patches !== 'patched')
          advisory.push(`patches:${h.worktree_patches}`);
        if (h.read_guard && h.read_guard !== 'patched')
          advisory.push(`read-guard:${h.read_guard}`);
        if (h.missing_symlinks > 0)
          advisory.push(`${h.missing_symlinks} broken symlink${h.missing_symlinks > 1 ? 's' : ''}`);

        const front = critical.length
          ? `\x1b[38;5;208m⚠ ${critical.join(' ')} — /dhx:sym repair\x1b[0m`
          : '';
        const tail = advisory.length
          ? `\x1b[31m⚠ ${advisory.join(' ')} — /dhx:sym repair\x1b[0m`
          : '';
        resolve({ front, tail });
      } catch { resolve(empty); }
    });
  });
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

// Helper: recursively get max mtime across all entries in a directory
function getMaxMtimeRecursive(dir) {
  let max = 0;
  try {
    const entries = fs.readdirSync(dir, { withFileTypes: true, recursive: true });
    for (const entry of entries) {
      try {
        const fullPath = entry.path ? path.join(entry.path, entry.name) : path.join(dir, entry.name);
        const st = fs.statSync(fullPath);
        if (st.mtimeMs > max) max = st.mtimeMs;
      } catch { /* skip unreadable entries */ }
    }
  } catch { /* directory doesn't exist or unreadable */ }
  return max;
}

// Collect current snapshot for all 5 watched paths + version. `settings` is
// hashed over the WARN-set projection rather than mtime'd — see HP-014's
// hot-reload note in the wrapper doc for why /effort, /model, /output-style,
// permission-grant mutations MUST NOT trip drift.
function collectSnapshot(data) {
  const configDir = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
  const snapshot = {
    agents_mtime: getMaxMtimeRecursive(path.join(os.homedir(), '.claude', 'agents')),
    settings_hash: '',
    gsd_mtime: getMaxMtimeRecursive(path.join(os.homedir(), '.claude', 'get-shit-done')),
    plugins_mtime: 0,
    version: data.version || '',
  };

  // Active settings.json — follow symlinks, hash WARN-set keys only
  try {
    const settingsReal = fs.realpathSync(path.join(configDir, 'settings.json'));
    snapshot.settings_hash = hashWarnSettings(settingsReal);
  } catch { /* missing or unresolvable — hash stays '' */ }

  // CCS plugins cache — shallow scan of top-level dirs
  try {
    const pluginsCache = path.join(configDir, 'plugins', 'cache');
    const entries = fs.readdirSync(pluginsCache, { withFileTypes: true });
    for (const entry of entries) {
      try {
        const st = fs.statSync(path.join(pluginsCache, entry.name));
        if (st.mtimeMs > snapshot.plugins_mtime) snapshot.plugins_mtime = st.mtimeMs;
      } catch { /* skip */ }
    }
  } catch { /* plugins cache missing — no-op */ }

  return snapshot;
}

// Drift detection (D-02 through D-05): snapshot comparison.
// First invocation: snapshots all 5 path mtimes + version into a single cache file.
// Subsequent invocations: compares current state against snapshot, warns on change.
// Age timer uses the snapshot file's own mtime (written ≈ session start).
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
        const tmp = snapshotFile + '.tmp.' + process.pid;
        fs.writeFileSync(tmp, JSON.stringify(current));
        fs.renameSync(tmp, snapshotFile);
      } catch { /* write failed — skip drift this invocation */ }
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

    // Schema migration: pre-hash snapshots lack `settings_hash`. Treat as
    // first-invocation — re-baseline with the current hash-bearing snapshot
    // and skip drift this round. Avoids comparing mixed-format fields and
    // guarantees one-round grace on upgrade.
    if (!('settings_hash' in snapshot)) {
      return writeBaselineAndReturnClean();
    }

    // Compare: collect which paths drifted (short labels match snapshot keys).
    // Exposing triggers enables tuning — without this, every false positive
    // looks identical and there's no way to diagnose which signal is noisy.
    const triggers = [];
    if (current.agents_mtime > snapshot.agents_mtime) triggers.push('agents');
    if (current.settings_hash !== snapshot.settings_hash) triggers.push('settings');
    if (current.gsd_mtime > snapshot.gsd_mtime) triggers.push('gsd');
    if (current.plugins_mtime > snapshot.plugins_mtime) triggers.push('plugins');
    if (current.version !== snapshot.version) triggers.push('version');

    if (triggers.length === 0) return resolve('');

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

    resolve(`\x1b[38;5;208m⚠ restart ${triggers.join('+')} (${ageStr})\x1b[0m`);
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
