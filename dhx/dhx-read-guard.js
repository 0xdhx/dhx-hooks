#!/usr/bin/env node
// DHX Read Guard — PreToolUse hook (partial-only shim)
// Patterns: HP-003, HP-016, HP-036
//
// COLLAPSED to partial-only on 2026-05-24 (Option C — read-guard fork-weight
// investigation). The prior three-state design (strong READ-BEFORE-EDIT advisory
// + full-read suppress + global-TTL/flock/prune cache) was removed. Empirical
// probes (1a–1f, 2, 3, M2, Probe 5; see the brief + decisions.md Option C row)
// showed CC's NATIVE runtime owns read-before-edit enforcement — it hard-blocks
// an Edit AND a Write to an unread file across same-session / resume / CCS-swap /
// subagent contexts. So the strong advisory was non-delivering when correct
// (swallowed by CC's native block) and a false positive when it spoke (long-
// session prune / Write-then-Edit). The ONE thing CC lacks is partial-read
// blindness: CC's read-gate is BINARY — a `limit:N` read satisfies it for an edit
// ANYWHERE in the file (Probe 2). This shim fires a soft NOTE in exactly that gap.
//
// Reference impl of the removed global-TTL/flock/prune machinery: the pre-collapse
// SHA is pinned in docs/decisions.md (Option C row) + the Q1 extraction-on-demand
// backlog brief. Recover from git if a multi-writer cross-session TTL store is
// ever needed; do NOT keep dead code in-tree.
//
// DETECTION (session-scoped, keyed on session_id ALONE — Probe 5 / Branch 1):
//   dhx-read-cache.sh records partial Reads to
//   ~/.cache/dhx/partial-read-detect-<session_id>.jsonl. session_id is PRESERVED
//   across plain /exit+--resume (corpus N=12, incl. a 24.8 h single-id gap) and
//   ROTATES only on a CCS profile-swap (HP-036). Keying on session_id ALONE
//   confines the only lost case to the rare swap (fail-toward-silence: CC still
//   allows the edit — the partial Read is in the restored transcript — only the
//   soft NOTE is missed). No regression to the 2026-04-15 false-positive class is
//   possible: State-1/State-2 are gone, so a session-scoped miss can only fail
//   toward silence, never toward a false strong-advisory fire.
//
// DEDUP (once-per-(session_id, ticks) — Q4 keep-as-is): the seen-set re-arms per
// CC process (ticks = /proc start-time field 22 rotate on resume — HP-016) so the
// NOTE re-fires after resume, while repeated Edits within ONE process stay deduped.
// DETECTION and DEDUP are DISTINCT stores with DISTINCT keys by design — do NOT
// unify them (unifying would suppress the deliberate re-fire-after-resume UX).
//
// Exit semantics (preserved from gsd): always exit 0, never block. Silent on every
// error path (parse, stdin, I/O). The only output is the PARTIAL-READ NOTE.
//
// Scope (HP-003): fires for parent AND subagent Write|Edit calls — no agent_id
// branch. Triggers on: Write and Edit tool calls.

const fs = require('fs');
const path = require('path');
const os = require('os');

// DEDUP seen-set keying (D-04/HP-016): keyed on (session_id, CC-process-start-ticks).
// read-guard.js registers as `node "$HOME/..."` → CC shell-wraps the command, so
// process.ppid is an EPHEMERAL SHELL whose start-ticks rotate per Edit. A naive
// getProcessStartTicks(process.ppid) keys the seen-set on that shell → the lookup
// ALWAYS misses → the note fires every time. Walk ancestry past shells to the first
// non-shell ancestor (the CC process), mirroring statusline-wrapper.js's
// findCCTicks(). Returns null on non-Linux / unreadable /proc / all-shell-ancestry
// → caller degrades to always-fire (never crashes).
const SHELL_COMMS = new Set(['sh', 'bash', 'zsh', 'dash', 'fish', 'tcsh', 'ksh']);
function findCCTicks(startPpid) {
  const MAX_HOPS = 5;
  let pid = startPpid;
  for (let i = 0; i < MAX_HOPS && pid > 1; i++) {
    try {
      const stat = fs.readFileSync(`/proc/${pid}/stat`, 'utf8');
      const comm = stat.substring(stat.indexOf('(') + 1, stat.lastIndexOf(')'));
      const after = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
      if (!SHELL_COMMS.has(comm)) {
        return after[19] || null; // starttime = field 22 (HP-016)
      }
      pid = parseInt(after[1]); // ppid — walk up past the ephemeral shell
    } catch { return null; }
  }
  return null;
}

