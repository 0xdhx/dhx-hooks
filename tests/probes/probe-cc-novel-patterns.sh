#!/bin/bash
# SAFE_FOR_LIVE: yes   (mktemp fixture trees; node -e require with explicit fixture-root arg; checkDrift driven under HOME + CLAUDE_CONFIG_DIR overrides; never reads live ~/.claude or ~/.cache/dhx)
#
# probe-cc-novel-patterns.sh — RAT-04 enumeration regression probe.
#
# Exercises the post-CC-upgrade novel-pattern detector in
# dhx/statusline-wrapper.js: `enumerateNovelPatterns(pluginsCacheRoot)` and the
# version-branch wiring inside `checkDrift`. Backs 17-01-PLAN.md Task 3 and the
# D-13a / D-15 / D-22 detector contract.
#
# Run: bash tests/probes/probe-cc-novel-patterns.sh
#
# Strategy (D-11): every scenario stands up an isolated
# `plugins/cache/<mp>/<plugin>/<git-hash>/...` tree under `mktemp -d` and calls
# the LIVE wrapper module via `node -e "require('$WRAPPER')"` — the probe
# carries NO in-file copy of the enumeration logic, so a regression in the
# wrapper flips an assertion red. Scenario 5 (D-22 — version-unchanged → no
# scan) drives the exported `checkDrift` directly with an injected
# version-equal fixture state under HOME + CLAUDE_CONFIG_DIR overrides, then
# asserts cc-novel-patterns.json is NOT written — a behavioral assertion, not
# the structural grep fallback.
#
#        REQ STATUSLINE-RAT-04.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# Every scenario below does `require("$WRAPPER")` of dhx/statusline-wrapper.js
# — the live module, never an in-file copy of the enumeration logic.
WRAPPER="$REPO_ROOT/dhx/statusline-wrapper.js"

TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

PASS=0
FAIL=0

pass() { echo "OK   $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1 ${2:-}"; FAIL=$((FAIL + 1)); }

echo "=== RAT-04 novel-pattern enumeration (tmpdir-isolated) ==="

