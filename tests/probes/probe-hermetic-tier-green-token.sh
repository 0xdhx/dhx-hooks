#!/bin/bash
# probe-hermetic-tier-green-token.sh
#
# SAFE_FOR_LIVE: yes  (every case runs inside a throwaway `git init` repo under
#                      mktemp carrying COPIES of the gate + the REAL run-probes.sh
#                      behind a logging wrapper + verify-multi-cc-results.sh; the
#                      only $HOME read is ~/.claude/gsd-core/VERSION to satisfy
#                      check #8c inside the fixture; never touches the live repo,
#                      its index, history, hooks, or its dhx-probe-tier tokens)
# RUNTIME: ~5s
#
# INVARIANT: check #8a's green token is a record of an OBSERVED GREEN on
# identical in-tree state — HEAD + candidate tree + a forced worktree snapshot
# (every tracked path, plus untracked/ignored files under the probe input
# roots, minus tests/probes/.results/) + git config/hooks.
#
#   green run                      -> tier runs once, token written
#   byte-identical rerun           -> tier NOT run, hit line printed, exit 0
#   staged tree changed            -> tier runs again (new key)
#   worktree-only edit, index same -> tier runs again (the runner reads the
#                                     WORKTREE, so the candidate alone is not
#                                     the key — measured 2026-09-14)
#   probe hidden by info/exclude   -> tier runs again (`add -A -f` sees it)
#   hooks dir changed              -> tier runs again (git-meta term)
#   untracked file under reports/  -> still a hit (outside the input roots);
#                                     a TRACKED edit anywhere re-runs
#   red run                        -> no token; identical rerun re-runs
#   DHX_RED_COMMIT=1 + green       -> tier runs, token written; identical
#                                     rerun under the flag HITS (one rule, no
#                                     carve-out — ruled 2026-09-14)
#   token older than the TTL       -> tier runs; DHX_PROBE_TIER_TTL=0 / off
#                                     force a run past a fresh token
#   the gate's own indexes         -> the real index is untouched by the key
#   MUTATION CONTROL               -> a gate whose snapshot term is a constant
#                                     wrongly HITS on a changed worktree, so
#                                     the worktree-edit case would go red
#
# Why the REAL runner and not a stub: the runner writes outcome JSON under
# tests/probes/.results/ during a run, which is exactly the churn the key must
# exclude to ever hit — a stub cannot show that (adversarial pass, round 1,
# reports/2026-09-14-hermetic-tier-token-presteer-codex/).
#
# Backs: docs/decisions.md 2026-09-14 hermetic-tier green-token row.
# Run: bash tests/probes/probe-hermetic-tier-green-token.sh
set -uo pipefail
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR
unset DHX_PROBE_TIER_TTL DHX_RED_COMMIT DHX_RED_COMMIT_REASON

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
PASS=0
FAIL=0
TMPS=()
cleanup() { local t; for t in "${TMPS[@]:-}"; do [ -n "$t" ] && rm -rf "$t" "$t.invocations"; done; }
trap cleanup EXIT

assert() {
  local name="$1" cond="$2"
  if [[ "$cond" == "true" ]]; then echo "OK   $name"; PASS=$((PASS+1))
  else echo "FAIL $name"; FAIL=$((FAIL+1)); fi
}
has() { grep -qF -- "$1" <<<"$2" && echo true || echo false; }

