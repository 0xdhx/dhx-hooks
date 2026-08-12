#!/usr/bin/env bash
#
# dhx-grep-vsz-cap.sh — PreToolUse:Bash address-space cap for grep-family commands.
# Patterns: HP-003, HP-028, HP-041
#
# THE INCIDENT (2026-08-11). A single `grep -E` call with two ranged interval
# quantifiers drove the bundled ugrep to ~19.4 GB RSS, took VmmemWSL to 32,562 MB
# (86% of host memory), and the WSL2 box became unresponsive. The allocation is
# COMPILE-TIME and INPUT-INDEPENDENT — the minimal reproducer targets /dev/null:
#
#   grep -E '.{0,90}a.{0,90}' /dev/null      # zero bytes of input, GBs of RAM
#
# It is a DFA state explosion: the engine materializes states proportional to the
# product of the interval bounds. Nothing about the search target bounds it, so no
# amount of "grep a smaller file" discipline helps.
#
# WHY `grep` REACHES ugrep AT ALL. In a Claude Code Bash tool shell, `grep` is a
# SHELL FUNCTION installed by the session snapshot that re-execs the `claude`
# binary with argv[0]=ugrep (plus `-G --ignore-files --hidden -I --exclude-dir=…`).
# So a plain `grep` is ugrep, and carries the defect. `command grep`, `/bin/grep`,
# and any absolute path bypass the function and reach GNU grep, which does NOT
# have the bug (verified: same pattern, rc=1 in 3ms).
#
# ─── MECHANISM: WHY NOT THE cgroup FACTORY ────────────────────────────────────
# The obvious build is dhx-pytest-cgroup-cap.sh's: rewrite to
# `systemd-run --user --scope -p MemoryMax=… -- bash -c '<original>'`. That is
# WRONG HERE, and silently so.
#
# The wrapper is a shell FUNCTION, and functions do not survive into a fresh
# non-interactive `bash -c` (measured: `type -t grep` → `file`, resolving to
# /usr/bin/grep). So the cgroup rewrite would substitute GNU grep for ugrep on
# every intercepted call — a different engine, a different regex dialect, and none
# of the wrapper's default flags. It would "fix" the memory bug by accident while
# silently changing what the search MEANS and what it returns. Corrupting results
# is strictly worse than the runaway this hook exists to contain.
#
# A SUBSHELL does inherit functions. So the cap is imposed with `ulimit -v` inside
# `( … )`, wrapping the original command VERBATIM:
#
#   ( ulimit -v 1048576 2>/dev/null || true
#   <ORIGINAL COMMAND, byte-for-byte>
#   )
#
# Consequences, all of them wins here:
#   - The wrapper function, its flags, and the exact command semantics survive.
#   - No argv surgery. Pipes, redirections, and quoting are preserved because the
#     command is never parsed for re-emission — only inspected for a yes/no.
#   - No transient systemd scope, so no per-grep scope churn and nothing added to
#     the `app.slice` accounting hole that sits outside the session cap.
#   - The session shell is untouched: `ulimit` applies to the subshell only
#     (verified — `ulimit -v` in the parent still reports `unlimited` after).
#
# The tradeoff accepted: `ulimit -v` bounds VIRTUAL address space, not RSS. That is
# a STRICTER bound than an equivalent RSS cap, so the false-positive question is
# the real one — and it was measured (see § SIZING).
#
# ─── SIZING: 1 GiB (1048576 KiB) ──────────────────────────────────────────────
# Time-to-contain scales linearly with the limit, which is itself confirmation of
# the unbounded-allocation diagnosis — the failure point tracks whatever ceiling
# you impose:
#
#   ulimit -v 4G → rc=139 in 30.9s     ulimit -v 1G → rc=139 in  6.4s   ← chosen
#   ulimit -v 2G → rc=139 in 13.8s     ulimit -v 512M → rc=139 in 2.7s
#
# Lower is better for containment latency, but there is a hard floor: the `claude`
# binary the wrapper re-execs CANNOT START below ~512 MiB of address space (at
# 128M/256M it dies in 1–3 ms having done nothing). 512M therefore sits AT the
# floor; 1 GiB is 2× it — the smallest value with real headroom.
#
# False positives, measured at 1 GiB — none:
#   repo-wide `grep -rn` over ~/repos/hooks   rc=0, 134 hits,  64 ms
#   589 MB text file, 700k matches            rc=0,           118 ms
#   300 MB single line (the incident shape)   rc=1,           127 ms
#   3.6 GB binary (detected + skipped)        rc=1,             8 ms
# All identical to their uncapped control runs.
#
# ─── PREDICATE: EVERY grep, NOT "dangerous-looking" ONES ──────────────────────
# This hook does NOT inspect the pattern. That is deliberate and was chosen over a
# narrow predicate AFTER measuring the blowup boundary, which turned out to be far
# subtler than it looks — two plausible-sounding rules were refuted by experiment:
#
#   -P '.{0,90}a.{0,90}'          SAFE  (PCRE is a different engine — 34 ms)
#   -F, single interval, {n} exact SAFE
#   '.{0,90}a.{0,8}'              SAFE  (BOTH bounds must be large)
#   '.{0,90}.{0,90}'              SAFE  (needs content BETWEEN the atoms)
#   '.{0,15}a.{0,15}'             458 ms — the knee, already climbing
#   '[a-z]{0,90}a[a-z]{0,90}'     BLOWUP (the atom need not be `.`)
#   -G '.\{0,90\}a.\{0,90\}'      BLOWUP (BRE counts too)
#
# The cost asymmetry settles it. A false POSITIVE costs a legitimate grep nothing
# measurable (see § SIZING). A false NEGATIVE costs a host freeze and, in the
# source incident, an OOM-killed session. Every hour spent making the predicate
# cleverer buys accuracy on the cheap side of a ~100:1 asymmetry. So: cap them all.
#
# ─── REFUSALS (each one a no-op — the command runs exactly as before) ─────────
#   - No grep-family command at any segment head.
#   - `ulimit -v` already present (idempotence — including our own rewrite).
#   - A pytest invocation is also present: dhx-pytest-cgroup-cap.sh claims that
#     command. Both hooks are PreToolUse:Bash `updatedInput` producers and they see
#     the SAME original input, so without this yield they would emit two competing
#     rewrites for one tool call. The cgroup cap is the stronger control (real RSS
#     accounting, OOM kill), so this hook defers unconditionally.
#   - Any segment head is a side-effecting builtin (`cd`, `export`, `source`, …).
#     The rewrite runs the command in a SUBSHELL, so such effects would be lost —
#     a `cd` that silently fails to persist is a worse bug than an uncapped grep.
#
# FAIL-OPEN throughout: emits {} on any error, missing dep, or unmatched command.
# A broken interceptor must never block or corrupt a command. `ulimit` itself is
# `|| true` — if the limit cannot be lowered, the command still runs, uncapped and
# exactly as it would have without this hook.
#
# KNOWN GAP, stated rather than papered over: the predicate reads SEGMENT HEADS
# split on shell separators with a quote-blind transform (HP-028 here-strings
# throughout). A grep reached indirectly — through a shell function, an alias, a
# Makefile target, `xargs grep`, or a `$(…)` substitution — is NOT matched and runs
# uncapped. That is the pre-hook status quo for those shapes, never a regression.
#
set -uo pipefail

