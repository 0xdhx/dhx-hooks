#!/usr/bin/env bash
# dhx-cd-compound-read-allow.sh — PreToolUse:Bash hook (input rewriter)
# Patterns: HP-028, HP-041, HP-049, HP-052, HP-060, HP-061
#
# Rewrites `cd <abs>; grep … <relative path>` so the relative operands become ABSOLUTE,
# which removes the precondition of the classifier ask-circuit that otherwise raises a
# permission prompt on every such command under `defaultMode: bypassPermissions`.
#
# THE DEFECT (HP-060, CC 2.1.259). The Bash classifier does not simulate `cd`, so a
# relative operand is unresolvable. With any `Read()` deny rule configured it cannot rule
# out a match and returns `behavior:"ask"` with `classifierApprovable:false`. Measured
# 2026-09-03: 11 and 9 prompts across two Explore subagent runs on two models.
#
# WHY A REWRITE AND NOT A DECISION (HP-061). This hook originally emitted a bare
# `permissionDecision:"allow"`. That does not work and cannot: CC's combiner `Ifo` runs
# hooks FIRST and then re-consults the rule engine — only a hook `deny` short-circuits, and
# a hook `allow` is discarded by any rule deny and by any ask, including the very
# `safetyCheck` ask this hook targets. But `Ifo` adjudicates `updatedInput ?? input`, so
# rewriting the command is the one lever a hook actually has.
#
# THIS IS A SECURITY IMPROVEMENT, NOT A BYPASS — the point worth understanding before
# touching anything below. The classifier's *deny* branch selects with
# `xe = (Pe) => !fs(Pe) && (!d || isAbsolute(Pe) || Pe.startsWith("~"))`, which EXCLUDES
# exactly the unresolvable operands its ask-circuit catches. So today `cd /abs; grep x .env`
# reaches ask, never deny. Once the operand is absolute the deny branch can see it, and the
# same command becomes a real DENY enforced by CC's own engine. This hook does not take over
# the secrets guard; it hands the guard back the information it was missing.
#
# THE RISK THIS ACCEPTS, STATED PLAINLY. A hook that mutates commands can silently change
# what one does, which is strictly worse than the prompt it removes. The whole defence is
# refusing to rewrite anything whose grammar is not fully understood:
#   * grep family ONLY (`grep`/`egrep`/`fgrep`/`rg`) is REWRITTEN — the entire measured
#     defect. `diff`, `cp`, `mv` also arm the circuit and are refused outright (different
#     grammars; cp/mv write). `git` is tolerated only with NO positional operand, since a
#     relative pathspec would arm the circuit and git's pathspec grammar is not implemented.
#   * the PATTERN operand is never rewritten. `cd /repo; grep -rn docs src/` is the shape
#     that punishes a naive rewriter — `docs` is also a real directory, and prefixing it
#     would silently change what is being searched FOR.
#   * `-e` / `-f` / `--regexp` / `--file` are refused outright, so the pattern is always the
#     first non-option word and the grammar stays decidable.
#   * options that consume one argument are handled EXPLICITLY, not refused: `-A 60`, `-C 2`,
#     `-t md`, `-g '*.md'`, `--context 3` consume their argument as an option-argument, never
#     as a path. Attached forms (`-A5`, `--context=3`) are positionally inert. Only a BUNDLE
#     carrying such a letter (`-nA`) and an UNKNOWN long option are refused — in both the
#     argument position is genuinely undecidable, and guessing shifts every operand after it.
#   * every rewritten operand must already EXIST under the cd target. A path that does not
#     resolve is not silently prefixed.
#   * if ANY path operand cannot be rewritten, the whole command is refused — a partial
#     rewrite would leave the ask armed and the allow useless.
# Refusal is always safe: it restores today's behaviour, which is a working prompt.
#
# Shape/allowlist additions route through /dhx:hooks modify (security allowlist + a command
# mutator — load-bearing gate logic). See `docs/decisions.md` 2026-09-03 row.
set -uo pipefail

