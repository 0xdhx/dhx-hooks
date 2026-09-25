#!/usr/bin/env bash
# dhx-worktree-write-guard.sh — PreToolUse hook (Edit|Write|MultiEdit matcher)
# Patterns: HP-003, HP-007, HP-009
#
# Blocks Edit/Write/MultiEdit calls whose absolute file_path escapes the
# enclosing Claude Code managed worktree when cwd is inside one. Protects
# against the silent-write-to-main-repo class of issue anthropics/claude-code
# #36182. Two scratch roots pass after canonicalization — /tmp and this
# session's job dir (2026-09-25; see the "Scratch roots" block below).
#
# ════════════════════════════════════════════════════════════════════════════
# SCOPE (HP-003 reframe, 2026-04-21): fires for parent AND subagent writes.
# ════════════════════════════════════════════════════════════════════════════
# PreToolUse:Write and PreToolUse:Edit propagate from Agent subprocesses to
# parent-registered hooks — subagent tool calls carry `agent_id`/`agent_type`
# in stdin and the subagent's worktree as `cwd`. The subagent leak vector
# reported in #36182 (Edit calls inside an isolation="worktree" agent writing
# to main-repo absolute paths) is therefore CAUGHT by this hook for Write and
# Edit. MultiEdit coverage is moot under current CC 2.1.112 — the tool is
# absent from both parent and general-purpose subagent tool surfaces per
# HP-003 campaign 2026-04-21, so the matcher is dormant until CC restores
# the tool. Matcher retained; no live invocations to observe.
#
# Audit decision 2026-04-21: parent+subagent uniform enforcement — a subagent
# write that escapes its worktree is the same violation as a top-level one.
# Neither context gets a relaxation; the hook does NOT branch on agent_id.
#
# Companion hooks retain independent value:
#   dhx/dhx-agent-leak-snapshot.sh  (PreToolUse:Agent, HP-011) — snapshots
#   dhx/dhx-agent-leak-check.sh     (PostToolUse:Agent, HP-011) — diffs
#   dhx/dhx-worktree-bash-guard.sh  (PreToolUse:Bash) — shell-fallback vector
# They cover tool classes outside Write|Edit|MultiEdit (Bash shell fallback,
# cp/mv/rsync, etc.) that this hook's matcher cannot see.
#
# This hook catches:
#   - user's own top-level Edit/Write/MultiEdit with cwd inside a worktree
#   - inline Skill (e.g. gsd-fast) writes that escape the worktree
#   - subagent Edit/Write inside isolation="worktree" dispatches (#36182)
#   - subagent MultiEdit (matcher dormant per HP-003 campaign 2026-04-21
#     — MultiEdit tool absent from current CC 2.1.112 invocable set)
#
# Prior art: @yurukusa's 2026-03-30 comment on #36182 proposed a git rev-parse
# --git-dir / --git-common-dir based detection. This implementation uses cwd
# string-prefix matching instead — ~20× faster (3ms vs 60ms) and we only care
# about CC-managed worktrees under .claude/worktrees/.

set -euo pipefail

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then exit 0; fi

