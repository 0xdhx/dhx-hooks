// Probe: confirm hashWarnSettings() ignores benign mutations, trips on WARN-set changes.
// Run: node tests/probes/probe-settings-hash.js
// SAFE_FOR_LIVE: yes   (reads `${CLAUDE_CONFIG_DIR}/settings.json` read-only for ONE
//                       differential cell; every fixture is written under an
//                       fs.mkdtempSync root and removed on exit — no live mutation,
//                       no predictable /tmp path)
//
// 2026-08-27 — de-pin + inertness repair. THREE defects, not one:
//
//   1. `const SRC = '/home/dhx/.ccs/shared/settings.json'` was an absolute literal
//      that ignored both $HOME and CLAUDE_CONFIG_DIR, so no fake-$HOME harness could
//      exercise it. It also encoded the CCS *layout* rather than the production
//      *lookup*: statusline-wrapper.js resolves
//      `fs.realpathSync(path.join(configDir, 'settings.json'))` with
//      `configDir = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude')`
//      (dhx/statusline-wrapper.js:686 and :1784). Reaching the same file by a
//      different route is not the same assertion.
//
//   2. The probe REIMPLEMENTED SETTINGS_WARN_KEYS / canonicalize / hashWarnSettings
//      instead of importing the exported production copy, so production could
//      regress while this file stayed green. Same shape as the 2026-08-19 §4g error
//      (a seam assumed absent that was exported all along) — see docs/decisions.md
//      § "statemd-phase-line lint — mirror the write ladder WHOLE".
//
//   3. LOAD-BEARING: `assert` only console.log'd. It never incremented a counter and
//      never set process.exitCode, and scripts/run-probes.sh:238 judges `.js` probes
//      by exit status alone (`*.js) timeout 30 node "$p" ;;`). EVERY assertion in
//      this file could fail while the suite reported it PASSED. A probe that cannot
//      fail is a photograph. Measured at repair time: all 5 legacy assertions did
//      pass, so adding the exit path reds nothing.
//
// The redirection proof (§B) is the point of the de-pin: it plants a scratch settings
// file behind a SYMLINK — mirroring the real CCS chain, so realpathSync is exercised
// rather than bypassed — and asserts the hash matches that file's content AND differs
// from the live one. "It resolved a path" is not proof it READ that path.

const fs = require('fs');
const os = require('os');
const path = require('path');

// Import the PRODUCTION implementation. statusline-wrapper.js is require-safe:
// its top-level runMain() is gated by `require.main === module` (line 31).
const { hashWarnSettings } = require('../../dhx/statusline-wrapper.js');

if (typeof hashWarnSettings !== 'function') {
  console.log('FAIL hashWarnSettings is not exported from dhx/statusline-wrapper.js');
  process.exit(1);
}

let PASS = 0;
let FAIL = 0;
const assert = (name, cond) => {
  if (cond) { PASS++; console.log(`OK   ${name}`); }
  else { FAIL++; console.log(`FAIL ${name}`); }
};

// Production's active-settings lookup, mirrored exactly (statusline-wrapper.js:1740+1784).
// Kept as a local mirror rather than imported because production inlines it at both
// call sites; if it is ever extracted, import it here instead.
function resolveActiveSettings(env = process.env, home = os.homedir()) {
  const configDir = env.CLAUDE_CONFIG_DIR || path.join(home, '.claude');
  return fs.realpathSync(path.join(configDir, 'settings.json'));
}

const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), 'probe-settings-hash-'));
process.on('exit', () => { try { fs.rmSync(ROOT, { recursive: true, force: true }); } catch {} });

const w = (p, obj) => { fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, JSON.stringify(obj, null, 2)); return p; };

// ---------------------------------------------------------------------------
// Section A — projection behaviour, on synthetic documents.
//
// The seed is now a minimal synthetic document rather than the operator's live
// settings: the projection contract is about WHICH KEYS survive, and importing the
// live file's schema made the assertion depend on content nobody controls.
// ---------------------------------------------------------------------------

