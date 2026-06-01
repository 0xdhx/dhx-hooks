#!/usr/bin/env bash
#
# dhx-pkg-install-filter.sh — PreToolUse:Bash output-reducer.
# Patterns: HP-040, HP-041
#
# Rewrites a package-manager INSTALL command (npm/pnpm/yarn install|add|ci,
# pip/pip3 install, python -m pip install, uv pip install) so a SUCCESSFUL
# install collapses to its summary, while a FAILED install passes through in
# FULL. Cuts Claude's tool-output context cost on a frequent, noisy, universal
# command class; the saving compounds across every cached-prefix re-read.
#
# HYBRID design (the key difference from a filter-in-pipe reducer like
# forgefinder's ff-test-output-filter.sh): this CAPTURES the output to a temp
# file and BRANCHES ON THE EXIT CODE, because the exit code is the authoritative
# success/failure signal and a filter inside a pipe can't see it —
#   - rc == 0 : pipe the captured output through dhx-pkg-install-summarize.sh
#               (keep/collapse/drop the success noise).
#   - rc != 0 : `cat` the captured output verbatim — the failure cause is NEVER
#               touched (HP-040: install failures — version conflicts, native
#               wheel/node-gyp build tracebacks — are exactly the detail you must
#               not drop, and their cause is an arbitrary block, not a signature).
# This resolves the tee-to-disk-vs-filter-in-pipe decision for this command
# class: compact-in-pipe on success, full-on-failure.
#
# Mechanism: CC's PreToolUse input-rewrite contract — hookSpecificOutput
# .updatedInput.command paired with permissionDecision "allow", applied on
# exit 0 (HP-041, live-verified on CC 2.1.153). The wrapped command's real exit
# code is preserved via `exit ${PIPESTATUS[0]}` (escaped so it evaluates when the
# rewritten command RUNS, not when this hook builds the string).
#
# FAIL-OPEN: emits {} (run unfiltered) on any error, missing dep, non-candidate
# command, or already-output-shaped command. A broken reducer must NEVER block
# or corrupt an install.
#
set -uo pipefail

emit_noop() { printf '{}'; exit 0; }

command -v jq >/dev/null 2>&1 || emit_noop

input=$(cat) || emit_noop
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) || emit_noop
[ -n "$cmd" ] || emit_noop

# --- Bypass: anything already output-shaped, compound, or self-referential. ---
# Compound/separator commands (&&, ||, ;, |) are bypassed because the summarizer
# only models install output — wrapping `npm install && npm run build` would feed
# the build's output through the summarizer and eat it. Conservative-but-correct:
# only a single clean install invocation is rewritten.
case "$cmd" in
  *"|"*|*">"*|*"<"*|*";"*|*"&&"*|*"||"*|*'$('*|*'`'*) emit_noop ;;
  *"dhx-pkg-install-summarize"*|*"dhx-pkg-install-filter"*) emit_noop ;;
  *"--json"*|*"--silent"*|*"--quiet"*|*" -q"*|*"--no-progress"*|*"--dry-run"*|*"--help"*|*" -h"*) emit_noop ;;
esac

# --- Candidate match: a single install-class invocation only. ---
# The leading char class is (^|[[:space:]]|/): the binary may be bare on PATH
# OR path-prefixed — `/home/u/.venv/bin/pip install`, `./venv/bin/pip install`
# (the canonical venv-direct-call pattern, common in scripts/CI/agents that
# don't rely on shell-activation state). `/` carries the same accepted
# false-positive tolerance the space anchor already has (e.g. `echo pip
# install` matches under either); fail-open + exit-code preservation keep it
# harmless. NOT covered: bare path-invoked yarn-with-no-subcommand
# (`/usr/bin/yarn` alone) — the bare-yarn matcher below stays ^-anchored;
# vanishingly rare, deliberately out of scope.
is_install() {
  local c="$1"
  # npm / pnpm  install|i|ci|add  (word-bounded so `npm info`, `npm init`,
  # `npm test`, `npm run install` do NOT match)
  printf '%s' "$c" | grep -Eq '(^|[[:space:]]|/)(npm|pnpm)[[:space:]]+(install|i|ci|add)([[:space:]]|$)' && return 0
  # yarn install | yarn add
  printf '%s' "$c" | grep -Eq '(^|[[:space:]]|/)yarn[[:space:]]+(install|add)([[:space:]]|$)' && return 0
  # bare `yarn` (yarn with no subcommand = install) — whole command is yarn + flags only
  printf '%s' "$c" | grep -Eq '^[[:space:]]*yarn([[:space:]]+-{1,2}[^[:space:]]+)*[[:space:]]*$' && return 0
  # pip / pip3 install
  printf '%s' "$c" | grep -Eq '(^|[[:space:]]|/)(pip|pip3)[[:space:]]+install([[:space:]]|$)' && return 0
  # uv pip install
  printf '%s' "$c" | grep -Eq '(^|[[:space:]]|/)uv[[:space:]]+pip[[:space:]]+install([[:space:]]|$)' && return 0
  # python[3][.x] -m pip install
  printf '%s' "$c" | grep -Eq '(^|[[:space:]]|/)python[0-9.]*[[:space:]]+-m[[:space:]]+pip[[:space:]]+install([[:space:]]|$)' && return 0
  return 1
}
is_install "$cmd" || emit_noop

# Absolute path to the summarizer, derived from this hook's own location
# (the symlink dir ~/.claude/hooks; the summarizer is symlinked alongside).
hook_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || emit_noop
summarizer="$hook_dir/dhx-pkg-install-summarize.sh"
[ -f "$summarizer" ] || emit_noop

# --- Rewrite: capture-then-branch on exit code. ---------------------------
# - mktemp fails  -> run the original unmodified (never break the install).
# - rc == 0       -> summarize the captured output; if the summarizer itself
#                    errors, fall back to the raw capture (never lose output).
# - rc != 0       -> cat the capture verbatim (full failure passthrough).
# ${PIPESTATUS[0]} / $rc are escaped so they evaluate at RUN time. Single-quoted
# summarizer path survives a directory with spaces.
rewritten="T=\$(mktemp 2>/dev/null); if [ -z \"\$T\" ]; then $cmd; else { $cmd ; } >\"\$T\" 2>&1; rc=\${PIPESTATUS[0]}; if [ \"\$rc\" -eq 0 ]; then bash '$summarizer' <\"\$T\" || cat \"\$T\"; else cat \"\$T\"; fi; rm -f \"\$T\"; exit \$rc; fi"

jq -cn --arg cmd "$rewritten" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    permissionDecisionReason: "dhx-pkg-install-filter: success collapses to summary; failure passes through full; exit code preserved",
    updatedInput: { command: $cmd }
  }
}'
