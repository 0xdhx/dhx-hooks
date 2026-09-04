#!/usr/bin/env bash
# probe-gh-issue-write.sh
#
# Regression probe for dhx-plugin/plugins/dhx/hooks/pre-tool-use-gh-issue-write.sh
# (PreToolUse:Bash HARD DENY for foreign-repo upstream writes — D-12, 2026-07-21).
#
# Invariant (post-D-12, verb set widened 2026-08-02 and again 2026-08-03): the hook DENIES —
# blocking — a foreign-repo MUTATION of an issue or PR thread (create / comment / edit / close /
# reopen / review / merge / ready, a `gh api` POST|PATCH|PUT|DELETE on an issue or PR path, or a
# `gh api graphql` carrying a mutation) when ALL of:
#   (a) the target owner is NOT in the hook's OWN_OWNERS list (or does not resolve), and
#   (b) no fresh /dhx:upstream marker exists for the session, and
#   (c) no fresh deliberate-bypass marker exists for the session.
# The deny is structured JSON on **exit 0** (`permissionDecision:"deny"` +
# `permissionDecisionReason` carrying the routing, plus `systemMessage` for the user).
# exit 0 is load-bearing: CC reads stdout JSON only on exit 0 — an exit-2 deny still
# blocks but discards the structured reason (cf. `updatedInput` "Ignored on exit 2",
# docs/hook-dev-guide.md L160), and the routing IS the point. exit 2 survives only as the
# emit-failure fallback (not reachable in-probe without breaking jq).
#
# It stays SILENT (no output, exit 0) when: the owner is own (`--repo 0xdhx/…`, a
# `repos/0xdhx/…` api path, or a cwd whose origin is 0xdhx), the skill marker is fresh
# (<5m), the bypass marker is fresh (<60s), the subcommand is different (`gh issue list`),
# token-anchoring rejects it (`create-something-else`, `mygh issue comment`, `edit-something-else`,
# `issue closed`), the call is a READ (`gh api` GET, or a graphql QUERY carrying no mutation
# token), or the shape is a documented NON-GOAL (`gh pr create`, raw `curl`).
#
# ORDER OF EVIDENCE — three classes below look alike and are not:
#   [50]-[63] BITE-TESTED arms. Each was measured SILENT against the pre-2026-08-03 hook, so each
#     is a real tooth. [53] and [59] are the two live incidents from the source report.
#   [65]-[68] PERMANENT TEETH, green before AND after. Live gsd-core consumers (`/gsd-inbox`,
#     `/gsd-ship`) passing a BARE NUMBER and surviving on ownership scoping — their staying green
#     is what proves the widening did not break them. Same role [44] plays for /dhx:review.
#   [72]-[73] CHARACTERIZATION only. `--edit-last` was ALREADY covered by the `issue comment` /
#     `pr comment` tokens and denied before this change; labelled so no reader mistakes them for
#     evidence of the widening (the source report called out this exact miswriting risk).
#
# INVARIANT (cross-file contract): the -write name must match hooks.json registration.
# INVARIANT (cross-file contract): the deny message names the bypass script, and that
# script must exist in this repo — a deny that routes to a missing script is a dead end.
#
# NOTE — matcher hazard: this probe's fixtures contain the literal `gh issue create`
# token, so they are built via jq from variables and kept OUT of any Bash tool command
# line. A test payload pasted into a command string trips the live hook (observed
# 2026-07-21 while smoke-testing this very change).
#
# Backs: docs/decisions.md 2026-07-21 D-12 hard-deny row (supersedes the 2026-07-10
# soft-warn row, whose 18 assertions this file replaces).
#
# Run: bash tests/probes/probe-gh-issue-write.sh
#
# SAFE_FOR_LIVE: yes   (hook subshell with synthetic stdin; CLAUDE_CONFIG_DIR is
#                       redirected to a mktemp dir so marker reads/writes hit a fixture,
#                       never live ~/.claude/dhx-tools; own-owner cwd cases use mktemp
#                       git repos with fake remotes; no repo/config/network writes. The
#                       hooks.json + bypass-script checks are read-only.)

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$REPO/dhx-plugin/plugins/dhx/hooks/pre-tool-use-gh-issue-write.sh"
MANIFEST="$REPO/dhx-plugin/plugins/dhx/hooks/hooks.json"
BYPASS="$REPO/scripts/dhx-upstream-bypass.sh"

if [[ ! -f "$HOOK" ]]; then
  echo "FAIL hook not found: $HOOK"
  exit 1
fi

TMP="$(mktemp -d)"
export CLAUDE_CONFIG_DIR="$TMP"
MARKERDIR="$TMP/dhx-tools"
mkdir -p "$MARKERDIR"
trap 'rm -rf "$TMP"' EXIT

# Fixture git repos for the cwd-origin owner-resolution path.
OWN_REPO="$TMP/own-repo"; FOREIGN_REPO="$TMP/foreign-repo"; BARE_DIR="$TMP/no-git"
mkdir -p "$OWN_REPO" "$FOREIGN_REPO" "$BARE_DIR"
git -C "$OWN_REPO" init -q 2>/dev/null
git -C "$OWN_REPO" remote add origin git@github.com:0xdhx/hooks.git 2>/dev/null
git -C "$FOREIGN_REPO" init -q 2>/dev/null
git -C "$FOREIGN_REPO" remote add origin https://github.com/open-gsd/gsd-core.git 2>/dev/null

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

# Command fragments assembled from variables — keeps the matcher tokens off any
# command line this probe itself might be pasted into.
GH="gh"; ISSUE="issue"; CREATE="create"; COMMENT="comment"; API="api"; PR="pr"

_json() { # $1 session_id, $2 command, $3 cwd (optional)
  jq -n --arg s "$1" --arg c "$2" --arg d "${3:-/tmp/x}" \
    '{session_id:$s, cwd:$d, tool_input:{command:$c}}'
}

