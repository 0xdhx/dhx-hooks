// Probe: classifyCacheEvent — diagnostics-first bust/cold classification
// (arc N7, manifest Item C as amended by the N5 review).
// Backs docs/decisions.md 2026-08-15 N7 bust-signal row and the accepted
// refinements f4 (diagnostics primary, ratio heuristic explicitly labeled),
// f24 (UNKNOWN_SMALL below the ~30k separability floor), f25 (terminal records
// only), f26 (ancestry rule), f27 (EXPECTED_COLD:<cause> vs UNEXPECTED_BUST).
// Run: node tests/probes/probe-cache-event-classifier.js

// SAFE_FOR_LIVE: yes   (drives exported classifyCacheEvent/parseTranscriptTail against tmp-file fixtures only)
const fs = require('fs');
const path = require('path');
const os = require('os');

const wrapper = require(path.join(__dirname, '..', '..', 'dhx', 'statusline-wrapper.js'));
const { parseTranscriptTail, classifyCacheEvent } = wrapper;

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'probe-cache-classifier-'));
process.on('exit', () => { try { fs.rmSync(TMP, { recursive: true, force: true }); } catch { /* nothing */ } });

let pass = 0, fail = 0;
function ok(name, cond) {
  if (cond) { console.log(`OK   ${name}`); pass++; }
  else { console.log(`FAIL ${name}`); fail++; }
}

let uuidN = 0;
function rec(ts, opts = {}) {
  return JSON.stringify({
    type: opts.type || 'assistant',
    isSidechain: false,
    timestamp: ts,
    requestId: opts.req || `req-${ts}-${uuidN}`,
    uuid: `u-${uuidN++}`,
    effort: opts.effort || 'medium',
    version: opts.version || '2.1.233',
    subtype: opts.subtype,
    message: opts.type === 'system' ? undefined : {
      id: opts.mid || `msg-${ts}-${uuidN}`,
      model: opts.model || 'claude-fable-5',
      stop_reason: 'end_turn',
      usage: opts.usage,
      diagnostics: opts.diag || null,
    },
  }) + '\n';
}

function classify(name, content) {
  const p = path.join(TMP, name);
  fs.writeFileSync(p, content);
  return classifyCacheEvent(parseTranscriptTail(p));
}

const T1 = '2026-08-15T10:00:00.000Z';
const T2 = '2026-08-15T10:10:00.000Z';
const bigWarm = { input_tokens: 5, cache_read_input_tokens: 150000, cache_creation_input_tokens: 2000 };

// --- diagnostics-first (f4) --------------------------------------------------
let ev = classify('diag-bust.jsonl',
  rec(T1, { usage: bigWarm }) +
  rec(T2, { usage: { input_tokens: 5, cache_read_input_tokens: 19000, cache_creation_input_tokens: 140000 },
            diag: { cache_miss_reason: { type: 'system_changed', cache_missed_input_tokens: 15750 } } }));
ok('server verdict → UNEXPECTED_BUST', ev.cls === 'UNEXPECTED_BUST');
ok('server verdict carries cause + missed + heuristic:false',
  ev.cause === 'system_changed' && ev.missed === 15750 && ev.heuristic === false);

ev = classify('diag-model.jsonl',
  rec(T1, { usage: bigWarm }) +
  rec(T2, { usage: { input_tokens: 5, cache_read_input_tokens: 0, cache_creation_input_tokens: 90000 },
            diag: { cache_miss_reason: { type: 'model_changed', cache_missed_input_tokens: 90000 } } }));
ok('diag model_changed → EXPECTED_COLD:model (f27)', ev.cls === 'EXPECTED_COLD:model');

// Diagnostics WIN over a warm-looking ratio (primary signal, not tie-breaker).
ev = classify('diag-over-ratio.jsonl',
  rec(T1, { usage: bigWarm }) +
  rec(T2, { usage: { input_tokens: 5, cache_read_input_tokens: 140000, cache_creation_input_tokens: 20000 },
            diag: { cache_miss_reason: { type: 'messages_changed', cache_missed_input_tokens: 18000 } } }));
ok('diagnostics override warm-shaped ratio', ev.cls === 'UNEXPECTED_BUST' && ev.heuristic === false);

// --- blind categories fall through to the heuristic --------------------------
// `unavailable` / `previous_message_not_found` are the server saying "can't
// diagnose", not bust verdicts (observed live: type unavailable on a fully-warm
// 447k-read turn). The heuristic classifies; the diag type stays as provenance.
ev = classify('blind-warm.jsonl',
  rec(T1, { usage: bigWarm }) +
  rec(T2, { usage: { input_tokens: 5, cache_read_input_tokens: 151000, cache_creation_input_tokens: 900 },
            diag: { cache_miss_reason: { type: 'unavailable' } } }));
