// Probe: per-segment self-diagnosis sigil + JSONL log + rotation.
//
// Backs: docs/decisions.md 2026-04-26 statusline self-diag row.
//
// Invariants exercised:
//   1. withSegmentDiag(name, promise) returns {value, error, segmentName} for both success and rejection.
//   2. appendStatuslineError appends one JSON line per call to ~/.cache/dhx/statusline-errors.jsonl.
//   3. Log rotates to .prev when size + new line > 1MB (mirror of appendTrace pattern).
//   4. Log writer failure (mocked fs.appendFile throw) MUST NOT throw out of appendStatuslineError —
//      the outer try/catch swallows everything so the render path never blocks.
//   5. Clean path: appendStatuslineError is never called when no segment errored — log file stays
//      byte-equal to its pre-state (or stays absent).
//   6. Sigil format is exact: \x1b[31m⚠ <segmentName>?\x1b[0m (red ANSI + alarm + name + ?).
//
// Not exercised here: the full runMain Promise.all integration under live stdin (covered by the
// non-regression run of probe-statusline-wrapper.js which still exits 0 with the wrapping in place).
//
// How to run:
//   node tests/probes/probe-statusline-self-diag.js

// SAFE_FOR_LIVE: yes   (mktemp HOME + `process.env.HOME` override per subtest; appendFile lands under temp HOME only)
const fs = require('fs');
const os = require('os');
const path = require('path');

let pass = 0;
let fail = 0;

function ok(label, got, want) {
  if (got === want) { console.log(`OK   ${label}`); pass++; }
  else { console.log(`FAIL ${label}\n  got:  ${JSON.stringify(got)}\n  want: ${JSON.stringify(want)}`); fail++; }
}

function okTruthy(label, got) {
  if (got) { console.log(`OK   ${label}`); pass++; }
  else { console.log(`FAIL ${label}\n  got:  ${JSON.stringify(got)} (expected truthy)`); fail++; }
}

// Each subtest gets a fresh temp HOME so the wrapper's module-scope STATUSLINE_ERROR_FILE
// path resolves to an isolated file per scenario. delete require.cache so the wrapper
// re-evaluates with the new HOME.
const WRAPPER_PATH = path.join(__dirname, '..', '..', 'dhx', 'statusline-wrapper.js');

function freshWrapper(homeDir) {
  process.env.HOME = homeDir;
  delete require.cache[require.resolve(WRAPPER_PATH)];
  // Also delete the realpath form in case node resolved differently.
  const real = fs.realpathSync(WRAPPER_PATH);
  delete require.cache[real];
  return require(WRAPPER_PATH);
}

// Fake-$HOME setup centralized in _make-fake-home.js — see that module's
// header for the wrapper require-boundary rationale (2026-04-28 commit
// 30893e3 + same-day silent-red repair + centralization rows).
const { makeFakeHome } = require('./_make-fake-home');

function makeHome(name) {
  return makeFakeHome(`selfdiag-${name}-`);
}

function logPath(home) {
  return path.join(home, '.cache', 'dhx', 'statusline-errors.jsonl');
}

function readLines(file) {
  if (!fs.existsSync(file)) return [];
  const txt = fs.readFileSync(file, 'utf8');
  return txt.split('\n').filter(Boolean);
}

// --- § 1 withSegmentDiag shape ---------------------------------------------

