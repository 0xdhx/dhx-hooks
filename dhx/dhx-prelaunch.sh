#!/usr/bin/env bash
# Patterns: HP-025
# dhx-prelaunch.sh — checks that must run BEFORE Claude Code starts, because what they repair
# decides whether the dhx plugin (and every hook it registers) loads at all.
#
# Callers — the two seams every normal launch passes through (docs/decisions.md 2026-09-15
# pre-launch row):
#   ~/repos/cross-repo/health/scripts/claude-capped.sh — bare `claude`, `ccs a|b|c|d`, tmux
#     lanes; runs whether or not the clodex bridge is active.
#   ~/repos/dotfiles/bin/clodex-bridge — its first action; it is the shared settings
#     `processWrapper`, so daemon-hosted background sessions and workers pass through it.
# A capped launch through the bridge runs this twice, by design: the children are idempotent,
# ~0 s on a healthy registry, and the heal's lock serializes them. A direct
# ~/.local/bin/claude invocation bypasses both seams.
#
# Contract (the callers' own "never the reason claude fails to start"): reads no stdin, writes
# nothing to stdout, always exits 0, and bounds each child with `timeout -k`. Children write to
# stderr only under their own first-sight rules.
#
# Children, in order — the order is load-bearing:
#   dhx-plugin-keys-heal.sh      restores enabledPlugins["dhx@dhx-local"] and
#                                extraKnownMarketplaces["dhx-local"] in settings (HP-017).
#   dhx-plugin-registry-heal.sh  (DHX_REGISTRY_HEAL_SURFACE=prelaunch) repairs
#                                known_marketplaces.json, but only for a marketplace settings
#                                declares — so it runs after the keys are back.
#
# Knobs: DHX_PRELAUNCH_DISABLE=1 skips everything. Test seams (tests/probes/
# probe-prelaunch-wiring.sh): DHX_PRELAUNCH_HOOKS_DIR — where children resolve (default: this
# script's real directory); DHX_PRELAUNCH_CHILD_BOUND_S — per-child bound in seconds (default 4).
set -u
[ "${DHX_PRELAUNCH_DISABLE:-0}" = "1" ] && exit 0
export PATH="/usr/local/bin:/usr/bin:/bin${PATH:+:$PATH}"

here="${DHX_PRELAUNCH_HOOKS_DIR:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")}"
bound="${DHX_PRELAUNCH_CHILD_BOUND_S:-4}"
case "$bound" in ''|*[!0-9]*) bound=4 ;; esac

# run_child SCRIPT [VAR=value ...]
run_child() {
  local script="$here/$1"
  shift
  [ -f "$script" ] || return 0
  if command -v timeout >/dev/null 2>&1; then
    env "$@" timeout -k 1 "$bound" bash "$script" </dev/null >/dev/null || true
  else
    env "$@" bash "$script" </dev/null >/dev/null || true
  fi
  return 0
}

run_child dhx-plugin-keys-heal.sh
run_child dhx-plugin-registry-heal.sh DHX_REGISTRY_HEAL_SURFACE=prelaunch
exit 0