ok('blind `unavailable` on warm geometry → WARM, not bust', ev.cls === 'WARM');
ok('blind verdict preserved as diag_type provenance', ev.diagType === 'unavailable' && ev.heuristic === true);

ev = classify('blind-bust.jsonl',
  rec(T1, { usage: bigWarm }) +
  rec(T2, { usage: { input_tokens: 5, cache_read_input_tokens: 20000, cache_creation_input_tokens: 130000 },
            diag: { cache_miss_reason: { type: 'previous_message_not_found' } } }));
ok('blind verdict + bust geometry → heuristic UNEXPECTED_BUST',
  ev.cls === 'UNEXPECTED_BUST' && ev.cause === 'ratio-bust' && ev.heuristic === true);

// --- structural expected-cold causes (f27) -----------------------------------
ev = classify('first.jsonl', rec(T1, { usage: { input_tokens: 5, cache_read_input_tokens: 0, cache_creation_input_tokens: 40000 } }));
ok('single record → EXPECTED_COLD:first', ev.cls === 'EXPECTED_COLD:first');

ev = classify('effort.jsonl',
  rec(T1, { usage: bigWarm, effort: 'medium' }) +
  rec(T2, { usage: { input_tokens: 5, cache_read_input_tokens: 0, cache_creation_input_tokens: 150000 }, effort: 'max' }));
ok('effort flip → EXPECTED_COLD:effort', ev.cls === 'EXPECTED_COLD:effort');

ev = classify('ccup.jsonl',
  rec(T1, { usage: bigWarm, version: '2.1.233' }) +
  rec(T2, { usage: { input_tokens: 5, cache_read_input_tokens: 0, cache_creation_input_tokens: 150000 }, version: '2.1.234' }));
ok('CC version bump → EXPECTED_COLD:cc-upgrade', ev.cls === 'EXPECTED_COLD:cc-upgrade');

ev = classify('compact.jsonl',
  rec(T1, { usage: bigWarm }) +
  rec('2026-08-15T10:05:00.000Z', { type: 'system', subtype: 'compact_boundary' }) +
  rec(T2, { usage: { input_tokens: 5, cache_read_input_tokens: 0, cache_creation_input_tokens: 30000 } }));
ok('compact boundary between records → EXPECTED_COLD:compact', ev.cls === 'EXPECTED_COLD:compact');

// --- heuristic fallback (explicitly labeled) ---------------------------------
ev = classify('h-warm.jsonl',
  rec(T1, { usage: bigWarm }) +
  rec(T2, { usage: { input_tokens: 5, cache_read_input_tokens: 151000, cache_creation_input_tokens: 1200 } }));
ok('read ≈ prior context → WARM', ev.cls === 'WARM');
ok('heuristic path labeled heuristic:true', ev.heuristic === true);

ev = classify('h-bust.jsonl',
  rec(T1, { usage: bigWarm }) +
  rec(T2, { usage: { input_tokens: 5, cache_read_input_tokens: 20000, cache_creation_input_tokens: 130000 } }));
ok('collapsed read + big creation → UNEXPECTED_BUST (ratio-bust)',
  ev.cls === 'UNEXPECTED_BUST' && ev.cause === 'ratio-bust' && ev.heuristic === true);

ev = classify('h-cold.jsonl',
  rec(T1, { usage: bigWarm }) +
  rec(T2, { usage: { input_tokens: 5, cache_read_input_tokens: 0, cache_creation_input_tokens: 145000 } }));
ok('read=0 + creation ≥10k → UNEXPECTED_BUST (ratio-cold)',
  ev.cls === 'UNEXPECTED_BUST' && ev.cause === 'ratio-cold');

// --- UNKNOWN_SMALL floor (f24) -----------------------------------------------
const smallPrior = { input_tokens: 5, cache_read_input_tokens: 18000, cache_creation_input_tokens: 2000 };
ev = classify('small.jsonl',
  rec(T1, { usage: smallPrior }) +
  rec(T2, { usage: { input_tokens: 5, cache_read_input_tokens: 0, cache_creation_input_tokens: 21000 } }));
ok('below ~30k prior → UNKNOWN_SMALL, never BUST/COLD', ev.cls === 'UNKNOWN_SMALL');

ev = classify('small-warm.jsonl',
  rec(T1, { usage: smallPrior }) +
  rec(T2, { usage: { input_tokens: 5, cache_read_input_tokens: 20500, cache_creation_input_tokens: 400 } }));
ok('small context but warm-shaped stays WARM', ev.cls === 'WARM');

// --- misc --------------------------------------------------------------------
ev = classify('gap.jsonl', rec(T1, { usage: bigWarm }) + rec(T2, { usage: { input_tokens: 5, cache_read_input_tokens: 151000, cache_creation_input_tokens: 900 } }));
ok('gap_s computed from adjacent terminal records', ev.gapS === 600);

ok('null tail → null', classifyCacheEvent(null) === null);

console.log(`${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
