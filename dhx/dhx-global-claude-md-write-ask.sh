#!/usr/bin/env bash
# dhx-global-claude-md-write-ask.sh — PreToolUse hook (Bash matcher)
# Patterns: HP-003, HP-009, HP-049, HP-061
#
# Ask-gates Bash-side WRITES to the global CLAUDE.md. Companion to the
# `permissions.ask` rules landed 2026-09-19 (hooks `29aacddb`):
#
#   Edit(~/repos/dotfiles/claude/CLAUDE.md)   ← canonical (dotfiles repo)
#   Edit(~/.claude/CLAUDE.md)                 ← symlink to canonical
#   Edit(~/.ccs/instances/*/CLAUDE.md)        ← symlinks to canonical (CCS)
#
# WHY A HOOK ON TOP OF THE RULES. `Edit(path)` rules are consulted for the
# Edit/Write tools and for `>` redirect targets only (code.claude.com/docs/
# en/permissions § "Bash rule limits"), and only the allow/deny lists at
# that — `sed -i`, `tee`, `cp`, a heredoc via `cat > file`, `git checkout --
# file` are invisible to an ask rule. Under `bypassPermissions` the harness
# tells agents to PREFER sed/heredocs over Edit, so the rules gate the door
# agents are told not to use. This hook watches the other door.
#
# DECISION SHAPE: `permissionDecision:"ask"` (HP-049), exit 0. Precedence
# (HP-061, re-read on 2.1.276): a hook `ask` is combined with the rule
# engine — a rule deny still denies; otherwise the ask reaches `canUseTool`
# untouched (`_0e` rewrites it only for tools with an onBlock policy, which
# Bash has none) — i.e. the operator's permission prompt, the same terminus
# a settings ask rule ends in, which prompts even under bypassPermissions
# (docs § "Actions no mode auto-approves"; measured live 2026-09-19). In a
# headless `-p` run `canUseTool` hardens the ask into a deny.
#
# NET (what decides which commands the tooth applies to):
#   global-path predicate  AND  write-verb predicate  →  ask
#   global-path predicate: any of the three spellings above, home-anchored
#     (`~`, `$HOME`, `/home/<u>`) so a PROJECT's `.claude/CLAUDE.md` does
#     not trip it; plus the relative form `claude/CLAUDE.md` when the same
#     command mentions `dotfiles` (the `cd ~/repos/dotfiles && sed -i …
#     claude/CLAUDE.md` shape).
#   write-verb predicate: `sed`/`perl` with an in-place flag; a `>`/`>>`
#     redirect whose target is a CLAUDE.md (fd-dup and /dev/null forms are
#     stripped first); tee/cp/mv/rm/install/truncate/rsync/ln/patch/shred;
#     interpreters (python/node/ruby) — they can write; and
#     `git checkout|restore|mv|rm|reset|stash|clean|apply|am`.
# Reads stay silent: cat/head/tail/grep/sed -n/diff/git diff|log|show.
#
# KNOWN HOLE (structural, not fixable at this layer): a path bound in an
# EARLIER Bash call and written via a variable in a later one carries no
# literal path in the later command. Same-command `f=…; sed -i … "$f"`
# IS caught (the literal is in the text).
#
# Silent on the happy path (exit 0, no stdout). Bad/absent stdin → exit 0.
set -uo pipefail

INPUT=$(cat)
[[ -z "$INPUT" ]] && exit 0

TOOL=$(jq -r '.tool_name // ""' <<<"$INPUT" 2>/dev/null || echo "")
# Manifest matcher is "Bash", but fail open on anything else regardless.
[[ -n "$TOOL" && "$TOOL" != "Bash" ]] && exit 0

CMD=$(jq -r '.tool_input.command // ""' <<<"$INPUT" 2>/dev/null || echo "")
[[ -z "$CMD" ]] && exit 0

# Cheap pre-filter: nothing to gate unless CLAUDE.md is even mentioned.
grep -q 'CLAUDE\.md' <<<"$CMD" || exit 0

# ── global-path predicate ─────────────────────────────────────────────────
HOME_RE='(~|\$HOME|\$\{HOME\}|/home/[A-Za-z0-9_.-]+)'
is_global_path() {
  grep -Eq "dotfiles/claude/CLAUDE\.md" <<<"$CMD" && return 0
  grep -Eq "${HOME_RE}/\.claude/CLAUDE\.md" <<<"$CMD" && return 0
  grep -Eq "${HOME_RE}/\.ccs/instances/[^/[:space:]\"']+/CLAUDE\.md" <<<"$CMD" && return 0
  # relative form after a cd into the dotfiles repo
  grep -Eq 'dotfiles' <<<"$CMD" && grep -Eq '(^|[^A-Za-z0-9_./-])claude/CLAUDE\.md' <<<"$CMD" && return 0
  return 1
}
is_global_path || exit 0

# ── write-verb predicate ──────────────────────────────────────────────────
# Strip redirect forms that never write a file: fd dups and /dev/null.
SCRUB=$(sed -E 's/[0-9]*>&[0-9]+//g; s/[0-9]*>{1,2}[[:space:]]*\/dev\/null//g' <<<"$CMD")
is_write() {
  # sed/perl in-place: any flag cluster carrying `i`, or --in-place
  grep -Eq '(^|[;&|(`[:space:]])(sed|perl)([[:space:]]+-[A-Za-z]+)*[[:space:]]+-[A-Za-z]*i' <<<"$SCRUB" && return 0
  grep -Eq '(^|[;&|(`[:space:]])(sed|perl)[[:space:]].*--in-place' <<<"$SCRUB" && return 0
  # redirect straight onto a CLAUDE.md
  grep -Eq '>{1,2}[[:space:]]*["'"'"']?[^[:space:]"'"'"'|;&]*CLAUDE\.md' <<<"$SCRUB" && return 0
  # file-writing utilities and interpreters (position-independent)
  grep -Eq '(^|[;&|(`[:space:]])(tee|rm|truncate|ln|patch|shred|python3?|node|ruby)([[:space:]]|$)' <<<"$SCRUB" && return 0
  # copy-shaped verbs write their LAST operand: `cp CLAUDE.md /tmp/bak` is a
  # read, `cp /tmp/x …/CLAUDE.md` is a write. Split on segment separators and
  # ask only when a segment led by one of these ends on a CLAUDE.md.
  local seg
  while IFS= read -r seg; do
    grep -Eq '^[[:space:]]*(cp|mv|install|rsync)([[:space:]]|$)' <<<"$seg" || continue
    grep -Eq 'CLAUDE\.md["'"'"']?[[:space:]]*$' <<<"$seg" && return 0
  done < <(sed -E 's/(&&|\|\||[;|])/\n/g' <<<"$SCRUB")
  # git verbs that rewrite the worktree file
  grep -Eq '(^|[;&|(`[:space:]])git([[:space:]]+-[A-Za-z-]+([[:space:]]+[^[:space:]]+)?)*[[:space:]]+(checkout|restore|mv|rm|reset|stash|clean|apply|am)([[:space:]]|$)' <<<"$SCRUB" && return 0
  return 1
}
is_write || exit 0

# ── ask ───────────────────────────────────────────────────────────────────
REASON='This command writes to the GLOBAL CLAUDE.md (~/repos/dotfiles/claude/CLAUDE.md via one of its spellings). Writes there are ask-gated — the operator approves each one. If approved, proceed; otherwise leave the file alone. Prefer the Edit tool on the canonical path so the diff is visible in the prompt.'
jq -cn --arg r "$REASON" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "ask",
    permissionDecisionReason: $r
  }
}'
exit 0
