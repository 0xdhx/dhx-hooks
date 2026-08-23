#!/usr/bin/env node
// SAFE_FOR_LIVE: yes   (mkdtempSync fixture trees + require() of the live wrapper with explicit fixture-root args; fs.readdirSync is patched and restored in-process only; no live ~/.claude, ~/.cache/dhx, or repo writes)
// LIVE_RUNTIME: no
//
// probe-dirent-engine-portability.js — pins the Dirent parent-path contract that
// every recursive `fs.readdirSync({withFileTypes:true, recursive:true})` walk in
// this repo depends on.
//
// WHY THIS EXISTS. Node renamed the Dirent's parent-directory property across
// majors: `dirent.path` (Node 20.1-23, deprecated DEP0178) -> `dirent.parentPath`
// (Node >= 20.12). Node 24 REMOVED `dirent.path`. The wrapper's walks read that
// property to rebuild each entry's absolute path; a walk that reads only
// `entry.path` and falls back to `join(scanRoot, entry.name)` does not crash on
// Node 24 — it silently flattens every nested path to `<root>/<basename>`, so
// statSync 404s (mtime 0 / kind 'unreadable') and classifyEntry's segment-0
// marketplace check sees a bare filename and classifies everything `novel`.
// The plugins drift trigger then never fires. A total FALSE-NEGATIVE that renders
// clean.
//
// That is not hypothetical: on 2026-08-19 18:18 this host's `nvm alias default`
// moved 22 -> 24, and on 2026-08-23 six probes were found red at an UNCHANGED
// HEAD with production drift detection dead for four days. See docs/decisions.md
// 2026-08-23 row, docs/troubleshooting.md § "Every drift/novel-pattern probe went
// red at once…", and HP-056.
//
// STRATEGY. The two engines cannot both be installed for one run, so the probe
// SIMULATES each by patching `fs.readdirSync` in-process to strip one property
// from every returned Dirent, then drives the LIVE wrapper exports over a nested
// fixture. A walk that is portable resolves nested entries identically under
// both shims; a walk that reads one property only reds under exactly one of them.
// This makes the probe engine-independent: it fails on the CURRENT host whichever
// node is installed, instead of waiting for the next major to break production.
//
// Run: node tests/probes/probe-dirent-engine-portability.js

'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');

const REPO_ROOT = path.join(__dirname, '..', '..');
const WRAPPER = path.join(REPO_ROOT, 'dhx', 'statusline-wrapper.js');

let PASS = 0;
let FAIL = 0;
function ok(name, cond, detail) {
  if (cond) { console.log(`OK   ${name}`); PASS++; }
  else { console.log(`FAIL ${name}${detail ? ` (${detail})` : ''}`); FAIL++; }
}

const m = require(WRAPPER);

// ---------------------------------------------------------------------------
// [E] Engine fact — recorded, never asserted.
//
// Deliberately NOT an assertion. Pinning "this host has parentPath" would make
// the probe red on a hypothetical engine that drops it, which is the harness's
// problem, not the repo's. The behavioural cells below are the real contract.
// ---------------------------------------------------------------------------
{
  const t = fs.mkdtempSync(path.join(os.tmpdir(), 'dirent-fact-'));
  fs.mkdirSync(path.join(t, 'a', 'b'), { recursive: true });
  fs.writeFileSync(path.join(t, 'a', 'b', 'leaf'), 'x');
  const nested = fs.readdirSync(t, { withFileTypes: true, recursive: true })
    .find((e) => e.name === 'leaf');
  console.log(`     [engine] ${process.version}  parentPath=${nested && 'parentPath' in nested}  path=${nested && 'path' in nested}`);
  fs.rmSync(t, { recursive: true, force: true });
}

// ---------------------------------------------------------------------------
// Dirent shims. `stripProp` returns a readdirSync replacement that deletes one
// property from every Dirent it hands back, simulating an engine that never had
// it. Restored in a finally so a red cell cannot leak the patch into later cells.
// ---------------------------------------------------------------------------
const realReaddirSync = fs.readdirSync;

function withStrippedDirentProp(prop, fn) {
  const keep = prop === 'path' ? 'parentPath' : 'path';
  fs.readdirSync = function patched(dir, opts) {
    const out = realReaddirSync.call(fs, dir, opts);
    if (!opts || !opts.withFileTypes) return out;
    for (const e of out) {
      // Read the parent from whichever property THIS engine populates, then
      // republish it under the name being simulated before deleting the other.
      // Reading the twin BEFORE assigning is load-bearing: on Node 24 `path` is
      // already absent, so a shim that sourced its value from `e.path` would
      // hand back a Dirent carrying NEITHER property — a third engine that has
      // never existed, and a vacuous test.
      const parent = e.parentPath !== undefined ? e.parentPath : e.path;
      if (parent === undefined) continue;
      e[keep] = parent;
      try { delete e[prop]; } catch { /* non-configurable — fall through */ }
    }
    return out;
  };
  try { return fn(); } finally { fs.readdirSync = realReaddirSync; }
}