# _verdict <json> -> "deny" | "silent" | "malformed"
# deny := stdout parses as JSON with permissionDecision=="deny", a non-empty
# permissionDecisionReason (the routing), and a non-empty systemMessage (user channel).
_verdict() {
  local out
  out=$(printf '%s' "$1" | bash "$HOOK" 2>/dev/null)
  if [[ -z "$out" ]]; then echo "silent"; return; fi
  if printf '%s' "$out" | jq -e \
      '(.hookSpecificOutput.permissionDecision == "deny")
       and ((.hookSpecificOutput.permissionDecisionReason // "") != "")
       and ((.systemMessage // "") != "")' >/dev/null 2>&1; then
    echo "deny"; return
  fi
  echo "malformed"
}

_rc() { printf '%s' "$1" | bash "$HOOK" >/dev/null 2>&1; echo "$?"; }

rm -f "$MARKERDIR"/.upstream-*

# --- Hard deny: foreign owner, no marker (the D-12 flip) ---
_assert "[1] foreign create, no marker -> deny" "deny" \
  "$(_verdict "$(_json s1 "$GH $ISSUE $CREATE --repo open-gsd/gsd-core --title x --body y")")"
_assert "[2] foreign comment, no marker -> deny" "deny" \
  "$(_verdict "$(_json s1 "$GH $ISSUE $COMMENT 2507 --repo open-gsd/gsd-core --body y")")"
_assert "[3] foreign owner via cwd origin -> deny" "deny" \
  "$(_verdict "$(_json s1 "$GH $ISSUE $COMMENT 42 --body y" "$FOREIGN_REPO")")"

# --- Deny exits 0 (structured), NOT 2 — stdout JSON is discarded on exit 2 ---
_assert "[4] deny path exits 0 (structured, not exit 2)" "0" \
  "$(_rc "$(_json s1 "$GH $ISSUE $CREATE --repo open-gsd/gsd-core --title x")")"
_assert "[5] no stderr noise on deny path" "" \
  "$(printf '%s' "$(_json s1 "$GH $ISSUE $CREATE --repo open-gsd/gsd-core --title x")" | bash "$HOOK" 2>&1 >/dev/null)"

# --- Deny reason routes: names both skill paths AND the bypass script ---
DENY_REASON=$(printf '%s' "$(_json s1 "$GH $ISSUE $CREATE --repo open-gsd/gsd-core --title x")" \
  | bash "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')
_assert "[6] deny reason names /dhx:upstream reply" "yes" \
  "$(grep -q '/dhx:upstream reply' <<< "$DENY_REASON" && echo yes || echo no)"
_assert "[7] deny reason names the bypass script" "yes" \
  "$(grep -q 'dhx-upstream-bypass.sh' <<< "$DENY_REASON" && echo yes || echo no)"

# --- Ownership scoping: own-owner writes are never gated (no friction on own repos) ---
_assert "[8] own owner via --repo -> silent" "silent" \
  "$(_verdict "$(_json s1 "$GH $ISSUE $CREATE --repo 0xdhx/hooks --title x")")"
_assert "[9] own owner via -R -> silent" "silent" \
  "$(_verdict "$(_json s1 "$GH $ISSUE $COMMENT 5 -R 0xdhx/dhx-skills --body y")")"
_assert "[10] own owner via cwd origin -> silent" "silent" \
  "$(_verdict "$(_json s1 "$GH $ISSUE $COMMENT 5 --body y" "$OWN_REPO")")"
_assert "[11] own owner via gh api path -> silent" "silent" \
  "$(_verdict "$(_json s1 "$GH $API repos/0xdhx/hooks/issues/1/comments -X POST -f body=hi")")"

# --- Fail-closed: owner unresolvable (no --repo, cwd not a git repo) -> deny ---
_assert "[12] unresolvable owner -> deny (fail-closed)" "deny" \
  "$(_verdict "$(_json s1 "$GH $ISSUE $CREATE --title x --body y" "$BARE_DIR")")"

# --- Fresh /dhx:upstream marker silences the gate (both verbs) ---
touch "$MARKERDIR/.upstream-marker-s2"
_assert "[13] foreign create, fresh skill marker -> silent" "silent" \
  "$(_verdict "$(_json s2 "$GH $ISSUE $CREATE --repo open-gsd/gsd-core --title x")")"
_assert "[14] foreign comment, fresh skill marker -> silent" "silent" \
  "$(_verdict "$(_json s2 "$GH $ISSUE $COMMENT 42 --repo open-gsd/gsd-core --body z")")"

# --- Stale skill marker (>5m) -> deny again (TTL not extended) ---
touch -d '10 minutes ago' "$MARKERDIR/.upstream-marker-s3"
_assert "[15] foreign create, stale (>5m) skill marker -> deny" "deny" \
  "$(_verdict "$(_json s3 "$GH $ISSUE $CREATE --repo open-gsd/gsd-core --title x")")"

# --- Bypass marker: fresh allows, >60s does not (short deliberate window) ---
touch "$MARKERDIR/.upstream-bypass-s4"
_assert "[16] fresh bypass marker -> silent (escape hatch works)" "silent" \
  "$(_verdict "$(_json s4 "$GH $ISSUE $CREATE --repo open-gsd/gsd-core --title x")")"
touch -d '5 minutes ago' "$MARKERDIR/.upstream-bypass-s5"
_assert "[17] stale (>60s) bypass marker -> deny (window closed)" "deny" \
  "$(_verdict "$(_json s5 "$GH $ISSUE $CREATE --repo open-gsd/gsd-core --title x")")"

# --- Widened matcher: gh api POST on issue/PR threads (the raw-API detour) ---
_assert "[18] gh api POST issues comments -> deny" "deny" \
  "$(_verdict "$(_json s1 "$GH $API repos/open-gsd/gsd-core/issues/2507/comments -X POST -f body=hi")")"
_assert "[19] gh api --method POST pulls -> deny" "deny" \
  "$(_verdict "$(_json s1 "$GH $API --method POST repos/open-gsd/gsd-core/pulls/12/comments -f body=hi")")"
_assert "[20] gh api GET (read-only) -> silent" "silent" \
  "$(_verdict "$(_json s1 "$GH $API repos/open-gsd/gsd-core/issues/2507")")"
_assert "[21] gh api POST to a non-issue path -> silent" "silent" \
  "$(_verdict "$(_json s1 "$GH $API repos/open-gsd/gsd-core/git/refs -X POST -f ref=x")")"

# --- Documented NON-GOALS stay silent (live legitimate consumers — see hook header) ---
# [22] pinned `gh pr comment` as a non-goal until 2026-08-02, when it was widened in
# (see [43]-[46]). Repurposed rather than deleted: token-anchoring for the NEW verb
# was otherwise untested, and that is exactly the class the `create-else` / `mygh`
# guards exist for.
_assert "[22] gh pr comment-else -> silent (continuation guard, pr verb)" "silent" \
  "$(_verdict "$(_json s1 "$GH $PR $COMMENT-something-else --body y")")"
_assert "[22b] mygh pr comment -> silent (prefix guard, pr verb)" "silent" \
  "$(_verdict "$(_json s1 "my$GH $PR $COMMENT 1 --body y")")"
_assert "[23] gh pr create -> silent (non-goal: run-pr.sh + /gsd-ship)" "silent" \
  "$(_verdict "$(_json s1 "$GH $PR $CREATE --repo open-gsd/gsd-core --title x")")"

# --- Token-anchoring: non-matches stay silent ---
_assert "[24] gh issue list -> silent (different subcmd)" "silent" \
  "$(_verdict "$(_json s6 "$GH $ISSUE list")")"
_assert "[25] gh issue create-else -> silent (continuation guard)" "silent" \
  "$(_verdict "$(_json s6 "$GH $ISSUE $CREATE-something-else")")"
_assert "[26] mygh issue comment -> silent (prefix guard)" "silent" \
  "$(_verdict "$(_json s6 "my$GH $ISSUE $COMMENT 1 --body y")")"

# --- Defensive: missing session_id on a foreign target -> deny (fail-closed) ---
_assert "[27] no session_id, foreign target -> deny" "deny" \
  "$(_verdict "$(jq -n --arg c "$GH $ISSUE $CREATE --repo open-gsd/gsd-core --title x" \
      '{cwd:"/tmp/x", tool_input:{command:$c}}')")"
_assert "[28] no session_id, own target -> silent (ownership wins)" "silent" \
  "$(_verdict "$(jq -n --arg c "$GH $ISSUE $CREATE --repo 0xdhx/hooks --title x" \
      '{cwd:"/tmp/x", tool_input:{command:$c}}')")"

# --- Bypass script contract: exists, executable, refuses without a real reason ---
_assert "[29] bypass script exists in-repo" "yes" \
  "$([[ -f "$BYPASS" ]] && echo yes || echo no)"
BP_NORSN=$(bash "$BYPASS" >/dev/null 2>&1; echo $?)
_assert "[30] bypass refuses with no --reason" "2" "$BP_NORSN"
BP_SHORT=$(bash "$BYPASS" --reason "meh" >/dev/null 2>&1; echo $?)
_assert "[31] bypass refuses a too-short --reason" "2" "$BP_SHORT"
BP_OK=$(CLAUDE_CODE_SESSION_ID=probe-sess bash "$BYPASS" --reason "probe: verifying the audited escape hatch" >/dev/null 2>&1; echo $?)
_assert "[32] bypass accepts a real reason" "0" "$BP_OK"
_assert "[33] bypass wrote its session marker" "yes" \
  "$([[ -f "$MARKERDIR/.upstream-bypass-probe-sess" ]] && echo yes || echo no)"
_assert "[34] bypass appended an audit line naming the reason" "yes" \
  "$(grep -q 'probe: verifying the audited escape hatch' "$MARKERDIR/upstream-bypass.log" 2>/dev/null && echo yes || echo no)"
# The marker the bypass just wrote must actually open the gate (end-to-end contract).
_assert "[35] bypass marker opens the gate end-to-end" "silent" \
  "$(_verdict "$(_json probe-sess "$GH $ISSUE $CREATE --repo open-gsd/gsd-core --title x")")"

# --- Positional target URL: the owner comes from the URL, not the cwd ---
# Gap found 2026-08-02: owner resolution had no branch for a positional
# https://github.com/<owner>/<repo>/... target, so it fell through to the cwd's
# origin. From a fork checkout (origin 0xdhx/...) a FOREIGN issue URL resolved to
# an OWN owner and was silently allowed — a live bypass of the D-12 hard deny.
_assert "[39] foreign issue URL from own-origin cwd -> deny (was: silent bypass)" "deny" \
  "$(_verdict "$(_json s1 "$GH $ISSUE $COMMENT https://github.com/open-gsd/gsd-core/issues/42 --body y" "$OWN_REPO")")"
_assert "[40] own issue URL from foreign-origin cwd -> silent (URL beats cwd both ways)" "silent" \
  "$(_verdict "$(_json s1 "$GH $ISSUE $COMMENT https://github.com/0xdhx/hooks/issues/42 --body y" "$FOREIGN_REPO")")"
_assert "[41] explicit --repo still outranks a URL elsewhere in the command" "silent" \
  "$(_verdict "$(_json s1 "$GH $ISSUE $COMMENT 5 --repo 0xdhx/hooks --body \"see https://github.com/open-gsd/gsd-core/issues/1\"" "$OWN_REPO")")"
# Deliberate over-match, documented: with no --repo, a foreign URL anywhere in the
# command resolves foreign and DENIES even if the real target was the cwd's repo.
# Fail-closed is the correct direction here — the operator passes --repo to disambiguate,
# which is exactly what the deny message already tells them to do.
_assert "[42] bare foreign URL in free text, no --repo -> deny (fail-closed over-match)" "deny" \
  "$(_verdict "$(_json s1 "$GH $ISSUE $COMMENT 5 --body \"see https://github.com/open-gsd/gsd-core/issues/1\"" "$OWN_REPO")")"

# --- gh pr comment: widened 2026-08-02 (was a documented non-goal) ---
# RV9's publication moved into cross-repo scripts/upstream/post-pr-comment.sh, so the
# sanctioned revise post is now a child process this hook cannot see -- which is what
# made widening safe. [44] is the /dhx:review live check, kept as a permanent tooth:
# it posts own-repo review bodies with a BARE PR NUMBER, so owner resolution falls to
# the cwd origin and must stay silent. If that ever reds, /dhx:review is broken.
_assert "[43] foreign PR URL comment -> deny" "deny" \
  "$(_verdict "$(_json s1 "$GH $PR $COMMENT https://github.com/open-gsd/gsd-core/pull/2595 --body-file b")")"
_assert "[44] /dhx:review shape (bare num, own-origin cwd) -> silent" "silent" \
  "$(_verdict "$(_json s1 "$GH $PR $COMMENT 123 --body-file b" "$OWN_REPO")")"
_assert "[45] bare num from a foreign-origin cwd -> deny" "deny" \
  "$(_verdict "$(_json s1 "$GH $PR $COMMENT 123 --body-file b" "$FOREIGN_REPO")")"
_assert "[46] foreign PR comment via --repo -> deny" "deny" \
  "$(_verdict "$(_json s1 "$GH $PR $COMMENT 12 --repo open-gsd/gsd-core --body-file b")")"
_assert "[47] gh pr create still silent (still a non-goal)" "silent" \
  "$(_verdict "$(_json s1 "$GH $PR $CREATE --repo open-gsd/gsd-core --title x")")"

# --- NEGATIVE CONTROL: the skipped-confirm path, from the cwd revise actually uses ---
# This is the acceptance criterion of cross-repo brief
# 2026-07-26-upstream-revise-rv9-confirm-has-no-enforcement.md, and it is the exact
# 2026-07-26 #2595 shape: a model that skipped RV9's confirm improvises the post as a
# top-level call, targeting a FOREIGN PR URL, from inside the revise worktree -- which
# is a FORK CHECKOUT whose origin owner is OWN. Both halves of this arc are required
# for it to deny: the matcher widening alone leaves ownership resolving to the cwd
# origin (own -> silent allow), and the URL-resolution fix alone leaves the verb
# unmatched. Either half reverted, this goes silent.
_assert "[48] NEG CONTROL: foreign PR URL improvised from a fork checkout -> deny" "deny" \
  "$(_verdict "$(_json s1 "$GH $PR $COMMENT https://github.com/open-gsd/gsd-core/pull/2595 --body-file b" "$OWN_REPO")")"
# The sanctioned path is a child process, so the hook never sees its gh call at all.
_assert "[49] sanctioned path (script invocation) -> silent" "silent" \
  "$(_verdict "$(_json s1 "bash ~/.claude/dhx-tools/dhx-upstream/post-pr-comment.sh --pr https://github.com/open-gsd/gsd-core/pull/2595 --body-file b" "$OWN_REPO")")"

# --- MUTATION VERBS: widened 2026-08-03 from creation-only (report
#     2026-08-03-gh-write-deny-covers-create-not-edit.md) ---
# Every [50]-[64] arm below was bite-tested against the PRE-widening hook and was SILENT there.
# [65]-[68] are the inverse: permanent teeth that were ALREADY silent pre-widening and must STAY
# silent, because they are live gsd-core consumers surviving on ownership scoping.
EDIT="edit"; CLOSE="close"; REOPEN="reopen"; REVIEW="review"; MERGE="merge"; READY="ready"
GRAPHQL="graphql"; MUT="mutation"

_assert "[50] foreign issue edit -> deny" "deny" \
  "$(_verdict "$(_json s1 "$GH $ISSUE $EDIT 42 --repo open-gsd/gsd-core --body y")")"
_assert "[51] foreign issue close -> deny" "deny" \
  "$(_verdict "$(_json s1 "$GH $ISSUE $CLOSE 42 --repo open-gsd/gsd-core")")"
_assert "[52] foreign issue reopen -> deny" "deny" \
  "$(_verdict "$(_json s1 "$GH $ISSUE $REOPEN 42 --repo open-gsd/gsd-core")")"
# [53] is measured incident #1: the retitle of open-gsd/gsd-core#2493 that went out ungated.
_assert "[53] foreign pr edit --title (INCIDENT 1) -> deny" "deny" \
  "$(_verdict "$(_json s1 "$GH $PR $EDIT https://github.com/open-gsd/gsd-core/pull/2493 --title t")")"
# `pr review` would let a session APPROVE or request-changes on a foreign PR. No live consumer.
_assert "[54] foreign pr review -> deny" "deny" \
  "$(_verdict "$(_json s1 "$GH $PR $REVIEW 12 --repo open-gsd/gsd-core --approve")")"
_assert "[55] foreign pr close -> deny" "deny" \
  "$(_verdict "$(_json s1 "$GH $PR $CLOSE 12 --repo open-gsd/gsd-core")")"
_assert "[56] foreign pr reopen -> deny" "deny" \
  "$(_verdict "$(_json s1 "$GH $PR $REOPEN 12 --repo open-gsd/gsd-core")")"
_assert "[57] foreign pr merge -> deny" "deny" \
  "$(_verdict "$(_json s1 "$GH $PR $MERGE 12 --repo open-gsd/gsd-core --squash")")"
_assert "[58] foreign pr ready -> deny" "deny" \
  "$(_verdict "$(_json s1 "$GH $PR $READY 12 --repo open-gsd/gsd-core")")"

# --- api write methods: POST was covered, PATCH/PUT/DELETE were not ---
# [59] is measured incident #2: the PATCH that rewrote an already-published comment.
_assert "[59] foreign api PATCH on a comment (INCIDENT 2) -> deny" "deny" \
  "$(_verdict "$(_json s1 "$GH $API --method PATCH repos/open-gsd/gsd-core/issues/comments/5164385953 -F body=@b")")"
# [59b] is the PR-BODY REST endpoint. `gh pr edit --body-file` (arms [74]-[76], [79]) is one of the
# two canonical ways to rewrite a foreign PR body; a PATCH on `pulls/<N>` is the other, and until
# 2026-09-04 no arm exercised it — the only `pulls/` arm was [19], a POST to `pulls/<N>/comments`.
_assert "[59b] foreign api PATCH on a PR body (pulls/<N>) -> deny" "deny" \
  "$(_verdict "$(_json s1 "$GH $API --method PATCH repos/open-gsd/gsd-core/pulls/2290 -F body=@b")")"
_assert "[60] foreign api -X PUT on an issue path -> deny" "deny" \
  "$(_verdict "$(_json s1 "$GH $API -X PUT repos/open-gsd/gsd-core/issues/1/lock")")"
_assert "[61] foreign api --method DELETE on a comment -> deny" "deny" \
  "$(_verdict "$(_json s1 "$GH $API --method DELETE repos/open-gsd/gsd-core/issues/comments/99")")"
# Read methods stay silent — the widening is to WRITE methods, not to `gh api` wholesale.
_assert "[61b] foreign api GET still silent (read, not a mutation)" "silent" \
  "$(_verdict "$(_json s1 "$GH $API repos/open-gsd/gsd-core/issues/comments/99")")"

# --- graphql: no repos/ path to key owner on, so the detector keys on the mutation token ---
_assert "[62] graphql mutation from a foreign-origin cwd -> deny" "deny" \
  "$(_verdict "$(_json s1 "$GH $API $GRAPHQL -f query='$MUT { addComment(input:{}) }'" "$FOREIGN_REPO")")"
# Fail-closed: an opaque node-ID target resolves NO owner, and unresolvable has denied since D-12.
_assert "[63] graphql mutation, node-id only, unresolvable owner -> deny (fail-closed)" "deny" \
  "$(_verdict "$(_json s1 "$GH $API $GRAPHQL -f query='$MUT { addComment(input:{subjectId:\"MDU6SXNzdWUx\"}) }'" "$BARE_DIR")")"
# A graphql QUERY carries no mutation token and must not be caught — this is the arm that keeps
# cross-repo ci-verdict.sh's read (and every other graphql read) out of the matcher.
_assert "[64] graphql QUERY (no mutation token) -> silent" "silent" \
  "$(_verdict "$(_json s1 "$GH $API $GRAPHQL -f query='query { repository { name } }'" "$FOREIGN_REPO")")"
# Ownership scoping still wins over the graphql detector — it is a matcher, not a bypass.
_assert "[64b] graphql mutation from an OWN-origin cwd -> silent (scoping wins)" "silent" \
  "$(_verdict "$(_json s1 "$GH $API $GRAPHQL -f query='$MUT { addComment(input:{}) }'" "$OWN_REPO")")"

# --- PERMANENT TEETH: live gsd-core consumers that survive on OWNERSHIP, not on the verb set ---
# Measured 2026-08-03 before widening: /gsd-inbox (gsd-core workflows/inbox.md) runs issue/pr
# edit+close, and /gsd-ship (workflows/ship.md) runs `pr edit --add-reviewer`. All pass a BARE
# NUMBER, so ownership resolves from the cwd origin. If any of these four ever RED, those two
# workflows are broken — identical role to [44] for /dhx:review. They were green before the
# widening too, and that is the point: they prove the widening did NOT touch them.
_assert "[65] gsd-inbox shape: issue edit, bare num, own cwd -> silent" "silent" \
  "$(_verdict "$(_json s1 "$GH $ISSUE $EDIT 42 --add-label bug" "$OWN_REPO")")"
_assert "[66] gsd-inbox shape: issue close, bare num, own cwd -> silent" "silent" \
  "$(_verdict "$(_json s1 "$GH $ISSUE $CLOSE 42 --comment x" "$OWN_REPO")")"
_assert "[67] gsd-ship shape: pr edit --add-reviewer, bare num, own cwd -> silent" "silent" \
  "$(_verdict "$(_json s1 "$GH $PR $EDIT 12 --add-reviewer someone" "$OWN_REPO")")"
_assert "[68] gsd-inbox shape: pr close, bare num, own cwd -> silent" "silent" \
  "$(_verdict "$(_json s1 "$GH $PR $CLOSE 12 --comment x" "$OWN_REPO")")"

# --- Token-anchoring holds for the NEW verbs too (the create-else / mygh guard class) ---
_assert "[69] gh pr edit-something-else -> silent (continuation guard)" "silent" \
  "$(_verdict "$(_json s1 "$GH $PR $EDIT-something-else --title t")")"
_assert "[70] gh issue closed (not close) -> silent (continuation guard)" "silent" \
  "$(_verdict "$(_json s1 "$GH $ISSUE ${CLOSE}d --repo open-gsd/gsd-core")")"
_assert "[71] mygh pr edit -> silent (prefix guard)" "silent" \
  "$(_verdict "$(_json s1 "my$GH $PR $EDIT 12 --repo open-gsd/gsd-core --title t")")"
# `gh pr merge` must not swallow `gh pr merge-queue`-style continuations either.
_assert "[71b] gh pr merge-else -> silent (continuation guard)" "silent" \
  "$(_verdict "$(_json s1 "$GH $PR $MERGE-else --repo open-gsd/gsd-core")")"

# --- CHARACTERIZATION, NOT a bite test: --edit-last was ALREADY covered pre-widening ---
# Both of these were deny BEFORE 2026-08-03 — they match on their `issue comment` / `pr comment`
# tokens, not on any verb added by this change. Labelled explicitly so nobody reads them as
# evidence for the widening; the report called this out precisely so no such arm got miswritten.
_assert "[72] CHAR (pre-existing): issue comment --edit-last, foreign -> deny" "deny" \
  "$(_verdict "$(_json s1 "$GH $ISSUE $COMMENT --edit-last --repo open-gsd/gsd-core --body y")")"
_assert "[73] CHAR (pre-existing): pr comment --edit-last, foreign -> deny" "deny" \
  "$(_verdict "$(_json s1 "$GH $PR $COMMENT --edit-last --repo open-gsd/gsd-core --body y")")"

# --- Stdin-parse shape arms (2026-08-03). The verb set was complete and correct; the INPUT
# PATH was starving it. `@tsv` escaped a real newline/tab into `\`+`n` / `\`+`t`, so the char
# preceding a line-start verb was the ALNUM letter `n`/`t` and the `(^|[^[:alnum:]_])` anchor
# could never fire. These arms assert the SHAPE, not the verb — one verb across the four input
# shapes, deliberately NOT one multi-line arm per covered verb. A per-verb sweep would be 13x
# the maintenance for the same signal AND would still have missed [75] (nobody predicted the
# tab), which is exactly why the shape is the tooth.
# BITE-TESTED: [74]-[78] were each measured SILENT against the pre-fix @tsv parse. Revert the
# two `jq -r` reads in the hook to the old one-line `@tsv` + `read` form and all five go SILENT.
#
# PAYLOAD NOTE — the leading fixture line is `export D=/tmp`, NOT the errexit-DISABLE directive
# the live incident actually opened with. verify-hook-patterns.sh's probe set-flag discipline lint
# greps ADDED LINES for that directive and cannot distinguish a shell directive from a quoted
# fixture payload (it would even flag this comment for naming it, which is why the token is
# described here rather than written). Its only exemption is a line-anchored errexit ENABLE —
# which a probe must not carry, since errexit would abort the suite on the first failing assertion
# instead of counting it. The lint is right and the fixture is what should move: only the SHAPE is
# under test — a line, then the verb at line-start — and `export D=/tmp` is the line that defined
# $D in the real incident anyway. Do NOT reintroduce the disable directive as fixture data, and do
# NOT add an errexit enable to this probe to silence the lint.
NL=$'\n'; TAB=$'\t'
_assert "[74] BITE: pr edit at START of line 2 -> deny" "deny" \
  "$(_verdict "$(_json s1 "export D=/tmp${NL}$GH $PR $EDIT 2493 --repo open-gsd/gsd-core --body-file b.md")")"
_assert "[75] BITE: pr edit on line 2, TAB-indented -> deny" "deny" \
  "$(_verdict "$(_json s1 "export D=/tmp${NL}${TAB}$GH $PR $EDIT 2493 --repo open-gsd/gsd-core --body-file b.md")")"
# The live 2026-08-03 incident: a foreign PR description mutated with no deny. Structurally
# faithful (leading line, cp, verb at line-start of line 3, piped) — see the PAYLOAD NOTE above
# for why line 1 is a setup line rather than the incident's literal opening directive.
_assert "[76] BITE: live incident shape (setup / cp / gh on line 3) -> deny" "deny" \
  "$(_verdict "$(_json s1 "export D=/tmp${NL}cp a b${NL}$GH $PR $EDIT 2493 --repo open-gsd/gsd-core --body-file b.md 2>&1 | tail -5")")"
_assert "[77] BITE: gh api POST at START of line 2 -> deny" "deny" \
  "$(_verdict "$(_json s1 "export D=/tmp${NL}$GH $API repos/open-gsd/gsd-core/issues/1/comments -X POST -f body=x")")"
# Bug 2 (field shift): tab is IFS-whitespace, so `read` collapsed a leading empty `.cwd` and
# the whole command landed in $CWD with $CMD empty. Needs a hand-built payload — _json's
# `${3:-/tmp/x}` default cannot express an EMPTY cwd.
_assert "[78] BITE: empty cwd does not shift fields -> deny" "deny" \
  "$(_verdict "$(jq -n --arg c "$GH $ISSUE $CREATE --repo open-gsd/gsd-core --title x --body y" \
      '{session_id:"s1", cwd:"", tool_input:{command:$c}}')")"
# NON-VACUITY / CHARACTERIZATION, not a bite test: this one was ALREADY deny pre-fix. It pins
# the real predicate — the ESCAPED WHITESPACE CHARACTER before the verb, not "multi-line". A
# space-indented line-2 call always matched, because @tsv leaves a real space alone. Any future
# reader tempted to describe this bug as "multi-line commands bypass the gate" is refuted here.
_assert "[79] CHAR (pre-existing): pr edit line 2, SPACE-indented -> deny" "deny" \
  "$(_verdict "$(_json s1 "export D=/tmp${NL}  $GH $PR $EDIT 2493 --repo open-gsd/gsd-core --body-file b.md")")"
# The fix must not over-fire: ownership scoping still decides, on a multi-line command too.
_assert "[80] own-owner at START of line 2 -> silent (scoping survives the parse fix)" "silent" \
  "$(_verdict "$(_json s1 "export D=/tmp${NL}$GH $ISSUE $CREATE --repo 0xdhx/dhx-hooks --title x --body y")")"

# --- Ownership rung 2 is SCOPED TO THE api ARM (2026-08-25) ---------------------------
# The rung greps `repos/<name>/` out of the raw command. Before this change it ran for
# every match arm, so a LOCAL FILESYSTEM PATH quoted anywhere in a command decided who
# owned the target. That broke both ways and both are pinned here as BITE arms:
#   [81] FALSE DENY  — a doc-authoring command naming a directory under ~/repos was
#        denied even though its real destination was an own repo. Measured twice on
#        2026-08-24, the second time on the probe written to characterise the first.
#   [82] FALSE ALLOW — the worse half, and the one the source report never found: a
#        FOREIGN write from a FOREIGN checkout whose --body prose mentions `repos/0xdhx/…`
#        resolved an OWN owner out of the prose and was SILENTLY ALLOWED. Same failure
#        mode the positional-URL rung was added for on 2026-08-02, on a different rung.
# [83]/[84] are non-vacuity controls: fail-closed survives, and the api arm — the ONE arm
# that legitimately reads a path — keeps resolving exactly as before.
DOCPATH="repos/cross-repo/scripts/upstream/ci-verdict.sh"
_assert "[81] BITE: doc-authoring cmd quoting a local repos/<dir>/ path, own cwd -> silent" "silent" \
  "$(_verdict "$(_json s1 "cat > note.md <<'X'${NL}run $GH $PR $EDIT to retitle; see $DOCPATH${NL}X" "$OWN_REPO")")"
_assert "[82] BITE: foreign write, foreign cwd, own-looking repos/ path in prose -> deny" "deny" \
  "$(_verdict "$(_json s1 "$GH $ISSUE $COMMENT 2507 --body \"see repos/0xdhx/hooks/scripts for the fix\"" "$FOREIGN_REPO")")"
_assert "[83] CTRL: same doc-authoring cmd, cwd not a git repo -> deny (fail-closed survives)" "deny" \
  "$(_verdict "$(_json s1 "cat > note.md <<'X'${NL}run $GH $PR $EDIT to retitle; see $DOCPATH${NL}X" "$BARE_DIR")")"
_assert "[84] CTRL: api arm still resolves owner from its own path (own cwd, foreign path) -> deny" "deny" \
  "$(_verdict "$(_json s1 "$GH $API repos/open-gsd/gsd-core/issues/1/comments -X POST -f body=x" "$OWN_REPO")")"

# --- The deny REASON carries NO cross-repo coupling (2026-08-25) ----------------------
# The message used to enumerate sibling-repo driver FILENAMES and restate that repo's
# editing doctrine. Both aged three separate ways in three weeks (missing the PR-body
# driver from 2026-08-12; missing both issue-side edit routes from 2026-08-23/24; still
# carrying the edit doctrine retired 2026-08-24). The ruling was to DELETE the coupling,
# not instrument it — so [85]/[86] assert its ABSENCE, which is the whole invariant:
# completeness cannot be proven from this repo without re-creating the dependency being
# removed. [87]/[88] pin the two routing facts a blocked session actually needs.
_assert "[85] reason enumerates no sibling driver script filename" "no" \
  "$(grep -qE 'edit-pr-(title|body|comment)\.sh|post-pr-comment\.sh|run-comment\.sh' <<< "$DENY_REASON" && echo yes || echo no)"
_assert "[86] reason does not restate the retired follow-up-over-edit doctrine" "no" \
  "$(grep -qi 'prefer posting a follow-up' <<< "$DENY_REASON" && echo yes || echo no)"
# --- [87] / [87b]: the two BODY-EDIT ROUTE arms ------------------------------------
# Since the message names no driver scripts, these two route sentences are the ONLY thing
# standing between a denied body edit and the audited bypass. [87b] is pinned as the
# standing instrument for the amended AC-7 of cross-repo's
# 2026-08-03-upstream-edit-pr-body-driver-and-revise-step.
#
# RELATIONAL, and they have to be. [87b]'s first form grepped the whole reason for
# `body edit` and for `revise` independently, and a close-gate reviewer refuted that within
# the hour: token co-occurrence stays green when a message routes body edits to the WRONG
# mode, as long as some other PR operation still mentions revise. Its second form read the
# first `/dhx:upstream <mode>` after the first `ody edit` anywhere in the message — better,
# but still POSITIONAL, and the round-3 review (2026-09-04, APPROVED-WITH-FINDINGS) recorded
# three mutations that defeat token order. What is asserted now is the ROUTING RELATION:
# within a named route's OWN segment, the single mode that route sends a body edit to.
#
# [87] was a bare `grep -qi 'editing the issue body'` until 2026-09-04 and carried the
# identical hazard one arm over — the very rewording that mutation (c) describes (route (2)
# saying "issue body edit") would have turned it RED against a correct message. It is a
# relation now too, off the same helper. A false red on either arm is not a harmless
# failure: it is the kind that gets an assertion deleted rather than fixed.
#
# _route_mode <route-anchor-ERE, lowercase> <reason>
#   Isolates that route's OWN segment — from the route anchor to the NEXT ROUTE ANCHOR (or
#   end of message) — and returns the single /dhx:upstream mode that segment routes a body
#   edit to.
#   Anchoring to the segment rather than to the first `ody edit` in the whole message is
#   what makes an unrelated route's rewording unable to shadow this one. Diagnostics:
#     __no-route-segment__  the message names no such route at all
#     __no-body-edit__      the route exists but routes no body edit
#     __no-mode__           the route names no /dhx:upstream mode
#     __ambiguous:a+b__     the route names >1 mode, so it routes a body edit to none singly
#
# KNOWN LIMIT — stated HERE, in the probe, because the brief requires the limitation live
# with the instrument rather than in prose elsewhere. Mutation (a) — "body edit is NOT
# supported by /dhx:upstream revise; use ... reply" — is caught by the mode-SET check, i.e.
# by CARDINALITY, not by reading the negation. A negation naming ONLY the correct mode
# ("retitle -> revise; a body edit is not supported") still passes. That is prose semantics
# and is not decidable syntactically; [87i] PINS the wrong answer so the limit is measured
# rather than asserted, and will go red the day someone closes it.
# RESIDUAL shared by both arms: they depend on the message keeping a literal route anchor
# ("EXISTING issue" / "EXISTING PR"). The anchors below accept the plural and the spelled-out
# "pull request", which narrows that dependency without removing it.
# RESIDUAL of the anchor bound, traded knowingly for the marker bound it replaced: the LAST
# route's segment runs to the end of the message, so a `/dhx:upstream <mode>` appearing in
# trailing prose AFTER the last route would read as a second mode and turn that arm
# ambiguous. Today no such mention exists past the PR route ([87b] green is that assertion),
# and the trade is worth it — the marker bound broke on any parenthetical digit anywhere in
# a route, a much larger class than "prose after the last route names a mode".
_route_mode() { # <route-anchor-ERE, lowercase> <reason> -> mode | __diagnostic__
  local __anchor="$1" __reason="$2" __seg
  # awk match() is leftmost — FIRST occurrence, unlike a greedy sed `s/^.*A//`. tolower is
  # length-preserving for ASCII, so RSTART/RLENGTH still index the original string.
  __seg="$(awk -v a="$__anchor" '{ l=tolower($0); if (match(l, a)) print "OK" substr($0, RSTART+RLENGTH) }' <<< "$__reason")"
  case "$__seg" in OK*) __seg="${__seg#OK}" ;; *) echo "__no-route-segment__"; return ;; esac
  # A route segment ends where the NEXT route begins, and a route begins with a `(N)` marker
  # AND a route anchor, with no other bracket between them. BOTH halves are load-bearing, and
  # each was learned from a defeat -- two close-gate rounds on 2026-09-04 killed the one-half
  # forms in one line each:
  #   marker alone  -> `EXISTING PR (2) common edits include body edit ...` truncated at the
  #                    parenthetical `(2)`      ([87l] is that counterexample)
  #   anchor alone  -> `EXISTING PR: unlike an EXISTING issue, a PR body edit ...` truncated
  #                    at the cross-reference   ([87m] is that one)
  # Both returned `__no-body-edit__` on a route that plainly routes one -- a false red, on the
  # arm whose false reds get assertions deleted rather than fixed. Neither a bare digit nor a
  # bare anchor mention can satisfy the conjunction.
  # Brackets are matched as [(] / [)] rather than escaped: a backslash escape inside an
  # awk -v string is processed by the string literal first, and POSIX leaves that undefined.
  local __next='[(][0-9]+[)][^()]*existing (issues?|pr|pull requests?)[^a-z]'
  __seg="$(awk -v a="$__next" '{ l=tolower($0); if (match(l, a)) print substr($0, 1, RSTART-1); else print }' <<< "$__seg")"
  grep -qiE 'body edit|editing the (issue|pr) body' <<< "$__seg" \
    || { echo "__no-body-edit__"; return; }
  local __modes
  __modes="$(grep -oiE '/dhx:upstream [a-z]+' <<< "$__seg" \
             | awk '{print tolower($2)}' | sort -u | tr '\n' '+' | sed 's/+$//')"
  case "$__modes" in
    "")  echo "__no-mode__" ;;
    *+*) echo "__ambiguous:${__modes}__" ;;
    *)   echo "$__modes" ;;
  esac
}
_ANCHOR_ISSUE='existing issues?[^a-z]'
_ANCHOR_PR='existing (pr|pull requests?)[^a-z]'
_assert "[87] the EXISTING-issue route sends a body edit to reply" "reply" \
  "$(_route_mode "$_ANCHOR_ISSUE" "$DENY_REASON")"
