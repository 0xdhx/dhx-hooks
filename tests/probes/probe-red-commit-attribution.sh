#!/bin/bash
# probe-red-commit-attribution.sh
#
# SAFE_FOR_LIVE: yes  (every case runs inside a throwaway `git init` repo under
#                      mktemp, carrying copies of the gate + runner + the
#                      commit-msg hook; the only $HOME read is
#                      ~/.claude/gsd-core/VERSION to satisfy check #8c inside
#                      the fixture; never mutates the live repo, index,
#                      history, or .git/hooks)
# RUNTIME: ~10s
#
# INVARIANT: DHX_RED_COMMIT=1 buys PERMISSION TO BE RED, never a general bypass,
# and never silence. It is honoured only when every probe in the tier's `red:`
# roster is a probe file THIS COMMIT STAGES — the mechanical statement of "a
# TDD-RED commit is red because of its own new assertion".
#
#   green parent shape (reds are all staged)  -> ALLOWED, no friction
#   inherited red (any red not staged)        -> REFUSED, naming the unattributed reds
#   no reason given                           -> REFUSED before the tier runs
#   commit-msg audit hook not wired           -> REFUSED fail-closed
#
# WHY ATTRIBUTION AND NOT A RECONSTRUCTED PARENT. The brief proposed running the
# tier against a `git archive HEAD` export. Measured 2026-08-23 at HEAD a074657,
# against a live tree that is green:
#     git archive HEAD                     -> 4 false reds
#     git worktree add --detach            -> VETOED by the XR-29 reftxn guard
#     git clone --shared                   -> 2 false reds
#     git clone --shared + install-hooks   -> 1 false red, IRREDUCIBLE
# The irreducible one is probe-v1-1-1-gate.sh: it is in the hermetic tier and
# shells out to verify-hooks.sh, which asserts that ~/.claude/hooks/* symlinks
# resolve into /home/dhx/repos/hooks/dhx/. No copy of the repo at any other path
# can satisfy that. Every parent-reconstruction design therefore has a false-red
# floor, and a gate that false-reds refuses LEGITIMATE TDD-RED commits — pushing
# people to `--no-verify`, which is wider AND equally untraceable. Attribution
# needs no reconstruction: it reads the roster of the run that already happened.
#
# Historical discrimination (both directions, real commits):
#   24afeee  staged session-start.sh + registry-prompt.sh + probe-schedule-wiring.sh;
#            reds were RAT-04 / RAT-01 / DRIFT-ALLOW-03 / gsd-diverging-files /
#            drift-detection — none staged  -> REFUSED (it is the one known misuse)
#   f8fbab1  staged two brand-new probe files; those two were the reds -> ALLOWED
#
# Backs: .planning/backlog/2026-08-23-red-commit-optout-is-a-general-untraceable-bypass.md
#
# Run: bash tests/probes/probe-red-commit-attribution.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
PASS=0
FAIL=0
TMPS=()
cleanup() { local t; for t in "${TMPS[@]:-}"; do [ -n "$t" ] && rm -rf "$t"; done; }
trap cleanup EXIT

assert() {
  local name="$1" cond="$2"
  if [[ "$cond" == "true" ]]; then echo "OK   $name"; PASS=$((PASS+1))
  else echo "FAIL $name"; FAIL=$((FAIL+1)); fi
}

# sandbox [wire_audit_hook:yes|no] -> echoes tmp repo path
sandbox() {
  local wire="${1:-yes}" t
  t=$(mktemp -d); TMPS+=("$t")
  mkdir -p "$t/scripts/hooks" "$t/tests/probes" "$t/docs" "$t/dhx"
  cp "$REPO/scripts/verify-hook-patterns.sh" "$t/scripts/"
  cp "$REPO/scripts/run-probes.sh" "$t/scripts/"
  cp "$REPO/scripts/verify-multi-cc-results.sh" "$t/scripts/"
  cp "$REPO/scripts/hooks/commit-msg" "$t/scripts/hooks/" 2>/dev/null || true
  chmod +x "$t/scripts/verify-hook-patterns.sh" "$t/scripts/verify-multi-cc-results.sh" \
           "$t/scripts/hooks/commit-msg" 2>/dev/null || true
  : > "$t/docs/hook-patterns.md"
  : > "$t/docs/decisions.md"
  # check #8c: seed a live-tier stamp matching the installed gsd-core so the
  # freshness branch is satisfied and cannot masquerade as this probe's verdict.
  mkdir -p "$t/tests/probes/.results/live-tier"
  local gv="absent"
  [ -r "$HOME/.claude/gsd-core/VERSION" ] && gv=$(tr -d '[:space:]' < "$HOME/.claude/gsd-core/VERSION")
  printf '{"gsd_version":"%s","ran_at":"1970-01-01T00:00:00Z","passed":0,"failing":[]}\n' \
    "$gv" > "$t/tests/probes/.results/live-tier/status.json"
  git -C "$t" init -q
  git -C "$t" config user.email p@example.invalid
  git -C "$t" config user.name Probe
  git -C "$t" add -A >/dev/null 2>&1
  git -C "$t" commit -q -m base --no-verify >/dev/null 2>&1
  if [ "$wire" = "yes" ] && [ -f "$t/scripts/hooks/commit-msg" ]; then
    ln -sf "$t/scripts/hooks/commit-msg" "$t/.git/hooks/commit-msg"
  fi
  printf '%s' "$t"
}

