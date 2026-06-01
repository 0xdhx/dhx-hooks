#!/usr/bin/env bash
# dhx-git-destructive-guard.sh — PreToolUse hook (Bash matcher)
# Patterns: HP-003, HP-009, HP-028, HP-037
#
# Closes the SYNTACTIC bypass surface that the existing
# `Bash(git push --force *)` / `Bash(git push -f *)` deny strings
# structurally cannot catch. The H1 enforcement-backstop for the
# skills-repo v1.3 /dhx:git.
#
# ════════════════════════════════════════════════════════════════════════════
# WHY THIS HOOK EXISTS (HP-037 anchor)
# ════════════════════════════════════════════════════════════════════════════
# HP-037 verified empirically (2026-05-25, CC 2.1.150): the deny-glob
# `Bash(cmd *)` matches the BARE `cmd` form. So bare `git push --force`
# and `git push -f` are ALREADY blocked by the existing deny rules —
# this hook MUST NOT add bare-form deny entries (redundant) and MUST NOT
# tighten the deny-glob (would over-block --force-with-lease).
#
# Two bypasses are SYNTACTIC — no prefix-anchored deny string can see
# them, regardless of trailing-glob behavior — and were verified to slip
# the live CC matcher (bypass-vector audit):
#
#   #1  Refspec with leading `+`     git push origin +main
#                                    git push origin +HEAD:main
#                                    git push origin src:+dst
#   #2  Leading-token redirection    git -C <path> push --force
#                                    git --git-dir=<path> push --force
#                                    git -c k=v push --force
#
# Permission eval order:
#   Hooks → Deny rules → mode check → Allow → canUseTool
# Hooks run BEFORE deny rules → this PreToolUse:Bash guard can block on
# INTENT before the deny-string check. Deny holds even under
# defaultMode: bypassPermissions, so this hook + the existing deny
# strings together are the entire firewall for the force-push surface.
#
# ════════════════════════════════════════════════════════════════════════════
# WHAT THIS HOOK DOES NOT TOUCH (decoupling — council-locked)
# ════════════════════════════════════════════════════════════════════════════
# `git reset --hard` enforcement is council-locked D-1..D-7 (2026-05-08):
# the agent-runtime layer stays fail-closed and NOT intent-aware; legitimate
# worktree-base correction was relocated to the orchestrator layer, NOT by
# loosening enforcement. This hook adds force-push bypass coverage ONLY and
# MUST NOT relax `git reset --hard`.
#
# ════════════════════════════════════════════════════════════════════════════
# SUBAGENT COVERAGE (HP-003 v2)
# ════════════════════════════════════════════════════════════════════════════
# PreToolUse:Bash propagates from subagents with full agent context (verified
# 2026-04-21, CC 2.1.112+). So this guard covers BOTH parent and subagent git
# commands — precisely the autonomous-runtime threat the deny rule guards
# (#7232). No branching on agent_id; uniform enforcement.
#
# Detection (each shell-separator-delimited segment is parsed independently):
#   1. Tokenize segment on whitespace (v1 floor: no full shell-quoting).
#   2. If first token != `git`, segment is non-git — ALLOW.
#   3. Skip git global options to find the subcommand (-C path, --git-dir[=],
#      --work-tree[=], -c k=v / -c<k=v>, -p / --paginate / --no-pager,
#      --namespace[=], --super-prefix[=], --bare, --no-replace-objects,
#      --no-optional-locks, --[no]glob-pathspecs, --literal-pathspecs,
#      --icase-pathspecs, --exec-path[=], --html-path, --man-path,
#      --info-path, --version, --help). Arg-takers consume the next token.
#   4. If subcommand != `push`, segment is not a push — ALLOW.
#   5. BLOCK if any positional refspec has `+` at the start of any
#      colon-delimited component (`+ref`, `+src:dst`, `src:+dst`).
#   6. BLOCK if a force flag is present:
#        --force                              (whole-token match)
#        -<short cluster containing f>        (e.g., -f, -fu, -uf)
#      ALLOW the GIT-SAFE-07 safe variants (whole-token, NOT substring):
#        --force-with-lease
#        --force-with-lease=<ref>
#        --force-if-includes
#
# Known v1 false-positives (acceptable; widen if observed):
#   - Quoted positional args containing literal `+`/colons (e.g.,
#     `git push origin "+special-tag"`). v1 whitespace tokenizer doesn't
#     unquote; the `+` still looks like a refspec. Rare in practice.
#
# HP-028 discipline: all command inspection uses here-strings (`<<<`),
# never `cmd | grep -q`.

set -uo pipefail

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then exit 0; fi

CMD=$(jq -r '.tool_input.command // ""' <<<"$INPUT" 2>/dev/null || echo "")
[[ -n "$CMD" ]] || exit 0

# ── Split the command on shell separators ────────────────────────────────
# Convert &&, ||, ;, |, and literal newlines into newline-delimited segments.
# Use a here-string into sed (no pipe — sidesteps HP-028 entirely; sed reads
# all input either way).
SPLIT=$(sed -e 's/&&/\n/g' -e 's/||/\n/g' -e 's/;/\n/g' -e 's/|/\n/g' <<<"$CMD")

BLOCK_REASON=""