_assert "[87b] the EXISTING-PR route sends a body edit to revise" "revise" \
  "$(_route_mode "$_ANCHOR_PR" "$DENY_REASON")"
# MUTATION CONTROLS. [87c]-[87d] kill the FIRST form (token co-occurrence). [87e]-[87h] are
# the round-3 review's three mutations, one control each, per the brief's requirement that
# every mutation the fix claims to close carries its own control. [87i] pins the one it
# does NOT close. [87j]-[87k] are vacuity controls: without them a helper that always
# returned the mode would pass every arm above.
_MUT87="(3) anything on an EXISTING PR: body edit -> '/dhx:upstream reply'; retitle -> '/dhx:upstream revise' (4) bypass"
_assert "[87c] MUT CONTROL: two modes in one route routes a body edit to neither" "__ambiguous:reply+revise__" \
  "$(_route_mode "$_ANCHOR_PR" "$_MUT87")"
_MUT87D="(3) anything on an EXISTING PR: body edit -> '/dhx:upstream reply' (4) bypass"
_assert "[87d] MUT CONTROL: body-edit routed to the wrong mode is caught" "reply" \
  "$(_route_mode "$_ANCHOR_PR" "$_MUT87D")"
# (c) — the realistic one: an issue route reworded to shadow the PR route's phrasing. BOTH
# arms must survive it. This is the false-red the segment anchor exists to prevent.
# NOTE the shape: the issue route names its mode AFTER its body-edit token. That ordering is
# load-bearing — with the mode named FIRST the positional form skips the whole route and
# stays green, so a fixture written that way is a control with no tooth. Measured against
# the pre-fix helper 2026-09-04: this string yields `reply` (red), the mode-first variant
# yields `revise` (green).
_MUT87C="(2) anything on an EXISTING issue: an issue body edit -> '/dhx:upstream reply'; (3) anything on an EXISTING PR: body edit, retitle -> '/dhx:upstream revise' (4) bypass"
_assert "[87e] MUT CONTROL (c): a shadowing issue route does not capture the PR arm" "revise" \
  "$(_route_mode "$_ANCHOR_PR" "$_MUT87C")"
