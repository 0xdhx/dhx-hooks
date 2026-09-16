#!/bin/bash
# Probe: the symlink loop reads a link's DESTINATION, not just its existence and type
#   (dhx/dhx-health-check.sh, 2026-09-15 second edit).
#
# THE DEFECT THIS PINS. The loop asked two questions of each item — does the path exist
# (`-e`), and outside canonical is it a symlink (`-L`) — and never asked where the symlink
# GOES. A link that exists, is a symlink, and resolves to a decoy (a stale instance dir, an
# old `get-shit-done` path, another lane, a deleted tree) was indistinguishable from a
# healthy one. That is the quiet fault of the set: the two the loop already caught are loud
# by nature, while a wrong-target link resolves cleanly and silently serves a different tree.
# Case [2] is the pre-fix reproduction turned into an assertion, and case [10] is that
# reproduction run against the OLD predicate to prove the fixture discriminates at all.
#
# THE CONTRACT NOW — four counted states plus one exemption:
#   absent                          -> counted (`-e`)
#   dangling link                   -> counted (`-e`, which FOLLOWS the link)
#   real dir/file standing in       -> counted (`! -L`, CCS lanes only)
#   link resolving elsewhere        -> counted (the destination comparison)     <-- new
#   canonical ~/.claude real paths  -> exempt, with no special case in the comparison
#
# THE TWO DESIGN CLAIMS IT EXISTS TO HOLD DOWN, both of which a later "simplification"
# would plausibly undo:
#
#   (a) ULTIMATE REFERENT, not the immediate target — case [9]. The repair primitive
#       (skills scripts/lib/sym-core.sh cmd_link) decides "already correct" by comparing
#       `readlink -f` on both operands. A hook comparing one-level targets would count a
#       link that repair calls correct and refuses to touch, i.e. a PERMANENT false count —
#       the same cry-wolf shape as the 2026-06-05 `get-shit-done` rename and the 2026-08-08
#       `package.json` removal. Case [9] reds if anyone switches to immediate-target
#       comparison; case [8] reds if anyone switches to a lexical compare against
#       "$HOME/.claude/$item", which live canonical already breaks because its own
#       `gsd-local-patches` is a symlink into ~/repos/dotfiles.
#
#   (b) BRANCH ORDER IS LOAD-BEARING — case [4]. Two paths compare EQUAL when both name the
#       same NONEXISTENT final component, so a lane link pointing at an absent canonical item
#       passes the destination comparison and is caught only by the `-e` test that runs
#       first. Deleting or reordering that branch on the theory that the comparison subsumes
#       it makes such a link read as healthy. Case [4b] is the one that holds this down, and
#       it is deliberately narrower than [4]: a link dangling at ANY OTHER path resolves
#       differently from canonical, so the comparison catches it and [4] stays green under a
#       deleted `-e`. Measured, not reasoned — the first draft of this probe asserted the
#       branch-order claim on [4]'s fixture and a mutation run showed it blind.
#
# WHAT THIS PROBE DOES NOT COVER, said plainly: `/dhx:sym repair` cannot fix what case [2]
# counts. The skills-repo per-path audit (cmd_check) reports a decoy-pointing link as a
# healthy `symlink`, so repair never collects the item. Filed as
# ~/repos/skills/.planning/backlog/2026-09-15-sym-audit-check-is-destination-blind.md;
# the manual relink in docs/troubleshooting.md is the working recovery meanwhile.
#
# Backs docs/decisions.md 2026-09-15 symlink-destination-check row.
# Run: bash tests/probes/probe-symlink-target-check.sh
#
# SAFE_FOR_LIVE: yes  (one run-scoped `mktemp -d` root holds every fake $HOME; the hook and
#   the wrapper are spawned with HOME + CLAUDE_CONFIG_DIR pointed inside it, so every
#   ~/.cache/dhx write lands there and the live cache is never read or written. Same
#   isolation pattern as probe-health-lane-scoping.sh.)
# LIVE_RUNTIME: no   (every path resolves under the fake $HOME; the hook's dhx-sym.sh fork
#   verifiers are absent there and take their default branch)
# HERMETIC_TIER: yes (14 hook runs + 1 wrapper spawn + 4 doc-snippet runs; ~4s)
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO/dhx/dhx-health-check.sh"
WRAPPER="$REPO/dhx/statusline-wrapper.js"
RENDERER="$REPO/dhx/dhx-statusline.js"

