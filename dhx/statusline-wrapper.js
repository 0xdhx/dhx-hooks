#!/usr/bin/env node
// gsd-hook-version: 1.36.0
// Patterns: HP-013, HP-014, HP-016
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

  // Run GSD statusline, git info, ccburn, health cache, and drift check in parallel
  // ccburn collect silently feeds its database; compact output goes in the statusline
  Promise.all([
    runGsd(input),
    getGitInfo(cwd),
    runCcburn(input),
    readHealthCache(),
    checkDrift(data),
  ]).then(([gsdOutput, gitInfo, burnOutput, healthWarning, driftWarning]) => {
    // Strip false-positive stale hooks warning (upstream bug: bash hooks lack
    // JS-style version headers, fixed in GSD Unreleased but not v1.36.0).
    // Remove this filter once upstream ships the fix (#2136).
    let line = gsdOutput.replace(/\x1b\[3[13]m⚠ (?:stale hooks|dev install)[^\x1b]*\x1b\[0m *│ */g, '').trimEnd();
    if (gitInfo) {
      line += ` \x1b[2m│\x1b[0m ${gitInfo}`;
    }
    if (burnOutput) {
      line += ` \x1b[2m│\x1b[0m ${burnOutput}`;
    }
    if (healthWarning) {
      line += ` \x1b[2m│\x1b[0m ${healthWarning}`;
    }
    // Drift warning goes FIRST (D-05: front-of-stack)
    if (driftWarning) {
      line = driftWarning + ' \x1b[2m|\x1b[0m ' + line;
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
// Returns a warning string if issues found, empty string if healthy.
// All non-ok classes share one recovery command (`/dhx:sym repair`); appending
// a single trailing suffix to the joined span keeps the signal scannable and
// gives users immediate direction instead of an opaque state token.
//
// Publisher override: sym-health.json is written by the skills-repo `/dhx:sym`
// status/audit/repair commands — the authoritative source for plugin_keys
// (same process that runs `claude plugin enable` publishes the result). When
// fresh (<1h via checked_at), its plugin_keys replaces health.json's. This
// lets mid-session `/dhx:sym repair` clear the warning within 60s instead of
// waiting for the next SessionStart. Stale/missing/malformed → defer to
// health.json, which already carries the SessionStart-time direct jq check.
function readHealthCache() {
  return new Promise((resolve) => {
    const cacheFile = path.join(os.homedir(), '.cache', 'dhx', 'health.json');
    fs.readFile(cacheFile, 'utf8', (err, data) => {
      if (err) return resolve('');
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

        const warnings = [];
        if (h.worktree_patches && h.worktree_patches !== 'patched')
          warnings.push(`patches:${h.worktree_patches}`);
        if (h.read_guard && h.read_guard !== 'patched')
          warnings.push(`read-guard:${h.read_guard}`);
        if (h.missing_symlinks > 0)
          warnings.push(`${h.missing_symlinks} broken symlink${h.missing_symlinks > 1 ? 's' : ''}`);
        if (h.settings_chain && h.settings_chain !== 'ok')
          warnings.push(`settings:${h.settings_chain}`);
        if (h.plugin_keys && h.plugin_keys !== 'ok')
          warnings.push(`plugin-keys:${h.plugin_keys}`);
        if (warnings.length === 0) return resolve('');
        resolve(`\x1b[31m⚠ ${warnings.join(' ')} — /dhx:sym repair\x1b[0m`);
      } catch { resolve(''); }
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
