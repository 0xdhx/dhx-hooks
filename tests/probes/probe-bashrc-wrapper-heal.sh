#!/bin/bash
# Probe: ~/.bashrc claude() wrapper plugin-keys heal stays in sync with the
# detection logic in dhx-health-check.sh + tests/probes/probe-plugin-keys.sh.
#
# The wrapper is the durable fix for the load-gating clobber documented in
# the 2026-04-17 decisions.md row + HP-017. It pre-launch-heals the two
# enabledPlugins/extraKnownMarketplaces keys whenever they go null in
# shared settings, so the next CC session boots with the dhx plugin
# registered.
#
# Drift between the wrapper's gate jq expression and the canonical health
# check's jq expression is silent — wrapper would heal at a different
# threshold than the warning fires (or vice versa), and a future change
# to one wouldn't propagate. This probe asserts content equality across
# all three definitions so they can never diverge silently.
#
# Backs decisions.md 2026-04-17 row "plugin-keys load-gating verified +
# bashrc auto-heal". Run: bash tests/probes/probe-bashrc-wrapper-heal.sh
set -uo pipefail

pass=0
fail=0

assert() {
  local name="$1" cond="$2"
  if eval "$cond"; then
    echo "OK   $name"
    pass=$((pass+1))
  else
    echo "FAIL $name"
    fail=$((fail+1))
  fi
}

assert_eq() {
  local name="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    echo "OK   $name"
    pass=$((pass+1))
  else
    echo "FAIL $name"
    echo "     got:  $got"
    echo "     want: $want"
    fail=$((fail+1))
  fi
}

BASHRC="$HOME/.bashrc"
HEALTH_CHECK="/home/dhx/repos/hooks/dhx/dhx-health-check.sh"
PLUGIN_KEYS_PROBE="/home/dhx/repos/hooks/tests/probes/probe-plugin-keys.sh"

# --- 1. Wrapper file exists and contains the heal block ---
assert "bashrc exists" "[[ -f '$BASHRC' ]]"
assert "claude() function defined" "grep -qE '^claude\(\) \{' '$BASHRC'"
assert "heal block present (marketplace add)" "grep -q 'plugin marketplace add /home/dhx/repos/hooks/dhx-plugin' '$BASHRC'"
assert "heal block present (enable dhx@dhx-local)" "grep -q 'plugin enable dhx@dhx-local' '$BASHRC'"
assert "post-exit symlink repair preserved" "grep -qE 'ln -sf .\\\$canonical. .\\\$target.' '$BASHRC'"

# --- 2. jq gate expression matches across all three sites ---
# Extract just the predicate body — after `.enabledPlugins`, before `>/dev/null`
# or end-of-line. All three should be identical strings.
canonical_pred='.enabledPlugins["dhx@dhx-local"] == true and (.extraKnownMarketplaces["dhx-local"].source.path // empty) != ""'

bashrc_pred=$(grep -oE "\.enabledPlugins\[\"dhx@dhx-local\"\] == true and \(\.extraKnownMarketplaces\[\"dhx-local\"\]\.source\.path // empty\) != \"\"" "$BASHRC" | head -1)
assert_eq "bashrc heal jq predicate matches canonical" "$bashrc_pred" "$canonical_pred"

health_pred=$(grep -oE "\.enabledPlugins\[\"dhx@dhx-local\"\] == true and \(\.extraKnownMarketplaces\[\"dhx-local\"\]\.source\.path // empty\) != \"\"" "$HEALTH_CHECK" | head -1)
assert_eq "dhx-health-check.sh jq predicate matches canonical" "$health_pred" "$canonical_pred"

probe_pred=$(grep -oE "\.enabledPlugins\[\"dhx@dhx-local\"\] == true and \(\.extraKnownMarketplaces\[\"dhx-local\"\]\.source\.path // empty\) != \"\"" "$PLUGIN_KEYS_PROBE" | head -1)
assert_eq "probe-plugin-keys.sh jq predicate matches canonical" "$probe_pred" "$canonical_pred"

# 4th site (D-15 extension): scripts/install-plugin.sh
# Resolved relative to this probe so the assertion is correct in both the
# main checkout AND in worktrees under .claude/worktrees/ (where the live
# `/home/dhx/repos/hooks/scripts/install-plugin.sh` may not yet exist
# pre-merge). The other 3 sites use absolute live paths because BASHRC
# lives in $HOME (not in-repo) and the existing convention predates
# parallel-execution worktree usage.
INSTALL_PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/install-plugin.sh"
install_pred=$(grep -oE "\.enabledPlugins\[\"dhx@dhx-local\"\] == true and \(\.extraKnownMarketplaces\[\"dhx-local\"\]\.source\.path // empty\) != \"\"" "$INSTALL_PLUGIN" | head -1)
assert_eq "install-plugin.sh jq predicate matches canonical" "$install_pred" "$canonical_pred"

# --- 3. Wrapper uses `command claude` for heal subcommands so it doesn't recurse ---
# Without `command`, the heal calls would re-enter the wrapper function and loop.
assert "heal uses 'command claude' (no recursion)" \
  "grep -E 'command claude plugin (marketplace add|enable)' '$BASHRC' | wc -l | grep -q '^2$'"

# --- 4. Heal output suppressed to keep happy path silent ---
assert "marketplace add output suppressed" \
  "grep -q 'plugin marketplace add /home/dhx/repos/hooks/dhx-plugin >/dev/null 2>&1' '$BASHRC'"
assert "enable output suppressed" \
  "grep -q 'plugin enable dhx@dhx-local >/dev/null 2>&1' '$BASHRC'"

# --- 5. Heal runs BEFORE the wrapped claude invocation, not after ---
# Line number of marketplace-add must be lower than line number of `command claude "$@"`.
add_line=$(grep -n 'plugin marketplace add /home/dhx/repos/hooks/dhx-plugin' "$BASHRC" | head -1 | cut -d: -f1)
exec_line=$(grep -n 'command claude "\$@"' "$BASHRC" | head -1 | cut -d: -f1)
if [[ -n "$add_line" && -n "$exec_line" && "$add_line" -lt "$exec_line" ]]; then
  echo "OK   heal precedes wrapped exec (add@$add_line < exec@$exec_line)"
  pass=$((pass+1))
else
  echo "FAIL heal precedes wrapped exec (add=$add_line exec=$exec_line)"
  fail=$((fail+1))
fi

echo
echo "$pass passed, $fail failed"
exit $fail
