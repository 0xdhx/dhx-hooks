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
# Backs: docs/decisions.md 2026-07-21 sync-mirror publish-gate row.
#
# Run: bash tests/probes/probe-sync-mirror-publish-gate.sh
#
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
_remote_head() { git --git-dir="$BARE" rev-parse --verify HEAD 2>/dev/null || echo "EMPTY"; }

_assert "[15] fixture remote starts empty" "EMPTY" "$(_remote_head)"

# Rehearsal against the fixture remote — must leave it untouched.
( cd "$REPO" && PUBLIC_REMOTE="$BARE" timeout 900 bash "$SCRIPT" --dry-run >/dev/null 2>&1 )
_assert "[16] rehearsal leaves the remote untouched" "EMPTY" "$(_remote_head)"

# Live publish against the fixture remote — must land a commit.
( cd "$REPO" && PUBLIC_REMOTE="$BARE" timeout 900 bash "$SCRIPT" --push >/dev/null 2>&1 )
PUSHED="$(_remote_head)"
_assert "[17] --push lands a commit on the remote" "yes" \
  "$([[ "$PUSHED" != "EMPTY" && ${#PUSHED} -eq 40 ]] && echo yes || echo no)"

# And the published tree still passes the scrub invariants (a publish gate that ships
# unscrubbed content is not a working gate).
WORK="$TMP/verify-clone"
git clone -q "$BARE" "$WORK" 2>/dev/null
for token in forgefinder "repos/skills"; do
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
UNGUARDED=$(grep -n 'bash "\$SCRIPT"' "$0" | grep -vc 'PUBLIC_REMOTE=')
_assert "[21] every script invocation in this probe binds PUBLIC_REMOTE" "0" "$UNGUARDED"

# --- --print-mode is genuinely side-effect-free (Codex finding 10) -----------
# The claim was "parse-only"; the first version ran repo discovery and created a temp dir
# before exiting, and no assertion checked either. Verify BOTH: no build dir is left
# behind, and the fixture remote is untouched by a print-mode LIVE-mode invocation.
BUILD_BEFORE=$(ls -d /tmp/dhx-hooks-public-* 2>/dev/null | wc -l)
FIX_BEFORE=$(git --git-dir="$SAFE_REMOTE" rev-parse --verify HEAD 2>/dev/null || echo EMPTY)
( cd "$REPO" && PUBLIC_REMOTE="$SAFE_REMOTE" bash "$SCRIPT" --push --print-mode >/dev/null 2>&1 )
BUILD_AFTER=$(ls -d /tmp/dhx-hooks-public-* 2>/dev/null | wc -l)
FIX_AFTER=$(git --git-dir="$SAFE_REMOTE" rev-parse --verify HEAD 2>/dev/null || echo EMPTY)
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

echo "---"
echo "$PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]] || exit 1
exit 0
