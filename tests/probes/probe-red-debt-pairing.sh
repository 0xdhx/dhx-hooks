#!/bin/bash
# probe-red-debt-pairing.sh — backs docs/decisions.md 2026-08-23
# "check #8e enforces the GREEN half of a TDD-RED pair".
#
# THE FAILURE THIS EXISTS TO PREVENT:
#
# DHX_RED_COMMIT=1 lets a commit land red on the promise of a paired GREEN.
# Until 2026-08-23 that promise was a sentence in a hook's output with nothing
# behind it. Check #8d closed the inheritance half — an ARMED commit cannot
# commit past a red it did not cause — but check #8 is armed only by dhx/*.js or
# tests/probes/*, so a RED commit followed by commits touching NEITHER never
# re-runs the tier at all. The red is not tolerated; it is invisible. That is
# exactly how 24afeee concealed a dead drift-detector for four days.
#
# #8e runs UNARMED on every commit, re-checks only the roster the RED commit
# recorded in its DHX-Red-Probes: trailer, and escalates warn -> block across a
# grace window.
#
# WHY WARN-THEN-BLOCK AND NOT BLOCK-ON-SIGHT. A hard block on the first
# inherited red freezes the repo on someone else's failure with no escape but
# --no-verify — the 2026-08-19 blast radius that the 2026-08-20 tier split
# exists to prevent. The grace window is the whole design, so BOTH sides of it
# are asserted here (A3 warns and must NOT block; A4 blocks). A probe that
# tested only the block would let the grace silently regress to zero, and a
# probe that tested only the warn would let enforcement silently never arrive.
#
# INVARIANT: an unpaired RED debt cannot go unreported on any commit, armed or
# not; and it cannot block before the grace window nor stay unblocking after it.
#
# Run: bash tests/probes/probe-red-debt-pairing.sh
# SAFE_FOR_LIVE: yes  (every case runs inside a throwaway `git init` repo under
#   mktemp carrying copies of the gate + runner + commit-msg, with fixture probes
#   only; the sole $HOME read is ~/.claude/gsd-core/VERSION to satisfy check #8c
#   inside the fixture; never mutates the live repo, index, history or .git/hooks)
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

sandbox() {
  local t
  t=$(mktemp -d); TMPS+=("$t")
  mkdir -p "$t/scripts/hooks" "$t/tests/probes" "$t/docs" "$t/dhx"
  cp "$REPO/scripts/verify-hook-patterns.sh" "$t/scripts/"
  cp "$REPO/scripts/run-probes.sh" "$t/scripts/"
  cp "$REPO/scripts/verify-multi-cc-results.sh" "$t/scripts/"
  cp "$REPO/scripts/hooks/commit-msg" "$t/scripts/hooks/"
  chmod +x "$t/scripts/verify-hook-patterns.sh" "$t/scripts/verify-multi-cc-results.sh" \
           "$t/scripts/hooks/commit-msg" "$t/scripts/run-probes.sh" 2>/dev/null || true
  : > "$t/docs/hook-patterns.md"
  : > "$t/docs/decisions.md"
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
  ln -sf "$t/scripts/hooks/commit-msg" "$t/.git/hooks/commit-msg"
  printf '%s' "$t"
}

# write_probe <repo> <name> <exit-rc>
write_probe() {
  printf '#!/bin/bash\n# SAFE_FOR_LIVE: yes\n# LIVE_RUNTIME: no\nexit %s\n' "$3" \
    > "$1/tests/probes/$2"
  chmod +x "$1/tests/probes/$2"
}

# red_commit <repo> <days-ago> <roster|-> [reason]
# Lands an empty commit carrying the audit trailers, backdated so #8e's age
# arithmetic can be driven directly. GIT_COMMITTER_DATE is what %ct reads.
red_commit() {
  local t="$1" days="$2" roster="$3" reason="${4:-fixture red half}" msg
  msg="feat(fixture): red half

DHX-Red-Commit: $reason"
  [ "$roster" != "-" ] && msg="$msg
DHX-Red-Probes: $roster"
  GIT_COMMITTER_DATE="$(date -d "$days days ago" --iso-8601=seconds)" \
  GIT_AUTHOR_DATE="$(date -d "$days days ago" --iso-8601=seconds)" \
    git -C "$t" commit -q --allow-empty --no-verify -m "$msg" >/dev/null 2>&1
}

