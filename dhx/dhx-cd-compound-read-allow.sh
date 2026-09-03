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
#   * grep family ONLY (`grep`/`egrep`/`fgrep`/`rg`) — the entire measured defect. `diff`,
#     `git`, `cp`, `mv` also arm the circuit but are REFUSED: their operand grammars differ
#     and `cp`/`mv` write. A compound containing one is left alone.
#   * the PATTERN operand is never rewritten. `cd /repo; grep -rn docs src/` is the shape
#     that punishes a naive rewriter — `docs` is also a real directory, and prefixing it
#     would silently change what is being searched FOR.
#   * `-e` / `-f` / `--regexp` / `--file` are refused outright, so the pattern is always the
#     first non-option word and the grammar stays decidable.
#   * any short bundle carrying an argument-consuming letter, and any long option not on the
#     known-no-argument list, is refused rather than guessed at.
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
case "$CMD" in 'cd /'*) ;; *) exit 0 ;; esac

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
# `|` and `&` (pipes, background, bare-& lists) are refused outright — they are not part of
# the measured shape and admitting them would widen the reassembly surface for nothing.
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
      '|')     [ "${s:$i:2}" = "||" ] || return 1
               SEG_TEXT+=("$cur"); SEG_SEP+=("||"); cur=""; i=$((i + 2)); continue ;;
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
scan_segments "$CMD" || exit 0
[ "${#SEG_TEXT[@]}" -ge 2 ] || exit 0

# --- Segment 1 must be exactly `cd <existing absolute dir>` -------------------------------
split_words "$(trim "${SEG_TEXT[0]}")"
[ "${#WORDS[@]}" -eq 2 ] || exit 0
[ "${WORDS[0]}" = "cd" ] || exit 0
CD_TARGET=$(strip_quotes "${WORDS[1]}")
case "$CD_TARGET" in /*) ;; *) exit 0 ;; esac
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

# Non-arming companions. They cannot raise the prompt and are never rewritten; they are
# tolerated only so a mixed compound containing a real grep is still fixable. Deliberately
# absent: cp, mv, tee, dd, install (write); python/node/perl/ruby/sh/bash/eval/source/xargs/
# env/sudo (opaque or execute); git and diff (arming, refused above).
is_allowed_companion() {
  case "$1" in
    cat|head|tail|wc|ls|sort|uniq|cut|nl|tr|stat|file|column) return 0 ;;
    basename|dirname|realpath|readlink|echo|printf|true|false|pwd|date) return 0 ;;
    sed|awk|find) return 0 ;;   # gated further below
    *) return 1 ;;
  esac
}

# Long grep/rg options known to take NO argument. Anything else long is refused rather than
# guessed at, because guessing wrong shifts every operand position after it.
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
        --*)
          case "$w" in
            --regexp*|--file*|--include*|--exclude*|--glob*|--iglob*|--type*|--max-count*|--after-context*|--before-context*|--context*)
              return 1 ;;                       # supplies a pattern, a path, or takes an arg
            *=*) out+=("$w"); i=$((i + 1)); continue ;;   # attached value, positionally inert
            *)   is_known_noarg_long "$w" || return 1
                 out+=("$w"); i=$((i + 1)); continue ;;
          esac ;;
        '-') return 1 ;;                        # bare `-` stdin operand: nothing to fix
        -*)
          # Short bundle. Refuse if it carries any argument-consuming letter — those either
          # take a separate operand (shifting positions) or supply a pattern/path.
          case "$w" in *[efmABCDdgt]*) return 1 ;; esac
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
  [ "$n_paths" -ge 1 ] || return 1      # no operands => no ask to remove => nothing to do
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

  is_other_arming "$head" && exit 0      # arms the circuit but grammar not implemented
  [ "$head" = "cd" ] && exit 0           # a second cd would move the base we resolved against

  if is_grep_family "$head"; then
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

jq -n --argjson ti "$TOOL_INPUT" --arg cmd "$NEW" --arg d "$CD_TARGET" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    permissionDecisionReason: ("dhx-cd-compound-read-allow: grep operands resolved absolute under " + $d + " so the classifier can evaluate the deny set"),
    updatedInput: ($ti | .command = $cmd)
  }
}' 2>/dev/null

exit 0
