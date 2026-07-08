#!/usr/bin/env bash
# dhx-worktree-bash-guard.sh — PreToolUse hook (Bash matcher)
# Patterns: HP-003, HP-007, HP-009, HP-028
#
# Companion to dhx-worktree-write-guard.sh. Blocks Bash tool calls that write
# to main-repo absolute paths when cwd is inside a CC-managed worktree —
# closes the shell-fallback channel of anthropics/claude-code #36182 (third
# incident, 2026-04-19, reports/2026-04-19-worktree-leak-gh-36182-third-incident.md).
#
# The write-guard only covers Edit|Write|MultiEdit. When CC's read-before-edit
# enforcement rejects an Edit, agents fall back to `sed -i`, `tee`, `>`, etc.,
# which route through the Bash tool and bypass the write-guard entirely.
#
# ════════════════════════════════════════════════════════════════════════════
# SUBAGENT COVERAGE (HP-003 v2, verified 2026-04-21, CC 2.1.112+)
# ════════════════════════════════════════════════════════════════════════════
# PreToolUse:Bash propagates from subagents with full agent context
# (agent_id / agent_type populated). This guard now catches:
#   - user's own top-level Bash writes from a worktree cwd
#   - inline Skill (e.g. gsd-fast) Bash writes that escape the worktree
#   - subagent Bash writes (general-purpose / Explore / gsd-* etc.) —
#     same uniform enforcement path (no agent_id branching)
# The prior comment claimed "does NOT fire inside Agent subprocesses (HP-003)"
# — that pre-2026-04-21 reading is superseded by HP-003 v2. The hook code
# itself was already correct; only the scope-limitation comment was stale.
# Companion observers `dhx-agent-leak-{snapshot,check}.sh` (PostToolUse:Agent
# layer) remain useful for post-hoc filesystem visibility around subagent
# boundaries, but they are no longer the ONLY coverage path for this vector.
#
# DETECTION SCOPE (deliberately narrow to avoid blocking legit reads):
#   sed -i | tee | > | >> | printf ... > | python3? -c | dd ... of= | install
# Known gaps (acceptable v1 false-negatives, widen on field-observed leaks):
#   - cp / mv / rsync with main-repo destination (too many legit uses)
#   - heredoc redirects tokenized across shell expansion
#   - node/ruby/perl -e with fs.writeFile / File.write / open(w)
# The resolver-level fix upstream is the proper solution; this is a band-aid.
#
# ⚠ LOAD-BEARING GAP — do NOT widen the literal `grep -qF "$MAIN_ROOT/"` (line ~98)
# to resolve variables without an exemption path. A variable-held absolute path
# ($VAR) currently passes because the literal $MAIN_ROOT/ string is absent from the
# command text — the same escape shape as the D-05 env-C branch already closed. But
# the skills-repo `/dhx:test` CAPTURE-drain (REMED-07) DEPENDS on this gap: it does a
# DELIBERATE, correct worktree→main-repo append via `cat "$tmp" >> "$CAPTURE_ABS"`.
# Closing the variable gap would block that legitimate write (a false-positive on an
# intended cross-tree write). Before widening: allowlist the intended target, or give
# the drain a guard-approved cross-tree affordance. Scope note: `git` is NOT a write-
# verb here, so git-safe / `git -C "$ROOT"` are unaffected either way.
# Full analysis: reports/2026-07-08-worktree-bash-guard-gap-is-loadbearing-for-deliberate-cross-tree-writes.md

set -euo pipefail

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then exit 0; fi

IFS=$'\t' read -r CWD CMD < <(jq -r '[.cwd // "", .tool_input.command // ""] | @tsv' <<<"$INPUT" 2>/dev/null || echo $'\t')

# Fast exit: not in a CC-managed worktree
[[ "$CWD" == *".claude/worktrees/"* ]] || exit 0

# Empty command — nothing to inspect
[[ -n "$CMD" ]] || exit 0

# Derive worktree root: everything up through the agent-ID segment
WT_ROOT=$(echo "$CWD" | sed -E 's|(.*\.claude/worktrees/[^/]+).*|\1|')

# Derive main-repo root: strip the trailing .claude/worktrees/<id> (3 levels up)
# <main>/.claude/worktrees/<id>  →  <main>
MAIN_ROOT=$(dirname "$(dirname "$(dirname "$WT_ROOT")")")

# --- Detect write-verb ---
# Grep is line-unfriendly for shell pipelines but fine here — CMD is a single
# command string. Anchored token matches to cut false positives (e.g., `sed`
# without `-i` is a read operation, so we require the `-i`).
HAS_WRITE_VERB=0
if grep -qE '(^|[^[:alnum:]_])sed[[:space:]]+(-[[:alnum:]]*i|[^-][^[:space:]]*[[:space:]]+-[[:alnum:]]*i)' <<< "$CMD"; then
  HAS_WRITE_VERB=1