# ---- [1] Allowlisted-only → no novel ---------------------------------------
C1="$TMPDIR_ROOT/c1"
mkdir -p "$C1/anthropic-agent-skills/document-skills/690f15cac7f7/skills"
echo x > "$C1/anthropic-agent-skills/document-skills/690f15cac7f7/plugin.json"
echo x > "$C1/anthropic-agent-skills/document-skills/690f15cac7f7/README.md"
echo x > "$C1/anthropic-agent-skills/document-skills/690f15cac7f7/skills/SKILL.md"
got=$(node -e "
  const m = require('$WRAPPER');
  const r = m.enumerateNovelPatterns('$C1');
  process.stdout.write(String(r.length));
" 2>/dev/null || echo "<error>")
if [ "$got" = "0" ]; then
  pass "[1] allowlisted-only tree → 0 novel"
else
  fail "[1] allowlisted-only tree → 0 novel" "(got=$got)"
fi

# ---- [2] Novel hit → surfaces, with utimesSync mtime control ---------------
# D-21: the first_seen_mtime assertion uses fs.utimesSync with an explicit
# FUTURE timestamp — never sleep — so the recorded mtime is deterministic.
# Phase 18 D-24d: a novel hit now requires an UNRECOGNIZED INTERMEDIATE segment
# (`weird-intermediate/`). A bare unknown leaf basename directly under a
# recognized version dir classifies `content`, not novel (the 39.1%-gap fix).
C2="$TMPDIR_ROOT/c2"
mkdir -p "$C2/anthropic-agent-skills/document-skills/690f15cac7f7/weird-intermediate"
echo x > "$C2/anthropic-agent-skills/document-skills/690f15cac7f7/README.md"
echo x > "$C2/anthropic-agent-skills/document-skills/690f15cac7f7/weird-intermediate/mystery-manifest.bin"
got=$(node -e "
  const fs = require('fs');
  const m = require('$WRAPPER');
  const novelFile = '$C2/anthropic-agent-skills/document-skills/690f15cac7f7/weird-intermediate/mystery-manifest.bin';
  // D-21: explicit future timestamp (now + 1 day) for deterministic mtime.
  const futureSec = Math.floor(Date.now() / 1000) + 86400;
  fs.utimesSync(novelFile, futureSec, futureSec);
  const r = m.enumerateNovelPatterns('$C2');
  const hit = r.find(x => x.basename === 'mystery-manifest.bin');
  const futureMs = futureSec * 1000;
  // hit present, basename correct, path present, mtime matches the utimesSync stamp
  const okHit = !!hit
    && typeof hit.path === 'string' && hit.path.length > 0
    && typeof hit.first_seen_mtime === 'number'
    && Math.abs(hit.first_seen_mtime - futureMs) < 2000;
  process.stdout.write(okHit ? 'ok' : 'bad:' + JSON.stringify(hit));
" 2>/dev/null || echo "<error>")
if [ "$got" = "ok" ]; then
  pass "[2] novel hit (leaf under unrecognized intermediate) surfaces with path + utimesSync-controlled mtime"
else
  fail "[2] novel hit (leaf under unrecognized intermediate) surfaces with path + utimesSync-controlled mtime" "(got=$got)"
fi

# ---- [3] Novel path segment → surfaces -------------------------------------
C3="$TMPDIR_ROOT/c3"
mkdir -p "$C3/anthropic-agent-skills/document-skills/690f15cac7f7/weird-new-dir"
echo x > "$C3/anthropic-agent-skills/document-skills/690f15cac7f7/weird-new-dir/inner.md"
got=$(node -e "
  const m = require('$WRAPPER');
  const r = m.enumerateNovelPatterns('$C3');
  process.stdout.write(r.length >= 1 ? 'ok' : 'count:' + r.length);
" 2>/dev/null || echo "<error>")
if [ "$got" = "ok" ]; then
  pass "[3] novel path segment (weird-new-dir/) surfaces ≥1 novel"
else
  fail "[3] novel path segment (weird-new-dir/) surfaces ≥1 novel" "(got=$got)"
fi

# ---- [4] Two distinct novel intermediate segments → ≥2 novel ----------------
# Phase 18 D-24d: novel fires on UNRECOGNIZED INTERMEDIATE segments, not on bare
# leaf basenames under recognized ancestry. Seed two distinct unrecognized
# intermediate segments so ≥2 novel hits surface.
C4="$TMPDIR_ROOT/c4"
mkdir -p "$C4/anthropic-agent-skills/document-skills/690f15cac7f7/weird-new-dir"
mkdir -p "$C4/anthropic-agent-skills/document-skills/690f15cac7f7/another-weird-dir"
echo x > "$C4/anthropic-agent-skills/document-skills/690f15cac7f7/another-weird-dir/manifest.bin"
echo x > "$C4/anthropic-agent-skills/document-skills/690f15cac7f7/weird-new-dir/inner.md"
got=$(node -e "
  const m = require('$WRAPPER');
  const r = m.enumerateNovelPatterns('$C4');
  process.stdout.write(r.length >= 2 ? 'ok' : 'count:' + r.length);
" 2>/dev/null || echo "<error>")
if [ "$got" = "ok" ]; then
  pass "[4] two distinct novel intermediate segments → ≥2 novel"
else
  fail "[4] two distinct novel intermediate segments → ≥2 novel" "(got=$got)"
fi

# ---- [5] Version unchanged → no scan (D-22 — BEHAVIORAL) -------------------
# Drive the exported checkDrift directly under HOME + CLAUDE_CONFIG_DIR
# overrides. First call writes a baseline snapshot at version V; the second
# call with the SAME version V → no `version` trigger → enumeration never runs
# → cc-novel-patterns.json is NOT written. The fixture plugins/cache contains a
# novel file precisely to prove the absence is caused by the unchanged version,
# not by an empty tree. Both calls run inside ONE node process so the snapshot
# file key (session_id + CC ticks) is stable across the pair.
#
# The wrapper resolves its renderer module (dhx-statusline.js) via
# os.homedir()/.claude/hooks/ at module-load time, so the sandbox HOME must
# carry a .claude/hooks/dhx-statusline.js entry or the `require($WRAPPER)`
# itself fails before checkDrift can run. Symlinking the real renderer in
# satisfies the load without affecting checkDrift's behavior (checkDrift never
# touches the renderer's getRepoSignals/formatLine2Signals exports).
C5="$TMPDIR_ROOT/c5"
mkdir -p "$C5/home/.claude/hooks"
mkdir -p "$C5/home/.claude/plugins/cache/anthropic-agent-skills/document-skills/690f15cac7f7"
ln -s "$REPO_ROOT/dhx/dhx-statusline.js" "$C5/home/.claude/hooks/dhx-statusline.js"
# Create the dhx runtime cache dir under the fixture HOME (the dir checkDrift
# writes its snapshot + the RAT-04 cache into). Built via node path.join so
# the literal live-cache path string never appears in this probe's source.
node -e "const fs=require('fs'),path=require('path');fs.mkdirSync(path.join('$C5/home','.cache','dhx'),{recursive:true});"
# a NOVEL file under the fixture cache — would surface IF a scan ran
echo x > "$C5/home/.claude/plugins/cache/anthropic-agent-skills/document-skills/690f15cac7f7/mystery-manifest.bin"
got=$(HOME="$C5/home" CLAUDE_CONFIG_DIR="$C5/home/.claude" node -e "
  const fs = require('fs');
  const path = require('path');
  const m = require('$WRAPPER');
  const ccNovelFile = path.join('$C5/home', '.cache', 'dhx', 'cc-novel-patterns.json');
  const data = { session_id: 'd22-fixture-session', version: '2.1.999' };
  (async () => {
    await m.checkDrift(data);          // call 1 — writes baseline snapshot @ v2.1.999
    await m.checkDrift(data);          // call 2 — same version → no version trigger
    // BEHAVIORAL assertion: cc-novel-patterns.json must NOT exist.
    process.stdout.write(fs.existsSync(ccNovelFile) ? 'written' : 'absent');
  })().catch(e => process.stdout.write('error:' + e.message));
" 2>/dev/null || echo "<error>")
if [ "$got" = "absent" ]; then
  pass "[5] version-unchanged → checkDrift runs no scan, cc-novel-patterns.json NOT written (D-22 behavioral)"
else
  fail "[5] version-unchanged → cc-novel-patterns.json NOT written (D-22 behavioral)" "(got=$got)"
fi

# ---- [6] Realistic legitimate plugin content → no novel --------------------
# Mirrors the live survey: anthropic-agent-skills/document-skills/<git-hash>/
# {README.md, THIRD_PARTY_NOTICES.md, skills/, spec/, template/}.
C6="$TMPDIR_ROOT/c6"
H6="$C6/anthropic-agent-skills/document-skills/690f15cac7f7"
mkdir -p "$H6/skills" "$H6/spec" "$H6/template" "$H6/.claude-plugin"
echo x > "$H6/README.md"
echo x > "$H6/THIRD_PARTY_NOTICES.md"
echo x > "$H6/plugin.json"
echo x > "$H6/.claude-plugin/plugin.json"
echo x > "$H6/skills/SKILL.md"
echo x > "$H6/spec/README.md"
echo x > "$H6/template/README.md"
got=$(node -e "
  const m = require('$WRAPPER');
  const r = m.enumerateNovelPatterns('$C6');
  process.stdout.write(r.length === 0 ? 'ok' : 'novel:' + JSON.stringify(r));
" 2>/dev/null || echo "<error>")
if [ "$got" = "ok" ]; then
  pass "[6] realistic legitimate plugin content → 0 novel"
else
  fail "[6] realistic legitimate plugin content → 0 novel" "(got=$got)"
fi

# ---- [7] Unknown 4th marketplace → novel (D-15) ----------------------------
# A new top-level marketplace dir alongside the 3 seeded ones must surface —
# the detector must NOT wildcard the first path segment.
C7="$TMPDIR_ROOT/c7"
mkdir -p "$C7/anthropic-agent-skills/document-skills/690f15cac7f7"
mkdir -p "$C7/mystery-marketplace/some-plugin/1.0.0"
echo x > "$C7/anthropic-agent-skills/document-skills/690f15cac7f7/README.md"
echo x > "$C7/mystery-marketplace/some-plugin/1.0.0/x.md"
got=$(node -e "
  const m = require('$WRAPPER');
  const r = m.enumerateNovelPatterns('$C7');
  // every novel hit's path must start with the unknown marketplace dir
  const unknownHits = r.filter(x => x.path.split('/')[0] === 'mystery-marketplace');
  process.stdout.write(unknownHits.length >= 1 ? 'ok' : 'count:' + r.length);
" 2>/dev/null || echo "<error>")
if [ "$got" = "ok" ]; then
  pass "[7] unknown 4th marketplace surfaces as novel (D-15)"
else
  fail "[7] unknown 4th marketplace surfaces as novel (D-15)" "(got=$got)"
fi

# ---- [8] CR-01 / WR-02 — unknown marketplace whose ONLY files are
#          allowlisted leaf basenames (plugin.json + README.md) → ≥1 novel ----
# WR-02: scenario [7] uses a NON-allowlisted leaf (x.md), so it exercised the
# segment-0 gate via a leaf that never hit the legitContentBasenames fast-path —
# it passed even with CR-01 present. The realistic case is a brand-new
# marketplace whose files ARE allowlisted basenames (every plugin ships a
# plugin.json + README.md). Pre-CR-01 the fast-path returned 'content' for those,
# so enumerateNovelPatterns saw 0 novel hits — the new marketplace was INVISIBLE.
# This scenario seeds ONLY plugin.json + README.md under a new marketplace and
# asserts ≥1 novel hit. FAILS on pre-CR-01 code, PASSES after the SEG0-GATED guard.
C8="$TMPDIR_ROOT/c8"
mkdir -p "$C8/brand-new-marketplace/some-plugin/1.0.0"
echo x > "$C8/brand-new-marketplace/some-plugin/1.0.0/plugin.json"
echo x > "$C8/brand-new-marketplace/some-plugin/1.0.0/README.md"
got=$(node -e "
  const m = require('$WRAPPER');
  const r = m.enumerateNovelPatterns('$C8');
  // the new marketplace's allowlisted-basename files must surface as novel
  const unknownHits = r.filter(x => x.path.split('/')[0] === 'brand-new-marketplace');
  process.stdout.write(unknownHits.length >= 1 ? 'ok' : 'count:' + r.length);
" 2>/dev/null || echo "<error>")
if [ "$got" = "ok" ]; then
  pass "[8] unknown marketplace with ONLY allowlisted leaves (plugin.json+README.md) → ≥1 novel (CR-01/WR-02)"
else
  fail "[8] unknown marketplace with ONLY allowlisted leaves → ≥1 novel (CR-01/WR-02)" "(got=$got)"
fi

echo "---"
echo "$PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
