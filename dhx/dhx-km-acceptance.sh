#!/usr/bin/env bash
# Patterns: HP-025
# dhx-km-acceptance.sh — once per installed Claude Code version, prove in a sandbox that CC
# still ACCEPTS what dhx-plugin-registry-heal.sh writes: for every known_marketplaces.json state
# the heal repairs, plugins register at the next launch. Exists because the heal's output was
# silently rejected by CC 2.1.272 (entries without `lastUpdated`) while every jq-level check
# stayed green, and CC auto-updates (docs/decisions.md 2026-09-15 pre-launch row).
#
# SessionStart child (session-start.sh `_dhx_child km-acceptance`). Per CC version:
#   no result, no run in flight   → start the acceptance probe DETACHED, exit 0
#   run in flight (< 15 min old)  → exit 0
#   result pass                   → exit 0, silent
#   result fail / error           → one stderr line, exit 1 (`_dhx_child` surfaces it once per
#                                   distinct message; repeats stay silent)
# The probe (tests/probes/probe-known-marketplaces-natural-heal.sh --acceptance-out) runs the
# real binary against throwaway config dirs with disableAllHooks and no API key; nothing live is
# read or written. To re-run after fixing a failure, delete the result file the message names.
#
# Version: basename of CLAUDE_CODE_EXECPATH (CC sets it to .../versions/<x.y.z>), else the
# target of ~/.local/bin/claude. Nothing resolvable → exit 0.
# Knobs: DHX_KM_ACCEPTANCE_DISABLE=1. Test seams (tests/probes/probe-km-acceptance-trigger.sh):
# DHX_HOOKS_CACHE_DIR, DHX_KM_ACCEPTANCE_PROBE.
set -uo pipefail
[[ "${DHX_KM_ACCEPTANCE_DISABLE:-0}" == "1" ]] && exit 0
export PATH="/usr/local/bin:/usr/bin:/bin${PATH:+:$PATH}"

here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
probe="${DHX_KM_ACCEPTANCE_PROBE:-$here/../tests/probes/probe-known-marketplaces-natural-heal.sh}"
if [[ -n "${DHX_HOOKS_CACHE_DIR:-}" ]]; then
  cache="$DHX_HOOKS_CACHE_DIR/km-acceptance"
elif [[ -n "${HOME:-}" ]]; then
  cache="$HOME/.cache/dhx/hooks/km-acceptance"
else
  exit 0
fi

bin="${CLAUDE_CODE_EXECPATH:-}"
if [[ -z "$bin" || ! -x "$bin" ]]; then
  bin=$(readlink -f "${HOME:-}/.local/bin/claude" 2>/dev/null || true)
fi
[[ -n "$bin" && -x "$bin" ]] || exit 0
ver=$(basename "$bin")
[[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 0
[[ -f "$probe" ]] || exit 0

result="$cache/$ver.json"
if [[ -f "$result" ]]; then
  status=$(jq -r '.status // "error"' "$result" 2>/dev/null || echo error)
  [[ "$status" == "pass" ]] && exit 0
  detail=$(jq -r '.detail // "no detail"' "$result" 2>/dev/null | head -c 160)
  printf 'km acceptance %s at CC %s: %s (re-run: rm %s)\n' "$status" "$ver" "$detail" "$result" >&2
  exit 1
fi

mkdir -p "$cache" 2>/dev/null || exit 0
running="$cache/$ver.running"
if ! mkdir "$running" 2>/dev/null; then
  age=$(( $(date +%s) - $(stat -c %Y "$running" 2>/dev/null || date +%s) ))
  (( age > 900 )) || exit 0
  rm -rf "$running" 2>/dev/null
  mkdir "$running" 2>/dev/null || exit 0
fi

# Detached: own session, every fd redirected, so neither the dispatcher nor CC waits on it.
# The inner shell guarantees a result file even when the probe dies without writing one.
setsid nohup bash -c '
  bash "$1" --acceptance-out "$2" --binary "$3" > "$4" 2>&1
  [ -f "$2" ] || printf "{\"status\":\"error\",\"detail\":\"acceptance probe exited without a result (log: %s)\"}\n" "$4" > "$2"
  rmdir "$5" 2>/dev/null
' _ "$probe" "$result" "$bin" "$cache/$ver.log" "$running" </dev/null >/dev/null 2>&1 &
exit 0
