// Probe: statusline-wrapper.js helper contracts.
//
// Locks: ccburn JSON → compact string transform, duration formatter,
// status-emoji mapping. These helpers own the visual contract the user
// reads every refresh ("S:🧊 9% (1h58m) · W:🚨 47% (3d)"). Prior design
// regex-munged ccburn's --compact text and could only surface what
// ccburn itself formatted; JSON-driven composition moved the format
// decisions into our code, so the probe has to pin them.
//
// Pairs with: docs/statusline-wrapper.md "ccburn compact" section,
// docs/decisions.md 2026-04-18 statusline-compaction row.

const path = require('path');
const WRAPPER = path.join(__dirname, '..', '..', 'dhx', 'statusline-wrapper.js');
const { buildCcburnSegment, formatBurnDuration, statusEmoji } = require(WRAPPER);

let pass = 0;
let fail = 0;

function ok(label, got, want) {
  if (got === want) { console.log(`OK   ${label}`); pass++; }
  else { console.log(`FAIL ${label}\n  got:  ${JSON.stringify(got)}\n  want: ${JSON.stringify(want)}`); fail++; }
}

// --- § 1 formatBurnDuration -------------------------------------------------
// Band boundaries: <1m → "<1m"; <60 → "Xm"; <360 → "XhXXm"; <1440 → "Xh"; ≥1440 → "Nd".

ok('duration: null → empty',           formatBurnDuration(null),      '');
ok('duration: undefined → empty',      formatBurnDuration(undefined), '');
ok('duration: negative → empty',       formatBurnDuration(-5),        '');
ok('duration: NaN → empty',            formatBurnDuration(NaN),       '');
ok('duration: 0.4 min → <1m',          formatBurnDuration(0.4),       '<1m');
ok('duration: 1 min',                  formatBurnDuration(1),         '1m');
ok('duration: 47 min',                 formatBurnDuration(47),        '47m');
ok('duration: 59.9 min (under hour)',  formatBurnDuration(59.9),      '59m');
ok('duration: 60 min (1h exact)',      formatBurnDuration(60),        '1h00m');
ok('duration: 118 min (1h58m)',        formatBurnDuration(118),       '1h58m');
ok('duration: 65 min (zero-pad guard)', formatBurnDuration(65),       '1h05m');
ok('duration: 359 min (just under 6h)', formatBurnDuration(359),      '5h59m');
ok('duration: 360 min (6h boundary)',  formatBurnDuration(360),       '6h');
ok('duration: 720 min (12h)',          formatBurnDuration(720),       '12h');
ok('duration: 1439 min (just under 1d)', formatBurnDuration(1439),    '23h');
ok('duration: 1440 min (1d)',          formatBurnDuration(1440),      '1d');
ok('duration: 4320 min (3d)',          formatBurnDuration(4320),      '3d');
ok('duration: 10080 min (7d)',         formatBurnDuration(10080),     '7d');

// --- § 2 statusEmoji --------------------------------------------------------
// INVARIANT: the mapped set is exactly ccburn's three emitted statuses
// (ccburn/utils/calculator.py:203 — the only producer). `at_pace` and
// `exhausted` from prior ccburn revisions no longer exist and must not be
// reintroduced without a matching producer.

ok('emoji: behind_pace',   statusEmoji('behind_pace'),   '🧊');
ok('emoji: on_pace',       statusEmoji('on_pace'),       '🟢');
ok('emoji: ahead_of_pace', statusEmoji('ahead_of_pace'), '🚨');
ok('emoji: unknown → empty', statusEmoji('approaching'), '');
ok('emoji: at_pace (retired) → empty', statusEmoji('at_pace'), '');
ok('emoji: exhausted (retired) → empty', statusEmoji('exhausted'), '');
ok('emoji: null → empty',    statusEmoji(null),          '');
ok('emoji: undefined → empty', statusEmoji(undefined),   '');

// --- § 3 buildCcburnSegment -------------------------------------------------

// Canonical live shape: session in minutes, weekly in hours.
const CANONICAL = JSON.stringify({
  limits: {
    session: {
      utilization: 0.09,
      status: 'behind_pace',
      resets_in_minutes: 118,
      resets_in_hours: null,
    },
    weekly: {
      utilization: 0.47,
      status: 'ahead_of_pace',
      resets_in_minutes: null,
      resets_in_hours: 72,
    },
  },
});
ok('ccburn: canonical session+weekly', buildCcburnSegment(CANONICAL),
   'S:🧊 9% (1h58m) · W:🚨 47% (3d)');

// Rounding: utilization 0.095 → 10% (half-up).
ok('ccburn: utilization rounds half-up',
   buildCcburnSegment(JSON.stringify({
     limits: { session: { utilization: 0.095, status: 'behind_pace', resets_in_minutes: 60 } },
   })),
   'S:🧊 10% (1h00m)');

// Hours fallback when minutes are null (long horizon): 2.5h → 2h30m.
ok('ccburn: hours fallback converts to minutes',
   buildCcburnSegment(JSON.stringify({
     limits: { session: { utilization: 0.5, status: 'on_pace', resets_in_hours: 2.5 } },
   })),
   'S:🟢 50% (2h30m)');

// No reset time at all → segment still renders pct + emoji, no parens.
ok('ccburn: missing resets → no duration',
   buildCcburnSegment(JSON.stringify({
     limits: { session: { utilization: 0.3, status: 'behind_pace' } },
   })),
   'S:🧊 30%');

// Unknown status → pct only (no stray emoji, no misleading icon).
ok('ccburn: unknown status → no emoji',
   buildCcburnSegment(JSON.stringify({
     limits: { session: { utilization: 0.2, status: 'mystery_state', resets_in_minutes: 30 } },
   })),
   'S:20% (30m)');

// Partial: weekly only renders when session is absent.
ok('ccburn: weekly-only',
   buildCcburnSegment(JSON.stringify({
     limits: { weekly: { utilization: 0.47, status: 'ahead_of_pace', resets_in_hours: 72 } },
   })),
   'W:🚨 47% (3d)');

// Partial: session only.
ok('ccburn: session-only',
   buildCcburnSegment(JSON.stringify({
     limits: { session: { utilization: 0.09, status: 'behind_pace', resets_in_minutes: 118 } },
   })),
   'S:🧊 9% (1h58m)');

// Empty / malformed / absent → empty string (segment hides).
ok('ccburn: empty string',           buildCcburnSegment(''),            '');
ok('ccburn: null',                   buildCcburnSegment(null),          '');
ok('ccburn: malformed JSON',         buildCcburnSegment('{not json'),   '');
ok('ccburn: no limits key',          buildCcburnSegment('{}'),          '');
ok('ccburn: empty limits object',    buildCcburnSegment('{"limits":{}}'), '');

// Utilization defaults to 0 when missing (edge of fresh session).
ok('ccburn: missing utilization → 0%',
   buildCcburnSegment(JSON.stringify({
     limits: { session: { status: 'behind_pace', resets_in_minutes: 300 } },
   })),
   'S:🧊 0% (5h00m)');

console.log();
console.log(`${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