INPUT=$(cat 2>/dev/null) || exit 0
[ -n "$INPUT" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$CMD" ] || exit 0

# Hot-path bail: almost no Bash call is a `cd <abs>`-prefixed compound. Everything past
# this line is cold, so the cost on the common path is one jq plus one pattern match.
case "$CMD" in 'cd /'*|'cd ~/'*) ;; *) exit 0 ;; esac

# --- Decision breadcrumb ---------------------------------------------------------------
# Installed AFTER the hot-path bail, so only cd-compound commands ever write. A hook that
# silently declines gives the operator no way to tell "refused by design" from "never ran" —
# which is exactly the question that could not be answered when this hook's coverage gaps
# were reported from the field on 2026-09-03. A coarse DHX_STAGE marker names the phase
# that refused, so a refusal is diagnosable without re-deriving it by bisection. (A line
# number was tried first and is NOT available: inside an EXIT trap `${BASH_LINENO[0]}`
# reports the trap's own invocation context — always 1 — not the exit site.)
# DHX_CD_ALLOW_LOG redirects the file (probes point it at mktemp; D-20 convention).
DHX_LOG=${DHX_CD_ALLOW_LOG-$HOME/.cache/dhx/cd-compound-read-allow.log}
DHX_EMITTED=0
_dhx_breadcrumb() {
  local rc=$?
  [ -n "$DHX_LOG" ] || return 0
  mkdir -p "$(dirname "$DHX_LOG")" 2>/dev/null || return 0
  # Cheap unbounded-growth guard: hooks.log's failure mode, avoided (docs/hook-dev-guide.md
  # § Known Gotchas 2). Truncate rather than rotate — this is a breadcrumb, not an audit log.
  if [ -f "$DHX_LOG" ] && [ "$(stat -c%s "$DHX_LOG" 2>/dev/null || echo 0)" -gt 262144 ]; then
    : > "$DHX_LOG" 2>/dev/null || true
  fi
  # ONE line per invocation. The command is flattened and capped before it is written:
  # a raw multi-line command sprawls across the log and makes it unparseable — measured
  # 2026-09-03, 254 entries occupying 3102 lines, because heredoc bodies were written
  # verbatim. Field separators inside the command are escaped for the same reason.
  local flat=${CMD//$'\n'/\\n}
  flat=${flat//$'\r'/\\r}
  flat=${flat//$'\t'/\\t}
  [ "${#flat}" -gt 400 ] && flat="${flat:0:400}..."
  printf '%s\t%s\tstage=%s\trc=%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$([ "$DHX_EMITTED" -eq 1 ] && echo REWROTE || echo refused)" \
    "${DHX_STAGE:-init}" "$rc" "$flat" >> "$DHX_LOG" 2>/dev/null || true
}
trap _dhx_breadcrumb EXIT
DHX_STAGE=prefilter

# Multi-line is refused before any parsing: a newline is a bash separator in its own right,
# and roughly half of all Bash tool calls are multi-line. (The sandbox-escape hook's
# pre-commit gate caught the line-2-smuggle hole on 2026-07-13; same class.)
case "$CMD" in *$'\n'*|*$'\r'*) exit 0 ;; esac

# Substitution and redirection are refused rather than parsed. `$(…)`, backticks and a bare
# `$` make the executed text runtime-determined — precisely the property this hook claims to
# have established — and `>`/`<` move data outside the operand set.
case "$CMD" in *'$'*|*'`'*|*'>'*|*'<'*) exit 0 ;; esac

# --- Quote-aware segment scanner ------------------------------------------------------
# The command must be REASSEMBLED after rewriting, so separators have to survive scanning
# with their identity intact — the reason a normalize-to-one-sentinel splitter cannot be
# used here. Quote tracking is mandatory rather than defensive: `grep "a;b" f` carries a
# separator inside an operand, and splitting on it would corrupt the pattern.
# A single `|` IS split on: with quote tracking an unquoted `|` is always a pipe, and
# `grep … | head -20` is the dominant real shape — refusing pipes cost more coverage than
# any other rule this hook had. Bare `&` (background / &-lists) stays refused.
SEG_TEXT=(); SEG_SEP=()
scan_segments() {
  local s="$1" n=${#1} i=0 c q="" cur=""
  SEG_TEXT=(); SEG_SEP=()
  while [ "$i" -lt "$n" ]; do
    c=${s:$i:1}
    if [ -n "$q" ]; then
      cur+=$c; [ "$c" = "$q" ] && q=""
      i=$((i + 1)); continue
    fi
    case "$c" in
      "'"|'"') q=$c; cur+=$c; i=$((i + 1)); continue ;;
      '\')     cur+=$c; i=$((i + 1))
               if [ "$i" -lt "$n" ]; then cur+=${s:$i:1}; i=$((i + 1)); fi
               continue ;;
      ';')     SEG_TEXT+=("$cur"); SEG_SEP+=(";"); cur=""; i=$((i + 1)); continue ;;
      '&')     [ "${s:$i:2}" = "&&" ] || return 1
               SEG_TEXT+=("$cur"); SEG_SEP+=("&&"); cur=""; i=$((i + 2)); continue ;;
      '|')     if [ "${s:$i:2}" = "||" ]; then
                 SEG_TEXT+=("$cur"); SEG_SEP+=("||"); cur=""; i=$((i + 2))
               else
                 # A single `|` is a pipe. Splitting on it is exactly as safe as splitting
                 # on `;` now that the scanner tracks quotes — an unquoted `|` is always a
                 # pipe, and a `|` inside a grep pattern (`-E 'a|b'`, `"a\|b"`) is quoted
                 # and never reaches here. Refusing pipes cost more coverage than any other
                 # single rule: `grep … | head -20` is the dominant real shape.
                 SEG_TEXT+=("$cur"); SEG_SEP+=("|"); cur=""; i=$((i + 1))
               fi
               continue ;;
    esac
    cur+=$c; i=$((i + 1))
  done
  [ -n "$q" ] && return 1            # unterminated quote — do not guess
  SEG_TEXT+=("$cur"); SEG_SEP+=("")
  return 0
}

