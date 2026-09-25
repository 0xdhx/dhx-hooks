// probe-worktree-guard-adversarial.test.js
//
// node:test adversarial suite for dhx/dhx-worktree-bash-guard.sh (PreToolUse:Bash)
// and dhx/dhx-worktree-write-guard.sh (PreToolUse:Edit|Write|MultiEdit).
//
// Invariant (DURA-01 / Phase 43): the two worktree-leak guards emit the structured
//   {hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",...}}
// contract on stdout with exit 0 (D-03) for a real main-repo leak from a worktree
// cwd, and stay silent (exit 0, empty stdout) for legitimate / documented-gap calls.
// Demonstrates the SC1 detection scope (pipe / redirect / python3 -c / env -C BLOCK;
// own-worktree + sibling-repo + cp/mv/rsync/node-e/perl-e + interpreter-heredoc
// documented-gap PASS) and the SC4 deny shape. Mirrors the bash probe's
// _assert_block/_assert_allow shape over the same guard binaries (stdlib only — D-02).
//
//   retained 25/25 native probe tests/probes/probe-worktree-bash-guard.sh.
//
// Run: node --test tests/probes/probe-worktree-guard-adversarial.test.js
//  (also auto-runs under bare `node tests/probes/probe-worktree-guard-adversarial.test.js`
//   — the form scripts/run-probes.sh uses via the probe-*.js glob, check #8.)
//
// SAFE_FOR_LIVE: yes   (each test spawns the guard in a bash subshell against
//   synthetic stdin; the write-attempt command strings are blocked by the guard
//   BEFORE any shell execution, so no real filesystem write occurs — mirrors the
//   bash probe's SAFE_FOR_LIVE rationale at probe-worktree-bash-guard.sh:18.)

const { test } = require('node:test');
const assert = require('node:assert');
const { spawnSync } = require('node:child_process');
const path = require('node:path');

const BASH_HOOK  = path.join(__dirname, '..', '..', 'dhx', 'dhx-worktree-bash-guard.sh');
const WRITE_HOOK = path.join(__dirname, '..', '..', 'dhx', 'dhx-worktree-write-guard.sh');

const WT_CWD     = '/home/dhx/repos/forgeworks/.claude/worktrees/agent-test/';
const MAIN_ROOT  = '/home/dhx/repos/forgeworks';
const MAIN       = '/home/dhx/repos/forgeworks/scripts/hub.js';

// fire() — synthetic Bash hook-JSON ({cwd, tool_input:{command}}) into the bash guard.
function fire(cwd, command) {
  const input = JSON.stringify({ cwd, tool_input: { command } });
  const r = spawnSync('bash', [BASH_HOOK], { input, encoding: 'utf8' });
  return { rc: r.status, stdout: r.stdout || '', stderr: r.stderr || '' };
}

// fireWrite() — synthetic Edit/Write hook-JSON ({cwd, tool_input:{file_path}}) into the
// WRITE guard (D-14). The write guard keys on tool_input.file_path, NOT .command.
function fireWrite(cwd, file_path) {
  const input = JSON.stringify({ cwd, tool_input: { file_path } });
  const r = spawnSync('bash', [WRITE_HOOK], { input, encoding: 'utf8' });
  return { rc: r.status, stdout: r.stdout || '', stderr: r.stderr || '' };
}

// _assert_block equivalent — AFTER the D-03 migration: exit 0 + structured deny on stdout.
function assertDeny({ rc, stdout }) {
  assert.strictEqual(rc, 0, `expected exit 0 (structured deny), got rc=${rc}; stdout=${JSON.stringify(stdout)}`);
  const j = JSON.parse(stdout);
  assert.strictEqual(j.hookSpecificOutput.hookEventName, 'PreToolUse');
  assert.strictEqual(j.hookSpecificOutput.permissionDecision, 'deny');
  assert.ok(j.hookSpecificOutput.permissionDecisionReason.length > 0, 'reason must be non-empty');
}

// _assert_allow equivalent — silent exit 0, empty stdout (allow path is unchanged by D-03).
function assertAllow({ rc, stdout }) {
  assert.strictEqual(rc, 0, `expected exit 0 (silent allow), got rc=${rc}`);
  assert.strictEqual(stdout, '', `expected empty stdout (silent allow), got ${JSON.stringify(stdout)}`);
}

// ── SC1 leak vectors that MUST BLOCK (structured deny) ──────────────────────

test('env -C main-root-exact + relative target is BLOCKED (D-05)', () => {
  assertDeny(fire(WT_CWD, `env -C ${MAIN_ROOT} sed -i s/a/b/ scripts/hub.js`));
});