// IN-02: align with the shell writer's `realpath` semantics — dhx-read-cache.sh
// resolves symlinks before recording `path`, so the guard must too or a symlink
// lookup misses (writer stores the resolved target, guard would look up the symlink
// string). Fall back to path.resolve when the file was deleted between Read and Edit
// (matches the writer's `|| echo "$FILE_PATH"` fallback).
function resolvePath(p) {
  try { return fs.realpathSync(p); } catch { return path.resolve(p); }
}

let input = '';
const stdinTimeout = setTimeout(() => process.exit(0), 3000);
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => input += chunk);
process.stdin.on('end', () => {
  clearTimeout(stdinTimeout);
  try {
    const data = JSON.parse(input);
    const toolName = data.tool_name;
    const sessionId = data.session_id; // untrusted — validated before use as a filename component (D-11)

    // Only intercept Write and Edit tool calls.
    if (toolName !== 'Write' && toolName !== 'Edit') process.exit(0);

    const filePath = data.tool_input?.file_path || '';
    if (!filePath) process.exit(0);

    // Only an existing file can have been partial-read; CC allows creating new
    // files directly, so there is nothing to note on a non-existent path.
    try {
      fs.accessSync(filePath, fs.constants.F_OK);
    } catch {
      process.exit(0);
    }

    // D-11: session_id is untrusted and is a filename component for BOTH the
    // detection and dedup stores. If it is empty / contains a path separator
    // (/ or \) / `..`, we cannot safely key either store → exit silently.
    // Fail-toward-silence is the accepted direction now that the strong advisory
    // is gone. Reject-and-disable, never sanitize (sanitizing risks two distinct
    // session_ids colliding to one store).
    const sessionIdSafe =
      typeof sessionId === 'string' && sessionId.length > 0 &&
      !/[/\\]/.test(sessionId) && !sessionId.includes('..');
    if (!sessionIdSafe) process.exit(0);

    const cacheDir = path.join(os.homedir(), '.cache', 'dhx');
    const resolvedTarget = resolvePath(filePath);

    // DETECTION: was this file partial-read this session? Session-scoped store,
    // read-only here (dhx-read-cache.sh is the sole writer). No TTL / flock /
    // prune: a single logical writer per session, and O_APPEND keeps concurrent
    // subagent appends atomic at the line level (< PIPE_BUF). Any I/O error →
    // treat as "not partial-read" → exit silent.
    let hasPartialRead = false;
    try {
      // INVARIANT: the detection store keys on session_id ALONE — NOT
      // session_id+ticks. ticks rotate on EVERY resume (HP-016/HP-036); keying on
      // them would miss the NOTE on every cross-session edit, not just the rare
      // CCS-swap, collapsing the Probe-5/Branch-1 result. Do not add ticks here.
      const detectPath = path.join(cacheDir, `partial-read-detect-${sessionId}.jsonl`);
      const contents = fs.readFileSync(detectPath, 'utf8');
      for (const line of contents.split('\n')) {
        if (!line.trim()) continue;
        try {
          const entry = JSON.parse(line);
          if (entry && typeof entry.path === 'string' &&
              resolvePath(entry.path) === resolvedTarget) {
            hasPartialRead = true;
            break;
          }
        } catch {
          // skip malformed line, continue scanning
        }
      }
    } catch {
      // no detection store / unreadable → not partial-read this session
    }

    // No partial read recorded → SILENT. CC's native runtime owns full
    // read-before-edit enforcement (Probes 1a–1f); there is nothing for this shim
    // to add. (This replaces both the old State-1 strong advisory and the old
    // State-2 full-read suppress — neither delivered net value under CC.)
    //
    // INVARIANT: this silence DEPENDS on CC's tool layer hard-blocking an Edit or
    // Write to a file not Read this session ("File has not been read yet."). If a
    // future CC release weakens that, blind edits to unread files would proceed
    // un-warned. The dependency is asserted by the supersession-watchdog
    // tests/probes/probe-read-guard-native-enforcement-tripwire.sh — when it flips
    // red, revisit the Option C collapse (the strong advisory may need reviving).
    if (!hasPartialRead) process.exit(0);

    // DEDUP: once-per-(session_id, ticks) — Q4 keep-as-is. null ticks (non-Linux /
    // unreadable /proc) → skip the gate → always-fire.
    // D-11 FAIL-SAFE (load-bearing): ALL seen-set ops live inside a targeted
    // try/catch whose catch FALLS THROUGH TO FIRE the note — it does NOT exit and
    // does NOT re-throw. The canonical case is the EXPECTED first-read ENOENT (the
    // seen-set file does not exist yet) → treated as a miss → the note FIRES, then
    // the file is created on append. Any seen-set error degrades to FIRING, never
    // to silence. The ONLY legitimate suppression is the happy-path cache HIT.
    const ticks = findCCTicks(process.ppid);
    if (ticks) {
      try {
        const seenPath = path.join(cacheDir, `partial-read-seen-${sessionId}-${ticks}.jsonl`);
        const contents = fs.readFileSync(seenPath, 'utf8');
        for (const line of contents.split('\n')) {
          if (!line.trim()) continue;
          try {
            const rec = JSON.parse(line);
            if (rec && rec.path === resolvedTarget) {
              process.exit(0); // cache HIT — the only legitimate suppression
            }
          } catch {
            // skip malformed line, continue scanning
          }
        }
        // cache MISS — append, then fall through to FIRE.
        fs.mkdirSync(cacheDir, { recursive: true });
        fs.appendFileSync(seenPath, JSON.stringify({ path: resolvedTarget, ts: Math.floor(Date.now() / 1000) }) + '\n');
      } catch {
        // D-11 fail-safe: ANY seen-set error (incl. the expected first-read ENOENT)
        // is a miss → fire the note. Best-effort append so the next Edit can dedup;
        // if even the append fails, the note has already fired (the safe outcome).
        try {
          const seenPath = path.join(cacheDir, `partial-read-seen-${sessionId}-${ticks}.jsonl`);
          fs.mkdirSync(cacheDir, { recursive: true });
          fs.appendFileSync(seenPath, JSON.stringify({ path: resolvedTarget, ts: Math.floor(Date.now() / 1000) }) + '\n');
        } catch {
          // append also failed — note still fires below (safe default)
        }
      }
    }

    // PARTIAL-READ NOTE — text preserved verbatim (Q4). Fires on dedup miss, null
    // ticks, or seen-set error; suppressed ONLY on a dedup cache HIT above.
    const fileName = path.basename(filePath);
    const output = {
      hookSpecificOutput: {
        hookEventName: 'PreToolUse',
        additionalContext:
          `PARTIAL-READ NOTE: "${fileName}" was Read with offset/limit this session ` +
          'but not in full. You may proceed if you have sufficient context for this edit. ' +
          'If unsure, do a full Read first.',
      },
    };
    process.stdout.write(JSON.stringify(output));
  } catch {
    // Silent fail — never block tool execution
    process.exit(0);
  }
});
