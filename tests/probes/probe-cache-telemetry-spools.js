// Probe: recordCacheTelemetry — cache-event + quota-snapshot spool writers
// (arc N7, manifest Item C as amended by the N5 review).
// Backs docs/decisions.md 2026-08-15 N7 bust-signal row and the accepted
// refinements f15/f29 (rows tagged {profile, session, resets_at}), f16 (log on
// main-chain advance, not only value change; suppress timer-only repeats),
// f28 (per-session spools + deterministic event IDs), f31/f61 (0600 files,
// 0700 dirs, rotation/retention bounds). Since 2026-09-16 also backs the
// P0-b row (docs/decisions.md 2026-09-16): additive event fields
// input/output/c1h/c5m/stop, snapshot rl_keys/rl_extra, raw float pct, and
// the 400-day retention default.
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

function rec(ts, req, mid, usage, diag, stop) {
  return JSON.stringify({
    type: 'assistant', isSidechain: false, timestamp: ts, requestId: req,
    uuid: `u-${req}-${mid}`, effort: 'medium', version: '2.1.233',
    message: { id: mid, model: 'claude-fable-5', stop_reason: stop || 'end_turn', usage, diagnostics: diag || null },
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

// --- 2026-09-16 additive fields (P0-b) ----------------------------------------
// Event row: usage fields the transcript carries — present → on the row.
fs.appendFileSync(tp, rec('2026-08-15T10:10:00.000Z', 'r3', 'm3', {
  input_tokens: 17, output_tokens: 4321, cache_read_input_tokens: 151000, cache_creation_input_tokens: 1200,
  cache_creation: { ephemeral_1h_input_tokens: 900, ephemeral_5m_input_tokens: 300 },
}, null, 'tool_use'));
tail = parseTranscriptTail(tp);
const RL_EXTRA = { five_hour: { used_percentage: 28.999999999999996, resets_at: 1765000000 },
  seven_day: { used_percentage: 12, resets_at: 1765400000 },
  seven_day_opus: { used_percentage: 3, resets_at: 1765400000 } };
recordCacheTelemetry({ session_id: SID, version: '2.1.273', rate_limits: RL_EXTRA }, tail);
const ev3 = readLines(evFile).map(JSON.parse).pop();
ok('event row carries input/output/c1h/c5m/stop from the transcript usage block',
  ev3.input === 17 && ev3.output === 4321 && ev3.c1h === 900 && ev3.c5m === 300 && ev3.stop === 'tool_use');
ok('event row keeps the legacy ttl_bucket alongside the raw split (additive)', ev3.ttl_bucket === '1h');
const sn3 = readLines(snapFile).map(JSON.parse).pop();
ok('snapshot row records every rate_limits key, sorted (rl_keys)',
  JSON.stringify(sn3.rl_keys) === JSON.stringify(['five_hour', 'seven_day', 'seven_day_opus']));
ok('snapshot row carries an unprojected rate_limits key raw (rl_extra)',
  sn3.rl_extra && sn3.rl_extra.seven_day_opus && sn3.rl_extra.seven_day_opus.used_percentage === 3);
ok('snapshot pct is stored AS RECEIVED (28.999999999999996 not rounded, not floored)',
  sn3.five_hour.pct === 28.999999999999996);
ok('schema version unchanged (v:1, additive only)', ev3.v === 1 && sn3.v === 1);
// Absent → row unchanged in shape: rl_keys lists only the two sides, no rl_extra key, usage fields default to 0/null.
fs.appendFileSync(tp, rec('2026-08-15T10:15:00.000Z', 'r4', 'm4', { cache_read_input_tokens: 152000, cache_creation_input_tokens: 0 }));
tail = parseTranscriptTail(tp);
recordCacheTelemetry(data, tail);
const ev4 = readLines(evFile).map(JSON.parse).pop();
const sn4 = readLines(snapFile).map(JSON.parse).pop();
ok('absent usage fields default to 0 / null, never undefined',
  ev4.input === 0 && ev4.output === 0 && ev4.c1h === 0 && ev4.c5m === 0 && ev4.stop === 'end_turn');
ok('with only the two known sides, rl_keys = [five_hour, seven_day] and rl_extra is absent',
  JSON.stringify(sn4.rl_keys) === JSON.stringify(['five_hour', 'seven_day']) && !('rl_extra' in sn4));

// --- retention sweep (default 400 days since 2026-09-16; was 30) -------------
const oldFile = path.join(TMP, 'cache-events', 'q-ancient.jsonl');
fs.writeFileSync(oldFile, '{"v":1}\n');
const old = (Date.now() - 500 * 86400_000) / 1000;
fs.utimesSync(oldFile, old, old);
const keepFile = path.join(TMP, 'cache-events', 'q-recent.jsonl');
fs.writeFileSync(keepFile, '{"v":1}\n');
const fortyDays = (Date.now() - 40 * 86400_000) / 1000;
fs.utimesSync(keepFile, fortyDays, fortyDays);
// Force the sweep window open by aging the state file's lastSweepMs.
const stateFile = path.join(TMP, 'cache-telemetry', `state-${SID}.json`);
const st = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
st.lastSweepMs = Date.now() - 2 * 86400_000;
st.lastEventKey = 'stale';           // let the next call advance
fs.writeFileSync(stateFile, JSON.stringify(st));
recordCacheTelemetry(data, tail);
ok('retention sweep removes >400d spool files', !fs.existsSync(oldFile));
ok('retention sweep KEEPS a 40-day-old spool file (the old 30-day default would have deleted it)', fs.existsSync(keepFile));

console.log(`${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
