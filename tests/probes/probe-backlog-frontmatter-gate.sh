#!/usr/bin/env bash
# Probe: backlog-frontmatter convention gate — enrollment + composition + behavior.
#
# Invariant: the hooks repo is enrolled in the cross-repo backlog-frontmatter-gate
# convention (Phase 24 collapse D-01 / INFRA-05). The convention's run-parts
# dispatcher (scripts/hooks/pre-commit) owns .git/hooks/pre-commit and COMPOSES
# the established verify-hook-patterns 8-check gate (folded behind the 05- leaf)
# with the convention's 10-backlog-frontmatter.sh gate leaf. Both gates fire; the
# backlog leaf BLOCKS a non-canonical active brief (status not in ['captured',
# 'in-progress'] or absent target_milestone) and PASSES a canonical one (status:
# captured OR in-progress + non-empty target_milestone).
#
#        the INFRA-05 intent ON THE GATE (not the dropped advisory backlog hook).
#
# How to run: bash tests/probes/probe-backlog-frontmatter-gate.sh
#
# SAFE_FOR_LIVE: yes   (structural checks are read-only; behavioral block/pass cells
#                       run entirely inside a throwaway mktemp git repo — never mutate
#                       the live hooks repo, its index, or its history)
# RUNTIME: ~2s

set -uo pipefail

PROBE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$PROBE_DIR/../.." && pwd)
cd "$REPO_ROOT" || { echo "FATAL: cannot cd to repo root $REPO_ROOT" >&2; exit 99; }

PASS=0
FAIL=0

ok()   { echo "OK   $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL $1"; FAIL=$((FAIL+1)); }

# --- structural assertions --------------------------------------------------

if [ -f scripts/hooks/pre-commit ] && [ -x scripts/hooks/pre-commit ]; then
  ok "dispatcher scripts/hooks/pre-commit exists and is executable"
else
  bad "dispatcher scripts/hooks/pre-commit missing or not executable"
fi

if [ -f scripts/hooks/pre-commit.d/10-backlog-frontmatter.sh ] && [ -x scripts/hooks/pre-commit.d/10-backlog-frontmatter.sh ]; then
  ok "convention leaf 10-backlog-frontmatter.sh exists and is executable"
else
  bad "convention leaf 10-backlog-frontmatter.sh missing or not executable"
fi

if [ -f scripts/hooks/pre-commit.d/05-verify-hook-patterns.sh ] && \
   [ -x scripts/hooks/pre-commit.d/05-verify-hook-patterns.sh ] && \
   grep -q 'verify-hook-patterns.sh' scripts/hooks/pre-commit.d/05-verify-hook-patterns.sh; then
  ok "composition guard: 05-verify-hook-patterns.sh exists, executable, references the canonical gate"
else
  bad "composition guard: 05-verify-hook-patterns.sh missing/not-executable/does-not-reference verify-hook-patterns.sh"
fi

# Resolve via `git rev-parse --git-path hooks/pre-commit` — respects core.hooksPath
# AND works from both main checkout and linked worktrees (in a worktree `.git` is
# a gitdir-pointer FILE, so literal `.git/hooks/pre-commit` is not a real path).
# Compare by CONTENT (diff -q), not absolute-path equivalence: from a worktree,
# `scripts/hooks/pre-commit` resolves to the worktree's checkout of the file
# (separate inode from the main repo's), yet the live hook symlink targets the
# main repo's copy — both have the same blob, so content-equivalence is the
# correct invariant.
LIVE_HOOK=$(git rev-parse --git-path hooks/pre-commit 2>/dev/null)
if [ -n "$LIVE_HOOK" ] && [ -L "$LIVE_HOOK" ] && \
   diff -q "$LIVE_HOOK" scripts/hooks/pre-commit >/dev/null 2>&1; then
  ok "live hooks/pre-commit symlink resolves to the dispatcher (scripts/hooks/pre-commit content)"
else
  bad "live hooks/pre-commit ($LIVE_HOOK) is not a symlink whose target matches scripts/hooks/pre-commit"
fi

# --- behavioral block/pass (isolated throwaway repo) ------------------------
# node must be on PATH for the gate's validator; if absent the gate fail-OPENs
# (exit 0) by contract, so SKIP the two behavioral cells rather than FAIL.
if ! command -v node >/dev/null 2>&1; then
  ok "behavioral block case (skipped: node absent — gate fail-OPEN contract)"
  ok "behavioral pass case (skipped: node absent — gate fail-OPEN contract)"