_assert "[87f] MUT CONTROL (c): the issue arm still resolves under the same rewording" "reply" \
  "$(_route_mode "$_ANCHOR_ISSUE" "$_MUT87C")"
# (b) — mode named BEFORE the body-edit token. Fatal to any positional form; fine here,
# because within a bounded route segment the order of the two facts does not matter.
_MUT87B="(3) anything on an EXISTING PR: use '/dhx:upstream revise' for a PR body edit, retitle, or response comment (4) bypass"
_assert "[87g] MUT CONTROL (b): mode named before the body-edit token still resolves" "revise" \
  "$(_route_mode "$_ANCHOR_PR" "$_MUT87B")"
# (a) — the body edit disclaimed and re-routed. Caught by CARDINALITY (two modes), not by
# reading the negation. See KNOWN LIMIT above, and [87i] for what that leaves open.
_MUT87A="(3) anything on an EXISTING PR: body edit is NOT supported by '/dhx:upstream revise'; use '/dhx:upstream reply' (4) bypass"
_assert "[87h] MUT CONTROL (a): a disclaimer naming a second mode is caught" "__ambiguous:reply+revise__" \
  "$(_route_mode "$_ANCHOR_PR" "$_MUT87A")"
# KNOWN LIMIT, pinned. This message routes NO body edit, yet the arm reads `revise`. The
# expectation below documents a defect, it does not endorse one — if a future form decides
# prose negation, this goes red and is deleted, not "fixed" back.
_MUT87NEG="(3) anything on an EXISTING PR: retitle -> '/dhx:upstream revise'; a body edit is not supported (4) bypass"
_assert "[87i] KNOWN LIMIT: a negation naming only the correct mode still passes" "revise" \
  "$(_route_mode "$_ANCHOR_PR" "$_MUT87NEG")"
