#!/usr/bin/env bash
# probe-stale-worktree-sweep.sh
#
# Regression probe for dhx/dhx-stale-worktree-sweep.sh (SessionStart hook).
#
# Invariants exercised:
#   Gate 1 (PID liveness): a locked worktree whose lock PID is alive is SILENTLY SKIPPED.
#   Gate 2 (clean tree):   a locked worktree with uncommitted changes is SKIPPED WITH REASON.
#   Gate 3 (merged base):  a locked worktree with commits not on dev/main/master is SKIPPED WITH REASON.
#   All pass:              a locked worktree with no uncommitted changes and a merged base is REMOVED.
#   Non-locked:            an unlocked worktree is IGNORED (not swept, not reported).
#   No-op:                 a repo with no worktrees produces silent exit 0.
#
# Backs: docs/decisions.md 2026-04-19 stale-worktree-sweep row.
#
# Run: bash tests/probes/probe-stale-worktree-sweep.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$REPO/dhx/dhx-stale-worktree-sweep.sh"

if [[ ! -x "$HOOK" ]]; then
  echo "FAIL hook not found or not executable: $HOOK"
  exit 1
fi

TMP=$(mktemp -d -t probe-stale-wt-sweep-XXXXXX)
cleanup() { rm -rf "$TMP" 2>/dev/null; }
trap cleanup EXIT

PASSED=0
FAILED=0

_assert() {
  local name="$1" expect="$2" actual="$3"
  if [[ "$actual" == *"$expect"* ]]; then
    echo "OK   $name"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL $name"
    echo "     expected substring: $expect"
    echo "     actual: $actual"
    FAILED=$((FAILED + 1))
  fi
}

_assert_not() {
  local name="$1" notexpect="$2" actual="$3"
  if [[ "$actual" != *"$notexpect"* ]]; then
    echo "OK   $name"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL $name"
    echo "     should NOT contain: $notexpect"
    echo "     actual: $actual"
    FAILED=$((FAILED + 1))
  fi
}

# ------------------------------------------------------------------
# Scenario A: repo with no worktrees → silent exit 0
# ------------------------------------------------------------------
REPO_A="$TMP/a"
mkdir -p "$REPO_A" && cd "$REPO_A"
git init -q -b main
git commit -q --allow-empty -m "initial"

OUT=$(echo "{\"cwd\":\"$REPO_A\"}" | bash "$HOOK" 2>&1)
RC=$?
_assert "A1: no worktrees exits silently" "" "$OUT"
_assert "A1: no worktrees exits 0" "0" "$RC"

# ------------------------------------------------------------------
# Scenario B: locked worktree, alive PID → silent skip (respect lock)
# ------------------------------------------------------------------
REPO_B="$TMP/b"
mkdir -p "$REPO_B" && cd "$REPO_B"
git init -q -b main
git commit -q --allow-empty -m "initial"

WT_B="$REPO_B/.claude/worktrees/wt-live"
mkdir -p "$(dirname "$WT_B")"
git worktree add -q -b wt-live-branch "$WT_B"
# Use this probe's own PID as "alive"
echo "claude agent wt-live (pid $$)" > "$REPO_B/.git/worktrees/wt-live/locked"

OUT=$(echo "{\"cwd\":\"$REPO_B\"}" | bash "$HOOK" 2>&1)
_assert "B1: alive-PID locked worktree: silent" "" "$OUT"
# Verify worktree still exists
if [[ -d "$WT_B" ]]; then
  echo "OK   B2: alive-PID worktree preserved on disk"; PASSED=$((PASSED + 1))
else
  echo "FAIL B2: alive-PID worktree was removed"; FAILED=$((FAILED + 1))
fi

# ------------------------------------------------------------------
# Scenario C: locked worktree, dead PID, dirty tree → skip with reason
# ------------------------------------------------------------------
REPO_C="$TMP/c"
mkdir -p "$REPO_C" && cd "$REPO_C"
git init -q -b main
git commit -q --allow-empty -m "initial"

WT_C="$REPO_C/.claude/worktrees/wt-dirty"
mkdir -p "$(dirname "$WT_C")"
git worktree add -q -b wt-dirty-branch "$WT_C"
# Create uncommitted change
echo "uncommitted" > "$WT_C/NEW_FILE.txt"
# Find a guaranteed-dead PID: use a large value unlikely to be allocated
DEAD_PID=999999
while kill -0 "$DEAD_PID" 2>/dev/null; do DEAD_PID=$((DEAD_PID + 1)); done
echo "claude agent wt-dirty (pid $DEAD_PID)" > "$REPO_C/.git/worktrees/wt-dirty/locked"

OUT=$(echo "{\"cwd\":\"$REPO_C\"}" | bash "$HOOK" 2>&1)
_assert "C1: dirty-tree worktree skipped with warning" "need manual review" "$OUT"
_assert "C1: dirty-tree reason cites uncommitted" "uncommitted" "$OUT"
_assert_not "C2: dirty-tree NOT reported as swept" "swept" "$OUT"
if [[ -d "$WT_C" ]]; then
  echo "OK   C3: dirty-tree worktree preserved"; PASSED=$((PASSED + 1))
