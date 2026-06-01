#!/usr/bin/env node
// cc-warning snooze — shared module + CLI.
//
// Single source of truth for the cc-warning snooze: the cache-file path, the
// JSON schema, the duration parser, and the snoozed/expired predicate. Both
// sides require() this module so they cannot drift (the D-02 single-classifier
// pattern used by scripts/lib/plugin-cache-allowlist.js):
//   - dhx/dhx-statusline.js     reads snoozeState() every refresh to suppress
//                               the cc version-drift cluster (⬆ cc, ⚠ cc dev
//                               install, ⚠ cc-autoupd). cc-novel is NOT in scope.
//   - .claude/commands/dhx/statusline.md  runs this file as a CLI to write/clear.
//
// State file: ~/.cache/dhx/cc-warning-snooze.json
//   { scope: "cc", until: <epoch-ms>|null, perma: <bool>, set_at: <ISO>, duration: <str> }
//
// Why a file, not an env var: the renderer runs as a child of `claude` and
// inherits its launch-time env (HP-012), so an env toggle would need a session
// restart. The file is re-read every refresh, so `snooze`/`clear` take effect on
// the next tick — the live-switch pattern shared with the ccburn-palette override.
//
// FAIL-OPEN on the render side (load-bearing): snoozeState() returns
// { active:false } on ANY error (absent/corrupt file, bad date). A snooze is an
// opt-OUT of a real signal, so a bug must never silently hide the warning — on
// doubt, show it. The renderer wraps the require in try/catch too (second line
// of defense). Probe: tests/probes/probe-cc-snooze.sh.

const fs = require('fs');
const path = require('path');
const os = require('os');

const SNOOZE_FILE = path.join(os.homedir(), '.cache', 'dhx', 'cc-warning-snooze.json');
const SCOPE = 'cc';

// Parse a duration token into { perma } or { ms }. Mirrors /dhx:watch snooze:
// `Xh` (hours), `Xd` (days), `perma`/`permanent`. Throws on anything else so the
// CLI can report a usage error; callers that must not throw guard their own call.
function parseDuration(str) {
  const s = String(str || '').trim().toLowerCase();
  if (s === 'perma' || s === 'permanent') return { perma: true };
  const m = s.match(/^(\d+)([hd])$/);
  if (!m) throw new Error(`invalid duration "${str}" — use Xh, Xd, or perma`);
  const n = parseInt(m[1], 10);
  if (!Number.isFinite(n) || n <= 0) throw new Error(`invalid duration "${str}" — must be > 0`);
  const unitMs = m[2] === 'h' ? 3600 * 1000 : 86400 * 1000;
  return { ms: n * unitMs };
}

// Read + validate the snooze file. Returns the parsed object for the matching
// scope, or null on absent/corrupt/scope-mismatch. Never throws.
function readSnooze(scope = SCOPE) {
  try {
    const obj = JSON.parse(fs.readFileSync(SNOOZE_FILE, 'utf8'));
    if (!obj || obj.scope !== scope) return null;
    return obj;
  } catch {
    return null;
  }
}

// The render-side predicate. Returns { active, perma, remainingMs }.
// active=false on ANY error (fail-open — see header). `now` injectable for probes.
function snoozeState(scope = SCOPE, now = Date.now()) {
  const obj = readSnooze(scope);
  if (!obj) return { active: false, perma: false, remainingMs: null };
  if (obj.perma === true) return { active: true, perma: true, remainingMs: null };
  const until = Number(obj.until);
  if (!Number.isFinite(until)) return { active: false, perma: false, remainingMs: null };
  const remainingMs = until - now;
  if (remainingMs <= 0) return { active: false, perma: false, remainingMs: null };
  return { active: true, perma: false, remainingMs };
}

// Compact "time remaining" for the dim countdown token. >=1d → "Nd", >=1h → "Nh",
// else "<1h". perma → "∞". Rounds UP so a snooze set for 7d reads "7d" not "6d"
// on the first refresh (and never shows "0d" while still active).
function formatRemaining(state) {
  if (!state || !state.active) return '';
  if (state.perma) return '∞';
  const ms = state.remainingMs;
  if (!Number.isFinite(ms) || ms <= 0) return '';
  const days = Math.ceil(ms / 86400000);
  if (ms >= 86400000) return `${days}d`;
  const hours = Math.ceil(ms / 3600000);
  if (ms >= 3600000) return `${hours}h`;
  return '<1h';
}

