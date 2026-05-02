'use strict';
// Node --require preloader. Forces child Node process to exit non-zero on
// any child_process invocation (D-14 wording: exit-on-call). Used by
// probe-statusline-load.js to assert post-retire dhx-statusline.js issues
// ZERO subprocess calls (D-03 contract; CONTEXT.md Discretion: "module
// monkeypatch"). Loads via `node --require <this> dhx/dhx-statusline.js`,
// BEFORE the rendered script's own requires resolve.
//
// On subprocess attempt the stub writes a diagnostic to stderr and calls
// `process.exit(2)` — NOT a thrown error. The renderer wraps its body in
// try/catch (dhx-statusline.js:311-471 silent-swallow); a thrown error
// would be caught, child would exit 0 cleanly = false-pass. process.exit
// bypasses user-land catch (only `process.on('exit')` runs). Per cycle-2
// W-A finding (D-14 locked).

const cp = require('child_process');

const FORBIDDEN = ['execFileSync', 'execSync', 'spawnSync', 'spawn', 'exec', 'execFile', 'fork'];

for (const fn of FORBIDDEN) {
  if (typeof cp[fn] === 'function' && !cp[fn].__dhxProbeShim) {
    const stub = (...args) => {
      const arg0 = args[0] != null ? JSON.stringify(args[0]).slice(0, 80) : '';
      process.stderr.write(`[no-subprocess-shim] forbidden child_process.${fn}(${arg0}) — STATUS-06 regression\n`);
      process.exit(2);
    };
    stub.__dhxProbeShim = true;
    cp[fn] = stub;
  }
}
