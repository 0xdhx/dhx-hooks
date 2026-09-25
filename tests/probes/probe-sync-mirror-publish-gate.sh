#!/usr/bin/env bash
# probe-sync-mirror-publish-gate.sh
#
# Regression probe for the publish gate in scripts/sync-public-mirror.sh.
#
# INVARIANT (the one that matters): a bare invocation REHEARSES. Publishing the public
# mirror requires an explicit `--push`. The 2026-07-21 incident was the inverse — the
# script gated on a DRY_RUN=1 env var with no argv parsing, so `--dry-run` was silently
# discarded and a rehearsal force-pushed 0xdhx/dhx-hooks. A flag-guarded dangerous
# DEFAULT is the same trap with an extra step; only the safe default removes it.
#
# Asserted here:
#   - bare invocation announces DRY RUN and pushes nothing
#   - --dry-run / -n likewise (kept for existing runbooks + muscle memory)
#   - an unrecognized argument REFUSES (exit 2) rather than falling through to a publish
#   - a typo'd flag (`--dryrun`, `--dry_run`) hits the refusal, NOT the publish path
#   - --push does reach the push (proved against a temp BARE repo, never the real remote)
#   - env DRY_RUN can only push the mode TOWARD rehearsal; publishing needs argv --push
#   - contradictory flags (--dry-run --push, either order) REFUSE instead of last-wins
#   - a set-but-EMPTY PUBLIC_REMOTE refuses instead of defaulting to production
#   - the probe process CANNOT authenticate to the production remote at all [20]
#   - a REJECTED push surfaces the remote's own words instead of asserting a cause,
#     and never claims "public main moved during this run" when it did not [41-44]
#
# INVARIANT (cross-file contract): the sibling convention lint
# probe-publisher-scripts-rehearse-by-default.sh asserts this shape for EVERY publisher
# in scripts/ — this probe is the deep check for one script, that one is the sweep.
#
# NOTE: the --push case redirects PUBLIC_REMOTE to a local bare repo AND runs under a
# credential lockout (see CAPABILITY LOCKOUT below) so a push to github.com cannot
# authenticate even if the override is lost. It does still make read-only HTTPS GETs:
# the script's step-6 permalink check hits raw.githubusercontent.com with hardcoded URLs
# that PUBLIC_REMOTE does not redirect (Codex review finding 11). Read-only, but the
# containment claim must be stated accurately rather than as "no network".
#
#
# Run: bash tests/probes/probe-sync-mirror-publish-gate.sh
#
# HERMETIC_TIER: no
# SUITE_TIMEOUT: 120   (measured 26-27s idle, 33s under load, and its own header above
#                       records 28s/50s. O(commits) and climbing, so this budget will need
#                       revisiting — the [BUDGET] line reports it every run so the creep is
#                       visible rather than arriving as a permanent red.)
#   COST, not liveness. This probe runs the REAL scripts/sync-public-mirror.sh five
#   times, and each run does `git clone --no-local` + `git filter-repo` over the FULL
#   history. Measured 2026-09-05: 28s idle, 50s under load, against run-probes.sh's 30s
#   per-probe cap — and the runtime is O(commits), so it gets worse forever (2,137
#   commits at time of writing). It had already blocked two unrelated commits.
#   Deliberately NOT tagged LIVE_RUNTIME: yes to achieve this. That axis asks "can an
#   upstream install flip this probe's verdict with the repository unchanged?" and the
#   answer here is no — tagging it so would have been a false answer written to buy a
#   scheduling outcome, which is the exact defect probe-hermetic-tier-contract-parity.sh
#   exists to prevent. See docs/decisions.md 2026-09-05.
#   Runs instead in the weekly rehearsal (.github/workflows/publish-mirror.yml), which
#   already checks out full history and installs git-filter-repo for the same reason.
# SAFE_FOR_LIVE: yes   (push target is a mktemp bare repo + a git credential lockout that
#                       makes authenticating to github.com impossible for this process
#                       and its children; no writes to the source repo; runs confined to
#                       a mktemp dir removed on EXIT. NOT "no network": step 6 issues
#                       read-only raw.githubusercontent.com GETs — see the NOTE above.)

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO/scripts/sync-public-mirror.sh"

