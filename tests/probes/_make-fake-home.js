'use strict';
// _make-fake-home.js — shared fixture builder for probes that exercise
// dhx/statusline-wrapper.js under an isolated $HOME.
//
// Underscore prefix keeps this file out of `scripts/run-probes.sh`'s
// `probe-*.{js,sh}` glob — it's a helper module, not a probe.
//
// Companion to the same-day silent-red repair (probe-statusline-self-diag.js
// + probe-health-suffix.js) and the same-day verify-hook-patterns.sh
// check #8 that gates the probe suite on wrapper/probe edits.

const fs = require('fs');
const os = require('os');
const path = require('path');

// Real renderer module — symlinked into each fake $HOME so a wrapper
// require()/spawn() that resolves $HOME/.claude/hooks/dhx-statusline.js
// finds the actual renderer. Required since 2026-04-28 commit 30893e3
// when getRepoSignals/formatLine2Signals moved out of the renderer's
// runStatusline() body and into wrapper-level require'd exports
// (dhx/statusline-wrapper.js:22 does
//   const { getRepoSignals, formatLine2Signals } = require(STATUSLINE_SCRIPT)
// at module-load, where STATUSLINE_SCRIPT joins os.homedir()).
//
// dhx-statusline.js gates its top-level runStatusline() on
// `require.main === module`, so requiring it from a wrapper has no I/O
// side effects. Spawning it (the live render path) finds the symlink
// the same way production resolves ~/.claude/hooks/dhx-statusline.js
// (which is itself a symlink into the dhx repo).
const REAL_RENDERER = path.resolve(__dirname, '..', '..', 'dhx', 'dhx-statusline.js');

// Build an isolated fake $HOME suitable for spawning or require()ing
// dhx/statusline-wrapper.js. Returns the absolute path; callers add
// per-test fixtures (health.json, sym-health.json, transcripts, etc.)
// at well-known paths inside the returned directory.
//
// What's set up:
//   <home>/.cache/dhx/                       — health.json + drift snapshots land here
//   <home>/.claude/hooks/dhx-statusline.js   — symlink to the real renderer
//
// If the wrapper grows a new module-load dependency on a $HOME-derived
// path, extend this helper rather than copying the symlink dance into
// each new probe. Probes that don't touch the wrapper at all should
// continue to use bare `fs.mkdtempSync` — the helper exists to mark
// the wrapper-fixture surface, not to be the only tmpdir builder.
function makeFakeHome(prefix) {
  if (typeof prefix !== 'string' || !prefix) prefix = 'dhx-fake-home-';
  const home = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  fs.mkdirSync(path.join(home, '.cache', 'dhx'), { recursive: true });
  fs.mkdirSync(path.join(home, '.claude', 'hooks'), { recursive: true });
  fs.symlinkSync(REAL_RENDERER, path.join(home, '.claude', 'hooks', 'dhx-statusline.js'));
  return home;
}

module.exports = { makeFakeHome, REAL_RENDERER };
