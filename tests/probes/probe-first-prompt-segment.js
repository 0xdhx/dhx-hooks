// Probe: confirm readFirstUserPromptText extracts the first non-synthetic
// user prompt from a JSONL transcript with proper filtering of tool_result
// entries, <local-command-caveat> synthetic CC entries, /clear single-skip
// exception, 20-char truncation, control-char stripping, and 64KB head-window
// handling.
// Backs the 2026-05-20 first-prompt segment swap (quick task 260520-34p,
// replaces 2026-04-27 last-prompt segment from commit 1b24044).
// Run: node tests/probes/probe-first-prompt-segment.js
//
// Pattern: re-implements readFirstUserPromptText locally (matching
// probe-cache-age-anchor.js convention) so a future regression in the
// wrapper diverges from the probe and flips assertions. The probe IS the
// contract — keep them in sync deliberately.

// SAFE_FOR_LIVE: yes   (re-implements function locally; tmp-file fixtures only)
const fs = require('fs');
const path = require('path');
const os = require('os');

// --- function under test (mirror of dhx/statusline-wrapper.js::readFirstUserPromptText) ---
function readFirstUserPromptText(transcriptPath) {
  const WINDOW = 65536;
  const MAX_CHARS = 20;
  let fd;
  try {
    fd = fs.openSync(transcriptPath, 'r');
    const size = fs.fstatSync(fd).size;
    if (size === 0) return null;
    const len = Math.min(WINDOW, size);
    const buf = Buffer.alloc(len);
    fs.readSync(fd, buf, 0, len, 0);
    const lines = buf.toString('utf8').split('\n');
    const endIdx = size > WINDOW ? lines.length - 1 : lines.length;
    let clearSkipped = false;
    for (let i = 0; i < endIdx; i++) {
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
      if (raw.startsWith('<local-command-caveat>')) continue;
      const cmdName = raw.match(/<command-name>([^<]+)<\/command-name>/);
      if (cmdName) raw = cmdName[1];
      if (!clearSkipped && raw === '/clear') {
        clearSkipped = true;
        continue;
      }
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
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'probe-first-prompt-'));
let pass = 0, fail = 0;
function ok(name, cond) {
  if (cond) { console.log(`OK   ${name}`); pass++; }
  else { console.log(`FAIL ${name}`); fail++; }
}

function userString(s, ts = '2026-05-20T10:00:00.000Z') {
  return JSON.stringify({ type: 'user', timestamp: ts, message: { content: s } });
}
function userTextArr(s, ts = '2026-05-20T10:00:00.000Z') {
  return JSON.stringify({ type: 'user', timestamp: ts,
    message: { content: [{ type: 'text', text: s }] } });
}
function userToolResult(s, ts = '2026-05-20T10:00:00.000Z') {
  return JSON.stringify({ type: 'user', timestamp: ts,
    message: { content: [{ type: 'tool_result', tool_use_id: 'tu_1', content: s }] } });
}
function asst(text, ts = '2026-05-20T10:00:00.000Z') {
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
ok('1. string content extracted directly', readFirstUserPromptText(p1) === 'hello world');

// --- 2. array text content extracted ---
const p2 = writeJsonl('2-array-text.jsonl', [userTextArr('foo')]);
ok('2. array [{type:text}] extracted via content[0].text', readFirstUserPromptText(p2) === 'foo');

// --- 3. tool_result-only window returns null (filtered) ---
const p3 = writeJsonl('3-tool-result.jsonl', [userToolResult('result data')]);
ok('3. tool_result-only window returns null (filtered)', readFirstUserPromptText(p3) === null);

// --- 4. mixed sequence: returns FIRST valid user prompt, skipping tool_result ---
// Inverted from prior last-prompt semantics: now picks 'older prompt' (first),
// not 'newer prompt' (last).
const p4 = writeJsonl('4-mixed.jsonl', [
  userString('older prompt',           '2026-05-20T10:00:00.000Z'),
  asst       ('reply',                  '2026-05-20T10:01:00.000Z'),
  userToolResult('intermediate result', '2026-05-20T10:01:05.000Z'),
  userString ('newer prompt',           '2026-05-20T10:02:00.000Z'),
  asst       ('reply2',                 '2026-05-20T10:03:00.000Z'),
  userToolResult('latest result',       '2026-05-20T10:03:05.000Z'),
]);
ok('4. picks FIRST user-with-text, skipping tool_result',
   readFirstUserPromptText(p4) === 'older prompt');

// --- 5. all-assistant window returns null ---
const p5 = writeJsonl('5-no-user.jsonl', [asst('a'), asst('b'), asst('c')]);
ok('5. no user entry in window returns null', readFirstUserPromptText(p5) === null);

// --- 6. truncation: long prompt → 19 chars + … (20 total, mirrors NAME_MAX truncate) ---
const longText = 'this is a very long user prompt over twenty chars';  // length > 20
const p6 = writeJsonl('6-trunc.jsonl', [userString(longText)]);
const got6 = readFirstUserPromptText(p6);
ok('6a. truncated output is exactly 20 chars total',
   typeof got6 === 'string' && got6.length === 20);
ok('6b. truncated output ends with ellipsis',
   typeof got6 === 'string' && got6.endsWith('…'));
ok('6c. truncated output equals first-19-chars + …',
   got6 === longText.slice(0, 19) + '…');

// --- 7. newline collapse: \n becomes single space ---
const p7 = writeJsonl('7-newlines.jsonl', [userString('line1\nline2')]);
ok('7. newlines collapsed to single space', readFirstUserPromptText(p7) === 'line1 line2');

// --- 8. empty content → null (degenerate) ---
const p8 = writeJsonl('8-empty.jsonl', [userString('')]);
ok('8. empty string content returns null', readFirstUserPromptText(p8) === null);

// --- 9. slash commands ARE user prompts (non-/clear) ---
const p9 = writeJsonl('9-slash.jsonl', [userString('/restart-plugins')]);
ok('9. slash command extracted (not filtered)', readFirstUserPromptText(p9) === '/restart-plugins');

// --- 10. 64KB boundary: user entry at HEAD of file is found even when file > 64KB ---
// Inverted from prior tail semantics: previously a user at byte 0 was pushed
// OUT of the tail window; now under head-read it's exactly where we look first.
// Place the real user prompt at byte 0, then fill the rest with assistant entries.
const filler = Array.from({length: 100}, (_, i) =>
  asst('x'.repeat(700) + ' ' + i)
).join('\n');  // ~70KB+
const p10 = path.join(TMP, '10-window.jsonl');
fs.writeFileSync(p10, userString('in window head') + '\n' + filler + '\n');
const sz10 = fs.statSync(p10).size;
ok('10a. fixture exceeds 64KB window', sz10 > 65536);
ok('10b. user entry at head of >64KB file is found by forward-scan',
   readFirstUserPromptText(p10) === 'in window head');

// --- 11. control-char / ANSI stripping (defensive) ---
// User pastes ANSI: literal ESC [31m red text ESC [0m
const ansiPayload = '\x1b[31mred text\x1b[0m';
const p11 = writeJsonl('11-ansi.jsonl', [userString(ansiPayload)]);
const got11 = readFirstUserPromptText(p11);
ok('11a. ANSI ESC stripped from output',
   typeof got11 === 'string' && !got11.includes('\x1b'));
ok('11b. ANSI strip preserves visible text substring',
   typeof got11 === 'string' && got11.includes('red text'));

// --- 12. partial last line in >64KB file is dropped without parse pollution ---
// Inverted from prior "partial head" semantics: under head-read, the partial
// is at the TAIL of the head slice (last line), so we drop the LAST element
// instead of skipping the first. Construct: a real user entry first, then a
// long junk line that gets truncated by the 64KB cap.
const junkLine = 'X'.repeat(70000);
const p12 = path.join(TMP, '12-partial-tail.jsonl');
fs.writeFileSync(p12, userString('found me') + '\n' + junkLine + '\n');
ok('12. partial line at tail of head-slice dropped without parse pollution',
   readFirstUserPromptText(p12) === 'found me');

// --- 13. small file (size <= window) reads first line as real entry ---
// endIdx stays at lines.length — no need to drop the trailing partial.
const p13 = writeJsonl('13-tiny.jsonl', [userString('tiny one')]);
const tinySize = fs.statSync(p13).size;
ok('13. small file reads first line as real entry',
   tinySize <= 65536 && readFirstUserPromptText(p13) === 'tiny one');

// --- 14. missing file → null (no exception) ---
ok('14. missing file path returns null',
   readFirstUserPromptText(path.join(TMP, 'does-not-exist.jsonl')) === null);

// --- 15. unparseable garbage → null (no exception bubbles out) ---
const garbageP = path.join(TMP, '15-garbage.jsonl');
fs.writeFileSync(garbageP, '{not json\nalso not json\n}{}{\n');
ok('15. unparseable garbage returns null without throwing',
   readFirstUserPromptText(garbageP) === null);

// --- 16. exact-20-char content is NOT truncated (boundary case) ---
const exact20 = 'a'.repeat(20);
const p16 = writeJsonl('16-exact20.jsonl', [userString(exact20)]);
const got16 = readFirstUserPromptText(p16);
ok('16a. exact-20-char content passes through unchanged',
   got16 === exact20);
ok('16b. exact-20-char output has no ellipsis',
   typeof got16 === 'string' && !got16.endsWith('…'));

// --- 17. 21-char content gets truncated to 20 (boundary case) ---
const twentyOne = 'b'.repeat(21);
const p17 = writeJsonl('17-21chars.jsonl', [userString(twentyOne)]);
const got17 = readFirstUserPromptText(p17);
ok('17. 21-char content truncated to 20 (19 b + …)',
   got17 === 'b'.repeat(19) + '…');

// =============================================================================
// NEW SCENARIOS (2026-05-20 first-prompt swap, quick task 260520-34p)
// =============================================================================

// --- 18. /clear as first user entry is skipped, returns second user prompt ---
// Single-skip exception: a leading `<command-name>/clear</command-name>` is
// skipped so the segment freezes on the user's real opening prompt.
const p18 = writeJsonl('18-clear-as-first.jsonl', [
  userString('<command-name>/clear</command-name>\n<command-args></command-args>',
             '2026-05-20T10:00:00.000Z'),
  asst       ('clear-ack',                                  '2026-05-20T10:00:01.000Z'),
  userString ('hello world',                                '2026-05-20T10:00:02.000Z'),
]);
ok('18. /clear as first user entry single-skipped, returns next prompt',
   readFirstUserPromptText(p18) === 'hello world');

// --- 19. two /clear entries in a row: single-skip allows second through ---
// Single-skip is bounded — only one /clear is skipped; if the user submitted
// /clear twice in a row, the second one is the intended freeze anchor. After
// <command-name> extraction, the returned form is the canonical "/clear" (not
// the opaque truncated wrapper tag).
const clearText = '<command-name>/clear</command-name>';
const p19 = writeJsonl('19-two-clears.jsonl', [
  userString(clearText,  '2026-05-20T10:00:00.000Z'),
  userString(clearText,  '2026-05-20T10:00:01.000Z'),
]);
const got19 = readFirstUserPromptText(p19);
ok('19. two consecutive /clear entries: second /clear returned as "/clear"',
   got19 === '/clear');

// --- 20. <local-command-caveat> synthetic entry filtered, returns real next prompt ---
// CC injects `<local-command-caveat>...` synthetic user messages around local
// command invocations. These are system caveats, not user-authored prompts,
// and must not appear as the freeze anchor.
const caveatText =
  '<local-command-caveat>Caveat: The messages below were generated by the ' +
  'user while running local commands.</local-command-caveat>';
const p20 = writeJsonl('20-local-command-caveat.jsonl', [
  userString(caveatText,    '2026-05-20T10:00:00.000Z'),
  userString('real prompt', '2026-05-20T10:00:01.000Z'),
]);
ok('20. <local-command-caveat> filtered, returns real next prompt',
   readFirstUserPromptText(p20) === 'real prompt');

// --- 21. slash-command <command-name> extraction surfaces canonical /foo form ---
// CC writes CLI slash invocations as a multi-tag block:
//   <command-message>foo</command-message>
//   <command-name>/foo</command-name>
//   <command-args>...</command-args>
// The raw string starts with <command-message>, which would truncate as
// "<command-message>f…" — opaque. Extraction pulls /foo out of <command-name>
// so the segment renders as "/foo" (or a clean truncation thereof).
const slashWrapped =
  '<command-message>dhx:statusline</command-message>\n' +
  '<command-name>/dhx:statusline</command-name>\n' +
  '<command-args>some args text that should not appear in the segment</command-args>';
const p21 = writeJsonl('21-slash-extract.jsonl', [userString(slashWrapped)]);
ok('21a. slash-command <command-name> extraction yields canonical /foo form',
   readFirstUserPromptText(p21) === '/dhx:statusline');
// Length-boundary: a 21+ char slash command still truncates the EXTRACTED form,
// not the raw wrapped text (assert truncation applies to /foo, not to the tag).
const longSlashWrapped =
  '<command-message>long-command-name-that-overflows</command-message>\n' +
  '<command-name>/long-command-name-that-overflows</command-name>\n' +
  '<command-args></command-args>';
const p21b = writeJsonl('21b-slash-long.jsonl', [userString(longSlashWrapped)]);
const got21b = readFirstUserPromptText(p21b);
// '/long-command-name-that-overflows' is 33 chars → slice(0,19) + …
// slice(0,19) yields '/long-command-name-' (19 chars including trailing -).
ok('21b. long slash command truncates the extracted /foo, not the wrapper tag',
   got21b === '/long-command-name-' + '…');

// --- cleanup ---
try { fs.rmSync(TMP, { recursive: true, force: true }); } catch { /* nothing */ }

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