if [[ ! -f "$SCRIPT" ]]; then
  echo "FAIL script not found: $SCRIPT"
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- CAPABILITY LOCKOUT (Codex adversarial review 2026-07-21, findings 1 + 4) ---------
# Binding PUBLIC_REMOTE per-invocation is a CONVENTION, and conventions are what failed
# twice. The review's decisive point: safety still depended on mutable code-under-test
# honoring an environment seam. Two concrete refutations it produced —
#   (a) rename PUBLIC_REMOTE in the publisher and forget the probe: assertion [19] stays
#       green (every caller still spells the old name), the publisher ignores it, and the
#       end-to-end --push force-pushes PRODUCTION before [17] fails. A publisher-only
#       commit does not even run this suite (verify-hook-patterns.sh:318 triggers on
#       dhx/*.js + tests/probes/ only), so the rename lands unguarded.
#   (b) `PUBLIC_REMOTE="$SAFE_REMOTE" true; bash "$SCRIPT" --push` passes the lexical
#       self-lint while the script receives no override at all.
# So: revoke the CAPABILITY. Every git child of this probe runs with an ssh command that
# cannot authenticate to anything. The local fixture is a filesystem path and needs no
# ssh, so the fixture keeps working while a push to github.com fails at auth — even if
# every override, flag, and lint in this file were deleted.
export GIT_SSH_COMMAND='ssh -o IdentitiesOnly=yes -o IdentityFile=/dev/null -o IdentityAgent=none -o BatchMode=yes -o ConnectTimeout=5'
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/true
export GIT_CONFIG_NOSYSTEM=1

# EVERY invocation in this file is ALSO bound to a local fixture remote — belt to the
# lockout's braces, not a substitute for it.
SAFE_REMOTE="$TMP/safe-remote.git"
git init --bare -q "$SAFE_REMOTE"
export PUBLIC_REMOTE="$SAFE_REMOTE"   # inherited by every child, independent of line spelling

