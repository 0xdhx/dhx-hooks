#!/usr/bin/env node
// Probe: stale-hooks filter retirement
//
// Backs: docs/decisions.md 2026-04-18 stale-hooks-filter-retire row
//        docs/backlog.md "gsd-stale-hooks-filter-retire" (closed 2026-04-18)
//
// Invariants:
//   1. statusline-wrapper.js no longer strips "⚠ stale hooks" / "⚠ dev install" warnings.
//      If the filter creeps back in (accidental re-add or bad rebase), this probe flips red.
//   2. gsd-check-update-worker.js regex accepts both `//` and `#` comment styles.
//      The retirement premise rests on upstream #2136 fix. If upstream regresses the regex
//      to JS-only, bash hooks will false-positive as stale again and the filter should return.
//   3. The 3 bash hooks in MANAGED_HOOKS carry a `# gsd-hook-version:` header.
//      Concrete evidence the bash-hook header convention is alive upstream.
//
// Run: `node tests/probes/probe-stale-hooks-filter-retired.js`

const fs = require('fs');
const os = require('os');
const path = require('path');

let passed = 0;
let failed = 0;

function assert(label, cond) {
  if (cond) {
    console.log(`OK   ${label}`);
    passed += 1;
  } else {
    console.log(`FAIL ${label}`);
    failed += 1;
  }
}

const WRAPPER = path.join(__dirname, '..', '..', 'dhx', 'statusline-wrapper.js');
const WORKER = path.join(os.homedir(), '.claude', 'hooks', 'gsd-check-update-worker.js');
const BASH_HOOKS = [
  'gsd-phase-boundary.sh',
  'gsd-session-state.sh',
  'gsd-validate-commit.sh',
];

// Invariant 1 — wrapper does not carry the retirement filter
const wrapperSrc = fs.readFileSync(WRAPPER, 'utf8');
assert(
  'wrapper: no "stale hooks|dev install" replace regex',
  !/\.replace\([^)]*stale hooks\|dev install/.test(wrapperSrc)
);
assert(
  'wrapper: no "#2136" reference (retirement comment removed)',
  !/#2136/.test(wrapperSrc)
);

// Invariant 2 — upstream regex accepts `#` comments
if (!fs.existsSync(WORKER)) {
  console.log('SKIP gsd-check-update-worker.js not found at ~/.claude/hooks/ — run after /gsd-update');
} else {
  const workerSrc = fs.readFileSync(WORKER, 'utf8');
  // Match the exact regex shape that supports both `//` and `#` comments.
  assert(
    'worker: hook-version regex accepts both `//` and `#` comments',
    /\(\?:\\\/\\\/\|#\)\s*gsd-hook-version/.test(workerSrc)
  );
}

// Invariant 3 — bash hooks carry `# gsd-hook-version:` headers
const hooksDir = path.join(os.homedir(), '.claude', 'hooks');
for (const h of BASH_HOOKS) {
  const p = path.join(hooksDir, h);
  if (!fs.existsSync(p)) {
    console.log(`SKIP ${h}: not installed`);
    continue;
  }
  const src = fs.readFileSync(p, 'utf8');
  assert(
    `${h}: has "# gsd-hook-version:" header`,
    /^#\s*gsd-hook-version:\s*\S+/m.test(src)
  );
}

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed > 0 ? 1 : 0);
