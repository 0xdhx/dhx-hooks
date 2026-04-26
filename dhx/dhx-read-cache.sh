#!/usr/bin/env bash
# dhx-read-cache.sh — PreToolUse:Read hook (sole writer, owned by dhx/)
# Patterns: HP-007, HP-017, HP-020
#
# Replaces the 2026-04-15 split between Boucle's ~/.claude/read-once/hook.sh
# (full-read writer) and dhx/dhx-read-partial-cache.sh (partial-read writer).
# Single writer, single XDG-cache cache file (~/.cache/dhx/read-cache.jsonl),
# emits {"path":<abs>,"ts":<unix>,"source":"read","partial":true?} entries.
#
# D-13 PRUNE BLOCK (supersedes D-02): rename-then-append-back pattern wrapped
# in `flock -n` (non-blocking). Sequence: mv $CACHE $CACHE.prune → concurrent
# writers' `>>` immediately land on the NEW (post-mv) empty $CACHE → awk
# filters survivors from $CACHE.prune and APPENDS to $CACHE (O_APPEND
# interleaves cleanly with the lock-free appenders) → rm $CACHE.prune.
# Marker write is INSIDE the flock subshell. D-14: env var
# DHX_READ_CACHE_TEST_PAUSE_MS forces a deterministic sleep between mv and
# append-back for adversarial probe testing (default unset = no-op).
#
# INVARIANT: per-write `>>` appends are lock-free (REQ READ-06, O_APPEND
# atomicity verified 2026-04-25, 20-writer × 50-line probe; this commit
# escalates to 50-writer regression gate via probe-read-cache-concurrency.sh).
# flock applies ONLY to the prune-rewrite block (D-13 scope).
#
# D-17 INVARIANT (partial-write semantics): writers MUST NOT emit
# `partial:true` with `source:"write"`. `partial` semantics apply only to
# Read-tool partial loads (offset/limit). The guard (dhx-read-guard.js)
# treats any `partial:true` entry as partial regardless of `source`, by
# design (defense-in-depth: if a writer ever regresses and emits the
# forbidden combo, guard degrades safely to PARTIAL-READ NOTE rather than
# incorrectly suppressing as a full read).
#
# Schema (D-05, D-07, D-08, D-17):
#   {"path":<abs>, "ts":<unix>, "source":"read", "partial":true?}
# `source:"read"` distinguishes from `dhx-write-cache.sh` entries (`source:"write"`).
# Legacy entries (no `source` field) treated as "read" by guard's null-safe loop (D-07).
# `source:"write"` + `partial:true` is FORBIDDEN per D-17.
#
# Fires: PreToolUse on Read tool
# Action: cache-write only, no stdout, no blocking

set -uo pipefail   # NOT -e; never fail the tool call on hook error (per dhx convention)

INPUT=$(cat)

# Fast path: full-read common case (~95%+) — case-statement avoids 4 jq forks
case "$INPUT" in
  *'"offset"'*|*'"limit"'*) IS_PARTIAL_CANDIDATE=1 ;;
  *) IS_PARTIAL_CANDIDATE=0 ;;
esac

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$FILE_PATH" ] && exit 0

# Belt-and-suspenders: case match catches the common path; jq returns empty
# if fields are present-but-null (D-07 schema treats null/absent equivalently)
if [ "$IS_PARTIAL_CANDIDATE" = "1" ]; then
  OFFSET=$(echo "$INPUT" | jq -r '.tool_input.offset // empty' 2>/dev/null)
  LIMIT=$(echo "$INPUT" | jq -r '.tool_input.limit // empty' 2>/dev/null)
  if [ -z "$OFFSET" ] && [ -z "$LIMIT" ]; then
    PARTIAL_MARKER=""
  else
    PARTIAL_MARKER=',"partial":true'
  fi
else
  PARTIAL_MARKER=""
fi

CACHE_DIR="${HOME}/.cache/dhx"
CACHE="${CACHE_DIR}/read-cache.jsonl"
mkdir -p "$CACHE_DIR"

RESOLVED=$(realpath "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")

# REQ READ-06: O_APPEND atomicity — bash `>>` is one open(O_APPEND)+write()
# per invocation, atomic up to PIPE_BUF=4096 on Linux/WSL2 ext4.
# (D-17 invariant: source:"read" hardcoded here; only Read-tool entries have
# source:"read", and only those may carry partial:true.)
echo "{\"path\":\"$RESOLVED\",\"ts\":$(date +%s),\"source\":\"read\"${PARTIAL_MARKER}}" >> "$CACHE"

# Hourly TTL prune (D-13: rename-then-append-back inside flock -n subshell)
NOW=$(date +%s)
CLEANUP_MARKER="${CACHE_DIR}/.last-cleanup"
LOCK="${CACHE_DIR}/.cache.lock"
# Outer gate: cheap pre-check to avoid spawning the lock subshell unnecessarily.
# The IN-LOCK re-check (D-13) is the authoritative one; this is just an optimization.
LAST_CLEANUP_OUTER=$(cat "$CLEANUP_MARKER" 2>/dev/null || echo 0)
LAST_CLEANUP_OUTER=${LAST_CLEANUP_OUTER:-0}
if [ $(( NOW - LAST_CLEANUP_OUTER )) -gt 3600 ]; then
  (
    flock -n 200 || exit 0
    # D-13: re-read marker INSIDE the lock — closes thundering-herd flagged
    # in Codex review (multiple writers all observed stale marker pre-lock).
    LAST_CLEANUP=$(cat "$CLEANUP_MARKER" 2>/dev/null || echo 0)
    LAST_CLEANUP=${LAST_CLEANUP:-0}
    [ $(( NOW - LAST_CLEANUP )) -gt 3600 ] || exit 0
    CUTOFF=$(( NOW - 7200 ))
    # D-13: rename-then-append-back. Concurrent writers' `>>` to $CACHE will
    # land on the new (post-mv) empty file; awk reads $CACHE.prune (which
    # captured any in-flight pre-rename writes) and APPENDS the survivors
    # back to $CACHE (O_APPEND atomicity preserves both awk output and
    # concurrent appends).
    mv "$CACHE" "${CACHE}.prune"
    # D-14: adversarial probe pause — env-var gated. Default unset = no-op.
    # When set (e.g., DHX_READ_CACHE_TEST_PAUSE_MS=200 from probe), forces
    # a deterministic sleep between mv and append-back so the adversarial
    # probe can spawn concurrent appenders during a known window.
    [ -n "${DHX_READ_CACHE_TEST_PAUSE_MS:-}" ] && sleep "$(awk -v ms="$DHX_READ_CACHE_TEST_PAUSE_MS" 'BEGIN { print ms/1000 }')"
    awk -F'"ts":' -v cutoff="$CUTOFF" '
      NF>=2 { split($2, a, /[^0-9]/); if (a[1]+0 >= cutoff) print }
    ' "${CACHE}.prune" >> "$CACHE"
    rm -f "${CACHE}.prune"
    # D-13: marker write INSIDE the lock subshell — closes "marker reset even
    # on skipped prune" flagged in Gemini review.
    echo "$NOW" > "$CLEANUP_MARKER"
  ) 200>"$LOCK"
fi

exit 0
