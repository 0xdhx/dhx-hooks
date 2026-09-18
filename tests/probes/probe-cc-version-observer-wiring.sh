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
#      silently, T6 a DAEMON-shaped consumer neither emits nor stamps while the
#      OPERATOR-facing consumer that follows still receives the notice, T7 an
#      absent/empty attendedness signal fails OPEN, T8 eight concurrent attended
#      consumers produce exactly one emission, T9 a stale claim is stealable and
#      a fresh one is respected, T10 an unwritable state dir still EMITS (the claim
#      must never be able to silence the operator) and the failed stamp re-announces,
#      T11/T12 the two claim RACES scheduled deterministically with a `mkdir` shim —
#      a peer finishing mid-claim, and losing a stale-claim steal — neither of which
#      T8's barrier can schedule and both of which it stayed green against, and
#      T13/T14 the remaining two rows of the observer's claim-outcome table: a stale
#      claim that cannot be REMOVED must still emit (a dead owner silencing the
#      transition forever is worse than the defect), and the indeterminate residue
#      deliberately emits rather than going silent. Skipped (not failed) when cross-repo hasn't provisioned the
#      symlink, so the probe stays green in a bare hooks clone — matching the
#      dispatcher's own [ -e ] graceful no-op.
#
# T6 is the cell the 2026-09-17 lane-delivery fix owes: every other cell here passes under
# BOTH the pre-fix and post-fix implementations, so it is the only one that can adjudicate
# the fix at all. Measured RED against hooks 8f22ea35 / cross-repo 228ff809c — there the
# daemon consumer emitted 342 bytes and the operator that followed received zero.
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

  # $1 = the value CLAUDE_CODE_SESSION_ATTENDED should carry, or "unset" to remove it.
  # PINNED, never inherited: this probe runs from whatever session invokes it, and a
  # background session exports CLAUDE_CODE_SESSION_ATTENDED=0. Inheriting it would make
  # T3/T3b red in a background session and green in an attended one — a suite whose verdict
  # depends on who ran it. Default "unset" is the fail-open path the observer documents.
  run_obs_as() {
    local att="${1:-unset}"
    if [ "$att" = "unset" ]; then
      env -u CLAUDE_CODE_SESSION_ATTENDED \
        CC_OBS_STATE_FILE="$STAMP" CC_BIN_LINK="$LINK" CC_OBS_MANIFEST="$MANIFEST" \
        bash "$INSTALLED_OBS" < /dev/null >"$SB/out" 2>"$SB/err"; echo "$?"
    else
      CLAUDE_CODE_SESSION_ATTENDED="$att" \
        CC_OBS_STATE_FILE="$STAMP" CC_BIN_LINK="$LINK" CC_OBS_MANIFEST="$MANIFEST" \
        bash "$INSTALLED_OBS" < /dev/null >"$SB/out" 2>"$SB/err"; echo "$?"
    fi
  }
  run_obs() { run_obs_as unset; }

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

  # ── T6: THE TWO-CONSUMER CELL. The one assertion that cannot be waived. ──────
  # Every cell above passes under BOTH the pre-2026-09-17 implementation and the fixed one,
  # so a fix validated only by them is untested by construction. This cell models the
  # measured defect directly: a DAEMON-shaped consumer runs first, then an OPERATOR-facing
  # one. The operator must still receive the notice.
  # RED against the implementation at hooks 8f22ea35 / cross-repo 228ff809c: measured there,
  # the daemon emitted 342 bytes and advanced the stamp, and the operator that followed got
  # ZERO bytes — which is exactly the 2026-09-17 production miss, reproduced in a sandbox.
  printf '2.1.273\n' > "$STAMP"; ln -sfn "$SB/versions/2.1.275" "$LINK"
  rc_d=$(run_obs_as 0); out_d=$(wc -c < "$SB/out"); stamp_d=$(cat "$STAMP" 2>/dev/null)
  if [ "$rc_d" = "0" ] && [ "$out_d" -eq 0 ] && [ "$stamp_d" = "2.1.273" ]; then
    check "[T6a] unattended (daemon) consumer -> silent AND leaves the stamp for the operator" ok
  else
    check "[T6a] unattended (daemon) consumer -> silent AND leaves the stamp for the operator" "fail" \
          "rc=$rc_d outsz=$out_d stamp=$stamp_d (expected rc=0, 0 bytes, stamp still 2.1.273)"
  fi

  rc_o=$(run_obs_as 1); out_o=$(wc -c < "$SB/out"); stamp_o=$(cat "$STAMP" 2>/dev/null)
  if [ "$rc_o" = "0" ] && grep -q '2\.1\.273 -> 2\.1\.275' "$SB/out" && [ "$stamp_o" = "2.1.275" ]; then
    check "[T6b] operator-facing consumer AFTER the daemon -> STILL receives the notice" ok
  else
    check "[T6b] operator-facing consumer AFTER the daemon -> STILL receives the notice" "fail" \
          "rc=$rc_o outsz=$out_o stamp=$stamp_o out=$(head -c 120 "$SB/out")"
  fi

  # T7: the polarity. Only the literal "0" suppresses; a vanished variable must degrade to
  # the old behaviour, never to silence. See the observer's POLARITY IS DELIBERATE block.
  printf '2.1.273\n' > "$STAMP"
  rc=$(run_obs_as unset)
  [ "$rc" = "0" ] && grep -q '2\.1\.273 -> 2\.1\.275' "$SB/out" \
    && check "[T7] CLAUDE_CODE_SESSION_ATTENDED unset -> fail-OPEN (notice fires; a missing signal can never silence)" ok \
    || check "[T7] CLAUDE_CODE_SESSION_ATTENDED unset -> fail-OPEN (notice fires; a missing signal can never silence)" "fail" \
             "rc=$rc out=$(head -c 120 "$SB/out")"

  printf '2.1.273\n' > "$STAMP"
  rc=$(run_obs_as "")
  [ "$rc" = "0" ] && grep -q '2\.1\.273 -> 2\.1\.275' "$SB/out" \
    && check "[T7b] empty-string attendedness -> fail-OPEN (only the literal 0 suppresses)" ok \
    || check "[T7b] empty-string attendedness -> fail-OPEN (only the literal 0 suppresses)" "fail" \
             "rc=$rc out=$(head -c 120 "$SB/out")"

  # T8: concurrent attended consumers. The read-compare-write the observer used through
  # 228ff809c is not atomic, so N sessions starting together all emit. Measured against that
  # implementation: 12 of 12 racing consumers emitted, three trials out of three. The mkdir
  # claim is the atomic test-and-set (same shape as the dispatcher's _dhx_child marker).
  # A barrier file synchronises the racers past the read; without it they serialise by luck.
  printf '2.1.273\n' > "$STAMP"
  BAR="$SB/race-go"; rm -f "$BAR" "$SB"/race.out.*
  for i in 1 2 3 4 5 6 7 8; do
    ( while [ ! -e "$BAR" ]; do :; done
      CLAUDE_CODE_SESSION_ATTENDED=1 CC_OBS_STATE_FILE="$STAMP" CC_BIN_LINK="$LINK" \
        CC_OBS_MANIFEST="$MANIFEST" bash "$INSTALLED_OBS" < /dev/null \
        > "$SB/race.out.$i" 2>/dev/null ) &
  done
  sleep 0.3; touch "$BAR"; wait
  emitters=$(grep -l 'cc-version-observer' "$SB"/race.out.* 2>/dev/null | wc -l)
  claims=$(find "$SB/state" -maxdepth 1 -name 'cc-version-seen.claim.*' 2>/dev/null | wc -l)
  if [ "$emitters" -eq 1 ] && [ "$claims" -eq 0 ]; then
    check "[T8] 8 concurrent attended consumers -> EXACTLY one emits, claim released" ok
  else
    check "[T8] 8 concurrent attended consumers -> EXACTLY one emits, claim released" "fail" \
          "emitters=$emitters (expected 1) leaked_claims=$claims (expected 0)"
  fi

  # T9: a claim abandoned mid-emit must not silence the version forever. CC terminates a
  # still-running SessionStart hook when the session exits, so this is a real path, not a
  # theoretical one. A claim older than the 300s staleness bound is stealable.
  printf '2.1.273\n' > "$STAMP"
  STALE_CLAIM="$STAMP.claim.2.1.275"
  mkdir -p "$STALE_CLAIM" 2>/dev/null
  touch -d '2 hours ago' "$STALE_CLAIM" 2>/dev/null || touch -t 200001010000 "$STALE_CLAIM" 2>/dev/null
  _pre_inode=$(stat -c %i "$STALE_CLAIM" 2>/dev/null)
  rc=$(run_obs_as 1)
  _post_inode=$(stat -c %i "$STALE_CLAIM" 2>/dev/null)
  # NOT "stolen" — since 2026-09-18 the observer never mutates a claim it did not create.
  # A stale claim is simply not an obstacle: it is left exactly where it is and the decision
  # falls through to the stamp re-read. Asserting the inode is UNCHANGED is what pins the
  # no-mutation invariant; four separate races traced to acting on this path from a stale read.
  [ "$rc" = "0" ] && grep -q '2\.1\.273 -> 2\.1\.275' "$SB/out" \
    && [ -n "$_pre_inode" ] && [ "$_pre_inode" = "$_post_inode" ] \
    && check "[T9] a STALE abandoned claim does not block, and is NOT mutated (same inode after)" ok \
    || check "[T9] a STALE abandoned claim does not block, and is NOT mutated (same inode after)" "fail" \
             "rc=$rc inode $_pre_inode -> $_post_inode out=$(head -c 100 "$SB/out")"

  # T9b: the inverse — a FRESH claim is respected, or T8's guarantee is vacuous.
  printf '2.1.273\n' > "$STAMP"
  # Build a FRESH claim deliberately: T9 leaves its stale one in place now, and `mkdir -p` on an
  # existing directory does NOT refresh the mtime the age test reads.
  rmdir "$STALE_CLAIM" 2>/dev/null; mkdir -p "$STALE_CLAIM" 2>/dev/null; touch "$STALE_CLAIM" 2>/dev/null
  rc=$(run_obs_as 1); outsz=$(wc -c < "$SB/out")
  [ "$rc" = "0" ] && [ "$outsz" -eq 0 ] && [ "$(cat "$STAMP" 2>/dev/null)" = "2.1.273" ] \
    && check "[T9b] a FRESH claim is respected -> silent, stamp untouched (T8's guarantee is not vacuous)" ok \
    || check "[T9b] a FRESH claim is respected -> silent, stamp untouched (T8's guarantee is not vacuous)" "fail" \
             "rc=$rc outsz=$outsz stamp=$(cat "$STAMP" 2>/dev/null)"
  rmdir "$STALE_CLAIM" 2>/dev/null

  # ── T10: the claim must never be able to SILENCE the notice ─────────────────
  # The claim directory lives beside the stamp, so an unwritable state dir fails BOTH the
  # stamp write and the `mkdir` claim. A shape that reads every mkdir failure as "a peer is
  # emitting" then goes quiet — measured 2026-09-17 at 0 bytes where the pre-claim observer
  # emitted 342. That is the serialisation nicety silencing the operator, which is the exact
  # failure class this whole mechanism exists to remove. Delivery beats de-duplication.
  # RED against the first cut of the claim (2026-09-17, pre-fail-open): 0 bytes emitted.
  # Skipped under a uid that ignores the mode bits, rather than passing vacuously.
  printf '2.1.273\n' > "$STAMP"
  chmod 0555 "$SB/state" 2>/dev/null
  # `touch`, not `printf >file`: bash applies redirections BEFORE 2>/dev/null takes effect, so
  # the redirect form leaks "Permission denied" to the probe's own stderr. touch reports its own.
  if touch "$SB/state/.writetest" 2>/dev/null; then
    rm -f "$SB/state/.writetest" 2>/dev/null; chmod 0755 "$SB/state" 2>/dev/null
    echo "SKIP [T10] unwritable-state-dir cells — this uid writes through mode 0555 (root?)"
  else
    rc=$(run_obs_as 1)
    if [ "$rc" = "0" ] && grep -q '2\.1\.273 -> 2\.1\.275' "$SB/out"; then
      check "[T10] unwritable state dir -> STILL emits (a failed claim can never silence the operator)" ok
    else
      check "[T10] unwritable state dir -> STILL emits (a failed claim can never silence the operator)" "fail" \
            "rc=$rc outsz=$(wc -c < "$SB/out") — the claim went quiet instead of failing open"
    fi
    # T10b: and the retry survives. The stamp could not be written, so this transition is NOT
    # recorded as delivered and the next attended start must announce it again — told twice
    # beats told zero times. This is what the unconditional claim release buys.
    rc=$(run_obs_as 1)
    [ "$rc" = "0" ] && grep -q '2\.1\.273 -> 2\.1\.275' "$SB/out" \
      && [ "$(cat "$STAMP" 2>/dev/null)" = "2.1.273" ] \
      && check "[T10b] stamp write failed -> transition re-announces next run (retry preserved, not consumed)" ok \
      || check "[T10b] stamp write failed -> transition re-announces next run (retry preserved, not consumed)" "fail" \
               "rc=$rc stamp=$(cat "$STAMP" 2>/dev/null) outsz=$(wc -c < "$SB/out")"
    chmod 0755 "$SB/state" 2>/dev/null
  fi

  # ── T11/T12: the claim RACES, scheduled deterministically ───────────────────
  # T8's barrier proves one-of-N under natural scheduling, but it cannot schedule the two
  # interleavings that actually break the contract, so it stayed green against both of them.
  # A `mkdir` shim on PATH interposes at exactly the moment the observer tries to claim —
  # after it has read the stamp — which is the window both races live in. Same technique the
  # close-gate reviewer used to reproduce them (2026-09-17, round 3).
  SHIM="$SB/shim"; mkdir -p "$SHIM"

  # T11: the WINNER FINISHED while we were failing to claim. Both sessions read the old stamp;
  # A takes the claim, emits, stamps, releases. B's mkdir fails and B then finds NO claim
  # directory. An implementation that infers "nobody holds one, so emit" announces a transition
  # A already announced. The shim IS lane A: it advances the stamp, then fails our mkdir.
  # RED against cross-repo da2bbd61e (fell through and emitted a duplicate).
  cat > "$SHIM/mkdir" <<SHIMEOF
