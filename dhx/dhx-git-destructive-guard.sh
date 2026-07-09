#!/usr/bin/env bash
# dhx-git-destructive-guard.sh — PreToolUse hook (Bash matcher)
# Patterns: HP-003, HP-009, HP-028, HP-037
#
# Closes the SYNTACTIC bypass surface that the existing
# `Bash(git push --force *)` / `Bash(git push -f *)` / `Bash(git reset --hard*)`
# deny strings structurally cannot catch. The H1 enforcement-backstop for the
# skills-repo v1.3 /dhx:git (cross-repo
# docs/git/destructive-op-enforcement-backstop.md).
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
# the live CC matcher in
# cross-repo/reports/done/2026-05-25-git-force-push-deny-rule-bypass-vectors.md:
#
#   #1  Refspec with leading `+`     git push origin +main
#                                    git push origin +HEAD:main
#                                    git push origin src:+dst
#   #2  Leading-token redirection    git -C <path> push --force
#                                    git --git-dir=<path> push --force
#                                    git -c k=v push --force
#
# Permission eval order (canonical:
# cross-repo/docs/research/2026-05-08-git-reset-hard-worktree-deny-history.md):
#   Hooks → Deny rules → mode check → Allow → canUseTool
# Hooks run BEFORE deny rules → this PreToolUse:Bash guard can block on
# INTENT before the deny-string check. Deny holds even under
# defaultMode: bypassPermissions, so this hook + the existing deny
# strings together are the entire firewall for the force-push surface.
#
# ════════════════════════════════════════════════════════════════════════════
# AUTHZ-01 EXTENSION — agent-surface command interception (XR-32)
# ════════════════════════════════════════════════════════════════════════════
# The reference-transaction layer (Layer-1, XR-29) structurally CANNOT see
# command intent: `reset --hard` / `clean -f` are commit-shaped /
# indistinguishable at the ref layer, and `checkout -b` is byte-identical to
# a sanctioned `worktree add -b` at the ref-txn layer (XR-31 empirical
# falsification of GUARD-03 at Layer-1). This hook is the agent-surface
# command-layer leg of the authorization floor (the OS-boundary half is the
# `+i` immutable-bit backstop, provisioned separately).
#
# THREAT MODEL (accident-class, D-08): a cooperative-but-buggy agent at the
# operator UID issues a git command via the Bash tool that would corrupt the
# SHARED primary checkout (the common gitdir) — e.g. a redirected
# `reset --hard`/`clean -f` aimed at the common dir, or an off-base
# `checkout -b`/`switch -c` in the primary that retargets the shared HEAD
# symref. This hook is an accident TRIPWIRE, not an unforgeable boundary
# against a malicious actor (an agent can invoke git outside the Bash tool;
# that out-of-band path is the OS-boundary half's job).
#
# EFFECTIVE-DIR DISCRIMINATION (the council-caught blanket-allow bug):
# the discriminator is the EFFECTIVE post-redirection gitdir, NOT "is the
# hook running in a worktree." A redirected command FROM a lane that targets
# the common dir (`git -C <common> reset --hard`, `cd <common> && git …`)
# must still BLOCK. is_primary() therefore resolves the effective dir by
# REPLAYING the retained ordered global-option prefix (-C/--git-dir/...) AND
# the running effective-cwd across `cd` segments, then compares
# `rev-parse --absolute-git-dir` == `rev-parse --git-common-dir`
# (resolution shape copied from install-hooks.sh:76–82).
#
# THE RESET ONE-TRUTH-TABLE (no self-contradiction; D-06 fail-closed):
#   | invocation                                   | disposition                |
#   | bare `git reset --hard` (no redirection)     | NOT this hook's concern —   |
#   |                                              | the existing                |
#   |                                              | `Bash(git reset --hard*)`   |
#   |                                              | deny string covers it;      |
#   |                                              | hook returns 0 (no          |
#   |                                              | double-jeopardy)            |
#   | redirected `-C <X>`/`--git-dir=<X>`/`cd <X>` | BLOCK (exit 2) — D-06       |
#   |   reset --hard, effective == COMMON          | fail-closed                 |
#   | redirected reset --hard, effective == a LANE | BLOCK (exit 2) — D-06       |
#   |                                              | fail-closed, block-ALL-     |
#   |                                              | redirected, not intent-aware|
#   | bare `git reset --hard` from inside a lane   | NOT this hook's concern —   |
#   |                                              | existing deny posture       |
#   |                                              | unchanged                   |
#   Net rule: the hook BLOCKS reset --hard IFF a redirection
#   (-C/--git-dir/--work-tree/cd) is present (regardless of common vs lane);
#   the BARE form is left entirely to the unchanged deny string. This removes
#   the prior "block only GITDIR==COMMON" vs "block all redirected"
#   contradiction (D-06 reads "fail-closed, not intent-aware" → block all
#   redirected reset --hard).
#
# clean / checkout / switch arms are scoped to GITDIR==COMMON (the primary):
#   - clean : BLOCK any force form (`-f`/`-fd`/`-fdx`/`-ff`/`--force`/any
#             `^-[a-zA-Z]+$` cluster containing f) when effective == COMMON;
#             ALLOW-FIRST `-n`/`--dry-run` (non-destructive escape).
#   - checkout/switch : BLOCK the off-base branch-CREATE in ALL git-2.54
#             accepted forms when effective == COMMON — separated
#             (`-b`/`-B`/`-c`/`-C`/`--create`/`--force-create`), ATTACHED-arg
#             (`-bfoo`/`-Bfoo`/`-cfoo`/`-Cfoo`), `=value` alias
#             (`--create=foo`/`--force-create=foo`), and `--orphan[=foo]`.
#             `worktree add -b` does NOT route through these subcommands and is
#             UNAFFECTED (the sanctioned creation path). Plain
#             `checkout <path>`/`checkout <branch>` is left alone.
#   switch's `-C` is its `--force-create` (the global `-C <path>` was already
#   consumed/retained by the skipper before landing on the subcommand) — a
#   future editor must not mis-handle the collision.
#
# The `add` arm is scoped to GITDIR==COMMON *and* a DECLARED shared primary:
#   - add : BLOCK the whole-index sweep (`-A` / `--all` / `--no-ignore-removal`
#           — three git synonyms — incl. single-dash clusters like `-Av`) when
#           effective == COMMON *and* the effective repo's
#           `.planning/config.json` declares `shared_primary` (or the legacy
#           `primary_must_stay_on_main`). ALLOW-FIRST `-n`/`--dry-run`.
#
# WHY THE add ARM IS DECLARATION-GATED AND THE OTHERS ARE NOT (the over-block
# trap): `checkout -b` in a primary is wrong in EVERY repo — the sanctioned
# alternative (`worktree add -b`) is always available, so `is_primary()` alone is
# the right predicate. `git add -A` is the OPPOSITE: in a solo repo the primary is
# exactly where you are supposed to run it. Gating the add arm on `is_primary()`
# alone would refuse it in all 16 non-shared repos — which is precisely the
# over-block that rules out a `Bash(git add -A*)` deny string, reproduced one layer
# down. Verified 2026-07-09: `is_primary()` reads only git state and returns 0 for
# ANY primary, solo or shared. The discriminator for THIS hazard is
# writer-concurrency, and only the repo can declare that.
#
# Keyed on `shared_primary` ALONE — never the (shared_primary x branching_strategy)
# pair. Concurrency of writers is orthogonal to branching strategy; pairing them
# would exempt the ONE repo that declares the flag today (`~/repos/cross-repo`,
# which sets `git.branching_strategy: phase`). That decoupling is the whole finding
# of skills `docs/decisions/2026-07-09-commit-mode-branching-none-scoped.md`.
#
# KNOWN RESIDUAL (deliberate, not an oversight): `git add .` from the repo root is
# an equivalent sweep but is NOT blocked — from a subdirectory it is legitimately
# scoped, so a whole-token match would false-positive. Named paths remain the rule;
# see `docs/backlog.md`.
#
# `--` PATHSPEC GUARD: every arm STOPS flag interpretation at the first bare
# `--` token; anything after `--` is a pathspec, never a flag. So
# `git clean -- -f` (pathspec literally `-f`) is NOT a force flag,
# `git checkout -- -b` is NOT a branch-create, and `git add -- -A` stages a
# pathspec literally named `-A`.
#
# (GUARD-03 / AUTHZ-01 / D-06 lineage. The full both-backend command matrix
# incl. these bypass forms is re-asserted by the XR-32 enrollment canary; this
# hook is the agent-surface leg.)
#
# ════════════════════════════════════════════════════════════════════════════
# WHAT THIS HOOK DOES NOT TOUCH (decoupling — council-locked)
# ════════════════════════════════════════════════════════════════════════════
# `git reset --hard` enforcement is council-locked D-1..D-7 (2026-05-08;
# cross-repo/docs/research/2026-05-08-git-reset-hard-worktree-deny-history.md):
# the agent-runtime layer stays fail-closed and NOT intent-aware; legitimate
# worktree-base correction was relocated to the orchestrator layer, NOT by
# loosening enforcement. The AUTHZ-01 extension ADDS redirection-bypass
# coverage (the forms the bare deny-string structurally cannot see) and MUST
# NOT relax the bare `reset --hard` / `clean -f` posture.
#
# ════════════════════════════════════════════════════════════════════════════
# SUBAGENT COVERAGE (HP-003 v2)
# ════════════════════════════════════════════════════════════════════════════
# PreToolUse:Bash propagates from subagents with full agent context (verified
# 2026-04-21, CC 2.1.112+). So this guard covers BOTH parent and subagent git
# commands — precisely the autonomous-runtime threat the deny rule guards
# (#7232). No branching on agent_id; uniform enforcement.
#
# Detection (each shell-separator-delimited segment is parsed independently,
# with a running effective-cwd carried ACROSS segments for `cd` redirection):
#   1. Tokenize segment on whitespace (v1 floor: no full shell-quoting).
#   2. A bare `cd <path>` segment updates the running effective-cwd; subsequent
#      `git` segments resolve their effective dir against it (catches
#      `cd /common && git checkout -b x`).
#   3. If first token != `git`, segment is non-git — ALLOW.
#   4. Skip git global options to find the subcommand, RETAINING the ordered
#      prefix (-C path, --git-dir[=], --work-tree[=], -c k=v / -c<k=v>, ...).
#      Arg-takers consume the next token.
#   5. Dispatch on the subcommand: push / reset / clean / checkout / switch / add.
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