else
  TMP=$(mktemp -d) || { echo "FATAL: mktemp failed" >&2; exit 99; }
  trap 'rm -rf "$TMP"' EXIT

  (
    cd "$TMP" || exit 99
    git init -q
    git config user.name  "ib4-probe"
    git config user.email "ib4-probe@example.invalid"
    git config commit.gpgsign false

    # Copy the dispatcher + both leaves + the validator at their repo-relative paths.
    mkdir -p scripts/hooks/pre-commit.d scripts/lib
    cp "$REPO_ROOT/scripts/hooks/pre-commit"                                scripts/hooks/pre-commit
    cp "$REPO_ROOT/scripts/hooks/pre-commit.d/10-backlog-frontmatter.sh"    scripts/hooks/pre-commit.d/10-backlog-frontmatter.sh
    cp "$REPO_ROOT/scripts/lib/backlog-frontmatter-validator.cjs"           scripts/lib/backlog-frontmatter-validator.cjs
    chmod +x scripts/hooks/pre-commit scripts/hooks/pre-commit.d/10-backlog-frontmatter.sh
    # NOTE: intentionally OMIT the 05- leaf — the behavioral cells exercise the
    # backlog convention gate in isolation; the 05- gate is the live repo's and
    # would block on this temp repo's missing docs/hook-patterns.md.

    # Install the .git/hooks/pre-commit symlink to the copied dispatcher.
    ln -s "$TMP/scripts/hooks/pre-commit" "$(git rev-parse --git-path hooks)/pre-commit"

    mkdir -p .planning/backlog
  )

  # Block case: status: active (NOT in ALLOWED_ACTIVE_STATUS=['captured']).
  cat > "$TMP/.planning/backlog/probe-block.md" <<'EOF'
---
title: probe block fixture
created: 2026-05-22T00:00:00Z
status: active
target_milestone: next
---
body
EOF
  block_rc=0
  ( cd "$TMP" && git add .planning/backlog/probe-block.md && git commit -q -m "block" ) >/dev/null 2>&1 || block_rc=$?
  if [ "$block_rc" -ne 0 ]; then
    ok "behavioral block case: non-canonical status: active is BLOCKED"
  else
    bad "behavioral block case: status: active should have blocked but commit succeeded"
  fi
  ( cd "$TMP" && git rm -q --cached --ignore-unmatch .planning/backlog/probe-block.md >/dev/null 2>&1; rm -f .planning/backlog/probe-block.md ) || true

  # Pass case: status: captured + non-empty target_milestone.
  cat > "$TMP/.planning/backlog/probe-pass.md" <<'EOF'
---
title: probe pass fixture
created: 2026-05-22T00:00:00Z
status: captured
target_milestone: next
---
body
EOF
  pass_rc=0
  ( cd "$TMP" && git add .planning/backlog/probe-pass.md && git commit -q -m "pass" ) >/dev/null 2>&1 || pass_rc=$?
  if [ "$pass_rc" -eq 0 ]; then
    ok "behavioral pass case: status: captured + target_milestone commits clean"
  else
    bad "behavioral pass case: canonical brief should have committed but was blocked"
  fi

  # Case 1b — pass: status: in-progress + non-empty target_milestone.
  # 'in-progress' is a canonical active status (skills backlog-close.cjs:44 +
  # backlog-regen.cjs:232 both honor {captured,in-progress,''}); the gate's
  # ALLOWED_ACTIVE_STATUS enum was widened to match in cross-repo a5a659a,
  # propagated to hooks in a81706b. Mirrors cross-repo Case 1b. Guards against
  # regression back to a captured-only enum.
  cat > "$TMP/.planning/backlog/probe-pass-in-progress.md" <<'EOF'
---
title: probe pass fixture (in-progress)
created: 2026-05-22T00:00:00Z
status: in-progress
target_milestone: next
---
body
EOF
  pass_ip_rc=0
  ( cd "$TMP" && git add .planning/backlog/probe-pass-in-progress.md && git commit -q -m "pass-in-progress" ) >/dev/null 2>&1 || pass_ip_rc=$?
  if [ "$pass_ip_rc" -eq 0 ]; then
    ok "behavioral pass case (1b): status: in-progress + target_milestone commits clean"
  else
    bad "behavioral pass case (1b): canonical in-progress brief should have committed but was blocked"
  fi
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
