#!/usr/bin/env node
// RAT-06 (STATUSLINE-RAT-06) detached worker — npm view @anthropic-ai/claude-code
// version -> write {latest, checked_at} to the cache. Spawned detached by
// cc-check-update.js; never blocks SessionStart.
//
// Clones the gsd-check-update-worker.js npm-view shape, trimmed to one job.
// DROPPED from the GSD worker: the MANAGED_HOOKS stale-hooks scan and the
// isNewer semver helper (D-08 — the renderer computes update_available). ADDED
// over the GSD precedent: a defensive mkdir (D-19), an atomic temp+rename write
// (T-17-06), and a `claude --version` probe (RAT-06b) that stamps the installed
// version npm `latest` was confirmed against — the dev-install false-positive
// guard. The GSD `installed` field served stale-hooks math; RAT-06b's
// installed_at_check serves the renderer's auto-updater-race suppression.
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

let latest = null;
try {
  latest = execFileSync('npm', ['view', '@anthropic-ai/claude-code', 'version'], {
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
  }).trim();
} catch (e) {
  // Network failure / unexpected output / timeout — latest stays null; the
  // cache records 'unknown' and the renderer treats it as "no update".
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
// (added only when the `claude --version` probe succeeded — absence is the
// renderer's fallback signal). ISO-8601 checked_at so the parent's TTL gate can
// Date.parse it. The renderer (Plan 03) computes update_available.
const result = {
  latest: latest || 'unknown',
  checked_at: new Date().toISOString(),
};
if (installed) result.installed_at_check = installed;

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
