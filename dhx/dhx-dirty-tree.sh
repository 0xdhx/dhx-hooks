#!/usr/bin/env bash
# dhx-dirty-tree.sh — SessionStart hook
# Patterns: HP-009, HP-015
# Reports uncommitted changes at session start. Read-only, non-blocking.
# Fires once per session. Silent on clean trees.
#
# On the two declared shared working trees (runtime allowlist — there is no
# per-repo hook; this one plugin hook fires in every repo, so scope is a
# runtime gate), the bare count is replaced by dhx-who's per-file attribution
# payload (who holds each dirty file), invoked through a strict fail-open
# wrapper:
#   - hard timeout      DHX_DIRTY_TREE_WHO_TIMEOUT, default 8s — covers the
#                       observed legitimate cold-cache range (3.5-6.3s);
#                       worst-case block is 2x timeout only when the helper
#                       hangs in BOTH the --version probe and the payload run
#   - output-size cap   CEILING, 16384 bytes. Over-cap DISCARDS WHOLE rather
#                       than truncates — a mid-payload cut would drop the
#                       payload's closing imperative line. See PAYLOAD CEILING
#                       below for the measurement behind the number
#   - protocol check    `--version` must print exactly WANT_PROTO
#   - shape check       payload must open with "[shared-tree state]"
# Every repo outside the allowlist pays NO helper invocation and no scan (the
# cost boundary the allowlist holds), and every degrade path emits today's
# bare-count line BYTE-IDENTICAL to the pre-enrichment hook.
#
# DEGRADE VOICE — which degrades speak, and why (2026-07-30)
# Fail-open is silent by default: a degrade notice on a fleet hook is noise on
# a path nobody can act on. The test for the exceptions is PERMANENCE — a
# degrade that never self-heals is one somebody must act on, so it says so
# once; a per-run race resolves itself before anyone could act, so it stays
# quiet. The permanence test is the RATIONALE; the set below is the MECHANISM,
# and it is CLOSED. Adding to it takes a fresh ruling, not an appeal to the
# principle.
#   SPEAKS (permanent — bare count + exactly one factual line):
#     - helper exit 3      dhx-who's serialization CANARY: a dead key form must
#                          never render as a clean ownership map
#     - protocol mismatch  `--version` answered with a protocol this hook does
#                          not speak. Nothing self-heals it and the symptom is a
#                          plausible bare count, so the feature can sit dark
#                          indefinitely with no other tell
#     - payload over cap   discards the owner map — the one thing the design
#                          says is NOT re-derivable from `git status`
#   SILENT (transient — bare count only, byte-identical):
#     - helper absent / repo outside allowlist   expected absence, not breakage
#     - `--version` exits nonzero                broken or mid-install helper
#     - timeout                                  per-run race; the legitimate
#                                                cold range sits just under the
#                                                bound, so a notice here is the
#                                                cry-wolf case
#     - zero-byte or malformed payload           indistinguishable from a partial
#                                                write under the F3 skew below
# Both guards that changed had the SAME defect: an `||` fusing a transient
# cause with a permanent one, so the permanent one inherited the silence.
#
# OUTCOME LOG (2026-09-18) — the silent degrades are silent to the SESSION, not
# to the operator. Every allowlisted run appends one TSV line to
# ${XDG_STATE_HOME:-~/.local/state}/dhx/dirty-tree-who.tsv:
#   utc  toplevel  outcome  elapsed_ms  payload_bytes  session_id
# outcome ∈ ok | timeout | canary | exit-N | empty | over-cap | malformed |
#           protocol-mismatch | version-timeout | version-fail | helper-absent
# Successes are logged too — a degrade RATE needs its denominator. Why: a timeout
# was the one degrade nobody could count, so "are SessionStart maps going
# missing?" had no answer but a hunch (skills DEC-2026-09-17-dhx-who-attribution-
# by-recorded-change-sets-stage-1, Amendment 1 cost). The log is not a voice:
# stdout stays byte-identical and the DEGRADE VOICE set above is untouched. It is
# fail-open (an unwritable log costs the line, never the output) and rotates to
# .1 past 1 MiB (~10k runs). Hermetic like dhx-who's codex seam: OFF whenever
# DHX_DIRTY_TREE_WHO or _ALLOWLIST is set without DHX_DIRTY_TREE_LOG, so no probe
# writes the real log.
#
# PAYLOAD CEILING — 16384 bytes, and a CROSS-REPO CONSTANT duplicated in two
# repos: here, and `dhx-who.sh`'s own `PAYLOAD_CEILING` (skills). Changing one
# without the other desynchronizes them silently.
#
# Since dhx-who's provenance work landed (skills `a591ac81`, 2026-07-30) the
# helper ENFORCES this ceiling itself: over budget it collapses owner groups to
# counted rollups largest-first, then drops lowest-priority groups entirely
# (never the hand-edit alarm), appending a budget note naming what it cut. So a
# well-behaved helper never exceeds the cap, and the over-cap notice below is a
# BACKSTOP against a helper-side enforcer regression — NOT a dirty-tree signal.
# Do not read a trip as "the tree got big."
#
# Measured 2026-07-30 against the live helper. Pre-provenance: 25 dirty files =
# 2,074 B; 100 = 6,877 B; 200 = 13,377 B (~66 B/file). With provenance on
# generated files the per-file cost roughly triples — 25 = 5,385 B (215 B/file),
# 50 = 10,360 B — and then the enforcer engages: 100 = 16,336 B, 200 = 16,290 B,
# i.e. MORE dirty files yielding FEWER bytes. The rollup exempts dead/unresolved
# per-file lines by design (they carry the owner map, which `git status` cannot
# re-derive), so absent the helper's enforcer the payload would grow unbounded.
#
# Why the number stays small rather than generous: an invisible ceiling has to
# be generous, because a trip costs the operator the whole owner map and tells
# them nothing; a visible one can stay small and report itself. Raising it would
# also strand headroom — the helper self-limits to 16384 regardless.
#
# BOUNDARY: both sides test `> 16384`, on different quantities. The helper
# measures its assembled string, then prints it with a trailing newline, so the
# file this hook stats is one byte larger — a payload whose string is exactly
# 16384 becomes a 16385-byte file: in budget by the producer's reckoning,
# discarded here. Fixed producer-side (skills) rather than by padding this cap;
# if that fix is reverted, the 1-byte window reopens here.
#
# The helper is two files (dhx-who.sh + enumerate-ccs-sessions.sh); --version
# interrogates only the first, so a peer mid-edit can skew them briefly. By
# adjudication this rides the wrapper battery — the failure mode is "bare
# count for a few seconds, silently". Revisit deployment isolation only on a
# real incident where the wrapper degraded because of mid-edit tree state.
#
# Helper contract: ~/repos/<skills-monorepo>/.planning/backlog/
#   2026-07-28-dirty-tree-attribution-session-start.md (criterion "Hook
#   boundary and scope") + docs/research/2026-07-28-dirty-tree-attribution-
#   codex-review.md §5 + M5/M6 (same repo).
#
# Suppression: DHX_SKIP_DIRTY_CHECK=1
# Source-of-truth: ~/repos/hooks/dhx/dhx-dirty-tree.sh
# Symlinked to:   ~/.claude/hooks/dhx-dirty-tree.sh
#
# TEST SEAMS (default-preserving; production sets none):
#   DHX_DIRTY_TREE_ALLOWLIST    colon-separated repo toplevels
#                               (default: ~/repos/<skills-monorepo>:~/repos/cross-repo)
#   DHX_DIRTY_TREE_WHO          helper path
#                               (default: ~/.claude/dhx-tools/dhx-history/dhx-who.sh)
#   DHX_DIRTY_TREE_WHO_TIMEOUT  seconds (default: 8)
#   DHX_DIRTY_TREE_LOG          outcome-log path; set-but-empty = off
#                               (default: see OUTCOME LOG — off under any seam)

