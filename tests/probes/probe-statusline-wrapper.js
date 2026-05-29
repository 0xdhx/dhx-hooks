// Probe: statusline-wrapper.js helper contracts.
//
// Locks the ccburn segment's stdin→line transform, the duration formatter, the
// pace classifier, and the meta-glyph. 2026-05-29 rewrite: the segment renders
// CC's stdin `rate_limits` directly (no ccburn subprocess, no cache, no
// `collect`), so the contract pinned here is the rate_limits→colored-line
// transform — pace = color, expired-side skip, ≥90% red override, fail-silent.
// These helpers own the visual contract the user reads every refresh
// ("62% (2h35m) · 41% (8h)", number colored by pace).
//
// Pairs with: docs/statusline-wrapper.md § ccburn segment,
// docs/decisions.md 2026-05-29 stdin-render row.

// SAFE_FOR_LIVE: yes   (pure require + helper function tests; no FS writes).
// Pins DHX_CCBURN_PALETTE='default' so colour assertions are deterministic
// regardless of the ambient palette env; assumes the default DHX_CCBURN_RED_AT (90).
const path = require('path');
const WRAPPER = path.join(__dirname, '..', '..', 'dhx', 'statusline-wrapper.js');
const { buildCcburnFromStdin, ccburnPace, ccburnResetSecs, formatBurnDuration, computeMetaGlyph } = require(WRAPPER);
// Pin palette to default + point the override-file at a nonexistent path so the
// colour assertions are deterministic regardless of the ambient env or any real
// ~/.config/dhx/ccburn-palette on this machine.
process.env.DHX_CCBURN_PALETTE_FILE = '/nonexistent/dhx-ccburn-palette';
process.env.DHX_CCBURN_PALETTE = 'default';

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

// --- § 2 ccburnResetSecs + ccburnPace ---------------------------------------
// resets_at accepts epoch-seconds OR an ISO string (CC has emitted both). Pace
// is reconstructed from utilization vs the fraction of the window elapsed —
// budgetPace = 1 - secsToReset/windowSecs. ≥ DHX_CCBURN_RED_AT (default 90%)
// short-circuits to 'ahead' so a near-empty limit never reads calm.

ok('resetSecs: epoch number passthrough', ccburnResetSecs(1780000000), 1780000000);
ok('resetSecs: ISO string → epoch secs',  ccburnResetSecs('2026-05-29T08:20:00Z'),
   Math.floor(Date.parse('2026-05-29T08:20:00Z') / 1000));
ok('resetSecs: garbage string → null',    ccburnResetSecs('not-a-date'), null);
ok('resetSecs: null → null',              ccburnResetSecs(null), null);
ok('resetSecs: NaN → null',               ccburnResetSecs(NaN), null);

// windowSecs 18000 (5h), secsToReset 9000 → budgetPace 0.5, tol ±0.05.
ok('pace: under clock → behind',          ccburnPace(0.10, 9000, 18000), 'behind');
ok('pace: at clock → on',                 ccburnPace(0.50, 9000, 18000), 'on');
ok('pace: within +tol → on',              ccburnPace(0.54, 9000, 18000), 'on');
ok('pace: over clock → ahead',            ccburnPace(0.80, 9000, 18000), 'ahead');
// 95% util with budgetPace 0.95 would be 'on' by pace alone — override forces 'ahead'.
ok('pace: ≥90% override beats on-pace',   ccburnPace(0.95, 900, 18000), 'ahead');
ok('pace: degenerate window → on',        ccburnPace(0.5, 100, 0), 'on');

// --- § 3 buildCcburnFromStdin -----------------------------------------------
// Default palette: behind = cyan (36), on = dim (2), ahead = red (31). Number
// coloured by pace; duration always dim. nowSecs injected for determinism.
const NOW = 1780000000;
const CY = '\x1b[36m', RD = '\x1b[31m', DM = '\x1b[2m', RS = '\x1b[0m';

// five_hour 62%, 9300s left (2h35m), 5h window → budgetPace .483, util .62 → ahead (red).
// seven_day 41%, 28800s left (8h), 7d window → budgetPace .952, util .41 → behind (cyan).
ok('stdin: canonical session+weekly',
   buildCcburnFromStdin(JSON.stringify({ rate_limits: {
     five_hour: { used_percentage: 62, resets_at: NOW + 9300 },
     seven_day: { used_percentage: 41, resets_at: NOW + 28800 },
   }}), NOW),
   `${RD}62%${RS} ${DM}(2h35m)${RS} ${DM}·${RS} ${CY}41%${RS} ${DM}(8h)${RS}`);