# Fail closed if the fixture is not local. A probe that silently loses its override is
# the exact shape that force-pushed production on 2026-07-21.
case "$SAFE_REMOTE" in
  /*) : ;;
  *) echo "FAIL refusing to run: fixture remote is not an absolute local path"; exit 1 ;;
esac
case "$SAFE_REMOTE" in
  *github.com*|*git@*) echo "FAIL refusing to run: fixture remote looks remote"; exit 1 ;;
esac

PASSED=0
FAILED=0

_assert() { # $1 label, $2 expected, $3 actual
  if [[ "$2" == "$3" ]]; then
    echo "OK   $1"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL $1 (expected [$2], got [$3])"
    FAILED=$((FAILED + 1))
  fi
}

# --- Static assertions on the gate's shape ---------------------------------
# Cheap, and they fail loudly if the default is flipped back by an edit that never
# runs the expensive paths below.
_assert "[1] DRY_RUN is initialized safe, unconditionally" "yes" \
  "$(grep -qE '^DRY_RUN=1 ' "$SCRIPT" && echo yes || echo no)"
_assert "[2] --push is the ONLY thing that clears it" "yes" \
  "$([ "$(grep -cE '^\[ "\$SAW_PUSH_FLAG" = "1" \] && DRY_RUN=0' "$SCRIPT")" = "1" ] \
      && echo yes || echo no)"
_assert "[3] unknown args exit 2 (no fall-through)" "yes" \
  "$(grep -qE 'exit 2 ;;' "$SCRIPT" && echo yes || echo no)"
_assert "[4] env can only push the mode TOWARD rehearsal" "yes" \
  "$(grep -qE '^\s+1\) DRY_RUN=1 ;;' "$SCRIPT" && echo yes || echo no)"

# --- Mode banner: what the operator sees BEFORE the work starts ------------
# The incident turned on there being no way to tell a rehearsal from a publish until
# after the fact, so the banner is part of the contract, not decoration.
# --print-mode is PARSE-ONLY: it resolves the mode, prints the banner, and exits before
# the clone/filter/scrub/push. Using it here is not a convenience — it is the fix for
# this probe's own 2026-07-21 defect. The first draft tested the LIVE banner by running
# the LIVE path under `timeout 20`, with no PUBLIC_REMOTE override on those cases. The
# timeout was not the safety it looked like: the pipeline reached the push inside 20s and
# force-pushed the PRODUCTION mirror from inside a pre-commit suite run. Never invoke a
# publish-capable mode here without both --print-mode and the fixture remote.
_mode() { # $@ -> "DRY" | "LIVE" | "REFUSED" | "?"
  local out
  out=$(cd "$REPO" && PUBLIC_REMOTE="$SAFE_REMOTE" timeout 20 bash "$SCRIPT" "$@" --print-mode 2>&1)
  case "$out" in
    *"MODE: DRY RUN"*)      echo "DRY" ;;
    *"MODE: LIVE PUBLISH"*) echo "LIVE" ;;
    *"REFUSE: unrecognized argument"*) echo "REFUSED" ;;
    *) echo "?" ;;
  esac
}

_assert "[5] bare invocation announces DRY RUN" "DRY" "$(_mode)"
_assert "[6] --dry-run announces DRY RUN" "DRY" "$(_mode --dry-run)"
_assert "[7] -n announces DRY RUN" "DRY" "$(_mode -n)"
_assert "[8] --push announces LIVE PUBLISH" "LIVE" "$(_mode --push)"

# Typo'd flags must land on the refusal, never the publish path. This is the exact
# 2026-07-21 shape: an argument the script does not understand.
_assert "[9] --dryrun (typo) refuses" "REFUSED" "$(_mode --dryrun)"
_assert "[10] --dry_run (typo) refuses" "REFUSED" "$(_mode --dry_run)"
_assert "[11] --bogus refuses" "REFUSED" "$(_mode --bogus)"

# Override set here too, though this path refuses at parse time — "I reasoned it was
# safe" is what produced the production push. The rule is unconditional: no invocation
# in this file sees the default remote.
RC_BOGUS=$( cd "$REPO" && PUBLIC_REMOTE="$SAFE_REMOTE" bash "$SCRIPT" --bogus >/dev/null 2>&1; echo $? )
_assert "[12] refusal exit code is 2" "2" "$RC_BOGUS"

# --- Env-var semantics ------------------------------------------------------
# NOTE: capture to a variable, then match — do NOT pipe into `head | grep -q` under
# `set -o pipefail`. `head` closing the pipe SIGPIPEs the producer (141), the pipeline
# inherits that non-zero, and `&& X || Y` then takes the WRONG branch regardless of what
# grep found. That bug shipped in this probe's first draft and inverted both cases
# (see tests/probes/probe-sigpipe-pipefail-shapes.sh for the general shape).
_env_mode() { # $1 DRY_RUN value -> "DRY" | "LIVE" | "?"
  local out
  # Kept on ONE line on purpose: the [19] self-lint is deliberately line-based, so a
  # continuation would hide the override from it. Dumb-and-true beats clever-and-fooled.
  out=$(cd "$REPO" && DRY_RUN="$1" PUBLIC_REMOTE="$SAFE_REMOTE" timeout 20 bash "$SCRIPT" --print-mode 2>&1)
  case "$out" in
    *"MODE: DRY RUN"*)      echo "DRY" ;;
    *"MODE: LIVE PUBLISH"*) echo "LIVE" ;;
    *) echo "?" ;;
  esac
}
# [13]/[14] previously asserted that `DRY_RUN=0` PUBLISHES. Codex finding 2 refuted that
# as a design: an exported 0 from an unrelated command hours earlier turned a BARE
# invocation into a force-push, and the banner then lied ("--push given"). The env path
# was removed rather than documented; these now assert the removal. See [26]/[27].
_assert "[13] DRY_RUN=0 does NOT publish (env publish path removed)" "DRY" "$(_env_mode 0)"
_assert "[14] DRY_RUN=junk rehearses" "DRY" "$(_env_mode junk)"

# --- End-to-end: rehearsal pushes NOTHING, --push pushes SOMETHING ----------
# Both run the full pipeline against a temp bare repo standing in for the mirror.
BARE="$TMP/fake-mirror.git"
git init --bare -q "$BARE"

# `rev-parse HEAD` on an EMPTY bare repo prints the literal "HEAD" on stdout before
# failing — `--verify` is what makes the empty case cleanly non-zero.
# Read refs/heads/main — the ref the publisher writes (`push public HEAD:main`) — NEVER the
# bare repo's HEAD. A fresh bare HEAD points at init.defaultBranch: `main` on this machine,
# `master` on a stock CI runner, where HEAD then never resolves. That failed [17]/[37] on
# every weekly rehearsal from 2026-09-05 (when this probe moved into CI) and, worse, turned
# every "remote untouched" check ([16], [23], [39]) vacuous there. Reproduce locally with
# GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=init.defaultBranch GIT_CONFIG_VALUE_0=master.
_remote_head() { git --git-dir="$BARE" rev-parse --verify refs/heads/main 2>/dev/null || echo "EMPTY"; }

_assert "[15] fixture remote starts empty" "EMPTY" "$(_remote_head)"

# Rehearsal against the fixture remote — must leave it untouched.
( cd "$REPO" && PUBLIC_REMOTE="$BARE" timeout 900 bash "$SCRIPT" --dry-run >/dev/null 2>&1 )
_assert "[16] rehearsal leaves the remote untouched" "EMPTY" "$(_remote_head)"

# Live publish against the fixture remote — must land a commit.
PUSH_OUT=$( cd "$REPO" && PUBLIC_REMOTE="$BARE" timeout 900 bash "$SCRIPT" --push 2>&1 )
PUSHED="$(_remote_head)"
_assert "[17] --push lands a commit on the remote" "yes" \
  "$([[ "$PUSHED" != "EMPTY" && ${#PUSHED} -eq 40 ]] && echo yes || echo no)"

# And the published tree still passes the scrub invariants (a publish gate that ships
# unscrubbed content is not a working gate).
WORK="$TMP/verify-clone"
git clone -q "$BARE" "$WORK" 2>/dev/null
for token in acme-app "repos/<skills-monorepo>"; do
  HITS=$(grep -rIl "$token" "$WORK" --exclude-dir=.git 2>/dev/null | wc -l)
  _assert "[18/$token] published tree carries no '$token'" "0" "$HITS"
done

# --- Capability lockout is real, not decorative -----------------------------
# Prove the probe cannot authenticate to the production host even when explicitly aimed
# at it. This is the assertion that survives a renamed env var, a fooled lexical lint, or
# a deleted override — the three ways the review broke the convention-only design.
# (Read-only: a failed auth handshake, no ref update attempted.)
AUTH_OUT=$(git ls-remote git@github.com:0xdhx/dhx-hooks.git 2>&1; echo "rc=$?")
_assert "[20] probe process CANNOT authenticate to the production remote" "yes" \
  "$(grep -q 'rc=0' <<< "$AUTH_OUT" && echo no || echo yes)"

# --- Self-lint: no invocation in THIS file may see the default remote --------
# The 2026-07-21 production push came from three assertions in this very file that
# invoked the script without a PUBLIC_REMOTE override. Asserting it structurally beats
# remembering it: every line that runs the script must also bind the remote.
# Widened 2026-09-03: the trap cells below run MUTATED COPIES of the publisher, which a
# lint spelled `bash "$SCRIPT"` would not see at all — a new invocation path sliding past
# the very lint that exists because invocation paths slid past people. Match every
# script-variable invocation, not one spelling.
# Comment lines are stripped first: this very comment block quotes the invocation shape
# it is describing, and a lint that flags its own documentation trains people to ignore it.
UNGUARDED=$(grep -nE 'bash "\$(SCRIPT|MUTANT[A-Z_]*)"' "$0" | grep -v '^[0-9]\+:[[:space:]]*#' | grep -vc 'PUBLIC_REMOTE=')
_assert "[21] every script invocation in this probe binds PUBLIC_REMOTE" "0" "$UNGUARDED"

# --- --print-mode is genuinely side-effect-free (Codex finding 10) -----------
# The claim was "parse-only"; the first version ran repo discovery and created a temp dir
# before exiting, and no assertion checked either. Verify BOTH: no build dir is left
# behind, and the fixture remote is untouched by a print-mode LIVE-mode invocation.
BUILD_BEFORE=$(ls -d /tmp/dhx-hooks-public-* 2>/dev/null | wc -l)
FIX_BEFORE=$(git --git-dir="$SAFE_REMOTE" rev-parse --verify refs/heads/main 2>/dev/null || echo EMPTY)
( cd "$REPO" && PUBLIC_REMOTE="$SAFE_REMOTE" bash "$SCRIPT" --push --print-mode >/dev/null 2>&1 )
BUILD_AFTER=$(ls -d /tmp/dhx-hooks-public-* 2>/dev/null | wc -l)
FIX_AFTER=$(git --git-dir="$SAFE_REMOTE" rev-parse --verify refs/heads/main 2>/dev/null || echo EMPTY)
_assert "[22] --print-mode leaves no build dir" "$BUILD_BEFORE" "$BUILD_AFTER"
_assert "[23] --print-mode does not touch the remote" "$FIX_BEFORE" "$FIX_AFTER"

# --- Contradictory flags refuse (Codex finding 7) ---------------------------
RC_CONFLICT=$( cd "$REPO" && PUBLIC_REMOTE="$SAFE_REMOTE" bash "$SCRIPT" --dry-run --push >/dev/null 2>&1; echo $? )
_assert "[24] --dry-run --push refuses (no last-flag-wins)" "2" "$RC_CONFLICT"
RC_CONFLICT2=$( cd "$REPO" && PUBLIC_REMOTE="$SAFE_REMOTE" bash "$SCRIPT" --push --dry-run >/dev/null 2>&1; echo $? )
_assert "[25] --push --dry-run refuses (order-independent)" "2" "$RC_CONFLICT2"

# --- env DRY_RUN can only push TOWARD rehearsal (Codex finding 2) -----------
_assert "[26] env DRY_RUN=0 does NOT publish on a bare invocation" "DRY" "$(_env_mode 0)"
_assert "[27] env DRY_RUN=1 still rehearses" "DRY" "$(_env_mode 1)"

# --- set-but-empty override refuses rather than defaulting to production ----
RC_EMPTY=$( cd "$REPO" && PUBLIC_REMOTE="" bash "$SCRIPT" --push --print-mode >/dev/null 2>&1; echo $? )
_assert "[28] PUBLIC_REMOTE set-but-empty refuses" "2" "$RC_EMPTY"

# --- Partial-publish honesty: the guard that was a comment (2026-09-03) ------
# The publish-mirror workflow's FIRST real run force-pushed `main` and then died
# `exit 128` on `git tag -a` — "fatal: empty ident name" — because a CI runner has no
# user.name/user.email and the tag command, unlike the scrub commit beside it, did not
# supply one inline. The run went RED OVER A SUCCESSFUL PUBLISH.
#
# The script already had a hand-written warning for "main is out, the tag is not." It
# guarded the tag PUSH. The failure landed on the tag CREATION one line above, where
# `set -e` walked straight past it — and `MAIN_PUBLISHED`, set at the push expressly to
# power that warning, was set and NEVER READ anywhere in the file. These assertions exist
# because a guard aimed at the one failure someone imagined is not a guard.

# Static shape — cheap, and each one names a specific way the bug comes back.
_assert "[29] git tag -a supplies a committer identity inline" "yes" \
  "$(grep -qE '^\s+git -c user\.email=.* \\$' "$SCRIPT" \
     && grep -qE '^\s+tag -a "\$TAG_VERSION"' "$SCRIPT" && echo yes || echo no)"
_assert "[30] MAIN_PUBLISHED is READ, not merely assigned" "yes" \
  "$([ "$(grep -c 'MAIN_PUBLISHED' "$SCRIPT")" -ge 2 ] \
     && grep -qE '\$\{MAIN_PUBLISHED:-0\}' "$SCRIPT" && echo yes || echo no)"
_assert "[31] the EXIT trap routes through _sync_on_exit" "yes" \
  "$(grep -qE '^trap _sync_on_exit EXIT' "$SCRIPT" && echo yes || echo no)"

# The CI condition itself: NO committer identity reachable. Isolate exactly that —
# GIT_CONFIG_NOSYSTEM is already exported above, so an empty GIT_CONFIG_GLOBAL removes the
# last source. Do NOT also redirect HOME: `git-filter-repo` here is a ~/.local/bin shim
# that imports its module from ~/.local/lib, so a HOME override kills the build for a
# reason that has nothing to do with identity and makes the cell fail for the wrong cause.
# (Learned the hard way while writing this cell — a hostile-in-the-wrong-dimension fixture
# is just a broken test wearing a rigour costume.)
: > "$TMP/empty.gitconfig"
BARE_NOID="$TMP/fake-mirror-noident.git"; git init --bare -q "$BARE_NOID"

# Vacuity guard FIRST. If the fixture still has an identity, [33]/[34] pass for free and
# assert nothing — which is the failure mode this whole block exists to catch elsewhere.
_assert "[32] the fixture environment genuinely has NO committer identity" "yes" \
  "$(env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL GIT_CONFIG_GLOBAL="$TMP/empty.gitconfig" git var GIT_COMMITTER_IDENT >/dev/null 2>&1 && echo no || echo yes)"

RC_NOID=$( cd "$REPO" && PUBLIC_REMOTE="$BARE_NOID" env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL GIT_CONFIG_GLOBAL="$TMP/empty.gitconfig" timeout 900 bash "$SCRIPT" --push >/dev/null 2>&1; echo $? )
_assert "[33] a publish with no committer identity still succeeds" "0" "$RC_NOID"
_assert "[34] ...and the version tag actually lands" "yes" \
  "$(grep -q . < <(git --git-dir="$BARE_NOID" tag -l 2>/dev/null) && echo yes || echo no)"

# Drive the trap. The mutant lives under the repo's gitignored tmp/ because the publisher
# derives REPO_ROOT from `realpath "$0"/..` — a copy in /tmp resolves to a non-repo and
# dies before it could prove anything. Removed on EXIT.
MUTANT_DIR="$REPO/tmp"; mkdir -p "$MUTANT_DIR"
MUTANT_POST="$MUTANT_DIR/.probe-mutant-postpush-$$.sh"
MUTANT_PRE="$MUTANT_DIR/.probe-mutant-prepush-$$.sh"
trap 'rm -rf "$TMP" "$MUTANT_POST" "$MUTANT_PRE"' EXIT
awk '{print} /^MAIN_PUBLISHED=1/ {print "false  # probe: simulated post-push failure"}' \
  "$SCRIPT" > "$MUTANT_POST"
awk '{print} /^echo "\[sync\] BUILD_DIR=/ {print "false  # probe: simulated PRE-push failure"}' \
  "$SCRIPT" > "$MUTANT_PRE"

BARE_TRAP="$TMP/fake-mirror-trap.git"; git init --bare -q "$BARE_TRAP"
TRAP_OUT=$( cd "$REPO" && PUBLIC_REMOTE="$BARE_TRAP" timeout 900 bash "$MUTANT_POST" --push 2>&1; echo "rc=$?" )
_assert "[35] a post-push failure still exits non-zero" "yes" \
  "$(grep -q 'rc=0' <<< "$TRAP_OUT" && echo no || echo yes)"
_assert "[36] ...and says MAIN IS ALREADY PUBLISHED" "yes" \
  "$(grep -q 'MAIN IS ALREADY PUBLISHED' <<< "$TRAP_OUT" && echo yes || echo no)"
# The warning must be TRUE, not merely printed: the fixture really did receive the commit.
_assert "[37] ...and the remote genuinely holds the commit it names" "yes" \
  "$(git --git-dir="$BARE_TRAP" rev-parse --verify refs/heads/main >/dev/null 2>&1 && echo yes || echo no)"

# Negative control 1 — failed but NOT armed: an identical failure injected BEFORE the push
# must stay silent, or the warning is just noise on every red run.
BARE_PRE="$TMP/fake-mirror-prepush.git"; git init --bare -q "$BARE_PRE"
PRE_OUT=$( cd "$REPO" && PUBLIC_REMOTE="$BARE_PRE" timeout 900 bash "$MUTANT_PRE" --push 2>&1; echo "rc=$?" )
_assert "[38] a PRE-push failure does NOT claim anything was published" "yes" \
  "$(grep -q 'MAIN IS ALREADY PUBLISHED' <<< "$PRE_OUT" && echo no || echo yes)"
_assert "[39] ...and the remote is untouched" "EMPTY" \
  "$(git --git-dir="$BARE_PRE" rev-parse --verify refs/heads/main 2>/dev/null || echo EMPTY)"

# Negative control 2 — armed but NOT failed: free, reusing [17]'s captured output.
_assert "[40] a SUCCESSFUL publish prints no already-published warning" "yes" \
  "$(grep -q 'MAIN IS ALREADY PUBLISHED' <<< "$PUSH_OUT" && echo no || echo yes)"

# --- A rejected push must report the REMOTE's reason, not a guessed one ----
# Backs the 2026-09-03 mirror-ruleset row. `0xdhx/dhx-hooks` now carries an active
# `block-force-push-main` ruleset (non_fast_forward, bypass: DeployKey), so a local
# --push is REFUSED server-side — the designed outcome, and now the COMMON one.
# The branch used to swallow the push's stderr and print "lease refused — public main
# moved during this run" for every failure, so the designed refusal announced a cause
# that had not happened. Two different failures land here; only the remote can tell
# them apart, so the remote's text is the payload.
#
# Fixture shape: a bare repo that already HAS main (so REMOTE_MAIN is non-empty and the
# lease branch is the one exercised) whose pre-receive hook rejects. The lease therefore
# SUCCEEDS and the rule rejects — exactly the production shape, inverted from a stale
# lease.
BARE_REJECT="$TMP/fake-mirror-reject.git"; git init --bare -q "$BARE_REJECT"
SEED="$TMP/seed"; git init -q "$SEED"
( cd "$SEED" \
    && git -c user.email=p@probe.local -c user.name=probe commit -q --allow-empty -m seed \
    && git branch -M main \
    && git push -q "$BARE_REJECT" main ) >/dev/null 2>&1
REJECT_TIP_BEFORE=$(git --git-dir="$BARE_REJECT" rev-parse --verify main 2>/dev/null || echo NONE)
cat > "$BARE_REJECT/hooks/pre-receive" <<'HOOK'
#!/bin/sh
echo "PROBE_REMOTE_SAYS: Cannot force-push to this branch" >&2
exit 1
HOOK
chmod +x "$BARE_REJECT/hooks/pre-receive"

REJECT_OUT=$( cd "$REPO" && PUBLIC_REMOTE="$BARE_REJECT" timeout 900 bash "$SCRIPT" --push 2>&1; echo "rc=$?" )

_assert "[41] a rejected push says REFUSED and nothing was published" "yes" \
  "$(grep -q 'REFUSED. Nothing was published' <<< "$REJECT_OUT" && echo yes || echo no)"
# The load-bearing one: the remote's text reaches the operator. Swallowed stderr is
# invisible to every other assertion here — [41] passes just as well without it.
_assert "[42] ...and relays the REMOTE's own reason verbatim" "yes" \
  "$(grep -q 'PROBE_REMOTE_SAYS: Cannot force-push to this branch' <<< "$REJECT_OUT" && echo yes || echo no)"
# Negative control: the old misdiagnosis must not be asserted. main did not move.
_assert "[43] ...and does NOT claim public main moved during this run" "yes" \
  "$(grep -q 'moved during this run' <<< "$REJECT_OUT" && echo no || echo yes)"
_assert "[44] ...and the remote is genuinely untouched" "$REJECT_TIP_BEFORE" \
  "$(git --git-dir="$BARE_REJECT" rev-parse --verify main 2>/dev/null || echo NONE)"

echo "---"
echo "$PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]] || exit 1
exit 0
