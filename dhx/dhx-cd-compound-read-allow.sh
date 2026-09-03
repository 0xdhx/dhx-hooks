#!/usr/bin/env bash
# dhx-cd-compound-read-allow.sh — PreToolUse:Bash hook
# Patterns: HP-028, HP-049, HP-052, HP-060
#
# Resolves the `cd <abs>;` prefix that CC's Bash classifier refuses to simulate, so a
# read-only compound command stops raising a permission prompt under bypassPermissions.
#
# THE DEFECT (HP-060, measured on CC 2.1.259). The classifier arms a
# `deniedPathInsideDirectory` ask-circuit when ALL of: the classified command head is in
# {grep, egrep, fgrep, rg, diff, git, cp, mv}; a `cd` makes a relative path operand
# unresolvable; and any `Read()` deny rule is configured. It then returns
# `behavior:"ask"` with `classifierApprovable:false`. Bypass mode never skips deny-rule
# evaluation, so `cd /abs; grep -n foo rel/path.md` prompts the human every time — 11 and
# 9 times across two measured Explore subagent runs on 2026-09-03.
#
# WHY THIS HOOK EXISTS AND WHAT IT MUST NOT BECOME. The circuit is the secrets guard
# doing its job with incomplete information; the answer is to SUPPLY the information, not
# to remove the deny rules. So this hook re-derives what the classifier could not — it
# joins `<cd target>/<relative operand>` itself — and emits `permissionDecision:"allow"`
# ONLY when every resolved operand misses the deny set. It NEVER default-allows
# (fail-open footgun: anthropics/claude-code#28812) and has NO block arm — blocking is
# `dhx-git-destructive-guard.sh`'s job. Silence is the correct output for anything not
# provably safe; silence restores today's behavior (the prompt), which is a working
# fallback, not a failure.
#
# RELATIONSHIP TO dhx-sandbox-escape-allow.sh (2026-07-13). That hook is the shape
# precedent — same class, same never-default-allow discipline — but its decisions.md row
# states "compound commands (&&, pipes, quotes) can never be shape-allowed". This hook is
# deliberately the exception, because a compound is the ONLY shape the defect takes. The
# stance is not reversed, it is paid for: that hook refuses compounds because a
# metacharacter can smuggle a second command inside an approved prefix, so here EVERY
# segment must independently clear the read-only allowlist and EVERY token in every
# segment is resolved against the deny set. A splitter that over-splits fails SAFE (an
# extra fragment simply fails the head allowlist); the danger is a separator bash honors
# that the splitter misses, so every substitution and redirection form is refused
# outright rather than parsed. See `docs/decisions.md` 2026-09-03 row.
#
# Allowlist additions route through /dhx:hooks modify (this is a security allowlist —
# load-bearing gate logic, full engage protocol).
set -uo pipefail

INPUT=$(cat 2>/dev/null) || exit 0
[ -n "$INPUT" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$CMD" ] || exit 0

# Hot-path bail: 99% of Bash calls are not `cd <abs>`-prefixed compounds. Everything
# below this line is cold. A leading `cd /` is the cheapest possible discriminator.
case "$CMD" in
  'cd /'*) ;;
  *) exit 0 ;;
esac

# Multi-line commands are refused outright, BEFORE any splitting. Roughly half of all
# Bash tool calls are multi-line, `grep -E` anchors `^` at every LINE start rather than
# at the start of the string, and a newline is a bash separator in its own right — so a
# payload could ride on line 2 of a command whose line 1 reads as a trusted compound.
# Same hole class the sandbox-escape hook's pre-commit gate caught on 2026-07-13.
case "$CMD" in *$'\n'*) exit 0 ;; esac
case "$CMD" in *$'\r'*) exit 0 ;; esac

# --- Substitution / redirection refusal -------------------------------------------
# These are refused rather than parsed. `$(...)`, backticks and process substitution
# make the executed text runtime-determined, which is precisely the condition this hook
# claims to have resolved; `>`/`<` write or read outside the operand set; a bare `$`
# covers `$VAR` and `${VAR}` so a cd target or path operand can never expand under us.
# The cost is real and accepted: `grep '$foo' f` and `grep 'a > b' f` fall through to
# the prompt. Falling through is the status quo, not a regression.
case "$CMD" in
  *'$'*|*'`'*|*'>'*|*'<'*) exit 0 ;;
