#!/usr/bin/env bash
# probe-agent-leak-check.sh
#
# Regression probe for dhx/dhx-agent-leak-snapshot.sh (PreToolUse:Agent) +
# dhx/dhx-agent-leak-check.sh (PostToolUse:Agent).
#
# Invariant pair:
#   PreToolUse:Agent with isolation=worktree writes baseline to
#     ~/.cache/dhx/agent-leak-{session_id}.pre (git status --porcelain of cwd).
#   PostToolUse:Agent with isolation=worktree diffs current state vs baseline;
#     NEW entries in POST produce a ⚠ WORKTREE LEAK SUSPECTED advisory on
#     stdout referencing upstream issue #36182 with recovery playbook.
#
# Both hooks:
#   - silent on non-worktree isolation
#   - silent on malformed JSON
#   - silent when .git missing
#   - paired cleanup: post-hook removes baseline file
#
# Backs: docs/decisions.md 2026-04-19 agent-leak-check row.
# Companion: probe-worktree-write-guard.sh covers the top-level/Skill detector.
#
# Run: bash tests/probes/probe-agent-leak-check.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PRE="$REPO/dhx/dhx-agent-leak-snapshot.sh"
POST="$REPO/dhx/dhx-agent-leak-check.sh"

for h in "$PRE" "$POST"; do
  if [[ ! -x "$h" ]]; then
    echo "FAIL hook not found or not executable: $h"
    exit 1
  fi
done

# Isolate probe cache entries so concurrent probes don't collide
SESSION_TAG="probe-$$-$(date +%s%N)"
CACHE="$HOME/.cache/dhx"
mkdir -p "$CACHE"

# Track baseline files we create so cleanup can remove them
BASELINES=()

cleanup() {
  rm -rf "$TMP" 2>/dev/null
  for b in "${BASELINES[@]}"; do
    rm -f "$b" 2>/dev/null
  done
  # Defensive sweep for any probe-$$ entries left behind
  rm -f "$CACHE/agent-leak-probe-$$-"*.pre 2>/dev/null
}
trap cleanup EXIT

# Seed a minimal fake git repo we can mutate
TMP=$(mktemp -d)
git -C "$TMP" init -q
echo "existing" > "$TMP/baseline.txt"
git -C "$TMP" add baseline.txt >/dev/null 2>&1
git -C "$TMP" -c user.email=probe@test -c user.name=probe commit -q -m "init"

PASS=0
FAIL=0

check() {
  local name="$1" cond="$2"
  if [[ "$cond" == "pass" ]]; then
    echo "OK   $name"
    PASS=$((PASS+1))
  else
    echo "FAIL $name"
    FAIL=$((FAIL+1))
  fi
}

pre_input() {
  local sid="$1" cwd="$2" iso="${3:-worktree}" agent="${4:-test}"
  printf '{"session_id":"%s","cwd":"%s","tool_input":{"isolation":"%s","subagent_type":"%s"}}' \
    "$sid" "$cwd" "$iso" "$agent"
}

# === [1] Pre-snapshot creates baseline file ===
SID="${SESSION_TAG}-1"
BASELINES+=("$CACHE/agent-leak-${SID}.pre")
pre_input "$SID" "$TMP" | "$PRE" >/dev/null 2>&1
[[ -f "$CACHE/agent-leak-${SID}.pre" ]] && check "[1] pre-hook writes baseline file" pass || check "[1] pre-hook writes baseline file" fail

# === [2] Post-check silent when main repo unchanged ===
SID="${SESSION_TAG}-2"
BASELINES+=("$CACHE/agent-leak-${SID}.pre")
pre_input "$SID" "$TMP" | "$PRE" >/dev/null 2>&1
OUT=$(pre_input "$SID" "$TMP" | "$POST" 2>/dev/null || true)
[[ -z "$OUT" ]] && check "[2] post-hook silent when clean" pass || check "[2] post-hook silent when clean — emitted: $OUT" fail

