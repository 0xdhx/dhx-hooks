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
// Cache paths read (D-01 dual-path during migration window):
//   - PRIMARY: ~/.cache/dhx/read-cache.jsonl (XDG, dhx-owned, D-04)
//   - LEGACY:  ~/.claude/read-once/reads.jsonl (Boucle community path,
//              read for in-flight session compatibility; removed in
//              v1.1.1 follow-up commit per
//              .planning/todos/pending/2026-04-26-v1-1-1-remove-legacy-path-read-fallback.md)
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

let input = '';
const stdinTimeout = setTimeout(() => process.exit(0), 3000);
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => input += chunk);
process.stdin.on('end', () => {
  clearTimeout(stdinTimeout);
  try {
    const data = JSON.parse(input);
    const toolName = data.tool_name;

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

    // Global TTL-based cache lookup: check both XDG and legacy paths for
    // recent reads. Any error falls through to emit the "no read" advisory
    // (safe default). D-01 dual-path read; D-07 null-safety; D-17 invariant.
    let hasFullRead = false;
    let hasPartialRead = false;
    try {
      // PRIMARY: new XDG cache (D-04)
      const primaryCachePath = path.join(os.homedir(), '.cache', 'dhx', 'read-cache.jsonl');
      // LEGACY: Boucle path — read until v1.1.1 hygiene commit (D-01)
      const legacyCachePath = path.join(os.homedir(), '.claude', 'read-once', 'reads.jsonl');

      const resolvedTarget = path.resolve(filePath);
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
                path.resolve(entry.path) === resolvedTarget &&
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
      scanCache(legacyCachePath);  // D-01: removed in v1.1.1 hygiene commit
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
      // Partial read found — targeted advisory
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
