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

// Drift detection (D-02, D-03, D-04, D-05): scans 5 watched paths and compares
// mtime against session-start time. Returns an orange warning or empty string.
function checkDrift(data) {
  return new Promise((resolve) => {
    if (!data.session_id) return resolve('');

    const cacheDir = path.join(os.homedir(), '.cache', 'dhx');
    const sessionId = data.session_id;
    const sessionStartFile = path.join(cacheDir, `session-start-${sessionId}.json`);

    // Get session start time: primary from cache, fallback creates it.
    // SessionStart hooks don't receive session_id in stdin, so the health-check
    // can't write this cache. The wrapper writes it on first invocation instead.
    let sessionStartMs;
    try {
      const raw = fs.readFileSync(sessionStartFile, 'utf8');
      const parsed = JSON.parse(raw);
      if (parsed.started && typeof parsed.started === 'number') {
        sessionStartMs = parsed.started * 1000; // epoch seconds -> ms
      }
    } catch { /* cache miss — write it now */ }

    if (!sessionStartMs) {
      // First invocation for this session — write session-start cache.
      // Use transcript birthtime if available (more accurate than Date.now()
      // for sessions that started before this code was deployed), else now.
      let startEpochSec = Math.floor(Date.now() / 1000);
      if (data.transcript_path) {
        try {
          startEpochSec = Math.floor(fs.statSync(data.transcript_path).birthtimeMs / 1000);
        } catch { /* use Date.now() fallback */ }
      }
      sessionStartMs = startEpochSec * 1000;
      try {
        const tmp = sessionStartFile + '.tmp.' + process.pid;
        fs.writeFileSync(tmp, JSON.stringify({ started: startEpochSec, session_id: sessionId }));
        fs.renameSync(tmp, sessionStartFile);
      } catch { /* write failed — still use the derived time for this invocation */ }
    }

    // --- Version drift check (Path 3) ---
    // On first invocation for this session, cache the version. On subsequent
    // invocations, compare against the cached value.
    let versionDrifted = false;
    if (data.version) {
      const versionFile = path.join(cacheDir, `session-version-${sessionId}.txt`);
      try {
        if (!fs.existsSync(versionFile)) {
          fs.writeFileSync(versionFile, data.version, 'utf8');
        } else {
          const cachedVersion = fs.readFileSync(versionFile, 'utf8').trim();
          if (cachedVersion !== data.version) {
            versionDrifted = true;
          }
        }
      } catch { /* ignore version tracking errors */ }
    }

    // --- mtime scan of 5 watched paths (D-04) ---
    let maxMtime = 0;

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

    // Path 1: ~/.claude/agents/ — recursive
    const agentsDir = path.join(os.homedir(), '.claude', 'agents');
    const agentsMtime = getMaxMtimeRecursive(agentsDir);
    if (agentsMtime > maxMtime) maxMtime = agentsMtime;

    // Path 2: Active settings.json — follow symlinks
    try {
      const configDir = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
      const settingsRaw = path.join(configDir, 'settings.json');
      const settingsReal = fs.realpathSync(settingsRaw);
      const st = fs.statSync(settingsReal);
      if (st.mtimeMs > maxMtime) maxMtime = st.mtimeMs;
    } catch { /* missing or unresolvable */ }

    // Path 3: Version — handled above via versionDrifted flag

    // Path 4: ~/.claude/get-shit-done/ — recursive
    const gsdDir = path.join(os.homedir(), '.claude', 'get-shit-done');
    const gsdMtime = getMaxMtimeRecursive(gsdDir);
    if (gsdMtime > maxMtime) maxMtime = gsdMtime;

    // Path 5: CCS plugins cache — shallow scan of top-level dirs only (~16 entries)
    try {
      const configDir = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
      const pluginsCache = path.join(configDir, 'plugins', 'cache');
      const entries = fs.readdirSync(pluginsCache, { withFileTypes: true });
      for (const entry of entries) {
        try {
          const st = fs.statSync(path.join(pluginsCache, entry.name));
          if (st.mtimeMs > maxMtime) maxMtime = st.mtimeMs;
        } catch { /* skip */ }
      }
    } catch { /* plugins cache missing — no-op */ }

    // --- Compare and format ---
    if (maxMtime <= sessionStartMs && !versionDrifted) return resolve('');

    // Drift detected — format age warning
    const ageMs = Date.now() - sessionStartMs;
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

    resolve(`\x1b[38;5;208m⚠ restart (${ageStr})\x1b[0m`);
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