#!/usr/bin/env bash
printf '2.1.275\n' > "$STAMP"
exit 1
SHIMEOF
  chmod +x "$SHIM/mkdir"
  printf '2.1.273\n' > "$STAMP"
  rc=$(PATH="$SHIM:$PATH" CLAUDE_CODE_SESSION_ATTENDED=1 CC_OBS_STATE_FILE="$STAMP" \
       CC_BIN_LINK="$LINK" CC_OBS_MANIFEST="$MANIFEST" \
       bash "$INSTALLED_OBS" </dev/null >"$SB/out" 2>/dev/null; echo $?)
  outsz=$(wc -c < "$SB/out")
  [ "$rc" = "0" ] && [ "$outsz" -eq 0 ] \
    && check "[T11] a peer finished mid-claim -> silent (no duplicate notice into a second lane)" ok \
    || check "[T11] a peer finished mid-claim -> silent (no duplicate notice into a second lane)" "fail" \
             "rc=$rc outsz=$outsz — emitted a transition a peer had already announced"

  # T12: the ABA PRECONDITION IS STRUCTURALLY ABSENT. The round-5 refutation reproduced two
  # processes that had both classified one claim as stale, each removing the OTHER's freshly
  # created claim and both emitting — an ABA on the pathname, because `rmdir` names a path and
  # not the inode you inspected. The repair deleted the steal rather than hardening it, so the
  # property to pin is that a non-owner performs no mutation at all: run against a stale claim
  # with a shim that makes any mkdir attempt observable, and require that the claim survives
  # untouched and that no second claim was created.
  # RED against cross-repo 351e67c2f, which removed and recreated it.
  printf '2.1.273\n' > "$STAMP"
  STALE2="$STAMP.claim.2.1.275"; /bin/rmdir "$STALE2" 2>/dev/null; /bin/mkdir -p "$STALE2"
  touch -d '2 hours ago' "$STALE2" 2>/dev/null || touch -t 200001010000 "$STALE2" 2>/dev/null
  _ino2=$(stat -c %i "$STALE2" 2>/dev/null)
  _mt2=$(stat -c %Y "$STALE2" 2>/dev/null)
  rc=$(run_obs_as 1)
  _ino2b=$(stat -c %i "$STALE2" 2>/dev/null)
  _mt2b=$(stat -c %Y "$STALE2" 2>/dev/null)
  _nclaims=$(find "$SB/state" -maxdepth 1 -name 'cc-version-seen.claim.*' 2>/dev/null | wc -l)
  if [ "$rc" = "0" ] && [ "$_ino2" = "$_ino2b" ] && [ "$_mt2" = "$_mt2b" ] && [ "$_nclaims" -eq 1 ]; then
    check "[T12] a non-owner never mutates the claim path (no remove, no recreate -> no ABA)" ok
  else
    check "[T12] a non-owner never mutates the claim path (no remove, no recreate -> no ABA)" "fail" \
          "inode $_ino2->$_ino2b mtime $_mt2->$_mt2b claims=$_nclaims (want 1, unchanged)"
  fi
  /bin/rmdir "$STALE2" 2>/dev/null; rm -rf "$SHIM"

  # ── T13/T14: the last two rows of the claim-outcome table ───────────────────
  # The claim point asks one question — "is another process going to deliver this?" — and the
  # filesystem answers it in exactly six ways (see the observer's CLAIM header). T6-T12 cover
  # four. These are the other two, and both were wrong at some point in this arc BECAUSE the
  # code inferred an answer instead of observing one.
  SHIM="$SB/shim"; mkdir -p "$SHIM"

  # T13: the stale claim could not be REMOVED. "mkdir failed and a directory is there" also
  # describes the claim we failed to remove, not only a competitor that recreated it — and its
  # owner is already dead, so treating it as a live owner means NOBODY delivers, forever.
  # RED against cross-repo a21880ac2: 0 bytes on every invocation.
  printf '2.1.273\n' > "$STAMP"
  STALE3="$STAMP.claim.2.1.275"; /bin/mkdir -p "$STALE3"
  touch -d '2 hours ago' "$STALE3" 2>/dev/null || touch -t 200001010000 "$STALE3" 2>/dev/null
  chmod 0555 "$SB/state" 2>/dev/null
  if touch "$SB/state/.wt" 2>/dev/null; then
    rm -f "$SB/state/.wt" 2>/dev/null; chmod 0755 "$SB/state" 2>/dev/null
    echo "SKIP [T13] unremovable-stale-claim cell — this uid writes through mode 0555 (root?)"
  else
    rc=$(run_obs_as 1); outsz=$(wc -c < "$SB/out")
    chmod 0755 "$SB/state" 2>/dev/null
    # Assert the NOTICE, not merely "some bytes" — unrelated stdout would satisfy a byte count.
    [ "$rc" = "0" ] && grep -q '2\.1\.273 -> 2\.1\.275' "$SB/out" \
      && check "[T13] stale claim + unwritable state dir -> still announces (a dead owner must not silence forever)" ok \
      || check "[T13] stale claim + unwritable state dir -> still announces (a dead owner must not silence forever)" "fail" \
               "rc=$rc outsz=$outsz out=$(head -c 100 "$SB/out") — a dead claim was treated as a live owner"
  fi
  /bin/rmdir "$STALE3" 2>/dev/null

  # T14: THE RESIDUE POLICY, pinned deliberately. When no claim can be taken and none exists,
  # the outcome is indeterminate by construction — you cannot serialise without a serialising
  # primitive — and it admits exactly two policies: emit (tell the operator twice) or exit
  # (tell them zero times). This observer chooses EMIT, because the brief rules a missed notice
  # the defect and a duplicate mere noise. Two claimless runs against an unadvanced stamp must
  # BOTH emit. This cell exists so that choice cannot be quietly flipped to silence by someone
  # "fixing" a duplicate-delivery report without reading why it is there.
  cat > "$SHIM/mkdir" <<'SHIMEOF'
