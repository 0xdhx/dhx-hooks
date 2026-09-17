#!/usr/bin/env bash
# SAFE_FOR_LIVE: yes  (read-only grep of the in-repo dispatcher; behavioral smoke
#   runs the observer with CC_OBS_STATE_FILE / CC_BIN_LINK / CC_OBS_MANIFEST seams
#   pointed at a mktemp sandbox — never reads or writes the live
#   ~/.local/state/dhx/cc-version-seen or ~/.local/bin/claude)
#
# Exercises the SessionStart wiring of the fleet CC version-CHANGE observer
# (cross-repo scripts/fleet/cc-version-observer.sh), wired into the hooks-repo
# dispatcher (dhx-plugin/plugins/dhx/hooks/session-start.sh) via the
# ~/.claude/dhx-tools/ indirection — the same provisioning shape as the sibling
# cc-version-guard.sh, NOT a direct ~/repos/cross-repo/ working-tree path.
#
# Sibling to probe-cc-version-guard-wiring.sh, and deliberately its inverse: the
# guard is a pin-LOCK whose correct behavior on an ordinary bump is SILENCE; the
# observer is loud exactly once per CHANGE. Group B therefore asserts the opposite
# polarity from the guard probe's — silence is the failure mode on T3, not the pass.
#
# Two assertion groups:
#   A. WIRING (unconditional, self-contained — backs the decisions.md row):
#      the dispatcher invokes the observer through the dhx-tools install path,
#      behind an [ -e ] existence guard, with < /dev/null and a fail-open
#      || true, under the _dhx_child failure-surfacing wrapper (e8fb4189,
#      2026-09-14), and does NOT couple to cross-repo's private scripts/fleet/
#      layout by absolute working-tree path.
#      INVARIANT: stdout must NOT be redirected on this line. The notice IS the
#      deliverable — under SessionStart it lands in session context. _dhx_child
#      captures stderr only, so the wrapper is stdout-transparent; a future edit
#      adding >/dev/null (as dhx-watch-health.cjs carries) silently deletes the
#      whole feature while every other assertion here stays green.
#   B. BEHAVIORAL SMOKE (conditional — runs only when the installed observer at
#      ~/.claude/dhx-tools/cc-version-observer.sh is present & executable):
#      T1 first-run baseline init is silent, T2 no-change is silent, T3 a change
#      FIRES and NAMES the keyed brief, T4 the re-run after a notice is silent
#      (once-per-change, not once-per-session), T5 an empty stamp re-baselines
#      silently. Skipped (not failed) when cross-repo hasn't provisioned the
#      symlink, so the probe stays green in a bare hooks clone — matching the
#      dispatcher's own [ -e ] graceful no-op.
#
# T3's naming assertion is the load-bearing one: per the originating brief
# (cross-repo 2026-08-23-cc-version-bump-has-no-trigger-firing-path), "A notice
# that says only 'CC bumped' reproduces the failure — the operator still has to
# know which briefs to go read."
#
# Backs docs/decisions.md 2026-09-17 "cc-version-observer SessionStart wiring
# (dhx-tools indirection, _dhx_child-wrapped, stdout preserved)" row.
# Run: bash tests/probes/probe-cc-version-observer-wiring.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DISPATCHER="$REPO_ROOT/dhx-plugin/plugins/dhx/hooks/session-start.sh"
INSTALLED_OBS="$HOME/.claude/dhx-tools/cc-version-observer.sh"

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [ "$cond" = "ok" ]; then echo "OK   $name"; PASS=$((PASS + 1))
  else echo "FAIL $name${3:+ ($3)}"; FAIL=$((FAIL + 1)); fi
}

echo "=== A. SessionStart dispatcher wiring (cc-version-observer) ==="

if [ ! -f "$DISPATCHER" ]; then
  check "dispatcher present at $DISPATCHER" "fail" "file missing"
  echo "---"; echo "$PASS passed, $FAIL failed"; exit 1
fi

# Pull the single non-comment line that invokes the observer.
OBS_LINE=$(grep -nE '(^|[^#].*)cc-version-observer\.sh' "$DISPATCHER" | grep -v '^[0-9]*:[[:space:]]*#' || true)

