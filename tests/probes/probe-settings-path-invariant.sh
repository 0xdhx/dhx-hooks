#!/bin/bash
# Probe: canonical settings.json resolution must land on the same inode from both
# the Node path (statusline-wrapper.js::collectSnapshot → hashWarnSettings) and the
# Bash path (dhx-health-check.sh plugin-keys jq check). Silent divergence would
# mean the drift hash and plugin-keys check read different files — no error,
# just subtly wrong behavior across an invariant no single file owns.
#
# Backs architecture.md § Settings file chain.
# Run: bash tests/probes/probe-settings-path-invariant.sh
set -uo pipefail

pass=0
fail=0

assert_eq() {
  local name="$1" a="$2" b="$3"
  if [[ "$a" == "$b" ]]; then
    echo "OK   $name"
    pass=$((pass+1))
  else
    echo "FAIL $name"
    echo "     bash: $a"
    echo "     node: $b"
    fail=$((fail+1))
  fi
}

# Bash resolver — mirrors dhx/dhx-health-check.sh:104.
bash_resolve() {
  readlink -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" 2>/dev/null
}

# Node resolver — mirrors dhx/statusline-wrapper.js:272-283.
node_resolve() {
  node -e '
    const fs = require("fs");
    const os = require("os");
    const path = require("path");
    const configDir = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), ".claude");
    try { console.log(fs.realpathSync(path.join(configDir, "settings.json"))); }
    catch { console.log(""); }
  ' 2>/dev/null
}

stat_inode() {
  [[ -n "$1" && -e "$1" ]] && stat -c %i "$1" 2>/dev/null || echo "MISSING"
}

# --- Scenario 1: current env (CLAUDE_CONFIG_DIR may or may not be set) ---
b1=$(bash_resolve)
n1=$(node_resolve)
assert_eq "current env: path strings match" "$b1" "$n1"
assert_eq "current env: inodes match"       "$(stat_inode "$b1")" "$(stat_inode "$n1")"

# --- Scenario 2: CLAUDE_CONFIG_DIR explicitly unset (fallback to ~/.claude) ---
saved_ccd="${CLAUDE_CONFIG_DIR-}"
unset CLAUDE_CONFIG_DIR
b2=$(bash_resolve)
n2=$(node_resolve)
assert_eq "unset CLAUDE_CONFIG_DIR: path strings match" "$b2" "$n2"
assert_eq "unset CLAUDE_CONFIG_DIR: inodes match"       "$(stat_inode "$b2")" "$(stat_inode "$n2")"

# --- Scenario 3: CLAUDE_CONFIG_DIR set to ~/.claude explicitly ---
export CLAUDE_CONFIG_DIR="$HOME/.claude"
b3=$(bash_resolve)
n3=$(node_resolve)
assert_eq "CLAUDE_CONFIG_DIR=~/.claude: path strings match" "$b3" "$n3"
assert_eq "CLAUDE_CONFIG_DIR=~/.claude: inodes match"       "$(stat_inode "$b3")" "$(stat_inode "$n3")"

# Restore env.
if [[ -n "$saved_ccd" ]]; then export CLAUDE_CONFIG_DIR="$saved_ccd"; else unset CLAUDE_CONFIG_DIR; fi

echo
echo "resolved (current env): $b1"
echo "$pass passed, $fail failed"
exit $fail
