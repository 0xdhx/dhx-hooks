#!/usr/bin/env bash
# scripts/lib/tab-ifs-scan.sh — the ONE TAB-valued-IFS detector (pattern, ALLOW list, judgement).
#
# Consumers (both must use this file; neither may carry its own pattern or ALLOW list):
#   tests/probes/probe-tab-ifs-field-collapse-lint.sh  at rest, over worktree files
#   scripts/verify-hook-patterns.sh check #5b           at commit, over STAGED blobs, run from
#                                                       this file's own STAGED copy (fail closed)
#
# RUN IT, NEVER SOURCE IT. The gate executes this file as a child process (`bash <copy> …`) so a
# staged edit can never reach the gate's FAIL accumulator, shell options or traps — the reason a
# sourced lib was rejected at the 2026-09-25 steer-point (docs/decisions.md, gate-check row).
#
# Invariant it enforces: no non-comment assignment of IFS to a value carrying a TAB, in any
# spelling, outside the reasoned ALLOW list. TAB is IFS *whitespace*: `read` collapses a run of
# tabs and strips leading ones, so an EMPTY leading or middle field vanishes and every later field
# shifts one variable to the left. Nothing errors. (docs/decisions.md 2026-09-25 sweep row.)
#
# THE TOOTH keys on the IFS ASSIGNMENT, not on a `read` beside it, so a split assignment and
# `local`/`export`/`declare` forms are caught. Spellings: $'\t' $'\011' $'\x09', a literal TAB
# inside '…' or "…" or bare, and a `printf … \t` command substitution. STATED RESIDUAL — invisible
# to a line lint: an IFS set through a variable (`IFS=$sep`), inside `eval`, or by a wrapper.
# Whole-line comments are skipped (the converted sites document the defect in comments).
#
# THE CORRECT IDIOMS: NUL framing — `jq -j` with "\u0000" after every field, read by
# `IFS= read -r -d ''` per field (dhx/dhx-schedule-prompt.sh); a delimiter split —
# `mapfile -t -d $'\t'` or a first-TAB parameter split (dhx/dhx-duplicate-launch.sh `_split_tab`);
# or a non-whitespace separator whose byte no field can carry (unit separator, \x1f).
#
# ALLOW entries are `path|anchor|reason`: the anchor must appear on the flagged line, each entry
# JUDGED must match EXACTLY one hit (0 = its site was converted away, 2+ = a second line hides
# behind it; both are STALE), and each carries its reason. Only rows from a fixed-format external
# producer qualify, where no field but the last can be empty — policy settled 2026-09-25. A claim
# about a producer this repo does not own does NOT qualify.
#
# Usage:
#   bash tab-ifs-scan.sh --root DIR [--hits] [--all-allow] [--] RELPATH...
#       Scan DIR/RELPATH for each RELPATH (labelled RELPATH). Judges the ALLOW entries whose path
#       is among the RELPATHs; --all-allow judges every entry (an entry whose path was not given
#       counts 0 hits, so it is STALE). --hits also prints every raw hit.
#   bash tab-ifs-scan.sh --list-allow      one `path|anchor|reason` per line
#
# Output lines: `HIT <path>:<line>:<text>` (--hits only), `UNALLOWED <path>:<line>:<text>`,
#               `STALE <path>|<anchor> (matches N hits, want exactly 1)`.
# Exit: 0 clean · 1 UNALLOWED or STALE lines printed · 2 cannot scan (usage, unreadable file,
#       awk or grep error). The gate blocks on 1 AND fails closed on anything else — an unusable
#       detector must never read as "zero hits".
set -uo pipefail

TAB=$'\t'
I="IF""S="   # assembled, so this file's own source never spells the thing it hunts
PAT="${I}\\\$'[^']*(\\\\t|\\\\011|\\\\x09)|${I}\"[^\"]*${TAB}|${I}'[^']*${TAB}|${I}${TAB}|${I}[^;]*printf[^;]*\\\\t"

ALLOW=(
  "scripts/verify-hook-patterns.sh|read -r _sha _ct|git log --format='%H%x09%ct': a 40-hex sha and an epoch, never empty; a row without a sha is skipped"
  "scripts/hooks/pre-commit.d/30-deletion-audit.sh|read -r added deleted path|git --numstat: added/deleted are digits or '-' (binary), never empty; path is LAST and absorbs the rest"
  "scripts/hooks/pre-commit.d/30-deletion-audit.sh|read -r _p _b|DELETION_SET rows are built in-file as path<TAB>blob from git -z path tokens (never empty; TAB/newline paths dropped at construction); blob is LAST"
)

die() { printf 'tab-ifs-scan: %s\n' "$1" >&2; exit 2; }

if [ "${1:-}" = "--list-allow" ]; then
  printf '%s\n' "${ALLOW[@]}"; exit 0
fi

ROOT="" SHOW_HITS=0 ALL_ALLOW=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || die "--root needs a directory"; ROOT=$2; shift 2 ;;
    --hits) SHOW_HITS=1; shift ;;
    --all-allow) ALL_ALLOW=1; shift ;;
    --) shift; break ;;
    -*) die "unknown option: $1" ;;
    *) break ;;
  esac
done
[ -n "$ROOT" ] && [ -d "$ROOT" ] || die "--root must name an existing directory"

# 1. Non-comment lines of every file, labelled path:line:text. A file that cannot be read is an
#    error, never an empty file.
LINES=""
for rel in "$@"; do
  [ -f "$ROOT/$rel" ] && [ -r "$ROOT/$rel" ] || die "cannot read $ROOT/$rel"
  out=$(awk -v f="$rel" '/^[[:space:]]*#/ {next} {print f ":" FNR ":" $0}' "$ROOT/$rel") \
    || die "awk failed on $rel"
  [ -n "$out" ] && LINES+="$out"$'\n'
done

# 2. The tooth. grep exit 1 is "no match"; anything above 1 is a broken pattern or engine.
HITS=$(command grep -E -- "$PAT" <<<"$LINES"); rc=$?
[ "$rc" -le 1 ] || die "grep -E failed (rc=$rc) — the pattern is broken"

# 3. Judgement: every hit covered; every judged entry matches exactly one hit.
declare -A GIVEN=()
for rel in "$@"; do GIVEN[$rel]=1; done
FOUND=0
[ "$SHOW_HITS" -eq 1 ] && [ -n "$HITS" ] && while IFS= read -r h; do printf 'HIT %s\n' "$h"; done <<<"$HITS"
while IFS= read -r h; do
  [ -n "$h" ] || continue
  covered=0
  for e in "${ALLOW[@]}"; do
    path=${e%%|*}; anchor=${e#*|}; anchor=${anchor%%|*}
    case "$h" in "$path:"*"$anchor"*) covered=1; break ;; esac
  done
  [ "$covered" -eq 1 ] || { printf 'UNALLOWED %s\n' "$h"; FOUND=1; }
done <<<"$HITS"
for e in "${ALLOW[@]}"; do
  path=${e%%|*}; anchor=${e#*|}; anchor=${anchor%%|*}
  [ "$ALL_ALLOW" -eq 1 ] || [ -n "${GIVEN[$path]:-}" ] || continue
  n=0
  while IFS= read -r h; do case "$h" in "$path:"*"$anchor"*) n=$((n+1)) ;; esac; done <<<"$HITS"
  [ "$n" -eq 1 ] || { printf 'STALE %s (matches %d hits, want exactly 1)\n' "$path|$anchor" "$n"; FOUND=1; }
done
[ "$FOUND" -eq 0 ] || exit 1
exit 0
