#!/usr/bin/env bash
# dhx-cgroup-cap.sh — shared cgroup memory-cap factory (NOT a hook; sourced).
# Patterns: HP-045, HP-051, HP-059
#
# Single source of truth for the `systemd-run --user --scope` memory-cap wrap.
# Sourced by BOTH consumers so the cap construction can never copy-drift:
#   - dhx/dhx-test-gate.sh  (Stop hook — caps its OWN pytest runner)
#   - dhx/dhx-pytest-cgroup-cap.sh (PreToolUse:Bash — caps a subagent's OWN
#     mid-session pytest, the DHX-7 OOM gap the gate's Stop-time wrap can't see)
#
# Runtime behavior this lib relies on is HP-045: on this WSL2 host a
# `systemd-run --user --scope` with `MemoryMax` + `MemorySwapMax=0` OOM-kills an
# overrunning child. The kill is categorical; the STATUS it surfaces as is not,
# and the rule was isolated 2026-09-03:
#
#   the kernel's victim IS the scope's main process  -> 137
#   the victim is some OTHER process in the scope    -> systemd (OOMPolicy=stop)
#                                                       SIGTERMs the survivors,
#                                                       so the main process
#                                                       usually exits 143 —
#                                                       or with ITS OWN code,
#                                                       INCLUDING 0
#
# Cap magnitude is NOT causal (verified across 64M/1G/4G). `RuntimeMaxSec`
# SIGTERMs at the runtime ceiling (exit 143). Both consumers treat 137 and 143
# identically, which is what makes THAT ambiguity harmless — but see the exit-0
# hole flagged in `dhx/dhx-pytest-cgroup-cap.sh`, which the cascade cannot see.
# `MemorySwapMax=0` is load-bearing — `MemoryMax` alone is
# advisory on a swap-enabled host (verified in
# private report 2026-05-03-test-gate-collection-cost).
#
# This file is sourced, never executed — no stdin read, no exit. It only DEFINES
# functions. A consumer that sources it and finds the functions absent (truncated
# file, etc.) is expected to fall back to a bare (uncapped) invocation — the cap
# is defense-in-depth, never a hard dependency.

# dhx_cgroup_available — return 0 iff the host can honor the scope cap.
# Matches the precondition dhx-test-gate.sh used inline before this extraction
# (systemd-run on PATH AND an active --user systemd manager). Kept byte-for-byte
# so the gate's host-fallback behavior is unchanged by the refactor. (The two
# host-precondition PROBES read the canonical cgroup.controllers surface instead;
# this is the gate's lighter runtime check, deliberately preserved.)
dhx_cgroup_available() {
  command -v systemd-run >/dev/null 2>&1 && \
    systemctl --user is-active default.target >/dev/null 2>&1
}

# --- Memory-token MECHANISM (grammar + arithmetic). POLICY stays with callers. --
# Added 2026-08-11 (DHX-7c). Both consumers reach `MemoryMax=$mem` through this
# file, and neither the factory nor the gate validated it — so the grammar and the
# overflow-safe arithmetic live here, once. What deliberately does NOT live here:
# which value is trusted, what the default is, and what the ceiling is. Those are
# per-caller trust policy (the interceptor clamps an untrusted repo config to its
# ceiling; the gate has its own budget and fallback), and pushing them down would
# impose one caller's policy on the other.

# dhx_cgroup_mem_shell_safe TOKEN — the FACTORY's own guard, and deliberately the
# weakest of the three. It asserts only the property the factory itself needs: the
# token is safe to interpolate into a command STRING (the interceptor space-joins
# these tokens; the gate execs them as argv). Alphanumerics, `.` and `%` only — no
# whitespace, quotes, `$`, backticks, `;`, `&`, `|`, redirections, parens, or
# newlines, and not empty.
#
# ADDED 2026-08-11 as a REGRESSION FIX (DHX-7c follow-up). The first cut of DHX-7c
# guarded `dhx_cgroup_prefix_tokens` with `dhx_cgroup_mem_token_valid` — the
# INTERCEPTOR's narrow numeric grammar — which silently became the GATE's grammar
# too. The gate had always passed arbitrary systemd specs straight through its argv
# array, so `MemoryMax=infinity` and `MemoryMax=50%` began returning nonzero here,
# emitting zero tokens, and (per HP-051, registered in that same commit) landing as
# an EMPTY `CGROUP_PREFIX` in the gate's `mapfile` — which runs the test suite
# UNCAPPED. `50%` is a real ceiling that silently became no ceiling.
#
# The lesson generalized: a shared factory may enforce only what IT needs. Anything
# narrower is one caller's policy wearing the factory's authority.
dhx_cgroup_mem_shell_safe() {
  [[ "$1" =~ ^[A-Za-z0-9.%]+$ ]]
}

