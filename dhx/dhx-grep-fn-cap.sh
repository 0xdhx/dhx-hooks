#!/usr/bin/env bash
#
# dhx-grep-fn-cap.sh — SessionStart: function-level address-space cap on `grep`.
# Patterns: HP-012, HP-052, HP-057
#
# Successor to dhx-grep-vsz-cap.sh (PreToolUse:Bash rewriter, retired 2026-08-23).
# Same incident, same budget, different altitude: instead of parsing arbitrary
# shell command strings to decide when to wrap them in `( ulimit -v …; )`, this
# hook appends a wrapper FUNCTION to $CLAUDE_ENV_FILE at session start. CC
# sources that file into the Bash tool shell AFTER the snapshot (HP-057), so the
# wrapper interposes on the snapshot's own `grep` shim — the ugrep re-exec that
# carries the interval-quantifier blowup (2026-08-11 incident: ~19.4 GB RSS from
# a compile-time DFA explosion; see the retired hook's history and DHX-8 in
# docs/decisions.md for the full mechanism and sizing measurements).
#
# WHY THE MOVE. The rewriter parsed arbitrary shell to constrain one known shell
# function, and every defect it had was a consequence of that choice — all
# verified live 2026-08-18/23:
#   - pattern text un-capped it: `grep -E 'ulimit -v' f` tripped its own
#     idempotence token; `grep -E 'x| cd y' f` manufactured a `cd` segment via
#     the quote-blind splitter; a leading `cd X && grep …` (the incident shape)
#     tripped the side-effect refusal. All three emitted {} — uncapped.
#   - the same quote-blind splitter OVER-capped: a non-grep command merely
#     containing `grep …|…` in a quoted string got the whole-command 1 GiB wrap
#     (2026-08-23: a nested `claude -p` OOM-aborted at startup under it).
#   - as an updatedInput producer it silently dropped `timeout`/`description`/
#     `run_in_background` (HP-041 whole-object replacement, 2026-08-23 row).
# The function-level cap deletes all three classes at once: the cap travels with
# the function itself, so WHAT invokes grep, with WHAT pattern, from WHAT cwd is
# irrelevant — and no updatedInput is emitted at all.
#
# COVERAGE DELTA, stated: the rewriter also matched `ugrep`/`ug` heads; this
# wrapper interposes only on the `grep` FUNCTION. No standalone ugrep/ug binary
# exists on this host (checked 2026-08-23), and the CC shim is reached as `grep`,
# so nothing live is lost. Conversely the wrapper now also caps shapes the
# rewriter never could: `cd X && grep …`, function/alias-indirected greps that
# resolve to the shim, and `\grep` — anything that lands on the function.
#
# FAIL-LOUD (user decision, 2026-08-23 — supersedes the rewriter's fail-open):
# if the limit cannot be set, the call aborts with exit 125 and a stderr message
# naming this hook. Rationale: a silent fall-through would mean "the cap exists
# but quietly stopped capping", the exact condition this insurance exists to
# prevent; 125 is outside grep's own 0/1/2 exit vocabulary so the abort cannot
# be mistaken for "no match".
#
# BUDGET: 1 GiB (1048576 KiB) soft virtual address space, override via
# DHX_GREP_CAP_VSZ_KB, floor 524288 KiB — all inherited from the rewriter's
# measured sizing (the claude binary cannot start below ~512 MiB; containment
# latency at 1 GiB was 6.4 s on the real reproducer; zero false positives
# across repo-wide greps, a 589 MB file, and a 3.6 GB binary). Validation runs
# at CALL time inside the wrapper: digits-only, length-bounded before numeric
# comparison (shell-git-os-gotchas §26), floored — junk falls back to default.
#
# MECHANICS. $CLAUDE_ENV_FILE is per-hook-invocation (observed 2026-08-23:
# …/session-env/<session-id>/sessionstart-hook-N.sh), and this hook appends —
# never truncates — so peer hooks' lines survive regardless. The emitted block
# is doubly guarded: it only interposes when a `grep` function already exists
# (never wrap GNU grep — the rewriter's own header explains why substituting
# engines corrupts results), and only when __dhx_orig_grep is not already
# defined (idempotent under re-sourcing on resume/clear/compact). The rename
# itself is checked: if `declare -f | sed | eval` ever fails to produce
# __dhx_orig_grep, the wrapper is NOT installed and the shim runs as before —
# fail-open on INSTALL, fail-loud on CAP, deliberately different postures.
#
# Registered via dhx-plugin session-start.sh dispatcher (HP-017); a session
# restart is required before it takes effect (HP-012). Silent on happy path;
# stdin is ignored (no JSON parsing to fail on).
#
set -uo pipefail

# No env file → not a SessionStart context that supports env injection. No-op.
[ -n "${CLAUDE_ENV_FILE:-}" ] || exit 0

# Idempotence within one file (defensive — CC hands each fire a fresh file).
if [ -f "$CLAUDE_ENV_FILE" ] && command grep -q '__dhx_orig_grep' -- "$CLAUDE_ENV_FILE" 2>/dev/null; then
  exit 0
fi

cat >> "$CLAUDE_ENV_FILE" <<'DHX_GREP_FN_CAP_EOF' 2>/dev/null || exit 0
# --- dhx-grep-fn-cap: begin (ugrep interval-quantifier blowup containment) ---
if declare -F grep >/dev/null 2>&1 && ! declare -F __dhx_orig_grep >/dev/null 2>&1; then
  eval "$(declare -f grep | sed '1s/^grep ()/__dhx_orig_grep ()/')" 2>/dev/null || true
  if declare -F __dhx_orig_grep >/dev/null 2>&1; then
    grep() (
      _dhx_kb="${DHX_GREP_CAP_VSZ_KB:-1048576}"
      case "$_dhx_kb" in ''|*[!0-9]*) _dhx_kb=1048576 ;; esac
      [ "${#_dhx_kb}" -le 12 ] || _dhx_kb=1048576
      [ "$_dhx_kb" -ge 524288 ] || _dhx_kb=1048576
      ulimit -S -v "$_dhx_kb" 2>/dev/null || {
        echo "dhx-grep-fn-cap: cannot set grep address-space cap (ulimit -v ${_dhx_kb} KiB); refusing to run uncapped" >&2
        exit 125
      }
      ulimit -S -c 0 2>/dev/null || true
      __dhx_orig_grep "$@"
    )
  fi
fi
# --- dhx-grep-fn-cap: end ---
DHX_GREP_FN_CAP_EOF

exit 0
