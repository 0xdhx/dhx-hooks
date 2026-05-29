#!/usr/bin/env node
// RAT-06 (STATUSLINE-RAT-06) detached worker — one `npm view
// @anthropic-ai/claude-code version versions --json` call -> write
// {latest, max_published, checked_at, installed_at_check?} to the cache.
// Spawned detached by cc-check-update.js; never blocks SessionStart.
//
// Clones the gsd-check-update-worker.js npm-view shape, trimmed to one job.
// DROPPED from the GSD worker: the MANAGED_HOOKS stale-hooks scan and the
// isNewer semver helper (D-08 — the renderer computes update_available). ADDED
// over the GSD precedent: a defensive mkdir (D-19), an atomic temp+rename write
// (T-17-06), a `claude --version` probe (RAT-06b) that stamps the installed
// version npm `latest` was confirmed against — the dev-install false-positive
// guard — and a `max_published` field (RAT-06c) that records the SEMVER-MAX of
// every published version so the renderer's dev-install branch can compare
// against "ahead of everything npm has published" rather than the `latest`
// dist-tag (which npm moves separately from, and hours after, publishing a
// version). The GSD `installed` field served stale-hooks math; RAT-06b's
// installed_at_check + RAT-06c's max_published serve the renderer's
// false-positive suppression.
//
// Using a separate file (rather than node -e '<inline code>') avoids the
// template-literal regex-escaping problem and makes the worker independently
// testable.
//
// Patterns: HP-033

'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

// CC_CACHE_FILE is the parent->worker output-path handoff (D-17). The parent
// (cc-check-update.js) sets it in the spawn env; the worker reads it here.
const cacheFile = process.env.CC_CACHE_FILE;

// RAT-06c: the highest PUBLISHED version by base-version semver (prerelease
// suffix stripped, same shape as the renderer's parseV). The dev-install branch
// compares the installed binary against THIS, not the `latest` dist-tag —
// because npm moves `latest` separately from (and hours after) publishing a
// version, and CC auto-updates from a faster channel, so a perfectly normal
// freshly-published binary reads as "ahead of the latest tag" during the lag.
// npm does NOT guarantee `versions[]` is sorted, so compute the max rather than
// taking the last element. Returns the original version string with the highest
// base tuple, or null when the list is empty / all non-string.
function pickMaxBaseVersion(versions) {
  let best = null;
  let bestTuple = [-1, -1, -1];
  for (const v of versions) {
    if (typeof v !== 'string') continue;
    const p = v.replace(/^v/, '').split('-')[0].split('.').map(Number);
    const t = [p[0] || 0, p[1] || 0, p[2] || 0];
    if (t[0] > bestTuple[0]
      || (t[0] === bestTuple[0] && t[1] > bestTuple[1])
      || (t[0] === bestTuple[0] && t[1] === bestTuple[1] && t[2] > bestTuple[2])) {
      best = v;
      bestTuple = t;
    }
  }
  return best;
}

let latest = null;
let maxPublished = null;
try {
  // ONE combined network round-trip yields both references: `.version` is the
  // `latest` dist-tag version (the `⬆ cc` update reference); `.versions` is
  // every published version (the RAT-06c dev-install max reference). `--json`
  // with multiple fields makes npm emit a {version, versions} object.
  const raw = execFileSync(
    'npm',
    ['view', '@anthropic-ai/claude-code', 'version', 'versions', '--json'],
    {
      encoding: 'utf8',
      timeout: 10000,
      windowsHide: true,
      // On Windows, 'npm' is distributed as npm.cmd. Node's execFileSync does
      // not apply PATHEXT resolution and looks for a literal 'npm' binary,
      // failing with ENOENT. Setting shell:true on Windows routes through
      // cmd.exe which resolves npm.cmd via PATHEXT.
      // POSIX (Linux/macOS) is left untouched — no shell spawn, no extra
      // signal/exit-code semantics, no overhead.
      shell: process.platform === 'win32',
    },
  );
  const meta = JSON.parse(raw);
  if (typeof meta.version === 'string' && meta.version.trim()) {
    latest = meta.version.trim();
  }
  // A package with a single published version makes npm emit `versions` as a
  // bare string rather than an array — normalize both shapes.
  const versions = Array.isArray(meta.versions)
    ? meta.versions
    : (typeof meta.versions === 'string' ? [meta.versions] : []);
  maxPublished = pickMaxBaseVersion(versions);
} catch (e) {
  // Network failure / non-JSON output / timeout — latest + maxPublished stay
  // null; the cache records latest:'unknown' (the renderer skips the whole
  // cc-version block) and omits max_published.
}

