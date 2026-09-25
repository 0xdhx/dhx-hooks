#!/usr/bin/env bash
# dhx-vet-closures-render.sh — pending `/dhx:vet` close-offer surfacer (worker).
# Patterns: HP-015
#
# Reads the machine-local closure ledger written by `/dhx:vet`'s close-offer UAQ
# (carve-out 3) and renders a SessionStart block for every row that survives a
# this-run disk verification. A residual row means exactly one thing: a session went
# stale with the close question unanswered. Both answers remove the row, so a row
# that survives is evidence the operator NEVER consented.
#
# Ledger schema (single source of truth): ~/repos/<skills-monorepo>/dhx/vet/SKILL.md
#   § "Closure ledger — pending close-offers"  (shipped skills 84a4b4e3).
#
# ─── The one invariant (read before changing ANY emitted line) ───
# INVARIANT: the action line is a RE-VET — `› /dhx:vet <repo_root>/<prompt_relpath>`.
# It must NEVER render `git mv`, `git -C`, or any other close command.
# Reason, because it is not obvious and a future editor will be tempted to "help":
# this script is a child of session-start.sh, whose plain stdout reaches MODEL CONTEXT.
# Vet's governing invariant — "Never `git mv` on a mechanical signal alone." — lives
# only in dhx/vet/SKILL.md, and vet is disable-model-invocation:false, so a cold
# session gets vet's *description* in the skill listing but NOT its *body*. At the
# moment a fresh session reads this block, that invariant is not in context. A row is
# evidence of the ABSENCE of consent; rendering it as an executable mutation inverts
# its meaning. Re-vetting re-derives the verdict inside vet, where the guard is loaded.
# Negative-tested: tests/probes/probe-vet-closures.sh goes RED on a producer that
# emits a literal `git mv` / `git -C`.
#
# Fail silent, ALWAYS. Malformed ledger, missing file, absent jq, or a lock timeout
# all exit 0 with no output. A SessionStart producer that can fail loudly is a
# producer that breaks every session start on this box.
#
# Probe override: DHX_VET_CLOSURES_LEDGER=<path> (D-20 SAFE_FOR_LIVE fixture injection).
# Source-of-truth: ~/repos/hooks/dhx/dhx-vet-closures-render.sh
# Symlinked to:    ~/.claude/hooks/dhx-vet-closures-render.sh
set -uo pipefail

LEDGER="${DHX_VET_CLOSURES_LEDGER:-$HOME/.claude/dhx-tools/state/vet-closures.jsonl}"
LOCK="$LEDGER.lock"

[ -f "$LEDGER" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# Read under the SAME flock the writer takes. The skills-side spec forbids a
# lock-free path: a concurrent rename-based rewrite would otherwise hand us a
# torn or vanished file. Lock timeout → silent exit 0 (never block session start).
RAW=$(
  exec 9>"$LOCK" 2>/dev/null || exit 1
  flock -w 2 9 2>/dev/null || exit 1
  cat "$LEDGER" 2>/dev/null
) || exit 0
[ -n "$RAW" ] || exit 0

# `fromjson? // empty` drops malformed lines silently in a single pass — a partially
# written or hand-corrupted ledger degrades to "fewer rows", never to a loud failure.
PARSED=$(printf '%s\n' "$RAW" | jq -rR '
  fromjson? // empty
  | select(type == "object")
  | [ (.repo_root // ""), (.prompt_relpath // ""), (.slug // ""),
      (.verdict // ""), (.state // "offered"),
      (.last_offered // .first_seen // "") ]
  | map(tostring | gsub("[\u001f\n\r]"; " ")) | join("\u001f")' 2>/dev/null) || exit 0
[ -n "$PARSED" ] || exit 0

now=$(date +%s 2>/dev/null) || exit 0
out=""
count=0

# Here-string, NOT a pipe: a `while … done < <(pipe)` subshell would discard every
# variable set in the loop body and this block would render permanently empty.
# Unit separator, NOT @tsv + TAB: TAB is IFS whitespace, so `read` collapsed an EMPTY slug or
# verdict and shifted state/ts into their columns (docs/decisions.md 2026-09-25 row). jq flattens
# 0x1f/newline inside a value to a space above — this is a renderer, and a path so mangled only
# fails the -d/-f checks below and skips its row.
while IFS=$'\x1f' read -r repo_root relpath slug verdict state ts; do
  [ -n "$repo_root" ] && [ -n "$relpath" ] || continue

  # ─── Self-heal on read (never surface a row unverified against disk THIS run) ───
  # A peer session or a `/dhx:vet sweep` may have closed it since the offer.
  case "$relpath" in */done/*) continue ;; esac   # already retired
  [ -d "$repo_root" ] || continue                 # stale repo_root
  full="$repo_root/$relpath"
  [ -f "$full" ] || continue                      # moved or deleted

  # Freshness suffix. Minutes under an hour, hours under a day, days beyond — a
  # residual row is stale BY CONSTRUCTION, so days is the common case and "72h ago"
  # would read worse than "3d ago". Unparseable timestamp → omit the suffix, not the row.
  age=""
  if [ -n "$ts" ]; then
    t=$(date -d "$ts" +%s 2>/dev/null) || t=""
    if [ -n "$t" ]; then
      s=$(( now - t )); [ "$s" -lt 0 ] && s=0
      if   [ "$s" -lt 3600 ];  then age="$(( s / 60 ))m ago"
      elif [ "$s" -lt 86400 ]; then age="$(( s / 3600 ))h ago"
      else                          age="$(( s / 86400 ))d ago"
      fi
    fi
  fi

  fields="$(basename "$repo_root") · $slug"
  [ -n "$verdict" ] && fields="$fields · $verdict"

  # `accepted-blocked` is a DIFFERENT ask from silence: the operator said YES and a
  # pre-commit gate then refused the commit. Collapsing the two states into one
  # rendering destroys that distinction and is a defect, not a simplification.
  if [ "$state" = "accepted-blocked" ]; then
    fields="$fields · close blocked by gate"
    [ -n "$age" ] && fields="$fields · accepted $age"
  elif [ -n "$age" ]; then
    fields="$fields · offered $age"
  else
    fields="$fields · offered"
  fi

  out="$out    $fields"$'\n'"      › /dhx:vet $full"$'\n'
  count=$(( count + 1 ))
done <<< "$PARSED"

[ "$count" -gt 0 ] || exit 0

# Header: own line, no leading space, count in parens, colon-terminated.
# `out` already ends in exactly one newline; blocks concatenate with no separator.
printf '⚠ Pending vet closures (%d):\n%s' "$count" "$out"
exit 0
