#!/usr/bin/env bash
# probe-deletion-audit-leaf.sh
#
# Regression probe for the binding deletion audit, ported to this repo 2026-09-14:
#   scripts/hooks/pre-commit                          (run-parts dispatcher)
#   scripts/hooks/pre-commit.d/30-deletion-audit.sh   (the leaf under test)
#
# Invariant: the first `git commit` of any deletion-carrying candidate is REFUSED with the
# raw -U0 patch on stderr plus a column-0 `DHX-DELETION-AUDIT-FIRST-SIGHT parent=<sha>`
# sentinel; the byte-identical rerun proceeds with no input; a changed candidate is
# surfaced again; a truncated patch withholds the sentinel (so no scripted retry) but not
# the token (so an interactive rerun still proceeds); addition-only candidates never fire.
# Every arm is MUTATION-CONTROLLED where a false green is possible: case 10 breaks the
# deletion oracle, case 13g breaks the sentinel emission, and both must make the probe RED.
#
# Backs: docs/decisions.md 2026-09-14 row "binding deletion audit ported to the hooks
#        pre-commit chain". Contract it honours (skills-repo rulings, absolute paths):
#        ~/repos/skills/docs/decisions/2026-09-07-pre-commit-deletion-audit-binds-at-the-candidate.md
#        ~/repos/skills/docs/decisions/2026-09-06-u0-patch-is-the-deletion-authority.md
#        ~/repos/skills/docs/decisions/2026-09-12-deletion-audit-first-sight-sentinel-bounded-retry.md
#
# WHY THIS PROBE EXISTS. The leaf is the ONLY runtime enforcement of the deletion-naming
# floor in this repo. Check 4 in ~/repos/skills/dhx-shared/verification/hooks/modify.md
# asserts that PROSE EXISTS in dhx/hooks/SKILL.md — it cannot observe whether a commit was
# audited. If this probe goes green while the leaf is broken, nothing else in the corpus reds.
#
# Strategy: throwaway `git init` repo under mktemp; copy ONLY the dispatcher + this leaf
# (a whole-chain copy would let 05-/10-/11-/20-'s verdicts decide these exit codes); wire
# .git/hooks/pre-commit at the copied dispatcher; drive real `git commit`s.
#
# How to run: bash tests/probes/probe-deletion-audit-leaf.sh
#
# SAFE_FOR_LIVE: yes   (every commit lands in a mktemp fixture; the leaf's firing record is
#                       redirected into the fixture via DHX_DELETION_AUDIT_RECORD_DIR so no
#                       fixture event reaches the live $CLAUDE_CONFIG_DIR/dhx-state sample;
#                       never touches the live repo, its index, history, or .git/hooks)
# RUNTIME: ~5s

set -uo pipefail

PROBE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$PROBE_DIR/../.." && pwd)

# The suite may run as a grandchild of a real `git commit` (check #8 inside the pre-commit
# gate). run-probes.sh already clears these; repeat it so a direct invocation from inside
# a hook context does not point the fixture's git at the outer commit's temp index.
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR

# scripts/run-probes.sh exports DHX_DELETION_AUDIT=off so that a fixture which installs the
# whole chain is never audited. THIS probe must watch the leaf fire, so it opts back in.
# Without this line every refusal assertion below silently inverts and the probe greens
# on a leaf that never ran.
unset DHX_DELETION_AUDIT

