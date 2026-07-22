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
#   - DRY_RUN=0 env still publishes (the automation path), DRY_RUN=<junk> rehearses
#
# INVARIANT (cross-file contract): the sibling convention lint
# probe-publisher-scripts-rehearse-by-default.sh asserts this shape for EVERY publisher
# in scripts/ — this probe is the deep check for one script, that one is the sweep.
#
# NOTE: the --push case redirects PUBLIC_REMOTE to a local bare repo via the env
# override the script already honors. It never contacts github.com. If that override is
# ever removed, this probe MUST be reworked, not "fixed" by pointing at the real remote.
#
# Backs: docs/decisions.md 2026-07-21 sync-mirror publish-gate row.
#
# Run: bash tests/probes/probe-sync-mirror-publish-gate.sh
#
# SAFE_FOR_LIVE: yes   (the only push target is a mktemp bare repo passed through
#                       PUBLIC_REMOTE; no network, no writes to the source repo, no
#                       contact with git@github.com:0xdhx/dhx-hooks.git. Runs are
#                       confined to a mktemp dir removed on EXIT.)

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO/scripts/sync-public-mirror.sh"

if [[ ! -f "$SCRIPT" ]]; then
  echo "FAIL script not found: $SCRIPT"
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

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
_assert "[1] default is rehearse (DRY_RUN defaults to 1)" "yes" \
  "$(grep -qE '^DRY_RUN="\$\{DRY_RUN:-1\}"' "$SCRIPT" && echo yes || echo no)"
_assert "[2] --push is the only argv path that clears it" "yes" \
  "$(grep -qE '^\s*--push\)\s*DRY_RUN=0;' "$SCRIPT" && echo yes || echo no)"
_assert "[3] unknown args exit 2 (no fall-through)" "yes" \
  "$(grep -qE 'exit 2 ;;' "$SCRIPT" && echo yes || echo no)"
_assert "[4] normalization: anything but explicit 0 rehearses" "yes" \
  "$(grep -qE '^\[ "\$DRY_RUN" = "0" \] \|\| DRY_RUN=1' "$SCRIPT" && echo yes || echo no)"

# --- Mode banner: what the operator sees BEFORE the work starts ------------
# The incident turned on there being no way to tell a rehearsal from a publish until
# after the fact, so the banner is part of the contract, not decoration.
_mode() { # $@ -> "DRY" | "LIVE" | "REFUSED" | "?"
  local out
  out=$(cd "$REPO" && timeout 20 bash "$SCRIPT" "$@" 2>&1 | head -20)
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

RC_BOGUS=$( cd "$REPO" && bash "$SCRIPT" --bogus >/dev/null 2>&1; echo $? )
_assert "[12] refusal exit code is 2" "2" "$RC_BOGUS"

# --- Env-var semantics ------------------------------------------------------
# NOTE: capture to a variable, then match — do NOT pipe into `head | grep -q` under
# `set -o pipefail`. `head` closing the pipe SIGPIPEs the producer (141), the pipeline
# inherits that non-zero, and `&& X || Y` then takes the WRONG branch regardless of what
# grep found. That bug shipped in this probe's first draft and inverted both cases
# (see tests/probes/probe-sigpipe-pipefail-shapes.sh for the general shape).
_env_mode() { # $1 DRY_RUN value -> "DRY" | "LIVE" | "?"
  local out
  out=$(cd "$REPO" && DRY_RUN="$1" timeout 20 bash "$SCRIPT" 2>&1)
  case "$out" in
    *"MODE: DRY RUN"*)      echo "DRY" ;;
    *"MODE: LIVE PUBLISH"*) echo "LIVE" ;;
    *) echo "?" ;;
  esac
}
_assert "[13] DRY_RUN=0 (automation path) publishes" "LIVE" "$(_env_mode 0)"
_assert "[14] DRY_RUN=junk rehearses (not treated as 'set therefore live')" "DRY" \
  "$(_env_mode junk)"

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

echo "---"
echo "$PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]] || exit 1
exit 0