set -uo pipefail

# Parse cwd from stdin (graceful — degrades to env var / pwd)
INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
if [ -z "$CWD" ]; then
  CWD="${CLAUDE_PROJECT_DIR:-.}"
fi

# Must be a git repo
if ! git -C "$CWD" rev-parse --is-inside-work-tree &>/dev/null; then
  exit 0
fi

# Suppression via env var
if [ "${DHX_SKIP_DIRTY_CHECK:-}" = "1" ]; then
  exit 0
fi

# Count changes
STATUS=$(git -C "$CWD" status --porcelain 2>/dev/null)
if [ -z "$STATUS" ]; then
  exit 0
fi

TOTAL=$(echo "$STATUS" | wc -l | tr -d ' ')
UNTRACKED=$(echo "$STATUS" | grep -c '^??' || true)
MODIFIED=$((TOTAL - UNTRACKED))
BARE="Working tree has $TOTAL uncommitted changes ($MODIFIED modified, $UNTRACKED untracked)"

# ---- attribution branch (allowlist-gated, strict fail-open) ----------------
TOPLEVEL=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)
ALLOWLIST="${DHX_DIRTY_TREE_ALLOWLIST:-$HOME/repos/<skills-monorepo>:$HOME/repos/cross-repo}"
IN_ALLOWLIST=0
if [ -n "$TOPLEVEL" ]; then
  IFS=':' read -ra ROOTS <<< "$ALLOWLIST"
  for r in "${ROOTS[@]}"; do
    if [ "$TOPLEVEL" = "$r" ]; then IN_ALLOWLIST=1; break; fi
  done
fi
if [ "$IN_ALLOWLIST" != "1" ]; then
  echo "$BARE"
  exit 0
fi

# ---- outcome log (see OUTCOME LOG in the header) --------------------------
if [ -n "${DHX_DIRTY_TREE_LOG+x}" ]; then
  LOG="$DHX_DIRTY_TREE_LOG"