#!/usr/bin/env bash
exit 1
SHIMEOF
  chmod +x "$SHIM/mkdir"
  printf '2.1.273\n' > "$STAMP"
  PATH="$SHIM:$PATH" CLAUDE_CODE_SESSION_ATTENDED=1 CC_OBS_STATE_FILE="$STAMP" \
       CC_BIN_LINK="$LINK" CC_OBS_MANIFEST="$MANIFEST" bash "$INSTALLED_OBS" </dev/null >"$SB/r1" 2>/dev/null
  printf '2.1.273\n' > "$STAMP"
  PATH="$SHIM:$PATH" CLAUDE_CODE_SESSION_ATTENDED=1 CC_OBS_STATE_FILE="$STAMP" \
       CC_BIN_LINK="$LINK" CC_OBS_MANIFEST="$MANIFEST" bash "$INSTALLED_OBS" </dev/null >"$SB/r2" 2>/dev/null
  # The transition LINE, not a byte count: a byte count is satisfied by any stray stdout.
  n1=$(grep -c '2\.1\.273 -> 2\.1\.275' "$SB/r1"); n2=$(grep -c '2\.1\.273 -> 2\.1\.275' "$SB/r2")
  [ "$n1" -eq 1 ] && [ "$n2" -eq 1 ] \
    && check "[T14] no claim takeable -> BOTH claimless consumers emit (the documented residue: duplicate beats silence)" ok \
    || check "[T14] no claim takeable -> BOTH claimless consumers emit (the documented residue: duplicate beats silence)" "fail" \
             "run1 notices=$n1 run2 notices=$n2 (want 1 each) — the fail-open residue was flipped to silence"
  rm -rf "$SHIM"

  # ── T15: a claim whose OWNER DIED must not hold the notice for 300s ─────────
  # "Fresh" was standing in for "the owner is still working", and the two come apart exactly
  # where it matters: Claude Code terminates a still-running SessionStart hook when the session
  # exits, so a hook can create the claim and die before emitting. Every attended session
  # arriving in the next five minutes then exits against a claim nobody owns -- ZERO lanes told.
  # Reproduced by the close-gate reviewer with a real process that claimed and exited
  # (output_bytes=0, stamp unmoved, claim_age_seconds=0). Liveness is now OBSERVED via
  # /proc/<pid>, which is a READ of a foreign claim and so keeps the no-mutation rule.
  # RED against cross-repo 0cda8beb9.
  printf '2.1.273\n' > "$STAMP"
  DEADC="$STAMP.claim.2.1.275"; rm -rf "$DEADC"
  # A real short-lived process creates the claim and records its own pid, then exits.
  bash -c 'mkdir -p "$1"; printf "%s\n" "$$" > "$1/pid"' _ "$DEADC"
  _dpid=$(cat "$DEADC/pid" 2>/dev/null)
  _dage=$(( $(date +%s) - $(stat -c %Y "$DEADC" 2>/dev/null || echo 0) ))
  if [ -r "/proc/$_dpid/stat" ]; then
    echo "SKIP [T15] dead-owner cell — pid $_dpid was recycled before the check"
  else
    rc=$(run_obs_as 1)
    [ "$rc" = "0" ] && grep -q '2\.1\.273 -> 2\.1\.275' "$SB/out" \
      && check "[T15] claim whose owner DIED -> announces immediately, no 300s wait (age ${_dage}s)" ok \
      || check "[T15] claim whose owner DIED -> announces immediately, no 300s wait (age ${_dage}s)" "fail" \
               "rc=$rc outsz=$(wc -c < "$SB/out") — a dead owner held the notice on freshness alone"
  fi
  rm -rf "$DEADC"

  # T15b: the inverse, or T15 would license ignoring every claim. A LIVE owner is still
  # respected: this shell claims, stays alive across the run, and the observer must stay silent.
  printf '2.1.273\n' > "$STAMP"
  LIVEC="$STAMP.claim.2.1.275"; rm -rf "$LIVEC"; mkdir -p "$LIVEC"
  printf '%s\n' "$$" > "$LIVEC/pid"
  rc=$(run_obs_as 1); outsz=$(wc -c < "$SB/out")
  [ "$rc" = "0" ] && [ "$outsz" -eq 0 ] && [ "$(cat "$STAMP" 2>/dev/null)" = "2.1.273" ] \
    && check "[T15b] claim whose owner is ALIVE -> still respected (T15 did not license ignoring claims)" ok \
    || check "[T15b] claim whose owner is ALIVE -> still respected (T15 did not license ignoring claims)" "fail" \
             "rc=$rc outsz=$outsz stamp=$(cat "$STAMP" 2>/dev/null)"
  rm -rf "$LIVEC"
fi

echo "---"
echo "$PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
