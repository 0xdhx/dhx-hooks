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
# a sibling repo's node:test output-filter): this CAPTURES the output to a temp
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
# Compound/separator commands are bypassed because the summarizer only models
# install output — wrapping `npm install && npm run build` would feed the build's
# output through the summarizer and eat it. Conservative-but-correct: only a
# single clean install invocation is rewritten.
#
# The separator set is BARE `&`, `(`, `)` as well as `&&`/`||`/`;`/`|` (and the
# redirections). Bare `&`, `(`, `)` were added 2026-08-23 and are load-bearing
# TWICE over:
#   1. On their own terms — `pip install six & pytest` is a compound command this
#      hook's own header declares out of scope, yet the old list (which carried
#      `&&` but not `&`) matched it and wrapped BOTH halves in the capture, so the
#      backgrounded install's output and pytest's output were summarized together.
#   2. As producer disjointness — `dhx-pytest-cgroup-cap.sh` splits segments on
#      `&`/`(`/`)` where this hook did not, so exactly those commands drew a
#      rewrite from BOTH `updatedInput` producers on the PreToolUse:Bash matcher.
#      CC resolves competing `updatedInput` in COMPLETION ORDER — last hook
#      process to finish wins, nondeterministically, and since updatedInput
#      REPLACES the whole tool-input object (HP-041) the loser's rewrite vanishes
#      wholesale. A safety cap must never lose that race to an output reducer.
#      Verified from CC 2.1.241 source; see
#      `.planning/backlog/shipped/2026-08-18-pretooluse-bash-updatedinput-producer-race.md`
#      § Resolution of the semantics, and `docs/hook-dev-guide.md` § Two hooks
#      rewriting the same Bash input. Enforced by
#      `tests/probes/probe-updatedinput-producer-disjointness.sh`.
# `(` also subsumes the old `$(` entry.
#
# A NEWLINE is a separator too, and it is the subtle one (added 2026-08-23 after
# an adversarial review of the head-anchoring change below found it). Two things
# combine: a newline separates commands in shell exactly like `;`, AND `grep -E`
# anchors `^` at every LINE start, not at the start of the string. So without
# this bail, `is_install`'s head-anchored matchers would happily match an install
# on line 2 of a multi-line command whose actual head is something else —
# `$'pytest\npip install six'` fired BOTH producers, which is precisely the
# collision head-anchoring exists to prevent, surviving on a different axis.
# Nearly half of all Bash tool calls in this operator's transcript corpus are
# multi-line, so this is not an exotic shape. Do not remove this pattern without
# first making every matcher in `is_install` newline-safe.
case "$cmd" in
  *"|"*|*">"*|*"<"*|*";"*|*"&"*|*"("*|*")"*|*'`'*|*$'\n'*) emit_noop ;;
  *"dhx-pkg-install-summarize"*|*"dhx-pkg-install-filter"*) emit_noop ;;
  *"--json"*|*"--silent"*|*"--quiet"*|*" -q"*|*"--no-progress"*|*"--dry-run"*|*"--help"*|*" -h"*) emit_noop ;;
esac

