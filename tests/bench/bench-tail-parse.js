// Benchmark: parseTranscriptTail hot-path cost (arc N7, review f30).
// NOT a probe — no assertions; prints p50/p95 wall latency and bytes read for
// three transcript shapes: small (~200KB), large (50MB), and oversized-line
// (a 5MB single JSONL line inside the tail window). Results recorded in
// docs/decisions.md 2026-08-15 N7 row.
// Run: node tests/bench/bench-tail-parse.js
const fs = require('fs');
const path = require('path');
const os = require('os');

const { parseTranscriptTail } = require(path.join(__dirname, '..', '..', 'dhx', 'statusline-wrapper.js'));

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'bench-tail-'));
process.on('exit', () => { try { fs.rmSync(TMP, { recursive: true, force: true }); } catch { /* nothing */ } });

let n = 0;
function rec(extra) {
  n++;
  return JSON.stringify({
    type: 'assistant', isSidechain: false,
    timestamp: new Date(1755200000000 + n * 4000).toISOString(),
    requestId: `req-${n}`, uuid: `uuid-${n}`, effort: 'medium', version: '2.1.233',
    message: {
      id: `msg-${n}`, model: 'claude-fable-5', stop_reason: 'end_turn',
      usage: { input_tokens: 5, cache_read_input_tokens: 150000 + n, cache_creation_input_tokens: 900,
               cache_creation: { ephemeral_1h_input_tokens: 900, ephemeral_5m_input_tokens: 0 } },
      diagnostics: null,
      content: extra ? [{ type: 'text', text: extra }] : [],
    },
  }) + '\n';
}

function build(name, targetBytes, oversized) {
  const p = path.join(TMP, name);
  const fd = fs.openSync(p, 'w');
  let written = 0;
  const filler = 'x'.repeat(2000);
  while (written < targetBytes) {
    const line = rec(filler);
    fs.writeSync(fd, line);
    written += Buffer.byteLength(line);
  }
  if (oversized) {
    const line = rec('y'.repeat(5 * 1024 * 1024)); // 5MB single line in the tail
    fs.writeSync(fd, line);
    fs.writeSync(fd, rec(filler));                 // one normal record after it
  }
  fs.closeSync(fd);
  return p;
}

function bench(label, p, iters) {
  const bytes = Math.min(262144, fs.statSync(p).size);
  const times = [];
  for (let i = 0; i < iters; i++) {
    const t0 = process.hrtime.bigint();
    parseTranscriptTail(p);
    times.push(Number(process.hrtime.bigint() - t0) / 1e6);
  }
  times.sort((a, b) => a - b);
  const pct = (q) => times[Math.min(times.length - 1, Math.floor(times.length * q))].toFixed(2);
  console.log(`${label.padEnd(18)} p50=${pct(0.5)}ms  p95=${pct(0.95)}ms  bytes_read=${bytes}  file=${(fs.statSync(p).size / 1e6).toFixed(1)}MB`);
}

bench('small (~200KB)', build('small.jsonl', 200 * 1024, false), 300);
bench('large (50MB)', build('large.jsonl', 50 * 1024 * 1024, false), 300);
bench('oversized-line', build('oversized.jsonl', 200 * 1024, true), 300);
