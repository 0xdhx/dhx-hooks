#!/bin/bash
# Probe: the dhx plugin-keys pre-launch heal has ONE home — dhx/dhx-plugin-keys-heal.sh, run by
# dhx/dhx-prelaunch.sh from the launch wrappers — and every site that checks those keys uses one
# jq predicate.
#
# The keys (enabledPlugins["dhx@dhx-local"], extraKnownMarketplaces["dhx-local"]) are
# load-gating (HP-017): when a stale-snapshot settings rewrite drops them, the dhx plugin
# silently fails to register, so the repair must run before Claude Code starts. From 2026-04-17
# it lived in the ~/.bashrc claude() wrapper, which returns early in non-interactive shells and
# which daemon-hosted sessions never pass; on 2026-09-15 it moved to the pre-launch seam
# (docs/decisions.md 2026-09-15 plugin-keys row). This probe keeps a second copy from growing
# back in .bashrc, keeps the wrapper's post-exit settings-symlink repair (which stayed), and
# asserts predicate parity so the heal and the warning fire at the same threshold.
#
# Backs decisions.md 2026-04-17 row "plugin-keys load-gating verified +
# bashrc auto-heal". Run: bash tests/probes/probe-bashrc-wrapper-heal.sh
# SAFE_FOR_LIVE: yes   (grep-only against live `~/.bashrc` and in-repo files; no writes)
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

# In-repo sites resolve relative to this probe, so a worktree checks its own copies.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASHRC="$HOME/.bashrc"
KEYS_HEAL="$REPO/dhx/dhx-plugin-keys-heal.sh"
PRELAUNCH="$REPO/dhx/dhx-prelaunch.sh"
HEALTH_CHECK="$REPO/dhx/dhx-health-check.sh"
PLUGIN_KEYS_PROBE="$REPO/tests/probes/probe-plugin-keys.sh"
INSTALL_PLUGIN="$REPO/scripts/install-plugin.sh"

# --- 1. The .bashrc wrapper keeps its post-exit half and routes through the capped launcher ---
assert "bashrc exists" "[[ -f '$BASHRC' ]]"
assert "claude() function defined" "grep -qE '^claude\(\) \{' '$BASHRC'"
assert "post-exit symlink repair preserved" "grep -qE 'ln -sf .\\\$canonical. .\\\$target.' '$BASHRC'"
assert "post-exit hold guard preserved" "grep -q 'settings-chain.hold' '$BASHRC'"
# `command claude` resolves through PATH to ~/.local/capbin/claude (claude-capped.sh), which runs
# dhx-prelaunch.sh — that is how an interactive launch still gets the heal.
assert "wrapper execs 'command claude \"\$@\"'" "grep -q 'command claude \"\$@\"' '$BASHRC'"

# --- 2. No second copy of the heal in .bashrc ---
assert "bashrc runs no 'claude plugin marketplace add'" "! grep -q 'plugin marketplace add' '$BASHRC'"
assert "bashrc runs no 'claude plugin enable'" "! grep -q 'plugin enable dhx@dhx-local' '$BASHRC'"
assert "bashrc carries no plugin-keys predicate" "! grep -q 'enabledPlugins\[\"dhx@dhx-local\"\]' '$BASHRC'"

# --- 3. The heal lives in the pre-launch seam and spawns no Claude Code process ---
assert "dhx-plugin-keys-heal.sh exists" "[[ -f '$KEYS_HEAL' ]]"
assert "dhx-prelaunch.sh runs dhx-plugin-keys-heal.sh" "grep -qE '^run_child dhx-plugin-keys-heal\.sh' '$PRELAUNCH'"
assert "keys heal invokes no 'claude' subcommand (comments aside)" \
  "! grep -vE '^[[:space:]]*#' '$KEYS_HEAL' | grep -qE '(^|[[:space:];|&(])claude[[:space:]]+plugin'"

# --- 4. jq predicate parity across every site that checks the keys ---
canonical_pred='.enabledPlugins["dhx@dhx-local"] == true and (.extraKnownMarketplaces["dhx-local"].source.path // empty) != ""'
PRED_ERE="\.enabledPlugins\[\"dhx@dhx-local\"\] == true and \(\.extraKnownMarketplaces\[\"dhx-local\"\]\.source\.path // empty\) != \"\""
for site in "$KEYS_HEAL" "$HEALTH_CHECK" "$PLUGIN_KEYS_PROBE" "$INSTALL_PLUGIN"; do
  got=$(grep -oE "$PRED_ERE" "$site" 2>/dev/null | head -1)
  assert_eq "$(basename "$site") jq predicate matches canonical" "$got" "$canonical_pred"
done

echo
echo "$pass passed, $fail failed"
exit $fail
