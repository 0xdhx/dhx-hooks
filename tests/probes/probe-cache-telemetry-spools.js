// Probe: recordCacheTelemetry — cache-event + quota-snapshot spool writers
// (arc N7, manifest Item C as amended by the N5 review).
// refinements f15/f29 (rows tagged {profile, session, resets_at}), f16 (log on
// main-chain advance, not only value change; suppress timer-only repeats),
// f28 (per-session spools + deterministic event IDs), f31/f61 (0600 files,
// 0700 dirs, rotation/retention bounds). Since 2026-09-16 also backs the
// P0-b row (docs/decisions.md 2026-09-16): additive event fields
// input/output/c1h/c5m/stop, snapshot rl_keys/rl_extra, raw float pct, and
// the 400-day retention default.
//
// Since 2026-09-18 also backs the SPOOL_SWEEP_DIRS ownership-table row
// (docs/decisions.md 2026-09-18): scenario [S] below derives its retention
// coverage FROM the exported table instead of naming the directories its
// author remembered. The arms above it did the latter, and that is why the
// cache-telemetry call site could be dead from 2026-08-15 to 2026-09-18 while
// this probe stayed green — both its retention assertions used .jsonl fixtures
// in cache-events, and it even WROTE state-${SID}.json into the unreachable
// directory without ever asserting that file was reachable.
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

// Session ids are uuid-shaped in production — verified 2026-09-17 by two
// independent routes over the live cache: 1560/1560 in cache-telemetry
// (`state-<sid>.json`) and 1477/1477 in cache-events (`<profile>-<sid>.jsonl`).
// The fixture was `probe-sess-1234` until 2026-09-18; that shape does not occur
// in production and made [S7] read the sweep as broken when it was the fixture
// that was wrong.
const SID = 'f47ac10b-58cc-4372-a567-0e02b2c3d479';
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

// --- [S] SPOOL_SWEEP_DIRS ownership table (2026-09-18) -----------------------
// The arms above enumerate; these derive. Adding a fourth row to the table
// extends [S1] automatically, and a fourth row whose name shape no generator
// below produces FAILS [S0] rather than being silently skipped.
// Degrade to a FAIL line, never a throw. A crashed harness emits NO FAIL lines
// at all, which reads exactly like a clean run — the 2026-09-17 drift-debug row
// records that shape costing a whole mutant round. So a missing export is an
// assertion here, not an exception three lines later.
const SPOOL_SWEEP_DIRS = Array.isArray(wrapper.SPOOL_SWEEP_DIRS) ? wrapper.SPOOL_SWEEP_DIRS : [];
const sweepSpoolDir = typeof wrapper.sweepSpoolDir === 'function' ? wrapper.sweepSpoolDir : null;
const { TELEMETRY_RETENTION_DAYS, TELEMETRY_STATE_RETENTION_DAYS } = wrapper;
ok('[S-pre] wrapper exports a non-empty SPOOL_SWEEP_DIRS table', SPOOL_SWEEP_DIRS.length > 0);
ok('[S-pre] wrapper exports sweepSpoolDir', sweepSpoolDir !== null);

// [S7] THE load-bearing arm: each row's predicate must ACCEPT the names the
// WRITER actually produced in that directory. Runs BEFORE anything is seeded,
// so every name it sees came from the code under test rather than from this
// file. That ordering is the whole point — [S1] below seeds a fixture chosen by
// `ownedName`, which picks a name the row's own regex accepts, so [S1] tests the
// row against itself and a predicate pointed at the wrong directory survives it.
// Measured 2026-09-17, this is the defect stated as an assertion: the shipped
// shared `.jsonl` test reached 1476/1476 in cache-events, 100/100 in
// quota-snapshots and 0 of 1559 in cache-telemetry. An empty directory FAILS
// rather than passing vacuously.
for (const row of SPOOL_SWEEP_DIRS) {
  let produced = [];
  try { produced = fs.readdirSync(path.join(TMP, row.dir)); } catch { produced = []; }
  const reach = produced.filter((n) => row.match.test(n));
  if (produced.length && reach.length !== produced.length) {
    console.log(`     unreachable: ${produced.filter((n) => !row.match.test(n)).join(', ')}`);
  }
  ok(`[S7] ${row.dir}: predicate reaches every file the writer produced `
     + `(${reach.length} of ${produced.length})`,
     produced.length > 0 && reach.length === produced.length);
}