else
  echo "FAIL C3: dirty-tree worktree was removed"; FAILED=$((FAILED + 1))
fi

# ------------------------------------------------------------------
# Scenario D: locked worktree, dead PID, clean tree, unmerged commits → skip with reason
# ------------------------------------------------------------------
REPO_D="$TMP/d"
mkdir -p "$REPO_D" && cd "$REPO_D"
git init -q -b main
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "initial"

WT_D="$REPO_D/.claude/worktrees/wt-unmerged"
mkdir -p "$(dirname "$WT_D")"
git worktree add -q -b wt-unmerged-branch "$WT_D"
# Add a commit on the worktree branch that is NOT on main
( cd "$WT_D" && \
  echo "on-branch-only" > feature.txt && \
  git add feature.txt && \
  git -c user.email=t@t -c user.name=t commit -q -m "feature commit" )

echo "claude agent wt-unmerged (pid $DEAD_PID)" > "$REPO_D/.git/worktrees/wt-unmerged/locked"

OUT=$(echo "{\"cwd\":\"$REPO_D\"}" | bash "$HOOK" 2>&1)
_assert "D1: unmerged-commits skipped with warning" "unmerged commit" "$OUT"
_assert_not "D2: unmerged NOT reported as swept" "swept" "$OUT"
if [[ -d "$WT_D" ]]; then
  echo "OK   D3: unmerged-commits worktree preserved"; PASSED=$((PASSED + 1))
else
  echo "FAIL D3: unmerged-commits worktree was removed"; FAILED=$((FAILED + 1))
fi

# ------------------------------------------------------------------
# Scenario E: locked, dead PID, clean tree, merged base → SWEEP
# ------------------------------------------------------------------
REPO_E="$TMP/e"
mkdir -p "$REPO_E" && cd "$REPO_E"
git init -q -b main
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "initial"

WT_E="$REPO_E/.claude/worktrees/wt-stale"
mkdir -p "$(dirname "$WT_E")"
# Create a new branch at main's commit, then add worktree on it. Since HEAD
# equals main's commit, merge-base --is-ancestor returns true (trivially merged).
git branch -q wt-stale-branch main
git worktree add -q "$WT_E" wt-stale-branch
echo "claude agent wt-stale (pid $DEAD_PID)" > "$REPO_E/.git/worktrees/wt-stale/locked"

OUT=$(echo "{\"cwd\":\"$REPO_E\"}" | bash "$HOOK" 2>&1)
_assert "E1: merged+clean locked worktree is swept" "swept 1" "$OUT"
if [[ ! -d "$WT_E" ]]; then
  echo "OK   E2: merged+clean worktree removed from disk"; PASSED=$((PASSED + 1))
else
  echo "FAIL E2: merged+clean worktree still on disk"; FAILED=$((FAILED + 1))
fi

# ------------------------------------------------------------------
# Scenario F: non-locked worktree → ignored (not swept, not warned)
# ------------------------------------------------------------------
REPO_F="$TMP/f"
mkdir -p "$REPO_F" && cd "$REPO_F"
git init -q -b main
git commit -q --allow-empty -m "initial"

WT_F="$REPO_F/.claude/worktrees/wt-unlocked"
mkdir -p "$(dirname "$WT_F")"
git worktree add -q -b wt-unlocked-branch "$WT_F"
# Explicitly NO locked file

OUT=$(echo "{\"cwd\":\"$REPO_F\"}" | bash "$HOOK" 2>&1)
_assert "F1: unlocked worktree produces no output" "" "$OUT"
if [[ -d "$WT_F" ]]; then
  echo "OK   F2: unlocked worktree preserved"; PASSED=$((PASSED + 1))
else
  echo "FAIL F2: unlocked worktree was touched"; FAILED=$((FAILED + 1))
fi

# ------------------------------------------------------------------
# Scenario G: suppression env var short-circuits everything
# ------------------------------------------------------------------
# Reuse a dirty stale worktree but with DHX_SKIP_STALE_WORKTREE_SWEEP=1
REPO_G="$TMP/g"
mkdir -p "$REPO_G" && cd "$REPO_G"
git init -q -b main
git commit -q --allow-empty -m "initial"
WT_G="$REPO_G/.claude/worktrees/wt-sup"
mkdir -p "$(dirname "$WT_G")"
git worktree add -q -b wt-sup-branch "$WT_G"
echo "x" > "$WT_G/dirty.txt"
echo "claude agent wt-sup (pid $DEAD_PID)" > "$REPO_G/.git/worktrees/wt-sup/locked"

OUT=$(DHX_SKIP_STALE_WORKTREE_SWEEP=1 bash -c "echo '{\"cwd\":\"$REPO_G\"}' | bash '$HOOK' 2>&1")
_assert "G1: suppression env var produces no output" "" "$OUT"

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
echo ""
echo "$PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]] && exit 0 || exit 1