# Quote-aware word split that PRESERVES each word's raw text, quotes included, so an
# untouched word can be re-emitted byte-identical.
WORDS=()
split_words() {
  local s="$1" n=${#1} i=0 c q="" cur=""
  WORDS=()
  while [ "$i" -lt "$n" ]; do
    c=${s:$i:1}
    if [ -n "$q" ]; then
      cur+=$c; [ "$c" = "$q" ] && q=""
      i=$((i + 1)); continue
    fi
    case "$c" in
      "'"|'"')   q=$c; cur+=$c; i=$((i + 1)); continue ;;
      ' '|$'\t') [ -n "$cur" ] && { WORDS+=("$cur"); cur=""; }
                 i=$((i + 1)); continue ;;
    esac
    cur+=$c; i=$((i + 1))
  done
  [ -n "$cur" ] && WORDS+=("$cur")
  return 0
}

trim() { local s="$1"; s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}; printf '%s' "$s"; }

strip_quotes() {
  local t="$1"
  case "$t" in
    \"*\") t=${t#\"}; t=${t%\"} ;;
    \'*\') t=${t#\'}; t=${t%\'} ;;
  esac
  printf '%s' "$t"
}

# Lexical normalization, deliberately not realpath: realpath fails on a non-existent path
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

# --- Deny set -------------------------------------------------------------------------
# Read live from the ACTIVE settings file (CCS: resolve through CLAUDE_CONFIG_DIR, since
# ~/.claude/settings.json may be inactive). Unknown deny set => no rewrite.
#
# Note what this is FOR now that the mechanism is a rewrite: CC's own engine does the real
# enforcement on the rewritten command. This check exists so the hook never TOUCHES a
# deny-adjacent command at all — a bug in the rewriter can then never land on a secrets
# path. Refusing leaves such a command at today's ask, which is the status quo.
DHX_STAGE=deny-set
SETTINGS=$(readlink -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" 2>/dev/null) || exit 0
[ -n "$SETTINGS" ] && [ -r "$SETTINGS" ] || exit 0

read_denies() {
  jq -r '(.permissions.deny // [])
         | map(select(type == "string"))
         | map(select(startswith("Read(") and endswith(")")))
         | map(.[5:-1]) | .[]' "$1" 2>/dev/null
}

DENY_PATTERNS=$(read_denies "$SETTINGS") || exit 0

# The floor is applied ALWAYS, not merely as a fallback. This repo exists in part to monitor
# a rewriter that strips settings entries (docs/architecture.md § The rewriter threat); a
# dropped Read() rule must never silently widen what this hook is willing to touch.
DENY_PATTERNS="$DENY_PATTERNS
./.env*
.env
.env.*
.secrets
~/.aws/**
~/.ssh/**"

path_is_denied() {
  local resolved="$1" base pat p anchored
  base=${resolved##*/}
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    p=$pat; p=${p#./}; anchored=""
    case "$p" in '~/'*) anchored="$HOME/"; p=${p#\~/} ;; esac
    # A trailing `**`/`*` means "and everything under it"; bash globs do not cross `/`
    # without globstar, so the subtree test is an explicit prefix compare.
    p=${p%/\*\*}; p=${p%/\*}
    if [ -n "$anchored" ]; then
      [ "$resolved" = "$anchored$p" ] && return 0
      case "$resolved" in "$anchored$p"/*) return 0 ;; esac
      continue
    fi
    case "$p" in
      */*) case "$resolved" in */"$p"/*|*/"$p") return 0 ;; esac ;;
        *) # Basename glob matched anywhere in the tree — deliberately wider than CC's
           # directory-anchored form. `$p` is unquoted so `*` still globs.
           # shellcheck disable=SC2254
           case "$base" in $p) return 0 ;; esac ;;
    esac
  done <<< "$DENY_PATTERNS"
  return 1
}

