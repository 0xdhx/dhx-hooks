#!/usr/bin/env node
// DHX Read Guard — PreToolUse hook (fork of gsd-read-guard.js)
//
// Fork of gsd-read-guard.js v1.32.0 with session-aware gating replaced
// by a global TTL-based cache lookup. Rewritten in v1.1 Phase 1 for the
// dhx-owned read-tracking stack (Option B; replaces ~/.claude/read-once/).
//
// Gate: Checks the dhx-owned XDG cache for recent reads. Entries with ts
// within the last 2 hours count as "read". Pure global TTL eliminates
// session-scoping false positives caused by CCS instance swaps changing
// session_id (load-bearing citation:
// reports/done/2026-04-15-read-guard-session-scoping-false-positives.md).
//
// Cache path read:
//   - ~/.cache/dhx/read-cache.jsonl (XDG, dhx-owned, D-04)
//
// D-01 dual-path migration-window fallback (also read ~/.claude/read-once/reads.jsonl
// during the ~1 week post-Phase-1 window while in-flight CC sessions still wrote to
// the legacy path) removed in v1.1.1 hygiene commit (2026-05-03): >1 week elapsed,
// all sessions confirmed restarted, legacy cache mtime >2h stale.
//
// Cache is written by:
//   - dhx-read-cache.sh (sole PreToolUse:Read writer; full + partial reads)
//   - dhx-write-cache.sh (PostToolUse:Write|Edit; "source":"write" entries)
//
// Line format (D-08 schema with D-07 null-safety):
//   {"path":"/abs/path","ts":<unix>,"source":"read"}
//   {"path":"/abs/path","ts":<unix>,"source":"read","partial":true}
//   {"path":"/abs/path","ts":<unix>,"source":"write"}
//   {"path":"/abs/path","ts":<unix>}                    (legacy, no source)
//   {"path":"/abs/path","ts":<unix>,"partial":true}     (legacy partial)
//
// D-07 null-safety: absent `source` field = treat as "read". D-08 semantics:
// `source:"write"` entries count as full reads (writing IS a "you've seen
// the bytes" signal — see dhx-write-cache.sh header for the false-positive
// class this closes).
//
// D-17 PARTIAL+WRITE INVARIANT (defense-in-depth): the guard treats any
// `partial:true` entry as partial regardless of the `source` value, by
// design. Writers MUST NOT emit `partial:true` with `source:"write"`
// (dhx-read-cache.sh writer header enforces this; only Read-tool partial
// loads carry partial:true). HOWEVER, if a writer ever regresses and emits
// the forbidden combo (partial:true + source:"write"), the guard's branch
// here degrades SAFELY to a PARTIAL-READ NOTE rather than incorrectly
// suppressing as a full read. This is the conservative/safe failure mode:
// emitting an unnecessary advisory is better than missing a needed one.
//
// Three-state detection (REQ READ-04; collapse to two-state deferred to
// v1.2 per READ-FUT-02 + D-03 dead-signal probe):
//   - Full read in cache (within TTL) → suppress advisory entirely
//   - Partial read in cache ({"partial":true}, within TTL) → light "PARTIAL-READ NOTE"
//   - No read in cache within TTL → strong "READ-BEFORE-EDIT" advisory
//
// Caveats (accepted residuals):
//   - If both caches don't exist or are empty, all edits get the advisory
//     (safe degradation — same as before any Read happens in a session).
//   - Global cache eliminates session-scoping false positives on CCS instance
//     swap, session resume, and context compaction.
//   - Entries older than 2 hours are pruned by dhx-read-cache.sh's hourly
//     cleanup cycle (.last-cleanup marker, flock-protected awk-rewrite —
//     see D-13 in CONTEXT.md for the rename-then-append-back pattern).
//
// Exit semantics preserved from gsd: always exit 0, never block. Silent on
// every error path (parse, stdin, I/O) — the hook must never be the reason
// a tool call fails.
//
// Triggers on: Write and Edit tool calls
// Action: Advisory (does not block) — injects read-first guidance on cache miss
//
// Scope (HP-003 reframe, audit 2026-04-21): fires for parent AND subagent
// Write/Edit calls. The global reads.jsonl cache is TTL-scoped, not session-
// scoped, so parent and subagent reads both feed the same cache (assuming
// read-once/hook.sh fires in both contexts — currently assumed, not verified
// under the new HP-003 matcher-specific framing). Uniform enforcement
// intended: if a subagent is about to Edit a file that has not been Read in
// the last 2h (by anyone), CC's runtime will reject the Edit and this
// advisory warns in advance. The hook does NOT branch on agent_id. The
// advisory is non-blocking, so a false positive in subagent context costs
// only one advisory line — cheap enough to accept over per-matcher branching.

const fs = require('fs');
const path = require('path');
const os = require('os');