# sandbox -> echoes tmp repo path. The invocation log lives OUTSIDE the tree at
# "$t.invocations" — inside it, the log itself would change the key every run.
sandbox() {
  local t
  t=$(mktemp -d); TMPS+=("$t")
  mkdir -p "$t/scripts/hooks" "$t/tests/probes" "$t/docs" "$t/dhx"
  cp "$REPO/scripts/verify-hook-patterns.sh" "$t/scripts/"
  mkdir -p "$t/scripts/lib" && cp "$REPO/scripts/lib/hp028-scan.awk" "$t/scripts/lib/"   # check #5 detector; the gate fails CLOSED without it
  cp "$REPO/scripts/run-probes.sh" "$t/scripts/run-probes.real.sh"
  cp "$REPO/scripts/verify-multi-cc-results.sh" "$t/scripts/"
  cp "$REPO/scripts/hooks/commit-msg" "$t/scripts/hooks/" 2>/dev/null || true
  printf '#!/bin/bash\n# logging wrapper: one line per tier invocation, then the REAL runner\necho "invoked $*" >> "%s"\nexec bash "$(dirname "$0")/run-probes.real.sh" "$@"\n' \
    "$t.invocations" > "$t/scripts/run-probes.sh"
  chmod +x "$t/scripts/verify-hook-patterns.sh" "$t/scripts/run-probes.sh" \
           "$t/scripts/run-probes.real.sh" "$t/scripts/verify-multi-cc-results.sh" \
           "$t/scripts/hooks/commit-msg" 2>/dev/null || true
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
  : > "$t.invocations"
  printf '%s' "$t"
}

# write_probe <repo> <name> <exit-rc>
write_probe() {
  printf '#!/bin/bash\n# SAFE_FOR_LIVE: yes\n# LIVE_RUNTIME: no\nexit %s\n' "$3" > "$1/tests/probes/$2"
  chmod +x "$1/tests/probes/$2"
}
# gate <repo> [env assignments...] -> GOUT / GRC
gate() { local t="$1"; shift; GOUT=$(cd "$t" && env "$@" bash scripts/verify-hook-patterns.sh 2>&1); GRC=$?; }
invocations() { wc -l < "$1.invocations" | tr -d ' '; }
tokens() { find "$1/.git/dhx-probe-tier" -maxdepth 1 -type f ! -name '*.tmp.*' 2>/dev/null | wc -l | tr -d ' '; }
HIT='identical rerun, not re-run'

echo "=== check #8a: green token ==="

# ---- 1. green run writes a token; identical rerun hits ----------------------
T1=$(sandbox)
write_probe "$T1" probe-fixture-green.sh 0
git -C "$T1" add -f tests/probes/probe-fixture-green.sh >/dev/null 2>&1
STAGED_BEFORE=$(git -C "$T1" diff --cached --name-only)
gate "$T1"
assert "1: green run -> gate exit 0" "$([ "$GRC" -eq 0 ] && echo true || echo false)"
assert "1: the tier ran exactly once" "$([ "$(invocations "$T1")" = 1 ] && echo true || echo false)"
assert "1: one token written under .git/dhx-probe-tier/" "$([ "$(tokens "$T1")" = 1 ] && echo true || echo false)"
TOK1=$(find "$T1/.git/dhx-probe-tier" -maxdepth 1 -type f | head -1)
assert "1: token body carries the run's summary" "$(has 'passed' "$(cat "$TOK1")")"
assert "1: no hit line on the first run" "$([ "$(has "$HIT" "$GOUT")" = false ] && echo true || echo false)"
assert "1: the real index is untouched by the key computation" \
  "$([ "$(git -C "$T1" diff --cached --name-only)" = "$STAGED_BEFORE" ] && echo true || echo false)"
gate "$T1"
assert "2: identical rerun -> exit 0" "$([ "$GRC" -eq 0 ] && echo true || echo false)"
assert "2: identical rerun did NOT run the tier" "$([ "$(invocations "$T1")" = 1 ] && echo true || echo false)"
assert "2: hit line printed" "$(has "$HIT" "$GOUT")"
assert "2: hit line names the force switch" "$(has 'DHX_PROBE_TIER_TTL=0' "$GOUT")"

# ---- 3. staged tree changed -> runs again --------------------------------------
write_probe "$T1" probe-fixture-second.sh 0
git -C "$T1" add -f tests/probes/probe-fixture-second.sh >/dev/null 2>&1
gate "$T1"
assert "3: staged change -> the tier ran again" "$([ "$(invocations "$T1")" = 2 ] && echo true || echo false)"
assert "3: a second token exists" "$([ "$(tokens "$T1")" = 2 ] && echo true || echo false)"

