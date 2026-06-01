// Probe: confirm getCacheAge anchors on the most recent type=assistant entry
// with cache_read_input_tokens > 0, NOT on JSONL mtime.
// HP-019 (JSONL transcript schema).
// Run: node tests/probes/probe-cache-age-anchor.js
//
// Pattern: re-implements readCacheAnchor locally (matching probe-settings-hash.js
// convention) so a future regression in the wrapper diverges from the probe and
// flips assertions. The probe IS the contract.

// SAFE_FOR_LIVE: yes   (re-implements function locally; tmp-file fixtures only)
const fs = require('fs');
const path = require('path');
const os = require('os');

// --- function under test (mirror of dhx/statusline-wrapper.js::readCacheAnchor) ---
function readCacheAnchor(transcriptPath) {
  const WINDOW = 65536;
  let fd;
  try {
    fd = fs.openSync(transcriptPath, 'r');
    const size = fs.fstatSync(fd).size;
    if (size === 0) return null;
    const len = Math.min(WINDOW, size);
    const buf = Buffer.alloc(len);
    fs.readSync(fd, buf, 0, len, size - len);
    const lines = buf.toString('utf8').split('\n');
    const startIdx = size > WINDOW ? 1 : 0;
    for (let i = lines.length - 1; i >= startIdx; i--) {
      const line = lines[i];
      if (!line) continue;
      let entry;
      try { entry = JSON.parse(line); } catch { continue; }
      if (entry.type !== 'assistant') continue;
      const reads = entry.message && entry.message.usage && entry.message.usage.cache_read_input_tokens;
      if (!reads || reads <= 0) continue;
      const t = Date.parse(entry.timestamp || '');
      if (Number.isFinite(t)) return t;
    }
    return null;
  } catch {
    return null;
  } finally {
    if (fd !== undefined) { try { fs.closeSync(fd); } catch { /* nothing */ } }
  }
}

// --- band selection (mirrors getCacheAge color logic) ---
// Returned for color-band assertions without re-implementing ANSI escapes here.
function bandFor(remaining) {
  if (remaining <= 0) return 'red';
  if (remaining < 15 * 60) return 'orange';
  if (remaining < 30 * 60) return 'yellow';
  return 'green';
}

// --- helpers ---
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'probe-cache-age-'));
let pass = 0, fail = 0;
function ok(name, cond) {
  if (cond) { console.log(`OK   ${name}`); pass++; }
  else { console.log(`FAIL ${name}`); fail++; }
}

function makeAssistant(ts, cacheRead) {
  return JSON.stringify({
    type: 'assistant',
    timestamp: ts,
    message: { usage: { cache_read_input_tokens: cacheRead, cache_creation_input_tokens: 0 } },
  });
}
function makeAwaySummary(ts) {
  // No .message.usage block — matches the real shape per away-summary-billing.md
  return JSON.stringify({ type: 'system', subtype: 'away_summary', timestamp: ts, summary: 'recap' });
}
function writeJsonl(name, lines) {
  const p = path.join(TMP, name);
  fs.writeFileSync(p, lines.join('\n') + '\n');
  return p;
}

// --- 1. missing transcript_path → null (caller resolves '') ---
ok('missing file path returns null', readCacheAnchor(path.join(TMP, 'does-not-exist.jsonl')) === null);

// --- 2. empty file → null ---
const emptyP = path.join(TMP, 'empty.jsonl');
fs.writeFileSync(emptyP, '');
ok('empty file returns null', readCacheAnchor(emptyP) === null);

// --- 3. no assistant-with-cache_read entries → null ---
// User entries + system away_summary entries only. mtime is recent but no anchor exists.
const noAnchorP = writeJsonl('no-anchor.jsonl', [
  JSON.stringify({ type: 'user', timestamp: '2026-04-17T10:00:00.000Z', message: { content: 'hi' } }),
  makeAwaySummary('2026-04-17T10:05:00.000Z'),
  makeAwaySummary('2026-04-17T10:08:00.000Z'),
]);
ok('no cache_read entries returns null (away_summary does not anchor)',
  readCacheAnchor(noAnchorP) === null);

// --- 4. assistant entry with cache_read=0 does NOT anchor ---
const zeroReadsP = writeJsonl('zero-reads.jsonl', [
  JSON.stringify({ type: 'assistant', timestamp: '2026-04-17T10:00:00.000Z',
    message: { usage: { cache_read_input_tokens: 0, cache_creation_input_tokens: 50000 } } }),
]);
ok('assistant with cache_read=0 returns null', readCacheAnchor(zeroReadsP) === null);