// RAT-06b: record the installed CC version this npm `latest` was confirmed
// against. The renderer's `⚠ cc dev install` branch fires when installed >
// cache.latest — but that is a FALSE POSITIVE when the auto-updater bumped the
// installed binary past the cache's `latest` WITHIN the parent's ~6h TTL
// window (the cache still names the OLDER latest it checked). Stamping the
// installed version here lets the renderer suppress the warning unless
// installed === installed_at_check (i.e. npm was checked against THIS binary,
// not a since-replaced one). Probed from `claude --version` (parse the leading
// token; drop the " (Claude Code)" suffix + any leading `v`) so it matches the
// bare stdin `data.version` the renderer compares against. Best-effort: any
// failure leaves `installed` null → the field is omitted → the renderer falls
// back to its prior unguarded behavior (no regression). See decisions.md
// 2026-05-21 RAT-06b row + HP-033 invariant 7.
let installed = null;
try {
  const out = execFileSync('claude', ['--version'], {
    encoding: 'utf8',
    timeout: 5000,
    windowsHide: true,
    shell: process.platform === 'win32',
  }).trim();
  const token = out.split(/\s+/)[0];
  if (token) installed = token.replace(/^v/, '');
} catch (e) {
  // `claude` not on PATH / unexpected output / timeout — installed stays null.
}

// Cache write — DIVERGES from gsd-check-update-worker.js per D-08. The GSD
// worker writes {update_available, installed, latest, checked, stale_hooks};
// RAT-06 writes {latest, checked_at} plus the RAT-06b installed_at_check stamp
// and the RAT-06c max_published stamp (each added only when its probe yielded a
// value — absence is the renderer's fallback signal). ISO-8601 checked_at so
// the parent's TTL gate can Date.parse it. The renderer (Plan 03) computes
// update_available.
const result = {
  latest: latest || 'unknown',
  checked_at: new Date().toISOString(),
};
if (installed) result.installed_at_check = installed;
// RAT-06c: omit when null (npm probe failed / list unparseable) so the renderer
// falls back to comparing against `latest` — backward-compatible with the
// pre-RAT-06c cache schema. Never written as 'unknown' (which would parse to
// [0,0,0] and false-fire dev-install); absence is the fallback signal.
if (maxPublished) result.max_published = maxPublished;

if (cacheFile) {
  // `tmp` is declared outside the try so the catch can unlink it on a
  // renameSync failure (WR-03); the value is deterministic (cacheFile + pid).
  const tmp = cacheFile + '.tmp.' + process.pid;
  try {
    // Defensive mkdir (D-19) — guards the detached-worker ENOENT race: if
    // ~/.cache/cc is cleared between the parent's run and this worker's
    // asynchronous write, fs.writeFileSync would otherwise throw a fatal
    // ENOENT (it does not recursively create directories). Inside the same
    // try/catch as the write, before the temp file.
    fs.mkdirSync(path.dirname(cacheFile), { recursive: true });
    // Atomic temp+rename — the worker is a detached background process
    // writing while a statusline refresh may concurrently read
    // cc-update-check.json. A torn read is a real race (T-17-06); writing to
    // a temp path then renaming makes the cache update atomic.
    fs.writeFileSync(tmp, JSON.stringify(result));
    fs.renameSync(tmp, cacheFile);
  } catch (e) {
    // Best-effort cache write — a failure here is non-fatal (the renderer
    // hides the segment when the cache is absent). If writeFileSync succeeded
    // but renameSync threw (cross-device link, permission change, read-only
    // target), the .tmp.<pid> file would leak — this is a detached background
    // process, so nothing else sweeps it; unlink it best-effort (WR-03).
    try { fs.unlinkSync(tmp); } catch (_) { /* tmp may not exist */ }
  }
}
