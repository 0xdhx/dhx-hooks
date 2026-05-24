#!/usr/bin/env bash
# dhx-read-cache.sh — PreToolUse:Read hook (partial-read detection writer)
# Patterns: HP-007, HP-017, HP-036
#
# COLLAPSED to partial-only on 2026-05-24 (Option C — read-guard fork-weight
# investigation). This hook formerly wrote a global, TTL-pruned, flock-protected
# JSONL cache of ALL reads (full + partial) at ~/.cache/dhx/read-cache.jsonl,
# consumed by dhx-read-guard.js's full-read suppress + strong-advisory paths.
# Those paths were removed (CC's native runtime owns full read-before-edit
# enforcement — see the guard header + decisions.md Option C row). The only
# surviving signal is partial-read blindness (Probe 2), so this hook now records
# ONLY partial Reads, to a SESSION-SCOPED store.
#
# Reference impl of the removed global-TTL/flock/prune machinery (D-13 prune,
# D-25 LOCK_SH race fix, O_APPEND atomicity, IN-02 realpath alignment): the
# pre-collapse SHA is pinned in docs/decisions.md (Option C row) + the Q1
# extraction-on-demand backlog brief. Recover from git if a multi-writer,
# cross-session TTL store is ever needed.
#
# DETECTION store (keyed on session_id ALONE — Probe 5 / Branch 1):
#   ~/.cache/dhx/partial-read-detect-<session_id>.jsonl
#   Entries: {"path":<abs-realpath>}
# session_id is preserved across plain /exit+--resume (HP-036) and rotates only
# on a CCS profile-swap, so session_id-alone keying loses only the rare swap case
# (fail-toward-silence — see guard header). dhx-read-guard.js is the sole reader.
#
# Why no TTL / flock / prune (the bulk of the old file): the store is per-session,
# not a 50-concurrent-sessions-sharing-one-global-file scenario. A single logical
# writer per session; bash `>>` is one open(O_APPEND)+write() (REQ READ-06),
# atomic up to PIPE_BUF=4096 on Linux/WSL2 ext4, so even concurrent subagent Reads
# (HP-003) append cleanly without a lock. The TTL/prune existed only to bound the
# shared global file; a per-session file needs no time-based expiry.
#
# Fires: PreToolUse on the Read tool.
# Action: cache-write only on a PARTIAL read; no stdout, no blocking. Full reads
#         and non-partial Reads exit silently (CC tracks them natively).

set -uo pipefail   # NOT -e; never fail the tool call on hook error (per dhx convention)

INPUT=$(cat)

# Fast path: only partial reads (offset/limit) are recorded. Case-statement
# pre-check avoids jq forks on the ~95% full-read path.
case "$INPUT" in
  *'"offset"'*|*'"limit"'*) ;;
  *) exit 0 ;;
esac

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$FILE_PATH" ] && exit 0

# Confirm it is genuinely partial: offset/limit present-and-non-null (D-07 schema
# treats null/absent equivalently — the case match above can hit on a present-but-
# null field, so re-check with jq).
OFFSET=$(echo "$INPUT" | jq -r '.tool_input.offset // empty' 2>/dev/null)
LIMIT=$(echo "$INPUT" | jq -r '.tool_input.limit // empty' 2>/dev/null)
[ -z "$OFFSET" ] && [ -z "$LIMIT" ] && exit 0

# D-11: session_id is untrusted and is a filename component. Reject-and-disable
# (NOT sanitize) if empty / contains a path separator / `..` — exit silently so we
# never write outside the cache dir or collide two session_ids onto one store.
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$SESSION_ID" ] && exit 0
case "$SESSION_ID" in
  */*|*'\'*|*..*) exit 0 ;;
esac

CACHE_DIR="${HOME}/.cache/dhx"
mkdir -p "$CACHE_DIR" 2>/dev/null || exit 0

# INVARIANT: detection store keys on session_id ALONE — NOT (session_id, ticks).
# ticks rotate on every resume (HP-016/HP-036); keying on them would miss the
# partial NOTE on every cross-session edit, not just the rare CCS-swap. The
# reader (dhx-read-guard.js) keys identically. Do not add ticks here.
DETECT="${CACHE_DIR}/partial-read-detect-${SESSION_ID}.jsonl"

# IN-02: resolve symlinks so the recorded path matches the guard's realpath lookup.
RESOLVED=$(realpath "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")

# WR-01: jq for JSONL escaping — paths containing `"` no longer break the schema.
# REQ READ-06: bash `>>` is one atomic open(O_APPEND)+write() (< PIPE_BUF); no lock
# needed (single logical writer per session; concurrent subagent appends stay
# line-atomic).
jq -cn --arg path "$RESOLVED" '{path: $path}' >> "$DETECT" 2>/dev/null

exit 0