pass=0; fail=0
ok()  { echo "OK   $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; shift; for l in "$@"; do echo "     $l"; done; fail=$((fail+1)); }
chk() { # chk <name> <got> <want>
  if [[ "$2" == "$3" ]]; then ok "$1 -> $2"; else bad "$1" "got:  $2" "want: $3"; fi
}

# RUN-SCOPED ROOT, deliberately: `make_home` is called as `H="$(make_home)"`, and an
# `arr+=()` inside a command substitution is discarded when the subshell exits, so an EXIT
# trap iterating a registry built that way removes nothing and the probe leaks a tree per
# run at a GREEN exit. One root, removed wholesale, sidesteps the boundary.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

ITEMS=(gsd-core hooks gsd-file-manifest.json gsd-local-patches dhx-tools)

make_home() {
  # mktemp, not a counter: a `_n=$((_n+1))` here dies with the command-substitution
  # subshell, so every "fresh" home would be the same directory and a later fixture would
  # inherit an earlier one's sidecar — turning a real divergence into a pass.
  local h; h="$(mktemp -d "$SCRATCH/home.XXXXXX")"
  mkdir -p "$h/.claude/hooks" "$h/.cache/dhx" "$h/repos/dotfiles/claude" "$h/decoy"
  echo canonical > "$h/repos/dotfiles/claude/CLAUDE.md"
  ln -s "$h/repos/dotfiles/claude/CLAUDE.md" "$h/.claude/CLAUDE.md"
  local i
  for i in "${ITEMS[@]}"; do mkdir -p "$h/.claude/$i"; done
  ln -s "$RENDERER" "$h/.claude/hooks/dhx-statusline.js"
  echo "$h"
}

make_lane() { # make_lane <home> <name>  — every item linked to canonical (healthy)
  local h="$1"
  local l="$h/.ccs/instances/$2"
  mkdir -p "$l"
  local i
  for i in "${ITEMS[@]}"; do ln -s "$h/.claude/$i" "$l/$i"; done
  echo "$l"
}

run_hook() { echo '{}' | HOME="$1" CLAUDE_CONFIG_DIR="$2" bash "$HOOK" >/dev/null 2>&1; }

count_for() { # count_for <home> <lane-id>  — the sidecar's reading, or `none`
  local f="$1/.cache/dhx/health-lane-$2.json"
  [[ -f "$f" ]] || { echo none; return; }
  jq -r '.missing_symlinks // "none"' "$f" 2>/dev/null || echo none
}

reading() { # reading <home> <config_dir> <lane-id>
  run_hook "$1" "$2"
  count_for "$1" "$3"
}

# ===================================================================================
# [1]-[3] THE CRITERION: a decoy-pointing link is counted, and repointing it clears the
#   count. These two halves together are what distinguishes "detects the fault" from
#   "counts everything" — an assertion that only ever goes up would pass on a loop that
#   had been broken to count unconditionally.
# ===================================================================================
H1="$(make_home)"; L1="$(make_lane "$H1" one)"
mkdir -p "$H1/decoy/dhx-tools"

chk "[1] a healthy lane counts nothing" "$(reading "$H1" "$L1" one)" "0"

rm "$L1/dhx-tools"; ln -s "$H1/decoy/dhx-tools" "$L1/dhx-tools"
chk "[2] a link repointed at an EXISTING decoy is counted" "$(reading "$H1" "$L1" one)" "1"

rm "$L1/dhx-tools"; ln -s "$H1/.claude/dhx-tools" "$L1/dhx-tools"
chk "[3] repointing it back clears the count" "$(reading "$H1" "$L1" one)" "0"

# ===================================================================================
# [4]-[6] the three states the loop already caught must SURVIVE the new branch. [4b] is
#   the branch-order case — see claim (b) in the header for why it, and not [4], is the
#   one that reds when `-e` is deleted as redundant.
# ===================================================================================
rm "$L1/dhx-tools"; ln -s "$H1/.claude/no-such-item" "$L1/dhx-tools"
chk "[4] a DANGLING link is still counted" "$(reading "$H1" "$L1" one)" "1"

# [4b] THE BRANCH-ORDER CASE, and it is a DIFFERENT fixture from [4] on purpose. [4]'s link
# dangles at a path that differs from canonical, so the destination comparison catches it
# even with `-e` removed — measured: deleting the `-e` branch leaves [4] GREEN. The hazard
# only bites when the link names the canonical item AND that item is itself absent: both
# operands then resolve EQUAL to the same nonexistent path, the comparison passes, and `-e`
# is the only thing left. Authored after a mutation run showed [4] could not see it.
rm "$L1/dhx-tools"; ln -s "$H1/.claude/dhx-tools" "$L1/dhx-tools"
rm -rf "$H1/.claude/dhx-tools"
chk "[4b] a link naming an ABSENT canonical item is counted (the -e branch, which must run first)" \
    "$(reading "$H1" "$L1" one)" "1"
mkdir -p "$H1/.claude/dhx-tools"

rm "$L1/dhx-tools"; mkdir -p "$L1/dhx-tools"
chk "[5] a REAL DIR standing in for a link is still counted (the ! -L branch)" \
    "$(reading "$H1" "$L1" one)" "1"

rm -rf "$L1/dhx-tools"
chk "[6] an ABSENT item is still counted" "$(reading "$H1" "$L1" one)" "1"

# ===================================================================================
# [7]-[9] the comparison must not FALSE-POSITIVE. This is the direction that matters most
#   here: this loop has twice shipped a permanently-false count (the 2026-06-05 rename, the
#   2026-08-08 package.json removal), and each one trains the operator to ignore the token.
# ===================================================================================
H2="$(make_home)"
chk "[7] canonical's real dirs are exempt with no special case in the comparison" \
    "$(reading "$H2" "$H2/.claude" default)" "0"

# The LIVE shape: canonical's own gsd-local-patches is a symlink into ~/repos/dotfiles.
# A lexical compare against "$HOME/.claude/$item" reds both of the next two.
H3="$(make_home)"
rm -rf "$H3/.claude/gsd-local-patches"
mkdir -p "$H3/repos/dotfiles/claude/gsd-local-patches"
ln -s "$H3/repos/dotfiles/claude/gsd-local-patches" "$H3/.claude/gsd-local-patches"
L3="$(make_lane "$H3" three)"
chk "[8] a lane linking THROUGH an indirect canonical item is healthy" \
    "$(reading "$H3" "$L3" three)" "0"

# ULTIMATE REFERENT: a lane link that skips canonical and names its final target directly
# resolves to the same tree, and the repair primitive calls exactly this "already correct".
# Counting it would emit a fault repair declines to fix — a permanent false count.
rm "$L3/gsd-local-patches"
ln -s "$H3/repos/dotfiles/claude/gsd-local-patches" "$L3/gsd-local-patches"
chk "[9] a link to canonical's ULTIMATE referent is healthy (agrees with cmd_link)" \
    "$(reading "$H3" "$L3" three)" "0"

# ===================================================================================
# [10] NEGATIVE CONTROL — run the PRE-FIX predicate over case [2]'s fixture and require
#   it to report 0. Without this, every assertion above is satisfiable by a loop that
#   counts for some unrelated reason, and the probe cannot tell "the destination check
#   works" from "the fixture is broken in a way that happens to produce 1". The old
#   predicate is materialised HERE rather than by mutating the hook file: a checkout-based
#   mutation restore reverts to HEAD and would wipe this session's uncommitted work.
# ===================================================================================
H4="$(make_home)"; L4="$(make_lane "$H4" four)"
mkdir -p "$H4/decoy/dhx-tools"
rm "$L4/dhx-tools"; ln -s "$H4/decoy/dhx-tools" "$L4/dhx-tools"

old_loop() { # the loop exactly as it stood before 2026-09-15's second edit
  local cdr chr p m=0 item
  cdr="$(readlink -f "$1")"; chr="$(readlink -f "$2")"
  for item in "${ITEMS[@]}"; do
    p="$cdr/$item"
    if [[ ! -e "$p" ]]; then m=$((m + 1))
    elif [[ "$cdr" != "$chr" && ! -L "$p" ]]; then m=$((m + 1)); fi
  done
  echo "$m"
}
chk "[10] NEGATIVE CONTROL: the pre-fix predicate reads the same decoy as healthy" \
    "$(old_loop "$L4" "$H4/.claude")" "0"
chk "[10b] ...while the live hook counts it (the control discriminates)" \
    "$(reading "$H4" "$L4" four)" "1"

# ===================================================================================
# [11] END TO END: the fault has to reach the operator. No other probe covers
#   wrong-target -> rendered token, and a producer that counts into a field nothing
#   renders is a silent detector.
# ===================================================================================
render() { HOME="$1" CLAUDE_CONFIG_DIR="$2" node "$WRAPPER" <<<'{"session_id":"probe","cwd":"/tmp"}' 2>/dev/null; }
out="$(render "$H4" "$L4")"
if grep -q 'symlinks:1' <<<"$out"; then
  ok "[11] a wrong-target link renders as 'symlinks:1' in the advisory tail"
else
  bad "[11] the wrong-target count did not reach the render" \
      "line: $(tr -d '\033' <<<"$out" | tail -c 200)"
fi
# The renamed token is cause-neutral ON PURPOSE: the integer folds four causes and
# "broken" named only one of them. A revert to the old wording reds here.
if grep -q 'broken symlink' <<<"$out"; then
  bad "[11b] the retired 'broken symlink' wording is back" \
      "line: $(tr -d '\033' <<<"$out" | tail -c 200)"
else
  ok "[11b] the token does not claim a cause it cannot know ('broken symlink' absent)"
fi

# ===================================================================================
# [12] THE DOC SNIPPET IS A HAND-KEPT COPY OF THIS LOOP, AND IT DRIFTS. This arm extracts
#   the fence out of docs/troubleshooting.md and RUNS it, rather than trusting that a human
#   kept two copies in step. Four documented wrong labels so far: the 2026-09-15 dhx-tools
#   decisions row records it "was wrong three ways" (a retired `package.json` item, a bare
#   `[[ -L ]]` that called a missing path REAL, and a canonical real dir called drift), and
#   the close-gate reviewer then found a fourth the same day — the canonical branch printed
#   `real` for `gsd-local-patches`, which is itself a symlink into ~/repos/dotfiles.
#
#   ITS OWN INVARIANT, stated because it is broader than this probe's nominal subject: this
#   is the ONLY thing in the corpus that reds when the troubleshooting diagnose snippet and
#   the hook disagree. No other probe reads that fence. If this arm is deleted, the snippet
#   goes back to being prose nobody executes.
#
#   The extraction is the silent-zero risk: a reshaped fence yields an empty script that
#   "agrees" with everything. [12a] is the positive control on the reader itself.
#
#   COUNTED LINES ARE KEYED ON THE UNIFORM `<-- counted` MARKER, and the snippet was made to
#   emit it uniformly for that reason. The first draft of [12b] matched the same string
#   against a snippet that wrote `<-- drift, counted` on one arm, silently undercounted by
#   one, and reported it as a snippet/hook DISAGREEMENT — a matcher bug wearing the costume
#   of the defect this arm exists to find. If a future arm gains a new label, it carries the
#   same marker or this count goes quietly wrong again.
# ===================================================================================
SNIP="$SCRATCH/snippet.sh"
sed -n '/^# The item list MUST match the loop/,/^done$/p' "$REPO/docs/troubleshooting.md" > "$SNIP"
missing_items=0
for i in "${ITEMS[@]}"; do grep -qF -- "$i" "$SNIP" || missing_items=$((missing_items + 1)); done
if [[ -s "$SNIP" ]] && (( missing_items == 0 )) && bash -n "$SNIP" 2>/dev/null; then
  ok "[12a] the diagnose fence extracts, parses, and names all five items"
else
  bad "[12a] the fence reader came back empty or broken — every arm below is vacuous" \
      "bytes: $(wc -c < "$SNIP")  items missing: $missing_items"
fi

# All five states at once, so the comparison is over the whole vocabulary rather than one.
H5="$(make_home)"; L5="$(make_lane "$H5" five)"
mkdir -p "$H5/decoy/dhx-tools"
rm "$L5/dhx-tools";            ln -s "$H5/decoy/dhx-tools" "$L5/dhx-tools"   # WRONG
rm "$L5/gsd-core";             mkdir -p "$L5/gsd-core"                        # REAL
rm "$L5/hooks";                ln -s "$H5/.claude/gone" "$L5/hooks"           # DANGLING
rm "$L5/gsd-file-manifest.json"                                               # MISSING
snip_counted="$(HOME="$H5" CLAUDE_CONFIG_DIR="$L5" bash "$SNIP" | grep -c -- '<-- counted')"
chk "[12b] the snippet's counted lines match the hook's count on a four-fault lane" \
    "$snip_counted" "$(reading "$H5" "$L5" five)"
chk "[12c] ...and on a healthy lane both say zero" \
    "$(HOME="$H5" CLAUDE_CONFIG_DIR="$(make_lane "$H5" six)" bash "$SNIP" | grep -c -- '<-- counted')" \
    "0"

# The fourth wrong label, as an assertion: canonical's own indirect item must not read `real`.
H7="$(make_home)"
rm -rf "$H7/.claude/gsd-local-patches"
mkdir -p "$H7/repos/dotfiles/claude/gsd-local-patches"
ln -s "$H7/repos/dotfiles/claude/gsd-local-patches" "$H7/.claude/gsd-local-patches"
canon_out="$(HOME="$H7" CLAUDE_CONFIG_DIR="$H7/.claude" bash "$SNIP")"
if grep -qE '^link +gsd-local-patches' <<<"$canon_out"; then
  ok "[12d] a canonical item that is ITSELF a symlink is labelled 'link', not 'real'"
else
  bad "[12d] the canonical branch mislabels an indirect item" "got: $(grep gsd-local-patches <<<"$canon_out")"
fi
chk "[12e] ...and canonical still counts nothing, so the verdict never moved" \
    "$(grep -c -- '<-- counted' <<<"$canon_out")" "0"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