# dhx_cgroup_mem_spec_valid TOKEN — the GATE's grammar: the systemd MemoryMax forms
# the gate has always accepted. Broader than the interceptor's numeric grammar
# (`infinity` and `N%` are valid systemd and were passed through pre-DHX-7c),
# narrower than "anything at all" — a value that fails this is rejected LOUDLY by
# the caller and replaced with a known-good default, never allowed to become an
# empty prefix. Shell-safety is implied: every accepted form is a subset of
# dhx_cgroup_mem_shell_safe.
dhx_cgroup_mem_spec_valid() {
  [ "$1" = "infinity" ] && return 0
  [[ "$1" =~ ^[1-9][0-9]*%$ ]] && return 0
  dhx_cgroup_mem_token_valid "$1"
}

# dhx_cgroup_mem_token_valid TOKEN — strict grammar: digits + at most one K/M/G/T.
# Rejects whitespace, shell metacharacters, newlines, "infinity", "%"-relative
# specs, leading zero/zero, and the empty string. Deliberately NARROWER than
# systemd's own accepted syntax: the interceptor JOINS factory tokens into a
# command STRING, so this grammar is the injection boundary for that caller.
#
# INTENTIONALLY UNBOUNDED in digit count. A huge-but-well-formed value like
# "999999999999G" is syntactically VALID and must classify as over-ceiling (→ the
# caller clamps) rather than as malformed (→ the caller defaults). The digit bound
# belongs to the arithmetic, not the grammar; conflating them silently reclassifies
# an over-ceiling value as a parse failure and can move the effective cap.
dhx_cgroup_mem_token_valid() {
  [[ "$1" =~ ^[1-9][0-9]*[KMGT]?$ ]]
}

# dhx_cgroup_mem_bytes TOKEN — normalize to bytes on stdout. Suffixless = bytes.
#
# THREE-WAY STATUS — the caller MUST branch on it and must never use stdout on a
# nonzero return:
#   0  ok, bytes on stdout
#   1  numeric overflow (well-formed but unrepresentable) → caller should CLAMP
#   2  malformed token                                    → caller should DEFAULT
#
# Why the guards (verified by execution 2026-08-11, DHX-7c):
#   - Bash arithmetic is SIGNED 64-BIT and wraps SILENTLY. The prior implementation
#     multiplied an unbounded operand, so a repo-controlled `.claude/test-gate.json`
#     `memory_max` of "99999999999G" produced -3306282043331051520 and "17179869184G"
#     produced 0 — both of which pass a `<= ceiling` test and defeat the documented
#     "a repo may lower the cap, never raise it" invariant.
#   - The length bound is NOT redundant with the multiply guard. Bash wraps an
#     oversized DECIMAL LITERAL at PARSE time with no error and no diagnostic
#     (`99999999999999999999` parses as 7766279631452241919 — positive and
#     plausible), so a post-multiply division check would compare against an
#     already-corrupted operand and pass. The bound must come first.
#   - 18 digits is a CONSERVATIVE blanket bound, not the exact int64 maximum. That
#     maximum (9223372036854775807) has 19 digits, but only some 19-digit values are
#     representable, so bounding at 18 refuses a band of representable-but-absurd
#     operands rather than doing an exact decimal comparison. Safe for any real
#     ceiling — the largest 18-digit byte value is ~889 PB — but the helper is
#     therefore NOT a general-purpose byte converter. Make the comparison exact
#     against `max` before reusing it as one.
#   - `n > max / mult` is checked BEFORE multiplying, so the overflow is never
#     performed rather than performed-and-detected.
dhx_cgroup_mem_bytes() {
  local v="$1" n mult=1 max=9223372036854775807 out
  dhx_cgroup_mem_token_valid "$v" || return 2

  case "$v" in
    *K) n=${v%K}; mult=1024 ;;
    *M) n=${v%M}; mult=$((1024 ** 2)) ;;
    *G) n=${v%G}; mult=$((1024 ** 3)) ;;
    *T) n=${v%T}; mult=$((1024 ** 4)) ;;
    *)  n=$v ;;
  esac

  [ "${#n}" -le 18 ] || return 1
  (( n > max / mult )) && return 1
  out=$(( n * mult ))
  (( out > 0 )) || return 1
  printf '%s\n' "$out"
}