// --- PARTIAL-READ NOTE once-per-(session,file) seen-set keying (CAL-POLISH-02) ---
// D-04: the PARTIAL-READ NOTE seen-set is keyed on (session_id, CC-process-start-ticks)
// so /resume (a NEW CC process — HP-016 field 22 rotates) re-arms the note while
// repeated Edits within ONE process stay deduped. read-guard.js is registered
// `node "$HOME/.claude/hooks/dhx-read-guard.js"`: the literal $HOME forces CC to
// shell-wrap the command, so process.ppid is an EPHEMERAL SHELL whose start-ticks
// rotate per Edit. A naive getProcessStartTicks(process.ppid) keys the seen-set on
// that shell → the lookup ALWAYS misses → the note fires every time and the bug
// persists silently. Mirror statusline-wrapper.js's findCCTicks() ancestry-walk
// past shells to the first non-shell ancestor (the CC process). Returns null on
// non-Linux / unreadable /proc / all-shell-ancestry → caller degrades to always-fire
// (NEVER crashes — same degrade-safely principle as the cache scan below).
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

    // Only intercept Write and Edit tool calls
    if (toolName !== 'Write' && toolName !== 'Edit') {
      process.exit(0);
    }

    const filePath = data.tool_input?.file_path || '';
    if (!filePath) {
      process.exit(0);
    }

    // Only inject guidance when the file already exists.
    // New files don't need a prior Read — the runtime allows creating them directly.
    let fileExists = false;
    try {
      fs.accessSync(filePath, fs.constants.F_OK);
      fileExists = true;
    } catch {
      // File does not exist — no guidance needed
    }

    if (!fileExists) {
      process.exit(0);
    }

    // Global TTL-based cache lookup (XDG primary cache only; D-01 legacy fallback
    // removed in v1.1.1 hygiene commit). Any error falls through to emit the
    // "no read" advisory (safe default). D-07 null-safety; D-17 invariant.
    let hasFullRead = false;
    let hasPartialRead = false;
    try {
      const primaryCachePath = path.join(os.homedir(), '.cache', 'dhx', 'read-cache.jsonl');

      // IN-02: align with shell writers' `realpath` semantics — both
      // dhx-read-cache.sh and dhx-write-cache.sh resolve symlinks before
      // emitting `path`. Using path.resolve here would miss matches when
      // the target is a symlink (writer emits the resolved target, guard
      // looks up the symlink string). Fall back to path.resolve when the
      // file was deleted between Read and Edit (matches writer's
      // `|| echo "$FILE_PATH"` fallback).
      let resolvedTarget;
      try {
        resolvedTarget = fs.realpathSync(filePath);
      } catch {
        resolvedTarget = path.resolve(filePath);
      }
      const resolveEntryPath = (p) => {
        try {
          return fs.realpathSync(p);
        } catch {
          return path.resolve(p);
        }
      };
      const nowSec = Math.floor(Date.now() / 1000);
      const ttl = 7200; // 2 hours

      // Reader factored out — same loop runs against both paths.
      // Accumulator is monotonic per V-DUAL-PATH-NOOP (RESEARCH.md);
      // no dedupe needed if same path appears in both caches.
      const scanCache = (cachePath) => {
        if (!fs.existsSync(cachePath)) return;
        const contents = fs.readFileSync(cachePath, 'utf8');
        for (const line of contents.split('\n')) {
          if (!line.trim()) continue;
          try {
            const entry = JSON.parse(line);
            if (entry && typeof entry.path === 'string' &&
                resolveEntryPath(entry.path) === resolvedTarget &&
                typeof entry.ts === 'number' &&
                (nowSec - entry.ts) <= ttl) {
              // D-07: absent `source` field = treat as "read" (legacy entries
              //       from ~/.claude/read-once/hook.sh which emit {"path","ts"}).
              // D-08: "source":"write" entries also count as full reads
              //       (writing IS a "you've seen the bytes" signal — that is
              //       why dhx-write-cache.sh exists).
              // D-17: any `partial:true` entry is treated as partial regardless
              //       of `source`, by design — defense-in-depth against a
              //       writer regression emitting partial:true + source:"write"
              //       (forbidden by writer invariant, but guard degrades safely).
              if (entry.partial) {
                hasPartialRead = true;
              } else {
                hasFullRead = true;
              }
            }
          } catch {
            // skip malformed line, continue scanning
          }
        }
      };

      scanCache(primaryCachePath);
    } catch {
      // fall through to advisory on any I/O error
    }

    // INVARIANT: fires for parent AND subagent Write|Edit calls (HP-003
    // verified 2026-04-21). Advisory is uniform across contexts — no
    // agent_id short-circuit.
    // Full read → suppress entirely
    if (hasFullRead) {
      process.exit(0);
    }

    const fileName = path.basename(filePath);

    if (hasPartialRead) {
      // PARTIAL-READ NOTE once-per-(session,file) gate (CAL-POLISH-02, D-02/D-04/D-11).
      //
      // D-11 FAIL-SAFE (load-bearing): ALL seen-set ops (existsSync / readFileSync /
      // JSON.parse-per-line / mkdir / appendFileSync) live inside a TARGETED try/catch
      // whose catch FALLS THROUGH TO FIRE the note — it does NOT process.exit and does
      // NOT re-throw. The canonical case is the EXPECTED first-read ENOENT (the
      // partial-read-seen-*.jsonl does not exist on the first partial read of a
      // (session,ticks)): that error is treated as a cache-miss → the note FIRES, then
      // the file is created on append. Any seen-set error degrades to FIRING, never to
      // silence — mirrors the existing degrade-safely principle at lines 44 and 120-121.
      // The ONLY legitimate suppression is the happy-path cache HIT (process.exit(0)).
      //
      // D-11 constraint (3): session_id is untrusted. If it is empty OR contains a path
      // separator (/ or \) OR `..`, DISABLE the optimization entirely (always-fire) — do
      // NOT strip-and-continue, because stripping risks two distinct session_ids
      // colliding to one seen-set file (key collision). Reject-and-disable, not sanitize.
      //
      // findCCTicks(process.ppid) keys on the CC process (ancestry-walk past the
      // shell-wrap, NOT a naive process.ppid read — see helper header). null ticks
      // (non-Linux / unreadable /proc) → skip the gate → always-fire.
      const sessionIdSafe =
        typeof sessionId === 'string' && sessionId.length > 0 &&
        !/[/\\]/.test(sessionId) && !sessionId.includes('..');
      const ticks = findCCTicks(process.ppid);

      if (sessionIdSafe && ticks) {
        try {
          // Resolve the target with the same realpath-then-resolve semantics the
          // cache scan uses (IN-02), so the seen-set key matches the writer's path.
          let seenTarget;
          try {
            seenTarget = fs.realpathSync(filePath);
          } catch {
            seenTarget = path.resolve(filePath);
          }
          const cacheDir = path.join(os.homedir(), '.cache', 'dhx');
          const seenPath = path.join(cacheDir, `partial-read-seen-${sessionId}-${ticks}.jsonl`);

          // Scan the seen-set for a record matching the resolved target. The
          // readFileSync throws ENOENT on the first partial read (file not yet
          // created) — that propagates to the targeted catch below, which fires
          // the note then this code creates the file on append.
          const contents = fs.readFileSync(seenPath, 'utf8');
          for (const line of contents.split('\n')) {
            if (!line.trim()) continue;
            try {
              const rec = JSON.parse(line);
              if (rec && rec.path === seenTarget) {
                // Cache HIT — happy-path once-per-(session,file) dedup.
                // This is the ONLY legitimate suppression of the note.
                process.exit(0);
              }
            } catch {
              // skip malformed line, continue scanning (D-11 constraint 2 —
              // mirrors scanCache's per-line resilience above)
            }
          }
          // Cache MISS (no matching record) — append, then fall through to FIRE.
          fs.mkdirSync(cacheDir, { recursive: true });
          fs.appendFileSync(seenPath, JSON.stringify({ path: seenTarget, ts: Math.floor(Date.now() / 1000) }) + '\n');
        } catch {
          // D-11 fail-safe: ANY seen-set error (incl. the expected first-read
          // ENOENT) is treated as a cache-miss → fall through to FIRE the note.
          // Never silent suppression. Best-effort append so the next Edit can dedup;
          // if even the append fails, the note has already fired (the safe outcome).
          try {
            const cacheDir = path.join(os.homedir(), '.cache', 'dhx');
            const seenPath = path.join(cacheDir, `partial-read-seen-${sessionId}-${ticks}.jsonl`);
            let seenTarget;
            try {
              seenTarget = fs.realpathSync(filePath);
            } catch {
              seenTarget = path.resolve(filePath);
            }
            fs.mkdirSync(cacheDir, { recursive: true });
            fs.appendFileSync(seenPath, JSON.stringify({ path: seenTarget, ts: Math.floor(Date.now() / 1000) }) + '\n');
          } catch {
            // append also failed — note still fires below (safe default)
          }
        }
      }
      // Partial read found — targeted advisory (fires on cache-miss, fail-safe error,
      // null ticks, or invalid session_id; suppressed ONLY on a cache HIT above).
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
    } else {
      // No read at all — strong advisory
      const output = {
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          additionalContext:
            `READ-BEFORE-EDIT: "${fileName}" exists but has not been Read this session. ` +
            'You MUST Read it before editing — the runtime will reject edits to unread files.',
        },
      };
      process.stdout.write(JSON.stringify(output));
    }
  } catch {
    // Silent fail — never block tool execution
    process.exit(0);
  }
});