# ---- 3b. WORKTREE-only edit, index unchanged -> runs again --------------------
# The staged copy still exits 0; the worktree copy now exits 1. The runner reads
# the worktree, so a candidate-only key would reuse the green here.
printf '#!/bin/bash\n# SAFE_FOR_LIVE: yes\n# LIVE_RUNTIME: no\nexit 1\n' > "$T1/tests/probes/probe-fixture-second.sh"
gate "$T1"
assert "3b: worktree-only edit -> the tier ran again (not a hit)" "$([ "$(invocations "$T1")" = 3 ] && echo true || echo false)"
assert "3b: and the gate blocked on the worktree red" "$([ "$GRC" -ne 0 ] && echo true || echo false)"
assert "3b: a red wrote no token" "$([ "$(tokens "$T1")" = 2 ] && echo true || echo false)"
write_probe "$T1" probe-fixture-second.sh 0   # restore

# ---- 3c. a probe hidden by .git/info/exclude still changes the key -------------
gate "$T1"; N=$(invocations "$T1")
echo 'tests/probes/probe-fixture-hidden.sh' >> "$T1/.git/info/exclude"
write_probe "$T1" probe-fixture-hidden.sh 0
gate "$T1"
assert "3c: ignored-but-glob-visible probe -> the tier ran again" "$([ "$(invocations "$T1")" = $((N+1)) ] && echo true || echo false)"

# ---- 3d. hooks dir content changes the key (git-meta term) --------------------
gate "$T1"; N=$(invocations "$T1")
printf '#!/bin/bash\nexit 0\n' > "$T1/.git/hooks/pre-push"; chmod +x "$T1/.git/hooks/pre-push"
gate "$T1"
assert "3d: hooks dir change -> the tier ran again" "$([ "$(invocations "$T1")" = $((N+1)) ] && echo true || echo false)"

# ---- 3e. untracked churn OUTSIDE the input roots does NOT move the key -------
# A peer writing Codex evidence under reports/ between a refusal and its retry
# defeated the first (whole-worktree) cut on 2026-09-14. Miss-only, but inert.
gate "$T1"; N=$(invocations "$T1")
mkdir -p "$T1/reports/peer-evidence" && echo "round-1 output" > "$T1/reports/peer-evidence/round-1.out"
gate "$T1"
assert "3e: untracked file under reports/ -> still a hit (not keyed)" "$([ "$(invocations "$T1")" = "$N" ] && [ "$(has "$HIT" "$GOUT")" = true ] && echo true || echo false)"
# ...but a TRACKED file anywhere still moves it (add -u).
echo "peer edit" >> "$T1/docs/decisions.md"
gate "$T1"
assert "3e: tracked edit under docs/ -> the tier ran again" "$([ "$(invocations "$T1")" = $((N+1)) ] && echo true || echo false)"

# ---- 4. red run: no token, identical rerun re-runs ----------------------------
T4=$(sandbox)
write_probe "$T4" probe-fixture-red.sh 1
git -C "$T4" add -f tests/probes/probe-fixture-red.sh >/dev/null 2>&1
gate "$T4"
assert "4: red run -> gate blocks" "$([ "$GRC" -ne 0 ] && echo true || echo false)"
assert "4: red run wrote NO token" "$([ "$(tokens "$T4")" = 0 ] && echo true || echo false)"
gate "$T4"
assert "4: identical rerun after a red re-runs the tier" "$([ "$(invocations "$T4")" = 2 ] && echo true || echo false)"
assert "4: and still blocks" "$([ "$GRC" -ne 0 ] && echo true || echo false)"

