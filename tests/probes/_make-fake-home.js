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
// Every fake home this module hands out, removed on process exit.
//
// Why here and not left to callers: cleanup WAS per-caller, and the caller that
// forgot leaked silently at rc 0 for months. Measured 2026-08-15:
// probe-statusline-self-diag.js allocated five fake homes per run and removed
// none, leaving 41 `selfdiag-*` trees in /tmp while the probe reported PASS —
// a leak that reports as success is invisible until someone counts /tmp.
// Centralizing matches this file's own stated contract ("extend this helper
// rather than copying the symlink dance into each new probe"): the allocation
// lives here, so the cleanup obligation does too, and a future caller cannot
// forget something it never has to write.
//
// Callers that ALREADY clean up in a `finally` (probe-health-suffix.js et al.)
// stay correct and unchanged — `force: true` makes removing an absent path a
// no-op, so the two layers compose rather than fight. Their eager cleanup is
// still worth keeping: it frees space mid-run rather than at exit.
const _fakeHomes = [];

function _cleanupFakeHomes() {
  // Escape hatch for debugging a failing probe: keep the trees to inspect them.
  if (process.env.DHX_KEEP_FAKE_HOME === '1') return;
  for (const home of _fakeHomes.splice(0)) {
    try { fs.rmSync(home, { recursive: true, force: true }); } catch (_) { /* best effort */ }
  }
}

process.on('exit', _cleanupFakeHomes);
// 'exit' does NOT fire on a signal, and a probe interrupted mid-run is exactly
// when scratch is most likely to be abandoned. process.exit() re-enters the
// 'exit' handler above, so the removal itself stays in one place.
for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
  process.on(sig, () => process.exit(1));
}

function makeFakeHome(prefix) {
  if (typeof prefix !== 'string' || !prefix) prefix = 'dhx-fake-home-';
  const home = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  _fakeHomes.push(home);
  fs.mkdirSync(path.join(home, '.cache', 'dhx'), { recursive: true });
  fs.mkdirSync(path.join(home, '.claude', 'hooks'), { recursive: true });
  fs.symlinkSync(REAL_RENDERER, path.join(home, '.claude', 'hooks', 'dhx-statusline.js'));
  // A HEALTHY settings.json, because since 2026-09-15 the wrapper computes plugin_keys
  // from $CLAUDE_CONFIG_DIR/settings.json at render time instead of inheriting the value
  // in the shared health.json (which every lane's SessionStart overwrites — a close-gate
  // reviewer showed a healthy lane clearing a broken lane's warning through it).
  //
  // Without this the wrapper reads an absent settings.json as MISSING — correctly, that is
  // the fault the change exists to surface — and every fake home would carry a
  // `plugin-keys:MISSING` token no probe asked for. A fake home stands in for a WORKING
  // lane, so it gets working keys; a probe that wants the fault overwrites this file.
  // Extended here rather than per-probe, per this module's own stated contract.
  fs.writeFileSync(
    path.join(home, '.claude', 'settings.json'),
    JSON.stringify({
      enabledPlugins: { 'dhx@dhx-local': true },
      extraKnownMarketplaces: { 'dhx-local': { source: { source: 'directory', path: '/p' } } },
    }),
  );
  return home;
}

module.exports = { makeFakeHome, REAL_RENDERER };