# run_gate <repo> -> sets GOUT / GRC. Stages a NON-probe file so check #8 is
# deliberately UNARMED: that is the whole scenario #8e exists for.
run_gate() {
  local t="$1"
  echo "touched $RANDOM" >> "$t/docs/decisions.md"
  git -C "$t" add docs/decisions.md >/dev/null 2>&1
  GOUT=$(cd "$t" && bash scripts/verify-hook-patterns.sh 2>&1); GRC=$?
}

echo "=== check #8e: unpaired RED debt ==="

# ---- A1: no RED commits at all -> the check is silent ------------------------
TA1=$(sandbox)
run_gate "$TA1"
assert "A1: no RED commit in history -> gate passes (exit 0)" \
  "$([[ "$GRC" -eq 0 ]] && echo true || echo false)"
assert "A1: says nothing about red debt" \
  "$(grep -qi 'shipped red' <<<"$GOUT" && echo false || echo true)"

# ---- A2: RED commit whose roster is now GREEN -> debt paid, silent -----------
TA2=$(sandbox)
write_probe "$TA2" probe-fixture-paid.sh 0
git -C "$TA2" add -f tests/probes/probe-fixture-paid.sh >/dev/null 2>&1
git -C "$TA2" commit -q --no-verify -m "add fixture" >/dev/null 2>&1
red_commit "$TA2" 5 "probe-fixture-paid.sh"
run_gate "$TA2"
assert "A2: roster now green -> gate passes (exit 0)" \
  "$([[ "$GRC" -eq 0 ]] && echo true || echo false)"
assert "A2: a PAID debt is not reported at all (no warn, no block)" \
  "$(grep -qi 'shipped red' <<<"$GOUT" && echo false || echo true)"

# ---- A3: still red, INSIDE the grace window -> WARN, must NOT block ----------
TA3=$(sandbox)
write_probe "$TA3" probe-fixture-owed.sh 1
git -C "$TA3" add -f tests/probes/probe-fixture-owed.sh >/dev/null 2>&1
git -C "$TA3" commit -q --no-verify -m "add fixture" >/dev/null 2>&1
red_commit "$TA3" 0 "probe-fixture-owed.sh" "young debt, still inside grace"
run_gate "$TA3"
assert "A3: inside grace -> does NOT block (exit 0)" \
  "$([[ "$GRC" -eq 0 ]] && echo true || echo false)"
assert "A3: warns rather than blocking" \
  "$(grep -q 'WARNING: a DHX_RED_COMMIT shipped red' <<<"$GOUT" && echo true || echo false)"
assert "A3: names the still-red probe" \
  "$(grep -q 'still red: probe-fixture-owed.sh' <<<"$GOUT" && echo true || echo false)"
assert "A3: surfaces the recorded reason from the trailer" \
  "$(grep -q 'young debt, still inside grace' <<<"$GOUT" && echo true || echo false)"
assert "A3: states that it will block later" \
  "$(grep -qi 'does NOT block yet' <<<"$GOUT" && echo true || echo false)"

# ---- A4: still red, PAST the grace window -> BLOCK ---------------------------
TA4=$(sandbox)
write_probe "$TA4" probe-fixture-owed.sh 1
git -C "$TA4" add -f tests/probes/probe-fixture-owed.sh >/dev/null 2>&1
git -C "$TA4" commit -q --no-verify -m "add fixture" >/dev/null 2>&1
red_commit "$TA4" 5 "probe-fixture-owed.sh" "stale debt, past grace"
run_gate "$TA4"
assert "A4: past grace -> BLOCKS (exit non-zero)" \
  "$([[ "$GRC" -ne 0 ]] && echo true || echo false)"
assert "A4: the refusal is #8e's, not another check's" \
  "$(grep -q 'BLOCKED: a DHX_RED_COMMIT shipped red' <<<"$GOUT" && echo true || echo false)"
assert "A4: reports the debt age in days" \
  "$(grep -qE 'shipped red [0-9]+d ago' <<<"$GOUT" && echo true || echo false)"
