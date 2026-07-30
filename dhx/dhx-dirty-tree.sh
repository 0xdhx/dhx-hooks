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
# PAYLOAD CEILING — 16384 bytes, measured 2026-07-30 against the live helper:
# 25 dirty files = 2,074 B; 100 = 6,877 B; 200 = 13,377 B (~66 B/file). The
# rollup collapses only live/self owners, so dead/unresolved per-file lines grow
# UNBOUNDED BY DESIGN (they carry the owner map, which the model cannot
# re-derive). So the cap trips at ~245 files today, ~120-150 once dhx-who's
# provenance lines land. Peak observed single-commit churn is 37 (skills) / 23
# (cross-repo) — a strict LOWER bound on peak dirty count, since every file in a
# commit was dirty just before it, so the true peak is unmeasured above 37. The
# cap stays tight because the trip is now VISIBLE: an invisible ceiling has to
# be generous, because a trip costs the operator the whole map and tells them
# nothing; a visible one can stay small and report itself. This is a CROSS-REPO
# constant — dhx-who budgets against the same 16384, so changing it here needs a
# matching note skills-side.
#
# The helper is two files (dhx-who.sh + enumerate-ccs-sessions.sh); --version
# interrogates only the first, so a peer mid-edit can skew them briefly. By
# adjudication this rides the wrapper battery — the failure mode is "bare
# count for a few seconds, silently". Revisit deployment isolation only on a
# real incident where the wrapper degraded because of mid-edit tree state.
#
# Helper contract: ~/repos/skills/.planning/backlog/
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
#                               (default: ~/repos/skills:~/repos/cross-repo)
#   DHX_DIRTY_TREE_WHO          helper path
#                               (default: ~/.claude/dhx-tools/dhx-history/dhx-who.sh)
#   DHX_DIRTY_TREE_WHO_TIMEOUT  seconds (default: 8)

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
ALLOWLIST="${DHX_DIRTY_TREE_ALLOWLIST:-$HOME/repos/skills:$HOME/repos/cross-repo}"
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

WHO="${DHX_DIRTY_TREE_WHO:-$HOME/.claude/dhx-tools/dhx-history/dhx-who.sh}"
TIMEOUT_S="${DHX_DIRTY_TREE_WHO_TIMEOUT:-8}"
if [ ! -e "$WHO" ]; then
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
# state. Silent (DEGRADE VOICE above).
if [ "$RC" -ne 0 ]; then
  echo "$BARE"
  exit 0
fi
# PERMANENT: the helper answered, with a protocol this hook does not speak.
# `tr -cd` because the helper's stdout is an UNTRUSTED channel and this text
# lands in every session's SessionStart context; head -c bounds the length.
VERSTR=$(head -c 64 "$TMPOUT" | tr -cd '[:print:]')
if [ "$VERSTR" != "$WANT_PROTO" ]; then
  echo "$BARE"
  echo "dhx-who attribution protocol mismatch (helper reports \"$VERSTR\", this hook speaks \"$WANT_PROTO\"); showing bare count until the hook's expected protocol string is updated"
  exit 0
fi

# HP-015: session_id is on SessionStart stdin; own files label "this session"
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
SELF_ARGS=()
if [ -n "$SESSION_ID" ]; then SELF_ARGS=(--self "$SESSION_ID"); fi

: > "$TMPOUT"
timeout "$TIMEOUT_S" bash "$WHO" --repo "$TOPLEVEL" "${SELF_ARGS[@]}" > "$TMPOUT" 2>/dev/null
RC=$?

if [ "$RC" -eq 3 ]; then
  # dhx-who's serialization canary — the one loud degrade (see header)
  echo "$BARE"
  echo "dhx-who attribution canary failed (helper exit 3: tool-input serialization drift); showing bare count until dhx-who's key form is updated"
  exit 0
fi
if [ "$RC" -ne 0 ]; then
  echo "$BARE"
  exit 0
fi

SIZE=$(stat -c %s "$TMPOUT" 2>/dev/null || echo 0)
# TRANSIENT: nothing, or a partial write under the F3 two-file skew. Silent.
if [ "$SIZE" -eq 0 ]; then
  echo "$BARE"
  exit 0
fi
# PERMANENT: a whole payload this hook refuses to relay. Persists while the tree
# stays this dirty, and what it drops is the non-re-derivable owner map.
if [ "$SIZE" -gt "$CEILING" ]; then
  echo "$BARE"
  echo "dhx-who attribution payload over cap ($SIZE bytes vs $CEILING limit; discarded whole, not truncated); showing bare count"
  exit 0
fi

case "$(head -c 19 "$TMPOUT")" in
  "[shared-tree state]") cat "$TMPOUT" ;;
  *) echo "$BARE" ;;
esac
exit 0
