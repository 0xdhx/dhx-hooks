#!/usr/bin/env bash
# tests/probes/lib/run-hook-envelope.sh
#
# Invoke a hook the way the SessionStart dispatcher does — an envelope piped
# into it — while reporting the HOOK'S OWN exit status rather than the
# pipeline's.
#
# WHY THIS EXISTS. The dispatcher calls every child as
#   printf '%s' "$INPUT" | _dhx_child <label> bash <hook>
# and probes reproduce that shape. But a probe runs `set -uo pipefail`, and a
# hook that exits at a suppression guard BEFORE its `INPUT=$(cat)` closes the
# read end without reading. The `printf` on the left then takes SIGPIPE, exits
# 141, and pipefail makes the PIPELINE's status 141 — while the hook itself
# exited 0, which is the thing the assertion meant to measure.
#
# Measured 2026-09-18 on dhx/dhx-vet-closures.sh via its DHX_SKIP_VET_CLOSURES
# guard: the real probe failed 3 of 30 runs under 2x-nproc CPU load and 0 of 30
# idle, printing `FAIL shim: DHX_SKIP_VET_CLOSURES=1 -> empty, exit 0` — empty
# stdout (correct) beside a non-zero rc (the dead writer's). Forcing the race by
# delaying the writer 50ms makes it deterministic: `PIPESTATUS=(141 0)`.
#
# This is a SIGPIPE+pipefail bug of the class docs/hook-patterns.md HP-028
# documents, but NOT an instance of the claim written there: that entry states
# the LHS must outrun the pipe buffer (it measured onset at ~70-100KB). A reader
# that exits without reading AT ALL makes the size leg irrelevant — this one
# fires on a 52-byte envelope. See HP-028's zero-read leg.
#
# NOT A PRODUCTION BUG, verified rather than reasoned. `_dhx_child` captures
# rc from `"$@"` (the child alone), returns 0, and the dispatcher discards the
# pipeline status at statement level with no errexit. Simulated with a forced
# race 2026-09-18: no `⚠ session-start child` line, dispatcher continued, exit 0.
# That invariant is pinned by probe-session-start-child-failure-surface.sh; if
# it ever stops holding, the fix is the shim, not the probe.
#
# Sourcing convention:
#   source "$(dirname "$0")/lib/run-hook-envelope.sh"
#
# Usage:
#   run_hook_envelope <envelope-json> <hook-path> [bash-args...]
#     -> stdout of the hook is captured in  $RHE_OUT
#        the HOOK's own exit status lands in $RHE_RC
#        the writer's status (141 on a dead-writer race) in $RHE_WRITER_RC
#     Returns 0 always; read the variables. Hook stderr is discarded — a caller
#     that wants stderr should redirect it itself before calling.
#
# Env passed to the hook comes from the caller's own environment, so the
# dispatcher-shaped form
#   DHX_SKIP_X=1 run_hook_envelope "$ENVELOPE" "$HOOK"
# works exactly as the inline pipeline did.

RHE_OUT=""
RHE_RC=0
RHE_WRITER_RC=0

run_hook_envelope() {
  local envelope="$1" hook="$2"; shift 2
  local outf st
  outf=$(mktemp) || return 0

  # The pipeline runs OUTSIDE a command substitution on purpose: PIPESTATUS
  # describes the most recent pipeline, and `out=$(a | b)` overwrites it with
  # the assignment's own status, which is what hid this bug in the first place.
  printf '%s' "$envelope" | bash "$hook" "$@" > "$outf" 2>/dev/null
  # Copy the WHOLE array in one assignment. A simple assignment is itself a
  # pipeline, so `A="${PIPESTATUS[0]}"` resets PIPESTATUS to a one-element
  # array and the next `${PIPESTATUS[1]}` is unbound under `set -u` — measured
  # here 2026-09-18, on the first stress run of this very helper.
  st=("${PIPESTATUS[@]}")
  RHE_WRITER_RC="${st[0]}"
  RHE_RC="${st[1]}"

  RHE_OUT=$(cat "$outf")
  rm -f "$outf"
  return 0
}