assert "A4: offers reverting as the honest exit" \
  "$(grep -qi 'revert' <<<"$GOUT" && echo true || echo false)"
assert "A4: does NOT suggest --no-verify as a fix" \
  "$(grep -q 'no-verify is not' <<<"$GOUT" && echo true || echo false)"

# ---- A5: grace BOUNDARY — exactly at the window is still a warn --------------
# The comparison is `-gt GRACE`, so day 2 warns and day 3 blocks. Pinned because
# an off-by-one here silently converts the grace window into a block-on-sight.
TA5=$(sandbox)
write_probe "$TA5" probe-fixture-owed.sh 1
git -C "$TA5" add -f tests/probes/probe-fixture-owed.sh >/dev/null 2>&1
git -C "$TA5" commit -q --no-verify -m "add fixture" >/dev/null 2>&1
red_commit "$TA5" 2 "probe-fixture-owed.sh"
run_gate "$TA5"
assert "A5: exactly AT the 2-day grace -> still warns, does not block" \
  "$([[ "$GRC" -eq 0 ]] && grep -q 'WARNING: a DHX_RED_COMMIT' <<<"$GOUT" && echo true || echo false)"

TA6=$(sandbox)
write_probe "$TA6" probe-fixture-owed.sh 1
git -C "$TA6" add -f tests/probes/probe-fixture-owed.sh >/dev/null 2>&1
git -C "$TA6" commit -q --no-verify -m "add fixture" >/dev/null 2>&1
red_commit "$TA6" 3 "probe-fixture-owed.sh"
run_gate "$TA6"
assert "A6: one day past grace -> blocks (boundary is 'greater than', not 'at')" \
  "$([[ "$GRC" -ne 0 ]] && grep -q 'BLOCKED: a DHX_RED_COMMIT' <<<"$GOUT" && echo true || echo false)"

# ---- A7: RED commit predating the trailer contract -> noted, never blocking ---
TA7=$(sandbox)
red_commit "$TA7" 5 "-"
run_gate "$TA7"
assert "A7: RED commit with no roster -> does not block" \
  "$([[ "$GRC" -eq 0 ]] && echo true || echo false)"
assert "A7: says the debt cannot be re-checked rather than reporting none" \
  "$(grep -q 'no DHX-Red-Probes: roster' <<<"$GOUT" && echo true || echo false)"

# ---- A8: roster naming a probe deleted since -> not an outstanding debt -------
TA8=$(sandbox)
red_commit "$TA8" 5 "probe-fixture-vanished.sh"
run_gate "$TA8"
assert "A8: roster probe no longer exists -> no debt, gate passes" \
  "$([[ "$GRC" -eq 0 ]] && echo true || echo false)"
assert "A8: a vanished probe is not reported as still red" \
  "$(grep -q 'still red' <<<"$GOUT" && echo false || echo true)"

# ---- A9: outside the lookback window -> not scanned ---------------------------
TA9=$(sandbox)
write_probe "$TA9" probe-fixture-owed.sh 1
git -C "$TA9" add -f tests/probes/probe-fixture-owed.sh >/dev/null 2>&1
git -C "$TA9" commit -q --no-verify -m "add fixture" >/dev/null 2>&1
red_commit "$TA9" 30 "probe-fixture-owed.sh"
run_gate "$TA9"
assert "A9: RED commit older than the 7-day lookback is not scanned (cost guard)" \
  "$([[ "$GRC" -eq 0 ]] && echo true || echo false)"

echo
echo "=== commit-msg: DHX-Red-Probes roster trailer ==="

# ---- B1: pending drop whose stamp matches HEAD -> trailer appended ------------
TB1=$(sandbox)
HEAD_B1=$(git -C "$TB1" rev-parse HEAD)
printf '%s\nprobe-a.sh\nprobe-b.sh\n' "$HEAD_B1" > "$TB1/.git/dhx-red-probes.pending"
MSG_B1="$TB1/msg1.txt"; printf 'feat: thing\n' > "$MSG_B1"
( cd "$TB1" && DHX_RED_COMMIT=1 DHX_RED_COMMIT_REASON="why" bash scripts/hooks/commit-msg "$MSG_B1" ) >/dev/null 2>&1
assert "B1: roster trailer appended when the stamp matches HEAD" \
  "$(grep -q '^DHX-Red-Probes: probe-a.sh probe-b.sh$' "$MSG_B1" && echo true || echo false)"