# INVARIANT: dhx_cgroup_unit_label MUST stay defined ABOVE dhx_cgroup_prefix_tokens.
# Both consumers guard a truncated lib with `declare -F dhx_cgroup_prefix_tokens` and
# neither checks for this helper. A file truncates from the END, so while the label
# helper precedes its caller, losing the helper necessarily loses the caller too and
# the existing guard still catches it. Reorder them and a truncation lands squarely
# between: `dhx_cgroup_prefix_tokens` exists, calls a missing function, and emits a
# prefix with an empty `--unit=` — an argument error at exec time on the gate's Stop
# path. Asserted by probe-test-gate-cgroup.sh [19c].
#
# dhx_cgroup_unit_label RAW — normalize RAW into a unit-name-safe, whitespace-free
# slug on stdout. NEVER returns nonzero and NEVER emits empty: a refusal here would
# be a brand-new way for `dhx_cgroup_prefix_tokens` to produce no prefix, which is
# an UNCAPPED run the gate's `mapfile` cannot even see (HP-051). Sanitize and
# continue; there is no input this may reject.
#
# Systemd unit names accept `[A-Za-z0-9:_.-]`; everything outside `[A-Za-z0-9_]` is
# collapsed to `-` (the two dropped characters, `:` and `.`, are legal in a unit name
# but earn nothing here and `.` in particular reads as a unit-type suffix). Runs of
# `-` are squeezed and the ends trimmed so a label like `//repo//` cannot produce
# `--repo--`, and the result is bounded at 40 chars — a repo basename reaches this
# and repo basenames are not length-bounded.
dhx_cgroup_unit_label() {
  local s="${1:-}"
  s="${s//[^A-Za-z0-9_]/-}"
  while [ "${s//--/-}" != "$s" ]; do s="${s//--/-}"; done
  s="${s#-}"; s="${s%-}"
  s="${s:0:40}"; s="${s%-}"
  [ -n "$s" ] || s="run"
  printf '%s\n' "$s"
}

