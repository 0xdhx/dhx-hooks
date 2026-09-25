#!/usr/bin/env bash
# probe-tab-ifs-field-collapse-lint.sh — static lint: no TAB-valued IFS in the repo's shell code
#
# Invariant: `dhx/`, `dhx-plugin/plugins/dhx/hooks/`, `scripts/` and `tests/` contain ZERO
# non-comment assignments of IFS to a value carrying a TAB, in any spelling, outside the
# reasoned ALLOW list. TAB is IFS *whitespace*: `read` collapses a run of tabs and strips
# leading ones, so an EMPTY leading or middle field vanishes and every later field shifts one
# variable to the left. Nothing errors. The canonical carrier was `jq … | @tsv` split by a
# TAB-IFS `read`, which shipped at 13 hook sites plus 8 elsewhere.
#
# Backs: docs/decisions.md 2026-09-25 rows — the class sweep (the 2026-08-03 row fixed two guards
#        and left the rest standing on a "safe by construction" claim that reasoned only about
#        @tsv's newline-escaping half) and the gate-check row (commit-time check #5b).
#
# THE DETECTOR is scripts/lib/tab-ifs-scan.sh — pattern, ALLOW list, judgement, spellings, stated
# residuals and the correct idioms all live in its header. This probe carries NONE of them: the
# commit gate (scripts/verify-hook-patterns.sh check #5b) runs the same file from its staged copy,
# so a probe-local pattern would be the drift that let check #5 fall behind its probe.
#
# THE NET is a mechanism, not a spelling: every git-listed (tracked or untracked-unignored) file
# under the four roots that is `*.sh` or opens with a shell shebang. Liveness is asserted — a
# per-root file floor and the presence of every file the sweep converted — so a net that silently
# scans nothing is a red, not a pass.
#
# Cells:
#   [net]    floors, sweep files present, scanner present
#   [tree]   zero UNALLOWED/STALE over the real tree, the ALLOW hits live, every entry reasoned
#   [mut]    copied tree: NULL mutant, seven red spellings, five clean shapes, stale/duplicate
#            ALLOW, a broken pattern exits 2 (never "zero hits")
#   [seed]   tests/probes/lib/gate-fixture-libs.sh lists every scripts/lib path the gate names
#   [gate]   fixture repos driving lint_tab_ifs_staged: red staged scripts/ file, suffix-less
#            shebang file, non-shell file, clean file, index-vs-worktree (partial staging) both
#            ways, ALLOW transitions, scanner-staged judges every entry, fail-closed on a missing,
#            broken or pattern-broken scanner, and an intact index copy wins over a broken worktree
#
# Mutation seam: DHX_PROBE_TAB_IFS_SCANNER points every cell, fixtures included, at a mutant.
#
# Run: bash tests/probes/probe-tab-ifs-field-collapse-lint.sh
# Exit 0 = clean, 1 = one or more failures.