const seed = {
  hooks: { SessionStart: [{ matcher: 'x', hooks: [{ type: 'command', command: 'echo a' }] }] },
  enabledPlugins: { 'dhx@dhx-marketplace': true },
  extraKnownMarketplaces: { 'dhx-marketplace': { source: { source: 'directory' } } },
  env: { SOME_VAR: '1' },
  effortLevel: 'high',
  permissions: { deny: ['Bash(git reset --hard*)'], allow: [] },
  statusLine: { type: 'command', command: 'x' },
};

const BASE = w(path.join(ROOT, 'a', 'base.json'), seed);

// Benign: mutate every IGNORE key. None may reach the hash.
const benign = JSON.parse(JSON.stringify(seed));
benign.effortLevel = 'xhigh';
benign.cleanupPeriodDays = 365;
benign.permissions.allow.push('Bash(rm *.tmp)');
benign.statusLine.refreshInterval = 999;
const BENIGN = w(path.join(ROOT, 'a', 'benign.json'), benign);

// Real WARN-set mutation: append a SessionStart matcher.
const real = JSON.parse(JSON.stringify(seed));
real.hooks.SessionStart.push({ matcher: 'test-probe', hooks: [{ type: 'command', command: 'echo probe' }] });
const REAL = w(path.join(ROOT, 'a', 'real.json'), real);

// Reorder: identical content, reversed top-level insertion order.
const reordered = {};
for (const k of Object.keys(seed).reverse()) reordered[k] = seed[k];
const REORDER = w(path.join(ROOT, 'a', 'reorder.json'), reordered);

// Nuked WARN keys.
const nuked = JSON.parse(JSON.stringify(seed));
delete nuked.hooks; delete nuked.enabledPlugins; delete nuked.extraKnownMarketplaces;
const NUKED = w(path.join(ROOT, 'a', 'nuked.json'), nuked);

const baseHash = hashWarnSettings(BASE);
assert('baseline hash is non-empty', baseHash !== '');
assert('benign mutation leaves hash unchanged', baseHash === hashWarnSettings(BENIGN));
assert('real wiring mutation changes hash', baseHash !== hashWarnSettings(REAL));
assert('top-level key reorder leaves hash unchanged', baseHash === hashWarnSettings(REORDER));
assert('nuked WARN keys produces distinct hash', baseHash !== hashWarnSettings(NUKED));
assert('missing file collapses to empty string', hashWarnSettings(path.join(ROOT, 'nope.json')) === '');

// A2 — per-key WARN-set membership. MEASURED GAP, closed 2026-08-27.
//
// The cells above prove only that `hooks` is in the WARN set: the "real mutation"
// fixture touches `hooks` and nothing else, and the benign fixture touches only
// IGNORE keys. Mutation-qualified during the de-pin — a copy of production with
// `env` DELETED from SETTINGS_WARN_KEYS scored 14/14 green against this file before
// this block existed. A key silently leaving the WARN set is precisely the drift the
// settings_hash detector is for, so a suite that cannot see it asserts less than it
// appears to. Each cell mutates exactly ONE WARN key, so each key is independently
// pinned and the failure names which one regressed.
const WARN_KEYS_UNDER_CONTRACT = ['hooks', 'enabledPlugins', 'extraKnownMarketplaces', 'env'];
for (const key of WARN_KEYS_UNDER_CONTRACT) {
  const only = JSON.parse(JSON.stringify(seed));
  // A structural change no other key can absorb, so the hash must move iff `key`
  // is projected. `_probe` is inert everywhere else in the document.
  only[key] = { ...(typeof only[key] === 'object' && only[key] !== null ? only[key] : {}), _probe_marker: key };
  const p = w(path.join(ROOT, 'a', `only-${key}.json`), only);
  assert(`WARN key '${key}' is projected — mutating it alone moves the hash`,
    baseHash !== hashWarnSettings(p));
}

