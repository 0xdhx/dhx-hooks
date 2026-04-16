#!/usr/bin/env node
// gsd-hook-version: 1.36.0
// Statusline wrapper — pipes stdin through GSD's gsd-statusline.js, appends git info.
// GSD script is called by path so GSD updates are picked up automatically.

const { execFile, spawn } = require('child_process');
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
function readHealthCache() {
  return new Promise((resolve) => {
    const cacheFile = path.join(os.homedir(), '.cache', 'dhx', 'health.json');
    fs.readFile(cacheFile, 'utf8', (err, data) => {
      if (err) return resolve('');
      try {
        const h = JSON.parse(data);
        const warnings = [];
        if (h.worktree_patches && h.worktree_patches !== 'patched')
          warnings.push(`patches:${h.worktree_patches}`);
        if (h.read_guard && h.read_guard !== 'patched')
          warnings.push(`read-guard:${h.read_guard}`);
        if (h.missing_symlinks > 0)
          warnings.push(`${h.missing_symlinks} broken symlink${h.missing_symlinks > 1 ? 's' : ''}`);
        if (h.settings_chain && h.settings_chain !== 'ok')
          warnings.push(`settings:${h.settings_chain}`);
        if (warnings.length === 0) return resolve('');
        resolve(`\x1b[31m⚠ ${warnings.join(' ')}\x1b[0m`);
      } catch { resolve(''); }
    });
  });
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

// Collect current mtime snapshot for all 5 watched paths + version
function collectSnapshot(data) {
  const configDir = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
  const snapshot = {
    agents_mtime: getMaxMtimeRecursive(path.join(os.homedir(), '.claude', 'agents')),
    settings_mtime: 0,
    gsd_mtime: getMaxMtimeRecursive(path.join(os.homedir(), '.claude', 'get-shit-done')),
    plugins_mtime: 0,
    version: data.version || '',
  };

  // Active settings.json — follow symlinks
  try {
    const settingsReal = fs.realpathSync(path.join(configDir, 'settings.json'));
    snapshot.settings_mtime = fs.statSync(settingsReal).mtimeMs;
  } catch { /* missing or unresolvable */ }

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
    const snapshotFile = path.join(cacheDir, `drift-snapshot-${data.session_id}.json`);

    // Collect current state
    const current = collectSnapshot(data);

    // Try to read existing snapshot
    let snapshot;
    try {
      snapshot = JSON.parse(fs.readFileSync(snapshotFile, 'utf8'));
    } catch {
      // First invocation for this session — write snapshot, return clean
      try {
        const tmp = snapshotFile + '.tmp.' + process.pid;
        fs.writeFileSync(tmp, JSON.stringify(current));
        fs.renameSync(tmp, snapshotFile);
      } catch { /* write failed — skip drift this invocation */ }
      return resolve('');
    }

    // Compare: collect which paths drifted (short labels match snapshot keys).
    // Exposing triggers enables tuning — without this, every false positive
    // looks identical and there's no way to diagnose which signal is noisy.
    const triggers = [];
    if (current.agents_mtime > snapshot.agents_mtime) triggers.push('agents');
    if (current.settings_mtime > snapshot.settings_mtime) triggers.push('settings');
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