esac

# --- Segment split ------------------------------------------------------------------
# Separators bash honors that survive the refusals above: `;` `&&` `||` `|` `&`. All five
# are normalized to a sentinel so the splitter can never under-split. `|` and `&` are
# split on rather than refused so that a piped or backgrounded compound decomposes into
# segments whose heads then fail the allowlist — refusing them here would be equivalent,
# but splitting keeps the failure attributable to a named segment.
SENTINEL=$'\001'
SPLIT=${CMD//&&/$SENTINEL}
SPLIT=${SPLIT//\|\|/$SENTINEL}
SPLIT=${SPLIT//;/$SENTINEL}
SPLIT=${SPLIT//|/$SENTINEL}
SPLIT=${SPLIT//&/$SENTINEL}

IFS="$SENTINEL" read -r -d '' -a SEGMENTS < <(printf '%s\0' "$SPLIT") || true
[ "${#SEGMENTS[@]}" -ge 2 ] || exit 0

# --- Helpers -------------------------------------------------------------------------

# Lexical absolute-path normalization. Deliberately NOT realpath: realpath fails on a
# non-existent path (a grep operand that does not exist is not an error for this hook)
# and follows symlinks, which would let a symlinked name resolve away from a deny match.
norm_path() {
  local p="$1" seg s=""
  local -a parts=() out=()
  IFS='/' read -r -a parts <<< "$p"
  for seg in "${parts[@]}"; do
    case "$seg" in
      ''|'.') continue ;;
      '..') [ "${#out[@]}" -gt 0 ] && unset 'out[$(( ${#out[@]} - 1 ))]' ;;
      *) out+=("$seg") ;;
    esac
  done
  for seg in ${out[@]+"${out[@]}"}; do s="$s/$seg"; done
  printf '%s' "${s:-/}"
}

# Strip one layer of surrounding quotes, then yield both the whole token and the part
# after a final `=` (so `--file=.env` is evaluated as `.env`, not just as a flag).
strip_quotes() {
  local t="$1"
  case "$t" in
    \"*\") t=${t#\"}; t=${t%\"} ;;
    \'*\') t=${t#\'}; t=${t%\'} ;;
  esac
  printf '%s' "$t"
}

# --- Deny set ------------------------------------------------------------------------
# Read live at run time from the ACTIVE settings file — this machine uses CCS, so
# ~/.claude/settings.json may be inactive and must be resolved through CLAUDE_CONFIG_DIR.
# An unreadable settings file means the deny set is unknown, which means no allow.
SETTINGS=$(readlink -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" 2>/dev/null) || exit 0
[ -n "$SETTINGS" ] && [ -r "$SETTINGS" ] || exit 0

DENY_PATTERNS=$(jq -r '
  (.permissions.deny // [])
  | map(select(type == "string"))
  | map(select(startswith("Read(") and endswith(")")))
  | map(.[5:-1])
  | .[]
' "$SETTINGS" 2>/dev/null) || exit 0

# The hardcoded floor is applied ALWAYS, not merely as a fallback when the read fails.
# A settings rewrite that drops a Read deny rule (the rewriter threat this repo exists to
# monitor — docs/architecture.md § The rewriter threat) must never silently widen what
# this hook is willing to auto-approve.
DENY_PATTERNS="$DENY_PATTERNS
./.env*
.env
.env.*
.secrets
~/.aws/**
~/.ssh/**"

# Project-scoped deny rules, if the cd target carries them. Cheap, and it keeps a repo's
# own secrets guard authoritative over a hook that would otherwise only see user scope.
read_project_denies() {
  local dir="$1" f extra
  for f in "$dir/.claude/settings.json" "$dir/.claude/settings.local.json"; do
    [ -r "$f" ] || continue
    extra=$(jq -r '
      (.permissions.deny // [])
      | map(select(type == "string"))
      | map(select(startswith("Read(") and endswith(")")))
      | map(.[5:-1])
      | .[]
    ' "$f" 2>/dev/null) || continue
    [ -n "$extra" ] && printf '%s\n' "$extra"
  done
}

# Conservative superset of CC's own deny matcher. Reimplementing that matcher exactly is
# a losing game, so this errs toward REFUSING: a pattern with no `/` is treated as a
# basename glob matched anywhere in the tree; a pattern with a `/` is treated as a path
# fragment matched anywhere. Both are strictly wider than CC's directory-anchored form,
# and wider means fewer allows — the safe direction for an allow-arm hook.
path_is_denied() {
  local resolved="$1" base pat p anchored
  base=${resolved##*/}
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    p=$pat
    p=${p#./}
    anchored=""
    case "$p" in
      '~/'*) anchored="$HOME/"; p=${p#\~/} ;;
    esac
    # Trailing `**` / `*` means "and everything under it" — bash globs do not cross `/`
    # without globstar, so the subtree test is done with an explicit prefix compare
    # rather than by letting `case` glob it.
    p=${p%/\*\*}
    p=${p%/\*}
    if [ -n "$anchored" ]; then
      [ "$resolved" = "$anchored$p" ] && return 0
      case "$resolved" in "$anchored$p"/*) return 0 ;; esac
      continue
    fi
    case "$p" in
      */*) case "$resolved" in */"$p"/*|*/"$p") return 0 ;; esac ;;
      *)   # Basename glob, matched anywhere in the tree — deliberately wider than CC's
           # directory-anchored form. `$p` is intentionally unquoted so `*` still globs.
           # shellcheck disable=SC2254
           case "$base" in $p) return 0 ;; esac ;;
    esac
  done <<< "$DENY_PATTERNS"
  return 1
}

