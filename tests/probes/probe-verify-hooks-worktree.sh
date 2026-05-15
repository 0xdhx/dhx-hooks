#!/usr/bin/env bash
# Probe: scripts/verify-hooks.sh resolves canonical source paths via
# `git rev-parse --git-common-dir` so worktree invocation matches main-repo
# invocation.
#
#
# Invariant exercised:
#   1. From main repo root: bash scripts/verify-hooks.sh exits 0 when the
#      live ~/.claude/hooks/<name> symlink targets repo/dhx/<name>.sh.
#   2. From a worktree of the same repo: same script exits 0 (was exit 1
#      pre-fix because reverse-index keyed `worktree/dhx/<name>.sh` while
#      symlink targets resolved to `mainrepo/dhx/<name>.sh`).
#
# Fixture isolation: mktemp + fake HOME + fake git repo. Never touches
# live `~/.claude/hooks/`, live `~/.ccs/shared/settings.json`, or the
# real hooks-repo `.git/worktrees/`.
#
# How to run:
#   bash tests/probes/probe-verify-hooks-worktree.sh

# SAFE_FOR_LIVE: yes   (mktemp tmproot + fake HOME; sandboxed git repo + worktree contained in $TMPROOT; no live `~/.claude/hooks/` or `.git/worktrees/` writes)
set -uo pipefail

PASS=0
FAIL=0
check() {
  local label="$1" expect="$2" actual="$3"
  if [[ "$expect" == "$actual" ]]; then
    echo "OK   $label"
    PASS=$((PASS+1))
  else
    echo "FAIL $label  expected=$expect actual=$actual"
    FAIL=$((FAIL+1))
  fi
}

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO/scripts/verify-hooks.sh"
[[ -f "$SCRIPT" ]] || { echo "FATAL: $SCRIPT not found"; exit 2; }

TMPROOT="$(mktemp -d -t verify-hooks-worktree.XXXXXX)"
trap 'rm -rf "$TMPROOT"' EXIT

# --- Sandbox setup -----------------------------------------------------------
FAKE_REPO="$TMPROOT/repo"
FAKE_HOME="$TMPROOT/home"
FAKE_HOOKS_DIR="$FAKE_HOME/.claude/hooks"
mkdir -p "$FAKE_REPO/dhx" "$FAKE_REPO/scripts" "$FAKE_HOOKS_DIR"

# Two source files exercise the OK path; a third exercises the
# `linked as <other-name>` branch (basename-mismatch but same target).
cat > "$FAKE_REPO/dhx/sample-a.sh" <<'EOF'
#!/usr/bin/env bash
echo "sample-a"
EOF
cat > "$FAKE_REPO/dhx/sample-b.sh" <<'EOF'
#!/usr/bin/env bash
echo "sample-b"
EOF
chmod +x "$FAKE_REPO/dhx/sample-a.sh" "$FAKE_REPO/dhx/sample-b.sh"

# Copy the patched script verbatim — probe asserts on the live impl.
cp "$SCRIPT" "$FAKE_REPO/scripts/verify-hooks.sh"
chmod +x "$FAKE_REPO/scripts/verify-hooks.sh"

# Fake symlink wiring (pointing into $FAKE_REPO/dhx/).
ln -s "$FAKE_REPO/dhx/sample-a.sh" "$FAKE_HOOKS_DIR/dhx-sample-a.sh"
ln -s "$FAKE_REPO/dhx/sample-b.sh" "$FAKE_HOOKS_DIR/dhx-sample-b.sh"

# Initialize git in the fake repo + a single commit so worktree add works.
git -C "$FAKE_REPO" init -q
git -C "$FAKE_REPO" -c user.email=probe@local -c user.name=probe \
    add dhx scripts >/dev/null 2>&1
git -C "$FAKE_REPO" -c user.email=probe@local -c user.name=probe \
    commit -q -m "seed" >/dev/null 2>&1

# Disable settings.json branch (line 84-94 expects $CLAUDE_CONFIG_DIR/settings.json
# or $HOME/.claude/settings.json). Either may be absent — the script handles that
# branch defensively. We use HOME=$FAKE_HOME and unset CLAUDE_CONFIG_DIR for
# isolation — the "settings.json: not readable" branch is fine and does not
# affect exit code.

# --- Test 1: main-repo invocation --------------------------------------------
HOME="$FAKE_HOME" \
  bash "$FAKE_REPO/scripts/verify-hooks.sh" >"$TMPROOT/main.out" 2>&1
check "[1a] main-repo invocation exits 0" "0" "$?"
check "[1b] main-repo reports 2 wired sources" \
      "1" "$(grep -c '^All 2 dhx hook sources wired\.$' "$TMPROOT/main.out")"
check "[1c] main-repo lists sample-a OK" \
      "1" "$(grep -c '^  OK    sample-a\.sh' "$TMPROOT/main.out")"
check "[1d] main-repo lists sample-b OK" \
      "1" "$(grep -c '^  OK    sample-b\.sh' "$TMPROOT/main.out")"
check "[1e] no MISS lines" \
      "0" "$(grep -c '^  MISS' "$TMPROOT/main.out")"

# --- Test 2: worktree invocation ---------------------------------------------
WT="$TMPROOT/wt"
git -C "$FAKE_REPO" worktree add -q "$WT" >/dev/null 2>&1
HOME="$FAKE_HOME" \
  bash "$WT/scripts/verify-hooks.sh" >"$TMPROOT/wt.out" 2>&1
WT_RC=$?
check "[2a] worktree invocation exits 0" "0" "$WT_RC"
check "[2b] worktree reports 2 wired sources" \
      "1" "$(grep -c '^All 2 dhx hook sources wired\.$' "$TMPROOT/wt.out")"
check "[2c] worktree lists sample-a OK" \
      "1" "$(grep -c '^  OK    sample-a\.sh' "$TMPROOT/wt.out")"
check "[2d] no MISS lines from worktree" \
      "0" "$(grep -c '^  MISS' "$TMPROOT/wt.out")"

# --- Test 3: regression — pre-fix would have reported 31 MISS ---------------
# Sanity check that the resolver actually went through git common-dir, not the
# script-relative fallback. Inside the worktree, $REPO must resolve to
# $FAKE_REPO (the main-repo path), NOT $WT.
HOME="$FAKE_HOME" \
  bash -c '
    set -u
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    GCD=$(git -C "$SCRIPT_DIR" rev-parse --git-common-dir 2>/dev/null)
    REPO_RESOLVED="$(cd "$SCRIPT_DIR" && cd "$GCD/.." && pwd)"
    echo "$REPO_RESOLVED"
  ' "$WT/scripts/verify-hooks.sh" >"$TMPROOT/resolver.out" 2>&1
check "[3a] git-common-dir resolver lands on main-repo path from worktree" \
      "$FAKE_REPO" "$(cat "$TMPROOT/resolver.out")"

# --- Cleanup worktree before tmp removal -------------------------------------
git -C "$FAKE_REPO" worktree remove -f "$WT" >/dev/null 2>&1 || true

echo ""
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