[ -n "$OBS_LINE" ] && check "dispatcher invokes cc-version-observer.sh" ok \
  || check "dispatcher invokes cc-version-observer.sh" "fail" "no non-comment invocation found"

grep -qE '\[ -e ~/\.claude/dhx-tools/cc-version-observer\.sh \]' "$DISPATCHER" \
  && check "invocation gated by [ -e ~/.claude/dhx-tools/cc-version-observer.sh ] existence guard" ok \
  || check "invocation gated by [ -e ~/.claude/dhx-tools/cc-version-observer.sh ] existence guard" "fail"

grep -qE 'bash ~/\.claude/dhx-tools/cc-version-observer\.sh' "$DISPATCHER" \
  && check "observer invoked via ~/.claude/dhx-tools/ (dhx-tools indirection, like the sibling guard)" ok \
  || check "observer invoked via ~/.claude/dhx-tools/ (dhx-tools indirection, like the sibling guard)" "fail"

printf '%s\n' "$OBS_LINE" | grep -qE '< */dev/null' \
  && check "observer invoked with < /dev/null (no stdin dependency)" ok \
  || check "observer invoked with < /dev/null (no stdin dependency)" "fail"

printf '%s\n' "$OBS_LINE" | grep -qE '\|\| *true *$' \
  && check "observer invocation is fail-open (trailing || true)" ok \
  || check "observer invocation is fail-open (trailing || true)" "fail"

# Failure-surfacing wrapper: the repo convention since e8fb4189 (2026-09-14).
printf '%s\n' "$OBS_LINE" | grep -qE '_dhx_child +cc-version-observer ' \
  && check "observer runs under _dhx_child (child-failure first-sight surface)" ok \
  || check "observer runs under _dhx_child (child-failure first-sight surface)" "fail"

# INVARIANT (see header): stdout is the deliverable. Any stdout redirect on this
# line deletes the feature silently. stderr redirects are _dhx_child's business.
if printf '%s\n' "$OBS_LINE" | grep -qE '(^|[^2])> */dev/null|&> */dev/null'; then
  check "observer stdout is NOT redirected (the notice is the deliverable)" "fail" \
    "found a stdout redirect on the invocation line"
else
  check "observer stdout is NOT redirected (the notice is the deliverable)" ok
fi

if grep -qE '/repos/cross-repo/.*cc-version-observer' "$DISPATCHER"; then
  check "dispatcher does NOT hardcode a ~/repos/cross-repo/ path for the observer" "fail" \
    "found direct cross-repo working-tree coupling"
else
  check "dispatcher does NOT hardcode a ~/repos/cross-repo/ path for the observer" ok
fi

echo "=== B. Behavioral smoke via override seams (sandboxed) ==="

if [ ! -e "$INSTALLED_OBS" ] || [ ! -x "$(readlink -f "$INSTALLED_OBS" 2>/dev/null)" ]; then
  echo "SKIP behavioral smoke — $INSTALLED_OBS not provisioned (run cross-repo install-dhx-tools.sh)"
else
  SB=$(mktemp -d)
  trap 'rm -rf "$SB"' EXIT
  mkdir -p "$SB/versions" "$SB/bin" "$SB/state" "$SB/fleet/repo-x/.planning/backlog"
  : > "$SB/versions/2.1.273"
  : > "$SB/versions/2.1.275"
  STAMP="$SB/state/cc-version-seen"
  LINK="$SB/bin/claude"

  # A keyed brief the notice must NAME, and a decoy that must not be named.
  cat > "$SB/fleet/repo-x/.planning/backlog/keyed-brief.md" <<'BRIEF'
---
title: "A brief keyed on a CC version change"
trigger_when: >
  on any Claude Code minor bump, because CC owns the contract
status: captured
---
BRIEF
  cat > "$SB/fleet/repo-x/.planning/backlog/decoy-brief.md" <<'BRIEF'