const U_OLD = '11111111-2222-3333-4444-555555555555';
const U_NEW = '66666666-7777-8888-9999-aaaaaaaaaaaa';
// Name shapes the live directories actually use. A row matching NONE of these
// is a row this probe cannot seed — [S0] fails closed on it.
const NAME_SHAPES = [(u) => `q-${u}.jsonl`, (u) => `state-${u}.json`];
const ownedName = (row, u) => NAME_SHAPES.map((f) => f(u)).find((n) => row.match.test(n)) || null;

const seeded = [];
const unnamed = [];
for (const row of SPOOL_SWEEP_DIRS) {
  const oldN = ownedName(row, U_OLD), newN = ownedName(row, U_NEW);
  if (!oldN || !newN) { unnamed.push(row.dir); continue; }
  const d = path.join(TMP, row.dir);
  fs.mkdirSync(d, { recursive: true, mode: 0o700 });
  const oldP = path.join(d, oldN), newP = path.join(d, newN);
  const keepDays = Math.max(1, row.days - 10);
  fs.writeFileSync(oldP, '{"v":1}\n'); fs.writeFileSync(newP, '{"v":1}\n');
  const oldT = (Date.now() - (row.days + 40) * 86400_000) / 1000;
  const newT = (Date.now() - keepDays * 86400_000) / 1000;
  fs.utimesSync(oldP, oldT, oldT); fs.utimesSync(newP, newT, newT);
  seeded.push({ dir: row.dir, days: row.days, keepDays, oldP, newP });
}
if (unnamed.length) console.log(`     rows with no fixture shape: ${unnamed.join(', ')}`);
ok('[S0] every SPOOL_SWEEP_DIRS row can be seeded (fail-closed on a new row)', unnamed.length === 0);

// Re-open the daily gate and let the REAL call site drive the REAL table.
const st2 = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
st2.lastSweepMs = Date.now() - 2 * 86400_000;
st2.lastEventKey = 'stale-table';
fs.writeFileSync(stateFile, JSON.stringify(st2));
recordCacheTelemetry(data, tail);

for (const s of seeded) {
  ok(`[S1] ${s.dir}: prunes a file ${s.days + 40}d old (window ${s.days}d)`, !fs.existsSync(s.oldP));
  ok(`[S1] ${s.dir}: keeps a file ${s.keepDays}d old`, fs.existsSync(s.newP));
}

// [S6] Every directory the writer actually creates must carry a sweep row.
// Derived from BEHAVIOUR, not from the table — which is the point. [S1] takes
// its coverage from the table, so deleting a row deletes that row's coverage
// along with it and nothing goes red; and a fourth write destination added with
// no retention at all is invisible to every arm above. This one reds on both.
const writtenDirs = fs.readdirSync(TMP, { withFileTypes: true })
  .filter((d) => d.isDirectory()).map((d) => d.name).sort();
const coveredDirs = new Set(SPOOL_SWEEP_DIRS.map((r) => r.dir));
const uncoveredDirs = writtenDirs.filter((d) => !coveredDirs.has(d));
if (uncoveredDirs.length) console.log(`     written but never swept: ${uncoveredDirs.join(', ')}`);
ok(`[S6] every directory the writer creates has a sweep row (saw ${writtenDirs.join(', ') || 'none'})`,
   writtenDirs.length > 0 && uncoveredDirs.length === 0);

// [S8] The residual, asserted rather than left in a comment. The
// cache-telemetry pattern is anchored on a uuid, so a session id of any other
// shape leaves a state file this sweep can never reach. That is the deliberate
// trade and its direction is RETAIN: the alternative — matching the writer's
// own contract, `state-<anything-without-a-separator>.json` — necessarily
// claims `state-summary.json` too, because `summary` is a valid session id.
// Both hazards are empty today; only this one fails toward keeping data.
// Pinning it here means a future loosening reds HERE and has to confront [S3b]
// in the same breath, instead of trading one silently for the other.
const oddSid = path.join(TMP, 'cache-telemetry', 'state-not-a-uuid.json');
fs.writeFileSync(oddSid, '{"v":1}\n');
const oddT = (Date.now() - 900 * 86400_000) / 1000;
fs.utimesSync(oddSid, oddT, oddT);
for (const row of SPOOL_SWEEP_DIRS) {
  sweepSpoolDir(path.join(TMP, row.dir), Date.now() - row.days * 86400_000, row.match);
}
ok('[S8] a non-uuid session id leaves an unreachable state file (fails toward RETAIN)',
   fs.existsSync(oddSid));