# write_probe <repo> <name> <exit-rc>
write_probe() {
  printf '#!/bin/bash\n# SAFE_FOR_LIVE: yes\n# LIVE_RUNTIME: no\nexit %s\n' "$3" \
    > "$1/tests/probes/$2"
  chmod +x "$1/tests/probes/$2"
}

echo "=== check #8d: attribution ==="

# ---- CASE 1: every red is staged -> ALLOWED ---------------------------------
T1=$(sandbox yes)
write_probe "$T1" probe-fixture-mine.sh 1          # red, and staged below
git -C "$T1" add -f tests/probes/probe-fixture-mine.sh >/dev/null 2>&1
OUT1=$(cd "$T1" && DHX_RED_COMMIT=1 DHX_RED_COMMIT_REASON="red half of a pair" \
        bash scripts/verify-hook-patterns.sh 2>&1); RC1=$?
assert "1: red caused ONLY by a staged probe -> allowed (exit 0)" \
  "$([[ "$RC1" -eq 0 ]] && echo true || echo false)"
assert "1: says the opt-out was honoured" \
  "$(printf '%s' "$OUT1" | grep -q 'DHX_RED_COMMIT=1 honoured' && echo true || echo false)"
assert "1: names the red it attributed to this commit" \
  "$(printf '%s' "$OUT1" | grep -q 'attributed red: probe-fixture-mine.sh' && echo true || echo false)"

# ---- CASE 2: an inherited red -> REFUSED ------------------------------------
# The shape of 24afeee: a probe IS staged, but the red is somewhere else.
T2=$(sandbox yes)
write_probe "$T2" probe-fixture-mine.sh 0          # staged, and green
write_probe "$T2" probe-fixture-inherited.sh 1     # red, NOT staged
git -C "$T2" add -f tests/probes/probe-fixture-inherited.sh >/dev/null 2>&1
git -C "$T2" commit -q -m "pre-existing red" --no-verify >/dev/null 2>&1
git -C "$T2" add -f tests/probes/probe-fixture-mine.sh >/dev/null 2>&1
OUT2=$(cd "$T2" && DHX_RED_COMMIT=1 DHX_RED_COMMIT_REASON="trying it on" \
        bash scripts/verify-hook-patterns.sh 2>&1); RC2=$?
assert "2: a red this commit does not touch -> REFUSED" \
  "$([[ "$RC2" -ne 0 ]] && echo true || echo false)"
assert "2: names the unattributed red" \
  "$(printf '%s' "$OUT2" | grep -q 'unattributed red: probe-fixture-inherited.sh' && echo true || echo false)"
assert "2: points at diagnosis, never at a wider bypass" \
  "$(printf '%s' "$OUT2" | grep -qi 'no-verify' && echo false || echo true)"
assert "2: does NOT name the staged-but-green probe as unattributed" \
  "$(printf '%s' "$OUT2" | grep -q 'unattributed red: probe-fixture-mine.sh' && echo false || echo true)"

# ---- CASE 3: no reason -> REFUSED, and before the tier runs -----------------
T3=$(sandbox yes)
write_probe "$T3" probe-fixture-mine.sh 1
git -C "$T3" add -f tests/probes/probe-fixture-mine.sh >/dev/null 2>&1
OUT3=$(cd "$T3" && DHX_RED_COMMIT=1 bash scripts/verify-hook-patterns.sh 2>&1); RC3=$?
assert "3: no DHX_RED_COMMIT_REASON -> REFUSED" \
  "$([[ "$RC3" -ne 0 ]] && echo true || echo false)"
assert "3: the refusal names the missing reason" \
  "$(printf '%s' "$OUT3" | grep -q 'DHX_RED_COMMIT_REASON' && echo true || echo false)"
assert "3: refuses BEFORE paying for the tier run" \
  "$(printf '%s' "$OUT3" | grep -q 'Running hermetic probe tier' && echo false || echo true)"