# Running effective-cwd, carried across segments so a bare `cd <path>` segment
# redirects subsequent `git` segments (shell-state redirection). Empty = the
# hook process cwd (let git resolve relative to its own cwd).
RUNNING_CWD=""

# is_primary <running-cwd> <global-prefix-token...> — true (return 0) when the
# EFFECTIVE post-redirection gitdir is the common gitdir (the primary). Resolve
# the effective dir by REPLAYING the retained ordered global prefix AND the
# running effective-cwd, then compare --absolute-git-dir == --git-common-dir
# (resolution shape copied from install-hooks.sh:76–82). CRITICAL anti-pattern
# (RESEARCH Pitfall 3 / the council-caught blanket-allow bug): test the
# EFFECTIVE dir, NOT the hook cwd — a redirected command from a lane that
# resolves to the common dir must report primary=true and BLOCK.
is_primary() {
  local run_cwd="$1"; shift
  local -a gp=("$@")
  local -a cdopt=()
  [[ -n "$run_cwd" ]] && cdopt=(-C "$run_cwd")
  local absdir commondir
  # Replay the running-cwd redirection (cdopt) FIRST, then the retained git
  # global prefix (gp) — git applies -C/--git-dir in order; an empty effective
  # resolution (not a repo) is treated as NOT-primary (fail-open here is safe:
  # a non-repo target cannot corrupt the shared primary).
  # Use --path-format=absolute (git ≥2.31; host is 2.54) for BOTH rev-parses so
  # neither result is relative to git's effective working dir — this sidesteps
  # the "primary returns a bare relative .git for --git-common-dir" ambiguity
  # entirely, regardless of how many -C are composed in the prefix. (Resolution
  # shape is the install-hooks.sh:76–82 --absolute-git-dir == --git-common-dir
  # test, hardened to absolute path-format.)
  absdir=$(git "${cdopt[@]}" "${gp[@]}" rev-parse --path-format=absolute --absolute-git-dir 2>/dev/null) || return 1
  commondir=$(git "${cdopt[@]}" "${gp[@]}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [[ -n "$absdir" && -n "$commondir" ]] || return 1
  local abs_real common_real
  abs_real=$(readlink -f "$absdir" 2>/dev/null || echo "$absdir")
  common_real=$(readlink -f "$commondir" 2>/dev/null || echo "$commondir")
  [[ "$abs_real" == "$common_real" ]]
}

# declares_shared_primary <running-cwd> <global-prefix-token...> — true (return 0)
# when the EFFECTIVE post-redirection repo declares itself a shared working tree in
# its `.planning/config.json`. Resolves the effective toplevel by replaying the SAME
# (cdopt, global-prefix) pair `is_primary` uses, so a redirected
# `git -C <shared> add -A` reads <shared>'s config, not the hook's cwd config.
#
# The key expression MIRRORS the four dhx skill binders byte-for-byte
# (`dhx/{discuss,disc-test}/references/discuss-finalize.md`, `dhx/review/references/
# review-workflow.md`, `dhx/test/SKILL.md`), which resolve SHARED_PRIMARY as
# `c.shared_primary || c.primary_must_stay_on_main || false`. jq's `//` treats
# `false` as empty and falls through, giving the same short-circuit as JS `||` —
# intentional parity. If the two ever diverge, the hook blocks a staging op the
# skills think is fine (or the reverse), which is worse than either behavior alone.
#
# FAIL-OPEN by design: no repo (bare gitdir, non-repo target), no
# `.planning/config.json`, unparseable JSON, or an undeclared repo all return 1 =>
# ALLOW. A repo that has not declared writer-concurrency is not this arm's concern,
# and `git add -A` cannot corrupt a tree nobody else is writing.
declares_shared_primary() {
  local run_cwd="$1"; shift
  local -a gp=("$@")
  local -a cdopt=()
  [[ -n "$run_cwd" ]] && cdopt=(-C "$run_cwd")
  local toplevel
  toplevel=$(git "${cdopt[@]}" "${gp[@]}" rev-parse --path-format=absolute --show-toplevel 2>/dev/null) || return 1
  [[ -n "$toplevel" ]] || return 1
  local cfg="$toplevel/.planning/config.json"
  [[ -f "$cfg" ]] || return 1
  jq -e '(.shared_primary // .primary_must_stay_on_main // false) == true' "$cfg" >/dev/null 2>&1
}

# is_redirected <global-prefix-token...> — the reset truth-table predicate:
# true when a gitdir redirection is present (any retained global option that
# changes the effective gitdir: -C / --git-dir / --work-tree). A running `cd`
# also counts (handled separately at the call site via RUNNING_CWD).
is_redirected() {
  local t
  for t in "$@"; do
    case "$t" in
      -C|--git-dir|--git-dir=*|--work-tree|--work-tree=*) return 0 ;;
    esac
  done
  return 1
}