# Returns:
#   0  segment allowed (no block)
#   1  segment blocked; sets BLOCK_REASON
inspect_segment() {
  local segment="$1"
  local -a tokens
  # v1 floor: whitespace-split. Real shell tokenization (quotes, $-expansion)
  # is out of scope; the HP-037 anchor narrows this hook to syntactic bypasses
  # of the deny strings — those bypasses are themselves whitespace-tokenized.
  read -ra tokens <<<"$segment" || return 0
  [[ ${#tokens[@]} -gt 0 ]] || return 0

  # Strip leading shell-noise (a trimmed segment can start with empty token)
  local i=0
  while [[ $i -lt ${#tokens[@]} && -z "${tokens[$i]}" ]]; do
    i=$((i + 1))
  done

  # First-token must be `git` (v1 floor — bare git, no leading env/assignments)
  [[ "${tokens[$i]:-}" == "git" ]] || return 0
  i=$((i + 1))

  # ── Skip git global options to find the subcommand ─────────────────────
  while [[ $i -lt ${#tokens[@]} ]]; do
    local t="${tokens[$i]}"
    case "$t" in
      # arg-takers (consume next token)
      -C|--git-dir|--work-tree|--namespace|--super-prefix)
        i=$((i + 2)); continue ;;
      # -c standalone — consumes next (the k=v pair)
      -c)
        i=$((i + 2)); continue ;;
      # =-form globals (self-contained, single token)
      --git-dir=*|--work-tree=*|--namespace=*|--super-prefix=*|--exec-path=*)
        i=$((i + 1)); continue ;;
      # -c with key=value bundled (e.g., -chttp.proxy=foo)
      -c?*)
        i=$((i + 1)); continue ;;
      # no-arg globals
      -p|-P|--paginate|--no-pager|--bare|--no-replace-objects|--no-optional-locks)
        i=$((i + 1)); continue ;;
      --literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs)
        i=$((i + 1)); continue ;;
      --exec-path|--html-path|--man-path|--info-path|--version|--help)
        i=$((i + 1)); continue ;;
      # First non-option token is the subcommand
      *)
        break ;;
    esac
  done

  # Subcommand must be `push` — otherwise this segment is not our concern
  local subcommand="${tokens[$i]:-}"
  [[ "$subcommand" == "push" ]] || return 0
  i=$((i + 1))

  # ── Walk push arguments for force-flags and +refspec ───────────────────
  while [[ $i -lt ${#tokens[@]} ]]; do
    local t="${tokens[$i]}"
    case "$t" in
      # Explicit allow: GIT-SAFE-07 safe variants (matched FIRST so the
      # --force whole-token check below cannot trip on the prefix)
      --force-with-lease|--force-with-lease=*|--force-if-includes)
        i=$((i + 1)); continue ;;
      # BLOCK: bare --force (whole-token, substring-trap safe)
      --force)
        BLOCK_REASON="--force flag present (use --force-with-lease)"
        return 1 ;;
      # BLOCK: single-dash short cluster containing 'f' (e.g., -f, -fu, -uf)
      # The pattern -[a-zA-Z]+ requires a single leading dash, so --foo
      # cannot match here.
      -*)
        if [[ "$t" =~ ^-[a-zA-Z]+$ && "$t" == *f* ]]; then
          BLOCK_REASON="-f short-flag cluster '$t' (use --force-with-lease)"
          return 1
        fi
        # Other unknown flags — skip
        i=$((i + 1)); continue ;;
      # Positional — could be a refspec. Check for leading `+` on any
      # colon-delimited component (`+ref`, `+src:dst`, `src:+dst`).
      *)
        if [[ "$t" == *+* ]]; then
          local IFS_BAK="$IFS"
          IFS=':'
          local -a parts
          read -ra parts <<<"$t"
          IFS="$IFS_BAK"
          local p
          for p in "${parts[@]}"; do
            if [[ "$p" == +* ]]; then
              BLOCK_REASON="refspec '$t' has leading '+' (force-push via refspec; use --force-with-lease)"
              return 1
            fi
          done
        fi
        i=$((i + 1)); continue ;;
    esac
  done

  return 0
}

# Iterate segments
while IFS= read -r SEGMENT; do
  [[ -n "$SEGMENT" ]] || continue
  if ! inspect_segment "$SEGMENT"; then
    cat >&2 <<EOF
BLOCKED: git destructive-op guard tripped on $BLOCK_REASON

  command: $CMD
  segment: $SEGMENT

Safe alternative: --force-with-lease (or --force-if-includes). These check
that the remote ref matches your local expectation before overwriting it,
which is what the skills-repo git-safety helper standardizes on
(GIT-SAFE-07). Plain --force / -f / +refspec overwrite unconditionally
and lose other contributors' work.

If this command is genuinely correct (e.g., re-publishing a rewritten
demo branch you own exclusively), invoke git directly outside Claude's
Bash tool. This guard exists because force-push bypasses via +refspec
and 'git -C' / '--git-dir=' / '-c k=v' redirection cannot be caught by
the existing prefix-anchored deny strings.
EOF
    echo "BLOCKED: git destructive-op guard tripped on $BLOCK_REASON"
    exit 2
  fi
done <<<"$SPLIT"

exit 0