assert "B1: the reason trailer is still written alongside it" \
  "$(grep -q '^DHX-Red-Commit: why$' "$MSG_B1" && echo true || echo false)"

# ---- B2: STALENESS GUARD — stamp does not match HEAD -> ignored ---------------
# Without this, an abandoned editor leaves a drop on disk that would attach a
# roster to some unrelated commit days later, inventing a debt never incurred.
TB2=$(sandbox)
printf '%s\nprobe-stale.sh\n' "0000000000000000000000000000000000000000" \
  > "$TB2/.git/dhx-red-probes.pending"
MSG_B2="$TB2/msg2.txt"; printf 'feat: unrelated\n' > "$MSG_B2"
( cd "$TB2" && DHX_RED_COMMIT=1 DHX_RED_COMMIT_REASON="why" bash scripts/hooks/commit-msg "$MSG_B2" ) >/dev/null 2>&1
assert "B2: a stale drop (stamp != HEAD) is IGNORED, no roster trailer" \
  "$(grep -q '^DHX-Red-Probes:' "$MSG_B2" && echo false || echo true)"

# ---- B3: inert on an ordinary commit -----------------------------------------
TB3=$(sandbox)
HEAD_B3=$(git -C "$TB3" rev-parse HEAD)
printf '%s\nprobe-a.sh\n' "$HEAD_B3" > "$TB3/.git/dhx-red-probes.pending"
MSG_B3="$TB3/msg3.txt"; printf 'chore: ordinary\n' > "$MSG_B3"
( cd "$TB3" && bash scripts/hooks/commit-msg "$MSG_B3" ) >/dev/null 2>&1
assert "B3: without DHX_RED_COMMIT=1 the hook writes nothing at all" \
  "$(grep -q 'DHX-Red' "$MSG_B3" && echo false || echo true)"

echo
echo "=== run-probes.sh --only (what makes #8e cheap) ==="

# ---- C1: --only narrows the run ----------------------------------------------
TC1=$(sandbox)
write_probe "$TC1" probe-fixture-one.sh 0
write_probe "$TC1" probe-fixture-two.sh 0
OUT_C1=$(cd "$TC1" && bash scripts/run-probes.sh --filter SAFE_FOR_LIVE=yes \
           --only probe-fixture-one.sh 2>&1)
assert "C1: --only runs exactly the named probe" \
  "$(grep -q 'Probes: 1 passed' <<<"$OUT_C1" && echo true || echo false)"

# ---- C2: an unmatched --only is an ERROR, never a quiet clean sweep -----------
# This is the assertion that stops a typo'd or stale roster from reading as
# "debt paid" — the single most dangerous way #8e could fail silently.
TC2=$(sandbox)
write_probe "$TC2" probe-fixture-one.sh 0
( cd "$TC2" && bash scripts/run-probes.sh --filter SAFE_FOR_LIVE=yes \
    --only probe-nope.sh >/dev/null 2>&1 ); RC_C2=$?
assert "C2: --only naming no probe exits 2 rather than reporting a clean sweep" \
  "$([[ "$RC_C2" -eq 2 ]] && echo true || echo false)"

# ---- C3: NEGATIVE CONTROL — the harness can actually observe a block ----------
# A4/A6 assert a non-zero rc. Prove that rc is reachable ONLY via the debt path
# by re-running A4's exact setup with the debt paid: same fixture, same staging,
# same unarmed commit, roster green. If this also blocked, A4 proved nothing.
TC3=$(sandbox)
write_probe "$TC3" probe-fixture-owed.sh 0        # <- the ONLY difference vs A4
git -C "$TC3" add -f tests/probes/probe-fixture-owed.sh >/dev/null 2>&1
git -C "$TC3" commit -q --no-verify -m "add fixture" >/dev/null 2>&1
red_commit "$TC3" 5 "probe-fixture-owed.sh" "stale debt, past grace"
run_gate "$TC3"
assert "C3: [negative control] A4's setup with the roster GREEN passes -> A4's block came from the debt" \
  "$([[ "$GRC" -eq 0 ]] && echo true || echo false)"