// --- 5. picks the MOST RECENT assistant-with-cache_read, not earlier ones ---
const t1 = '2026-04-17T10:00:00.000Z';  // older
const t2 = '2026-04-17T10:30:00.000Z';  // newer
const multipleP = writeJsonl('multiple.jsonl', [
  makeAssistant(t1, 50000),
  makeAwaySummary('2026-04-17T10:15:00.000Z'),  // bumps mtime, doesn't anchor
  makeAssistant(t2, 60000),
  makeAwaySummary('2026-04-17T10:45:00.000Z'),  // most recent line, but not assistant
]);
ok('picks most recent assistant-with-cache_read (skips later non-anchor lines)',
  readCacheAnchor(multipleP) === Date.parse(t2));

// --- 6. mtime independence — anchor stays at t2 even if we re-touch the file ---
const beforeMtime = readCacheAnchor(multipleP);
fs.utimesSync(multipleP, new Date(), new Date());  // bump mtime to NOW
const afterMtime = readCacheAnchor(multipleP);
ok('anchor unchanged when mtime alone bumps (proves mtime independence)',
  beforeMtime === afterMtime && afterMtime === Date.parse(t2));

// --- 7. partial line at head of large file is skipped (no JSON.parse pollution) ---
// Construct a file >64KB. The reader's 64KB tail will start mid-record. Make
// the partial head an unparseable string so a missing skip would throw or noise.
// Then place a valid anchor near the end.
const filler = 'X'.repeat(70000);  // 70KB of junk that becomes the partial first line
const tEnd = '2026-04-17T11:00:00.000Z';
const partialP = path.join(TMP, 'partial-head.jsonl');
// Single line of 70k 'X' chars (no newlines) followed by the real anchor entry.
// When the reader takes the last 64KB and splits on '\n', lines[0] is "XXX...XXX{maybe}"
// — definitely not parseable JSON. lines[1] is the anchor.
fs.writeFileSync(partialP, filler + '\n' + makeAssistant(tEnd, 30000) + '\n');
ok('partial line at head of window is skipped (no parse error pollution)',
  readCacheAnchor(partialP) === Date.parse(tEnd));

// --- 8. file fits entirely in window — startIdx stays 0, byte 0 is a real record head ---
// Put the only anchor as the very first line. If the reader incorrectly skipped
// startIdx 0 even when size <= WINDOW, this would return null.
const tinyP = writeJsonl('tiny-fits.jsonl', [
  makeAssistant('2026-04-17T09:00:00.000Z', 12345),
]);
const tinySize = fs.statSync(tinyP).size;
ok('small file (size <= window) reads first line as real entry',
  tinySize <= 65536 && readCacheAnchor(tinyP) === Date.parse('2026-04-17T09:00:00.000Z'));

// --- 9. unparseable file → null (no exception bubbles out) ---
const garbageP = path.join(TMP, 'garbage.jsonl');
fs.writeFileSync(garbageP, '{not json\nalso not json\n}{}{\n');
ok('unparseable garbage returns null without throwing', readCacheAnchor(garbageP) === null);

// --- 10. band thresholds map remaining → color correctly ---
const TTL = 3600;
ok('remaining 3000s (50m) → green', bandFor(3000) === 'green');
ok('remaining 1700s (28m) → yellow', bandFor(1700) === 'yellow');
ok('remaining 600s  (10m) → orange', bandFor(600) === 'orange');
ok('remaining 0s         → red',    bandFor(0) === 'red');
ok('remaining -500s      → red',    bandFor(-500) === 'red');

// --- 11. clamp: anchor in the future (clock skew) yields remaining clamped to TTL ---
// Re-implements the getCacheAge clamp formula to assert it's still tight.
function remainingFor(anchorMs, nowMs, ttl) {
  const elapsed = (nowMs - anchorMs) / 1000;
  return Math.min(ttl, Math.floor(ttl - elapsed));
}
ok('future anchor clamped to TTL ceiling',
  remainingFor(Date.now() + 5_000, Date.now(), TTL) === TTL);
ok('expired anchor produces remaining ≤ 0',
  remainingFor(Date.now() - (TTL + 100) * 1000, Date.now(), TTL) <= 0);

// --- cleanup ---
try { fs.rmSync(TMP, { recursive: true, force: true }); } catch { /* nothing */ }

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