// Sanity: the shim must actually remove the property, or every cell below is
// vacuously green. This is the probe's own negative control.
{
  const t = fs.mkdtempSync(path.join(os.tmpdir(), 'dirent-shim-'));
  fs.mkdirSync(path.join(t, 'a'), { recursive: true });
  fs.writeFileSync(path.join(t, 'a', 'leaf'), 'x');
  const seen = {};
  for (const prop of ['path', 'parentPath']) {
    withStrippedDirentProp(prop, () => {
      const e = fs.readdirSync(t, { withFileTypes: true, recursive: true })
        .find((x) => x.name === 'leaf');
      seen[prop] = e && e[prop] === undefined;
    });
  }
  ok('[shim] stripping `path` leaves it undefined on a nested Dirent', seen.path === true);
  ok('[shim] stripping `parentPath` leaves it undefined on a nested Dirent', seen.parentPath === true);
  fs.rmSync(t, { recursive: true, force: true });
}

// ---------------------------------------------------------------------------
// [A] scanRecursive — nested entries must be counted and their mtimes read.
//
// The flattened-path failure shows up two ways at once: statSync 404s so the
// nested mtime never wins, and `maxPath` names a file that does not exist.
// ---------------------------------------------------------------------------
function nestedFixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dirent-scan-'));
  fs.mkdirSync(path.join(root, 'mp', 'plugin', 'v1'), { recursive: true });
  fs.writeFileSync(path.join(root, 'shallow.txt'), 'x');
  const deep = path.join(root, 'mp', 'plugin', 'v1', 'deep.json');
  fs.writeFileSync(deep, 'x');
  // Push the DEEP file's mtime well past everything else so a correct walk must
  // report it as the winner. A flattened walk cannot stat it at all.
  const future = Date.now() + 600000;
  fs.utimesSync(deep, future / 1000, future / 1000);
  return { root, deep, future };
}

