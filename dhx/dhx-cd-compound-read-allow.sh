#!/usr/bin/env bash
# dhx-cd-compound-read-allow.sh — RETIRED 2026-09-04. Inert stub: drains stdin, exits 0.
# Patterns: HP-012
#
# WHY THIS FILE STILL EXISTS. Hook REGISTRATION is frozen at session start (HP-012) while
# hook BODIES are read at invocation, so every session that was running when the manifest
# entry was removed keeps invoking this path on every Bash call until it exits. A missing
# file would surface as a hook error on each of those calls; an inert file is silent.
# Delete this stub and its ~/.claude/hooks/ symlink only after those registrations drain
# (docs/prompts/done/2026-09-04-cd-compound-read-allow-retirement-prompt.md § 3.1 step 6).
#
# WHY IT WAS RETIRED. The hook was a command-mutating workaround for CC 2.1.259's
# bypass-immune `deniedPathInsideDirectory` circuit. That registry entry is absent from
# 2.1.260 and 2.1.261; the surviving `cd-compound-read` ask is `type:"other"` with no
# `circuitBreaker`, so `defaultMode: bypassPermissions` clears it — the hook had zero
# prompt-suppression benefit on the shipping build. Independently, both arms were defective:
# ARM 1's word splitter did not honour backslash-escaped spaces and could silently change what
# a command searched for; ARM 2's ` -- -` marker landed AFTER the pattern, where CC's
# extractor has already stopped honouring `--`, so it never suppressed the `.` default and
# instead added two junk operands. The earlier claim that the marker flipped the extractor's
# end-of-options flag was false for a post-pattern marker. Evidence and version table:
# docs/decisions.md 2026-09-04 row, HP-060. The full implementation is in git history
# (`git show 1d47131:dhx/dhx-cd-compound-read-allow.sh`).
#
# The drift monitor that replaced it: scripts/verify-cc-circuit-breakers.sh (session-start).
#
# Drain stdin before exiting so the writer never sees EPIPE (CC hands every PreToolUse hook
# the payload; a hook that exits first turns that write into a SIGPIPE on the other end).
cat >/dev/null 2>&1
exit 0