# Returns:
#   0  segment allowed (no block)
#   1  segment blocked; sets BLOCK_REASON
# Reads/updates RUNNING_CWD (a bare `cd <path>` segment updates it).
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

  # ── Shell-state redirection: a bare `cd <path>` segment updates the running
  # effective-cwd so subsequent `git` segments resolve against it. The
  # separator splitter already turned `cd /x && git …` into two segments, so a
  # `cd` segment here is bare (`cd <path>` possibly with trailing tokens we
  # ignore). Resolve relative paths against the prior running cwd.
  if [[ "${tokens[$i]:-}" == "cd" ]]; then
    local target="${tokens[$((i + 1))]:-}"
    if [[ -n "$target" ]]; then
      case "$target" in
        /*) RUNNING_CWD="$target" ;;
        *)
          local base="${RUNNING_CWD:-$PWD}"
          RUNNING_CWD="$base/$target" ;;
      esac
    fi
    return 0
  fi

  # First-token must be `git` (v1 floor — bare git, no leading env/assignments)
  [[ "${tokens[$i]:-}" == "git" ]] || return 0
  i=$((i + 1))

  # ── Skip git global options to find the subcommand, RETAINING the ordered
  # prefix (codex HIGH — "skips but does not retain"). Every -C/--git-dir/
  # --work-tree/-c (incl. multiple -C) is appended in order to global_prefix so
  # the rev-parse effective-dir resolution sees exactly what git would.
  local -a global_prefix=()
  while [[ $i -lt ${#tokens[@]} ]]; do
    local t="${tokens[$i]}"
    case "$t" in
      # arg-takers (consume next token) — RETAIN both the flag and its arg
      -C|--git-dir|--work-tree|--namespace|--super-prefix)
        global_prefix+=("$t" "${tokens[$((i + 1))]:-}")
        i=$((i + 2)); continue ;;
      # -c standalone — consumes next (the k=v pair). NOT gitdir-affecting, but
      # retain it so the replay is byte-faithful.
      -c)
        global_prefix+=("$t" "${tokens[$((i + 1))]:-}")
        i=$((i + 2)); continue ;;
      # =-form globals (self-contained, single token)
      --git-dir=*|--work-tree=*|--namespace=*|--super-prefix=*|--exec-path=*)
        global_prefix+=("$t")
        i=$((i + 1)); continue ;;
      # -c with key=value bundled (e.g., -chttp.proxy=foo)
      -c?*)
        global_prefix+=("$t")
        i=$((i + 1)); continue ;;
      # no-arg globals
      -p|-P|--paginate|--no-pager|--bare|--no-replace-objects|--no-optional-locks)
        global_prefix+=("$t")
        i=$((i + 1)); continue ;;
      --literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs)
        global_prefix+=("$t")
        i=$((i + 1)); continue ;;
      --exec-path|--html-path|--man-path|--info-path|--version|--help)
        global_prefix+=("$t")
        i=$((i + 1)); continue ;;
      # First non-option token is the subcommand
      *)
        break ;;
    esac
  done

  local subcommand="${tokens[$i]:-}"
  i=$((i + 1))

  case "$subcommand" in
    push)
      # ── Walk push arguments for force-flags and +refspec (UNCHANGED) ──────
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
      ;;

    reset)
      # ── RESET one-truth-table arm (D-06 fail-closed, block-ALL-redirected) ─
      # Walk args (stop flag-interpretation at `--`) for a whole-token --hard.
      local has_hard=0 seen_ddash=0
      local j=$i
      while [[ $j -lt ${#tokens[@]} ]]; do
        local t="${tokens[$j]}"
        if [[ $seen_ddash -eq 0 && "$t" == "--" ]]; then
          seen_ddash=1; j=$((j + 1)); continue
        fi
        if [[ $seen_ddash -eq 0 && "$t" == "--hard" ]]; then
          has_hard=1
        fi
        j=$((j + 1))
      done
      [[ $has_hard -eq 1 ]] || return 0
      # The hook BLOCKS reset --hard IFF a redirection is present (-C/--git-dir/
      # --work-tree OR a running cd). The BARE form (no redirection) is left
      # ENTIRELY to the existing `Bash(git reset --hard*)` deny string — return
      # 0 to avoid double-jeopardy. Redirected (common OR lane) → BLOCK.
      if is_redirected "${global_prefix[@]}" || [[ -n "$RUNNING_CWD" ]]; then
        BLOCK_REASON="redirected 'reset --hard' (-C/--git-dir/cd redirection — blocked fail-closed; the bare form is left to the existing deny string)"
        return 1
      fi
      # Bare reset --hard — not this hook's concern (existing deny string).
      return 0
      ;;

    clean)
      # ── CLEAN arm — ALLOW-FIRST dry-run; else block force when GITDIR==COMMON
      # (stop flag-interpretation at `--` so a `clean -- -f` pathspec is NOT a
      # force flag). Mirror the --force-with-lease-before---force ALLOW-FIRST
      # discipline.
      local has_force=0 has_dryrun=0 seen_ddash=0 force_tok=""
      local j=$i
      while [[ $j -lt ${#tokens[@]} ]]; do
        local t="${tokens[$j]}"
        if [[ $seen_ddash -eq 0 && "$t" == "--" ]]; then
          seen_ddash=1; j=$((j + 1)); continue
        fi
        if [[ $seen_ddash -eq 0 ]]; then
          case "$t" in
            -n|--dry-run) has_dryrun=1 ;;
            --force) has_force=1; force_tok="$t" ;;
            -*)
              # whole-token short cluster containing 'f' (e.g. -f, -fd, -fdx,
              # -ff, -ffd). The ^-[a-zA-Z]+$ guard means --foo cannot match.
              if [[ "$t" =~ ^-[a-zA-Z]+$ && "$t" == *f* ]]; then
                has_force=1; force_tok="$t"
              fi
              ;;
          esac
        fi
        j=$((j + 1))
      done
      # ALLOW-FIRST: an explicit dry-run is non-destructive regardless.
      [[ $has_dryrun -eq 1 ]] && return 0
      [[ $has_force -eq 1 ]] || return 0
      if is_primary "$RUNNING_CWD" "${global_prefix[@]}"; then
        BLOCK_REASON="'clean $force_tok' force-cleans the common/primary gitdir (deletes untracked files tree-wide on the shared checkout)"
        return 1
      fi
      return 0
      ;;

    checkout)
      # ── CHECKOUT arm — block the off-base branch-CREATE in ALL git-2.54 forms
      # when GITDIR==COMMON. Separated -b/-B, ATTACHED -bfoo/-Bfoo, and
      # --orphan[=foo]. Plain `checkout <path>`/`checkout <branch>` is left
      # alone. Stop flag-interpretation at `--` (a `checkout -- -b` is a
      # pathspec, not a create).
      local is_create=0 create_tok="" seen_ddash=0
      local j=$i
      while [[ $j -lt ${#tokens[@]} ]]; do
        local t="${tokens[$j]}"
        if [[ $seen_ddash -eq 0 && "$t" == "--" ]]; then
          seen_ddash=1; j=$((j + 1)); continue
        fi
        if [[ $seen_ddash -eq 0 ]]; then
          case "$t" in
            -b|-B) is_create=1; create_tok="$t" ;;
            --orphan|--orphan=*) is_create=1; create_tok="$t" ;;
            # ATTACHED-argument: -bfoo / -Bfoo (a token matching ^-[bB][^-].*)
            -[bB][!-]*) is_create=1; create_tok="$t" ;;
          esac
        fi
        j=$((j + 1))
      done
      [[ $is_create -eq 1 ]] || return 0
      if is_primary "$RUNNING_CWD" "${global_prefix[@]}"; then
        BLOCK_REASON="off-base branch-create 'checkout $create_tok' in the primary (retargets the shared HEAD symref; use 'worktree add -b' for isolated lanes)"
        return 1
      fi
      return 0
      ;;

    switch)
      # ── SWITCH arm — block the create in ALL git-2.54 forms when
      # GITDIR==COMMON. Separated -c/-C/--create/--force-create, ATTACHED
      # -cfoo/-Cfoo, =value alias --create=foo/--force-create=foo, and
      # --orphan[=foo]. NOTE the `switch -C` collision: -C here is switch's
      # --force-create (the global -C <path> was already consumed/RETAINED by
      # the skipper before landing on the subcommand) — a future editor must
      # not mis-handle it as a global redirection. Stop at `--`.
      local is_create=0 create_tok="" seen_ddash=0
      local j=$i
      while [[ $j -lt ${#tokens[@]} ]]; do
        local t="${tokens[$j]}"
        if [[ $seen_ddash -eq 0 && "$t" == "--" ]]; then
          seen_ddash=1; j=$((j + 1)); continue
        fi
        if [[ $seen_ddash -eq 0 ]]; then
          case "$t" in
            -c|-C) is_create=1; create_tok="$t" ;;
            --create|--force-create) is_create=1; create_tok="$t" ;;
            --create=*|--force-create=*) is_create=1; create_tok="$t" ;;
            --orphan|--orphan=*) is_create=1; create_tok="$t" ;;
            # ATTACHED-argument: -cfoo / -Cfoo (a token matching ^-[cC][^-].*)
            -[cC][!-]*) is_create=1; create_tok="$t" ;;
          esac
        fi
        j=$((j + 1))
      done
      [[ $is_create -eq 1 ]] || return 0
      if is_primary "$RUNNING_CWD" "${global_prefix[@]}"; then
        BLOCK_REASON="off-base branch-create 'switch $create_tok' in the primary (retargets the shared HEAD symref; use 'worktree add -b' for isolated lanes)"
        return 1
      fi
      return 0
      ;;

    add)
      # ── ADD arm — block the whole-index sweep on a DECLARED shared primary ───
      # `git add -A` stages EVERY change in the tree, including files a concurrent
      # session staged but has not yet committed. On a shared working tree the index
      # is shared state, so the next `git commit` in EITHER session carries the
      # other's work. Two documented incidents on `~/repos/skills` (2026-06-04,
      # 9 files; 2026-07-07, 4 files). Disjoint file sets do NOT protect you.
      #
      # Synonyms per git-add(1): `-A`, `--all`, `--no-ignore-removal` are the same
      # flag; `--no-all` / `--ignore-removal` negate it (last-wins, as git does).
      # ALLOW-FIRST `-n`/`--dry-run` (stages nothing) mirrors the clean arm's
      # discipline. Stop flag-interpretation at `--`.
      local all_state=0 all_tok="" has_dryrun=0 seen_ddash=0
      local j=$i
      while [[ $j -lt ${#tokens[@]} ]]; do
        local t="${tokens[$j]}"
        if [[ $seen_ddash -eq 0 && "$t" == "--" ]]; then
          seen_ddash=1; j=$((j + 1)); continue
        fi
        if [[ $seen_ddash -eq 0 ]]; then
          case "$t" in
            # Negators first — they win when they appear later (git's last-wins).
            --no-all|--ignore-removal) all_state=0 ;;
            -A|--all|--no-ignore-removal) all_state=1; all_tok="$t" ;;
            -n|--dry-run) has_dryrun=1 ;;
            -*)
              # Single-dash cluster (`-Av`, `-vA`, `-nA`). The ^-[a-zA-Z]+$ guard
              # means `--all` cannot reach here. Case-SENSITIVE on purpose: `-N`
              # (intent-to-add) contains no `A`, and `-N` is not a sweep.
              if [[ "$t" =~ ^-[a-zA-Z]+$ ]]; then
                [[ "$t" == *A* ]] && { all_state=1; all_tok="$t"; }
                [[ "$t" == *n* ]] && has_dryrun=1
              fi
              ;;
          esac
        fi
        j=$((j + 1))
      done
      # ALLOW-FIRST: an explicit dry-run stages nothing regardless.
      [[ $has_dryrun -eq 1 ]] && return 0
      [[ $all_state -eq 1 ]] || return 0
      # BOTH predicates, in this order: primary-ness is cheap and rules out lanes
      # (where `add -A` is safe and common); the declaration is what separates a
      # SHARED primary from the 16 solo primaries where `add -A` is routine.
      if is_primary "$RUNNING_CWD" "${global_prefix[@]}" \
         && declares_shared_primary "$RUNNING_CWD" "${global_prefix[@]}"; then
        BLOCK_REASON="'add $all_tok' stages the WHOLE index on a declared shared primary (sweeps a concurrent session's staged-but-uncommitted work into your next commit)"
        return 1
      fi
      return 0
      ;;

    *)
      # Not a subcommand this hook gates (incl. `worktree`, which does NOT route
      # through checkout/switch — `worktree add -b lane` is the sanctioned
      # creation path and is UNAFFECTED; its first token is `worktree`, not `add`,
      # so the add arm above never sees it).
      return 0
      ;;
  esac
}

# Iterate segments
while IFS= read -r SEGMENT; do
  [[ -n "$SEGMENT" ]] || continue
  if ! inspect_segment "$SEGMENT"; then
    cat >&2 <<EOF
BLOCKED: git destructive-op guard tripped on $BLOCK_REASON

  command: $CMD
  segment: $SEGMENT

This guard closes the SYNTACTIC bypasses that prefix-anchored deny strings
structurally cannot see — force-push via +refspec / -f, and (AUTHZ-01)
redirected 'reset --hard'/'clean -f' aimed at the shared common gitdir plus
off-base 'checkout -b'/'switch -c' in the primary that retarget the shared
HEAD symref, plus a whole-index 'add -A' on a declared shared primary.

Safe alternatives:
  - force-push:        --force-with-lease (or --force-if-includes)
  - isolated branch:   git worktree add ../<dir> -b <branch>   (NOT checkout -b
                       in the primary — that moves the shared HEAD for every
                       concurrent session)
  - in-lane reset:     run a BARE 'git reset --hard' inside your own lane (the
                       redirected -C/--git-dir/cd form is what is blocked here)
  - staging:           git add -- <path> [<path>...]   (name every path; on a
                       shared tree 'add -A' also stages whatever a concurrent
                       session left in the index, and your next commit takes it)

If this command is genuinely correct, invoke git directly outside Claude's
Bash tool. This guard is an accident tripwire for the shared working tree,
not an unforgeable boundary.
EOF
    echo "BLOCKED: git destructive-op guard tripped on $BLOCK_REASON"
    exit 2
  fi
done <<<"$SPLIT"

exit 0