(async () => {
  const home = makeHome('shape');
  const w = freshWrapper(home);
  okTruthy('export: withSegmentDiag is a function', typeof w.withSegmentDiag === 'function');
  okTruthy('export: appendStatuslineError is a function', typeof w.appendStatuslineError === 'function');

  const goodResult = await w.withSegmentDiag('renderer', Promise.resolve('hello'));
  ok('withSegmentDiag: success value passes through',  goodResult.value, 'hello');
  ok('withSegmentDiag: success error is null',         goodResult.error, null);
  ok('withSegmentDiag: success segmentName preserved', goodResult.segmentName, 'renderer');

  const badResult = await w.withSegmentDiag('git', Promise.reject(new Error('boom')));
  ok('withSegmentDiag: error value is null',           badResult.value, null);
  okTruthy('withSegmentDiag: error captured',          badResult.error && badResult.error.message === 'boom');
  ok('withSegmentDiag: error segmentName preserved',   badResult.segmentName, 'git');

  // --- § 2 appendStatuslineError happy path ---------------------------------
  const home2 = makeHome('append');
  const w2 = freshWrapper(home2);
  w2.appendStatuslineError({
    ts: '2026-04-26T00:00:00Z',
    segment: 'health',
    error_message: 'simulated parse failure',
    error_stack_first_line: 'Error: simulated parse failure',
    cwd: '/tmp/probe',
  });
  // appendFile is async fire-and-forget; give it a tick to flush.
  await new Promise(r => setTimeout(r, 50));
  const lines = readLines(logPath(home2));
  ok('appendStatuslineError: one line written', lines.length, 1);
  let parsed = null;
  try { parsed = JSON.parse(lines[0]); } catch { /* leave null */ }
  okTruthy('appendStatuslineError: line is valid JSON', parsed !== null);
  if (parsed) {
    ok('appendStatuslineError: segment field round-trips', parsed.segment, 'health');
    ok('appendStatuslineError: error_message round-trips', parsed.error_message, 'simulated parse failure');
  }

  // --- § 3 multiple appends append (not overwrite) -------------------------
  w2.appendStatuslineError({ ts: 't1', segment: 'git', error_message: 'a', error_stack_first_line: 'a', cwd: '/' });
  w2.appendStatuslineError({ ts: 't2', segment: 'ccburn', error_message: 'b', error_stack_first_line: 'b', cwd: '/' });
  await new Promise(r => setTimeout(r, 50));
  const lines2 = readLines(logPath(home2));
  ok('appendStatuslineError: 3 lines after 3 calls', lines2.length, 3);

  // --- § 4 rotation at 1MB ---------------------------------------------------
  const home3 = makeHome('rotate');
  const w3 = freshWrapper(home3);
  // Pre-fill the file to >1MB so the next append triggers a rename.
  const filler = 'x'.repeat(1_100_000);
  fs.writeFileSync(logPath(home3), filler);
  // Sanity: file is bigger than threshold.
  const preSize = fs.statSync(logPath(home3)).size;
  okTruthy('rotate: pre-fill exceeds 1MB threshold', preSize > 1_000_000);
  // Now append — this should rotate filler to .prev and write a fresh main file.
  w3.appendStatuslineError({ ts: 'r1', segment: 'drift', error_message: 'rotation test', error_stack_first_line: 'X', cwd: '/' });
  await new Promise(r => setTimeout(r, 50));
  const prevExists = fs.existsSync(logPath(home3) + '.prev');
  okTruthy('rotate: .prev file created', prevExists);
  const prevSize = prevExists ? fs.statSync(logPath(home3) + '.prev').size : 0;
  ok('rotate: .prev contains the original filler', prevSize, preSize);
  const mainLines = readLines(logPath(home3));
  ok('rotate: main file has only the new line', mainLines.length, 1);
  let rotated = null;
  try { rotated = JSON.parse(mainLines[0]); } catch { /* leave null */ }
  okTruthy('rotate: post-rotation line parses as JSON', rotated !== null);
  if (rotated) ok('rotate: post-rotation line carries new segment', rotated.segment, 'drift');

  // --- § 5 log writer failure must NOT throw (CRITICAL invariant) ----------
  // Monkey-patch fs.statSync + fs.appendFile to throw — appendStatuslineError
  // must swallow these so the render path is never blocked.
  const home4 = makeHome('writerfail');
  const w4 = freshWrapper(home4);
  const origStat = fs.statSync;
  const origAppend = fs.appendFile;
  const origRename = fs.renameSync;
  let threw = false;
  try {
    fs.statSync = () => { throw new Error('stat denied'); };
    fs.appendFile = () => { throw new Error('append denied'); };
    fs.renameSync = () => { throw new Error('rename denied'); };
    w4.appendStatuslineError({ ts: 'fail', segment: 'renderer', error_message: 'x', error_stack_first_line: 'x', cwd: '/' });
  } catch (e) {
    threw = true;
  } finally {
    fs.statSync = origStat;
    fs.appendFile = origAppend;
    fs.renameSync = origRename;
  }
  okTruthy('writer-failure: appendStatuslineError swallowed all exceptions (did NOT throw)', !threw);

  // --- § 6 clean path — no log written when no segments error --------------
  const home5 = makeHome('clean');
  const w5 = freshWrapper(home5);
  const all6 = await Promise.all([
    w5.withSegmentDiag('renderer', Promise.resolve('a')),
    w5.withSegmentDiag('git',      Promise.resolve('b')),
    w5.withSegmentDiag('cacheAge', Promise.resolve('c')),
    w5.withSegmentDiag('ccburn',   Promise.resolve('d')),
    w5.withSegmentDiag('health',   Promise.resolve({ front: '', tail: '' })),
    w5.withSegmentDiag('drift',    Promise.resolve('')),
  ]);
  const errCount = all6.filter(r => r.error).length;
  ok('clean: zero errored segments across all 6', errCount, 0);
  okTruthy('clean: log file does not exist (no append called)', !fs.existsSync(logPath(home5)));

  // --- § 7 sigil format pin -------------------------------------------------
  // The wrapper should expose computeSegmentSigil OR otherwise let us pin the format.
  // We re-construct the canonical format here and assert the wrapper does the same
  // by checking the constant the wrapper uses for the sigil prefix is reachable.
  // The plan specifies: \x1b[31m⚠ <segmentName>?\x1b[0m
  if (typeof w.computeSegmentSigil === 'function') {
    ok('sigil: format matches \\x1b[31m⚠ git?\\x1b[0m', w.computeSegmentSigil('git'), '\x1b[31m⚠ git?\x1b[0m');
    ok('sigil: format matches \\x1b[31m⚠ renderer?\\x1b[0m', w.computeSegmentSigil('renderer'), '\x1b[31m⚠ renderer?\x1b[0m');
  } else {
    // Acceptable if not exported; the visual contract is enforced by the
    // integration probe (probe-statusline-wrapper.js extension) in Task 3.
    console.log('SKIP computeSegmentSigil not exported — format pinned only via composition probe');
  }

  console.log();
  console.log(`${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