// Write the snooze file (atomic tmp+rename). `durationStr` is parsed here so an
// invalid value throws before any write. Returns the written object. `now`
// injectable for probes.
function writeSnooze(scope, durationStr, now = Date.now()) {
  const parsed = parseDuration(durationStr);
  const obj = {
    scope,
    until: parsed.perma ? null : now + parsed.ms,
    perma: !!parsed.perma,
    set_at: new Date(now).toISOString(),
    duration: String(durationStr).trim().toLowerCase(),
  };
  fs.mkdirSync(path.dirname(SNOOZE_FILE), { recursive: true });
  const tmp = `${SNOOZE_FILE}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(obj));
  fs.renameSync(tmp, SNOOZE_FILE);
  return obj;
}

// Remove the snooze file. Returns true if a file was removed, false if none
// existed. Never throws on ENOENT.
function clearSnooze() {
  try {
    fs.unlinkSync(SNOOZE_FILE);
    return true;
  } catch (e) {
    if (e && e.code === 'ENOENT') return false;
    throw e;
  }
}

module.exports = {
  SNOOZE_FILE,
  SCOPE,
  parseDuration,
  readSnooze,
  snoozeState,
  formatRemaining,
  writeSnooze,
  clearSnooze,
};

// --- CLI ---------------------------------------------------------------------
// Invoked by /dhx:statusline snooze ... (the command strips the leading
// `snooze` token and passes the rest here):
//   cc <Xh|Xd|perma>   snooze the cc version-drift cluster
//   cc clear | cc off  cancel an active snooze
//   status             show current snooze state
// Only the `cc` target exists today; other targets are rejected (exit 2) rather
// than silently accepted, leaving the door open for future scoped targets.
if (require.main === module) {
  const RESET = '\x1b[0m', DIM = '\x1b[2m', YEL = '\x1b[33m', GRN = '\x1b[32m', RED = '\x1b[31m';
  const argv = process.argv.slice(2);
  const target = (argv[0] || '').toLowerCase();
  const arg = (argv[1] || '').toLowerCase();

  function printStatus() {
    const st = snoozeState();
    if (!st.active) {
      console.log(`${DIM}cc warnings: not snoozed — ⬆ cc / ⚠ cc dev install / ⚠ cc-autoupd render normally.${RESET}`);
      return;
    }
    const obj = readSnooze();
    if (st.perma) {
      console.log(`${YEL}cc warnings snoozed permanently${RESET} ${DIM}(set ${obj && obj.set_at}). Clear with: /dhx:statusline snooze cc clear${RESET}`);
    } else {
      const until = new Date(Number(obj.until));
      console.log(`${YEL}cc warnings snoozed${RESET} — ${formatRemaining(st)} left, until ${until.toString().slice(0, 24)}. ${DIM}Clear: /dhx:statusline snooze cc clear${RESET}`);
    }
  }

  if (target === '' || target === 'status') {
    printStatus();
    process.exit(0);
  }

  if (target !== 'cc') {
    console.error(`${RED}Unknown snooze target "${argv[0]}". Only "cc" is supported.${RESET}`);
    console.error(`${DIM}Usage: /dhx:statusline snooze cc <Xh|Xd|perma> | snooze cc clear | snooze status${RESET}`);
    process.exit(2);
  }

  if (arg === 'clear' || arg === 'off') {
    const removed = clearSnooze();
    console.log(removed
      ? `${GRN}cc snooze cleared${RESET} — ⬆ cc / ⚠ cc dev install / ⚠ cc-autoupd will show again on the next refresh.`
      : `${DIM}cc was not snoozed — nothing to clear.${RESET}`);
    process.exit(0);
  }

  try {
    const obj = writeSnooze('cc', arg || argv[1] || '');
    const where = obj.perma ? 'permanently' : `for ${obj.duration}`;
    const until = obj.perma ? '' : ` ${DIM}(until ${new Date(obj.until).toString().slice(0, 24)})${RESET}`;
    console.log(`${YEL}cc warnings snoozed${RESET} ${where}${until}.`);
    console.log(`${DIM}Hidden while snoozed: ⬆ cc, ⚠ cc dev install, ⚠ cc-autoupd → collapsed to a dim "⚠ cc ${formatRemaining(snoozeState())}" countdown.${RESET}`);
    console.log(`${DIM}Still shown: ⚠ cc-novel (separate plugin-pattern detector). Auto-reverts to the bright warning when the snooze expires.${RESET}`);
    process.exit(0);
  } catch (e) {
    console.error(`${RED}${e.message}${RESET}`);
    console.error(`${DIM}Usage: /dhx:statusline snooze cc <Xh|Xd|perma> | snooze cc clear | snooze status${RESET}`);
    process.exit(2);
  }
}
