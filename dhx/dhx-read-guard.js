#!/usr/bin/env node
// DHX Read Guard — PreToolUse hook (session-aware fork of gsd-read-guard.js)
//
// Fork of gsd/gsd-read-guard.js v1.32.0 with an added session-aware gate.
// The upstream gsd version fires this advisory every time Edit/Write targets
// an existing file, which is a 100% false-positive rate on Claude sessions
// (Claude already follows read-before-edit natively). See
//   reports/done/2026-04-10-read-guard-false-positives.md
// for incident evidence and rationale.
//
// Gate: piggybacks on ~/.claude/read-once/ per-session JSONL cache. If a
// Read of this file_path was recorded in the current session's cache, suppress
// the advisory. Otherwise fall through to the unchanged gsd advisory.
//
// Cache path:   ~/.claude/read-once/session-<sha256(session_id)[:16]>.jsonl
// Line format:  {"path":"/abs/path","mtime":"...","ts":<unix>,"tokens":<int>}
// Hash algo MUST match read-once/hook.sh:97 exactly:
//   bash: echo -n "$SESSION_ID" | sha256sum | cut -c1-16
//   node: crypto.createHash('sha256').update(sessionId).digest('hex').slice(0,16)
//
// Three-state detection (requires dhx-read-partial-cache.sh companion):
//   - Full read in cache → suppress advisory entirely
//   - Partial read in cache ({"partial":true}) → light "PARTIAL-READ NOTE"
//   - No read in cache → strong "READ-BEFORE-EDIT" advisory
//
// Caveats (accepted residuals):
//   - If dhx-read-partial-cache.sh is not installed, partial reads
//     produce the strong "no read" advisory (safe degradation).
//   - If the user sets READ_ONCE_DISABLED=1, the cache is stale and the
//     advisory fires on every Edit (regression to gsd behavior). Accepted opt-out.
//   - No TTL check on cache entries: we only care "was it ever Read this
//     session", not how long ago.
//
// Exit semantics preserved from gsd: always exit 0, never block. Silent on
// every error path (parse, stdin, I/O) — the hook must never be the reason
// a tool call fails.
//
// Triggers on: Write and Edit tool calls
// Action: Advisory (does not block) — injects read-first guidance on cache miss

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
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

    // Session-aware gate: check read-once session cache for full and partial reads.
    // Piggybacks on ~/.claude/read-once/session-<hash>.jsonl cache.
    // Full reads are written by read-once/hook.sh (no "partial" field).
    // Partial reads are written by dhx-read-partial-cache.sh ({"partial":true}).
    // Any error falls through to emit the "no read" advisory (safe default).
    let hasFullRead = false;
    let hasPartialRead = false;
    try {
      const sessionId = data.session_id;
      if (sessionId) {
        const hash = crypto.createHash('sha256')
          .update(sessionId)
          .digest('hex')
          .slice(0, 16);
        const cachePath = path.join(os.homedir(), '.claude', 'read-once', `session-${hash}.jsonl`);
        if (fs.existsSync(cachePath)) {
          const resolvedTarget = path.resolve(filePath);
          const contents = fs.readFileSync(cachePath, 'utf8');
          const lines = contents.split('\n');
          for (const line of lines) {
            if (!line.trim()) continue;
            try {
              const entry = JSON.parse(line);
              if (entry && typeof entry.path === 'string' &&
                  path.resolve(entry.path) === resolvedTarget) {
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
