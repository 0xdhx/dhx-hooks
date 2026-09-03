#!/usr/bin/env bash
# probe-mirror-workflow-gate.sh
#
# Static gate probe for .github/workflows/publish-mirror.yml — the promotion half of the
# build/promote split for the public mirror.
#
# INVARIANT: the workflow's publish job must (a) be attached to an Environment, which is
# where the required-reviewer approval lives, (b) be reachable ONLY by a manual dispatch
# that explicitly asks to publish, and (c) be the only job that touches the deploy-key
# secret. The rehearsal job must hold NO credential — that is what makes it structurally
# incapable of publishing, rather than merely instructed not to.
#
# WHY STATIC CHECKS ARE WORTH IT HERE: the gate is one line (`environment:`). Deleting it
# leaves a workflow that still runs, still says "publish", and silently loses the human
# approval — a green pipeline with the safety removed. That is the same failure shape as
# the 2026-07-21 incidents (a flag that read as a rehearsal, a probe that read as safe),
# so it gets an assertion rather than a comment.
#
# KNOWN LIMIT: these are structural assertions about the workflow FILE. A green here means
# the workflow asks for its gates; it does not prove GitHub is enforcing them. Two pieces
# of this gate live in GitHub's settings rather than in the repo, and they are no longer
# in the same position:
#   - the `publish-mirror` Environment's required reviewer — still unproven here, and in
#     fact absent (unarmable on this plan). Verified out-of-band: gh api
#     repos/:owner/:repo/environments/publish-mirror
#   - the mirror's `block-force-push-main` ruleset — no longer unwatched. Check [16] pins
#     the step, and `scripts/verify-mirror-ruleset.sh` running weekly in the rehearse job
#     does the actual asserting against the live API. Static probe pins the shape; the
#     scheduled job pins the state.
#
# Backs: docs/decisions.md 2026-07-22 mirror CI promotion row, and the 2026-09-03
# mirror-ruleset-detection row.
#
# Run: bash tests/probes/probe-mirror-workflow-gate.sh
#
# SAFE_FOR_LIVE: yes   (read-only static analysis of a repo file — no execution, no
#                       writes, no network, no GitHub API calls.)

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WF="$REPO/.github/workflows/publish-mirror.yml"

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

_assert "[1] the publish workflow exists" "yes" \
  "$([[ -f "$WF" ]] && echo yes || echo no)"

if [[ ! -f "$WF" ]]; then
  echo "---"
  echo "$PASSED passed, $((FAILED + 1)) failed (workflow missing — remaining checks skipped)"
  exit 1
fi

# Split the file into the two job bodies so credential checks can be attributed to the
# right job. Crude line-range slicing beats a YAML parser dependency for three jobs.
REHEARSE_BODY=$(awk '/^  rehearse:/,/^  publish:/' "$WF")
PUBLISH_BODY=$(awk '/^  publish:/,0' "$WF")

# Comment-stripped view, for the checks that assert a count of ZERO. A full-line comment
# REFERENCES nothing, so a comment warning "don't put secrets. or github.token here" was
# itself enough to fail [6] and [17] — the assertion firing on the documentation of the
# rule it enforces. Positive checks keep the full body; only the zero-count ones use this.
REHEARSE_CODE=$(grep -v '^[[:space:]]*#' <<< "$REHEARSE_BODY")

# --- The gate itself --------------------------------------------------------
_assert "[2] publish job is attached to an Environment (the approval gate)" "yes" \
  "$(grep -qE '^\s*environment:\s*publish-mirror' <<< "$PUBLISH_BODY" && echo yes || echo no)"

_assert "[3] publish job requires a manual dispatch (schedule cannot publish)" "yes" \
  "$(grep -qE "if:.*workflow_dispatch" <<< "$PUBLISH_BODY" && echo yes || echo no)"

_assert "[4] publish job requires the publish input to be explicitly true" "yes" \
  "$(grep -qE "inputs\.publish\s*==\s*'true'" <<< "$PUBLISH_BODY" && echo yes || echo no)"

