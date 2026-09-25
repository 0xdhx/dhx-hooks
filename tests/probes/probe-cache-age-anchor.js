// Probe: parseTranscriptTail anchor semantics + getCacheAge render (arc N7).
// the 2026-08-15 N7 bust-signal row, HP-019 (JSONL transcript schema), and the
// N5 review amendments f20 (TTL from observed write bucket) + f21 (anchor on
// substantial cache_creation, not only positive reads).
// Run: node tests/probes/probe-cache-age-anchor.js
//
// Pattern change (2026-08-15): drives the REAL exported functions from
// dhx/statusline-wrapper.js instead of a local mirror — readCacheAnchor was
// replaced by the shared parseTranscriptTail and a mirror of dead code cannot
// regress. Fixtures are tmp files only.

// SAFE_FOR_LIVE: yes   (drives exported functions against tmp-file fixtures only)
const fs = require('fs');
const path = require('path');
const os = require('os');

const wrapper = require(path.join(__dirname, '..', '..', 'dhx', 'statusline-wrapper.js'));
const { parseTranscriptTail, getCacheAge } = wrapper;

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'probe-cache-anchor-'));
process.on('exit', () => { try { fs.rmSync(TMP, { recursive: true, force: true }); } catch { /* nothing */ } });

let pass = 0, fail = 0;
function ok(name, cond) {
  if (cond) { console.log(`OK   ${name}`); pass++; }
  else { console.log(`FAIL ${name}`); fail++; }
}

function rec(ts, opts = {}) {
  return JSON.stringify({
    type: opts.type || 'assistant',
    isSidechain: opts.sidechain === true,
    timestamp: ts,
    requestId: opts.req || `req-${ts}`,
    uuid: opts.uuid || `uuid-${ts}-${Math.floor(Math.random() * 1e9)}`,
    effort: opts.effort || 'medium',
    version: opts.version || '2.1.233',
    subtype: opts.subtype,
    message: opts.type === 'system' ? undefined : {
      id: opts.mid || `msg-${ts}`,
      model: opts.model || 'claude-fable-5',
      stop_reason: opts.stop === null ? null : (opts.stop || 'end_turn'),
      usage: opts.usage || { input_tokens: 5, cache_read_input_tokens: 1000, cache_creation_input_tokens: 100 },
      diagnostics: opts.diag || null,
    },
  }) + '\n';
}

function writeFixture(name, content) {
  const p = path.join(TMP, name);
  fs.writeFileSync(p, content);
  return p;
}

// --- basic null paths --------------------------------------------------------
ok('missing file returns null', parseTranscriptTail(path.join(TMP, 'nope.jsonl')) === null);
ok('empty file returns null', parseTranscriptTail(writeFixture('empty.jsonl', '')) === null);
ok('no assistant entries returns null',
  parseTranscriptTail(writeFixture('nouser.jsonl', JSON.stringify({ type: 'user', timestamp: '2026-01-01T00:00:00Z' }) + '\n')) === null);

// --- anchor selection --------------------------------------------------------
const t1 = '2026-08-15T10:00:00.000Z', t2 = '2026-08-15T10:05:00.000Z';

// Zero reads + trivial creation → parse succeeds but no anchor.
const zeroP = writeFixture('zero.jsonl',
  rec(t1, { usage: { input_tokens: 5, cache_read_input_tokens: 0, cache_creation_input_tokens: 100 } }));
const zeroT = parseTranscriptTail(zeroP);
ok('zero reads + trivial creation → no anchor', zeroT !== null && zeroT.anchor === null);

// f21: zero reads + SUBSTANTIAL creation anchors (cold write re-anchors).
const coldP = writeFixture('coldwrite.jsonl',
  rec(t1, { usage: { input_tokens: 5, cache_read_input_tokens: 0, cache_creation_input_tokens: 60000 } }));
const coldT = parseTranscriptTail(coldP);
ok('substantial cache_creation anchors without reads (f21)',
  coldT !== null && coldT.anchor !== null && coldT.anchor.tsMs === Date.parse(t1));