elif [ -n "${DHX_DIRTY_TREE_WHO:-}${DHX_DIRTY_TREE_ALLOWLIST:-}" ]; then
  LOG=""
else
  LOG="${XDG_STATE_HOME:-$HOME/.local/state}/dhx/dirty-tree-who.tsv"
fi
now_us() { local t="${EPOCHREALTIME:-}"; if [ -n "$t" ]; then echo "${t//[.,]/}"; else date +%s%6N; fi; }
T0=$(now_us)
# HP-015: session_id is on SessionStart stdin; own files label "this session"
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
log_outcome() { # outcome, payload-bytes — fail-open: never touches stdout or rc
  [ -n "$LOG" ] || return 0
  {
    local ms=$(( ($(now_us) - T0) / 1000 ))
    mkdir -p "$(dirname "$LOG")" || return 0
    if [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
      mv -f "$LOG" "$LOG.1"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TOPLEVEL" \
      "$1" "$ms" "${2:-0}" "$SESSION_ID" >> "$LOG"
  } >/dev/null 2>&1
  return 0
}

WHO="${DHX_DIRTY_TREE_WHO:-$HOME/.claude/dhx-tools/dhx-history/dhx-who.sh}"
TIMEOUT_S="${DHX_DIRTY_TREE_WHO_TIMEOUT:-8}"
if [ ! -e "$WHO" ]; then
  log_outcome helper-absent
  echo "$BARE"
  exit 0
fi

# Capture to a FILE, never $( ). `timeout` kills only its direct child; the
# helper's python grandchild survives the kill, and if it held a $( ) pipe the
# hook would block on pipe-EOF past the timeout. A file has no reader to block;
# the orphan writes to an unlinked inode and exits on its own.
TMPOUT=$(mktemp)
trap 'rm -f "$TMPOUT"' EXIT

# Single-source the protocol string and the cap so a notice can never disagree
# with the guard that fired it.
WANT_PROTO="dhx-who protocol 1"
CEILING=16384

timeout "$TIMEOUT_S" bash "$WHO" --version > "$TMPOUT" 2>/dev/null
RC=$?
# TRANSIENT: the probe itself failed — timeout, non-executable, mid-install tree
# state. Silent (DEGRADE VOICE above). `timeout` exits 124 when it fired.
if [ "$RC" -ne 0 ]; then
  if [ "$RC" -eq 124 ]; then log_outcome version-timeout; else log_outcome version-fail; fi
  echo "$BARE"
  exit 0
fi
# PERMANENT: the helper answered, with a protocol this hook does not speak.
# `tr -cd` because the helper's stdout is an UNTRUSTED channel and this text
# lands in every session's SessionStart context; head -c bounds the length.
VERSTR=$(head -c 64 "$TMPOUT" | tr -cd '[:print:]')
if [ "$VERSTR" != "$WANT_PROTO" ]; then
  log_outcome protocol-mismatch
  echo "$BARE"
  echo "dhx-who attribution protocol mismatch (helper reports \"$VERSTR\", this hook speaks \"$WANT_PROTO\"); showing bare count until the hook's expected protocol string is updated"
  exit 0
fi

SELF_ARGS=()
if [ -n "$SESSION_ID" ]; then SELF_ARGS=(--self "$SESSION_ID"); fi

: > "$TMPOUT"
timeout "$TIMEOUT_S" bash "$WHO" --repo "$TOPLEVEL" "${SELF_ARGS[@]}" > "$TMPOUT" 2>/dev/null
RC=$?

if [ "$RC" -eq 3 ]; then
  # dhx-who's serialization canary — the one loud degrade (see header)
  log_outcome canary
  echo "$BARE"
  echo "dhx-who attribution canary failed (helper exit 3: tool-input serialization drift); showing bare count until dhx-who's key form is updated"
  exit 0
fi
if [ "$RC" -ne 0 ]; then
  if [ "$RC" -eq 124 ]; then log_outcome timeout; else log_outcome "exit-$RC"; fi
  echo "$BARE"
  exit 0
fi

SIZE=$(stat -c %s "$TMPOUT" 2>/dev/null || echo 0)
# TRANSIENT: nothing, or a partial write under the F3 two-file skew. Silent.
if [ "$SIZE" -eq 0 ]; then
  log_outcome empty
  echo "$BARE"
  exit 0
fi
# PERMANENT: a whole payload this hook refuses to relay. Persists while the tree
# stays this dirty, and what it drops is the non-re-derivable owner map.
if [ "$SIZE" -gt "$CEILING" ]; then
  log_outcome over-cap "$SIZE"
  echo "$BARE"
  echo "dhx-who attribution payload over cap ($SIZE bytes vs $CEILING limit; discarded whole, not truncated); showing bare count"
  exit 0
fi

case "$(head -c 19 "$TMPOUT")" in
  "[shared-tree state]") log_outcome ok "$SIZE"; cat "$TMPOUT" ;;
  *) log_outcome malformed "$SIZE"; echo "$BARE" ;;
esac
exit 0
