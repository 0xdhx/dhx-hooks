#!/usr/bin/env bash
# probe-gh-issue-write.sh
#
# Regression probe for dhx-plugin/plugins/dhx/hooks/pre-tool-use-gh-issue-write.sh
# (PreToolUse:Bash soft-deny for upstream filings).
#
# Invariant: the hook warns — non-blocking — when a `gh issue create` OR
# `gh issue comment` runs WITHOUT a fresh /dhx:upstream marker for the session,
# and it warns through the HP-049 structured JSON surface (NOT plain stdout, which
# is debug-log-only on PreToolUse:Bash and reaches neither user nor model — the
# pre-rename OD-1 dead-warn bug). A warn carries BOTH `systemMessage` (user channel)
# and `hookSpecificOutput.additionalContext` (model channel) with
# `permissionDecision:"allow"` and ALWAYS exits 0 (it is a warn, not a deny — the
# D-12 hard-deny flip to permissionDecision:"deny"/exit 2 is out of scope). It stays
# silent (no output, exit 0) when the marker is fresh, when the command is a
# different subcommand (`gh issue list`), or when token-anchoring rejects a
# continuation (`create-something-else`) / prefix (`mygh issue comment`).
#
# INVARIANT (cross-file contract): the rename from -create to -write is only half
# done if hooks.json still points at the old name. Asserted directly below against
# the live plugin manifest — the script path and the manifest must move together.
#
# Backs: docs/decisions.md 2026-07-10 gh-issue-write generalize+JSON-surface row.
#
# Run: bash tests/probes/probe-gh-issue-write.sh
#
# SAFE_FOR_LIVE: yes   (hook subshell with synthetic stdin; CLAUDE_CONFIG_DIR is
#                       redirected to a mktemp dir so the marker read/write hits a
#                       fixture, never live ~/.claude/dhx-tools; no repo/config/git
#                       writes. The hooks.json invariant is a read-only jq check.)

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$REPO/dhx-plugin/plugins/dhx/hooks/pre-tool-use-gh-issue-write.sh"
MANIFEST="$REPO/dhx-plugin/plugins/dhx/hooks/hooks.json"

if [[ ! -f "$HOOK" ]]; then
  echo "FAIL hook not found: $HOOK"
  exit 1
fi

# Fixture config dir — the hook resolves the marker under $CLAUDE_CONFIG_DIR/dhx-tools.
TMP="$(mktemp -d)"
export CLAUDE_CONFIG_DIR="$TMP"
MARKERDIR="$TMP/dhx-tools"
mkdir -p "$MARKERDIR"
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

# Build a PreToolUse stdin payload.
_json() { # $1 session_id, $2 command
  jq -n --arg s "$1" --arg c "$2" \
    '{session_id:$s, cwd:"/tmp/x", tool_input:{command:$c}}'
}

# _verdict <json> -> "warn" | "silent" | "malformed"
# warn := stdout parses as JSON AND carries both user (systemMessage) and model
# (additionalContext) channels; silent := no stdout; malformed := stdout that is
# not JSON or is missing a channel.
_verdict() {
  local out
  out=$(printf '%s' "$1" | bash "$HOOK" 2>/dev/null)
  if [[ -z "$out" ]]; then echo "silent"; return; fi
  if printf '%s' "$out" | jq -e \
      '(.systemMessage // "") != "" and (.hookSpecificOutput.additionalContext // "") != ""' \
      >/dev/null 2>&1; then
    echo "warn"; return
  fi
  echo "malformed"
}

# _rc <json> -> exit code of the hook
_rc() {
  printf '%s' "$1" | bash "$HOOK" >/dev/null 2>&1
  echo "$?"
}

# --- Warn path: both verbs, no marker present ---
rm -f "$MARKERDIR"/.upstream-marker-*

_assert "[1] gh issue create, no marker -> warn" "warn" \
  "$(_verdict "$(_json s1 'gh issue create --title x --body y')")"