# --- Segment 1 must be exactly `cd <existing absolute dir>` ---------------------------
read -r -a CD_TOKENS <<< "${SEGMENTS[0]}"
[ "${#CD_TOKENS[@]}" -eq 2 ] || exit 0
[ "${CD_TOKENS[0]}" = "cd" ] || exit 0
CD_TARGET=$(strip_quotes "${CD_TOKENS[1]}")
case "$CD_TARGET" in /*) ;; *) exit 0 ;; esac
CD_TARGET=$(norm_path "$CD_TARGET")
[ -d "$CD_TARGET" ] || exit 0

PROJECT_DENIES=$(read_project_denies "$CD_TARGET")
[ -n "$PROJECT_DENIES" ] && DENY_PATTERNS="$DENY_PATTERNS
$PROJECT_DENIES"

# --- Read-only allowlist --------------------------------------------------------------
# Sized against the measured circuit, not against imagination. The heads that can ACTUALLY
# arm the ask-circuit are {grep, egrep, fgrep, rg, diff, git} — `cp` and `mv` are in CC's
# same set but WRITE, so they are deliberately absent here and must stay absent. The
# remaining companions earn their place for a different reason: every segment must clear
# the allowlist, so an unlisted `ls` or `wc` in an otherwise-safe compound would poison
# the allow for the `grep` that needed it. They are not here on their own merit.
#
# Deliberately absent, permanently: cp, mv, tee, dd, install (write); python/python3,
# node, perl, ruby, sh, bash, eval, source, xargs, env, sudo (opaque or execute).
is_allowed_head() {
  case "$1" in
    grep|egrep|fgrep|rg|diff) return 0 ;;
    cat|head|tail|wc|ls|sort|uniq|cut|nl|tr|stat|file|column) return 0 ;;
    basename|dirname|realpath|readlink|echo|printf|true|false|pwd|date) return 0 ;;
    git|sed|awk|find) return 0 ;;  # gated further below
    *) return 1 ;;
  esac
}

# Read-only git subcommands only. `branch` (-D), `tag` (-d) and `config` (--unset) are
# excluded because each carries a destructive flag; the destructive verbs (push, add,
# clean, checkout, switch, commit, reset) are `dhx-git-destructive-guard.sh`'s surface and
# must never appear here — that disjointness is asserted by this hook's probe.
git_subcommand_ok() {
  case "$1" in
    log|show|diff|status|rev-parse|grep|ls-files|ls-tree|blame|describe|shortlog|cat-file|show-ref|rev-list) return 0 ;;
    *) return 1 ;;
  esac
}

# The heads that can actually arm the ask-circuit this hook exists to answer (HP-060).
# At least one segment must carry one, or the hook stays silent: a compound with no
# arming head was never going to prompt, so an allow there would buy nothing while
# silently suppressing any OTHER ask-circuit that might apply to it. `cp`/`mv` are in
# CC's arming set but write, so they are excluded here and by the allowlist both.
is_arming_head() {
  case "$1" in
    grep|egrep|fgrep|rg|diff|git) return 0 ;;
    *) return 1 ;;
  esac
}

# --- Validate every remaining segment --------------------------------------------------
SAW_ARMING_HEAD=0
i=0
for seg in "${SEGMENTS[@]}"; do
  i=$((i + 1))
  [ "$i" -eq 1 ] && continue

  # An empty segment means a dangling separator — malformed, so refuse rather than guess.
  case "$seg" in
    *[![:space:]]*) ;;
    *) exit 0 ;;
  esac

  read -r -a TOKENS <<< "$seg"
  [ "${#TOKENS[@]}" -ge 1 ] || exit 0

  HEAD=$(strip_quotes "${TOKENS[0]}")
  # A path-qualified head (`/usr/bin/grep`) is accepted on its basename; anything else
  # containing a slash is not a bare command and is refused.
  case "$HEAD" in
    /*|*/*) HEAD=${HEAD##*/} ;;
  esac
  is_allowed_head "$HEAD" || exit 0
  is_arming_head "$HEAD" && SAW_ARMING_HEAD=1

  # A second `cd` anywhere would move the base this hook resolved against — refuse.
  # (Unreachable while `cd` is off the allowlist; kept so removing it from one place
  # cannot silently re-open the re-rooting hole.)
  [ "$HEAD" = "cd" ] && exit 0

  case "$HEAD" in
    git)
      [ "${#TOKENS[@]}" -ge 2 ] || exit 0
      SUB=$(strip_quotes "${TOKENS[1]}")
      # A leading `-C`/`-c` would re-root or reconfigure the repo under us.
      case "$SUB" in -*) exit 0 ;; esac
      git_subcommand_ok "$SUB" || exit 0
      ;;
    sed)
      # `-n` required (suppress auto-print => reading), `-i` refused (in-place write),
      # and a `w` command in the script can write a file regardless of `-n`.
      sed_has_n=0
      for t in "${TOKENS[@]}"; do
        [ "$t" = "-n" ] && sed_has_n=1
      done
      [ "$sed_has_n" -eq 1 ] || exit 0
      for t in "${TOKENS[@]}"; do
        case "$t" in -*i*) exit 0 ;; esac
        case "$t" in *w*) case "$t" in -*) ;; *) exit 0 ;; esac ;; esac
      done
      ;;
    awk)
      # Redirection is already refused globally; `system()` is the remaining escape.
      for t in "${TOKENS[@]}"; do
        case "$t" in *system*) exit 0 ;; esac
      done
      ;;
    find)
      for t in "${TOKENS[@]}"; do
        case "$t" in
          -delete|-exec|-execdir|-ok|-okdir|-fls|-fprint|-fprintf) exit 0 ;;
        esac
      done
      ;;
  esac

  # Every token — not merely the ones that look like operands — is resolved and checked.
  # A flag can carry a path (`grep -f .env`, `--file=.env`), and a token that is not a
  # path at all simply fails to match the deny set, so checking everything costs nothing
  # and closes the "I did not think that was an operand" hole.
  for t in "${TOKENS[@]}"; do
    for cand in "$(strip_quotes "$t")" "$(strip_quotes "${t##*=}")"; do
      [ -n "$cand" ] || continue
      case "$cand" in
        /*)  resolved=$(norm_path "$cand") ;;
        '~'/*) resolved=$(norm_path "$HOME/${cand#\~/}") ;;
        -*)  resolved="" ;;
        *)   resolved=$(norm_path "$CD_TARGET/$cand") ;;
      esac
      [ -n "$resolved" ] || continue
      path_is_denied "$resolved" && exit 0
    done
  done
done

[ "$SAW_ARMING_HEAD" -eq 1 ] || exit 0

# --- Allow ----------------------------------------------------------------------------
jq -n --arg d "$CD_TARGET" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    permissionDecisionReason: ("dhx-cd-compound-read-allow: read-only compound under " + $d + ", no deny-set path")
  }
}'
exit 0