# --- Candidate match: a single install-class invocation only. ---
# The head may be bare on PATH OR path-prefixed — `/home/u/.venv/bin/pip install`,
# `./venv/bin/pip install` (the canonical venv-direct-call pattern, common in
# scripts/CI/agents that don't rely on shell-activation state); the optional
# `([^[:space:]]*/)?` in each matcher covers that. NOT covered: bare
# path-invoked yarn-with-no-subcommand (`/usr/bin/yarn` alone) — the bare-yarn
# matcher stays whole-command-anchored; vanishingly rare, deliberately out of
# scope.
is_install() {
  local c="$1"
  # Anchored at the command HEAD (2026-08-23). Leading whitespace is trimmed and
  # env-assignment prefixes (`FOO=bar `) are stripped repeatably, then every
  # matcher below is ^-anchored — the SAME anchoring discipline
  # `dhx-pytest-cgroup-cap.sh`'s `is_pytest` already uses.
  #
  # WHY the head, not "anywhere space/slash-anchored": the old leading class
  # `(^|[[:space:]]|/)` matched an install token in ARGUMENT position, so any
  # command that merely carried one fired this hook — `echo pip install six`
  # (documented at the time as an accepted false positive) but also
  # `pytest tests/ pip install` and `pytest --rootdir=/x/npm i`, whose HEAD is
  # pytest. Those drew a rewrite from BOTH PreToolUse:Bash `updatedInput`
  # producers at once, and CC resolves that race in completion order (see the
  # bypass block above). Head-anchoring makes producer disjointness STRUCTURAL —
  # two producers can only collide if they claim the same command head — which is
  # the rule `docs/hook-dev-guide.md` § Two hooks rewriting the same Bash input
  # now states for any future rewriter.
  #
  # ACCEPTED COST, stated accurately: head-anchoring drops more than the
  # `echo pip install six` false positive. Any COMMAND-PREFIX wrapper now blocks
  # the match, because only env-assignments are stripped — measured 2026-08-23,
  # each of these used to compact and no longer does: `sudo pip install six`,
  # `timeout 600 pip install six`, `time`/`env`/`nice -n 10`/`nohup`/`command`/
  # `stdbuf -oL` prefixes, and `poetry run pip install` / `uv run pip install`.
  # Those ARE real installs. This is a lost OPTIMIZATION, not a correctness
  # break — the hook is fail-open, so an unmatched install simply runs
  # unfiltered exactly as it did before this hook existed. Restoring the
  # wrapper-prefix set is deliberately deferred rather than bolted on here:
  # each wrapper has its own argument grammar, and a stripping list is new
  # surface that needs its own disjointness corpus rows. Brief:
  # `.planning/backlog/2026-08-23-pkg-install-filter-command-prefix-coverage.md`.
  c="${c#"${c%%[![:space:]]*}"}"
  while grep -Eq '^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+' < <(printf '%s' "$c"); do
    c=$(printf '%s' "$c" | sed -E 's/^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+//')
  done
  # npm / pnpm  install|i|ci|add  (word-bounded so `npm info`, `npm init`,
  # `npm test`, `npm run install` do NOT match)
  grep -Eq '^([^[:space:]]*/)?(npm|pnpm)[[:space:]]+(install|i|ci|add)([[:space:]]|$)' < <(printf '%s' "$c") && return 0
  # yarn install | yarn add
  grep -Eq '^([^[:space:]]*/)?yarn[[:space:]]+(install|add)([[:space:]]|$)' < <(printf '%s' "$c") && return 0
  # bare `yarn` (yarn with no subcommand = install) — whole command is yarn + flags only
  grep -Eq '^[[:space:]]*yarn([[:space:]]+-{1,2}[^[:space:]]+)*[[:space:]]*$' < <(printf '%s' "$c") && return 0
  # pip / pip3 install
  grep -Eq '^([^[:space:]]*/)?(pip|pip3)[[:space:]]+install([[:space:]]|$)' < <(printf '%s' "$c") && return 0
  # uv pip install
  grep -Eq '^([^[:space:]]*/)?uv[[:space:]]+pip[[:space:]]+install([[:space:]]|$)' < <(printf '%s' "$c") && return 0
  # python[3][.x] -m pip install
  grep -Eq '^([^[:space:]]*/)?python[0-9.]*[[:space:]]+-m[[:space:]]+pip[[:space:]]+install([[:space:]]|$)' < <(printf '%s' "$c") && return 0
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

# updatedInput REPLACES the whole tool-input object — CC consumes it as
# `updatedInput ?? original`, never a merge (verified from CC 2.1.241 source;
# see docs/hook-patterns.md HP-041). Emitting {command} alone would silently
# drop the caller's timeout / description / run_in_background. So: re-emit the
# ORIGINAL tool_input with only .command overridden. $input parsed successfully
# above (cmd extraction gated on it), so this jq cannot fail on parse.
printf '%s' "$input" | jq -c --arg cmd "$rewritten" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    permissionDecisionReason: "dhx-pkg-install-filter: success collapses to summary; failure passes through full; exit code preserved",
    updatedInput: (.tool_input | .command = $cmd)
  }
}'
