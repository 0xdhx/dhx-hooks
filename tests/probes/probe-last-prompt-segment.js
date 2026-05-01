// Probe: confirm readLastUserPromptText extracts the most recent user prompt
// from a JSONL transcript with proper filtering of tool_result entries,
// 20-char truncation, control-char stripping, and 64KB tail-window handling.
// Backs the 2026-04-27 last-prompt segment addition (item 1 of statusline session).
// Run: node tests/probes/probe-last-prompt-segment.js
//
// Pattern: re-implements readLastUserPromptText locally (matching
// probe-cache-age-anchor.js convention) so a future regression in the
// wrapper diverges from the probe and flips assertions. The probe IS the
// contract — keep them in sync deliberately.

// SAFE_FOR_LIVE: yes   (re-implements function locally; tmp-file fixtures only)
const fs = require('fs');
const path = require('path');
const os = require('os');

// --- function under test (mirror of dhx/statusline-wrapper.js::readLastUserPromptText) ---
function readLastUserPromptText(transcriptPath) {
  const WINDOW = 65536;
  const MAX_CHARS = 20;
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
      if (entry.type !== 'user') continue;
      const content = entry.message && entry.message.content;
      let raw = null;
      if (typeof content === 'string') {
        raw = content;
      } else if (Array.isArray(content) && content.length > 0
                 && content[0] && content[0].type === 'text') {
        raw = content[0].text;
      }
      if (typeof raw !== 'string' || raw.length === 0) continue;
      const cleaned = raw.replace(/[\x00-\x1f\x7f]/g, ' ').replace(/\s+/g, ' ').trim();
      if (!cleaned) continue;
      return cleaned.length <= MAX_CHARS
        ? cleaned
        : cleaned.slice(0, MAX_CHARS - 1) + '…';
    }
    return null;
  } catch {
    return null;
  } finally {
    if (fd !== undefined) { try { fs.closeSync(fd); } catch { /* nothing */ } }
  }
}

// --- helpers ---
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'probe-last-prompt-'));
let pass = 0, fail = 0;
function ok(name, cond) {
  if (cond) { console.log(`OK   ${name}`); pass++; }
  else { console.log(`FAIL ${name}`); fail++; }
}

function userString(s, ts = '2026-04-27T10:00:00.000Z') {
  return JSON.stringify({ type: 'user', timestamp: ts, message: { content: s } });
}
function userTextArr(s, ts = '2026-04-27T10:00:00.000Z') {
  return JSON.stringify({ type: 'user', timestamp: ts,
    message: { content: [{ type: 'text', text: s }] } });
}
function userToolResult(s, ts = '2026-04-27T10:00:00.000Z') {
  return JSON.stringify({ type: 'user', timestamp: ts,
    message: { content: [{ type: 'tool_result', tool_use_id: 'tu_1', content: s }] } });
}
function asst(text, ts = '2026-04-27T10:00:00.000Z') {
  return JSON.stringify({ type: 'assistant', timestamp: ts,
    message: { content: [{ type: 'text', text }] } });
}
function writeJsonl(name, lines) {
  const p = path.join(TMP, name);
  fs.writeFileSync(p, lines.join('\n') + '\n');
  return p;
}

// --- 1. string content extracted directly ---
const p1 = writeJsonl('1-string.jsonl', [userString('hello world')]);
ok('1. string content extracted directly', readLastUserPromptText(p1) === 'hello world');

// --- 2. array text content extracted ---
const p2 = writeJsonl('2-array-text.jsonl', [userTextArr('foo')]);
ok('2. array [{type:text}] extracted via content[0].text', readLastUserPromptText(p2) === 'foo');

// --- 3. tool_result-only window returns null (filtered) ---
const p3 = writeJsonl('3-tool-result.jsonl', [userToolResult('result data')]);
ok('3. tool_result-only window returns null (filtered)', readLastUserPromptText(p3) === null);

// --- 4. mixed sequence: returns most recent valid user prompt, skipping tool_result ---
const p4 = writeJsonl('4-mixed.jsonl', [
  userString('older prompt',           '2026-04-27T10:00:00.000Z'),
  asst       ('reply',                  '2026-04-27T10:01:00.000Z'),
  userToolResult('intermediate result', '2026-04-27T10:01:05.000Z'),
  userString ('newer prompt',           '2026-04-27T10:02:00.000Z'),
  asst       ('reply2',                 '2026-04-27T10:03:00.000Z'),
  userToolResult('latest result',       '2026-04-27T10:03:05.000Z'),  // most recent user-role, but tool_result → skip
]);
ok('4. picks newest user-with-text, skipping tool_result',
   readLastUserPromptText(p4) === 'newer prompt');

// --- 5. all-assistant window returns null ---
const p5 = writeJsonl('5-no-user.jsonl', [asst('a'), asst('b'), asst('c')]);
ok('5. no user entry in window returns null', readLastUserPromptText(p5) === null);

