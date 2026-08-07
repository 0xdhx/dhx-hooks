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
# Budget resolution — TRUSTED env > UNTRUSTED per-project config > default:
#   DHX_PYTEST_CAP_MEM      memory ceiling. Operator-set, so TRUSTED and
#                           UNBOUNDED — an explicit value wins outright and the
#                           project config is not consulted. Default 8G.
#   DHX_PYTEST_CAP_RUNTIME  runtime ceiling in seconds (default: none)
#   <cwd>/.claude/test-gate.json `.memory_max`  — the SAME key the Stop-hook gate
#                           reads (schema: docs/troubleshooting.md). Consulted
#                           only when DHX_PYTEST_CAP_MEM is unset. REPO-CONTROLLED
#                           and therefore untrusted: strictly validated and CLAMPED
#                           to MEM_CEILING. It can LOWER the cap freely; it cannot
#                           raise it past the ceiling. Closes the DHX-7 deferral.
#
# WHY THE VALIDATION IS A SECURITY CONTROL, NOT A NICETY: the rewrite below
# FLATTENS the factory's tokens into a command STRING (`prefix + bash -c '…'`),
# unlike the gate which execs an argv ARRAY. So an unvalidated budget value is
# arbitrary command injection — `4G; rm -rf ~; echo` would land as executable
# shell in the command CC then runs. Measured 2026-08-07 before the validator
# existed. The gate's own pass-through (dhx-test-gate.sh) is safe ONLY because of
# that array/string difference; do not "simplify" this to match it.
#
# Directory resolution is stdin `.cwd` ONLY — deliberately NOT parsed out of the
# command. A `cd <dir> && pytest` parse was designed and REJECTED: the classifier
# splits on separators with a quote-blind sed, so quoted text can manufacture a
# fake `cd` candidate; and one Bash input can run pytest in two repos while this
# hook creates exactly ONE outer scope, so "first config wins" is an invented
# policy, not shell semantics. Consequence, accepted and documented: a
# cross-repo invocation (`cd /other/repo && pytest`, issued from a session whose
# .cwd is elsewhere) resolves the SESSION's config, not the target repo's — it
# falls back to the default, which is why the default is sized to cover a real
# suite rather than left at the old 4G.
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
# Session cwd — the ONLY project-config resolution key (see header). Absent or
# unparseable is fine: the budget then falls back to the default.
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null) || cwd=""

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

# --- Budget resolution (see header § Budget resolution + § security note). -----
# Default sized from a MEASURED peak: statforge's tests/test_render/
# test_espn_template.py peaks at 5,158,532 kB (4.92 GiB) and passes 177/1 when it
# has room — under the previous 4G default it was OOM-killed at 86% three times,
# surfacing as a bare "Terminated" with NO pytest output (reads as a hang, not a
# budget hit). 8G is ~62% headroom over that peak and still ~4.6x below the
# ~37 GB runaway DHX-7 exists to contain.
DEFAULT_MEM="8G"
# Applies ONLY to the untrusted repo-controlled config, never to the trusted env.
MEM_CEILING="8G"

# Strict grammar: digits + at most one K/M/G/T suffix. Rejects whitespace, shell
# metacharacters, newlines, "infinity", "%"-relative specs, leading zero/zero,
# and the empty string. Deliberately NARROWER than systemd's own accepted syntax
# — this value is interpolated into a command string, so the grammar is the
# injection boundary.
_mem_valid() { [[ "$1" =~ ^[1-9][0-9]*[KMGT]?$ ]]; }

# Normalize to bytes for the ceiling comparison. Suffixless = already bytes.
_mem_bytes() {
  local v="$1" n="${1%[KMGT]}"
  case "$v" in
    *K) echo $(( n * 1024 )) ;;
    *M) echo $(( n * 1024 * 1024 )) ;;
    *G) echo $(( n * 1024 * 1024 * 1024 )) ;;
    *T) echo $(( n * 1024 * 1024 * 1024 * 1024 )) ;;
    *)  echo "$v" ;;
  esac
}

if [ -n "${DHX_PYTEST_CAP_MEM:-}" ]; then
  # Trusted operator override — wins outright, unbounded, config not consulted.
  MEM="$DHX_PYTEST_CAP_MEM"
else
  MEM="$DEFAULT_MEM"
  cfg="$cwd/.claude/test-gate.json"
  if [ -n "$cwd" ] && [ -f "$cfg" ] && [ -r "$cfg" ]; then
    # `if type == "string"` (not `// empty`) so a numeric/bool/null memory_max is
    # REJECTED rather than stringified into the command.
    cfg_mem=$(jq -r 'if (.memory_max | type) == "string" then .memory_max else empty end' \
                "$cfg" 2>/dev/null) || cfg_mem=""
    if [ -n "$cfg_mem" ] && _mem_valid "$cfg_mem"; then
      if [ "$(_mem_bytes "$cfg_mem")" -le "$(_mem_bytes "$MEM_CEILING")" ]; then
        MEM="$cfg_mem"
      else
        MEM="$MEM_CEILING"   # clamp: a repo may lower the cap, never raise it
      fi
    fi
    # Malformed / hostile / non-string value → keep DEFAULT_MEM. NEVER emit {}
    # here: a bad config must not silently un-cap the command.
  fi
fi
TIME="${DHX_PYTEST_CAP_RUNTIME:-}"

# Belt-and-suspenders: whatever path produced MEM, it must satisfy the grammar
# before it is interpolated. An env override that fails this falls back to the
# default rather than injecting.
_mem_valid "$MEM" || MEM="$DEFAULT_MEM"

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
