// Probe: confirm hashWarnSettings() ignores benign mutations, trips on WARN-set changes.
// Run: node tests/probes/probe-settings-hash.js
// SAFE_FOR_LIVE: yes   (reads `~/.ccs/shared/settings.json` read-only as seed; writes only to `/tmp/probe-settings-*.json` fixtures (predictable paths, no live mutation))
const crypto = require('crypto');
const fs = require('fs');

const SETTINGS_WARN_KEYS = ['hooks', 'enabledPlugins', 'extraKnownMarketplaces', 'env'];

function canonicalize(value) {
  if (value === null || typeof value !== 'object') return value;
  if (Array.isArray(value)) return value.map(canonicalize);
  const out = {};
  for (const key of Object.keys(value).sort()) out[key] = canonicalize(value[key]);
  return out;
}

function hashWarnSettings(path) {
  try {
    const parsed = JSON.parse(fs.readFileSync(path, 'utf8'));
    const projection = {};
    for (const key of SETTINGS_WARN_KEYS) {
      if (key in parsed) projection[key] = parsed[key];
    }
    return crypto.createHash('sha256').update(JSON.stringify(canonicalize(projection))).digest('hex');
  } catch { return ''; }
}

const SRC = '/home/dhx/.ccs/shared/settings.json';
const BASE = '/tmp/probe-settings-base.json';
const BENIGN = '/tmp/probe-settings-benign.json';
const REAL = '/tmp/probe-settings-real.json';
const INSERT_ORDER = '/tmp/probe-settings-reorder.json';
const NUKED = '/tmp/probe-settings-empty.json';

// Pristine baseline
const raw = fs.readFileSync(SRC, 'utf8');
fs.writeFileSync(BASE, raw);

// Benign: change effortLevel + add new cleanupPeriodDays + bump mtime via re-write.
// Also mutate a top-level IGNORE key to be sure none of them leak into the hash.
const benign = JSON.parse(raw);
benign.effortLevel = 'xhigh';
benign.cleanupPeriodDays = 365;
benign.permissions = { ...(benign.permissions || {}), allow: [...((benign.permissions || {}).allow || []), 'Bash(rm *.tmp)'] };
benign.statusLine = { ...benign.statusLine, refreshInterval: 999 };
fs.writeFileSync(BENIGN, JSON.stringify(benign, null, 2));

// Real WARN-set mutation: tweak .hooks (append a new SessionStart matcher entry)
const real = JSON.parse(raw);
real.hooks = real.hooks || {};
real.hooks.SessionStart = real.hooks.SessionStart || [];
real.hooks.SessionStart.push({ matcher: 'test-probe', hooks: [{ type: 'command', command: 'echo probe' }] });
fs.writeFileSync(REAL, JSON.stringify(real, null, 2));

// Reorder: same content, different insertion order of top-level keys. Hash must be stable.
const reorderedTop = {};
for (const key of Object.keys(JSON.parse(raw)).reverse()) {
  reorderedTop[key] = JSON.parse(raw)[key];
}
fs.writeFileSync(INSERT_ORDER, JSON.stringify(reorderedTop, null, 2));

// Fully nuked WARN keys: confirm empty projection produces deterministic hash
const nuked = JSON.parse(raw);
delete nuked.hooks;
delete nuked.enabledPlugins;
delete nuked.extraKnownMarketplaces;
fs.writeFileSync(NUKED, JSON.stringify(nuked, null, 2));

const baseHash = hashWarnSettings(BASE);
const benignHash = hashWarnSettings(BENIGN);
const realHash = hashWarnSettings(REAL);
const reorderHash = hashWarnSettings(INSERT_ORDER);
const nukedHash = hashWarnSettings(NUKED);
const missingHash = hashWarnSettings('/nonexistent/settings.json');

console.log(`baseline:  ${baseHash}`);
console.log(`benign:    ${benignHash}  (effort, cleanupPeriodDays, permissions, statusLine all mutated)`);
console.log(`real:      ${realHash}  (new SessionStart hook appended)`);
console.log(`reorder:   ${reorderHash}  (top-level keys reversed, content identical)`);
console.log(`nuked:     ${nukedHash}  (hooks+enabledPlugins+extraKnownMarketplaces removed)`);
console.log(`missing:   ${missingHash}  (unreadable path — expect empty string)`);

const assert = (name, cond) => console.log(`${cond ? 'OK  ' : 'FAIL'} ${name}`);
assert('benign mutation leaves hash unchanged', baseHash === benignHash);
assert('real wiring mutation changes hash', baseHash !== realHash);
assert('top-level key reorder leaves hash unchanged', baseHash === reorderHash);
assert('nuked WARN keys produces distinct hash', baseHash !== nukedHash);
assert('missing file collapses to empty string', missingHash === '');
