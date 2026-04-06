#!/usr/bin/env node
// gsd-hook-version: 1.26.0
// Statusline wrapper — pipes stdin through GSD's gsd-statusline.js, appends git info.
// GSD script is called by path so GSD updates are picked up automatically.

const { execFile, spawn } = require('child_process');
const path = require('path');
const os = require('os');

// Resolve GSD script via ~/.claude/hooks/ (not __dirname, which follows symlinks)
const GSD_SCRIPT = path.join(os.homedir(), '.claude', 'hooks', 'gsd-statusline.js');

// Collect stdin
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => input += chunk);
process.stdin.on('end', () => {
  let cwd;
  try {
    const data = JSON.parse(input);
    cwd = data.workspace?.current_dir || process.cwd();
  } catch {
    cwd = process.cwd();
  }

  // Run GSD statusline and git info in parallel
  Promise.all([
    runGsd(input),
    getGitInfo(cwd),
  ]).then(([gsdOutput, gitInfo]) => {
    let line = gsdOutput.trimEnd();
    if (gitInfo) {
      line += ` \x1b[2m│\x1b[0m ${gitInfo}`;
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