emit_noop() { printf '{}'; exit 0; }

command -v jq >/dev/null 2>&1 || emit_noop

input=$(cat) || emit_noop
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) || emit_noop
[ -n "$cmd" ] || emit_noop

# --- Bypass: already address-capped (idempotence, incl. our own rewrite). ------
# `ulimit -v` is the ONLY idempotence key, deliberately. The sibling cgroup hook
# also bypasses on its own FILENAME; copying that here was a measured mistake —
# the token appears in this hook's own path, so `grep foo dhx/dhx-grep-vsz-cap.sh`
# (a completely ordinary grep) matched the guard and ran UNCAPPED. A self-reference
# guard keyed on a name that can appear as a plain path ARGUMENT un-caps real work.
case "$cmd" in
  *"ulimit -v"*) emit_noop ;;
esac

# --- Classify segment heads in ONE pass. --------------------------------------
# Splits on shell command separators, then strips leading whitespace and repeated
# env-assignments (FOO=bar ) before matching the head — the same shape as
# dhx-pytest-cgroup-cap.sh's classifier, so the two hooks agree on what a
# "command head" is and their yield contract stays honest.
#
# The split is quote-blind, so a `|` inside a quoted pattern (`grep -E 'a|b'`)
# manufactures spurious segments. That is harmless BY CONSTRUCTION: segments are
# only ever inspected to reach a yes/no, and the rewrite re-emits the original
# string byte-for-byte. A mis-split can change WHETHER we cap; it can never change
# WHAT runs.
HAS_GREP=0
HAS_PYTEST=0
HAS_SIDE_EFFECT=0