try { fs.unlinkSync(oddSid); } catch { /* a loosened pattern already swept it — [S8] said so */ }

// [S2] The table is the ONLY driver. Comments stripped, the wrapper must carry
// exactly one `sweepSpoolDir(` declaration plus one call — a direct call added
// beside the loop would sweep a directory under a predicate it never declared.
const wrapperSrc = fs.readFileSync(path.join(__dirname, '..', '..', 'dhx', 'statusline-wrapper.js'), 'utf8');
const codeOnly = wrapperSrc.split('\n').filter((l) => !/^\s*\/\//.test(l)).join('\n');
const callSites = (codeOnly.match(/sweepSpoolDir\(/g) || []).length;
ok(`[S2] SPOOL_SWEEP_DIRS is the only driver (1 decl + 1 call, saw ${callSites})`, callSites === 2);

// [S3a] End-anchoring, asserted as a PROPERTY over every row rather than a list
// of file classes. An unanchored suffix deletes `x.jsonl.bak`; the 2026-09-17
// drift-debug row records an unanchored /\.log/ passing every other assertion
// in its scenario ([19e2]) because no bystander in its hardcoded list happened
// to carry a non-terminal `.log`. A property cannot go stale that way.
let tailLeaks = [];
for (const row of SPOOL_SWEEP_DIRS) {
  const base = ownedName(row, U_OLD);
  if (!base) continue;
  for (const t of ['.bak', '.1', '.tmp', '~', '.swp']) {
    if (row.match.test(base + t)) tailLeaks.push(`${row.dir}:${base}${t}`);
  }
}
if (tailLeaks.length) console.log(`     unanchored matches: ${tailLeaks.join(', ')}`);
ok('[S3a] no row matches an owned name plus a trailing suffix (end-anchored)', tailLeaks.length === 0);

// [S3b] `state-summary.json` is the concrete file class a bare `.json` widening
// or a loose `state-` prefix would claim. No row may reach it, at any age.
const summaryClaimers = SPOOL_SWEEP_DIRS.filter((r) => r.match.test('state-summary.json')).map((r) => r.dir);
if (summaryClaimers.length) console.log(`     state-summary.json claimed by: ${summaryClaimers.join(', ')}`);
ok('[S3b] no row claims state-summary.json', summaryClaimers.length === 0);

// [S4] Windows are per-row, not one shared cutoff. Behavioural, and derived:
// age a file owned by the NARROWEST row to the midpoint between the narrowest
// and widest windows. It must be swept under its own window and would survive
// if every row inherited the widest one.
const minRow = SPOOL_SWEEP_DIRS.length
  ? SPOOL_SWEEP_DIRS.reduce((a, b) => (b.days < a.days ? b : a))
  : { dir: '.', days: 0, match: /$^/ };
const maxDays = SPOOL_SWEEP_DIRS.length ? Math.max(...SPOOL_SWEEP_DIRS.map((r) => r.days)) : 0;
ok('[S4a] at least two distinct retention windows exist across the table', minRow.days < maxDays);
const midDays = Math.floor((minRow.days + maxDays) / 2);
const midName = ownedName(minRow, '99999999-8888-7777-6666-555555555555') || 'unseedable';
const midP = path.join(TMP, minRow.dir, midName);
fs.writeFileSync(midP, '{"v":1}\n');
const midT = (Date.now() - midDays * 86400_000) / 1000;
fs.utimesSync(midP, midT, midT);
sweepSpoolDir(path.join(TMP, minRow.dir), Date.now() - minRow.days * 86400_000, minRow.match);
ok(`[S4b] ${minRow.dir}: a ${midDays}d file is swept under its own ${minRow.days}d window `
   + `(it would survive the ${maxDays}d one)`, !fs.existsSync(midP));

// [S5] The state-file window is a distinct constant, not an alias. Guards the
// one-line "reuse TELEMETRY_RETENTION_DAYS" regression that [S4] would miss if
// someone set both constants to the same number.
ok('[S5] TELEMETRY_STATE_RETENTION_DAYS is separate from the 400-day spool window',
   TELEMETRY_STATE_RETENTION_DAYS !== TELEMETRY_RETENTION_DAYS && TELEMETRY_STATE_RETENTION_DAYS > 0);

console.log(`${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
