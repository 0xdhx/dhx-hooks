#!/bin/bash
# Probe: dhx-health-check.sh scopes its drift-snapshot `rm` to THIS session only,
# even when the untrusted session_id is a glob/path-injection attempt (WR-01,
# Phase 20 code-review follow-up from 20-REVIEW.md).
#
# Bug class: SESSION_ID is read from stdin JSON (untrusted). The prune line
#   rm -f "$CACHE_DIR/drift-snapshot-${SESSION_ID}.json" \
#         "$CACHE_DIR"/drift-snapshot-${SESSION_ID}-*.json
# interpolates it UNQUOTED into a glob. A session_id of `*` expands the second
# arg to `drift-snapshot-*-*.json` and deletes EVERY session's snapshots — the
# same untrusted-input-as-filename class the read-guard hardened against (D-11).
# Fix: allowlist the UUID shape (`^[A-Za-z0-9_-]+$`) before the rm; a
# non-conforming id skips the targeted prune (the -mtime +30 catchall reclaims it).
#
# Strategy:
#   1. Static — the hook gates the drift-snapshot rm on the allowlist regex.
#   2. Behavioral (regex primitive) — the allowlist accepts UUID-shaped ids and
#      rejects every injection metachar (*, ?, [, /, \, ..).
#   3. Integration — replicate the EXACT guarded block against a fake cache with
#      two sessions' snapshots; assert SESSION_ID="*" deletes NOTHING, and a real
#      UUID deletes ONLY its own files. A static check ties the replicated block
#      back to the hook so the two cannot silently drift.
#
# Run: bash tests/probes/probe-health-check-session-id-rm-safety.sh
# SAFE_FOR_LIVE: yes   (mktemp only; never touches $HOME or the live cache)
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO/dhx/dhx-health-check.sh"

PASS=0; FAIL=0
check() {
  local name="$1" got="$2"  # got: 1 = pass, 0 = fail
  if [[ "$got" == "1" ]]; then echo "OK   $name"; PASS=$((PASS+1));
  else echo "FAIL $name"; FAIL=$((FAIL+1)); fi
}

# --- 1. Static: the allowlist guard gates the drift-snapshot rm ---
# INVARIANT: the rm of drift-snapshot-${SESSION_ID}* is reachable ONLY when
# SESSION_ID matches ^[A-Za-z0-9_-]+$. If a refactor drops the regex from the
# guard, this fails.
if grep -qF 'if [[ -n "$SESSION_ID" && "$SESSION_ID" =~ ^[A-Za-z0-9_-]+$ ]]; then' "$HOOK"; then
  check "hook gates drift-snapshot rm on session_id allowlist (^[A-Za-z0-9_-]+\$)" 1
else
  check "hook missing session_id allowlist guard before drift-snapshot rm — WR-01 not fixed" 0
fi

# --- 2. Behavioral: the allowlist primitive accepts UUIDs, rejects injections ---
id_safe() { [[ -n "$1" && "$1" =~ ^[A-Za-z0-9_-]+$ ]]; }

# Accept: real CC UUID + plain alnum/underscore/hyphen.
ACCEPT_OK=1
for good in "a1b2c3d4-5e6f-7081-92a3-b4c5d6e7f809" "session_01" "ABC-123_x"; do
  id_safe "$good" || ACCEPT_OK=0
done
check "allowlist ACCEPTS UUID + alnum/_/- session ids" "$ACCEPT_OK"

# Reject: glob metachars + path-traversal + empty.
REJECT_OK=1
for bad in "*" "?" "a*" "[ab]" "../evil" "a/b" 'a\b' ".." "" "with space"; do
  if id_safe "$bad"; then REJECT_OK=0; echo "     leaked: '$bad' accepted"; fi
done
check "allowlist REJECTS *,?,[,/,\\,.. and empty (injection metachars)" "$REJECT_OK"

# --- 3. Integration: replicate the guarded block; cross-session files survive ---
# This block MUST mirror the hook's prune. Tie #4 below asserts the hook still
# carries the exact rm line so this replica cannot drift unnoticed.
prune_this_session() {
  local CACHE_DIR="$1" SESSION_ID="$2"
  if [[ -n "$SESSION_ID" && "$SESSION_ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
    rm -f "$CACHE_DIR/drift-snapshot-${SESSION_ID}.json" "$CACHE_DIR"/drift-snapshot-${SESSION_ID}-*.json
  fi
}

CACHE=$(mktemp -d)
trap 'rm -rf "$CACHE"' EXIT
seed_cache() {
  rm -f "$CACHE"/drift-snapshot-*.json
  : > "$CACHE/drift-snapshot-aaaa.json"
  : > "$CACHE/drift-snapshot-aaaa-p123.json"
  : > "$CACHE/drift-snapshot-bbbb.json"
  : > "$CACHE/drift-snapshot-bbbb-p456.json"
}

# 3a. Malicious session_id "*" must delete NOTHING (guard skips the rm).
seed_cache
prune_this_session "$CACHE" "*"
REMAIN=$(find "$CACHE" -name 'drift-snapshot-*.json' | wc -l | tr -d ' ')
if [[ "$REMAIN" == "4" ]]; then
  check "session_id='*' deletes nothing — all 4 cross-session snapshots survive" 1
else
  check "session_id='*' wiped snapshots — only $REMAIN/4 survived (injection succeeded)" 0
fi

# 3b. Valid UUID-shaped id deletes ONLY its own files, leaves the other session.
seed_cache
prune_this_session "$CACHE" "aaaa"
AAAA=$(find "$CACHE" -name 'drift-snapshot-aaaa*.json' | wc -l | tr -d ' ')
BBBB=$(find "$CACHE" -name 'drift-snapshot-bbbb*.json' | wc -l | tr -d ' ')
if [[ "$AAAA" == "0" && "$BBBB" == "2" ]]; then
  check "valid id 'aaaa' prunes own 2 snapshots, leaves session bbbb's 2 intact" 1
else
  check "scoped prune wrong — aaaa=$AAAA (want 0), bbbb=$BBBB (want 2)" 0
fi

# --- 4. Anti-drift: the hook still carries the exact rm line this replica mirrors ---
if grep -qF 'rm -f "$CACHE_DIR/drift-snapshot-${SESSION_ID}.json" "$CACHE_DIR"/drift-snapshot-${SESSION_ID}-*.json' "$HOOK"; then
  check "replica rm line matches the hook (probe + hook cannot silently drift)" 1
else
  check "hook drift-snapshot rm line changed — update this probe's replica" 0
fi

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]