# --- Scan --------------------------------------------------------------------------------
DHX_STAGE=scan
scan_segments "$CMD" || exit 0
[ "${#SEG_TEXT[@]}" -ge 2 ] || exit 0

# --- Segment 1 must be exactly `cd <existing absolute dir>` -------------------------------
DHX_STAGE=cd-target
split_words "$(trim "${SEG_TEXT[0]}")"
[ "${#WORDS[@]}" -eq 2 ] || exit 0
[ "${WORDS[0]}" = "cd" ] || exit 0
CD_RAW=$(strip_quotes "${WORDS[1]}")
case "$CD_RAW" in
  /*)    CD_TARGET=$CD_RAW ;;
  '~/'*) CD_TARGET="$HOME/${CD_RAW#\~/}" ;;   # `cd ~/repos/x` is how agents actually write it
  *)     exit 0 ;;
esac
CD_TARGET=$(norm_path "$CD_TARGET")
[ -d "$CD_TARGET" ] || exit 0

PROJECT_DENIES=""
for f in "$CD_TARGET/.claude/settings.json" "$CD_TARGET/.claude/settings.local.json"; do
  [ -r "$f" ] || continue
  extra=$(read_denies "$f") || continue
  [ -n "$extra" ] && PROJECT_DENIES="$PROJECT_DENIES
$extra"
done
[ -n "$PROJECT_DENIES" ] && DENY_PATTERNS="$DENY_PATTERNS$PROJECT_DENIES"

# --- Command classification ---------------------------------------------------------------
# The grep family is what this hook rewrites. `diff`/`git`/`cp`/`mv` also arm the circuit
# (HP-060) but are refused — different operand grammars, and cp/mv write.
is_grep_family() { case "$1" in grep|egrep|fgrep|rg) return 0 ;; *) return 1 ;; esac; }
is_other_arming() { case "$1" in diff|git|cp|mv) return 0 ;; *) return 1 ;; esac; }

# A git segment is acceptable only if its subcommand is read-only AND it has no positional
# operand. A positional would be a pathspec (or a revision), and a relative pathspec is
# exactly what arms the circuit — so allowing one would leave the ask in place and make the
# rewrite inert. Refusing keeps the failure honest.
git_ok() {
  local sub w
  [ "$#" -ge 2 ] || return 1
  sub=$(strip_quotes "$2")
  case "$sub" in -*) return 1 ;; esac
  case "$sub" in
    log|show|status|diff|rev-parse|ls-files|ls-tree|blame|describe|shortlog|cat-file|show-ref|rev-list) ;;
    *) return 1 ;;
  esac
  shift 2
  for w in "$@"; do
    case "$w" in -*) ;; *) return 1 ;; esac
  done
  return 0
}

# Companions. They are never rewritten; they are tolerated only so a mixed compound
# containing a real grep is still fixable — every one of these appears alongside grep in
# real commands (`| head -20`, `; echo '=== …'`, `; sed -n '1,80p' f`, `; ls dir`).
# Deliberately absent: cp, mv, tee, dd, install (write); python/node/perl/ruby/sh/bash/
# eval/source/xargs/env/sudo (opaque or execute); diff (arms the circuit). `git` is present
# but unreachable except through git_ok(), which is checked before this function.
is_allowed_companion() {
  case "$1" in
    cat|head|tail|wc|ls|sort|uniq|cut|nl|tr|stat|file|column) return 0 ;;
    basename|dirname|realpath|readlink|echo|printf|true|false|pwd|date) return 0 ;;
    sed|awk|find) return 0 ;;   # gated further below
    git) return 0 ;;            # reachable only after git_ok() has already vetted it
    *) return 1 ;;
  esac
}

# Long grep/rg options known to take NO argument. Anything else long is refused rather than
# guessed at, because guessing wrong shifts every operand position after it.
# Long options that consume exactly ONE following word. Their argument is a count, a
# glob, a type or a colour keyword — never a path this hook should rewrite — so consuming
# it verbatim is faithful. Anything long that is on NEITHER list is refused, because
# guessing whether it eats the next word shifts every operand position after it.
is_known_arg_long() {
  case "$1" in
    --after-context|--before-context|--context|--max-count|--max-columns|--threads) return 0 ;;
    --include|--exclude|--exclude-dir|--exclude-from|--glob|--iglob|--type|--type-not) return 0 ;;
    --color|--colour|--binary-files|--devices|--directories|--label|--sort|--sortr) return 0 ;;
    *) return 1 ;;
  esac
}

is_known_noarg_long() {
  case "$1" in
    --line-number|--ignore-case|--no-ignore-case|--recursive|--dereference-recursive) return 0 ;;
    --word-regexp|--line-regexp|--extended-regexp|--fixed-strings|--basic-regexp|--perl-regexp) return 0 ;;
    --invert-match|--count|--files-with-matches|--files-without-match|--only-matching) return 0 ;;
    --no-filename|--with-filename|--quiet|--silent|--no-messages|--text|--byte-offset) return 0 ;;
    --null|--null-data|--initial-tab|--line-buffered|--hidden|--no-hidden|--follow) return 0 ;;
    --no-heading|--heading|--column|--vimgrep|--json|--smart-case|--case-sensitive) return 0 ;;
    --fixed-strings|--multiline|--no-config|--one-file-system|--sort-files) return 0 ;;
    *) return 1 ;;
  esac
}

REWROTE=0

# Rewrite one grep-family segment's path operands to absolute. Sets SEG_OUT.
# Returns non-zero to refuse the entire command.
SEG_OUT=""
rewrite_grep_segment() {
  local seg="$1"
  split_words "$seg" || return 1
  local n=${#WORDS[@]} i=1 w bare abs
  local seen_pattern=0 endopts=0 n_paths=0
  local -a out=("${WORDS[0]}")

  while [ "$i" -lt "$n" ]; do
    w=${WORDS[$i]}
    if [ "$endopts" -eq 0 ]; then
      case "$w" in
        '--') endopts=1; out+=("$w"); i=$((i + 1)); continue ;;
        # `-e`/`-f` and their long forms supply the PATTERN, which would make the first
        # positional a path instead of the pattern. Refused so the grammar stays decidable.
        -e|-f|--regexp|--regexp=*|--file|--file=*) return 1 ;;
        --*=*) out+=("$w"); i=$((i + 1)); continue ;;   # attached value: positionally inert
        --*)
          if is_known_noarg_long "$w"; then out+=("$w"); i=$((i + 1)); continue; fi
          if is_known_arg_long "$w"; then
            [ $((i + 1)) -lt "$n" ] || return 1
            out+=("$w" "${WORDS[$((i + 1))]}"); i=$((i + 2)); continue
          fi
          return 1 ;;                           # unknown long option: position undecidable
        '-') return 1 ;;                        # bare `-` stdin operand: nothing to fix
        # A lone short option that takes one argument (`-A 60`, `-C 2`, `-t md`, `-g '*.md'`).
        # The argument is consumed as an option-argument and never treated as a path — which
        # is what makes `grep -n "x" -A 60 file.py` rewritable instead of refused. Context
        # flags are mainstream grep usage; blanket-refusing them cost most of this hook's
        # real-world coverage.
        -[ABCmdgtjM])
          [ $((i + 1)) -lt "$n" ] || return 1
          out+=("$w" "${WORDS[$((i + 1))]}"); i=$((i + 2)); continue ;;
        -[ABCmM][0-9]*) out+=("$w"); i=$((i + 1)); continue ;;   # attached value: inert
        -*)
          # Any remaining bundle carrying an argument-consuming letter is still refused:
          # in a bundle the letter's argument position is genuinely ambiguous.
          case "$w" in *[efABCmdgtjM]*) return 1 ;; esac
          out+=("$w"); i=$((i + 1)); continue ;;
      esac
    fi

    # First non-option word is the PATTERN. Never rewritten: prefixing it would change what
    # is searched for, not where. This is the whole reason `-e`/`-f` are refused above —
    # with them the pattern could come from an option and every positional would be a path.
    if [ "$seen_pattern" -eq 0 ]; then
      seen_pattern=1; out+=("$w"); i=$((i + 1)); continue
    fi

    # Path operand.
    bare=$(strip_quotes "$w")
    n_paths=$((n_paths + 1))
    case "$bare" in
      /*|'~'/*) out+=("$w"); i=$((i + 1)); continue ;;   # already resolvable by the classifier
    esac
    abs=$(norm_path "$CD_TARGET/$bare")
    # Only rewrite to a path that actually exists and needs no quoting. Anything else is a
    # refusal, never a guess.
    [ -e "$abs" ] || return 1
    case "$abs" in *[!A-Za-z0-9_./+@:,-]*) return 1 ;; esac
    path_is_denied "$abs" && return 1
    out+=("$abs"); REWROTE=1
    i=$((i + 1))
  done

  [ "$seen_pattern" -eq 1 ] || return 1
  # A grep with no path operand reads stdin (`… | grep -n foo`). That cannot arm the circuit
  # and needs no rewrite, so it is accepted here; the command-level REWROTE check below is
  # what still refuses a whole command in which nothing was actually fixed.
  SEG_OUT="${out[*]}"
  return 0
}

# --- Walk the segments -------------------------------------------------------------------
SAW_GREP=0
NEW=""
i=0
for seg in "${SEG_TEXT[@]}"; do
  t=$(trim "$seg")
  if [ "$i" -eq 0 ]; then
    NEW="$t"
    i=$((i + 1)); continue
  fi

  [ -n "$t" ] || exit 0                  # empty interior segment: malformed, do not guess

  split_words "$t"
  [ "${#WORDS[@]}" -ge 1 ] || exit 0
  head=$(strip_quotes "${WORDS[0]}")
  case "$head" in /*|*/*) head=${head##*/} ;; esac
  DHX_STAGE="segment:$head"

  # `git` arms the circuit (HP-060) but its pathspec grammar is not implemented. A git
  # segment is tolerated ONLY when it carries no positional operand at all — `git log
  # --oneline -5`, `git status --porcelain` — because with no path operand there is nothing
  # for the circuit to catch. `git ls-files -- tests/x` refuses the whole command.
  if [ "$head" = "git" ]; then
    git_ok "${WORDS[@]}" || exit 0
  else
    is_other_arming "$head" && exit 0    # diff/cp/mv: grammar differs, or it writes
  fi
  [ "$head" = "cd" ] && exit 0           # a second cd would move the base we resolved against

  if is_grep_family "$head"; then
    DHX_STAGE="grep-grammar:$head"
    rewrite_grep_segment "$t" || exit 0
    SAW_GREP=1
    NEW="$NEW ${SEG_SEP[$((i - 1))]} $SEG_OUT"
  else
    is_allowed_companion "$head" || exit 0
    case "$head" in
      sed)
        sed_has_n=0
        for w in "${WORDS[@]}"; do [ "$w" = "-n" ] && sed_has_n=1; done
        [ "$sed_has_n" -eq 1 ] || exit 0
        for w in "${WORDS[@]}"; do
          case "$w" in -*i*) exit 0 ;; esac
          case "$w" in *w*) case "$w" in -*) ;; *) exit 0 ;; esac ;; esac
        done ;;
      awk)  for w in "${WORDS[@]}"; do case "$w" in *system*) exit 0 ;; esac; done ;;
      find) for w in "${WORDS[@]}"; do
              case "$w" in -delete|-exec|-execdir|-ok|-okdir|-fls|-fprint|-fprintf) exit 0 ;; esac
            done ;;
    esac
    # Companions are re-emitted byte-identical: never rewritten, never normalized.
    NEW="$NEW ${SEG_SEP[$((i - 1))]} $t"
  fi
  i=$((i + 1))
