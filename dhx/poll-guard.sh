#!/bin/bash
# poll-guard: PreToolUse hook for Claude Code Read tool
# Patterns: HP-007, HP-028
# Rate-limits reads of background task output files to prevent busy-polling.
# Complements read-once (content dedup) with frequency rate-limiting.
#
# When a task output file is re-read within the cooldown window, blocks the
# read and tells Claude to use TaskGet instead. Escalating cooldowns:
# base -> base*2 -> base*4 (default 15s -> 30s -> 60s).
#
# Config (env vars):
#   POLL_GUARD_DISABLED=1       Disable the hook entirely
#   POLL_GUARD_MODE=deny        "deny" (default) blocks reads, "warn" allows with advisory
#   POLL_GUARD_PATTERNS         Space-separated regex patterns (default: /tasks/.*\.output$)
#   POLL_GUARD_COOLDOWN=15      Base cooldown seconds. Tiers: base, base*2, base*4
#   POLL_GUARD_NOW              Injectable epoch timestamp for testing
#   POLL_GUARD_DIR              State directory (default: ~/.claude/poll-guard)

set -euo pipefail

# D-01: Allow disabling via env var
if [ "${POLL_GUARD_DISABLED:-0}" = "1" ]; then
  exit 0
fi

# D-14: cat fail-open
INPUT=$(cat) || exit 0

# D-14: jq guard, D-15: printf for paths
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty') || exit 0
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty') || exit 0

# D-07: Narrow path match — must match task output pattern
PATTERNS="${POLL_GUARD_PATTERNS:-/tasks/.*\.output$}"
MATCH=false
for pat in $PATTERNS; do
  if grep -qE "$pat" <<< "$FILE_PATH"; then
    MATCH=true; break
  fi
done
$MATCH || exit 0

# D-08: Fail-open on missing session_id
if [ -z "$SESSION_ID" ]; then
  exit 0
fi

# Setup state directory
GUARD_DIR="${POLL_GUARD_DIR:-${HOME}/.claude/poll-guard}"
mkdir -p "$GUARD_DIR"

# Session hash (portable: sha256sum on Linux, shasum on macOS)
if command -v sha256sum >/dev/null 2>&1; then
  SESSION_HASH=$(echo -n "$SESSION_ID" | sha256sum | cut -c1-16)
else
  SESSION_HASH=$(echo -n "$SESSION_ID" | shasum -a 256 | cut -c1-16)
fi

STATE_FILE="${GUARD_DIR}/session-${SESSION_HASH}.json"
STATS_FILE="${GUARD_DIR}/stats.jsonl"

# D-17: Injectable clock
NOW=${POLL_GUARD_NOW:-$(date +%s)}

# Cleanup: hourly marker, 24h expiry (matches read-once pattern)
CLEANUP_MARKER="${GUARD_DIR}/.last-cleanup"
LAST_CLEANUP=$(cat "$CLEANUP_MARKER" 2>/dev/null || echo 0)
LAST_CLEANUP=${LAST_CLEANUP:-0}
if [ $(( NOW - LAST_CLEANUP )) -gt 3600 ]; then
  find "$GUARD_DIR" -name 'session-*.json' -mtime +1 -delete 2>/dev/null || true
  find "$GUARD_DIR" -name 'session-*.json.lock' -mtime +1 -delete 2>/dev/null || true
  printf '%s\n' "$NOW" > "$CLEANUP_MARKER"
fi

# D-13: Derive cooldown tiers from configurable base
BASE=${POLL_GUARD_COOLDOWN:-15}
COOLDOWN_TIERS=($BASE $((BASE*2)) $((BASE*4)))

# Mode: "deny" (default) blocks reads, "warn" allows with advisory
MODE="${POLL_GUARD_MODE:-deny}"

# Basename for messages
BASENAME=$(basename "$FILE_PATH")

