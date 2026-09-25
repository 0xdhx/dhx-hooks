#!/usr/bin/env bash
# probe-sigpipe-pipefail-shapes.sh — static lint enforcing the HP-028 invariant
#
# Invariant: no shell file under `dhx/`, `dhx-plugin/plugins/dhx/hooks/`, `scripts/` or
# `tests/` pipes into an EARLY-EXIT reader — grep / egrep / fgrep / rg carrying -q, -m,
# --quiet, --silent or --max-count, in any spelling or argument position — outside a
# line carrying the literal HP-028. Under `set -o pipefail`, when the reader exits
# before the producer finishes writing, the producer takes SIGPIPE, the pipeline exits
# 141, and the surrounding `if` silently takes the wrong arm.
#
# The failure is NOT symmetric, which is why it survived so long unseen. In an
# `if cmd | grep -q X` the fail-open reads as "no match" and the probe reports
# a false RED, which someone investigates. In the INVERTED shapes —
# `! cmd | grep -q X`, or `cmd | grep -q X && check fail || check pass` — the
# fail-open takes the passing arm, so the guard reports itself HOLDING exactly
# when the thing it forbids is present. That is a false GREEN, and nothing
# looks at it. 21 of the 122 sites converted on 2026-09-18 were that shape.
#
# Reader scope: early-exit readers only, MEASURED 2026-09-25 with
# `timeout 3 bash -c 'yes | R'` (141 = quit early, 124 = read everything): grep -q,
# grep -m1, rg -q, rg -m1, rg --quiet quit early; grep -l, --files-with-matches, -c and
# -L read everything and are not flagged. `head -N`, `awk '/PAT/{exit}'` and
# `sed '/PAT/q'` also quit early (all 141) but stay out by design: they are
# overwhelmingly capture contexts (`$(... | head -1)`, often `|| true`) where the
# pipeline status never reaches control flow, and a line lint cannot tell capture from
# test. HP-028 documents the broader class; this lint enforces the truth-signal readers.
#
# THE DETECTOR is scripts/lib/hp028-scan.awk — ONE file, shared with the commit gate
# (scripts/verify-hook-patterns.sh check #5, `lint_hp028_staged`, which runs it from its
# STAGED copy and fails closed). Neither consumer carries its own pattern.
#
# History, because each step was a spelling mistaken for a shape:
#   - April 2026 – 2026-09-18: scanned `dhx/` ALONE and reported "audit closed" while
#     191 sites accumulated one directory over; roots widened to three and driven to
#     zero the same day (decisions.md 2026-09-18 rows).
#   - until 2026-09-25: the shape was one regex, `[^|]\| *grep -[qm]`, requiring the
#     flag IMMEDIATELY after `grep`, and the file net was `--include='*.sh'`. So
#     `grep -Eq`, `grep -Fxq`, `grep -qE`, `grep -E -q`, `command grep -q`, argument-
#     permuted `grep -e PAT -q` and the suffix-less scripts/hooks/commit-msg were all
#     invisible — 10 live sites, one of them the inverted `!` shape — while this probe
#     printed "invariant holds". The gate's copy had drifted further (`| *grep -[qm]`,
#     staged `dhx/*.sh` only). Both now use the scanner (decisions.md 2026-09-25 row).
#
# Cells, so the probe cannot pass by being blind:
#   [net]   per-root file floors + scanner present + the suffix-less git hook in the net
#   [tree]  zero hits over the real tree
#   [red]   one per spelling class — each must flag exactly once
#   [clean] shapes that are correct or not early-exit — each must flag nothing
#   [netfx] fixture repo: a shebang-only file is scanned, a non-shell file is not
#   [gate]  fixture repos driving lint_hp028_staged: blocks a staged scripts/ site, passes
#           a clean one, reads the scanner from the INDEX not the worktree, fails CLOSED
#           on a missing or broken staged scanner, and ignores a missing scanner when
#           no shell file is staged
#
# Exemption: an `HP-028` token on the line — the visible marker for a fixture that
# CONSTRUCTS the broken form on purpose (probe-deferred-check-canonical-classifier.sh
# 6.5, probe-pii-gate-fail-open.sh). A sweep that "fixes" either disarms it silently.
#
# Backs:
#   - docs/decisions.md — 2026-04-28 rows (audit sweep rounds 1+2, static lint)
#   - docs/decisions.md — 2026-09-18 rows (scan roots widened; 191 -> 122 -> 0)
#   - docs/decisions.md — 2026-09-25 row (shared scanner; spelling holes; 10 converted)
#   - docs/hook-patterns.md — HP-028
#
# Run: bash tests/probes/probe-sigpipe-pipefail-shapes.sh
# Exit 0 = invariant holds and every cell behaves, 1 = otherwise.

