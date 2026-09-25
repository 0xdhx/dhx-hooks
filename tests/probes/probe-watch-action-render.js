#!/usr/bin/env node
// probe-watch-action-render.js — exercises the AWAITING-US ACTION INBOX section
// of dhx/dhx-watch-digest.sh (the SessionStart banner). The action section is a
// READ-ONLY, FAIL-SILENT consumer of the cross-repo Phase-21 action-state surface
// in watchlist.json (producer: scripts/watch/dhx-watch-check.cjs computes
// action_state; dhx-watch-driver.cjs writes ack/snooze). It is DISTINCT from the
// Phase-20 12-key health cache (D-05) and from the edge-triggered digest delta block.
//
// What this proves (the grep-can't-give-it behavioral proof, D-25):
//   1. TWO-SESSION RENDER — the section is LEVEL-triggered: an awaiting_us non-snoozed
//      item renders in BOTH consecutive SessionStart runs (it persists until ack/snooze
//      clears it), unlike an edge-triggered delta that fires once and is gone.
//   2. FILTER CONTRACT across snooze_until — the D-13 DEFENSIVE parse:
//        null / missing / expired-ISO / malformed  -> RENDER (banner never throws)
//        future-ISO / "perma"                       -> HIDE
//      and WR-04: status != "active" HIDES even when action_state == "awaiting_us"
//      (action_state is not re-cleared on status change).
//   3. GATE TAG — a tag:"gate" awaiting_us non-snoozed item still renders (the banner
//      is a renderer; the gate-confirm guard lives in the driver/skill, not here).
//   4. FAIL-SILENT — absent / empty / non-JSON watchlist renders nothing + exits 0.
//   5. NOT BARE IDS — each rendered item carries the copy-ready ack/snooze shortcuts.
//   6. POLL-AGE SUFFIX — a parseable last_checked_at renders "· polled Xh ago" /
//      "Xm ago" (ms-precision ISO exercised — the producer's real format, which
//      needs the fractional-second strip before fromdateiso8601); a missing or
//      malformed last_checked_at renders the row BARE (fail-silent, never throws).
//   7. UPSTREAM-STATE EXCLUSION (Gap 7 / AC9) — WR-04's upstream twin. An item whose
//      last_seen_state is "closed" or "merged" HIDES even while its stored action_state
//      still reads awaiting_us; "open" and a never-polled item (field absent) RENDER.
//      The banner is level-triggered on the STORED action_state, which the checker only
//      recomputes to `resolved` on that item's next due poll -- so without this clause a
//      closed-upstream item demands action for up to cadence_hours (24h). Both selects
//      (count + rows) carry the clause, asserted together so divergence is caught.
//
// Backs docs/decisions.md 2026-05-28 watch action-required banner-consumer row
// + the 2026-09-04 Gap 7 / AC9 row.
// Hermetic: each spawn points DHX_WATCH_DIR at a throwaway mktemp dir holding only a
// fixtured watchlist.json, and DHX_WATCH_HEALTH_CACHE at a nonexistent path — so the
// banner reads ONLY the fixture (no live ~/repos/cross-repo/watch, no live health
// cache, no digest/pointer). The only write the banner can make (pointer.txt) requires
// surfaced digest events; there is no digest, so nothing is written anywhere.
// Run: node tests/probes/probe-watch-action-render.js
//
// SAFE_FOR_LIVE: yes   (mktemp watch dir + DHX_WATCH_DIR/DHX_WATCH_HEALTH_CACHE env
//                       overrides; reads only the fixture, never live state)
const { spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const BANNER = path.resolve(__dirname, '..', '..', 'dhx', 'dhx-watch-digest.sh');
const SECTION = 'Action required'; // unique header substring
const j = (o) => JSON.stringify(o);
const FUTURE = () => new Date(Date.now() + 8 * 3600 * 1000).toISOString(); // still snoozed
const EXPIRED = () => new Date(Date.now() - 8 * 3600 * 1000).toISOString(); // snooze elapsed

// Run the banner against a watchlist.json holding `items` (or, if `raw` is a string,
// that literal file content — for the non-JSON / empty cases). Returns {stdout, status}.
function runBanner(items, raw) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'dhx-watch-action-probe-'));
  try {
    const content = raw !== undefined ? raw : j({ schema_version: 1, items });
    fs.writeFileSync(path.join(tmp, 'watchlist.json'), content);
    const res = spawnSync('bash', [BANNER], {
      input: '',
      env: {
        ...process.env,
        DHX_WATCH_DIR: tmp,
        DHX_WATCH_HEALTH_CACHE: path.join(tmp, 'no-health-cache.json'), // guaranteed absent
      },
      encoding: 'utf8',
      timeout: 5000,
    });
    return { stdout: res.stdout || '', status: res.status };
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

// A canonical awaiting_us, never-snoozed, active item.
const item = (over) => Object.assign({
  id: 'o-r-1', url: 'https://github.com/o/r/issues/1', tag: 'claude-code',
  status: 'active', action_state: 'awaiting_us', snooze_until: null,
  last_seen_labels: ['bug', 'area:core'],
}, over || {});

let pass = 0, fail = 0;
function check(name, cond, detail) {
  if (cond) { console.log(`OK   ${name}`); pass++; }
  else { console.log(`FAIL ${name}`); if (detail) console.log(`      ${detail}`); fail++; }
}

// ── (1) TWO-SESSION RENDER — level-triggered persistence across consecutive runs ──
{
  const items = [item({ id: 'persist-1' })];
  const r1 = runBanner(items);
  const r2 = runBanner(items); // same fixture, second session
  check('(1) session-1 renders Action required section', r1.stdout.includes(SECTION), `s1=${j(r1.stdout)}`);
  check('(1) session-1 renders the awaiting_us item', r1.stdout.includes('persist-1'), `s1=${j(r1.stdout)}`);
  check('(1) session-2 STILL renders it (level-triggered, not edge)',
    r2.stdout.includes(SECTION) && r2.stdout.includes('persist-1'), `s2=${j(r2.stdout)}`);
  check('(1) both sessions exit 0', r1.status === 0 && r2.status === 0, `s1=${r1.status} s2=${r2.status}`);
}

// ── (2) FILTER CONTRACT — every snooze_until disposition + WR-04 status clause ──
const RENDER_CASES = [
  { name: 'null snooze_until',     over: { id: 'render-null', snooze_until: null } },
  { name: 'missing snooze_until',  over: { id: 'render-missing' }, drop: ['snooze_until'] },
  { name: 'expired ISO',           over: { id: 'render-expired', snooze_until: EXPIRED() } },
  { name: 'malformed snooze_until', over: { id: 'render-malformed', snooze_until: 'not-a-date' } },
];
const HIDE_CASES = [
  { name: 'future ISO (still snoozed)', over: { id: 'hide-future', snooze_until: FUTURE() } },
  { name: '"perma" snooze',             over: { id: 'hide-perma', snooze_until: 'perma' } },
  { name: 'awaiting_them (not us)',     over: { id: 'hide-them', action_state: 'awaiting_them' } },
  { name: 'WR-04 status=closed',        over: { id: 'hide-closed', status: 'closed' } },
];
function build(spec) {
  const it = item(spec.over);
  for (const k of (spec.drop || [])) delete it[k];
  return it;
}
for (const c of RENDER_CASES) {
  const r = runBanner([build(c)]);
  check(`(2) RENDER: ${c.name}`,
    r.status === 0 && r.stdout.includes(SECTION) && r.stdout.includes(c.over.id),
    `status=${r.status} out=${j(r.stdout)}`);
}
for (const c of HIDE_CASES) {
  const r = runBanner([build(c)]);
  check(`(2) HIDE: ${c.name}`,
    r.status === 0 && !r.stdout.includes(c.over.id),
    `status=${r.status} out=${j(r.stdout)}`);
}
// Combined fixture: 4 render + 4 hide → count is exactly 4, no hidden id leaks.
{
  const items = [...RENDER_CASES, ...HIDE_CASES].map(build);
  const r = runBanner(items);
  check('(2) combined: header reports count 4', r.stdout.includes('Action required (4)'), `out=${j(r.stdout)}`);
  check('(2) combined: all 4 render ids present',
    RENDER_CASES.every((c) => r.stdout.includes(c.over.id)), `out=${j(r.stdout)}`);
  check('(2) combined: no hide id leaks',
    HIDE_CASES.every((c) => !r.stdout.includes(c.over.id)), `out=${j(r.stdout)}`);
  check('(2) combined: banner does not throw', r.status === 0, `status=${r.status}`);
}

// ── (3) GATE TAG — gate-tagged awaiting_us non-snoozed item still renders ──
{
  const r = runBanner([item({ id: 'gate-item', tag: 'gate' })]);
  check('(3) gate-tagged item renders (banner is a renderer, not the gate-confirm guard)',
    r.stdout.includes(SECTION) && r.stdout.includes('gate-item'), `out=${j(r.stdout)}`);
}

// ── (4) FAIL-SILENT — absent / empty / non-JSON watchlist → silent + exit 0 ──
const SILENT_CASES = [
  { name: 'no items (empty array)', items: [] },
  { name: 'non-JSON garbage', raw: 'not json at all {{{' },
  { name: 'empty file', raw: '' },
  { name: 'object missing items', raw: j({ schema_version: 1 }) },
];
for (const c of SILENT_CASES) {
  const r = runBanner(c.items, c.raw);
  check(`(4) fail-silent: ${c.name} → no section + exit 0`,
    r.status === 0 && !r.stdout.includes(SECTION),
    `status=${r.status} out=${j(r.stdout)}`);
}

// ── (5) NOT BARE IDS — rendered item carries copy-ready ack + snooze shortcuts ──
{
  const r = runBanner([item({ id: 'shortcut-1' })]);
  check('(5) renders copy-ready ack shortcut', r.stdout.includes('ack shortcut-1'), `out=${j(r.stdout)}`);
  check('(5) renders copy-ready snooze shortcut', r.stdout.includes('snooze shortcut-1 8h'), `out=${j(r.stdout)}`);
  check('(5) renders the url (openable identity)',
    r.stdout.includes('https://github.com/o/r/issues/1'), `out=${j(r.stdout)}`);
}

// ── (6) POLL-AGE SUFFIX — last_checked_at freshness age, D-13 fail-silent ──
{
  // 9h ago, ms-precision ISO (toISOString) — the producer's real format; proves the
  // fractional-second strip works (without it, fromdateiso8601 throws on every real
  // timestamp and the suffix never renders).
  const nineH = new Date(Date.now() - 9 * 3600 * 1000).toISOString();
  const rH = runBanner([item({ id: 'age-hours', last_checked_at: nineH })]);
  check('(6) renders hour-granularity poll age (ms-precision ISO parsed)',
    rH.stdout.includes('· polled 9h ago'), `out=${j(rH.stdout)}`);

  // 12m ago → minute granularity below the 1h threshold.
  const twelveM = new Date(Date.now() - 12 * 60 * 1000).toISOString();
  const rM = runBanner([item({ id: 'age-minutes', last_checked_at: twelveM })]);
  check('(6) renders minute-granularity poll age under 1h',
    rM.stdout.includes('· polled 12m ago'), `out=${j(rM.stdout)}`);

  // Missing field → row renders bare, no suffix (fail-silent leg).
  const rNone = runBanner([item({ id: 'age-absent' })]);
  check('(6) missing last_checked_at → row renders bare (no "polled")',
    rNone.status === 0 && rNone.stdout.includes('age-absent') && !rNone.stdout.includes('polled'),
    `status=${rNone.status} out=${j(rNone.stdout)}`);

  // Malformed field → same bare render, banner never throws.
  const rBad = runBanner([item({ id: 'age-malformed', last_checked_at: 'not-a-date' })]);
  check('(6) malformed last_checked_at → row renders bare + exit 0',
    rBad.status === 0 && rBad.stdout.includes('age-malformed') && !rBad.stdout.includes('polled'),
    `status=${rBad.status} out=${j(rBad.stdout)}`);
}

// ── (7) UPSTREAM-STATE EXCLUSION (Gap 7 / AC9) — closed/merged never demand action ──
// Negative control: every HIDE case below FAILS against the pre-Gap-7 selects (measured
// 2026-09-04 — a 3-item fixture counted 3, of which only 1 was actionable). The RENDER
// cases pass both before and after; they are the guard that the clause did not become a
// blanket suppression, and the never-polled case pins the jq null-safety (`null != "closed"`
// is true, so an item the checker has never reached still surfaces).
const UPSTREAM_HIDE = [
  { name: 'last_seen_state=closed (the #2140 shape)', over: { id: 'up-closed', last_seen_state: 'closed' } },
  { name: 'last_seen_state=merged',                   over: { id: 'up-merged', last_seen_state: 'merged' } },
];
const UPSTREAM_RENDER = [
  { name: 'last_seen_state=open',            over: { id: 'up-open', last_seen_state: 'open' } },
  { name: 'last_seen_state absent (never polled)', over: { id: 'up-unpolled' } },
];
for (const c of UPSTREAM_HIDE) {
  const r = runBanner([build(c)]);
  check(`(7) HIDE: ${c.name}`,
    r.status === 0 && !r.stdout.includes(c.over.id) && !r.stdout.includes(SECTION),
    `status=${r.status} out=${j(r.stdout)}`);
}
for (const c of UPSTREAM_RENDER) {
  const r = runBanner([build(c)]);
  check(`(7) RENDER: ${c.name}`,
    r.status === 0 && r.stdout.includes(SECTION) && r.stdout.includes(c.over.id),
    `status=${r.status} out=${j(r.stdout)}`);
}
// Combined: the COUNT select and the ROWS select must agree. A clause added to only one
// would show here as a header count that does not match the rows rendered beneath it.
{
  const items = [...UPSTREAM_HIDE, ...UPSTREAM_RENDER].map(build);
  const r = runBanner(items);
  check('(7) combined: header count is 2 (count select carries the clause)',
    r.stdout.includes('Action required (2)'), `out=${j(r.stdout)}`);
  check('(7) combined: exactly the 2 render ids appear (rows select carries it too)',
    UPSTREAM_RENDER.every((c) => r.stdout.includes(c.over.id))
      && UPSTREAM_HIDE.every((c) => !r.stdout.includes(c.over.id)), `out=${j(r.stdout)}`);
  check('(7) combined: banner does not throw', r.status === 0, `status=${r.status}`);
}

// ── (8) PR-READY BLOCK (AC7 / Gap 5) — the two blocks PARTITION ──────────────────────
// The criterion: an approval label must produce a signal meaning "this issue is now eligible for
// OUR PR", DISTINCT from awaiting_us ("they need a reply from us"). Producer: cross-repo's checker
// derives `pr_eligible` level-triggered from current labels. This surfacer is a read-only consumer.
//
// Two clauses, both load-bearing, asserted separately below:
//   · pr_eligible                    — membership in the new block
//   · last_seen_open_closing_pr      — EXCLUDES an issue whose fix is already in flight. Without it
//                                      the block rendered 16 rows on live data, 13 already PR'd.
//
// The partition assertion is the one that matters. Action-required excludes EXACTLY this block's
// membership test, so no item can render in both AND — the trap this guards — no item can fall
// through BOTH. An approved item that also has an in-flight PR and a genuine maintainer question
// must stay in Action required; a naive `.pr_eligible != true` exclusion would vanish it entirely.
const PR_SECTION = 'Ready for your PR';
// Section-scoped fixture: the PR-ready rows render `.url` (the action rows render `.id` in their
// shortcut), so two eligible items sharing the helper's constant url render byte-identically and
// nothing downstream can tell them apart. Overriding url HERE keeps that need local — an earlier
// attempt to derive url from id in the shared helper above broke case (5), which asserts the
// literal constant url. Shared fixture semantics are load-bearing for the 35 assertions above it.
const prItem = (over) => item(Object.assign({ url: `https://github.com/o/r/issues/${over.id}` }, over));
{
  // Eligible, no in-flight PR → PR block, and OUT of Action required.
  const r = runBanner([prItem({ id: 'prready-1', pr_eligible: true })]);
  check('(8) eligible item renders in the PR-ready block',
    r.stdout.includes(PR_SECTION) && r.stdout.includes('prready-1'), `out=${j(r.stdout)}`);
  check('(8) ...and is NOT also in Action required (blocks are exclusive)',
    !r.stdout.includes(SECTION), `out=${j(r.stdout)}`);
  check('(8) PR-ready row offers the pr verb, never ack (ack sets awaiting_them — the burying bug)',
    r.stdout.includes('/dhx:upstream pr') && !r.stdout.includes('ack prready-1'), `out=${j(r.stdout)}`);
  check('(8) banner does not throw', r.status === 0, `status=${r.status}`);
}
{
  // THE NO-VANISH CASE. Eligible AND a closing PR already open AND awaiting_us: excluded from the
  // PR block by the closing-PR clause, so it MUST remain in Action required. If this row ever goes
  // red, the Action-required exclusion has been widened to bare `.pr_eligible` and this item is
  // rendering nowhere at all.
  const r = runBanner([prItem({ id: 'novanish-1', pr_eligible: true, last_seen_open_closing_pr: true })]);
  check('(8) eligible + in-flight PR is EXCLUDED from the PR-ready block',
    !r.stdout.includes('Ready for your PR (1)'), `out=${j(r.stdout)}`);
  check('(8) NO-VANISH: it stays in Action required rather than disappearing from both',
    r.stdout.includes(SECTION) && r.stdout.includes('novanish-1'), `out=${j(r.stdout)}`);
}
{
  // A snoozed eligible item hides — the snooze clause is carried here byte-identically with the
  // action pair, so silencing works on these rows even though the row does not advertise the verb.
  const r = runBanner([prItem({ id: 'prsnooze-1', pr_eligible: true, snooze_until: FUTURE() })]);
  check('(8) snoozed eligible item hides from the PR-ready block',
    !r.stdout.includes('prsnooze-1'), `out=${j(r.stdout)}`);
}
{
  // Non-eligible items are untouched — the clause must be null-safe, not merely correct on `true`.
  const cases = [
    { name: 'pr_eligible absent', over: { id: 'noel-absent' } },
    { name: 'pr_eligible false',  over: { id: 'noel-false', pr_eligible: false } },
    { name: 'pr_eligible null',   over: { id: 'noel-null', pr_eligible: null } },
  ];
  for (const c of cases) {
    const r = runBanner([prItem(c.over)]);
    check(`(8) unchanged for ${c.name}: still Action required, not PR-ready`,
      r.stdout.includes(SECTION) && r.stdout.includes(c.over.id) && !r.stdout.includes(PR_SECTION),
      `out=${j(r.stdout)}`);
  }
}
{
  // Combined: count and rows selects must agree, exactly as section (7) asserts for the action pair.
  // A clause added to only one select shows up here as a header count that contradicts the rows.
  const items = [
    prItem({ id: 'mix-eligible-a', pr_eligible: true }),
    prItem({ id: 'mix-eligible-b', pr_eligible: true }),
    prItem({ id: 'mix-inflight', pr_eligible: true, last_seen_open_closing_pr: true }),
    prItem({ id: 'mix-plain' }),
  ];
  const r = runBanner(items);
  check('(8) combined: PR-ready header count is 2 (count select carries both clauses)',
    r.stdout.includes('Ready for your PR (2)'), `out=${j(r.stdout)}`);
  check('(8) combined: exactly the 2 eligible ids appear under it (rows select agrees)',
    r.stdout.includes('mix-eligible-a') && r.stdout.includes('mix-eligible-b'), `out=${j(r.stdout)}`);
  check('(8) combined: Action required count is 2 (the in-flight + the plain item)',
    r.stdout.includes('Action required (2)'), `out=${j(r.stdout)}`);
  // Membership, not occurrence count: an id appears TWICE inside its own row (once in the url, once
  // in the shortcut argument), so counting raw substrings measures row shape rather than placement.
  // Split at the PR header and ask which side each id landed on — exactly one, never both, never none.
  const [actionHalf, prHalf] = r.stdout.split(PR_SECTION);
  check('(8) combined: every item renders in exactly one block — none lost, none doubled',
    items.every((it) => (actionHalf.includes(it.id) ? 1 : 0) + ((prHalf || '').includes(it.id) ? 1 : 0) === 1),
    `out=${j(r.stdout)}`);
  check('(8) combined: banner does not throw', r.status === 0, `status=${r.status}`);
}
{
  // Silent-on-no-deltas: a session whose ONLY output is the PR-ready block must still emit it. The
  // early-exit guard lists every section by name, and a block omitted from it is swallowed entirely —
  // the failure is silent, which is why it is pinned rather than inferred.
  const r = runBanner([prItem({ id: 'onlyblock-1', pr_eligible: true, action_state: 'awaiting_them' })]);
  check('(8) PR-ready block survives the silent-on-no-deltas guard as the sole output',
    r.stdout.includes(PR_SECTION) && r.stdout.includes('onlyblock-1'), `out=${j(r.stdout)}`);
  check('(8) ...and it renders independently of action_state (ack no longer buries it)',
    !r.stdout.includes(SECTION), `out=${j(r.stdout)}`);
}

// ── (9) ORIGIN-REPORT CONTEXT LINE (v2.6 Signals R1, 2026-09-25) ──
// The checker stamps origin_report {path, linked_at} — the report whose **Watchlist:** line filed
// the item. Both ask-blocks render it as ONE context sub-line between the row and its `›` command,
// only when .origin_report.path is a non-empty string. Context only: membership, counts and the `›`
// line are byte-identical with or without it. Fail-silent on a malformed pointer (never a throw —
// a jq error here would blank the WHOLE block, not just the line).
{
  // Undated fixture names on purpose: scripts/sync-public-mirror.sh refuses to publish a dated
  // reports/<date>-<slug>.md path on a code line (it reads as a private report reference).
  const LINK = { path: 'reports/origin-x.md', linked_at: '2026-09-24T00:00:00.000Z' };
  const CTX = (p) => `\n      ↳ from ${p}\n      › `;
  const r = runBanner([
    prItem({ id: 'orl-ready', pr_eligible: true, origin_report: LINK }),
    item({ id: 'orl-action', url: 'https://github.com/o/r/issues/77', origin_report: { ...LINK, path: 'reports/done/origin-y.md' } }),
    prItem({ id: 'orl-bare-ready', pr_eligible: true, origin_report: null }),
    item({ id: 'orl-bare-action', url: 'https://github.com/o/r/issues/78' }),
  ]);
  const [actionHalf, prHalf] = r.stdout.split(PR_SECTION);
  check('(9) a linked Ready row carries "↳ from <path>" directly above its › line',
    (prHalf || '').includes(`issues/orl-ready${CTX('reports/origin-x.md')}/dhx:upstream pr https://github.com/o/r/issues/orl-ready`),
    `out=${j(r.stdout)}`);
  check('(9) a linked Action row carries "↳ from <path>" (reports/done/ path as stored)',
    actionHalf.includes(`issues/77${CTX('reports/done/origin-y.md')}/dhx:watch ack orl-action`), `out=${j(r.stdout)}`);
  check('(9) exactly two context lines — unlinked rows (null / absent) render none',
    (r.stdout.match(/↳ from /g) || []).length === 2, `out=${j(r.stdout)}`);
  check('(9) unlinked rows keep the bare row → › shape',
    (prHalf || '').includes('issues/orl-bare-ready\n      › /dhx:upstream pr ')
      && actionHalf.includes('issues/78\n      › /dhx:watch ack orl-bare-action'), `out=${j(r.stdout)}`);
  check('(9) context line never moves counts (Action 2, Ready 2)',
    r.stdout.includes('Action required (2)') && r.stdout.includes('Ready for your PR (2)'), `out=${j(r.stdout)}`);
}
{
  // Malformed pointers the validator would refuse, if a hand edit ever landed one: the row still
  // renders, bare. A throwing clause would silently empty the whole block instead.
  const bad = [
    { id: 'orl-str', origin_report: 'reports/x.md' },
    { id: 'orl-nopath', origin_report: { linked_at: '2026-09-24T00:00:00Z' } },
    { id: 'orl-numpath', origin_report: { path: 7 } },
    { id: 'orl-empty', origin_report: { path: '' } },
  ];
  const r = runBanner(bad.map((o) => prItem({ ...o, pr_eligible: true })));
  check('(9) malformed origin_report: every row still renders, none with a context line',
    bad.every((o) => r.stdout.includes(`/dhx:watch snooze ${o.id} 8h`)) && !r.stdout.includes('↳'),
    `out=${j(r.stdout)}`);
  check('(9) malformed origin_report: banner exits 0', r.status === 0, `status=${r.status}`);
}

// ── (10) ROW TAG = getTags(item)[0] || 'untagged' (2026-09-25) ──
// The row programs read the legacy single `.tag` alone, so every tags[]-only item rendered a BLANK
// tag slot (live: gsd-core #4936). primary_tag mirrors cross-repo dhx-watch-shared.cjs getTags rule
// for rule — an ARRAY tags wins even when empty; members trimmed, lowercased, non-strings and blanks
// dropped; else a non-empty string tag; else 'untagged' (the checker's digest-event tag fallback).
{
  const cases = [
    { id: 'tg-array',   over: { tags: ['gsd', 'gsd-core'] },                 want: 'gsd' },
    { id: 'tg-messy',   over: { tags: [7, '  ', ' GSD-Core '] },             want: 'gsd-core' },
    { id: 'tg-legacy',  over: { tag: 'claude-code' },                        want: 'claude-code' },
    { id: 'tg-emptyarr', over: { tags: [], tag: 'ignored-legacy' },          want: 'untagged' },
    { id: 'tg-none',    over: {}, drop: ['tag'],                             want: 'untagged' },
  ];
  const mk = (c, extra) => { const o = item(Object.assign({ id: c.id, url: `https://github.com/o/r/issues/${c.id}` }, c.over, extra));
    for (const k of c.drop || []) delete o[k]; if (!('tag' in c.over)) delete o.tag; return o; };
  const r = runBanner(cases.map((c) => mk(c)).concat(cases.map((c) => mk({ ...c, id: `${c.id}-pr` }, { pr_eligible: true }))));
  for (const c of cases) {
    for (const id of [c.id, `${c.id}-pr`]) {
      check(`(10) ${id}: row leads with tag "${c.want}"`,
        r.stdout.includes(`\n    ${c.want} · bug, area:core · https://github.com/o/r/issues/${id}`), `out=${j(r.stdout)}`);
    }
  }
  check('(10) no row renders a blank tag slot', !/\n     · /.test(r.stdout), `out=${j(r.stdout)}`);
  check('(10) both blocks still count every row (5 + 5)',
    r.stdout.includes('Action required (5)') && r.stdout.includes('Ready for your PR (5)'), `out=${j(r.stdout)}`);
}

console.log('');
console.log(`${pass} passed, ${fail} failed`);
process.exit(fail);