done

DHX_STAGE=finalize
[ "$SAW_GREP" -eq 1 ] || exit 0
[ "$REWROTE" -eq 1 ] || exit 0           # nothing changed => an allow would be inert (HP-061)

# --- Emit ---------------------------------------------------------------------------------
# updatedInput REPLACES the whole tool_input object — no merge (HP-041) — so the ORIGINAL
# object is re-emitted with only `.command` overridden. Emitting `{command:…}` alone would
# silently drop the caller's timeout / description / run_in_background, all optional in the
# Bash schema, so validation would pass and nothing would warn.
#
# The pairing with permissionDecision:"allow" is mechanical, not stylistic: `Ifo`'s
# no-opinion branch passes the ORIGINAL input onward, so an updatedInput submitted without a
# decision is discarded (HP-061).
TOOL_INPUT=$(printf '%s' "$INPUT" | jq -c '.tool_input // {}' 2>/dev/null) || exit 0
[ -n "$TOOL_INPUT" ] || exit 0

DHX_EMITTED=1
jq -n --argjson ti "$TOOL_INPUT" --arg cmd "$NEW" --arg d "$CD_TARGET" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    permissionDecisionReason: ("dhx-cd-compound-read-allow: grep operands resolved absolute under " + $d + " so the classifier can evaluate the deny set"),
    updatedInput: ($ti | .command = $cmd)
  }
}' 2>/dev/null

exit 0