# SAFE_FOR_LIVE: yes   (static lint over in-repo shell files + mktemp fixture repos; no writes to the repo)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# DHX_PROBE_HP028_SCANNER: mutation seam — point every cell (fixtures included) at a mutant.
SCANNER="${DHX_PROBE_HP028_SCANNER:-$REPO_ROOT/scripts/lib/hp028-scan.awk}"
GATE="$REPO_ROOT/scripts/verify-hook-patterns.sh"
ROOTS=(dhx dhx-plugin/plugins/dhx/hooks scripts tests)

PASS=0
FAIL=0
ok()  { echo "OK   $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL $1${2:+ — $2}"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The net: tracked + untracked-not-ignored files under the roots that are shell — `*.sh`
# or a shell shebang. Mechanism, not a spelling: a suffix-less hook is shell by its
# first line. Run from the repo root given as $1.
net_files() {
  local root=$1 f first
  while IFS= read -r f; do
    [[ -f "$root/$f" && ! -L "$root/$f" ]] || continue
    case "$f" in */.inactive/*|*/.planned/*) continue ;; esac
    if [[ "$f" == *.sh ]]; then printf '%s\n' "$f"; continue; fi
    first=""; IFS= read -r first < "$root/$f" 2>/dev/null || true
    [[ "$first" =~ ^\#!.*[/[:space:]](ba|z|k|da)?sh([[:space:]]|$) ]] && printf '%s\n' "$f"
  done < <(git -C "$root" ls-files --cached --others --exclude-standard -- "${ROOTS[@]}" 2>/dev/null)
}

scan_line() { awk -f "$SCANNER" <<<"$1" | awk 'END { print NR }'; }

# ── [net] ─────────────────────────────────────────────────────────────────────────
[ -s "$SCANNER" ] && ok "[net] scanner present: scripts/lib/hp028-scan.awk" \
  || { bad "[net] scanner present" "scripts/lib/hp028-scan.awk missing — every cell below is inert"; echo; echo "$PASS passed, $FAIL failed"; exit 1; }

FILES=$(net_files "$REPO_ROOT")
declare -A FLOOR=([dhx]=40 [dhx-plugin/plugins/dhx/hooks]=2 [scripts]=15 [tests]=100)
for r in "${ROOTS[@]}"; do
  n=0
  while IFS= read -r f; do [[ "$f" == "$r/"* ]] && n=$((n + 1)); done <<<"$FILES"
  [ "$n" -ge "${FLOOR[$r]}" ] && ok "[net] covers $r/ ($n shell files >= floor ${FLOOR[$r]})" \
    || bad "[net] covers $r/" "$n shell files < floor ${FLOOR[$r]} — the file listing is broken, the scan is inert"
done
[[ $'\n'"$FILES"$'\n' == *$'\n'"scripts/hooks/commit-msg"$'\n'* ]] \
  && ok "[net] suffix-less scripts/hooks/commit-msg is in the net (shebang)" \
  || bad "[net] suffix-less scripts/hooks/commit-msg is in the net" "the shebang half of the net is broken"

# ── [tree] ────────────────────────────────────────────────────────────────────────
HITS=""
if [ -n "$FILES" ]; then
  HITS=$(cd "$REPO_ROOT" && xargs -d '\n' awk -f "$SCANNER" <<<"$FILES")
fi
if [ -z "$HITS" ]; then
  ok "[tree] no early-exit-reader pipes in dhx/, the plugin hooks, scripts/ or tests/ (HP-028 invariant holds)"
else
  while IFS= read -r h; do bad "[tree] $h"; done <<<"$HITS"
  echo
  echo "HP-028 — SIGPIPE+pipefail breaks a pipe into an early-exit reader (grep/egrep/"
  echo "fgrep/rg with -q, -m, --quiet, --silent or --max-count) when the reader exits"
  echo "before the producer finishes. Replace, BY PRODUCER:"
  echo "  grep -q PAT <<<\"\$VAR\"                 # echo \"\$VAR\" or printf '%s\\n' \"\$VAR\""
  echo "  grep -q PAT < <(printf '%s' \"\$VAR\")   # printf '%s' — NO trailing newline"
  echo "  grep -q PAT < <(cmd args)              # any command output"
  echo
  echo "The producer decides. 'echo \"\$V\"' and 'printf '%s\\n' \"\$V\"' both emit"
  echo "\"\$V\\n\", byte-identical to a here-string (unless \$V is an echo option"
  echo "like -n). 'printf '%s' \"\$V\"' emits NO trailing newline — a here-string there"
  echo "silently changes the matched input. See docs/hook-patterns.md HP-028."
  echo "A deliberate construction of the broken form is exempted by HP-028 on the line."
fi

# ── [red] — each spelling must flag exactly once ─────────────────────────────────
# Every case is a quoted string (invisible to the scanner when it reads THIS file) and
# carries HP-028 on its source line besides, so this probe never trips itself.
RED=(
  'x | grep -q a'                         # HP-028 fixture: baseline
  'x | grep -Eq a'                        # HP-028 fixture: flag cluster, q last
  'x | grep -qE a'                        # HP-028 fixture: flag cluster, q first
  'x | grep -E -q a'                      # HP-028 fixture: later flag
  'x | grep -e a -q'                      # HP-028 fixture: permuted after -e PAT
  "x | grep -E 'a|b' -q"                  # HP-028 fixture: permuted after a quoted pipe
  'x | grep -A 3 -q a'                    # HP-028 fixture: after a valued option
  "x | grep --regexp='^m' --quiet"        # HP-028 fixture: long options
  'x | grep -m1 a'                        # HP-028 fixture: -m with count
  'x | grep --max-count=1 a'              # HP-028 fixture: --max-count=
  'x | command grep -q a'                 # HP-028 fixture: command prefix (the filed hole)
  'x | env grep -q a'                     # HP-028 fixture: env prefix
  'x | /usr/bin/grep -q a'                # HP-028 fixture: absolute path
  'x | \grep -q a'                        # HP-028 fixture: backslash
  'x | "grep" -q a'                       # HP-028 fixture: quoted command word
  'x | egrep -q a'                        # HP-028 fixture: egrep
  'x | rg -q a'                           # HP-028 fixture: ripgrep
  'x |& grep -q a'                        # HP-028 fixture: |&
  'x | tee f | grep -q a'                 # HP-028 fixture: later stage
  'x | { grep -q a; }'                    # HP-028 fixture: brace group
  'v="$(x | grep -m1 a)"'                 # HP-028 fixture: $() inside double quotes
  'if ! x | grep -qF a; then :; fi'       # HP-028 fixture: inverted shape
  $'x |\n  grep -q a'                     # HP-028 fixture: trailing-pipe continuation
  $'x | grep \\\n  -q a'                  # HP-028 fixture: backslash continuation
)
for c in "${RED[@]}"; do
  n=$(scan_line "$c")
  [ "$n" = 1 ] && ok "[red] flags: ${c//$'\n'/⏎}" || bad "[red] flags: ${c//$'\n'/⏎}" "scanner reported $n hit(s), want 1"
done

# ── [clean] — correct or non-early-exit shapes must flag nothing ─────────────────
CLEAN=(
  'x || grep -q a'                        # logical OR, not a pipe
  'grep -q a <<<"$x"'                     # the canonical fix, here-string
  'grep -q a < <(x)'                      # the canonical fix, process substitution
  'x | grep -c a'                         # -c reads everything
  'x | grep -l a'                         # -l reads everything on stdin (measured)
  'x | command grep -F a'                 # no early-exit flag
  'x | grep -i a | head -1'               # head is out of scope by design
  'echo "text | grep -q ok"'              # pipe inside a string
  'x | grep -F -- -q'                     # -q after -- is a pattern
  'x | xargs grep -q a'                   # reader of files, not the pipe
  'x | grep -c a # | grep -q in a comment' # trailing comment
  '# x | grep -q a'                       # whole-line comment
)
for c in "${CLEAN[@]}"; do
  n=$(scan_line "$c")
  [ "$n" = 0 ] && ok "[clean] ignores: $c" || bad "[clean] ignores: $c" "scanner reported $n hit(s), want 0"
done
n=$(scan_line 'x | grep -q a # HP-028 deliberate')   # HP-028 fixture: the exemption token
[ "$n" = 0 ] && ok "[clean] HP-028 token exempts its line" || bad "[clean] HP-028 token exempts its line" "$n hit(s)"

# ── fixture repo helper ──────────────────────────────────────────────────────────
mkrepo() {
  local d="$TMP/$1"
  mkdir -p "$d/scripts/lib" "$d/scripts/hooks" "$d/dhx"
  git -C "$d" init -q
  git -C "$d" config user.email probe@example.invalid
  git -C "$d" config user.name probe
  printf '%s\n' "$d"
}
RED_LINE='x | grep -Eq a'                 # HP-028 fixture: payload written into fixture files

# ── [netfx] — a shebang-only file is scanned, a non-shell file is not ───────────
R=$(mkrepo netfx)
printf '#!/usr/bin/env bash\n%s\n' "$RED_LINE" > "$R/scripts/hooks/suffixless"
printf 'plain text\n%s\n' "$RED_LINE" > "$R/scripts/notes.txt"
NF=$(net_files "$R")
[[ $'\n'"$NF"$'\n' == *$'\n'scripts/hooks/suffixless$'\n'* ]] && ok "[netfx] shebang-only file is in the net" \
  || bad "[netfx] shebang-only file is in the net" "net: ${NF:-<empty>}"
[[ $'\n'"$NF"$'\n' != *$'\n'scripts/notes.txt$'\n'* ]] && ok "[netfx] non-shell file stays out of the net" \
  || bad "[netfx] non-shell file stays out of the net" "net: $NF"

# ── [gate] — drive lint_hp028_staged in fixture repos ────────────────────────────
# Sourced in a subshell from inside the fixture (the gate cds to the toplevel); the
# DHX_SKIP_SET_FLAG_LINT_TESTS guard stops sourcing before any gate check runs.
run_gate() {
  ( cd "$1" && export DHX_SKIP_SET_FLAG_LINT_TESTS=1 && source "$GATE" >/dev/null 2>&1 && FAIL=0 \
      && lint_hp028_staged ) >/dev/null 2>"$TMP/gate.err"
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

R=$(mkrepo g-block); cp "$SCANNER" "$R/scripts/lib/hp028-scan.awk"
printf '#!/usr/bin/env bash\n%s\n' "$RED_LINE" > "$R/scripts/hooks/suffixless"
git -C "$R" add -A
gate_case "blocks a staged suffix-less scripts/ hook carrying the shape" 1 "$R" "scripts/hooks/suffixless:2"

R=$(mkrepo g-clean); cp "$SCANNER" "$R/scripts/lib/hp028-scan.awk"
printf '#!/usr/bin/env bash\ngrep -Eq a <<<"$x"\n' > "$R/scripts/ok.sh"
git -C "$R" add -A
gate_case "passes a staged clean shell file" 0 "$R"

R=$(mkrepo g-index); cp "$SCANNER" "$R/scripts/lib/hp028-scan.awk"
printf '#!/usr/bin/env bash\ngrep -Eq a <<<"$x"\n' > "$R/dhx/ok.sh"
git -C "$R" add -A
printf 'BEGIN { this is not awk\n' > "$R/scripts/lib/hp028-scan.awk"    # worktree broken, index intact
gate_case "runs the scanner from the INDEX (a broken worktree copy does not change the verdict)" 0 "$R"

R=$(mkrepo g-missing)
printf '#!/usr/bin/env bash\ngrep -Eq a <<<"$x"\n' > "$R/dhx/ok.sh"
git -C "$R" add -A
gate_case "fails CLOSED when the scanner is not in the index" 1 "$R" "not in the index"

R=$(mkrepo g-broken)
printf 'BEGIN { this is not awk\n' > "$R/scripts/lib/hp028-scan.awk"
printf '#!/usr/bin/env bash\ngrep -Eq a <<<"$x"\n' > "$R/dhx/ok.sh"
git -C "$R" add -A
gate_case "fails CLOSED when the staged scanner makes awk error" 1 "$R" "fails on"

R=$(mkrepo g-noshell)
printf 'notes\n' > "$R/scripts/notes.txt"
git -C "$R" add -A
gate_case "no staged shell file: a missing scanner does not block" 0 "$R"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