echo
echo "=== end-to-end: #8d writes the roster, commit-msg lands it in history ==="

# ---- D1: check #8d writes the sha-stamped handoff ----------------------------
# The link B1 cannot see. If #8d never drops the file, the trailer never appears,
# #8e has no roster, and the whole chain degrades to silence that LOOKS like "no
# debt" — the exact failure mode this arc exists to remove.
TD1=$(sandbox)
write_probe "$TD1" probe-fixture-mine.sh 1
git -C "$TD1" add -f tests/probes/probe-fixture-mine.sh >/dev/null 2>&1
HEAD_D1=$(git -C "$TD1" rev-parse HEAD)
( cd "$TD1" && DHX_RED_COMMIT=1 DHX_RED_COMMIT_REASON="red half" \
    bash scripts/verify-hook-patterns.sh ) >/dev/null 2>&1
assert "D1: #8d drops the roster handoff file" \
  "$([ -f "$TD1/.git/dhx-red-probes.pending" ] && echo true || echo false)"
assert "D1: the drop is stamped with the sha the roster was measured against" \
  "$([ "$(head -1 "$TD1/.git/dhx-red-probes.pending" 2>/dev/null)" = "$HEAD_D1" ] && echo true || echo false)"
assert "D1: the drop names the attributed red probe" \
  "$(tail -n +2 "$TD1/.git/dhx-red-probes.pending" 2>/dev/null | grep -qx 'probe-fixture-mine.sh' && echo true || echo false)"

# ---- D2: a real `git commit` through BOTH hooks lands BOTH trailers ----------
# The only assertion that proves the chain end to end rather than a link at a
# time: pre-commit measures the roster, commit-msg writes it, git stores it, and
# #8e's own reader (git log --format=%(trailers:...)) gets it back.
TD2=$(sandbox)
printf '#!/bin/bash\nexec bash "$(git rev-parse --show-toplevel)/scripts/verify-hook-patterns.sh"\n' \
  > "$TD2/.git/hooks/pre-commit"
chmod +x "$TD2/.git/hooks/pre-commit"
write_probe "$TD2" probe-fixture-e2e.sh 1
git -C "$TD2" add -f tests/probes/probe-fixture-e2e.sh >/dev/null 2>&1
( cd "$TD2" && DHX_RED_COMMIT=1 DHX_RED_COMMIT_REASON="e2e red half" \
    git commit -q -m "test(fixture): red half e2e" ) >/dev/null 2>&1
E2E_RC=$?
assert "D2: the RED commit is accepted by the wired gate" \
  "$([[ "$E2E_RC" -eq 0 ]] && echo true || echo false)"
E2E_ROSTER=$(git -C "$TD2" log -1 --format='%(trailers:key=DHX-Red-Probes,valueonly)' 2>/dev/null | tr -d '\n ')
E2E_REASON=$(git -C "$TD2" log -1 --format='%(trailers:key=DHX-Red-Commit,valueonly)' 2>/dev/null | head -1)
assert "D2: the committed history carries the roster trailer" \
  "$([ "$E2E_ROSTER" = "probe-fixture-e2e.sh" ] && echo true || echo false)"
assert "D2: the committed history carries the reason trailer" \
  "$([ "$E2E_REASON" = "e2e red half" ] && echo true || echo false)"
assert "D2: the bypass is greppable in history, which is the whole audit claim" \
  "$(git -C "$TD2" log --grep='^DHX-Red-Commit:' --format=%H | grep -q . && echo true || echo false)"

# D3 — and now #8e must SEE the debt this very chain just created.
run_gate "$TD2"
assert "D3: #8e picks up the debt the e2e commit just created (warns, inside grace)" \
  "$(grep -q 'WARNING: a DHX_RED_COMMIT shipped red' <<<"$GOUT" && echo true || echo false)"
assert "D3: and names the probe it read back out of the trailer" \
  "$(grep -q 'still red: probe-fixture-e2e.sh' <<<"$GOUT" && echo true || echo false)"

echo
echo "$PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