// Newest-by-timestamp wins.
const multiP = writeFixture('multi.jsonl', rec(t1) + rec(t2));
const multiT = parseTranscriptTail(multiP);
ok('anchor is newest cache_read entry', multiT.anchor.tsMs === Date.parse(t2));

// Anchor unaffected by file mtime.
const before = parseTranscriptTail(multiP).anchor.tsMs;
fs.utimesSync(multiP, new Date(), new Date());
ok('anchor ignores file mtime', parseTranscriptTail(multiP).anchor.tsMs === before);

// Sidechain exclusion.
const sideP = writeFixture('side.jsonl', rec(t1) + rec(t2, { sidechain: true }));
ok('sidechain entries excluded from anchor', parseTranscriptTail(sideP).anchor.tsMs === Date.parse(t1));

// Non-terminal (no stop_reason) records are ignored entirely.
const streamP = writeFixture('stream.jsonl', rec(t1) + rec(t2, { stop: null }));
ok('non-terminal record (no stop_reason) ignored', parseTranscriptTail(streamP).newest.tsMs === Date.parse(t1));

// uuid dedup (fork replay).
const dupP = writeFixture('dup.jsonl', rec(t1, { uuid: 'same' }) + rec(t2, { uuid: 'same' }));
ok('duplicate uuid deduped', parseTranscriptTail(dupP).prev === null);

// --- TTL bucket (f20) --------------------------------------------------------
const b5P = writeFixture('b5.jsonl', rec(t1, {
  usage: { input_tokens: 5, cache_read_input_tokens: 1000, cache_creation_input_tokens: 500,
           cache_creation: { ephemeral_1h_input_tokens: 0, ephemeral_5m_input_tokens: 500 } } }));
ok('5m write bucket → ttlSecs 300', parseTranscriptTail(b5P).ttlSecs === 300);
const b1P = writeFixture('b1.jsonl', rec(t1, {
  usage: { input_tokens: 5, cache_read_input_tokens: 1000, cache_creation_input_tokens: 500,
           cache_creation: { ephemeral_1h_input_tokens: 500, ephemeral_5m_input_tokens: 0 } } }));
ok('1h write bucket → ttlSecs 3600', parseTranscriptTail(b1P).ttlSecs === 3600);

// --- disorder flag (HP-019) --------------------------------------------------
const disP = writeFixture('dis.jsonl', rec(t2) + rec(t1));
ok('file order vs timestamp disorder sets corrupt flag', parseTranscriptTail(disP).corrupt === true);
ok('in-order file has corrupt=false', parseTranscriptTail(multiP).corrupt === false);

