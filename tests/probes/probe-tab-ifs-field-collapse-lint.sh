#!/usr/bin/env bash
# probe-tab-ifs-field-collapse-lint.sh — static lint: no TAB-valued IFS in the repo's shell code
#
# Invariant: `dhx/`, `dhx-plugin/plugins/dhx/hooks/`, `scripts/` and `tests/` contain ZERO
# non-comment assignments of IFS to a value carrying a TAB, in any spelling, outside the
# reasoned ALLOW list below. TAB is IFS *whitespace*: `read` collapses a run of tabs and strips
# leading ones, so an EMPTY leading or middle field vanishes and every later field shifts one
# variable to the left. Nothing errors. The canonical carrier was `jq … | @tsv` split by
# `IFS=$'\t' read`, which shipped at 13 hook sites plus 8 elsewhere.
#
# Backs: docs/decisions.md 2026-09-25 row (the class sweep; the 2026-08-03 row fixed two guards
#        and left the rest standing on a "safe by construction" claim that reasoned only about
#        @tsv's newline-escaping half).
#
# THE NET is a mechanism, not a spelling: every git-listed (tracked or untracked-unignored) file
# under the four roots that is `*.sh` or opens with a shell shebang. Liveness is asserted — a
# per-root file floor and the presence of every file this sweep converted — so a net that
# silently scans nothing is a red, not a pass.
#
# THE TOOTH keys on the IFS ASSIGNMENT, not on a `read` beside it, so a split assignment
# (`IFS=$'\t'` on one line, `read -r a b` on the next) and `local`/`export`/`declare` forms are
# caught. Spellings: $'\t' $'\011' $'\x09', a literal TAB inside '…' or "…" or bare, and a
# `printf … \t` command substitution (the form the 2026-09-24 census `rg` missed at
# scripts/hooks/pre-commit.d/30-deletion-audit.sh). STATED RESIDUAL — invisible to a line lint:
# an IFS set through a variable (`IFS=$sep`), inside `eval`, or by a wrapper function.
# Whole-line comments are skipped (the converted sites document the defect in comments).
#
# THE CORRECT IDIOMS (what to write instead): NUL framing — `jq -j` with "\u0000" after every
# field, read by `IFS= read -r -d ''` per field (see dhx/dhx-schedule-prompt.sh); a delimiter
# split — `mapfile -t -d $'\t'` or a first-TAB parameter split (dhx/dhx-duplicate-launch.sh
# `_split_tab`); or a non-whitespace separator whose byte no field can carry (`IFS=$'\x1f'`).
#
# ALLOW entries are `path|anchor|reason`: the anchor must appear on the flagged line, each entry
# must match EXACTLY one hit (a stale entry is a red), and each carries its reason. Only rows from
# a fixed-format external producer qualify, where no field but the last can be empty — policy
# settled 2026-09-25. A claim about a producer this repo does not own does NOT qualify.
#
# Run: bash tests/probes/probe-tab-ifs-field-collapse-lint.sh
# Exit 0 = clean, 1 = one or more failures.