classify() {
  local c="$1" seg norm
  norm=$(printf '%s' "$c" | sed -E 's/(\|\||&&|[;|&()])/\n/g')
  while IFS= read -r seg; do
    seg="${seg#"${seg%%[![:space:]]*}"}"
    [ -z "$seg" ] && continue
    while grep -Eq '^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+' <<< "$seg"; do
      seg=$(sed -E 's/^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+//' <<< "$seg")
    done

    # grep-family HEAD, bare spelling only. `\grep` is included because the
    # backslash suppresses ALIAS expansion but not FUNCTION lookup — in this shell
    # it still lands on the ugrep wrapper. `command grep` and any path-prefixed
    # form (`/bin/grep`, `./grep`) are deliberately NOT matched: they bypass the
    # function and reach GNU grep, which does not carry the defect.
    grep -Eq '^\\?(grep|ugrep|ug)([[:space:]]|$)' <<< "$seg" && HAS_GREP=1

    # pytest HEAD — yield to dhx-pytest-cgroup-cap.sh (see § REFUSALS).
    grep -Eq '^([^[:space:]]*/)?pytest([[:space:]]|$)' <<< "$seg" && HAS_PYTEST=1
    grep -Eq '^([^[:space:]]*/)?python[0-9.]*[[:space:]]+-m[[:space:]]+pytest([[:space:]]|$)' <<< "$seg" && HAS_PYTEST=1
    grep -Eq '^([^[:space:]]*/)?(poetry|uv)[[:space:]]+run[[:space:]]+' <<< "$seg" && HAS_PYTEST=1

    # Side-effecting builtins whose effect would be swallowed by the subshell.
    grep -Eq '^(cd|pushd|popd|export|source|\.|set|shopt|unset|alias|unalias|trap|exec|eval|read|declare|typeset|local|umask|ulimit)([[:space:]]|$)' <<< "$seg" \
      && HAS_SIDE_EFFECT=1
  done <<< "$norm"
}
classify "$cmd"

[ "$HAS_GREP" -eq 1 ]        || emit_noop
[ "$HAS_PYTEST" -eq 0 ]      || emit_noop
[ "$HAS_SIDE_EFFECT" -eq 0 ] || emit_noop

# --- Budget. -------------------------------------------------------------------
# KiB, matching `ulimit -v`'s own unit. 1 GiB — see § SIZING for the measurements
# behind both the value and the floor.
DEFAULT_VSZ_KB=1048576
# Measured floor: below ~512 MiB the wrapped `claude` binary cannot start at all,
# so a smaller value is not a tighter cap — it is a total grep outage for the
# session. Enforced even against the trusted env override, because the failure
# mode of a too-LOW value is far worse than that of a too-high one.
MIN_VSZ_KB=524288

VSZ_KB="${DHX_GREP_CAP_VSZ_KB:-$DEFAULT_VSZ_KB}"
# Strict digits-only grammar. This value is interpolated into a command STRING, so
# the grammar is this hook's injection boundary — the same reasoning that makes
# dhx-pytest-cgroup-cap.sh's numeric grammar a security control rather than a
# nicety. Anything else falls back to the default; never emit {} here, since a bad
# override must not silently un-cap the command.
grep -Eq '^[1-9][0-9]*$' <<< "$VSZ_KB" || VSZ_KB="$DEFAULT_VSZ_KB"
# Length-bounded BEFORE any numeric comparison: bash wraps an oversized decimal
# literal at PARSE time with no diagnostic, so a comparison against an
# already-corrupted operand can pass (cross-repo shell-git-os-gotchas §26).
[ "${#VSZ_KB}" -le 12 ] || VSZ_KB="$DEFAULT_VSZ_KB"
[ "$VSZ_KB" -ge "$MIN_VSZ_KB" ] || VSZ_KB="$DEFAULT_VSZ_KB"

# --- Rewrite. ------------------------------------------------------------------
# NEWLINE-separated, not `;`-separated. A trailing comment in the original
# (`grep -E 'x' f  # why`) would swallow a `; )` terminator and produce an
# unterminated subshell; a newline ends the comment and the `)` survives on its own
# line. The original is embedded byte-for-byte — no escaping, because it is not
# being placed inside quotes.
#
# `ulimit -c 0` is not cosmetic. Containment here surfaces as SIGSEGV (the engine
# dies on a failed allocation, not gracefully), and a segfault at a ~1 GiB address
# space can dump a core of that order. On THIS host it happens to be harmless —
# `ulimit -c` is already 0 and core_pattern pipes to a WSL crash handler — but that
# is host configuration the hook must not depend on. Set it in the subshell so a
# contained runaway cannot convert a memory problem into a disk problem.
rewritten="( ulimit -v ${VSZ_KB} 2>/dev/null || true
ulimit -c 0 2>/dev/null || true
${cmd}
)"

jq -cn --arg cmd "$rewritten" --arg kb "$VSZ_KB" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    permissionDecisionReason: ("dhx-grep-vsz-cap: capped grep address space at " + $kb + " KiB (ugrep interval-quantifier blowup containment); wrapper + exit code preserved"),
    updatedInput: { command: $cmd }
  }
}'