# ---- CASE 4: audit hook not wired -> REFUSED fail-closed --------------------
T4=$(sandbox no)
write_probe "$T4" probe-fixture-mine.sh 1
git -C "$T4" add -f tests/probes/probe-fixture-mine.sh >/dev/null 2>&1
OUT4=$(cd "$T4" && DHX_RED_COMMIT=1 DHX_RED_COMMIT_REASON="red half" \
        bash scripts/verify-hook-patterns.sh 2>&1); RC4=$?
assert "4: commit-msg audit hook unwired -> REFUSED (fail closed)" \
  "$([[ "$RC4" -ne 0 ]] && echo true || echo false)"
assert "4: the refusal prints the installer command" \
  "$(printf '%s' "$OUT4" | grep -q 'install-hooks.sh' && echo true || echo false)"

# ---- CASE 5: opt-out set but the tier is green -> allowed, and says so ------
T5=$(sandbox yes)
write_probe "$T5" probe-fixture-mine.sh 0
git -C "$T5" add -f tests/probes/probe-fixture-mine.sh >/dev/null 2>&1
OUT5=$(cd "$T5" && DHX_RED_COMMIT=1 DHX_RED_COMMIT_REASON="belt and braces" \
        bash scripts/verify-hook-patterns.sh 2>&1); RC5=$?
assert "5: green tier under the opt-out -> allowed" \
  "$([[ "$RC5" -eq 0 ]] && echo true || echo false)"
assert "5: tells the operator the opt-out was unnecessary" \
  "$(printf '%s' "$OUT5" | grep -q 'was unnecessary' && echo true || echo false)"

echo
echo "=== commit-msg: the bypass leaves a trace in history ==="

# msg_case <repo> <env-reason|""> <message-body> -> MRC / MOUT / MFILE contents
MRC=0; MOUT=""; MBODY=""
msg_case() {
  local t="$1" reason="$2" body="$3" f
  f="$t/.git/COMMIT_EDITMSG_probe"
  printf '%s\n' "$body" > "$f"
  if [ -n "$reason" ]; then
    MOUT=$(cd "$t" && DHX_RED_COMMIT=1 DHX_RED_COMMIT_REASON="$reason" bash scripts/hooks/commit-msg "$f" 2>&1); MRC=$?
  else
    MOUT=$(cd "$t" && DHX_RED_COMMIT=1 bash scripts/hooks/commit-msg "$f" 2>&1); MRC=$?
  fi
  MBODY=$(cat "$f")
}

T6=$(sandbox yes)

msg_case "$T6" "" "test(x): a RED probe"
assert "6: DHX_RED_COMMIT=1 with no trailer and no reason -> REFUSED" \
  "$([[ "$MRC" -ne 0 ]] && echo true || echo false)"
assert "6: the refusal names the required trailer" \
  "$(printf '%s' "$MOUT" | grep -q 'DHX-Red-Commit:' && echo true || echo false)"

msg_case "$T6" "target machinery does not exist yet" "test(x): a RED probe"
assert "7: a reason in the env APPENDS the trailer and passes" \
  "$([[ "$MRC" -eq 0 ]] && echo true || echo false)"
assert "7: the trailer carries the reason verbatim" \
  "$(printf '%s' "$MBODY" | grep -q '^DHX-Red-Commit: target machinery does not exist yet$' && echo true || echo false)"

msg_case "$T6" "" "test(x): a RED probe

DHX-Red-Commit: hand-written reason"
assert "8: an already-present trailer passes untouched" \
  "$([[ "$MRC" -eq 0 ]] && echo true || echo false)"
assert "8: the trailer is not duplicated" \
  "$([[ "$(printf '%s' "$MBODY" | grep -c '^DHX-Red-Commit:')" -eq 1 ]] && echo true || echo false)"

msg_case "$T6" "" "DHX-Red-Commit:   "
assert "9: an EMPTY trailer reason is refused (a blank reason is not a reason)" \
  "$([[ "$MRC" -ne 0 ]] && echo true || echo false)"

# no opt-out at all -> the hook is inert
MF="$T6/.git/COMMIT_EDITMSG_probe"
printf 'chore: ordinary commit\n' > "$MF"
OUT10=$(cd "$T6" && bash scripts/hooks/commit-msg "$MF" 2>&1); RC10=$?
assert "10: without DHX_RED_COMMIT the hook is a silent no-op" \
  "$([[ "$RC10" -eq 0 ]] && [ -z "$OUT10" ] && echo true || echo false)"
assert "10: and it does not inject a trailer" \
  "$(grep -q 'DHX-Red-Commit' "$MF" && echo false || echo true)"

# ---- CASE 11: greppability — the whole point of the trailer ----------------
assert "11: the trailer shape is git-log --grep-able" \
  "$(printf 'x\n\nDHX-Red-Commit: why\n' | grep -qE '^DHX-Red-Commit: .+$' && echo true || echo false)"

echo "---"
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