for (const strip of ['path', 'parentPath']) {
  const engine = strip === 'path' ? 'node>=24 (no .path)' : 'node<20.12 (no .parentPath)';
  const { root, deep, future } = nestedFixture();
  try {
    const res = withStrippedDirentProp(strip, () => m.scanRecursive(root));
    ok(`[A1/${engine}] scanRecursive counts the nested entries`,
      res.count >= 4, `count=${res.count}`);
    ok(`[A2/${engine}] the deep file's mtime wins the scan (nested statSync resolved)`,
      Math.round(res.maxMtime) === Math.round(future), `maxMtime=${res.maxMtime} want≈${future}`);
    ok(`[A3/${engine}] maxPath names the real nested file, not a flattened sibling`,
      res.maxPath === deep, `maxPath=${res.maxPath}`);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

// ---------------------------------------------------------------------------
// [B] scanRecursive + keepPredicate — the D-20 contract.
//
// keepPredicate MUST receive a cache-root-relative, forward-slash path. Under a
// flattened walk it receives the bare basename, segment 0 becomes the filename,
// and every marketplace-segment check misses. This cell asserts the SHAPE the
// predicate is handed, which is the thing classifyEntry keys on.
// ---------------------------------------------------------------------------
for (const strip of ['path', 'parentPath']) {
  const engine = strip === 'path' ? 'node>=24' : 'node<20.12';
  const { root } = nestedFixture();
  try {
    const rels = [];
    withStrippedDirentProp(strip, () => m.scanRecursive(root, (rel) => { rels.push(rel); return true; }));
    ok(`[B1/${engine}] keepPredicate sees the full relative path of the nested file`,
      rels.includes('mp/plugin/v1/deep.json'), `got=${JSON.stringify(rels)}`);
    ok(`[B2/${engine}] no entry is handed a bare basename in place of its path`,
      !rels.includes('deep.json'), `got=${JSON.stringify(rels)}`);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

// ---------------------------------------------------------------------------
// [C] enumerateNovelPatterns — allowlisted trees must stay silent.
//
// This is the RAT-04 surface. Under a flattened walk every leaf loses its
// marketplace ancestry, so an entirely legitimate plugin tree surfaces as novel
// and first_seen_mtime is 0 for all of them.
// ---------------------------------------------------------------------------
for (const strip of ['path', 'parentPath']) {
  const engine = strip === 'path' ? 'node>=24' : 'node<20.12';
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dirent-novel-'));
  try {
    // A tree whose every leaf is allowlisted under recognized ancestry.
    for (const rel of ['dhx-local/dhx/abc123/plugin.json',
                       'dhx-local/dhx/abc123/README.md',
                       'dhx-local/dhx/abc123/skills/x/SKILL.md']) {
      const full = path.join(root, rel);
      fs.mkdirSync(path.dirname(full), { recursive: true });
      fs.writeFileSync(full, 'x');
    }
    const novel = withStrippedDirentProp(strip, () => m.enumerateNovelPatterns(root));
    ok(`[C1/${engine}] a fully-allowlisted tree surfaces zero novel entries`,
      Array.isArray(novel) && novel.length === 0, `got=${JSON.stringify(novel)}`);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

// ---------------------------------------------------------------------------
// [D] collectGsdDriftDivergingFiles — nested files must be READ, not 'unreadable'.
//
// The flattened walk's tell here is a diverging entry whose `path` is a bare
// basename and whose `kind` is 'unreadable' — the shape observed on 2026-08-23.
// ---------------------------------------------------------------------------
for (const strip of ['path', 'parentPath']) {
  const engine = strip === 'path' ? 'node>=24' : 'node<20.12';
  const live = fs.mkdtempSync(path.join(os.tmpdir(), 'dirent-gsd-live-'));
  const fork = fs.mkdtempSync(path.join(os.tmpdir(), 'dirent-gsd-fork-'));
  try {
    const rel = 'workflows/execute-phase.md';
    for (const base of [live, fork]) {
      const full = path.join(base, rel);
      fs.mkdirSync(path.dirname(full), { recursive: true });
      fs.writeFileSync(full, 'canonical');
    }
    // Make the live copy newer than the snapshot so it is actually compared,
    // and byte-differ it so a correct walk reports `mismatch` at the FULL rel.
    fs.writeFileSync(path.join(live, rel), 'diverged');
    const snapshot = { gsd_mtime: 0 };
    const out = withStrippedDirentProp(strip, () => m.collectGsdDriftDivergingFiles(snapshot, live, fork));
    ok(`[D1/${engine}] the diverging file is reported at its full relative path`,
      out.length === 1 && out[0].path === rel, `got=${JSON.stringify(out)}`);
    ok(`[D2/${engine}] it is classified 'mismatch', not 'unreadable' (nested read resolved)`,
      out.length === 1 && out[0].kind === 'mismatch', `got=${JSON.stringify(out)}`);
  } finally {
    fs.rmSync(live, { recursive: true, force: true });
    fs.rmSync(fork, { recursive: true, force: true });
  }
}

// ---------------------------------------------------------------------------
// [S] Source lint — refuse the reintroduction of the single-property idiom.
//
// The behavioural cells above cover the exported walks. This cell covers the
// ones a future edit might add: any `<x>.path` read that is NOT paired with
// `parentPath` on the same line, inside a file that does a recursive
// withFileTypes walk. Cheap, and it names the fix instead of a symptom.
//
// INVARIANT: every recursive-readdir walk in this repo resolves its Dirent
// parent via `parentPath || path || <scanRoot>`, in that order.
// ---------------------------------------------------------------------------
{
  const WALK_FILES = [
    path.join(REPO_ROOT, 'dhx', 'statusline-wrapper.js'),
    path.join(REPO_ROOT, 'tests', 'probes', 'probe-drift-detection.js'),
  ];
  // Scoped by CALL SITE, not by identifier name. An identifier-name regex
  // (`d.path`, `e.path`) collides with the wrapper's unrelated
  // `gsdDiverging[].path` records and reports them as offenders; anchoring on
  // the recursive-readdir call and scanning its loop body has no such blind
  // spot in either direction.
  const WINDOW = 40;   // lines after the call site — every walk body here is < 25
  const offenders = [];
  for (const f of WALK_FILES) {
    const lines = fs.readFileSync(f, 'utf8').split('\n');
    lines.forEach((line, i) => {
      if (!/readdirSync\(/.test(line)) return;
      if (!/withFileTypes/.test(line) || !/recursive:\s*true/.test(line)) return;
      for (let j = i + 1; j < Math.min(i + 1 + WINDOW, lines.length); j++) {
        const body = lines[j];
        if (/^\s*(\/\/|\*)/.test(body)) continue;            // comments are prose
        if (!/\.path\b/.test(body)) continue;
        if (/parentPath/.test(body)) continue;                 // paired — portable
        if (/\bpath\.(join|relative|dirname|basename|sep)\b/.test(body) &&
            !/\b[A-Za-z_$][\w$]*\.path\b/.test(body.replace(/\bpath\./g, 'PATHMOD.'))) continue;
        offenders.push(`${path.relative(REPO_ROOT, f)}:${j + 1}: ${body.trim()}`);
      }
    });
  }
  // Overlapping call-site windows can name one line twice — dedupe so the
  // detail reads as a site list, not a multiplicity.
  const uniq = [...new Set(offenders)];
  ok('[S1] no recursive-walk file reads a Dirent `.path` unpaired with `parentPath`',
    uniq.length === 0, uniq.join(' | '));
}

console.log('---');
console.log(`${PASS} passed, ${FAIL} failed`);
process.exit(FAIL > 0 ? 1 : 0);