_assert "[5] the publish input defaults to false (rehearsal)" "yes" \
  "$(grep -qE '^\s*default:\s*false' "$WF" && echo yes || echo no)"

# --- The credential split ---------------------------------------------------
# The rehearsal's safety is that it has nothing to publish WITH. If a secret ever appears
# in that job, the split is gone and only the script's own gate remains.
_assert "[6] rehearse job references NO secret" "0" \
  "$(grep -c 'secrets\.' <<< "$REHEARSE_CODE" | tr -d ' ')"

_assert "[7] publish job loads the deploy key from secrets" "yes" \
  "$(grep -qE 'secrets\.MIRROR_DEPLOY_KEY' <<< "$PUBLISH_BODY" && echo yes || echo no)"

_assert "[8] publish job refuses when the secret is absent (no ambient fallback)" "yes" \
  "$(grep -qE 'REFUSE: MIRROR_DEPLOY_KEY secret is not set' <<< "$PUBLISH_BODY" && echo yes || echo no)"

# --- Build correctness ------------------------------------------------------
# A shallow clone silently produces a TRUNCATED mirror: filter-repo rewrites whatever
# history it is given, so the failure is a quietly incomplete publish, not an error.
_assert "[9] both jobs check out full history (fetch-depth: 0)" "2" \
  "$(grep -c 'fetch-depth: 0' "$WF" | tr -d ' ')"

_assert "[10] rehearse runs the script in rehearsal mode" "yes" \
  "$(grep -qE 'sync-public-mirror\.sh --dry-run' <<< "$REHEARSE_BODY" && echo yes || echo no)"

_assert "[11] publish runs the script with --push" "yes" \
  "$(grep -qE 'sync-public-mirror\.sh --push' <<< "$PUBLISH_BODY" && echo yes || echo no)"

_assert "[12] publish depends on a green rehearsal" "yes" \
  "$(grep -qE '^\s*needs:\s*rehearse' <<< "$PUBLISH_BODY" && echo yes || echo no)"

# Two concurrent publishes would collide late, after minutes of filtering, on the lease.
_assert "[13] workflow serializes runs (concurrency group)" "yes" \
  "$(grep -qE '^\s*group:\s*publish-mirror' "$WF" && echo yes || echo no)"

_assert "[14] workflow requests least privilege (contents: read)" "yes" \
  "$(grep -qE '^\s*contents:\s*read' "$WF" && echo yes || echo no)"

# --- The drift-catching rehearsal -------------------------------------------
# The weekly run is the reason the scrub classes stay small; without it the mirror rots
# between manual syncs and the next publish drowns in stale-reference failures.
_assert "[15] a schedule exists so drift is caught between publishes" "yes" \
  "$(grep -qE '^\s*- cron:' "$WF" && echo yes || echo no)"

# --- The remote-settings watchdog (2026-09-03) -------------------------------
# The KNOWN LIMIT above is now half-closed. The mirror's `block-force-push-main`
# ruleset still lives in GitHub's settings rather than in this repo, but the weekly
# rehearsal asserts it, so switching it off surfaces within a week instead of never.
# Deleting THAT step restores the silence — hence an assertion rather than a comment.
_assert "[16] rehearse job asserts the mirror ruleset is still armed" "yes" \
  "$(grep -qE 'verify-mirror-ruleset\.sh' <<< "$REHEARSE_BODY" && echo yes || echo no)"

# Check [6] greps for `secrets.` — which `${{ github.token }}` does not match. The
# obvious way to authenticate that read would therefore pass [6] while putting a
# credential back into the job that is supposed to have none: the letter of the
# assertion kept, the property it exists to protect gone. The read is unauthenticated
# because the mirror is public and needs no token. This refuses the other spelling.
_assert "[17] rehearse job holds no credential in ANY spelling (not even github.token)" "0" \
  "$(grep -cE 'github\.token|GITHUB_TOKEN' <<< "$REHEARSE_CODE" | tr -d ' ')"

echo "---"
echo "$PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]] || exit 1
exit 0