# SAFE_FOR_LIVE: yes   (static lint over git-listed in-repo shell files; mutation and gate cells run in mktemp git repos; no writes to the tree)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCANNER="${DHX_PROBE_TAB_IFS_SCANNER:-$REPO_ROOT/scripts/lib/tab-ifs-scan.sh}"
GATE="$REPO_ROOT/scripts/verify-hook-patterns.sh"
SEED="$REPO_ROOT/tests/probes/lib/gate-fixture-libs.sh"
ROOTS=(dhx dhx-plugin/plugins/dhx/hooks scripts tests)
PASS=0; FAIL=0
ok()  { echo "OK   $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }

TAB=$'\t'
I="IF""S="   # assembled, so this file's own source never spells the thing it hunts
Q="'"

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

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# judge <base> <scanner> [extra-args…] — runs the scanner over the whole net of <base>; sets OUT to
# its stdout and JRC to its exit code. Never call it inside $( ): JRC would stay in the subshell.
JRC=0 OUT=""
judge() {
  local base=$1 sc=$2; shift 2
  local -a files=()
  mapfile -t files < <(list_shell_files "$base")
  bash "$sc" --root "$base" "$@" -- "${files[@]}" > "$TMP/judge.out" 2>"$TMP/judge.err"; JRC=$?
  OUT=$(cat "$TMP/judge.out")
}

echo "=== 1. Net liveness (the set the tooth is applied to) ==="
FILES=$(list_shell_files "$REPO_ROOT")
declare -A FLOOR=([dhx]=40 [dhx-plugin/plugins/dhx/hooks]=2 [scripts]=15 [tests]=100)
for r in "${ROOTS[@]}"; do
  n=$(printf '%s\n' "$FILES" | command grep -c "^$r/")
  [ "$n" -ge "${FLOOR[$r]}" ] && ok "[net] covers $r/ ($n shell files >= floor ${FLOOR[$r]})" \
    || bad "[net] covers $r/" "$n shell files < floor ${FLOOR[$r]} — the file listing is broken, the tooth is inert"
done
# every file the 2026-09-25 sweep converted must be inside the net, or its regression is invisible
for f in dhx/dhx-worktree-write-guard.sh dhx/dhx-session-registry-prompt.sh dhx/dhx-schedule-prompt.sh \
         dhx/dhx-cold-return-gate.sh dhx/dhx-duplicate-launch.sh dhx/dhx-health-check.sh \
         dhx/dhx-vet-closures-render.sh dhx/dhx-key-coverage-audit.sh dhx/dhx-session-registry-start.sh \
         tests/probes/probe-hook-advisory-commands-reachable.sh tests/probes/probe-cc-grep-operand-extractor.sh \
         tests/probes/probe-v1-1-1-gate.sh scripts/verify-hook-patterns.sh scripts/hooks/pre-commit.d/30-deletion-audit.sh \
         scripts/lib/tab-ifs-scan.sh; do
  [[ $'\n'"$FILES"$'\n' == *$'\n'"$f"$'\n'* ]] && ok "[net] includes $f" || bad "[net] includes $f" "absent from the listing"
done
[ -r "$SCANNER" ] && ok "[net] scanner readable ($SCANNER)" || bad "[net] scanner readable" "$SCANNER"

echo "=== 2. The tree (zero unallowed hits; every ALLOW entry live) ==="
judge "$REPO_ROOT" "$SCANNER" --hits --all-allow
HITS=$(sed -n 's/^HIT //p' <<<"$OUT")
REPORT=$(command grep -v '^HIT ' <<<"$OUT")
# The ALLOW entries are themselves hits, so a zero-hit scan here means the tooth is dead.
[ -n "$HITS" ] || bad "[tree] scan returns hits for the ALLOW sites" "no hits at all — the pattern or the net is broken"
if [ "$JRC" -eq 0 ] && [ -z "$REPORT" ]; then
  ok "[tree] no TAB-valued IFS outside ALLOW ($(command grep -c . <<<"$HITS") allowed hit(s), each entry matching exactly one)"
else
  bad "[tree] scanner verdict" "rc=$JRC"
  while IFS= read -r l; do [ -n "$l" ] && bad "[tree] $l"; done <<<"$REPORT"
  echo "     fix: see the correct idioms in scripts/lib/tab-ifs-scan.sh's header"
fi
ALLOWS=$(bash "$SCANNER" --list-allow)
while IFS= read -r e; do
  [ -n "$e" ] || continue
  r=${e##*|}; [ ${#r} -ge 40 ] && ok "[tree] ALLOW ${e%%|*} carries a reason" || bad "[tree] ALLOW ${e%%|*} carries a reason" "reason too short: '$r'"
done <<<"$ALLOWS"

echo "=== 3. Mutation cells (a copy of the real tree + one file each) ==="
W="$TMP/tree"; mkdir -p "$W"
( cd "$REPO_ROOT" && printf '%s\n' "$FILES" | while IFS= read -r f; do mkdir -p "$W/$(dirname "$f")"; cp "$f" "$W/$f"; done )
git -C "$W" init -q 2>/dev/null
judge "$W" "$SCANNER" --hits --all-allow; BASE=$(sed -n 's/^HIT //p' <<<"$OUT")
# NULL mutant first: the unmutated copy must reproduce the real tree's result exactly.
[ "$BASE" = "$HITS" ] && ok "[mut] NULL mutant: the copied tree scans identically to the real one" \
  || bad "[mut] NULL mutant: copied tree scans identically" "base=$(command grep -c . <<<"$BASE") real=$(command grep -c . <<<"$HITS")"

cell() {  # cell <expect red|clean> <relpath> <label> <content>
  local want=$1 rel=$2 label=$3 body=$4 got new=0
  mkdir -p "$W/$(dirname "$rel")"; printf '%s\n' "$body" > "$W/$rel"
  # in the net at all? (a non-shell file must stay out), then hits on that one file
  if [[ $'\n'"$(list_shell_files "$W")"$'\n' == *$'\n'"$rel"$'\n'* ]]; then
    new=$(bash "$SCANNER" --root "$W" --hits -- "$rel" | command grep -c '^HIT ')
  fi
  rm -f "$W/$rel"
  if [ "$want" = red ]; then got=$([ "$new" -eq 1 ] && echo red || echo "clean($new)"); else got=$([ "$new" -eq 0 ] && echo clean || echo "red($new)"); fi
  [ "$got" = "$want" ] && ok "[mut] [$want] $label" || bad "[mut] [$want] $label" "got $got"
}
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
MUT="$TMP/mut-stale.sh"
sed 's#^ALLOW=($#ALLOW=(\n  "dhx/nope.sh|read -r gone|a site that no longer exists, kept only to prove staleness reds"#' "$SCANNER" > "$MUT"
judge "$W" "$MUT" --all-allow
[ "$JRC" -eq 1 ] && [[ "$OUT" == *"STALE dhx/nope.sh|read -r gone (matches 0 hits"* ]] && ok "[mut] a stale ALLOW entry reds (exit 1)" \
  || bad "[mut] a stale ALLOW entry reds" "rc=$JRC out: ${OUT:-nothing}"
# A second TAB-IFS line hiding behind an entry's anchor must red too.
cp "$W/scripts/verify-hook-patterns.sh" "$TMP/vhp.bak"
printf '%s\n' "  while ${I}\$${Q}\\t${Q} read -r _sha _ct; do :; done" >> "$W/scripts/verify-hook-patterns.sh"
judge "$W" "$SCANNER" --all-allow
cp "$TMP/vhp.bak" "$W/scripts/verify-hook-patterns.sh"
[ "$JRC" -eq 1 ] && [[ "$OUT" == *"STALE scripts/verify-hook-patterns.sh|read -r _sha _ct (matches 2 hits"* ]] \
  && ok "[mut] a second line behind an ALLOW anchor reds (exit 1)" || bad "[mut] a second line behind an ALLOW anchor reds" "rc=$JRC out: ${OUT:-nothing}"
# A broken pattern must exit 2, never read as "zero hits".
MUT="$TMP/mut-pat.sh"; sed 's#^PAT=.*#PAT="(("#' "$SCANNER" > "$MUT"
judge "$W" "$MUT"
[ "$JRC" -eq 2 ] && ok "[mut] a broken pattern exits 2 (cannot scan), not 0" || bad "[mut] a broken pattern exits 2" "rc=$JRC"

echo "=== 4. Gate fixture seed list (tests/probes/lib/gate-fixture-libs.sh) ==="
SEEDED=$(bash "$SEED" --list)
NAMED=$(command grep -oE 'scripts/lib/[A-Za-z0-9._-]+' "$GATE" | sort -u)
[ -n "$NAMED" ] || bad "[seed] the gate names scripts/lib paths" "none found — the extraction is broken"
while IFS= read -r p; do
  [ -n "$p" ] || continue
  [[ $'\n'"$SEEDED"$'\n' == *$'\n'"$p"$'\n'* ]] && ok "[seed] gate lib $p is in the fixture seed list" \
    || bad "[seed] gate lib $p is in the fixture seed list" "fixture probes will fail CLOSED on it"
done <<<"$NAMED"
while IFS= read -r p; do
  [ -n "$p" ] || continue
  [ -f "$REPO_ROOT/$p" ] && ok "[seed] seed entry $p exists" || bad "[seed] seed entry $p exists" "missing from the repo"
done <<<"$SEEDED"

echo "=== 5. Gate cells (lint_tab_ifs_staged in fixture repos) ==="
RED_LINE="while ${I}\$${Q}\\t${Q} read -r a b; do :; done"
mkrepo() {  # mkrepo <name> — gate + seeded libs (scanner from the seam) + both real ALLOW files, committed
  local d="$TMP/$1"
  mkdir -p "$d/scripts/hooks/pre-commit.d" "$d/dhx"
  git -C "$d" init -q
  git -C "$d" config user.email probe@example.invalid
  git -C "$d" config user.name probe
  cp "$GATE" "$d/scripts/verify-hook-patterns.sh"
  cp "$REPO_ROOT/scripts/hooks/pre-commit.d/30-deletion-audit.sh" "$d/scripts/hooks/pre-commit.d/"
  bash "$SEED" "$REPO_ROOT" "$d"
  cp "$SCANNER" "$d/scripts/lib/tab-ifs-scan.sh"
  git -C "$d" add -A && git -C "$d" commit -q --no-verify -m base
  printf '%s\n' "$d"
}
run_gate() {
  ( cd "$1" && export DHX_SKIP_SET_FLAG_LINT_TESTS=1 && source scripts/verify-hook-patterns.sh >/dev/null 2>&1 && FAIL=0 \
      && lint_tab_ifs_staged ) >/dev/null 2>"$TMP/gate.err"
}
gate_case() {  # label want_rc repo [stderr-substring]
  local label=$1 want=$2 repo=$3 needle=${4:-} rc
  run_gate "$repo"; rc=$?
  if [ "$rc" = "$want" ] && { [ -z "$needle" ] || [[ "$(cat "$TMP/gate.err")" == *"$needle"* ]]; }; then
    ok "[gate] $label"
  else
    bad "[gate] $label" "rc=$rc want=$want; stderr: $(head -c 300 "$TMP/gate.err")"
  fi
}

R=$(mkrepo g-red); printf '#!/usr/bin/env bash\n%s\n' "$RED_LINE" > "$R/scripts/zz.sh"; git -C "$R" add -A
gate_case "blocks a staged scripts/*.sh site (the measured gap)" 1 "$R" "scripts/zz.sh:2 assigns IFS"

R=$(mkrepo g-suffixless); printf '#!/usr/bin/env bash\n%s\n' "$RED_LINE" > "$R/scripts/hooks/zz"; git -C "$R" add -A
gate_case "blocks a staged suffix-less shebang file" 1 "$R" "scripts/hooks/zz:2"

R=$(mkrepo g-inactive); mkdir -p "$R/tests/probes/.inactive"; printf '%s\n' "$RED_LINE" > "$R/tests/probes/.inactive/zz.sh"; git -C "$R" add -A
gate_case "blocks under .inactive/ (no exclusions, like the at-rest net)" 1 "$R" ".inactive/zz.sh:1"

R=$(mkrepo g-nonshell); printf 'notes\n%s\n' "$RED_LINE" > "$R/scripts/notes.txt"; git -C "$R" add -A
gate_case "passes a staged non-shell file" 0 "$R"

R=$(mkrepo g-clean); printf '#!/usr/bin/env bash\nmapfile -t -d $%s\\t%s F <<<"$row"\n' "$Q" "$Q" > "$R/scripts/zz.sh"; git -C "$R" add -A
gate_case "passes a clean staged shell file" 0 "$R"

R=$(mkrepo g-partial-clean); printf 'echo ok\n' > "$R/scripts/zz.sh"; git -C "$R" add -A
printf '%s\n' "$RED_LINE" >> "$R/scripts/zz.sh"
gate_case "judges the INDEX: a worktree-only violation passes" 0 "$R"

R=$(mkrepo g-partial-red); printf '%s\n' "$RED_LINE" > "$R/scripts/zz.sh"; git -C "$R" add -A
printf 'echo ok\n' > "$R/scripts/zz.sh"
gate_case "judges the INDEX: an index-only violation blocks" 1 "$R" "scripts/zz.sh:1"

R=$(mkrepo g-allow-ok); printf '# touched\n' >> "$R/scripts/hooks/pre-commit.d/30-deletion-audit.sh"; git -C "$R" add -A
gate_case "passes a staged exempt file whose two sites are intact" 0 "$R"

R=$(mkrepo g-allow-dup); printf '%s\n' "  while ${I}\$${Q}\\t${Q} read -r _sha _ct; do :; done" >> "$R/scripts/verify-hook-patterns.sh"; git -C "$R" add -A
gate_case "blocks a second line behind a staged file's ALLOW anchor" 1 "$R" "matches 2 hits"

R=$(mkrepo g-allow-gone); sed -i "s/^while ${I}\\\$'\\\\t' read -r added deleted path; do/while read -r added deleted path; do/" "$R/scripts/hooks/pre-commit.d/30-deletion-audit.sh"
git -C "$R" add -A
gate_case "blocks a converted exempt site until its entry is dropped" 1 "$R" "read -r added deleted path is stale"

R=$(mkrepo g-scanner-staged)
sed -i "s/^while ${I}\\\$'\\\\t' read -r added deleted path; do/while read -r added deleted path; do/" "$R/scripts/hooks/pre-commit.d/30-deletion-audit.sh"
git -C "$R" add -A && git -C "$R" commit -q --no-verify -m "site converted, entry left behind"
printf '# touched\n' >> "$R/scripts/lib/tab-ifs-scan.sh"; git -C "$R" add -A
gate_case "scanner staged alone: every ALLOW entry is judged from the index" 1 "$R" "read -r added deleted path is stale"

R=$(mkrepo g-missing); git -C "$R" rm -q --cached scripts/lib/tab-ifs-scan.sh
printf 'echo ok\n' > "$R/scripts/zz.sh"; git -C "$R" add scripts/zz.sh
gate_case "fails CLOSED when the scanner is absent from the index" 1 "$R" "is not in the index"

# The break goes MID-file (after `set -uo pipefail`) — bash parses as it runs, so garbage past the
# scanner's last `exit` would never be reached; the gate's `bash -n` pre-parse is what catches both.
R=$(mkrepo g-broken); sed -i '/^set -uo pipefail$/a if then' "$R/scripts/lib/tab-ifs-scan.sh"; git -C "$R" add -A
gate_case "fails CLOSED on a staged scanner bash cannot parse (mid-file)" 1 "$R" "does not parse"

R=$(mkrepo g-broken-tail); printf 'if then\n' >> "$R/scripts/lib/tab-ifs-scan.sh"; git -C "$R" add -A
gate_case "fails CLOSED on a parse error past the scanner's last exit" 1 "$R" "does not parse"

R=$(mkrepo g-badpat); sed -i 's#^PAT=.*#PAT="(("#' "$R/scripts/lib/tab-ifs-scan.sh"; git -C "$R" add -A
gate_case "fails CLOSED on a staged scanner whose pattern grep rejects" 1 "$R" "exited 2"

R=$(mkrepo g-worktree-broken); printf 'echo ok\n' > "$R/scripts/zz.sh"; git -C "$R" add scripts/zz.sh
sed -i '/^set -uo pipefail$/a if then' "$R/scripts/lib/tab-ifs-scan.sh"
gate_case "a broken WORKTREE scanner over an intact index copy still passes" 0 "$R"

R=$(mkrepo g-noshell); git -C "$R" rm -q --cached scripts/lib/tab-ifs-scan.sh
printf 'notes\n' > "$R/scripts/notes.txt"; git -C "$R" add scripts/notes.txt
gate_case "ignores a missing scanner when no shell file is staged" 0 "$R"

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