// --- getCacheAge render ------------------------------------------------------
async function renderChecks() {
  const nowIso = new Date(Date.now() - 5 * 60 * 1000).toISOString(); // 5 min ago
  const freshP = writeFixture('fresh.jsonl', rec(nowIso));
  const freshT = parseTranscriptTail(freshP);
  const data = { model: { id: 'claude-fable-5' }, effort: { level: 'medium' } };

  const seg = await getCacheAge(data, freshT);
  ok('fresh anchor renders green countdown', /\x1b\[32m\d+m\x1b\[0m/.test(seg));

  const segNoTail = await getCacheAge(data, null);
  ok('null tail hides segment', segNoTail === '');

  // Model-ID mismatch vs anchor → dim ttl? (unknown, never a fake countdown).
  const segModel = await getCacheAge({ model: { id: 'claude-opus-5' }, effort: { level: 'medium' } }, freshT);
  ok('model change → dim ttl?', segModel.includes('ttl?') && segModel.includes('\x1b[2m'));

  // Effort mismatch vs anchor → same invalidation.
  const segEffort = await getCacheAge({ model: { id: 'claude-fable-5' }, effort: { level: 'max' } }, freshT);
  ok('effort change → dim ttl?', segEffort.includes('ttl?'));

  // Context-window VARIANT tag must not read as a model change. stdin carries
  // `claude-<model>[1m]`; the API echoes only the base model in message.model.
  // Comparing them raw made every long-context session render `ttl?` forever
  // (shipped 2026-08-15, caught same day on a live 7-of-10-session sample).
  // The fixture below is the shape the original cases could not produce: they
  // drew both sides from ONE string space, so the client-vs-API asymmetry was
  // unrepresentable.
  const segVariant = await getCacheAge(
    { model: { id: 'claude-fable-5[1m]' }, effort: { level: 'medium' } }, freshT);
  ok('[1m] variant vs base anchor renders a countdown, not ttl?',
    /\d+m/.test(segVariant) && !segVariant.includes('ttl?'));

  // ...and the reverse direction (variant on the ANCHOR side, base on stdin).
  const variantAnchorT = parseTranscriptTail(
    writeFixture('variant-anchor.jsonl', rec(nowIso, { model: 'claude-fable-5[1m]' })));
  const segVariantAnchor = await getCacheAge(
    { model: { id: 'claude-fable-5' }, effort: { level: 'medium' } }, variantAnchorT);
  ok('base stdin vs [1m] anchor renders a countdown, not ttl?',
    /\d+m/.test(segVariantAnchor) && !segVariantAnchor.includes('ttl?'));

  // Non-vacuity: normalization must NOT swallow a genuine cross-model switch
  // that happens to carry a variant tag on one side.
  const segRealSwitch = await getCacheAge(
    { model: { id: 'claude-opus-5[1m]' }, effort: { level: 'medium' } }, freshT);
  ok('opus[1m] vs fable anchor still invalidates', segRealSwitch.includes('ttl?'));

  // Display-name-only stdin (no stable id) must NOT false-trigger (f5).
  const segNoId = await getCacheAge({ model: { display_name: 'Fable 5' }, effort: { level: 'medium' } }, freshT);
  ok('absent model.id does not invalidate', /\d+m/.test(segNoId) && !segNoId.includes('ttl?'));

  // Expired anchor.
  const oldIso = new Date(Date.now() - 2 * 3600 * 1000).toISOString();
  const oldT = parseTranscriptTail(writeFixture('old.jsonl', rec(oldIso)));
  const segOld = await getCacheAge(data, oldT);
  ok('expired anchor renders EXPIRED', segOld.includes('EXPIRED'));

  // Bust glyph: newest terminal record carries a server bust verdict.
  const bustP = writeFixture('bust.jsonl',
    rec(nowIso, { req: 'rA', mid: 'mA', usage: { input_tokens: 5, cache_read_input_tokens: 150000, cache_creation_input_tokens: 200 } }) +
    rec(new Date().toISOString(), { req: 'rB', mid: 'mB',
      usage: { input_tokens: 5, cache_read_input_tokens: 19000, cache_creation_input_tokens: 140000 },
      diag: { cache_miss_reason: { type: 'messages_changed', cache_missed_input_tokens: 133000 } } }));
  const bustT = parseTranscriptTail(bustP);
  const segBust = await getCacheAge(data, bustT);
  ok('unexpected bust appends red ✸bust glyph with kt', segBust.includes('\x1b[31m✸bust:133k\x1b[0m'));

  // Expected cold (model change between records) → NO glyph.
  const expP = writeFixture('exp.jsonl',
    rec(nowIso, { req: 'rA', mid: 'mA', model: 'claude-opus-5' }) +
    rec(new Date().toISOString(), { req: 'rB', mid: 'mB', model: 'claude-fable-5',
      usage: { input_tokens: 5, cache_read_input_tokens: 0, cache_creation_input_tokens: 90000 },
      diag: { cache_miss_reason: { type: 'model_changed', cache_missed_input_tokens: 90000 } } }));
  const segExp = await getCacheAge(data, parseTranscriptTail(expP));
  ok('expected cold (model change) renders no glyph', !segExp.includes('✸'));

  console.log(`${pass} passed, ${fail} failed`);
  process.exit(fail === 0 ? 0 : 1);
}
renderChecks();