# --- BEGIN FLOCK CRITICAL SECTION (D-11) ---
# flock prevents concurrent hooks from clobbering each other's state updates
# Uses subshell + fd 200 redirect pattern (standard flock idiom)
# flock -n (non-blocking): if lock held, subshell exits immediately -> fail-open
RESULT=$(
  (
    flock -n 200 || { echo "ALLOW_FLOCK_FAIL"; exit 0; }

    # D-12: Read state — corrupt/missing -> empty state
    STATE=$(jq '.' "$STATE_FILE" 2>/dev/null) || STATE='{"paths":{}}'

    # Look up entry for this FILE_PATH
    # D-14: jq guard on path lookup
    ENTRY=$(printf '%s' "$STATE" | jq -r --arg p "$FILE_PATH" '.paths[$p] // empty') || { echo "ALLOW_JQ_FAIL"; exit 0; }

    if [ -z "$ENTRY" ] || [ "$ENTRY" = "null" ]; then
      # First read — ALLOW
      # Record first_read in state
      NEW_STATE=$(printf '%s' "$STATE" | jq --arg p "$FILE_PATH" --argjson now "$NOW" \
        '.paths[$p] = {"last_allowed": $now, "block_count": 0}') || { echo "ALLOW_JQ_FAIL"; exit 0; }
      printf '%s\n' "$NEW_STATE" > "$STATE_FILE.$$.tmp" && mv "$STATE_FILE.$$.tmp" "$STATE_FILE"
      echo "FIRST_READ"
      exit 0
    fi

    # Parse entry fields
    LAST_ALLOWED=$(printf '%s' "$ENTRY" | jq -r '.last_allowed // 0') || { echo "ALLOW_JQ_FAIL"; exit 0; }
    BLOCK_COUNT=$(printf '%s' "$ENTRY" | jq -r '.block_count // 0') || { echo "ALLOW_JQ_FAIL"; exit 0; }

    ELAPSED=$(( NOW - LAST_ALLOWED ))

    # D-18: cooldown uses PRE-INCREMENT block_count
    TIER_INDEX=$((BLOCK_COUNT < 3 ? BLOCK_COUNT : 2))
    COOLDOWN=${COOLDOWN_TIERS[$TIER_INDEX]}

    if [ "$ELAPSED" -ge "$COOLDOWN" ]; then
      # Cooldown expired — ALLOW
      NEW_STATE=$(printf '%s' "$STATE" | jq --arg p "$FILE_PATH" --argjson now "$NOW" \
        '.paths[$p] = {"last_allowed": $now, "block_count": 0}') || { echo "ALLOW_JQ_FAIL"; exit 0; }
      printf '%s\n' "$NEW_STATE" > "$STATE_FILE.$$.tmp" && mv "$STATE_FILE.$$.tmp" "$STATE_FILE"
      echo "ALLOW:$ELAPSED"
      exit 0
    fi

    # Within cooldown — BLOCK
    # D-18: POST-INCREMENT for messages/state
    NEW_BLOCK_COUNT=$((BLOCK_COUNT + 1))
    REMAINING=$((COOLDOWN - ELAPSED))

    # Update state with incremented block_count
    NEW_STATE=$(printf '%s' "$STATE" | jq --arg p "$FILE_PATH" --argjson now "$NOW" --argjson bc "$NEW_BLOCK_COUNT" --argjson la "$LAST_ALLOWED" \
      '.paths[$p] = {"last_allowed": $la, "block_count": $bc}') || { echo "ALLOW_JQ_FAIL"; exit 0; }
    printf '%s\n' "$NEW_STATE" > "$STATE_FILE.$$.tmp" && mv "$STATE_FILE.$$.tmp" "$STATE_FILE"

    echo "BLOCK:$NEW_BLOCK_COUNT:$COOLDOWN:$REMAINING:$ELAPSED"
    exit 0

  ) 200>"$STATE_FILE.lock"
) || true
# --- END FLOCK CRITICAL SECTION ---

# Handle results from critical section
case "$RESULT" in
  FIRST_READ)
    # D-10: Stats logging — first_read event
    printf '{"ts":%d,"path":"%s","event":"first_read","session":"%s"}\n' \
      "$NOW" "$FILE_PATH" "$SESSION_HASH" >> "$STATS_FILE" 2>/dev/null || true
    exit 0
    ;;
  ALLOW_FLOCK_FAIL|ALLOW_JQ_FAIL|"")
    # Fail-open: flock contention, jq failure, or empty result
    exit 0
    ;;
  ALLOW:*)
    # Cooldown expired — allowed
    RETRY_GAP=${RESULT#ALLOW:}
    printf '{"ts":%d,"path":"%s","event":"allow","cooldown":%d,"retry_gap":%s,"block_count":0,"session":"%s"}\n' \
      "$NOW" "$FILE_PATH" "$BASE" "$RETRY_GAP" "$SESSION_HASH" >> "$STATS_FILE" 2>/dev/null || true
    exit 0
    ;;
  BLOCK:*)
    # Parse block details
    IFS=':' read -r _ NEW_BLOCK_COUNT COOLDOWN REMAINING ELAPSED <<< "$RESULT"
    ;;
  *)
    # Unknown result — fail-open
    exit 0
    ;;
esac

# D-05: Escalating messages based on NEW_BLOCK_COUNT (post-increment)
if [ "$NEW_BLOCK_COUNT" -le 1 ]; then
  # Tier 1
  REASON="poll-guard: ${BASENAME} was read ${ELAPSED}s ago. Next read in ${REMAINING}s. Consider using TaskGet to check task status."
elif [ "$NEW_BLOCK_COUNT" -le 2 ]; then
  # Tier 2
  REASON="poll-guard: ${BASENAME} -- cooldown escalated to ${COOLDOWN}s (${NEW_BLOCK_COUNT} blocks). Next read in ${REMAINING}s. Use TaskGet or continue other work."
else
  # Tier 3
  REASON="poll-guard: STOP polling ${BASENAME}. Blocked ${NEW_BLOCK_COUNT} times (cooldown: ${COOLDOWN}s, next read in ${REMAINING}s). Use TaskGet to check task status, or continue other work."
fi

# D-06: Output hookSpecificOutput JSON
if [ "$MODE" = "warn" ]; then
  # Warn mode: allow + advisory
  jq -cn --arg r "$REASON" \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":$r}}' || exit 0
else
  # Deny mode (default): block the read
  jq -cn --arg r "$REASON" \
    '{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":$r}}' || exit 0
fi

# D-10: Stats logging — block event
printf '{"ts":%d,"path":"%s","event":"block","cooldown":%s,"block_count":%s,"session":"%s"}\n' \
  "$NOW" "$FILE_PATH" "$COOLDOWN" "$NEW_BLOCK_COUNT" "$SESSION_HASH" >> "$STATS_FILE" 2>/dev/null || true

exit 0