# Single jq pass, NUL-framed — NOT `@tsv` + `IFS=$'\t' read`. TAB is IFS *whitespace*, so
# `read` collapsed an EMPTY `.cwd` and shifted the file path into CWD, leaving FILE empty.
# Here that was verdict-NEUTRAL, measured (docs/decisions.md 2026-09-25 row): with no cwd the
# guard has nothing to anchor a deny on, so both bindings reached the same allow. The parse is
# fixed so it stays honest, not because it misfired. NUL follows every field, so an empty one
# still has its delimiter. A NUL INSIDE a field is escaped to the two characters `\0` — exactly how
# `@tsv` rendered it — NOT rejected as the non-guard parses do: rejecting empties both fields,
# which ALLOWS, and the old parse DENIED a worktree cwd carrying one (probe [14]). A guard does
# not loosen, even on input no kernel path can produce; both values are compared, never keyed.
{ IFS= read -r -d '' CWD; IFS= read -r -d '' FILE; } < <(jq -j '
  def f: (. // "") | tostring | gsub("\u0000"; "\\0");
  (.cwd | f), "\u0000", (.tool_input.file_path | f), "\u0000"' <<<"$INPUT" 2>/dev/null) || { CWD=""; FILE=""; }

# Fast exit: not in a CC-managed worktree
[[ "$CWD" == *".claude/worktrees/"* ]] || exit 0

# No file_path (some tool variants pass different shapes) — let through
[[ -n "$FILE" ]] || exit 0

# Only guard absolute paths. Relative paths resolve against cwd correctly
# by CC's path resolver — no leak vector there.
[[ "$FILE" == /* ]] || exit 0

# Derive worktree root: everything up through the agent-ID segment
WT_ROOT=$(echo "$CWD" | sed -E 's|(.*\.claude/worktrees/[^/]+).*|\1|')

# File inside worktree → OK
[[ "$FILE" == "$WT_ROOT"/* ]] && exit 0

# --- Scratch roots: /tmp and THIS session's job dir (2026-09-25, operator ruling) ---
# 136 of this guard's 141 false denies in 90 days were worktree agents writing scratch files
# (reports/2026-09-25-guard-false-positive-census.md fix 3). Those two roots are not the leak
# #36182 is about, so they pass — but only after canonicalizing, because every lexical version
# of this allowance was broken by an adversarial pass before it shipped:
#   - `realpath -m` FIRST: a /tmp symlink aliased onto the main repo, and a `/tmp/../` path,
#     both resolve out of /tmp and fall through to the deny (probe [19], [20]).
#   - realpath failing is a DENY, never an exit: under `set -e` a bare failing assignment exits
#     1, and exit 1 does not block (HP-009) — the `if` form keeps it errexit-exempt ([23]).
#   - an EXISTING target with more than one hard link is refused: /tmp and $HOME share one
#     filesystem on this host, so a scratch-path hardlink onto a repo file is reachable, and
#     realpath keeps the scratch name ([21]). Static case only; a link created between this
#     check and the write is a race this hook cannot close.
#   - the job dir comes from hook STDIN — <config>/jobs/<first 8 of session_id>, the layout of
#     194 of 194 job dirs measured 2026-09-25 — never from $CLAUDE_JOB_DIR, which is settable
#     to anything including the main checkout ([18]). The session prefix must be 8 hex chars
#     (no path characters), the dir must exist, and it must canonicalize INSIDE <config>/jobs.
# $HOME, sibling repos and other sessions' job dirs stay denied ([16], [22]).
SESSION_ID=$(jq -r '.session_id // ""' <<<"$INPUT" 2>/dev/null || true)
if REAL=$(realpath -m -- "$FILE" 2>/dev/null) && [[ "$REAL" == /* ]]; then
  SCRATCH_OK=0
  [[ "$REAL" == /tmp/* ]] && SCRATCH_OK=1
  if [[ "$SCRATCH_OK" == 0 && "$SESSION_ID" =~ ^[0-9a-f]{8} ]]; then
    CFG_JOBS=$(realpath -e -- "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/jobs" 2>/dev/null || true)
    JOB_ROOT=$(realpath -e -- "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/jobs/${SESSION_ID:0:8}" 2>/dev/null || true)
    if [[ -n "$CFG_JOBS" && -n "$JOB_ROOT" && "$JOB_ROOT" == "$CFG_JOBS"/* && "$REAL" == "$JOB_ROOT"/* ]]; then
      SCRATCH_OK=1
    fi
  fi
  if [[ "$SCRATCH_OK" == 1 ]]; then
    LINKS=$(stat -c %h -- "$REAL" 2>/dev/null || echo 1)
    [[ "$LINKS" == 1 ]] && exit 0
  fi
fi

# INVARIANT: fires for parent AND subagent Write|Edit calls (HP-003 verified
# 2026-04-21). Uniform enforcement intended — a subagent escape is the same
# violation as a top-level escape. Do NOT add an agent_id short-circuit.
# File outside worktree → BLOCK
# --- D-03: structured fail-closed deny (parity with dhx-worktree-bash-guard.sh) ---
# CC processes JSON only on exit 0; a non-zero exit AFTER emitting deny-JSON is the
# fail-open trap. Emit-then-exit-0 inside the `if` condition (errexit-exempt); fall
# CLOSED to exit 2 if the emit fails (still hard-blocks). Nothing runs between a
# successful printf and exit 0.
REASON="Worktree-leak guard: Edit/Write file_path escapes the worktree boundary (issue #36182). cwd=$CWD file_path=$FILE worktree=$WT_ROOT — use a worktree-rooted absolute path or a cwd-relative path. Scratch writes may go to /tmp or this session's job dir (\$CLAUDE_JOB_DIR); those are checked after resolving symlinks, and a target with a second hard link is refused."
if DENY_JSON=$(jq -cn --arg r "$REASON" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null) \
   && printf '%s\n' "$DENY_JSON"; then
  exit 0
fi
echo "BLOCKED (fallback): worktree-leak write-guard could not emit structured deny; hard-blocking." >&2
exit 2
