// Probe: recordCacheTelemetry — cache-event + quota-snapshot spool writers
// (arc N7, manifest Item C as amended by the N5 review).
// Backs docs/decisions.md 2026-08-15 N7 bust-signal row and the accepted
// refinements f15/f29 (rows tagged {profile, session, resets_at}), f16 (log on
// main-chain advance, not only value change; suppress timer-only repeats),
// f28 (per-session spools + deterministic event IDs), f31/f61 (0600 files,
// 0700 dirs, rotation/retention bounds).
// Run: node tests/probes/probe-cache-telemetry-spools.js

// SAFE_FOR_LIVE: yes   (all writes under a mkdtemp dir via DHX_CACHE_TELEMETRY_DIR override; never touches live ~/.cache/dhx)
const fs = require('fs');
const path = require('path');
const os = require('os');

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'probe-cache-telemetry-'));
process.env.DHX_CACHE_TELEMETRY_DIR = TMP;
process.env.CLAUDE_CONFIG_DIR = '/home/probe/.ccs/instances/q'; // profile letter q

const wrapper = require(path.join(__dirname, '..', '..', 'dhx', 'statusline-wrapper.js'));
const { parseTranscriptTail, recordCacheTelemetry, telemetryProfileLetter } = wrapper;

process.on('exit', () => { try { fs.rmSync(TMP, { recursive: true, force: true }); } catch { /* nothing */ } });

let pass = 0, fail = 0;
function ok(name, cond) {
  if (cond) { console.log(`OK   ${name}`); pass++; }
  else { console.log(`FAIL ${name}`); fail++; }
}

function rec(ts, req, mid, usage, diag) {
  return JSON.stringify({
    type: 'assistant', isSidechain: false, timestamp: ts, requestId: req,
    uuid: `u-${req}-${mid}`, effort: 'medium', version: '2.1.233',
    message: { id: mid, model: 'claude-fable-5', stop_reason: 'end_turn', usage, diagnostics: diag || null },
  }) + '\n';
}
const warm = (r) => ({ input_tokens: 5, cache_read_input_tokens: r, cache_creation_input_tokens: 900,
  cache_creation: { ephemeral_1h_input_tokens: 900, ephemeral_5m_input_tokens: 0 } });

const tp = path.join(TMP, 't.jsonl');
fs.writeFileSync(tp, rec('2026-08-15T10:00:00.000Z', 'r1', 'm1', warm(150000)));
let tail = parseTranscriptTail(tp);

const SID = 'probe-sess-1234';
const RL = { five_hour: { used_percentage: 42, resets_at: 1765000000 }, seven_day: { used_percentage: 12, resets_at: 1765400000 } };
const data = { session_id: SID, version: '2.1.233', rate_limits: RL };

ok('profile letter derived from CLAUDE_CONFIG_DIR', telemetryProfileLetter() === 'q');

// --- advance gating (f16) ----------------------------------------------------
recordCacheTelemetry(data, tail);
recordCacheTelemetry(data, tail);   // timer-only repeat: same newest key
const evFile = path.join(TMP, 'cache-events', `q-${SID}.jsonl`);
const readLines = (p) => fs.readFileSync(p, 'utf8').trim().split('\n').filter(Boolean);
ok('one event row after two refreshes of the same call (timer repeat suppressed)',
  readLines(evFile).length === 1);

const snapDir = path.join(TMP, 'quota-snapshots');
const snapFile = path.join(snapDir, fs.readdirSync(snapDir)[0]);
ok('one snapshot row after two refreshes', readLines(snapFile).length === 1);

// Main-chain advance with UNCHANGED utilization still writes (f16).
fs.appendFileSync(tp, rec('2026-08-15T10:05:00.000Z', 'r2', 'm2', warm(151000)));
tail = parseTranscriptTail(tp);
recordCacheTelemetry(data, tail);   // same RL values, new call
ok('advance with unchanged utilization writes a snapshot row (f16)',
  readLines(snapFile).length === 2);
ok('advance writes a second event row', readLines(evFile).length === 2);

// --- row content -------------------------------------------------------------
const rows = readLines(evFile).map(JSON.parse);
ok('deterministic event id = session:requestId:messageId',
  rows[1].id === `${SID}:r2:m2`);
ok('event row carries schema v, profile, class, ttl_bucket',
  rows[1].v === 1 && rows[1].profile === 'q' && rows[1].class === 'WARM' && rows[1].ttl_bucket === '1h');
const snaps = readLines(snapFile).map(JSON.parse);
ok('snapshot row tagged {profile, session, resets_at} (f15/f29)',
  snaps[1].profile === 'q' && snaps[1].session === SID &&
  snaps[1].five_hour.resets_at === 1765000000 && snaps[1].seven_day.resets_at === 1765400000);
ok('snapshot row keyed to the advancing event', snaps[1].event_key === 'r2:m2');

// --- permissions (f31/f61) ---------------------------------------------------
ok('event spool mode 0600', (fs.statSync(evFile).mode & 0o777) === 0o600);
ok('snapshot spool mode 0600', (fs.statSync(snapFile).mode & 0o777) === 0o600);
ok('spool dir mode 0700', (fs.statSync(path.join(TMP, 'cache-events')).mode & 0o777) === 0o700);

// --- guards ------------------------------------------------------------------
recordCacheTelemetry({ session_id: '../evil', rate_limits: RL }, tail);
ok('path-escaping session_id refused',
  !fs.existsSync(path.join(TMP, 'cache-events', 'q-..' )) &&
  readLines(evFile).length === 2);
recordCacheTelemetry({ rate_limits: RL }, tail);
ok('absent session_id is a no-op', readLines(evFile).length === 2);
recordCacheTelemetry(data, null);
ok('null tail is a no-op', readLines(evFile).length === 2);

// --- retention sweep ---------------------------------------------------------
const oldFile = path.join(TMP, 'cache-events', 'q-ancient.jsonl');
fs.writeFileSync(oldFile, '{"v":1}\n');
const old = (Date.now() - 40 * 86400_000) / 1000;
fs.utimesSync(oldFile, old, old);
const keepFile = path.join(TMP, 'cache-events', 'q-recent.jsonl');
fs.writeFileSync(keepFile, '{"v":1}\n');
// Force the sweep window open by aging the state file's lastSweepMs.
const stateFile = path.join(TMP, 'cache-telemetry', `state-${SID}.json`);
const st = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
st.lastSweepMs = Date.now() - 2 * 86400_000;
st.lastEventKey = 'stale';           // let the next call advance
fs.writeFileSync(stateFile, JSON.stringify(st));
recordCacheTelemetry(data, tail);
ok('retention sweep removes >30d spool files', !fs.existsSync(oldFile));
ok('retention sweep keeps recent spool files', fs.existsSync(keepFile));

console.log(`${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
