#!/bin/bash
# SAFE_FOR_LIVE: yes   (mktemp fixture trees; node -e require of the live wrapper checkDrift/scanRecursive/enumerateNovelPatterns + classifyEntry under HOME + CLAUDE_CONFIG_DIR overrides; never reads live ~/.claude or ~/.cache/dhx)
#
# probe-drift-allowlist.sh — Phase 18 DRIFT-ALLOW-03 three-state boundary probe.
#
# Asserts the denylist -> allowlist inversion's runtime contract on the
# `plugins/cache` drift detector in dhx/statusline-wrapper.js. The detector now
# fires `⚠ restart plugins` ONLY on `content`-classified changes; `bookkeeping`
# changes are silent; `novel` files are excluded from drift and routed to the
# Phase 17 `⚠ cc-novel` detector (enumerateNovelPatterns). Backs 18-03-PLAN.md
# Task 1 and CONTEXT.md D-09 / D-17 / D-18 / D-20 / D-21 / D-22 / D-24a / D-28.
#
# Run: bash tests/probes/probe-drift-allowlist.sh   (D-28b — `.sh` => bash, never node)
#
# Strategy (D-18 verification-skew discipline): every assertion `require()`s the
# LIVE wrapper functions (checkDrift / scanRecursive / enumerateNovelPatterns)
# and `classifyEntry` from scripts/lib/plugin-cache-allowlist.js — there is NO
# in-file copy of the classification or drift-compare logic, so a wrapper
# regression flips an assertion red.
#
# Isolation (D-22 / T-18-08): each scenario builds its own fixture tree under
# `$TMPDIR` and runs every `node -e` under BOTH `HOME=$C/home` (so
# `os.homedir()` -> the sandbox, scoping checkDrift's cacheDir at
# os.homedir()/.cache/dhx) AND `CLAUDE_CONFIG_DIR=$C/home/.claude` (scoping the
# plugins/cache root). The probe never reads or writes the operator's live
# `~/.claude` or `~/.cache/dhx`.
#
# Independent sessions (D-22): each 3-state case uses an independent fixture tree
# AND a fresh `session_id` + fresh baseline — no shared session contamination of
# the mtime/count compare.
#
# Snapshot filename (D-22): the snapshot file is
# `drift-snapshot-${session_id}${suffix}.json` where `suffix` is a
# NON-DETERMINISTIC findCCTicks(ppid) value (`-p<ticks>` or ''). The
# schema-migration scenario does NOT reconstruct the suffix — it lets checkDrift
# WRITE the baseline, then GLOBS the single `drift-snapshot-*.json` in the
# isolated cacheDir.
#
# mtime control (gemini review): mtime mutation uses `fs.utimesSync(file, sec,
# sec)` with `sec = Math.floor(Date.now()/1000)+60` — SECONDS, not milliseconds
# (ms causes an out-of-bounds utimesSync), and never a shell `date`/`sleep`.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# Every node -e below does `require("$WRAPPER")` of dhx/statusline-wrapper.js and
# `require("$ALLOWLIST")` of scripts/lib/plugin-cache-allowlist.js — the LIVE
# modules, never an in-file copy (D-18).
WRAPPER="$REPO_ROOT/dhx/statusline-wrapper.js"
ALLOWLIST="$REPO_ROOT/scripts/lib/plugin-cache-allowlist.js"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0

pass() { echo "OK   $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1 ${2:-}"; FAIL=$((FAIL + 1)); }

# Build a sandbox HOME under $TMPDIR/$1 with the renderer-symlink gotcha applied
# and the dhx cache dir created. The wrapper require()s the renderer
# (dhx-statusline.js) at module-load against os.homedir()/.claude/hooks/, so the
# sandbox HOME MUST carry it reachable or `require($WRAPPER)` fails before
# checkDrift can run.
make_sandbox() {
  local name="$1"
  local C="$TMPDIR/$name"
  mkdir -p "$C/home/.claude/hooks"
  mkdir -p "$C/home/.claude/plugins/cache"
  mkdir -p "$C/home/.cache/dhx"
  ln -s "$REPO_ROOT/dhx/dhx-statusline.js" "$C/home/.claude/hooks/dhx-statusline.js"
  echo "$C"
}