_assert "[2] gh issue comment, no marker -> warn" "warn" \
  "$(_verdict "$(_json s1 'gh issue comment 123 --body y')")"

# --- Silent path: fresh marker suppresses both verbs ---
touch "$MARKERDIR/.upstream-marker-s2"
_assert "[3] gh issue create, fresh marker -> silent" "silent" \
  "$(_verdict "$(_json s2 'gh issue create --title x')")"
_assert "[4] gh issue comment, fresh marker -> silent" "silent" \
  "$(_verdict "$(_json s2 'gh issue comment 42 --body z')")"

# --- Stale marker (>5 min) -> warn again (TTL expiry) ---
touch -d '10 minutes ago' "$MARKERDIR/.upstream-marker-s3"
_assert "[5] gh issue create, stale (>5m) marker -> warn" "warn" \
  "$(_verdict "$(_json s3 'gh issue create --title x')")"

# --- Token-anchoring: non-matches stay silent ---
_assert "[6] gh issue list -> silent (different subcmd)" "silent" \
  "$(_verdict "$(_json s4 'gh issue list')")"
_assert "[7] gh issue create-else -> silent (continuation guard)" "silent" \
  "$(_verdict "$(_json s4 'gh issue create-something-else')")"
_assert "[8] mygh issue comment -> silent (prefix guard)" "silent" \
  "$(_verdict "$(_json s4 'mygh issue comment 1 --body y')")"

# --- Defensive: missing session_id -> silent (cannot resolve marker) ---
_assert "[9] no session_id -> silent" "silent" \
  "$(_verdict '{"cwd":"/x","tool_input":{"command":"gh issue create --title x"}}')"

# --- permissionDecision:"allow" on the warn path (both verbs) ---
rm -f "$MARKERDIR"/.upstream-marker-*
PD_CREATE=$(printf '%s' "$(_json s5 'gh issue create --title x')" | bash "$HOOK" 2>/dev/null \
  | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
_assert "[10] create warn carries permissionDecision:allow" "allow" "$PD_CREATE"
PD_COMMENT=$(printf '%s' "$(_json s5 'gh issue comment 9 --body y')" | bash "$HOOK" 2>/dev/null \
  | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
_assert "[11] comment warn carries permissionDecision:allow" "allow" "$PD_COMMENT"

# --- Never blocks: exit 0 on every path (warn AND silent) ---
_assert "[12] warn path exits 0 (create)" "0" "$(_rc "$(_json s6 'gh issue create --title x')")"
_assert "[13] warn path exits 0 (comment)" "0" "$(_rc "$(_json s6 'gh issue comment 3 --body y')")"
touch "$MARKERDIR/.upstream-marker-s7"
_assert "[14] silent path exits 0 (fresh marker)" "0" "$(_rc "$(_json s7 'gh issue create --title x')")"

# --- Warn JSON is well-formed + stderr is clean ---
WARN_OUT=$(printf '%s' "$(_json s8 'gh issue comment 7 --body y')" | bash "$HOOK" 2>/dev/null)
_assert "[15] warn stdout is valid JSON" "yes" \
  "$(printf '%s' "$WARN_OUT" | jq empty >/dev/null 2>&1 && echo yes || echo no)"
WARN_ERR=$(printf '%s' "$(_json s8 'gh issue create --title x')" | bash "$HOOK" 2>&1 >/dev/null)
_assert "[16] no stderr noise on warn path" "" "$WARN_ERR"

# --- Cross-file contract: hooks.json registers the -write name (rename ripple) ---
REG=$(jq -e '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command]
              | any(contains("pre-tool-use-gh-issue-write"))' "$MANIFEST" >/dev/null 2>&1 \
        && echo yes || echo no)
_assert "[17] hooks.json Bash matcher points at pre-tool-use-gh-issue-write" "yes" "$REG"
STALE=$(grep -q "pre-tool-use-gh-issue-create" "$MANIFEST" && echo yes || echo no)
_assert "[18] no stale -create ref left in hooks.json" "no" "$STALE"

echo "---"
echo "$PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]] || exit 1
exit 0
