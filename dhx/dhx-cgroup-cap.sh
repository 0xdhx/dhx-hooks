#!/usr/bin/env bash
# dhx-cgroup-cap.sh — shared cgroup memory-cap factory (NOT a hook; sourced).
# Patterns: HP-045, HP-051
#
# Single source of truth for the `systemd-run --user --scope` memory-cap wrap.
# Sourced by BOTH consumers so the cap construction can never copy-drift:
#   - dhx/dhx-test-gate.sh  (Stop hook — caps its OWN pytest runner)
#   - dhx/dhx-pytest-cgroup-cap.sh (PreToolUse:Bash — caps a subagent's OWN
#     mid-session pytest, the DHX-7 OOM gap the gate's Stop-time wrap can't see)
#
# Runtime behavior this lib relies on is HP-045: on this WSL2 host a
# `systemd-run --user --scope` with `MemoryMax` + `MemorySwapMax=0` OOM-kills an
# overrunning child — exit 137 in every controlled cell tested, though a memory
# overrun has ALSO been observed surfacing as 143 in the field (see HP-045; cause
# not isolated, so do not rely on the code to distinguish memory from runtime).
# `RuntimeMaxSec` SIGTERMs at the runtime ceiling (exit 143). Both consumers
# treat 137 and 143 identically, which is what makes the ambiguity harmless.
# `MemorySwapMax=0` is load-bearing — `MemoryMax` alone is
# advisory on a swap-enabled host (verified in
# reports/2026-05-03-test-gate-collection-cost.md).
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
#   - 18 digits is the widest operand accepted. The largest 18-digit byte value is
#     ~889 PB, already astronomically above any real ceiling, so nothing legitimate
#     is refused; values above it return 1 and the caller clamps.
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

# dhx_cgroup_prefix_tokens MEM [TIME] — emit the systemd-run scope prefix as one
# token per line, terminated by `--`. Every token is whitespace-free, so a caller
# may either `mapfile` it into an array (direct argv exec — the gate) OR join it
# with spaces into a command string (the rewrite — the interceptor).
#
# Returns nonzero WITHOUT emitting anything if MEM fails the grammar (DHX-7c).
# CALLER-STATUS WARNING: this guard protects a caller that uses command
# substitution (`x=$(… ) || fallback` — the interceptor), because `$( )`
# propagates the producer's status. It does NOT protect a caller that uses
# `mapfile -t A < <(… )` — process substitution discards the producer's status and
# `mapfile` returns 0 regardless (verified 2026-08-11). The gate uses that form, so
# the gate validates its own value BEFORE calling here; this guard is its second
# layer, not its only one.
#
#   MEM   memory ceiling, e.g. 4G (passed to MemoryMax). Required.
#   TIME  runtime ceiling in whole seconds (passed to RuntimeMaxSec=${TIME}s).
#         OPTIONAL — omit/empty to apply a MEMORY-ONLY cap (no runtime ceiling).
#         The gate passes its runtime budget; the mid-session interceptor omits
#         it by default (the DHX-7 threat is OOM, not a hang — and CC's own Bash
#         tool timeout already backstops a hung command, so a runtime cap here
#         would only add a false-positive class on legitimately-slow suites).
#
# Token order is identical to the gate's former inline array, so a `mapfile`d
# array with TIME present is byte-for-byte what the gate built pre-refactor.
dhx_cgroup_prefix_tokens() {
  local mem="$1" time="${2:-}"
  dhx_cgroup_mem_token_valid "$mem" || return 1
  printf '%s\n' systemd-run --user --scope --quiet \
    -p "MemoryMax=$mem" \
    -p "MemorySwapMax=0"
  if [ -n "$time" ]; then
    printf '%s\n' -p "RuntimeMaxSec=${time}s"
  fi
  printf '%s\n' --
}
