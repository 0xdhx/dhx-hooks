#!/usr/bin/env bash
# verify-mirror-ruleset.sh
#
# Asserts that the public mirror's branch-protection ruleset is STILL ARMED.
#
# WHY THIS EXISTS. `0xdhx/dhx-hooks` carries the ruleset `block-force-push-main`
# (id 22160551), which is what revokes the local publish capability server-side.
# Its armed state is REMOTE SETTINGS, not a tracked file. If it is deleted, set to
# `enforcement: disabled`, or retargeted off `main`, then every probe in this repo
# stays green, every document still claims the gate exists, and the only symptom is
# a local `--push` quietly succeeding. That is a silent inversion of a documented
# guarantee — the failure shape most worth catching, and the one nothing in the repo
# could see until this script existed.
#
# WHY IT ASKS `/rules/branches/<branch>` AND NOT `/rulesets`. `/rulesets` answers
# "does a ruleset object exist", which stays TRUE for a ruleset that has been
# disabled or pointed at some other ref — the two cheapest ways to switch the gate
# off without deleting anything. `/rules/branches/<branch>` answers the question
# actually being asked: is this branch protected RIGHT NOW.
#
# WHY IT HOLDS NO CREDENTIAL. Its home is the `publish-mirror` workflow's `rehearse`
# job, whose defining property is that it has no key with which to push — that is
# what makes it structurally incapable of publishing rather than merely instructed
# not to (`probe-mirror-workflow-gate.sh` check [6] pins this). The mirror is a
# PUBLIC repo and both ruleset endpoints answer unauthenticated, so the invariant is
# preserved exactly rather than worked around. `${{ github.token }}` would slip past
# check [6]'s `secrets.` pattern while putting a credential back in the job; check
# [17] exists to refuse that spelling specifically.
#
# EXIT CODES
#   0  every expected rule is in force (or the check was rate-limited — see below)
#   1  the endpoint answered and an expected rule is MISSING: the gate is off
#   2  the endpoint could not be reached or returned something unparseable
#
# KNOWN LIMIT — rate-limiting degrades to INCONCLUSIVE, not red. Unauthenticated
# api.github.com is limited per source IP, and hosted runners share egress IPs. A
# 403/429 therefore means "could not look", which is not evidence the gate is off.
# Failing red on it would produce weekly false alarms, and an alarm you learn to
# ignore is worse than no alarm. It prints loudly and exits 0. The consequence is
# honest and worth stating: a week that gets rate-limited is a week unchecked.
#
# KNOWN LIMIT — this is DETECTION, not prevention, and it runs on the schedule of
# whatever invokes it. A ruleset deleted on Tuesday surfaces on the following
# Monday's rehearsal. An admin can still delete their own ruleset; this makes that
# visible within a week instead of never.
#
# Extra rules beyond the expected set are NOT a failure — they are additive
# protection. Only a MISSING expected rule is.
#
# Run:
#   bash scripts/verify-mirror-ruleset.sh
#   MIRROR_BRANCH=some-unprotected-branch bash scripts/verify-mirror-ruleset.sh   # red control
#
# Backs: docs/decisions.md 2026-09-03 mirror-ruleset-detection row.

set -uo pipefail

MIRROR_REPO="${MIRROR_REPO:-0xdhx/dhx-hooks}"
MIRROR_BRANCH="${MIRROR_BRANCH:-main}"
# Space-separated. Keep in step with the ruleset itself; a rule added there and not
# here is simply unasserted, which is the quiet half of the same problem.
MIRROR_EXPECT_RULES="${MIRROR_EXPECT_RULES:-non_fast_forward deletion}"

API="https://api.github.com/repos/${MIRROR_REPO}/rules/branches/${MIRROR_BRANCH}"

echo "[ruleset] asking ${API}"
echo "[ruleset] expecting: ${MIRROR_EXPECT_RULES}"

BODY="$(mktemp)"
trap 'rm -f "$BODY"' EXIT

# No Authorization header, deliberately. See "WHY IT HOLDS NO CREDENTIAL" above.
STATUS="$(curl -sS -o "$BODY" -w '%{http_code}' \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  "$API" 2>/dev/null)" || STATUS="000"

case "$STATUS" in
  200) ;;
  403|429)
    echo "[ruleset] INCONCLUSIVE: HTTP $STATUS from an unauthenticated read (rate limit)." >&2
    echo "[ruleset]   This is NOT evidence the ruleset is gone — it means the check could" >&2
    echo "[ruleset]   not look. This run is unchecked. Verify by hand if it repeats:" >&2
    echo "[ruleset]     gh api repos/${MIRROR_REPO}/rules/branches/${MIRROR_BRANCH}" >&2
    exit 0
    ;;
  *)
    echo "[ruleset] FAIL: HTTP $STATUS from $API — cannot determine the gate's state." >&2
    head -c 400 "$BODY" >&2; echo >&2
    exit 2
    ;;
esac

ACTUAL="$(jq -r 'if type == "array" then .[].type else empty end' "$BODY" 2>/dev/null | sort -u)"
if [ -z "$ACTUAL" ] && ! jq -e 'type == "array"' "$BODY" >/dev/null 2>&1; then
  echo "[ruleset] FAIL: response was not a rules array — cannot determine the gate's state." >&2
  head -c 400 "$BODY" >&2; echo >&2
  exit 2
fi

echo "[ruleset] in force on ${MIRROR_BRANCH}: $(printf '%s' "${ACTUAL:-<none>}" | tr '\n' ' ')"

MISSING=""
for want in $MIRROR_EXPECT_RULES; do
  printf '%s\n' "$ACTUAL" | grep -qx -- "$want" || MISSING="${MISSING} ${want}"
done

if [ -n "$MISSING" ]; then
  echo "" >&2
  echo "[ruleset] FAIL: the mirror's branch protection is NOT what this repo claims." >&2
  echo "[ruleset]   missing rule(s):${MISSING}" >&2
  echo "[ruleset]   on:              ${MIRROR_REPO} @ refs/heads/${MIRROR_BRANCH}" >&2
  echo "" >&2
  echo "[ruleset]   What this means: a local 'sync-public-mirror.sh --push' may now" >&2
  echo "[ruleset]   SUCCEED. Documents in this repo state that it cannot. One of the" >&2
  echo "[ruleset]   two is wrong and it is not the remote." >&2
  echo "[ruleset]   Inspect:  gh api repos/${MIRROR_REPO}/rulesets --jq '.[]|{id,name,enforcement}'" >&2
  echo "[ruleset]   Context:  docs/scripts-reference.md § sync-public-mirror.sh" >&2
  exit 1
fi

echo "[ruleset] OK: every expected rule is in force."
exit 0
