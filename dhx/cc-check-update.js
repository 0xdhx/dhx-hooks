#!/usr/bin/env node
// RAT-06 (STATUSLINE-RAT-06): CC-version-drift check. SessionStart parent —
// TTL-gated spawn of cc-check-update-worker.js. Registered via the
// session-start.sh dispatcher (HP-017 + D-17), not settings.json.
//
// Clones the gsd-check-update.js parent shape with two RAT-06-specific
// additions:
//   1. A NET-NEW TTL freshness gate (gsd-check-update.js has NO TTL — it
//      spawns the worker on every SessionStart). The parent reads
//      cc-update-check.json.checked_at and skips the worker spawn when fresh.
//   2. A dedicated CC_CHECK_UPDATE_CACHE env override (D-17) so the TTL gate
//      is unit-testable without touching live ~/.cache/cc.
//
// No stdin parsing — dispatched with `< /dev/null`. Fire-and-forget: always
// exits 0, never blocks SessionStart.
//
// Patterns: HP-033

const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawn } = require('child_process');

// Cache-path resolution with the D-17 test seam. CC_CHECK_UPDATE_CACHE is the
// PARENT's own cache-path override — it makes the TTL gate unit-testable
// without touching the live ~/.cache/cc. It is NOT CC_CACHE_FILE: per D-17,
// CC_CACHE_FILE is reserved solely for the parent->worker output-path handoff
// (set in the spawn env below) — no double duty.
const cacheFile = process.env.CC_CHECK_UPDATE_CACHE
  || path.join(os.homedir(), '.cache', 'cc', 'cc-update-check.json');
// Derive the cache dir FROM the resolved cacheFile so a test override
// relocates the directory too.
const cacheDir = path.dirname(cacheFile);

// NET-NEW TTL gate — no equivalent in gsd-check-update.js (which spawns the
// worker every SessionStart). Placed BEFORE the spawn AND before the mkdir so
// a fresh-cache run never creates a directory.
const TTL_MS = 6 * 60 * 60 * 1000;  // ~6h per RAT-06 brief (D-07 Claude's Discretion)
try {
  const c = JSON.parse(fs.readFileSync(cacheFile, 'utf8'));
  if (c.checked_at && (Date.now() - Date.parse(c.checked_at)) < TTL_MS) {
    // Cache fresh — skip the worker spawn AND the mkdir.
    process.exit(0);
  }
  // A malformed checked_at makes Date.parse return NaN; (Date.now() - NaN)
  // < TTL_MS is false → falls through to spawn (malformed cache == stale).
} catch {
  // missing / malformed JSON — fall through to spawn (HP-015 silent-rebuild).
}

// Cache is stale, missing, or malformed — ensure the cache dir exists, then
// spawn the worker. Placed AFTER the TTL early-return so a fresh-cache run
// creates no directory.
if (!fs.existsSync(cacheDir)) {
  fs.mkdirSync(cacheDir, { recursive: true });
}

// Spawn the detached worker. CC_CACHE_FILE carries the resolved cacheFile to
// the worker as its OUTPUT path — this is the only role of CC_CACHE_FILE
// (D-17). child.unref() lets the hook return immediately so the 1-3s npm view
// network call never blocks SessionStart.
const workerPath = path.join(__dirname, 'cc-check-update-worker.js');
const child = spawn(process.execPath, [workerPath], {
  stdio: 'ignore',
  windowsHide: true,
  detached: true,  // Required on Windows for proper process detachment
  env: { ...process.env, CC_CACHE_FILE: cacheFile },
});
child.unref();

process.exit(0);