_MUT87NOPR="(1) a NEW issue -> '/dhx:upstream <report-path>'; (2) anything on an EXISTING issue -> '/dhx:upstream reply', including an issue body edit (4) bypass"
_assert "[87j] CTRL vacuity: a message with no PR route resolves to no segment" "__no-route-segment__" \
  "$(_route_mode "$_ANCHOR_PR" "$_MUT87NOPR")"
_MUT87NOBE="(3) anything on an EXISTING PR: retitle only -> '/dhx:upstream revise' (4) bypass"
_assert "[87k] CTRL vacuity: a PR route routing no body edit is not silently green" "__no-body-edit__" \
  "$(_route_mode "$_ANCHOR_PR" "$_MUT87NOBE")"
# The close-gate reviewer's counterexample, verbatim (round 1, 2026-09-04). Against the
# `(N)`-marker bound this returned `__no-body-edit__` — a false red on a route that plainly
# routes a body edit — because the parenthetical `(2)` mid-clause read as the next route
# marker. The anchor bound is immune to it. Kept as a live control so the marker bound
# cannot come back unnoticed.
_MUT87PAREN="(3) anything on an EXISTING PR (2) common edits include body edit and retitle -> '/dhx:upstream revise' (4) bypass"
_assert "[87l] MUT CONTROL: a parenthetical digit mid-route does not truncate the segment" "revise" \
  "$(_route_mode "$_ANCHOR_PR" "$_MUT87PAREN")"
