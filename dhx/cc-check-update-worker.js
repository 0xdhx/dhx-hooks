#!/usr/bin/env node
// RAT-06 (STATUSLINE-RAT-06) detached worker — npm view @anthropic-ai/claude-code
// version -> write {latest, checked_at} to the cache. Spawned detached by
// cc-check-update.js; never blocks SessionStart.
//
// Clones the gsd-check-update-worker.js npm-view shape, trimmed to one job.
// DROPPED from the GSD worker: the MANAGED_HOOKS stale-hooks scan and the
// isNewer semver helper (D-08 — the renderer computes update_available, the
// detector needs no installed-version probe). ADDED over the GSD precedent:
// a defensive mkdir (D-19) and an atomic temp+rename write (T-17-06).
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

// Cache write — DIVERGES from gsd-check-update-worker.js per D-08. The GSD
// worker writes {update_available, installed, latest, checked, stale_hooks};
// RAT-06 writes ONLY {latest, checked_at}. ISO-8601 checked_at so the parent's
// TTL gate can Date.parse it. The renderer (Plan 03) computes update_available.
const result = {
  latest: latest || 'unknown',
  checked_at: new Date().toISOString(),
};

if (cacheFile) {
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
    const tmp = cacheFile + '.tmp.' + process.pid;
    fs.writeFileSync(tmp, JSON.stringify(result));
    fs.renameSync(tmp, cacheFile);
  } catch (e) {
    // Best-effort cache write — a failure here is non-fatal (the renderer
    // hides the segment when the cache is absent).
  }
}