test('env -C quoted/multi-space/env -i -C is BLOCKED (D-10)', () => {
  // quoted bare-root
  assertDeny(fire(WT_CWD, `env -C "${MAIN_ROOT}" sed -i s/a/b/ scripts/hub.js`));
  // multi-space between tokens
  assertDeny(fire(WT_CWD, `env  -C  ${MAIN_ROOT} sed -i s/a/b/ scripts/hub.js`));
  // env -i -C (extra env flag before -C)
  assertDeny(fire(WT_CWD, `env -i -C ${MAIN_ROOT} sed -i s/a/b/ scripts/hub.js`));
});

test('pipe: cmd | tee mainpath is BLOCKED (D-06 locked)', () => {
  assertDeny(fire(WT_CWD, `echo x | tee ${MAIN}`));
});

test('redirect: > mainpath is BLOCKED (D-10)', () => {
  assertDeny(fire(WT_CWD, `echo x > ${MAIN}`));
});

test('python3 -c open(mainpath) is BLOCKED (D-10)', () => {
  assertDeny(fire(WT_CWD, `python3 -c "open('${MAIN}','w').write('y')"`));
});

// ── SC2 prefix-collision / sibling-repo: MUST ALLOW (no false-deny) ─────────

test('prefix-collision: write to OWN worktree path PASSES (SC2)', () => {
  assertAllow(fire(WT_CWD, `sed -i s/a/b/ ${WT_CWD}scripts/hub.js`));
});

test('sibling-repo /repos/forge vs /repos/forgeworks is NOT false-blocked (D-06)', () => {
  // cwd in a /repos/forge worktree, writing to the SIBLING /repos/forgeworks repo:
  // the trailing-slash `grep -qF "$MAIN_ROOT/"` (MAIN_ROOT=/home/dhx/repos/forge)
  // does NOT match "/home/dhx/repos/forgeworks/..." (forge + 'f', not forge + '/').
  assertAllow(fire('/home/dhx/repos/forge/.claude/worktrees/agent-x/',
                   `sed -i s/a/b/ /home/dhx/repos/forgeworks/x`));
});

// ── Documented gaps: MUST ALLOW — a complete shell matcher is structurally
//    unwinnable; backstop is dhx-worktree-write-guard.sh (Edit/Write) +
//    dhx-agent-leak-{snapshot,check}.sh (PostToolUse:Agent diff) (D-06/D-10). ──

test('documented gap: cp/mv/rsync/node -e/perl -e to main path PASSES — backstop is agent-leak diff (D-10)', () => {
  // documented gap — a complete shell matcher is structurally unwinnable; backstop is
  // dhx-worktree-write-guard.sh (Edit/Write) + dhx-agent-leak-{snapshot,check}.sh
  // (PostToolUse:Agent diff). None of these carry a detected write-verb token.
  assertAllow(fire(WT_CWD, `cp /tmp/x ${MAIN}`));
  assertAllow(fire(WT_CWD, `mv /tmp/x ${MAIN}`));
  assertAllow(fire(WT_CWD, `rsync /tmp/x ${MAIN}`));
  assertAllow(fire(WT_CWD, `node -e "require('fs').writeFileSync('${MAIN}','y')"`));
  assertAllow(fire(WT_CWD, `perl -e "open(F,'>','${MAIN}');print F 'y'"`));
});

test('documented gap: interpreter-heredoc to main path PASSES — backstop is agent-leak diff (D-10)', () => {
  // documented gap (the guard's :35 known heredoc gap) — `python3 <<EOF` carries NO
  // `-c` and NO `>` write-verb, so detection does not fire; backstop is the
  // agent-leak diff. (Do NOT use `cat <<EOF > path` — its `>` would make it a deny.)
  const heredoc = `python3 <<EOF\nopen('${MAIN}','w').write('y')\nEOF`;
  assertAllow(fire(WT_CWD, heredoc));
});

// ── D-14: write-guard deny-contract parity regression (file_path, not command) ──

test('write-guard: Edit file_path under main-root from worktree is DENIED (D-14)', () => {
  assertDeny(fireWrite(WT_CWD, `${MAIN_ROOT}/x`));
});

// ── SC3 (D-08 / D-15): captured live subagent fixture — VERSION-WITNESS ──
test('captured subagent fixture has agent_id + agent_type (SC3 version-witness)', () => {
  const fx = require('./fixtures/worktree-guard-subagent-fire.json'); // operator-captured, D-08
  // D-15: VERSION-WITNESS — durably records that CC 2.1.170 emitted subagent context
  // (agent_id / agent_type) on a PreToolUse:Bash hook at capture time (2026-06-09,
  // canonical operator session-restart fire). NOT a future-version drift detector: a
  // static committed fixture's own fields can never "go red" when a future CC changes
  // runtime behavior — genuine drift detection would require per-version live re-capture.
  assert.ok(fx.agent_id);
  assert.ok(fx.agent_type);
});
