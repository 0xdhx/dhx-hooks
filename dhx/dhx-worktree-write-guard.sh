#!/usr/bin/env bash
# dhx-worktree-write-guard.sh — PreToolUse hook (Edit|Write|MultiEdit matcher)
# Patterns: HP-003, HP-007, HP-009, HP-066
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
# (private report 2026-09-25-guard-false-positive-census fix 3). Those two roots are not the leak
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
#   - the job dir is the one whose state.json names hook STDIN's session_id as the job's LIVE id,
#     `(.resumeSessionId // .sessionId)` — never $CLAUDE_JOB_DIR, which is settable to anything
#     including the main checkout ([18]). NOT the dir NAME: a job dir is named after the BIRTH id
#     (`jobs/<first 8 of sessionId>`), and STDIN carries the LIVE id, which moves on /clear, on a
#     resume that mints a new id, and on some /compact continuations. 85 of 193 job dirs on this
#     host had rotated away from their name (2026-09-25, `resumeSessionId != sessionId` over
#     ~/.ccs/instances/*/jobs/*/state.json), and the name-keyed version false-denied every one
#     of them ([26]). CC 2.1.282 keeps the field current in two places: the /clear path rewrites
#     it immediately, and the per-turn state classifier rewrites it with the current id on every
#     classified turn (HP-066). Live id only, not "either id": the birth id after a rotation is a
#     dead conversation, and admitting it would outlive the job's own addressing ([27]).
#     Hardening: session_id must be a full UUID; state.json must be a regular file, not a
#     symlink ([29]); an id found only in another field (fork parents, intent text) does not
#     count — grep -F prefilters, jq decides ([28]); the dir must canonicalize to a DIRECT child
#     of <config>/jobs ([30]). A state.json the session edits can only widen admission into
#     that same dir, which it could already write.
# $HOME, sibling repos and other sessions' job dirs stay denied ([16], [22]).
SESSION_ID=$(jq -r '.session_id // ""' <<<"$INPUT" 2>/dev/null || true)
# One resolution feeds the admission AND the deny text, so the message names exactly what the
# verdict used. Lazy: only a write outside the worktree and outside /tmp pays for it (~4 ms over
# 59 state files, measured 2026-09-25).
JOB_DIRS=()
JOBS_RESOLVED=0
resolve_job_dirs() {
  [[ "$JOBS_RESOLVED" == 1 ]] && return 0
  JOBS_RESOLVED=1
  [[ "$SESSION_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || return 0
  local cfg_jobs state d
  cfg_jobs=$(realpath -e -- "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/jobs" 2>/dev/null || true)
  [[ -n "$cfg_jobs" ]] || return 0
  while IFS= read -r -d '' state; do
    [[ -f "$state" && ! -L "$state" ]] || continue
    jq -e --arg s "$SESSION_ID" '(.resumeSessionId // .sessionId) == $s' "$state" >/dev/null 2>&1 || continue
    if d=$(realpath -e -- "${state%/state.json}" 2>/dev/null) && [[ "$d" == "$cfg_jobs"/* && "${d#"$cfg_jobs"/}" != */* ]]; then
      JOB_DIRS+=("$d")
    fi
  done < <(grep -l -Z -F -- "$SESSION_ID" "$cfg_jobs"/*/state.json 2>/dev/null)
  return 0
}
if REAL=$(realpath -m -- "$FILE" 2>/dev/null) && [[ "$REAL" == /* ]]; then
  SCRATCH_OK=0
  [[ "$REAL" == /tmp/* ]] && SCRATCH_OK=1
  if [[ "$SCRATCH_OK" == 0 ]]; then
    resolve_job_dirs
    for JD in "${JOB_DIRS[@]}"; do
      [[ "$REAL" == "$JD"/* ]] && { SCRATCH_OK=1; break; }
    done
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
# The reason names what the guard RESOLVED, not the rule: on 2026-09-25 a deny that promised
# "$CLAUDE_JOB_DIR" (never read) hid a resolution that had come out empty.
resolve_job_dirs
if [[ "$SESSION_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then SID_SHOW="${SESSION_ID:0:8}"; else SID_SHOW="none"; fi
JOB_SHOW="none"
[[ ${#JOB_DIRS[@]} -gt 0 ]] && JOB_SHOW="${JOB_DIRS[*]}"
REASON="Worktree-leak guard: Edit/Write file_path escapes the worktree boundary (issue #36182). cwd=$CWD file_path=$FILE worktree=$WT_ROOT — use a worktree-rooted absolute path or a cwd-relative path. Scratch writes may go to /tmp or this session's job dir; job dir resolved from hook stdin session_id=$SID_SHOW via <config>/jobs/*/state.json (live id): $JOB_SHOW. Both are checked after resolving symlinks, and a target with a second hard link is refused."
if DENY_JSON=$(jq -cn --arg r "$REASON" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null) \
   && printf '%s\n' "$DENY_JSON"; then
  exit 0
fi
echo "BLOCKED (fallback): worktree-leak write-guard could not emit structured deny; hard-blocking." >&2
exit 2
