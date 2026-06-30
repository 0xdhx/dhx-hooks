#!/usr/bin/env bash
#
# dhx-pytest-cgroup-cap.sh — PreToolUse:Bash memory-cap interceptor (DHX-7).
# Patterns: HP-003, HP-041, HP-045
#
# Closes the DHX-7 OOM gap: dhx-test-gate.sh wraps pytest in a memory-capped
# cgroup, but ONLY at Stop-hook time around the gate's OWN runner. A subagent (or
# any mid-session tool call) that runs its OWN pytest — `pytest …`,
# `python -m pytest …`, `uv run pytest …`, a debugging one-off — does NOT pass
# through the gate, so it runs UNCAPPED and a runaway suite (memory-leak
# collection, a fork-bomb fixture, an xdist worker explosion) can OOM the whole
# WSL2 box mid-session.
#
# This hook intercepts such commands at the Bash tool call and REWRITES them,
# wrapped in the SAME `systemd-run --user --scope` MemoryMax cgroup the gate uses
# (single-sourced via dhx-cgroup-cap.sh — no copy-drift). The cap then fires
# inside the runaway pytest's OWN scope (OOM SIGKILL → exit 137), so the blast
# radius of the cap is the runaway command, never the session. PreToolUse:Bash
# fires for a SUBAGENT's Bash calls too (HP-003), which is exactly the executor /
# subagent pytest that the source incident OOM-killed.
#
# Memory-ONLY by default (no RuntimeMaxSec): the DHX-7 threat is OOM, not a hang,
# and CC's own Bash tool timeout already bounds a hung command — a runtime cap
# here would only break a legitimately-slow mid-session suite. Set
# DHX_PYTEST_CAP_RUNTIME=<sec> to opt into a runtime ceiling.
#
# Mechanism: HP-041 PreToolUse input-rewrite — hookSpecificOutput.updatedInput
# .command paired with permissionDecision "allow", applied on exit 0. The wrapped
# command's real exit code propagates because `systemd-run --scope` runs
# synchronously and returns the child's status (the same propagation the gate
# relies on for its 137/143 fail-open cascade); no pipe, so no PIPESTATUS dance.
#
# Config (env; per-project .claude/test-gate.json unification is a documented
# deferral — see docs/decisions.md DHX-7 row):
#   DHX_PYTEST_CAP_MEM      memory ceiling (default 4G; matches the gate default)
#   DHX_PYTEST_CAP_RUNTIME  runtime ceiling in seconds (default: none)
#
# FAIL-OPEN: emits {} (run the command unchanged) on ANY error, missing dep,
# non-pytest command, already-wrapped command, or absent host cgroup support. A
# broken interceptor must NEVER block or corrupt a command — a missed cap leaves
# the command exactly as uncapped as it was before this hook existed.
#
set -uo pipefail

emit_noop() { printf '{}'; exit 0; }

command -v jq >/dev/null 2>&1 || emit_noop

input=$(cat) || emit_noop
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) || emit_noop
[ -n "$cmd" ] || emit_noop

# --- Bypass: already cgroup-wrapped (avoid double-wrap / self-reference). ------
# The gate runs pytest as a Stop-hook subprocess, NOT via the Bash tool, so it
# never reaches this hook — but a manually-wrapped command (or our own rewrite,
# defensively) must pass through untouched.
case "$cmd" in
  *"systemd-run"*|*"MemoryMax"*|*"dhx-pytest-cgroup-cap"*) emit_noop ;;
esac

# --- Classify: is pytest the COMMAND being run (not merely an argument)? -------
# Anchored at command-segment HEADS so `pip install pytest`, `grep pytest …`,
# `echo pytest`, `cat pytest.ini`, and a commit message mentioning pytest do NOT
# match — only an actual pytest invocation does. Segments are split on shell
# command separators; within each, leading whitespace + env-assignments
# (FOO=bar ) are stripped before the head is matched. A shape that slips the
# classifier (a Makefile target, an aliased/scripted pytest, a conftest that
# forks its own subprocesses) falls through UNCAPPED — fail-safe: no worse than
# the pre-hook status quo. All matches use here-strings (`<<<`), never a pipe
# into grep -q, per HP-028.
is_pytest() {
  local c="$1" seg norm
  norm=$(printf '%s' "$c" | sed -E 's/(\|\||&&|[;|&()])/\n/g')
  while IFS= read -r seg; do
    # trim leading whitespace
    seg="${seg#"${seg%%[![:space:]]*}"}"
    [ -z "$seg" ] && continue
    # strip leading env-assignments (VAR=val …), repeatable
    while grep -Eq '^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+' <<< "$seg"; do
      seg=$(sed -E 's/^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+//' <<< "$seg")
    done
    # bare / path-prefixed pytest  (pytest, /x/.venv/bin/pytest, ./pytest)
    grep -Eq '^([^[:space:]]*/)?pytest([[:space:]]|$)' <<< "$seg" && return 0
    # python[3][.x] -m pytest
    grep -Eq '^([^[:space:]]*/)?python[0-9.]*[[:space:]]+-m[[:space:]]+pytest([[:space:]]|$)' <<< "$seg" && return 0
    # poetry|uv run pytest      (also path-prefixed pytest after run)
    grep -Eq '^([^[:space:]]*/)?(poetry|uv)[[:space:]]+run[[:space:]]+([^[:space:]]*/)?pytest([[:space:]]|$)' <<< "$seg" && return 0
    # poetry|uv run python -m pytest
    grep -Eq '^([^[:space:]]*/)?(poetry|uv)[[:space:]]+run[[:space:]]+([^[:space:]]*/)?python[0-9.]*[[:space:]]+-m[[:space:]]+pytest([[:space:]]|$)' <<< "$seg" && return 0
  done <<< "$norm"
  return 1
}
is_pytest "$cmd" || emit_noop

# --- Source the single-sourced cap factory (same wrap the gate builds). --------
hook_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || emit_noop
cap_lib="$hook_dir/dhx-cgroup-cap.sh"
[ -f "$cap_lib" ] || emit_noop
# shellcheck source=/dev/null
. "$cap_lib" 2>/dev/null || emit_noop
# Functions must exist after sourcing (truncated lib → fail open, run uncapped).
declare -F dhx_cgroup_available >/dev/null 2>&1 || emit_noop
declare -F dhx_cgroup_prefix_tokens >/dev/null 2>&1 || emit_noop

# Host can't honor the cap → run unchanged (uncapped, same as the gate's bare
# fallback). Capping is defense-in-depth, never a hard gate on the command.
dhx_cgroup_available || emit_noop

MEM="${DHX_PYTEST_CAP_MEM:-4G}"
TIME="${DHX_PYTEST_CAP_RUNTIME:-}"

# --- Rewrite: wrap the WHOLE original command in the cgroup scope. -------------
# The entire command (compound commands, cd-prefixes, env-prefixes included) runs
# under `bash -c '<original>'` inside the scope, so the cap covers the full
# subtree without argv-surgery. Single-quote escaping is the standard '\'' idiom;
# jq --arg then handles JSON escaping. Tokens from the factory are whitespace-free
# so the space-join is safe.
prefix=$(dhx_cgroup_prefix_tokens "$MEM" "$TIME" | tr '\n' ' ') || emit_noop
esc=${cmd//\'/\'\\\'\'}
rewritten="${prefix}bash -c '$esc'"

jq -cn --arg cmd "$rewritten" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    permissionDecisionReason: "dhx-pytest-cgroup-cap: wrapped mid-session pytest in a MemoryMax cgroup (DHX-7 OOM cap); exit code preserved",
    updatedInput: { command: $cmd }
  }
}'