# ---- 5. DHX_RED_COMMIT=1 + green: runs, writes; flagged rerun hits ------------
T5=$(sandbox)
write_probe "$T5" probe-fixture-optout.sh 0
git -C "$T5" add -f tests/probes/probe-fixture-optout.sh >/dev/null 2>&1
gate "$T5" DHX_RED_COMMIT=1 DHX_RED_COMMIT_REASON="green under the flag"
assert "5: opt-out + green -> exit 0, tier ran" "$([ "$GRC" -eq 0 ] && [ "$(invocations "$T5")" = 1 ] && echo true || echo false)"
assert "5: opt-out + green -> token written (a green is a green)" "$([ "$(tokens "$T5")" = 1 ] && echo true || echo false)"
assert "5: opt-out green still reports the flag as unnecessary" "$(has 'was unnecessary' "$GOUT")"
gate "$T5" DHX_RED_COMMIT=1 DHX_RED_COMMIT_REASON="green under the flag"
assert "5: identical rerun under the flag HITS (no carve-out)" "$([ "$(invocations "$T5")" = 1 ] && echo true || echo false)"
assert "5: hit line printed under the flag" "$(has "$HIT" "$GOUT")"
gate "$T5"
assert "5: unflagged rerun on the same state also hits" "$([ "$(invocations "$T5")" = 1 ] && echo true || echo false)"

# ---- 6. TTL: expired token re-runs; TTL=0 / off force a run --------------------
T6=$(sandbox)
write_probe "$T6" probe-fixture-ttl.sh 0
git -C "$T6" add -f tests/probes/probe-fixture-ttl.sh >/dev/null 2>&1
gate "$T6"
TOK6=$(find "$T6/.git/dhx-probe-tier" -maxdepth 1 -type f | head -1)
touch -d '-20 min' "$TOK6"
gate "$T6"
assert "6: token older than the TTL -> the tier ran again" "$([ "$(invocations "$T6")" = 2 ] && echo true || echo false)"
assert "6: the expired token was pruned and a fresh one written" "$([ "$(tokens "$T6")" = 1 ] && [ -f "$TOK6" ] && echo true || echo false)"
gate "$T6" DHX_PROBE_TIER_TTL=0
assert "6: DHX_PROBE_TIER_TTL=0 forces a run past a fresh token" "$([ "$(invocations "$T6")" = 3 ] && echo true || echo false)"
gate "$T6" DHX_PROBE_TIER_TTL=off
assert "6: DHX_PROBE_TIER_TTL=off forces a run too" "$([ "$(invocations "$T6")" = 4 ] && echo true || echo false)"
gate "$T6" DHX_PROBE_TIER_TTL=900
assert "6: back to the default -> hits" "$([ "$(invocations "$T6")" = 4 ] && [ "$(has "$HIT" "$GOUT")" = true ] && echo true || echo false)"

# ---- 7. MUTATION CONTROL: a constant snapshot term wrongly reuses --------------
# Replace the snapshot write-tree with a constant in the fixture's COPY of the
# gate. Case 3b's assertion ("worktree-only edit -> ran again") must now be
# violated: the mutated gate HITS. Behaviour changes, not bytes.
T7=$(sandbox)
sed -i 's|_tt_snap=$(GIT_INDEX_FILE="$_tt_idx" git write-tree 2>/dev/null \|\| true)|_tt_snap=constant0000|' "$T7/scripts/verify-hook-patterns.sh"
assert "7: control mutation applied to the fixture copy" \
  "$([ "$(grep -c '_tt_snap=constant0000' "$T7/scripts/verify-hook-patterns.sh")" = 1 ] && echo true || echo false)"
write_probe "$T7" probe-fixture-ctl.sh 0
git -C "$T7" add -f tests/probes/probe-fixture-ctl.sh >/dev/null 2>&1
gate "$T7"
printf '#!/bin/bash\n# SAFE_FOR_LIVE: yes\n# LIVE_RUNTIME: no\nexit 1\n' > "$T7/tests/probes/probe-fixture-ctl.sh"
gate "$T7"
assert "7: CONTROL — with the snapshot term broken, the worktree-red rerun wrongly HITS" \
  "$([ "$(invocations "$T7")" = 1 ] && [ "$GRC" -eq 0 ] && [ "$(has "$HIT" "$GOUT")" = true ] && echo true || echo false)"

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