---
title: "A brief keyed on something else entirely"
trigger_when: "when the tmux pane-capture format changes"
status: captured
---
BRIEF
  MANIFEST="$SB/fleet/manifest.json"
  printf '{"repos":[{"path":"%s"}]}\n' "$SB/fleet/repo-x" > "$MANIFEST"

  run_obs() {
    CC_OBS_STATE_FILE="$STAMP" CC_BIN_LINK="$LINK" CC_OBS_MANIFEST="$MANIFEST" \
      bash "$INSTALLED_OBS" < /dev/null >"$SB/out" 2>"$SB/err"; echo "$?"
  }

  # T1: no stamp -> silent baseline init, stamp created at the current version.
  rm -f "$STAMP"; ln -sfn "$SB/versions/2.1.273" "$LINK"
  rc=$(run_obs); outsz=$(wc -c < "$SB/out")
  [ "$rc" = "0" ] && [ "$outsz" -eq 0 ] && [ "$(cat "$STAMP" 2>/dev/null)" = "2.1.273" ] \
    && check "[T1] first run -> silent baseline init (rc=0, no stdout, stamp=2.1.273)" ok \
    || check "[T1] first run -> silent baseline init (rc=0, no stdout, stamp=2.1.273)" "fail" \
             "rc=$rc outsz=$outsz stamp=$(cat "$STAMP" 2>/dev/null)"

  # T2: stamp == current -> silent (the common case, every session start).
  rc=$(run_obs); outsz=$(wc -c < "$SB/out")
  [ "$rc" = "0" ] && [ "$outsz" -eq 0 ] \
    && check "[T2] no change -> silent (rc=0, zero stdout: no per-session context cost)" ok \
    || check "[T2] no change -> silent (rc=0, zero stdout: no per-session context cost)" "fail" "rc=$rc outsz=$outsz"

  # T3: a real bump -> notice FIRES, names the transition, stamp advances.
  ln -sfn "$SB/versions/2.1.275" "$LINK"
  rc=$(run_obs)
  if [ "$rc" = "0" ] && grep -q '2\.1\.273 -> 2\.1\.275' "$SB/out" \
     && [ "$(cat "$STAMP" 2>/dev/null)" = "2.1.275" ]; then
    check "[T3] change -> notice fires naming the transition, stamp advances" ok
  else
    check "[T3] change -> notice fires naming the transition, stamp advances" "fail" \
          "rc=$rc stamp=$(cat "$STAMP" 2>/dev/null) out=$(head -c 120 "$SB/out")"
  fi

  # T3b: the notice NAMES the keyed brief and not the decoy. This is the whole
  # point — "CC bumped" alone reproduces the failure the observer exists to fix.
  # Requires jq for the manifest walk; without it the observer takes its documented
  # "brief scan unavailable" branch, so assert that fallback instead of failing.
  if command -v jq >/dev/null 2>&1; then
    if grep -q 'keyed-brief\.md' "$SB/out" && ! grep -q 'decoy-brief\.md' "$SB/out"; then
      check "[T3b] notice NAMES the keyed brief and skips the non-keyed decoy" ok
    else
      check "[T3b] notice NAMES the keyed brief and skips the non-keyed decoy" "fail" \
            "out=$(head -c 200 "$SB/out")"
    fi
  else
    grep -q 'brief scan unavailable' "$SB/out" \
      && check "[T3b] jq absent -> documented 'brief scan unavailable' fallback (not a silent pass)" ok \
      || check "[T3b] jq absent -> documented 'brief scan unavailable' fallback (not a silent pass)" "fail"
  fi

  # T4: re-run right after a notice -> silent. Once per CHANGE, not per session.
  rc=$(run_obs); outsz=$(wc -c < "$SB/out")
  [ "$rc" = "0" ] && [ "$outsz" -eq 0 ] \
    && check "[T4] re-run after a notice -> silent (once per change, not once per session)" ok \
    || check "[T4] re-run after a notice -> silent (once per change, not once per session)" "fail" "rc=$rc outsz=$outsz"

  # T5: empty stamp -> silent re-baseline (not a spurious notice against "").
  : > "$STAMP"
  rc=$(run_obs); outsz=$(wc -c < "$SB/out")
  [ "$rc" = "0" ] && [ "$outsz" -eq 0 ] && [ "$(cat "$STAMP" 2>/dev/null)" = "2.1.275" ] \
    && check "[T5] empty stamp -> silent re-baseline (no notice against an empty last-seen)" ok \
    || check "[T5] empty stamp -> silent re-baseline (no notice against an empty last-seen)" "fail" \
             "rc=$rc outsz=$outsz stamp=$(cat "$STAMP" 2>/dev/null)"
fi

echo "---"
echo "$PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