PASS=0
FAIL=0
ok()  { echo "OK   $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

LEAF="scripts/hooks/pre-commit.d/30-deletion-audit.sh"
for f in scripts/hooks/pre-commit "$LEAF"; do
  if [ -f "$REPO_ROOT/$f" ]; then ok "present: $f"; else bad "missing: $REPO_ROOT/$f"; echo "$PASS passed, $FAIL failed"; exit 1; fi
done
if [ -x "$REPO_ROOT/$LEAF" ]; then ok "leaf is executable (the dispatcher skips a non-exec leaf)"
else bad "leaf is not executable — the dispatcher would skip it"; fi

# AC-4 of the port brief: the fixture exemption for THIS repo's probe runner.
if grep -qE '^export DHX_DELETION_AUDIT=off' "$REPO_ROOT/scripts/run-probes.sh"; then
  ok "run-probes.sh exports DHX_DELETION_AUDIT=off (whole-chain fixtures stay exempt)"
else
  bad "run-probes.sh does not export DHX_DELETION_AUDIT=off — a whole-chain fixture would red the suite"
fi

FIXTURE=$(mktemp -d) || { echo "FATAL: mktemp failed" >&2; exit 99; }
trap 'rm -rf "$FIXTURE"' EXIT
export DHX_DELETION_AUDIT_RECORD_DIR="$FIXTURE/.record"

git init -q "$FIXTURE"
git -C "$FIXTURE" config user.email probe@example.invalid
git -C "$FIXTURE" config user.name  probe
git -C "$FIXTURE" config commit.gpgsign false

mkdir -p "$FIXTURE/scripts/hooks/pre-commit.d"
cp "$REPO_ROOT/scripts/hooks/pre-commit" "$FIXTURE/scripts/hooks/pre-commit"
cp "$REPO_ROOT/$LEAF"                    "$FIXTURE/scripts/hooks/pre-commit.d/"
chmod +x "$FIXTURE/scripts/hooks/pre-commit" "$FIXTURE/scripts/hooks/pre-commit.d/"*
ln -sf "$FIXTURE/scripts/hooks/pre-commit" "$FIXTURE/.git/hooks/pre-commit"

ERR="$FIXTURE/.probe-stderr"
COMMIT_RC=0
commit_run() { # commit_run <msg> [pathspec...]   (no errexit here — rc is captured, never trapped)
  local msg="$1"; shift
  if [ "$#" -gt 0 ]; then
    git -C "$FIXTURE" commit -q -m "$msg" -- "$@" >/dev/null 2>"$ERR"
  else
    git -C "$FIXTURE" commit -q -m "$msg" >/dev/null 2>"$ERR"
  fi
  COMMIT_RC=$?
}
check() { # check <expected-rc> <actual-rc> <label>
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected rc=$1, got rc=$2)"; fi
}
check_has()   { if grep -qF -- "$2" "$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi; }
check_lacks() { if grep -qF -- "$2" "$1"; then bad "$3 (unexpectedly present: $2)"; else ok "$3"; fi; }
# Column-0 anchored sentinel count on a file. `grep -c` exits 1 on zero matches; that is a
# count, not an error, so the rc is deliberately discarded.
SENT='DHX-DELETION-AUDIT-FIRST-SIGHT '
SENT_RE='^DHX-DELETION-AUDIT-FIRST-SIGHT '
sent_count()   { grep -c -- "$SENT_RE" "$1" 2>/dev/null || true; }
unanch_count() { grep -c -- 'DHX-DELETION-AUDIT-FIRST-SIGHT' "$1" 2>/dev/null || true; }

# --- Case 1: seed. An initial commit has no HEAD; the leaf must not fire. -----------
printf 'alpha\nbeta\ngamma\n' > "$FIXTURE/a.txt"
git -C "$FIXTURE" add a.txt
commit_run 'seed'
check 0 "$COMMIT_RC" "case 1: initial commit (no HEAD) is not audited"

# --- Case 2: an addition-only candidate deletes nothing and passes silently ---------
printf 'one\ntwo\n' > "$FIXTURE/b.txt"
git -C "$FIXTURE" add b.txt
commit_run 'add b'
check 0 "$COMMIT_RC" "case 2: deletion-free candidate passes"
check_lacks "$ERR" "FIRST SIGHT" "case 2: ...and emits no audit surface"

# --- Case 3: a deletion is surfaced and the FIRST attempt is refused ----------------
printf 'alpha\ngamma\n' > "$FIXTURE/a.txt"          # 'beta' removed
git -C "$FIXTURE" add a.txt
commit_run 'delete beta'
check 1 "$COMMIT_RC" "case 3: first sight of a deletion-carrying candidate is refused"
check_has "$ERR" "FIRST SIGHT"        "case 3: the surface is emitted"
check_has "$ERR" "-beta"              "case 3: the removed line appears in the raw -U0 patch"
check_has "$ERR" "text deletions 1"   "case 3: the deletion count is reported"
check_has "$ERR" "blocked by 30-deletion-audit.sh" "case 3: the dispatcher attributes the block to this leaf"

# --- Case 4: the UNCHANGED rerun proceeds with no input (NOT a confirm gate) --------
commit_run 'delete beta'
check 0 "$COMMIT_RC" "case 4: identical rerun proceeds without input"

# --- Case 5: a CHANGED candidate is a new (HEAD,tree) pair and is surfaced again ----
printf 'alpha\n' > "$FIXTURE/a.txt"                 # 'gamma' removed too
git -C "$FIXTURE" add a.txt
commit_run 'delete gamma'
check 1 "$COMMIT_RC" "case 5: a changed candidate is surfaced again"
check_has "$ERR" "-gamma" "case 5: the new deletion is named"
commit_run 'delete gamma'
check 0 "$COMMIT_RC" "case 5: ...and its own rerun proceeds"

# --- Case 6: the `---` trap. A deleted '---' must survive to the patch --------------
# `^---` (no space) eats a deleted `---` (rendered `----`); `^--- ` (with space) keeps it
# but eats a deleted line starting `-- ` (rendered `--- <rest>`). This is why the leaf
# emits the patch RAW and never hand-rolls a `grep '^-'`.
printf -- '---\ntitle: x\n---\nbody\n' > "$FIXTURE/c.md"
git -C "$FIXTURE" add c.md
commit_run 'seed frontmatter'
check 0 "$COMMIT_RC" "case 6: the addition-only seed is not audited"
printf 'title: x\nbody\n' > "$FIXTURE/c.md"          # both --- lines removed
git -C "$FIXTURE" add c.md
commit_run 'strip frontmatter'
check 1 "$COMMIT_RC" "case 6: a deleted '---' fires the audit"
check_has "$ERR" "----" "case 6: the deleted '---' survives raw into the patch as '----'"

# --- Case 6b: the OTHER collision — a deleted `-- ` line renders as `--- <rest>` -------
commit_run 'strip frontmatter'                       # clear case 6
printf -- '-- sql comment\nkeep\n' > "$FIXTURE/e.sql"
git -C "$FIXTURE" add e.sql
commit_run 'seed sql'; commit_run 'seed sql'
printf 'keep\n' > "$FIXTURE/e.sql"                   # the `-- ` line removed
git -C "$FIXTURE" add e.sql
commit_run 'delete sql comment'
check 1 "$COMMIT_RC" "case 6b: a deleted '-- ' line fires the audit"
check_has "$ERR" "--- sql comment" "case 6b: it renders as '--- sql comment' — the shape both filter forms eat"
commit_run 'delete sql comment'
check 0 "$COMMIT_RC" "case 6b: rerun proceeds"

# --- Case 7: pathspec commit audits the TEMP INDEX candidate, not the whole index ---
commit_run 'strip frontmatter'                       # clear case 6
printf 'one\n' > "$FIXTURE/b.txt"                    # 'two' removed  -> pathspec'd
printf 'zeta\n' > "$FIXTURE/d.txt"                   # unrelated, staged but NOT committed
git -C "$FIXTURE" add d.txt
commit_run 'pathspec delete' b.txt
check 1 "$COMMIT_RC" "case 7: pathspec commit is audited"
check_has  "$ERR" "-two"  "case 7: the pathspec'd deletion is in the candidate"
check_lacks "$ERR" "d.txt" "case 7: a path outside the pathspec is NOT in the temp-index candidate"
commit_run 'pathspec delete' b.txt
check 0 "$COMMIT_RC" "case 7: rerun proceeds"

# --- Case 8: the fixture opt-out disables the leaf entirely ------------------------
git -C "$FIXTURE" rm -q --cached d.txt >/dev/null 2>&1 || true
printf 'alpha-only\n' > "$FIXTURE/a.txt"
git -C "$FIXTURE" add a.txt
DHX_DELETION_AUDIT=off git -C "$FIXTURE" commit -q -m 'opt-out' -- a.txt >/dev/null 2>"$ERR"
RC=$?
check 0 "$RC" "case 8: DHX_DELETION_AUDIT=off passes a deletion-carrying candidate"
check_lacks "$ERR" "FIRST SIGHT" "case 8: ...and emits nothing"

# --- Case 9: concurrency. Two DIFFERENT candidates get different tokens ------------
TOKDIR="$FIXTURE/.git/dhx-deletion-audit"
BEFORE=$(find "$TOKDIR" -maxdepth 1 -type f 2>/dev/null | wc -l)
printf 'p\nq\nr\n' > "$FIXTURE/e.txt"; git -C "$FIXTURE" add e.txt
commit_run 'seed e'; commit_run 'seed e'
printf 'p\nr\n' > "$FIXTURE/e.txt"; git -C "$FIXTURE" add e.txt
commit_run 'cand A'
check 1 "$COMMIT_RC" "case 9: candidate A refused on first sight"
printf 'p\n' > "$FIXTURE/e.txt"; git -C "$FIXTURE" add e.txt
commit_run 'cand B'
check 1 "$COMMIT_RC" "case 9: candidate B (different tree) ALSO refused — A's token did not green-light it"
AFTER=$(find "$TOKDIR" -maxdepth 1 -type f 2>/dev/null | wc -l)
if [ "$AFTER" -gt "$BEFORE" ]; then ok "case 9: distinct tokens are written per candidate"
else bad "case 9: expected distinct token files (before=$BEFORE after=$AFTER)"; fi
commit_run 'cand B'
check 0 "$COMMIT_RC" "case 9: candidate B's own rerun proceeds"

# --- Case 10: MUTATION CONTROL on the deletion oracle -------------------------------
MUT="$FIXTURE/scripts/hooks/pre-commit.d/30-deletion-audit.sh"
cp "$MUT" "$FIXTURE/.leaf.bak"
sed -i 's/^TEXT_DELETIONS=0$/TEXT_DELETIONS=0; DHX_MUTANT=1/; s/^if \[ "\$TEXT_DELETIONS" -eq 0 \]/if [ -n "${DHX_MUTANT:-}" ] || [ "$TEXT_DELETIONS" -eq 0 ]/' "$MUT"
if cmp -s "$MUT" "$FIXTURE/.leaf.bak"; then
  bad "case 10: mutation control could not locate the oracle gate — the control is DEAD"
fi
printf 'alpha-only\nsurvivor\n' > "$FIXTURE/a.txt"
git -C "$FIXTURE" add a.txt
commit_run 'mutant seed'; commit_run 'mutant seed'
printf 'alpha-only\n' > "$FIXTURE/a.txt"            # a real deletion
git -C "$FIXTURE" add a.txt
commit_run 'mutant: deletion must NOT be caught'
if [ "$COMMIT_RC" = "0" ]; then
  ok "case 10: mutation control — a broken oracle lets the deletion through (this probe CAN go red)"
else
  bad "case 10: mutation control did not take effect; the assertions above may be inert"
fi
cp "$FIXTURE/.leaf.bak" "$MUT"

# --- Case 11: the firing record ------------------------------------------------------
RECDIR="$FIXTURE/.record.case11"
DHX_DELETION_AUDIT_RECORD_DIR="$RECDIR"
printf 'keep\ngoes-away\n' > "$FIXTURE/rec.txt"
git -C "$FIXTURE" add rec.txt
commit_run 'rec seed'; commit_run 'rec seed'
printf 'keep\n' > "$FIXTURE/rec.txt"
git -C "$FIXTURE" add rec.txt
commit_run 'rec cut'; commit_run 'rec cut'
EVENTS=$(cat "$RECDIR"/*.jsonl 2>/dev/null | sed -n 's/.*"event":"\([a-z]*\)".*/\1/p' | tr '\n' ',')
if [ "$EVENTS" = "surfaced,passed," ]; then ok "case 11: record emits surfaced then passed for one candidate"
else bad "case 11: expected 'surfaced,passed,' got '$EVENTS'"; fi
if cat "$RECDIR"/*.jsonl 2>/dev/null | python3 -c 'import json,sys; [json.loads(l) for l in sys.stdin]' 2>/dev/null; then
  ok "case 11: every record line parses as JSON"
else bad "case 11: record contains a line that is not valid JSON"; fi
REPOF=$(cat "$RECDIR"/*.jsonl 2>/dev/null | python3 -c 'import json,sys; print(json.loads(next(iter(sys.stdin)))["repo"])' 2>/dev/null)
if [ "$REPOF" = "$(git -C "$FIXTURE" rev-parse --show-toplevel)" ]; then ok "case 11: repo carries the absolute toplevel, not the shared basename"
else bad "case 11: repo field '$REPOF' is not the fixture toplevel"; fi
RECBASE=$(basename "$(ls "$RECDIR"/*.jsonl 2>/dev/null | head -n1)")
if [ "$RECBASE" = "$(basename "$FIXTURE").jsonl" ]; then ok "case 11: the record file is named by repo basename (hooks.jsonl in the live repo)"
else bad "case 11: record file '$RECBASE' is not '<basename>.jsonl'"; fi
MUTREC="$FIXTURE/.record.case11b"
printf 'keep\nalso-goes\n' > "$FIXTURE/rec.txt"
git -C "$FIXTURE" add rec.txt
DHX_DELETION_AUDIT_RECORD_DIR="$MUTREC" DHX_DELETION_AUDIT_RECORD=off commit_run 'rec optout'
DHX_DELETION_AUDIT_RECORD_DIR="$MUTREC" DHX_DELETION_AUDIT_RECORD=off commit_run 'rec optout'
if [ "$(cat "$MUTREC"/*.jsonl 2>/dev/null | wc -l)" -eq 0 ]; then ok "case 11: opt-out writes nothing (so case 11's pass is not vacuous)"
else bad "case 11: DHX_DELETION_AUDIT_RECORD=off still wrote records"; fi
DHX_DELETION_AUDIT_RECORD_DIR="$FIXTURE/.record"

# --- Case 12: del_paths is the DELETION set with the candidate blob ------------------
RECDIR12="$FIXTURE/.record.case12"
DHX_DELETION_AUDIT_RECORD_DIR="$RECDIR12"
printf 'keep\ngoes-away\n' > "$FIXTURE/d12.txt"
printf 'first\n'            > "$FIXTURE/a12.txt"
git -C "$FIXTURE" add d12.txt a12.txt
commit_run 'c12 seed'; commit_run 'c12 seed'
printf 'keep\n'             > "$FIXTURE/d12.txt"
printf 'first\nsecond\n'    > "$FIXTURE/a12.txt"
git -C "$FIXTURE" add d12.txt a12.txt
commit_run 'c12 cut'
DELP=$(cat "$RECDIR12"/*.jsonl 2>/dev/null | python3 -c '
import json,sys
for l in sys.stdin:
    o=json.loads(l)
    if o["event"]=="surfaced":
        print(",".join(sorted(e["p"] for e in o["del_paths"]))); break
' 2>/dev/null)
if [ "$DELP" = "d12.txt" ]; then ok "case 12: del_paths is the DELETION set — the addition-only sibling is absent"
else bad "case 12: expected del_paths 'd12.txt', got '$DELP'"; fi
DELB=$(cat "$RECDIR12"/*.jsonl 2>/dev/null | python3 -c '
import json,sys
for l in sys.stdin:
    o=json.loads(l)
    if o["event"]=="surfaced":
        print(o["del_paths"][0]["b"]); break
' 2>/dev/null)
WANTB=$(git -C "$FIXTURE" rev-parse ":d12.txt" 2>/dev/null)
if [ -n "$WANTB" ] && [ "$DELB" = "$WANTB" ]; then ok "case 12: del_paths carries the CANDIDATE blob at full length"
else bad "case 12: blob '$DELB' is not the candidate blob '$WANTB'"; fi
# Renames must record BOTH real endpoints, never git's `old => new` display form.
RECDIR12R="$FIXTURE/.record.case12r"
commit_run 'c12 cut'                                  # clear the candidate above
printf 'r1\nr2\nr3\n' > "$FIXTURE/moved.txt"
git -C "$FIXTURE" add moved.txt
commit_run 'c12 rename seed'; commit_run 'c12 rename seed'
mkdir -p "$FIXTURE/sub12"
git -C "$FIXTURE" mv moved.txt sub12/moved.txt
printf 'r1\nr2\n' > "$FIXTURE/sub12/moved.txt"
git -C "$FIXTURE" add sub12/moved.txt
DHX_DELETION_AUDIT_RECORD_DIR="$RECDIR12R" commit_run 'c12 rename'
RENP=$(cat "$RECDIR12R"/*.jsonl 2>/dev/null | python3 -c '
import json,sys
o=json.loads(next(iter(sys.stdin))); print(",".join(sorted(e["p"] for e in o["del_paths"])))' 2>/dev/null)
case "$RENP" in
  *'=>'*|*'{'*)             bad "case 12: a rename leaked git's display form into del_paths: '$RENP'" ;;
  'moved.txt,sub12/moved.txt') ok "case 12: a rename records BOTH real endpoints, not git's display form" ;;
  *)                        bad "case 12: expected both rename endpoints in del_paths, got '$RENP'" ;;
esac
DHX_DELETION_AUDIT_RECORD_DIR="$RECDIR12R" commit_run 'c12 rename'   # clear
DHX_DELETION_AUDIT_RECORD_DIR="$FIXTURE/.record"

# --- Case 13: THE FIRST-SIGHT SENTINEL ------------------------------------------------
# Consumers pin these bytes: ~/repos/skills/dhx-shared/lib/git-safe.sh git_safe_commit
# (dhx-commit -C ~/repos/hooks) and the backlog committers' shared retry helper. A reword
# here must break them loudly — that is what this case is for.
printf 's1\ns2\ns3\n' > "$FIXTURE/sent.txt"
git -C "$FIXTURE" add sent.txt
commit_run 'c13 seed'; commit_run 'c13 seed'
C13_PARENT=$(git -C "$FIXTURE" rev-parse --verify HEAD)
printf 's1\n' > "$FIXTURE/sent.txt"            # deletes two lines
git -C "$FIXTURE" add sent.txt
commit_run 'c13 first sight' sent.txt
check 1 "$COMMIT_RC" "case 13a: a deletion-carrying candidate is still refused on first sight"
N13=$(sent_count "$ERR")
if [ "$N13" = "1" ]; then ok "case 13a: first-sight refusal emits EXACTLY ONE anchored sentinel line"
else bad "case 13a: expected 1 anchored sentinel line, got $N13"; fi
check_has "$ERR" "${SENT}parent=${C13_PARENT}" \
  "case 13b: the sentinel carries parent=<HEAD at hook time>, the retry's HEAD-unmoved interlock"
# ORDERING: the sentinel follows the final patch line (NOT "is the last stderr line" — the
# dispatcher appends `pre-commit: blocked by …` afterwards). Whole match sets captured, then
# first/last taken by parameter expansion — no early-exit pipe reader (HP-028).
_sl=$(grep -n -- "$SENT_RE" "$ERR" || true); _sl="${_sl%%$'\n'*}"; SENT_LN="${_sl%%:*}"
_dl=$(grep -n '^-' "$ERR" || true); _dl="${_dl##*$'\n'}"; LASTDEL_LN="${_dl%%:*}"
if [ -n "$SENT_LN" ] && [ -n "$LASTDEL_LN" ] && [ "$SENT_LN" -gt "$LASTDEL_LN" ]; then
  ok "case 13c: the sentinel follows the last patch line (line $SENT_LN > $LASTDEL_LN), so its presence implies the full surface"
else
  bad "case 13c: sentinel line '$SENT_LN' does not follow the last patch '-' line '$LASTDEL_LN' (truncation would fail OPEN)"
fi
commit_run 'c13 first sight' sent.txt
check 0 "$COMMIT_RC" "case 13d: the unchanged rerun still proceeds"
N13D=$(sent_count "$ERR")
if [ "$N13D" = "0" ]; then ok "case 13d: the PASSING second sight emits no sentinel"
else bad "case 13d: sentinel leaked onto the passed path ($N13D line(s))"; fi
printf 's1\ns9\n' > "$FIXTURE/sent.txt"
git -C "$FIXTURE" add sent.txt
commit_run 'c13 addition only' sent.txt
check 0 "$COMMIT_RC" "case 13e: an addition-only candidate still passes silently"
N13E=$(sent_count "$ERR")
if [ "$N13E" = "0" ]; then ok "case 13e: an addition-only candidate emits no sentinel"
else bad "case 13e: sentinel emitted on a deletion-free candidate ($N13E line(s))"; fi

# (f) FORGERY CONTROL — column-0 anchoring is load-bearing. A commit that DELETES a line
# quoting the sentinel renders it `-DHX-DELETION-AUDIT-FIRST-SIGHT …` inside the patch.
printf '%sparent=deadbeef\nkeep\n' "$SENT" > "$FIXTURE/quotes.txt"
git -C "$FIXTURE" add quotes.txt
commit_run 'c13 forgery seed'; commit_run 'c13 forgery seed'
printf 'keep\n' > "$FIXTURE/quotes.txt"
git -C "$FIXTURE" add quotes.txt
commit_run 'c13 forgery' quotes.txt
N13F_ANCH=$(sent_count "$ERR")
N13F_UNANCH=$(unanch_count "$ERR")
if [ "$N13F_ANCH" = "1" ] && [ "$N13F_UNANCH" -gt 1 ]; then
  ok "case 13f: a deleted line quoting the sentinel is visible UNANCHORED ($N13F_UNANCH) but the anchored match stays 1 — the anchor is load-bearing"
else
  bad "case 13f: anchored=$N13F_ANCH unanchored=$N13F_UNANCH — expected anchored=1 and unanchored>1"
fi
check_has "$ERR" "-${SENT}parent=deadbeef" "case 13f: the quoting line reaches the patch with git's own '-' prefix"
commit_run 'c13 forgery' quotes.txt   # clear

# (g) MUTATION CONTROL ON THE SENTINEL ITSELF — case 10 would pass vacuously here.
MUT13="$FIXTURE/.mut13-leaf.sh"
cp "$REPO_ROOT/$LEAF" "$MUT13"
if python3 - "$MUT13" <<'MUTPY'
import sys
p=sys.argv[1]; s=open(p).read()
needle="printf 'DHX-DELETION-AUDIT-FIRST-SIGHT parent=%s\\n'"
n=s.count(needle)
if n!=1: sys.exit(1)
open(p,'w').write(s.replace(needle,"printf 'MUTATED-NO-SENTINEL parent=%s\\n'",1))
MUTPY
then
  printf 'm1\nm2\nm3\n' > "$FIXTURE/mut13.txt"
  git -C "$FIXTURE" add mut13.txt
  commit_run 'c13 mut seed'; commit_run 'c13 mut seed'
  printf 'm1\n' > "$FIXTURE/mut13.txt"
  git -C "$FIXTURE" add mut13.txt
  MUTERR="$FIXTURE/.mut13-stderr"
  ( cd "$FIXTURE" && bash "$MUT13" >/dev/null 2>"$MUTERR" )
  MUT13_RC=$?
  N13G=$(sent_count "$MUTERR")
  if [ "$MUT13_RC" = "1" ] && [ "$N13G" = "0" ]; then
    ok "case 13g: mutation control — a reworded sentinel still refuses (rc 1) but emits NO anchored match, so 13a-13f can go RED"
  else
    bad "case 13g: mutation control did not bite (rc=$MUT13_RC, anchored=$N13G) — the sentinel arms may be false-green"
  fi
  commit_run 'c13 mut'; commit_run 'c13 mut'   # clear through the REAL leaf
else
  bad "case 13g: mutation control could not locate the sentinel emission exactly once — the control is DEAD"
fi

# (h) TRUNCATION SUPPRESSES THE SENTINEL but NOT the token.
RECDIR13H="$FIXTURE/.record.case13h"
seq 1 60 | sed 's/^/tline /' > "$FIXTURE/trunc13.txt"
git -C "$FIXTURE" add trunc13.txt
commit_run 'c13h seed'; commit_run 'c13h seed'
printf 'tline 1\n' > "$FIXTURE/trunc13.txt"      # 59 deletions
git -C "$FIXTURE" add trunc13.txt
DHX_DELETION_AUDIT_RECORD_DIR="$RECDIR13H" DHX_DELETION_AUDIT_CAP=3 commit_run 'c13h trunc' trunc13.txt
check 1 "$COMMIT_RC" "case 13h: a truncated candidate is still refused"
check_has "$ERR" "NOT a clean read" "case 13h: the truncation warning is emitted"
N13H=$(sent_count "$ERR")
if [ "$N13H" = "0" ]; then ok "case 13h: a TRUNCATED patch emits NO sentinel, so no scripted caller may retry it unattended"
else bad "case 13h: sentinel emitted alongside a truncated patch ($N13H) — a scripted retry would land a commit whose deletion set nobody saw"; fi
check_has "$ERR" "NO first-sight sentinel emitted" "case 13h: the suppression says WHY"
DHX_DELETION_AUDIT_RECORD_DIR="$RECDIR13H" DHX_DELETION_AUDIT_CAP=3 commit_run 'c13h trunc' trunc13.txt
check 0 "$COMMIT_RC" "case 13h: the INTERACTIVE unchanged rerun still proceeds (suppression withholds the sentinel, not the token)"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