// Expired session side (resets_at in the past) → skipped; weekly renders alone.
// This is the cross-profile "stale 100%" guard — never show a window-expired side.
ok('stdin: expired session side skipped',
   buildCcburnFromStdin(JSON.stringify({ rate_limits: {
     five_hour: { used_percentage: 100, resets_at: NOW - 100 },
     seven_day: { used_percentage: 41, resets_at: NOW + 28800 },
   }}), NOW),
   `${CY}41%${RS} ${DM}(8h)${RS}`);

// ≥90% override → red even where pace (budgetPace .95, util .95) would be 'on'.
ok('stdin: ≥90% override → red',
   buildCcburnFromStdin(JSON.stringify({ rate_limits: {
     five_hour: { used_percentage: 95, resets_at: NOW + 900 },
   }}), NOW),
   `${RD}95%${RS} ${DM}(15m)${RS}`);

// ISO resets_at string tolerated (forward-compat).
ok('stdin: ISO resets_at string',
   buildCcburnFromStdin(JSON.stringify({ rate_limits: {
     five_hour: { used_percentage: 30, resets_at: new Date((NOW + 9300) * 1000).toISOString() },
   }}), NOW),
   `${CY}30%${RS} ${DM}(2h35m)${RS}`);

// Rounding: 61.6 → 62%.
ok('stdin: used_percentage rounds',
   buildCcburnFromStdin(JSON.stringify({ rate_limits: {
     seven_day: { used_percentage: 61.6, resets_at: NOW + 28800 },
   }}), NOW),
   `${CY}62%${RS} ${DM}(8h)${RS}`);

// Fail-silent: missing / malformed / fully-expired → '' (segment hides).
ok('stdin: no rate_limits → empty',        buildCcburnFromStdin('{}', NOW), '');
ok('stdin: malformed JSON → empty',        buildCcburnFromStdin('{not json', NOW), '');
ok('stdin: null → empty',                  buildCcburnFromStdin(null, NOW), '');
ok('stdin: both sides expired → empty',
   buildCcburnFromStdin(JSON.stringify({ rate_limits: {
     five_hour: { used_percentage: 50, resets_at: NOW - 1 },
   }}), NOW), '');
ok('stdin: non-numeric used_percentage skipped → empty',
   buildCcburnFromStdin(JSON.stringify({ rate_limits: {
     five_hour: { used_percentage: 'x', resets_at: NOW + 9300 },
   }}), NOW), '');

// --- § 4 computeMetaGlyph (2026-04-26 #2b additive meta-glyph) -------------
// Aggregates {driftWarning, healthFront, healthTail, sigilCount} into a single
// leftmost glyph: dim green ∙ (color 70) when ALL inputs clean, bright yellow
// ⌃ (220) when ANY fires. Purely additive — does not replace existing front
// composition. Color non-collision: 70/220 distinct from critical 208 and
// advisory red 31. Probe pinned in tests/probes/probe-statusline-wrapper.js
// per docs/decisions.md 2026-04-26 meta-glyph row (hairline glyphs locked
// 2026-04-26 — see same-day "meta-glyph hairline glyphs" decisions row).

const GREEN_DOT  = '\x1b[2;38;5;70m∙\x1b[0m';
const YELLOW_TRI = '\x1b[38;5;220m⌃\x1b[0m';

ok('meta-glyph: all clear → dim green ∙',         computeMetaGlyph('', '', '', 0),                       GREEN_DOT);
ok('meta-glyph: drift fires → yellow ⌃',          computeMetaGlyph('drift-text', '', '', 0),             YELLOW_TRI);
ok('meta-glyph: critical fires → yellow ⌃',       computeMetaGlyph('', 'critical-text', '', 0),          YELLOW_TRI);
ok('meta-glyph: advisory fires → yellow ⌃',       computeMetaGlyph('', '', 'advisory-text', 0),          YELLOW_TRI);
ok('meta-glyph: 1 sigil → yellow ⌃',              computeMetaGlyph('', '', '', 1),                       YELLOW_TRI);
ok('meta-glyph: many sigils → yellow ⌃',          computeMetaGlyph('', '', '', 6),                       YELLOW_TRI);
ok('meta-glyph: mixed (drift+crit+adv+sigil) → yellow ⌃',
   computeMetaGlyph('drift', 'crit', 'adv', 2), YELLOW_TRI);
ok('meta-glyph: null inputs → dim green ∙ (!! coerces)',
   computeMetaGlyph(null, null, null, 0), GREEN_DOT);
ok('meta-glyph: undefined inputs → dim green ∙',  computeMetaGlyph(undefined, undefined, undefined, 0),  GREEN_DOT);
// Edge: sigilCount = 0 falsy. 0 → dim green ∙.
ok('meta-glyph: sigilCount = 0 (zero is falsy) → dim green ∙', computeMetaGlyph('', '', '', 0), GREEN_DOT);

console.log();
console.log(`${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