// A3 — negative control for A2. An IGNORE key given the SAME structural mutation must
// NOT move the hash. Without this, A2 would also pass against a hash over the whole
// document, which projects nothing and discriminates nothing.
{
  const ignored = JSON.parse(JSON.stringify(seed));
  ignored.statusLine = { ...ignored.statusLine, _probe_marker: 'statusLine' };
  const p = w(path.join(ROOT, 'a', 'only-ignored.json'), ignored);
  assert("negative control — IGNORE key 'statusLine' given the same mutation does NOT move the hash",
    baseHash === hashWarnSettings(p));
}

// ---------------------------------------------------------------------------
// Section B — the redirection proof.
//
// Each cell plants a scratch settings.json behind a SYMLINK (the real CCS chain is
// ~/.claude/settings.json -> ~/.ccs/shared/settings.json, so a probe that plants a
// regular file never exercises realpathSync and would pass against a resolver that
// does not follow links). Then: resolve, hash, and require BOTH that the hash equals
// the scratch content's AND that it differs from the live one.
//
// The live-differential is what makes this a proof rather than a photograph. Without
// it, a resolver that ignored its arguments and read the operator's real file would
// still satisfy "returned a hash".
// ---------------------------------------------------------------------------

function plantRedirect(dirName, cfgDirName, marker) {
  const realFile = w(path.join(ROOT, dirName, 'shared', 'settings.json'), {
    ...seed,
    hooks: { SessionStart: [{ matcher: marker, hooks: [{ type: 'command', command: `echo ${marker}` }] }] },
  });
  const cfgDir = path.join(ROOT, dirName, cfgDirName);
  fs.mkdirSync(cfgDir, { recursive: true });
  fs.symlinkSync(realFile, path.join(cfgDir, 'settings.json'));
  return { realFile, cfgDir };
}

let liveHash = null;
try { liveHash = hashWarnSettings(resolveActiveSettings()); } catch { liveHash = null; }

// B1 — CLAUDE_CONFIG_DIR wins.
{
  const { realFile, cfgDir } = plantRedirect('b1', 'cfgdir', 'redirect-probe-ccd');
  const resolved = resolveActiveSettings({ CLAUDE_CONFIG_DIR: cfgDir }, '/nonexistent-home');
  assert('B1 CLAUDE_CONFIG_DIR resolves through the symlink to the scratch file',
    resolved === fs.realpathSync(realFile));
  const h = hashWarnSettings(resolved);
  assert('B1 hash matches the scratch file read directly', h === hashWarnSettings(realFile));
  assert('B1 hash DIFFERS from live — the live file was not what was read',
    liveHash === null || h !== liveHash);
}

// B2 — $HOME fallback when CLAUDE_CONFIG_DIR is absent.
{
  const { realFile, cfgDir } = plantRedirect('b2', '.claude', 'redirect-probe-home');
  const fakeHome = path.dirname(cfgDir);
  const resolved = resolveActiveSettings({}, fakeHome);
  assert('B2 $HOME fallback resolves to <home>/.claude/settings.json',
    resolved === fs.realpathSync(realFile));
  const h = hashWarnSettings(resolved);
  assert('B2 hash matches the scratch file read directly', h === hashWarnSettings(realFile));
  assert('B2 hash DIFFERS from live — the live file was not what was read',
    liveHash === null || h !== liveHash);
}

// B3 — negative control. The two redirect targets carry DIFFERENT markers inside the
// WARN set, so their hashes must differ from each other. If they matched, both cells
// would be reading some third thing and B1/B2 would be passing vacuously.
{
  const h1 = hashWarnSettings(fs.realpathSync(path.join(ROOT, 'b1', 'cfgdir', 'settings.json')));
  const h2 = hashWarnSettings(fs.realpathSync(path.join(ROOT, 'b2', '.claude', 'settings.json')));
  assert('B3 negative control — the two redirect targets hash differently', h1 !== h2);
}

// B4 — the production lookup is reachable on this machine at all. Read-only.
{
  let ok = false;
  try { ok = fs.existsSync(resolveActiveSettings()); } catch { ok = false; }
  assert('B4 production lookup resolves an existing file on this machine', ok);
}

console.log(`\n${PASS} passed, ${FAIL} failed`);
process.exit(FAIL === 0 ? 0 : 1);