echo "=== Phase 18 DRIFT-ALLOW-03 three-state boundary (tmpdir-isolated) ==="

# ===========================================================================
# [D-20] STRUCTURAL — run FIRST: catches the path-shape (absolute-path) bug
#        earlier than checkDrift.
# ===========================================================================
# Call the ACTUAL exported scanRecursive(cacheRoot, keepPredicate) with the SAME
# keepPredicate collectSnapshot uses — (rel,b) => classifyEntry(rel,b) ==='content'
# — over a fixture containing a real content leaf
# (claude-plugins-official/<plugin>/<hash>/plugin.json) plus a bookkeeping
# `.orphaned_at`. Assert content-count > 0. If scanRecursive fed keepPredicate
# the ABSOLUTE path, segment 0 would be a sandbox dir, every entry would
# classify `novel`, and content-count would be 0 — so this fails LOUDLY on the
# D-20 bug. classifyEntry is required from the live allowlist module (D-18).
S20="$(make_sandbox d20)"
CACHE20="$S20/home/.claude/plugins/cache"
mkdir -p "$CACHE20/claude-plugins-official/superpowers/5.0.7"
echo x > "$CACHE20/claude-plugins-official/superpowers/5.0.7/plugin.json"
echo x > "$CACHE20/claude-plugins-official/superpowers/5.0.7/.orphaned_at"
got=$(HOME="$S20/home" CLAUDE_CONFIG_DIR="$S20/home/.claude" node -e "
  const m = require('$WRAPPER');
  const { classifyEntry } = require('$ALLOWLIST');
  const r = m.scanRecursive('$CACHE20', (rel, b) => classifyEntry(rel, b) === 'content');
  process.stdout.write(r.count > 0 ? 'ok:' + r.count : 'zero');
" 2>/dev/null || echo "<error>")
if [ "${got#ok:}" != "$got" ]; then
  pass "[D-20 structural] scanRecursive feeds keepPredicate a cache-root-relative path → content-count > 0 ($got)"
else
  fail "[D-20 structural] scanRecursive feeds keepPredicate a cache-root-relative path → content-count > 0" "(got=$got — absolute-path bug would yield 0)"
fi

# ===========================================================================
# [D-21] 3-STATE CONTRACT via checkDrift's RESOLVED VALUE.
# ===========================================================================
# checkDrift(data) returns Promise<string>: '' clean, otherwise the rendered
# `\x1b[...m⚠ restart ${triggers} (${age})\x1b[0m`. The plugins case pushes the
# literal token `plugins`; the token survives ANSI, so we grep the raw resolved
# string for the substring `plugins`. Each case: an INDEPENDENT fixture tree +
# fresh session_id. Both checkDrift calls run in ONE node process so the
# snapshot key (session_id + findCCTicks ppid suffix) is stable across the pair
# (D-22). Call 1 baselines; we then mutate; call 2 compares.

# ---- [D-21 content] content-file mtime change → resolved carries `plugins` ----
SC="$(make_sandbox d21-content)"
CC="$SC/home/.claude/plugins/cache"
mkdir -p "$CC/anthropic-agent-skills/document-skills/690f15cac7f7/skills"
echo x > "$CC/anthropic-agent-skills/document-skills/690f15cac7f7/plugin.json"
echo x > "$CC/anthropic-agent-skills/document-skills/690f15cac7f7/skills/SKILL.md"
got=$(HOME="$SC/home" CLAUDE_CONFIG_DIR="$SC/home/.claude" node -e "
  const fs = require('fs');
  const m = require('$WRAPPER');
  const contentFile = '$CC/anthropic-agent-skills/document-skills/690f15cac7f7/skills/SKILL.md';
  const data = { session_id: 'd21-content-session', version: '2.1.500' };
  (async () => {
    await m.checkDrift(data);                       // call 1 — baseline
    const sec = Math.floor(Date.now() / 1000) + 60; // SECONDS (gemini review)
    fs.utimesSync(contentFile, sec, sec);           // bump a CONTENT leaf's mtime
    const r = await m.checkDrift(data);             // call 2 — compare
    const hasPlugins = String(r).includes('plugins');
    process.stdout.write((r.length > 0 && hasPlugins) ? 'ok' : 'bad:' + JSON.stringify(r));
  })().catch(e => process.stdout.write('error:' + e.message));
" 2>/dev/null || echo "<error>")
if [ "$got" = "ok" ]; then
  pass "[D-21 content] content-file change → checkDrift resolves non-empty + carries 'plugins' token"
else
  fail "[D-21 content] content-file change → checkDrift resolves non-empty + carries 'plugins' token" "(got=$got)"
fi

# ---- [D-21 bookkeeping] bookkeeping-only change → resolved LACKS `plugins` ----
# Mutate ONLY a bookkeeping file (`.orphaned_at`). The drift signal must NOT
# carry the `plugins` token (the resolved string may be '' or carry only
# unrelated triggers).
SB="$(make_sandbox d21-bookkeeping)"
CB="$SB/home/.claude/plugins/cache"
mkdir -p "$CB/anthropic-agent-skills/document-skills/690f15cac7f7"
echo x > "$CB/anthropic-agent-skills/document-skills/690f15cac7f7/plugin.json"
echo x > "$CB/anthropic-agent-skills/document-skills/690f15cac7f7/.orphaned_at"
got=$(HOME="$SB/home" CLAUDE_CONFIG_DIR="$SB/home/.claude" node -e "
  const fs = require('fs');
  const m = require('$WRAPPER');
  const bookFile = '$CB/anthropic-agent-skills/document-skills/690f15cac7f7/.orphaned_at';
  const data = { session_id: 'd21-bookkeeping-session', version: '2.1.500' };
  (async () => {
    await m.checkDrift(data);                       // call 1 — baseline
    const sec = Math.floor(Date.now() / 1000) + 60; // SECONDS
    fs.utimesSync(bookFile, sec, sec);              // bump a BOOKKEEPING leaf only
    const r = await m.checkDrift(data);             // call 2 — compare
    process.stdout.write(String(r).includes('plugins') ? 'has-plugins:' + JSON.stringify(r) : 'ok');
  })().catch(e => process.stdout.write('error:' + e.message));
" 2>/dev/null || echo "<error>")
if [ "$got" = "ok" ]; then
  pass "[D-21 bookkeeping] bookkeeping-only change → checkDrift resolved string LACKS 'plugins' token"
else
  fail "[D-21 bookkeeping] bookkeeping-only change → checkDrift resolved string LACKS 'plugins' token" "(got=$got)"
fi

# ---- [D-21 novel] novel file → `plugins` token absent AND in detector scope ---
# A novel file (unknown 4th-marketplace path) must be (a) absent from the
# plugins drift signal AND (b) present in enumerateNovelPatterns(fixtureRoot)
# output. This assertion is DETECTOR SCOPE (enumerateNovelPatterns), NOT the
# cohort-gated production route (D-28a / D-06): direct enumeration proves the
# detector's scope, not the full CC-version-cohort-gated route.
SN="$(make_sandbox d21-novel)"
CN="$SN/home/.claude/plugins/cache"
mkdir -p "$CN/anthropic-agent-skills/document-skills/690f15cac7f7"
echo x > "$CN/anthropic-agent-skills/document-skills/690f15cac7f7/plugin.json"
# novel: an unknown 4th marketplace (marketplaceTopLevel is seeded — D-15)
mkdir -p "$CN/mystery-marketplace/some-plugin/1.0.0"
echo x > "$CN/mystery-marketplace/some-plugin/1.0.0/manifest.bin"
got=$(HOME="$SN/home" CLAUDE_CONFIG_DIR="$SN/home/.claude" node -e "
  const fs = require('fs');
  const m = require('$WRAPPER');
  const novelFile = '$CN/mystery-marketplace/some-plugin/1.0.0/manifest.bin';
  const data = { session_id: 'd21-novel-session', version: '2.1.500' };
  (async () => {
    await m.checkDrift(data);                       // call 1 — baseline
    const sec = Math.floor(Date.now() / 1000) + 60; // SECONDS
    fs.utimesSync(novelFile, sec, sec);             // bump the NOVEL leaf
    const r = await m.checkDrift(data);             // call 2 — compare
    const driftSilentOnPlugins = !String(r).includes('plugins');
    // detector scope (D-28a): enumerateNovelPatterns over the fixture root
    const novel = m.enumerateNovelPatterns('$CN');
    const inDetector = novel.some(x =>
      x && x.path && x.path.split('/')[0] === 'mystery-marketplace');
    process.stdout.write((driftSilentOnPlugins && inDetector) ? 'ok'
      : 'bad:silent=' + driftSilentOnPlugins + ' inDetector=' + inDetector + ' r=' + JSON.stringify(r));
  })().catch(e => process.stdout.write('error:' + e.message));
" 2>/dev/null || echo "<error>")
if [ "$got" = "ok" ]; then
  pass "[D-21 novel] novel file → 'plugins' token absent AND present in enumerateNovelPatterns (detector scope, not the cohort-gated production route — D-28a)"
else
  fail "[D-21 novel] novel file → 'plugins' token absent AND present in enumerateNovelPatterns (detector scope, D-28a)" "(got=$got)"
fi

# ===========================================================================
# [D-24a] RESIDUAL-NOVEL — classify every leaf of a representative fixture cache
#         tree seeded with the D-13 content classes; assert 0 novel for known
#         content (the `.git/` internal must classify bookkeeping). Catches
#         under-widening at test time before it becomes a live drift
#         false-negative. classifyEntry required from the live module (D-18).
# ===========================================================================
got=$(node -e "
  const { classifyEntry } = require('$ALLOWLIST');
  // One leaf of EACH D-13 content class (cache-root-relative paths), plus a
  // .git/ internal that MUST classify bookkeeping (gitInternalsPathPattern).
  const mp = 'anthropic-agent-skills/document-skills/690f15cac7f7';
  // Each leaf sits directly under a RECOGNIZED D-13 intermediate segment (the
  // D-24d leaf rule then accepts the arbitrary leaf basename). office/ schemas/
  // docx/ scripts/ are widened-from-survey D-13 segments; plugin.json is a
  // root-level named config leaf; the .git/ internal must classify bookkeeping.
  const leaves = [
    [mp + '/office/document.xml',                       'document.xml'],   // office/
    [mp + '/schemas/docx/wml.xsd',                      'wml.xsd'],        // schemas/ + docx/
    [mp + '/scripts/build.py',                          'build.py'],       // scripts/
    [mp + '/plugin.json',                               'plugin.json'],    // root config leaf
    [mp + '/superpowers-checkout/.git/objects/ab/cdef0123', 'cdef0123'],   // .git/ internal
  ];
  const expected = ['content','content','content','content','bookkeeping'];
  let novelCount = 0;
  let mismatch = '';
  for (let i = 0; i < leaves.length; i++) {
    const c = classifyEntry(leaves[i][0], leaves[i][1]);
    if (c === 'novel') novelCount++;
    if (c !== expected[i]) mismatch += ' [' + leaves[i][0] + ' => ' + c + ' want ' + expected[i] + ']';
  }
  process.stdout.write((novelCount === 0 && mismatch === '') ? 'ok'
    : 'bad: novel=' + novelCount + mismatch);
" 2>/dev/null || echo "<error>")
if [ "$got" = "ok" ]; then
  pass "[D-24a residual-novel] every leaf of the representative content tree classifies non-novel (.git internal → bookkeeping); 0 novel for known content"
else
  fail "[D-24a residual-novel] 0 novel for known content (.git internal → bookkeeping)" "(got=$got)"
fi

# ===========================================================================
# [D-22] SCHEMA-MIGRATION REGRESSION — glob-not-guess.
# ===========================================================================
# A pre-Phase-18 snapshot lacking `schema_version` must re-baseline clean with
# NO false `plugins` fire (D-07/D-25 — the schema_version guard short-circuits
# before the marker block). Let checkDrift WRITE the baseline (call 1); GLOB the
# single drift-snapshot-*.json in the isolated cacheDir (do NOT reconstruct the
# -p<ticks> suffix — D-22); strip schema_version; rewrite to the SAME path; call
# checkDrift again (call 2) and assert the resolved string LACKS `plugins`.
# Both checkDrift calls + the glob/strip/rewrite run in one node process under
# the SAME HOME/session_id so the snapshot file persists across the pair.
SM="$(make_sandbox d22-schema)"
CM="$SM/home/.claude/plugins/cache"
CACHEDIR_M="$SM/home/.cache/dhx"
mkdir -p "$CM/anthropic-agent-skills/document-skills/690f15cac7f7"
echo x > "$CM/anthropic-agent-skills/document-skills/690f15cac7f7/plugin.json"
echo x > "$CM/anthropic-agent-skills/document-skills/690f15cac7f7/README.md"
got=$(HOME="$SM/home" CLAUDE_CONFIG_DIR="$SM/home/.claude" node -e "
  const fs = require('fs');
  const path = require('path');
  const m = require('$WRAPPER');
  const cacheDir = '$CACHEDIR_M';
  const data = { session_id: 'd22-schema-session', version: '2.1.500' };
  (async () => {
    await m.checkDrift(data);   // call 1 — checkDrift WRITES the baseline snapshot
    // GLOB the single drift-snapshot-*.json (do NOT guess the -p<ticks> suffix).
    const snaps = fs.readdirSync(cacheDir).filter(f =>
      /^drift-snapshot-.*\.json$/.test(f));
    if (snaps.length !== 1) {
      process.stdout.write('bad: expected exactly 1 snapshot, got ' + JSON.stringify(snaps));
      return;
    }
    const snapPath = path.join(cacheDir, snaps[0]);
    const snap = JSON.parse(fs.readFileSync(snapPath, 'utf8'));
    // Sanity: the baseline checkDrift wrote MUST carry schema_version (proves the
    // strip below actually simulates a pre-Phase-18 snapshot, not a no-op).
    if (!('schema_version' in snap)) {
      process.stdout.write('bad: baseline snapshot lacked schema_version (nothing to strip)');
      return;
    }
    delete snap.schema_version;                          // simulate pre-Phase-18 snapshot
    fs.writeFileSync(snapPath, JSON.stringify(snap));    // rewrite to the SAME path
    const r = await m.checkDrift(data);                  // call 2 — must re-baseline clean
    // Clean re-baseline: the migration guard short-circuits to a baseline write
    // and returns '' — no plugins fire.
    process.stdout.write(String(r).includes('plugins')
      ? 'has-plugins:' + JSON.stringify(r) : 'ok:' + JSON.stringify(r));
  })().catch(e => process.stdout.write('error:' + e.message));
" 2>/dev/null || echo "<error>")
if [ "${got#ok:}" != "$got" ]; then
  pass "[D-22 schema-migration] pre-Phase-18 snapshot (no schema_version, globbed not guessed) → clean re-baseline, no false 'plugins' fire"
else
  fail "[D-22 schema-migration] pre-Phase-18 snapshot → clean re-baseline, no false 'plugins' fire" "(got=$got)"
fi

echo "---"
echo "$PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
