#!/bin/bash
# Probe: dhx-health-check.sh CLAUDE.md symlink-integrity detection (producer half).
# Runs the real SessionStart health-check in an isolated fake $HOME across four
# CLAUDE.md states and asserts the claude_md field it writes to health.json:
#   intact symlink -> ok          regular file       -> REAL_FILE
#   missing        -> MISSING      symlink->elsewhere -> WRONG_TARGET
#
# Pairs with the render half in probe-health-suffix.js (its claude_md cases assert
# the advisory tail token). Together they cover the brief's acceptance: a broken
# config symlink surfaces, an intact one stays silent.
#
# Motivating incident: $HOME/.claude/CLAUDE.md silently became a regular file and
# drifted the dotfiles backup ~8 weeks undetected.
# Run: bash tests/probes/probe-claude-md-link-check.sh
#
# SAFE_FOR_LIVE: yes  (mktemp fake $HOME per case + HOME override; the script's
#   only writes/rm land under the fake $HOME/.cache/dhx — never touches live $HOME)
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO/dhx/dhx-health-check.sh"

pass=0; fail=0
assert_eq() {
  local name="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    echo "OK   $name -> claude_md=$got"
    pass=$((pass+1))
  else
    echo "FAIL $name"
    echo "     got:  claude_md=$got"
    echo "     want: claude_md=$want"
    fail=$((fail+1))
  fi
}

# Run dhx-health-check.sh in a fake $HOME whose ~/.claude/CLAUDE.md state is set up
# by $1 (a function receiving the fake-home path). The dotfiles canonical always
# exists; cases vary only the ~/.claude/CLAUDE.md side. Echoes the claude_md field.
run_case() {
  local setup="$1" home state
  home="$(mktemp -d)"
  mkdir -p "$home/.claude" "$home/.cache/dhx" "$home/repos/dotfiles/claude"
  echo "canonical" > "$home/repos/dotfiles/claude/CLAUDE.md"
  "$setup" "$home"
  HOME="$home" CLAUDE_CONFIG_DIR="$home/.claude" \
    bash "$SCRIPT" <<<'{"session_id":"probe-claude-md"}' >/dev/null 2>&1
  state="$(jq -r '.claude_md // "ABSENT"' "$home/.cache/dhx/health.json" 2>/dev/null)"
  echo "$state"
  rm -rf "$home"
}

setup_intact()   { ln -s "$1/repos/dotfiles/claude/CLAUDE.md" "$1/.claude/CLAUDE.md"; }
setup_realfile() { echo "drifted regular file" > "$1/.claude/CLAUDE.md"; }
setup_missing()  { : ; }   # leave ~/.claude/CLAUDE.md absent
setup_wrong()    { echo other > "$1/elsewhere.md"; ln -s "$1/elsewhere.md" "$1/.claude/CLAUDE.md"; }

assert_eq "intact symlink"          "$(run_case setup_intact)"   "ok"
assert_eq "regular file (drifted)"  "$(run_case setup_realfile)" "REAL_FILE"
assert_eq "missing entirely"        "$(run_case setup_missing)"  "MISSING"
assert_eq "symlink -> wrong target" "$(run_case setup_wrong)"    "WRONG_TARGET"

echo
echo "PASS: $pass  FAIL: $fail"
exit $fail