# The round-2 reviewer's counterexample, verbatim. Against the anchor-ONLY bound that round 1
# produced, this returned `__no-body-edit__` — the mid-clause cross-reference to the other
# route read as the start of that route. Requiring a `(N)` marker alongside the anchor is
# what separates a cross-reference from a route start.
_MUT87XREF="(3) anything on an EXISTING PR: unlike an EXISTING issue, a PR body edit -> /dhx:upstream revise (4) bypass"
_assert "[87m] MUT CONTROL: an in-route cross-reference is not read as the next route" "revise" \
  "$(_route_mode "$_ANCHOR_PR" "$_MUT87XREF")"
_assert "[88] reason names the document-authoring escape (the self-deny mitigation)" "yes" \
  "$(grep -qi 'assemble the verb tokens from shell variables' <<< "$DENY_REASON" && echo yes || echo no)"

# --- Cross-file contracts ---
REG=$(jq -e '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command]
              | any(contains("pre-tool-use-gh-issue-write"))' "$MANIFEST" >/dev/null 2>&1 \
        && echo yes || echo no)
_assert "[36] hooks.json Bash matcher points at pre-tool-use-gh-issue-write" "yes" "$REG"
STALE=$(grep -q "pre-tool-use-gh-issue-create" "$MANIFEST" && echo yes || echo no)
_assert "[37] no stale -create ref left in hooks.json" "no" "$STALE"
# The deny routes users to a symlink under dhx-tools; the farm entry must exist.
LINKED=$([[ -e "$HOME/.claude/dhx-tools/dhx-upstream-bypass.sh" ]] && echo yes || echo no)
_assert "[38] bypass script is symlinked into ~/.claude/dhx-tools" "yes" "$LINKED"

echo "---"
echo "$PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]] || exit 1
exit 0