# dhx_cgroup_prefix_tokens MEM [TIME] [LABEL] — emit the systemd-run scope prefix as
# one token per line, terminated by `--`. Every token is whitespace-free, so a caller
# may either `mapfile` it into an array (direct argv exec — the gate) OR join it
# with spaces into a command string (the rewrite — the interceptor).
#
# Returns nonzero WITHOUT emitting anything if MEM is not SHELL-SAFE (DHX-7c).
# The guard is `dhx_cgroup_mem_shell_safe`, NOT a numeric grammar: the factory
# enforces only the property it owns, so `infinity` and `50%` — valid systemd specs
# the gate has always passed — still produce a prefix. Enforcing the interceptor's
# numeric grammar here was the DHX-7c regression; see that helper's header.
#
# CALLER-STATUS WARNING: this guard protects a caller that uses command
# substitution (`x=$(… ) || fallback` — the interceptor), because `$( )`
# propagates the producer's status. It does NOT protect a caller that uses
# `mapfile -t A < <(… )` — process substitution discards the producer's status and
# `mapfile` returns 0 regardless (verified 2026-08-11, HP-051). An unprotected
# caller must validate BEFORE calling and must never let a refusal become an empty
# prefix, because an empty prefix runs the workload UNCAPPED and is indistinguishable
# from "this host has no cgroup support."
#
#   MEM   memory ceiling, e.g. 4G (passed to MemoryMax). Required.
#   TIME  runtime ceiling in whole seconds (passed to RuntimeMaxSec=${TIME}s).
#         OPTIONAL — omit/empty to apply a MEMORY-ONLY cap (no runtime ceiling).
#         The gate passes its runtime budget; the mid-session interceptor omits
#         it by default (the DHX-7 threat is OOM, not a hang — and CC's own Bash
#         tool timeout already backstops a hung command, so a runtime cap here
#         would only add a false-positive class on legitimately-slow suites).
#   LABEL who is being capped, and where — e.g. `testgate-myrepo`, `pytest-myrepo`.
#         OPTIONAL — sanitized through dhx_cgroup_unit_label; omit/empty/unusable
#         yields `run`, so every existing call site keeps working unchanged.
#
# --- NAMING (2026-09-02) -------------------------------------------------------
# `--unit=dhx-cap-<label>-<pid>-<rand>` exists so a journal sweep can answer the
# only question it is really asking of an OOM kill on this box: *is this an
# incident, or is this containment doing its job?* Some scopes this factory builds
# are DESIGNED to be OOM-killed (the cap probes assert exactly that), and before
# the name they landed as anonymous `run-r<hex>.scope` records indistinguishable
# from a real memory event — a 2026-09-02 investigation spent a full session
# attributing 56 such kills back to this repo's own probes. Every scope this
# factory builds now carries the `dhx-cap-` prefix; a `run-r<hex>` OOM kill on
# this host is therefore NOT from here.
#
# --- READING ONE BACK (2026-09-03) ---------------------------------------------
# The name is only useful if you can query it, and the obvious query silently
# returns nothing. `journalctl -u <name>` appends `.service` to a suffixless
# argument, so a SCOPE asked for by bare name matches a unit that does not exist —
# clean exit 0, zero lines, which reads as "that scope logged nothing." Spell the
# suffix. `UNIT=` is the SYSTEM manager's field; `--user` records carry
# `USER_UNIT=`. Both wrong forms are silently empty:
#
#   journalctl --user -u dhx-cap-foo-123-456.scope        # correct
#   journalctl --user -u dhx-cap-foo-123-456              # 0 lines, exit 0
#   journalctl --user UNIT=dhx-cap-foo-123-456.scope      # 0 lines, exit 0
#
# And prefer the structured field over grepping the message text — the cause is
# already parsed, and it is the ONLY reliable memory-vs-runtime discriminator
# (the wait status is not; see the rule at the top of this file):
#
#   journalctl --user -u <name>.scope -o json \
#     | jq -r 'select(.UNIT_RESULT).UNIT_RESULT'    # oom-kill | timeout
#
# HP-059 has the matrix; cross-repo `2026-07-10-shell-git-os-gotchas.md` section 49
# has the general form of the trap.
#
# UNIQUENESS IS LOAD-BEARING, not hygiene. A repeated unit name fails with
# `Unit NAME.scope was already loaded or has a fragment file`, rc 1 — and rc 1
# means the workload NEVER RAN, which neither consumer's fail-open cascade
# (137|143|124) treats as a kill: the gate would read it as a test failure and
# block Stop. Measured 2026-09-02 via live `systemd-run --user --scope` on systemd
# 255: two OVERLAPPING same-name scopes → rc 1, and same-name reuse immediately
# after a SUCCESSFUL scope → rc 1. `CollectMode` reaps a *failed* scope fast
# enough for back-to-back OOM runs (137 x3, zero lingering units), but not a clean
# one — and a green suite is the common path, so a fixed name would break the
# ordinary case rather than the rare one. Hence pid + a random suffix expanded
# HERE, at token-emission time, so the emitted token is a literal: the interceptor
# space-joins these tokens into a command string that a shell it does not control
# re-parses, and an unexpanded `$RANDOM` in that string would be re-expanded there.
#
# `-p CollectMode=inactive-or-failed` is what makes a *named* scope safe to build
# repeatedly at all: without it a failed named unit LINGERS and blocks reuse until
# `systemctl --user reset-failed`, which matters far more here than in general
# because these scopes are designed to fail. (Same measurement, 2026-09-02.)
#
# `-p Description=` was considered and refused: measured 2026-09-02, the
# `Failed with result 'oom-kill'` line a sweep greps carries ONLY the unit name —
# the description reaches just the `Started` line — and a description readable
# enough to be worth having contains spaces, which the interceptor's space-join
# cannot carry.
#
# Token order otherwise follows the gate's former inline array. The `--unit` and
# `CollectMode` tokens are additions, so a `mapfile`d array is NO LONGER
# byte-for-byte what the gate built pre-refactor; the ordering of the tokens that
# predate this change is unchanged, and `systemd-run --user --scope` remains
# contiguous at the head (three probe assertions substring-match it).
dhx_cgroup_prefix_tokens() {
  local mem="$1" time="${2:-}" label="${3:-}" unit
  dhx_cgroup_mem_shell_safe "$mem" || return 1
  unit="dhx-cap-$(dhx_cgroup_unit_label "$label")-$$-${RANDOM}${RANDOM}"
  printf '%s\n' systemd-run --user --scope --quiet \
    "--unit=$unit" \
    -p "MemoryMax=$mem" \
    -p "MemorySwapMax=0" \
    -p "CollectMode=inactive-or-failed"
  if [ -n "$time" ]; then
    printf '%s\n' -p "RuntimeMaxSec=${time}s"
  fi
  printf '%s\n' --
}