# === [3] Post-check warns on new untracked file ===
SID="${SESSION_TAG}-3"
BASELINES+=("$CACHE/agent-leak-${SID}.pre")
pre_input "$SID" "$TMP" "worktree" "gsd-executor" | "$PRE" >/dev/null 2>&1
echo "leaked" > "$TMP/leaked-file.txt"   # simulate leak
OUT=$(pre_input "$SID" "$TMP" "worktree" "gsd-executor" | "$POST" 2>/dev/null || true)
echo "$OUT" | grep -q "LEAK SUSPECTED" && check "[3a] post-hook emits LEAK SUSPECTED" pass || check "[3a] post-hook missing warning" fail
echo "$OUT" | grep -q "leaked-file.txt" && check "[3b] warning includes filename" pass || check "[3b] warning missing filename" fail
echo "$OUT" | grep -q "36182" && check "[3c] warning cites upstream issue" pass || check "[3c] warning missing issue ref" fail
echo "$OUT" | grep -q "gsd-executor" && check "[3d] warning names subagent_type" pass || check "[3d] warning missing subagent_type" fail
echo "$OUT" | grep -q "stash" && check "[3e] warning includes recovery hint" pass || check "[3e] warning missing recovery hint" fail
rm -f "$TMP/leaked-file.txt"

# === [4] Non-worktree isolation → pre-hook silent, no baseline written ===
SID="${SESSION_TAG}-4"
BASELINES+=("$CACHE/agent-leak-${SID}.pre")
pre_input "$SID" "$TMP" "none" | "$PRE" >/dev/null 2>&1
[[ ! -f "$CACHE/agent-leak-${SID}.pre" ]] && check "[4] pre-hook skips isolation=none" pass || check "[4] pre-hook fired on isolation=none" fail

# === [5] Post-hook with no baseline → silent (paired hook didn't fire) ===
SID="${SESSION_TAG}-ghost"
OUT=$(pre_input "$SID" "$TMP" | "$POST" 2>/dev/null || true)
[[ -z "$OUT" ]] && check "[5] post-hook silent without baseline" pass || check "[5] post-hook emitted without baseline: $OUT" fail

# === [6] Malformed JSON → both hooks silent ===
OUT=$(echo 'not json' | "$PRE" 2>/dev/null || true)
[[ -z "$OUT" ]] && check "[6a] pre-hook silent on malformed JSON" pass || check "[6a] pre-hook output on malformed JSON" fail
OUT=$(echo 'not json' | "$POST" 2>/dev/null || true)
[[ -z "$OUT" ]] && check "[6b] post-hook silent on malformed JSON" pass || check "[6b] post-hook output on malformed JSON" fail

# === [7] Post-hook removes baseline file after running ===
SID="${SESSION_TAG}-7"
BASELINES+=("$CACHE/agent-leak-${SID}.pre")
pre_input "$SID" "$TMP" | "$PRE" >/dev/null 2>&1
pre_input "$SID" "$TMP" | "$POST" >/dev/null 2>&1
[[ ! -f "$CACHE/agent-leak-${SID}.pre" ]] && check "[7] baseline cleaned up post-compare" pass || check "[7] baseline leaked after compare" fail

# === [8] Pre-hook skips when cwd is already inside a worktree ===
SID="${SESSION_TAG}-8"
BASELINES+=("$CACHE/agent-leak-${SID}.pre")
# Seed fake worktree path under the tmp repo
mkdir -p "$TMP/.claude/worktrees/agent-inner"
cp -r "$TMP/.git" "$TMP/.claude/worktrees/agent-inner/" 2>/dev/null || true
pre_input "$SID" "$TMP/.claude/worktrees/agent-inner" | "$PRE" >/dev/null 2>&1
[[ ! -f "$CACHE/agent-leak-${SID}.pre" ]] && check "[8] pre-hook skips nested worktree cwd" pass || check "[8] pre-hook fired for nested worktree cwd" fail

# === [9] Cross-scenario: scenario_3's baseline was cleaned up ===
[[ ! -f "$CACHE/agent-leak-${SESSION_TAG}-3.pre" ]] && check "[9] scenario 3 baseline also cleaned" pass || check "[9] scenario 3 baseline leaked" fail

# === [10] jq missing → silent ===
# Skip: jq is a hard dependency on dhx/ infra. Verified by the `command -v jq` guard.

echo ""
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