# SAFE_FOR_LIVE: yes   (static lint over git-listed in-repo shell files; mutation cells run in a mktemp git repo; no writes to the tree)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ROOTS=(dhx dhx-plugin/plugins/dhx/hooks scripts tests)
PASS=0; FAIL=0
ok()  { echo "OK   $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }

TAB=$'\t'
I="IF""S="   # assembled, so this file's own source never spells the thing it hunts
PAT="${I}\\\$'[^']*(\\\\t|\\\\011|\\\\x09)|${I}\"[^\"]*${TAB}|${I}'[^']*${TAB}|${I}${TAB}|${I}[^;]*printf[^;]*\\\\t"

ALLOW=(
  "scripts/verify-hook-patterns.sh|read -r _sha _ct|git log --format='%H%x09%ct': a 40-hex sha and an epoch, never empty; a row without a sha is skipped"
  "scripts/hooks/pre-commit.d/30-deletion-audit.sh|read -r added deleted path|git --numstat: added/deleted are digits or '-' (binary), never empty; path is LAST and absorbs the rest"
  "scripts/hooks/pre-commit.d/30-deletion-audit.sh|read -r _p _b|DELETION_SET rows are built in-file as path<TAB>blob from git -z path tokens (never empty; TAB/newline paths dropped at construction); blob is LAST"
)

# list_shell_files <base> — repo-relative shell files under ROOTS in <base> (a git work tree)
list_shell_files() {
  local base=$1 f
  git -C "$base" ls-files --cached --others --exclude-standard -- "${ROOTS[@]}" 2>/dev/null \
  | while IFS= read -r f; do
      [ -f "$base/$f" ] || continue
      case "$f" in
        *.sh) printf '%s\n' "$f" ;;
        *) local first=""; IFS= read -r first < "$base/$f" 2>/dev/null
           [[ "$first" =~ ^\#!.*[/[:space:]](ba|z|k|da)?sh([[:space:]]|$) ]] && printf '%s\n' "$f" ;;
      esac
    done
}

# scan <base> — `path:line:text` for every non-comment line carrying a TAB-valued IFS
scan() {
  local base=$1 f
  list_shell_files "$base" | while IFS= read -r f; do
    awk -v f="$f" '/^[[:space:]]*#/ {next} {print f ":" FNR ":" $0}' "$base/$f"
  done | command grep -E "$PAT"
}

# unallowed <hits> <allow-entry…> — prints hits no entry covers, then STALE lines for entries
# matching a count other than exactly one.
unallowed() {
  local hits=$1; shift
  local h e path anchor n covered
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    covered=0
    for e in "$@"; do
      path=${e%%|*}; anchor=${e#*|}; anchor=${anchor%%|*}
      case "$h" in "$path:"*"$anchor"*) covered=1; break ;; esac
    done
    [ "$covered" -eq 1 ] || printf 'UNALLOWED %s\n' "$h"
  done <<<"$hits"
  for e in "$@"; do
    path=${e%%|*}; anchor=${e#*|}; anchor=${anchor%%|*}
    n=0
    while IFS= read -r h; do case "$h" in "$path:"*"$anchor"*) n=$((n+1)) ;; esac; done <<<"$hits"
    [ "$n" -eq 1 ] || printf 'STALE %s (matches %d hits, want exactly 1)\n' "$path|$anchor" "$n"
  done
}

echo "=== 1. Net liveness (the set the tooth is applied to) ==="
FILES=$(list_shell_files "$REPO_ROOT")
declare -A FLOOR=([dhx]=40 [dhx-plugin/plugins/dhx/hooks]=2 [scripts]=15 [tests]=100)
for r in "${ROOTS[@]}"; do
  n=$(printf '%s\n' "$FILES" | command grep -c "^$r/")
  [ "$n" -ge "${FLOOR[$r]}" ] && ok "net covers $r/ ($n shell files >= floor ${FLOOR[$r]})" \
    || bad "net covers $r/" "$n shell files < floor ${FLOOR[$r]} — the file listing is broken, the tooth is inert"
done
# every file the 2026-09-25 sweep converted must be inside the net, or its regression is invisible
for f in dhx/dhx-worktree-write-guard.sh dhx/dhx-session-registry-prompt.sh dhx/dhx-schedule-prompt.sh \
         dhx/dhx-cold-return-gate.sh dhx/dhx-duplicate-launch.sh dhx/dhx-health-check.sh \
         dhx/dhx-vet-closures-render.sh dhx/dhx-key-coverage-audit.sh dhx/dhx-session-registry-start.sh \
         tests/probes/probe-hook-advisory-commands-reachable.sh tests/probes/probe-cc-grep-operand-extractor.sh \
         tests/probes/probe-v1-1-1-gate.sh scripts/verify-hook-patterns.sh scripts/hooks/pre-commit.d/30-deletion-audit.sh; do
  [[ $'\n'"$FILES"$'\n' == *$'\n'"$f"$'\n'* ]] && ok "net includes $f" || bad "net includes $f" "absent from the listing"
done

echo "=== 2. The tree (zero unallowed hits; every ALLOW entry live) ==="
HITS=$(scan "$REPO_ROOT")
# The ALLOW entries are themselves hits, so a zero-hit scan here means the tooth is dead.
if [ -z "$HITS" ]; then
  bad "scan returned hits for the ALLOW sites" "no hits at all — the pattern or the net is broken"
fi
REPORT=$(unallowed "$HITS" "${ALLOW[@]}")
if [ -z "$REPORT" ]; then
  ok "no TAB-valued IFS outside ALLOW ($(printf '%s\n' "$HITS" | command grep -c .) allowed hit(s), each entry matching exactly one)"
else
  while IFS= read -r l; do bad "tree: $l"; done <<<"$REPORT"
  echo "     fix: NUL framing, mapfile -d \$'\\t', a first-TAB split, or IFS=\$'\\x1f' — see this probe's header"
fi
for e in "${ALLOW[@]}"; do
  r=${e##*|}; [ ${#r} -ge 40 ] && ok "ALLOW ${e%%|*} carries a reason" || bad "ALLOW ${e%%|*} carries a reason" "reason too short: '$r'"
done

echo "=== 3. Mutation cells (a copy of the real tree + one file each) ==="
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
W="$TMP/tree"; mkdir -p "$W"
( cd "$REPO_ROOT" && printf '%s\n' "$FILES" | while IFS= read -r f; do mkdir -p "$W/$(dirname "$f")"; cp "$f" "$W/$f"; done )
git -C "$W" init -q 2>/dev/null
BASE=$(scan "$W")
# NULL mutant first: the unmutated copy must reproduce the real tree's result exactly.
[ "$BASE" = "$HITS" ] && ok "NULL mutant: the copied tree scans identically to the real one" \
  || bad "NULL mutant: copied tree scans identically" "base=$(printf '%s' "$BASE" | command grep -c .) real=$(printf '%s' "$HITS" | command grep -c .)"

cell() {  # cell <expect red|clean> <relpath> <label> <content>
  local want=$1 rel=$2 label=$3 body=$4 got new
  mkdir -p "$W/$(dirname "$rel")"; printf '%s\n' "$body" > "$W/$rel"
  new=$(scan "$W" | command grep -c "^$rel:")
  rm -f "$W/$rel"
  if [ "$want" = red ]; then got=$([ "$new" -eq 1 ] && echo red || echo "clean($new)"); else got=$([ "$new" -eq 0 ] && echo clean || echo "red($new)"); fi
  [ "$got" = "$want" ] && ok "[$want] $label" || bad "[$want] $label" "got $got"
}
Q="'"
cell red   dhx/zz-r1.sh "@tsv + tab read pair (the canonical carrier)" \
  "F=\$(jq -r ${Q}[.a,.b] | @tsv${Q} <<<\"\$X\"); ${I}\$${Q}\\t${Q} read -r A B <<<\"\$F\""
cell red   dhx/zz-r2.sh "split assignment, read on the next line" "${I}\$${Q}\\t${Q}
read -r A B <<<\"\$F\""
cell red   dhx/zz-r3.sh "literal TAB inside double quotes" "while ${I}\"${TAB}\" read -r A B; do :; done"
cell red   dhx/zz-r4.sh "octal \\011 spelling" "${I}\$${Q}\\011${Q} read -r A B"
cell red   scripts/zz-r5.sh "printf command-substitution spelling" "while ${I}\"\$(printf ${Q}\\t${Q})\" read -r A B; do :; done"
cell red   tests/zz-r6.sh "local assignment" "f() { local ${I}\$${Q}\\t${Q}; read -r A B; }"
cell red   scripts/zz-r7 "extensionless file with a bash shebang" "#!/usr/bin/env bash
${I}\$${Q}\\x09${Q} read -r A B"
cell clean dhx/zz-n1.sh "whole-line comment naming the shape" "# NOT \`${I}\$${Q}\\t${Q} read\`: TAB is IFS whitespace"
cell clean dhx/zz-n2.sh "sort -t with a TAB" "sort -t\$${Q}\\t${Q} -k1,1n"
cell clean dhx/zz-n3.sh "mapfile -d TAB (delimiter split)" "mapfile -t -d \$${Q}\\t${Q} F <<<\"\$row\""
cell clean dhx/zz-n4.sh "unit-separator IFS" "${I}\$${Q}\\x1f${Q} read -r A B <<<\"\$row\""
cell clean dhx/zz-n5.js "a non-shell file" "// ${I}\$${Q}\\t${Q} read"

# A stale ALLOW entry (its site converted away) must red, or the list rots silently.
STALE=$(unallowed "$HITS" "${ALLOW[@]}" "dhx/nope.sh|read -r gone|a site that no longer exists, kept only to prove staleness reds")
case "$STALE" in *"STALE dhx/nope.sh|read -r gone"*) ok "a stale ALLOW entry reds" ;; *) bad "a stale ALLOW entry reds" "got: ${STALE:-nothing}" ;; esac

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
