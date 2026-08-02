#!/usr/bin/env bash
# probe-gh-issue-write.sh
#
# Regression probe for dhx-plugin/plugins/dhx/hooks/pre-tool-use-gh-issue-write.sh
# (PreToolUse:Bash HARD DENY for foreign-repo upstream writes — D-12, 2026-07-21).
#
# Invariant (post-D-12): the hook DENIES — blocking — a `gh issue create`, `gh issue
# comment`, or `gh api …POST` on an issue/PR thread when ALL of:
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
# token-anchoring rejects it (`create-something-else`, `mygh issue comment`), or the shape
# is a documented NON-GOAL (`gh pr comment`, `gh pr create`, non-POST `gh api`).
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
_assert "[22] gh pr comment -> silent (non-goal: /dhx:upstream revise + /dhx:review)" "silent" \
  "$(_verdict "$(_json s1 "$GH $PR $COMMENT 12 --repo open-gsd/gsd-core --body y")")"
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