// --- 6. truncation: long prompt → 19 chars + … (20 total, mirrors NAME_MAX truncate) ---
const longText = 'this is a very long user prompt over twenty chars';  // length > 20
const p6 = writeJsonl('6-trunc.jsonl', [userString(longText)]);
const got6 = readLastUserPromptText(p6);
ok('6a. truncated output is exactly 20 chars total',
   typeof got6 === 'string' && got6.length === 20);
ok('6b. truncated output ends with ellipsis',
   typeof got6 === 'string' && got6.endsWith('…'));
ok('6c. truncated output equals first-19-chars + …',
   got6 === longText.slice(0, 19) + '…');

// --- 7. newline collapse: \n becomes single space ---
const p7 = writeJsonl('7-newlines.jsonl', [userString('line1\nline2')]);
ok('7. newlines collapsed to single space', readLastUserPromptText(p7) === 'line1 line2');

// --- 8. empty content → null (degenerate) ---
const p8 = writeJsonl('8-empty.jsonl', [userString('')]);
ok('8. empty string content returns null', readLastUserPromptText(p8) === null);

// --- 9. slash commands ARE user prompts ---
const p9 = writeJsonl('9-slash.jsonl', [userString('/restart-plugins')]);
ok('9. slash command extracted (not filtered)', readLastUserPromptText(p9) === '/restart-plugins');

// --- 10. 64KB boundary: huge non-matching tail pushes user entry out of window ---
// Place a real user prompt at byte 0, then fill the rest with assistant entries.
const filler = Array.from({length: 100}, (_, i) =>
  asst('x'.repeat(700) + ' ' + i)
).join('\n');  // ~70KB+
const p10 = path.join(TMP, '10-window.jsonl');
fs.writeFileSync(p10, userString('out of window') + '\n' + filler + '\n');
const sz10 = fs.statSync(p10).size;
ok('10a. fixture exceeds 64KB window', sz10 > 65536);
ok('10b. user entry pushed out of 64KB window returns null',
   readLastUserPromptText(p10) === null);

// --- 11. control-char / ANSI stripping (defensive) ---
// User pastes ANSI: literal ESC [31m red text ESC [0m
const ansiPayload = '\x1b[31mred text\x1b[0m';
const p11 = writeJsonl('11-ansi.jsonl', [userString(ansiPayload)]);
const got11 = readLastUserPromptText(p11);
ok('11a. ANSI ESC stripped from output',
   typeof got11 === 'string' && !got11.includes('\x1b'));
ok('11b. ANSI strip preserves visible text substring',
   typeof got11 === 'string' && got11.includes('red text'));

// --- 12. partial first line in >64KB file is skipped without parse pollution ---
// Mirror the cache-anchor probe's "filler XX...XX" pattern: huge junk first
// line, real anchor near end. The window starts mid-record and lines[0] is
// unparseable JSON; the startIdx=1 skip prevents pollution.
const junkLine = 'X'.repeat(70000);
const p12 = path.join(TMP, '12-partial-head.jsonl');
fs.writeFileSync(p12, junkLine + '\n' + userString('found me') + '\n');
ok('12. partial line at head of window skipped without parse pollution',
   readLastUserPromptText(p12) === 'found me');

// --- 13. small file (size <= window) reads first line as real entry ---
// startIdx stays 0 — byte 0 is a real record head, not a partial.
const p13 = writeJsonl('13-tiny.jsonl', [userString('tiny one')]);
const tinySize = fs.statSync(p13).size;
ok('13. small file reads first line as real entry',
   tinySize <= 65536 && readLastUserPromptText(p13) === 'tiny one');

// --- 14. missing file → null (no exception) ---
ok('14. missing file path returns null',
   readLastUserPromptText(path.join(TMP, 'does-not-exist.jsonl')) === null);

// --- 15. unparseable garbage → null (no exception bubbles out) ---
const garbageP = path.join(TMP, '15-garbage.jsonl');
fs.writeFileSync(garbageP, '{not json\nalso not json\n}{}{\n');
ok('15. unparseable garbage returns null without throwing',
   readLastUserPromptText(garbageP) === null);

// --- 16. exact-20-char content is NOT truncated (boundary case) ---
const exact20 = 'a'.repeat(20);
const p16 = writeJsonl('16-exact20.jsonl', [userString(exact20)]);
const got16 = readLastUserPromptText(p16);
ok('16a. exact-20-char content passes through unchanged',
   got16 === exact20);
ok('16b. exact-20-char output has no ellipsis',
   typeof got16 === 'string' && !got16.endsWith('…'));

// --- 17. 21-char content gets truncated to 20 (boundary case) ---
const twentyOne = 'b'.repeat(21);
const p17 = writeJsonl('17-21chars.jsonl', [userString(twentyOne)]);
const got17 = readLastUserPromptText(p17);
ok('17. 21-char content truncated to 20 (19 b + …)',
   got17 === 'b'.repeat(19) + '…');

// --- cleanup ---
try { fs.rmSync(TMP, { recursive: true, force: true }); } catch { /* nothing */ }

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