elif grep -qE '(^|[^[:alnum:]_])(tee|dd|install)[[:space:]]' <<< "$CMD"; then
  HAS_WRITE_VERB=1
elif grep -qE '[[:space:]]>>?[[:space:]]*[^[:space:]|&;]' <<< "$CMD"; then
  # > or >> redirection targeting a path (not >| process sub or >& fd)
  HAS_WRITE_VERB=1
elif grep -qE '(^|[^[:alnum:]_])python3?[[:space:]]+-c' <<< "$CMD"; then
  HAS_WRITE_VERB=1
fi

[[ "$HAS_WRITE_VERB" == "1" ]] || exit 0

# --- D-05: env -C <main-root-exact> escape (bare/quoted cwd, relative target) ---
# The main-root-hit grep below needs "$MAIN_ROOT/"; `env -C <root>` is followed by
# a SPACE (and the target is relative), so a relative-target write under
# `env -C <root>` never produces "$MAIN_ROOT/" and evaded detection. Catch
# `env -C <MAIN_ROOT>` as a bare/quoted directory token (incl. `env -i -C` and
# multi-space), provided it is NOT the WT_ROOT form. The trailing space|quote|end
# boundary keeps a sibling repo (/repos/forge vs /repos/forgefinder) from
# false-matching, and an `env -C <root>/subpath` absolute form stays on the
# existing path (already caught via the literal "$MAIN_ROOT/").
ENV_C_MAIN_HIT=0
MAIN_ESC=$(printf '%s' "$MAIN_ROOT" | sed 's|[.[\*^$/]|\\&|g')
WT_ESC=$(printf '%s' "$WT_ROOT" | sed 's|[.[\*^$/]|\\&|g')
if grep -qE "(^|[[:space:]])env([[:space:]]+-[^[:space:]]*)*[[:space:]]+-C[[:space:]]+[\"']?${MAIN_ESC}[\"']?([[:space:]]|\$)" <<< "$CMD" \
   && ! grep -qE "(^|[[:space:]])env([[:space:]]+-[^[:space:]]*)*[[:space:]]+-C[[:space:]]+[\"']?${WT_ESC}" <<< "$CMD"; then
  ENV_C_MAIN_HIT=1
fi

# --- Is a main-repo absolute path referenced? (skip when an env -C main-root hit
#     already fired — fall straight through to the BLOCK tail) ---
if [[ "$ENV_C_MAIN_HIT" != "1" ]]; then
  # Escape MAIN_ROOT for regex use (dots, slashes — use fixed-string grep instead)
  if ! grep -qF "$MAIN_ROOT/" <<< "$CMD"; then
    exit 0
  fi

  # --- Is that path actually inside the worktree (subpath of MAIN_ROOT but
  #     under WT_ROOT)? If yes, allow — worktree paths are legit targets. ---
  # Heuristic: if every occurrence of MAIN_ROOT/ in the command is immediately
  # followed by ".claude/worktrees/", it's a worktree reference.
  # Count main-root hits that DON'T continue into .claude/worktrees/.
  NON_WT_HITS=$(echo "$CMD" \
    | grep -oE "$(printf '%s\n' "$MAIN_ROOT/" | sed 's|[.[\*^$/]|\\&|g')[^[:space:]\"\x27]*" \
    | grep -vcE "\.claude/worktrees/" || true)

  [[ "$NON_WT_HITS" -gt 0 ]] || exit 0
fi

# --- D-03: structured fail-closed deny (PreToolUse permissionDecision) ---
# CC processes JSON only on exit 0; a non-zero exit AFTER emitting deny-JSON would
# make CC discard the deny and let the tool THROUGH (the fail-open trap — strictly
# worse than exit 2). Build the JSON and printf BOTH inside the `if` condition
# (the test position is exempt from `set -e`), exit 0 immediately on a clean emit,
# and fall CLOSED to exit 2 if the emit fails (exit 2 still hard-blocks via stderr).
# Nothing executes between a successful printf and exit 0.
REASON="Worktree-leak guard: Bash write-verb targets a main-repo path from a worktree cwd (issue #36182 shell variant). cwd=$CWD worktree=$WT_ROOT main-root=$MAIN_ROOT command=$CMD — use a worktree-rooted path, or cd into the target repo explicitly."
if DENY_JSON=$(jq -cn --arg r "$REASON" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null) \
   && printf '%s\n' "$DENY_JSON"; then
  exit 0
fi
echo "BLOCKED (fallback): worktree-leak guard could not emit structured deny; hard-blocking." >&2
exit 2
