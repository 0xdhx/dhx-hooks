#!/usr/bin/env node
// Exercises statusline-wrapper's readHealthCache() against fixture health.json
// files by spawning the wrapper with HOME pointed at a temp dir. Verifies:
//   - healthy cache → no warning
//   - each warning class → correct token + ` — /dhx:sym repair` suffix in its tier
//   - all-classes → one suffix per tier (critical + advisory), tokens split correctly
// Side-effects on real $HOME are zero — each spawn runs in an isolated tmpdir.
//
// Backs docs/decisions.md 2026-04-16 actionable-hints row + 2026-04-17 critical/
// advisory split row. sym-health.json precedence lives in
// probe-sym-health-override.js — this file stays scoped to warning-format contract.
// Run: node tests/probes/probe-health-suffix.js

// SAFE_FOR_LIVE: yes   (uses `_make-fake-home` (mktemp + HOME override per spawn); fully sandboxed)
const { spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const WRAPPER = path.resolve(__dirname, '..', '..', 'dhx', 'statusline-wrapper.js');
// Fake-$HOME setup centralized in _make-fake-home.js — see that module's
// header for the wrapper require-boundary rationale (2026-04-28 commit
// 30893e3 + same-day silent-red repair + centralization rows).
const { makeFakeHome } = require('./_make-fake-home');
const SUFFIX_REGEX = /— \/dhx:sym repair/g;

// Two fixtures now, because the cache was split by scope (2026-09-15).
// `healthJson`  -> ~/.cache/dhx/health.json           (machine-wide fields)
// `lane`        -> ~/.cache/dhx/health-lane-default.json (this lane's reading)
//
// The fake $HOME's CLAUDE_CONFIG_DIR is <tmp>/.claude, which the producer and
// consumer both resolve to the lane id `default`. The sidecar records the REALPATH
// of that dir, and the reader refuses a sidecar whose recorded config_dir is not
// this lane's — so the fixture must realpath too (on a host where /tmp is itself a
// symlink, writing the unresolved path would silently exercise the refusal branch
// on every case instead of the one case that means to).
//
// `lane: null` means NO sidecar — the state of a lane that has not started a session
// since the split. That renders `symlinks:?`, never silence: an absent reading
// presenting as a clean one is the failure this split exists to remove.
function runWith(healthJson, lane = { missing_symlinks: 0 }) {
  const tmp = makeFakeHome('dhx-probe-');
  try {
    const cacheDir = path.join(tmp, '.cache', 'dhx');
    if (healthJson !== null) {
      fs.writeFileSync(path.join(cacheDir, 'health.json'), healthJson);
    }
    if (lane !== null) {
      const configDir = path.join(tmp, '.claude');
      fs.writeFileSync(path.join(cacheDir, 'health-lane-default.json'), JSON.stringify({
        config_dir: lane.config_dir ?? fs.realpathSync(configDir),
        missing_symlinks: lane.missing_symlinks,
        checked: 0,
      }));
    }
    const res = spawnSync(process.execPath, [WRAPPER], {
      input: JSON.stringify({ session_id: 'probe-suffix', version: '2.1.112' }),
      env: { ...process.env, HOME: tmp, CLAUDE_CONFIG_DIR: path.join(tmp, '.claude') },
      encoding: 'utf8',
      timeout: 5000,
    });
    return res.stdout || '';
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

const cases = [
  { name: 'healthy (all ok)',
    cache: { worktree_patches: 'patched', read_guard: 'patched', settings_chain: 'ok', plugin_keys: 'ok', checked: 0 },
    expectSuffix: 0, expectTokens: [] },
  { name: 'plugin-keys MISSING',
    cache: { worktree_patches: 'patched', read_guard: 'patched', settings_chain: 'ok', plugin_keys: 'MISSING', checked: 0 },
    expectSuffix: 1, expectTokens: ['plugin-keys:MISSING'] },
  { name: 'settings chain REAL_FILE',
    cache: { worktree_patches: 'patched', read_guard: 'patched', settings_chain: 'REAL_FILE', plugin_keys: 'ok', checked: 0 },
    expectSuffix: 1, expectTokens: ['settings:REAL_FILE'] },
  { name: 'worktree patches REGRESSED',
    cache: { worktree_patches: 'REGRESSED', read_guard: 'patched', settings_chain: 'ok', plugin_keys: 'ok', checked: 0 },
    expectSuffix: 1, expectTokens: ['patches:REGRESSED'] },
  { name: 'read-guard REGRESSED',
    cache: { worktree_patches: 'patched', read_guard: 'REGRESSED', settings_chain: 'ok', plugin_keys: 'ok', checked: 0 },
    expectSuffix: 1, expectTokens: ['read-guard:REGRESSED'] },
  { name: "missing symlinks (2) — from THIS lane's sidecar",
    cache: { worktree_patches: 'patched', read_guard: 'patched', settings_chain: 'ok', plugin_keys: 'ok', checked: 0 },
    lane: { missing_symlinks: 2 },
    expectSuffix: 1, expectTokens: ['2 broken symlinks'] },
  { name: 'claude_md REAL_FILE (symlink replaced by regular file)',
    cache: { worktree_patches: 'patched', read_guard: 'patched', claude_md: 'REAL_FILE', settings_chain: 'ok', plugin_keys: 'ok', checked: 0 },
    expectSuffix: 1, expectTokens: ['CLAUDE.md unlinked'] },
  { name: 'claude_md WRONG_TARGET (symlink points elsewhere)',
    cache: { worktree_patches: 'patched', read_guard: 'patched', claude_md: 'WRONG_TARGET', settings_chain: 'ok', plugin_keys: 'ok', checked: 0 },
    expectSuffix: 1, expectTokens: ['CLAUDE.md mislinked'] },
  { name: 'claude_md MISSING (no file at all)',
    cache: { worktree_patches: 'patched', read_guard: 'patched', claude_md: 'MISSING', settings_chain: 'ok', plugin_keys: 'ok', checked: 0 },
    expectSuffix: 1, expectTokens: ['CLAUDE.md missing'] },
  { name: 'claude_md ok (intact symlink — stays silent)',
    cache: { worktree_patches: 'patched', read_guard: 'patched', claude_md: 'ok', settings_chain: 'ok', plugin_keys: 'ok', checked: 0 },
    expectSuffix: 0, expectTokens: [] },
  { name: 'all classes at once (front+tail — 2 suffixes, one per tier)',
    cache: { worktree_patches: 'REGRESSED', read_guard: 'REGRESSED', claude_md: 'REAL_FILE', settings_chain: 'WRONG_TARGET', plugin_keys: 'MISSING', checked: 0 },
    lane: { missing_symlinks: 3 },
    expectSuffix: 2, expectTokens: ['patches:REGRESSED', 'read-guard:REGRESSED', '3 broken symlinks', 'CLAUDE.md unlinked', 'settings:WRONG_TARGET', 'plugin-keys:MISSING'] },
  { name: 'legacy schema (no plugin_keys field)',
    cache: { worktree_patches: 'patched', read_guard: 'patched', settings_chain: 'ok', checked: 0 },
    expectSuffix: 0, expectTokens: [] },

  // --- lane scoping, render half (2026-09-15) ------------------------------------
  // Producer half + the cross-lane contract live in probe-health-lane-scoping.sh.
  // These pin what the OPERATOR sees, which is where the silent-zero would have
  // surfaced: each asserts the unknown token IS emitted, and where a wrong value was
  // reachable, that it is NOT. A `lane: null` fixture is the state of a lane that has
  // not started a session since the split — it must never render as a clean line.
  { name: 'no sidecar for this lane -> symlinks:? (never silence)',
    cache: { worktree_patches: 'patched', read_guard: 'patched', settings_chain: 'ok', plugin_keys: 'ok', checked: 0 },
    lane: null,
    expectSuffix: 1, expectTokens: ['symlinks:?'] },
  { name: 'sidecar stamped for a DIFFERENT config dir -> symlinks:?, count refused',
    cache: { worktree_patches: 'patched', read_guard: 'patched', settings_chain: 'ok', plugin_keys: 'ok', checked: 0 },
    lane: { missing_symlinks: 9, config_dir: '/nonexistent/some-other-lane' },
    expectSuffix: 1, expectTokens: ['symlinks:?'], rejectTokens: ['9 broken symlinks'] },
  { name: 'legacy top-level missing_symlinks does NOT leak into the render',
    cache: { worktree_patches: 'patched', read_guard: 'patched', missing_symlinks: 7, settings_chain: 'ok', plugin_keys: 'ok', checked: 0 },
    lane: null,
    expectSuffix: 1, expectTokens: ['symlinks:?'], rejectTokens: ['7 broken symlinks'] },

  { name: 'missing cache file (nothing has checked this lane)',
    raw: null, lane: null,
    expectSuffix: 1, expectTokens: ['symlinks:?'] },
];

let pass = 0, fail = 0;
for (const c of cases) {
  const cacheStr = c.raw === null ? null : JSON.stringify(c.cache);
  // `'lane' in c` not `c.lane ??` — a case declaring `lane: null` means NO sidecar
  // and must not silently fall back to the healthy default, which is exactly how the
  // unknown-render cases would rot into re-asserting the clean path.
  const lane = 'lane' in c ? c.lane : { missing_symlinks: 0 };
  const out = runWith(cacheStr, lane);
  const suffixes = (out.match(SUFFIX_REGEX) || []).length;
  const tokensOk = c.expectTokens.every(t => out.includes(t));
  const rejectOk = (c.rejectTokens || []).every(t => !out.includes(t));
  const ok = suffixes === c.expectSuffix && tokensOk && rejectOk;
  if (ok) {
    console.log(`  \u2713 ${c.name} (suffixes=${suffixes}, tokens match)`);
    pass++;
  } else {
    console.log(`  \u2717 ${c.name}`);
    console.log(`      expected suffix count: ${c.expectSuffix}, got: ${suffixes}`);
    console.log(`      expected tokens: ${JSON.stringify(c.expectTokens)}`);
    if (c.rejectTokens) console.log(`      must NOT contain: ${JSON.stringify(c.rejectTokens)}`);
    console.log(`      output: ${JSON.stringify(out)}`);
    fail++;
  }
}

console.log('---');
console.log(`PASS: ${pass}  FAIL: ${fail}`);
process.exit(fail);
