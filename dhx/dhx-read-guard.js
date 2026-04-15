#!/usr/bin/env node
// DHX Read Guard — PreToolUse hook (fork of gsd-read-guard.js)
//
// Fork of gsd/gsd-read-guard.js v1.32.0 with session-aware gating replaced
// by a global TTL-based cache lookup.
//
// Gate: Checks ~/.claude/read-once/reads.jsonl — a global TTL-based cache
// shared across all CCS instances. Entries with ts within the last 2 hours
// count as "read". This eliminates session-scoping false positives caused by
// CCS instance swaps changing session_id.
//
// Cache is written by:
//   - read-once/hook.sh (full reads)
//   - dhx-read-partial-cache.sh (partial reads with {"partial":true})
//
// Line format:  {"path":"/abs/path","ts":<unix>}
//               {"path":"/abs/path","ts":<unix>,"partial":true}
//
// Three-state detection:
//   - Full read in cache (within TTL) → suppress advisory entirely
//   - Partial read in cache ({"partial":true}, within TTL) → light "PARTIAL-READ NOTE"
//   - No read in cache within TTL → strong "READ-BEFORE-EDIT" advisory
//
// Caveats (accepted residuals):
//   - If reads.jsonl doesn't exist or is empty, all edits get the advisory
//     (safe degradation — same as before any Read happens in a session).
//   - If dhx-read-partial-cache.sh is not installed, partial reads are not
//     recorded in reads.jsonl and produce the strong advisory (safe degradation).
//   - Global cache eliminates session-scoping false positives on CCS instance
//     swap, session resume, and context compaction.
//   - Entries older than 2 hours are pruned by hook.sh's hourly cleanup cycle.
//
// Exit semantics preserved from gsd: always exit 0, never block. Silent on
// every error path (parse, stdin, I/O) — the hook must never be the reason
// a tool call fails.
//
// Triggers on: Write and Edit tool calls
// Action: Advisory (does not block) — injects read-first guidance on cache miss

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

    // Global TTL-based cache lookup: check reads.jsonl for recent reads.
    // Any error falls through to emit the "no read" advisory (safe default).
    let hasFullRead = false;
    let hasPartialRead = false;
    try {
      const globalCachePath = path.join(os.homedir(), '.claude', 'read-once', 'reads.jsonl');
      if (fs.existsSync(globalCachePath)) {
        const resolvedTarget = path.resolve(filePath);
        const nowSec = Math.floor(Date.now() / 1000);
        const ttl = 7200; // 2 hours
        const contents = fs.readFileSync(globalCachePath, 'utf8');
        const lines = contents.split('\n');
        for (const line of lines) {
          if (!line.trim()) continue;
          try {
            const entry = JSON.parse(line);
            if (entry && typeof entry.path === 'string' &&
                path.resolve(entry.path) === resolvedTarget &&
                typeof entry.ts === 'number' &&
                (nowSec - entry.ts) <= ttl) {
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
      }
    } catch {
      // fall through to advisory on any I/O error
    }

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
