#!/usr/bin/env bash
# probe-memory-scope-guard.sh
#
# Regression probe for dhx/dhx-memory-scope-guard.sh (PreToolUse Write).
#
# Invariant: the hook is a WRITE-TIME front-stop on the per-project auto-memory
# store. It fires ONLY on a new memory FILE birth (tool=Write, path under
# */.ccs/*/memory/*.md, basename != MEMORY.md, target does not yet exist). On a
# benign new memory it injects the earns-its-slot / scope-home checklist as
# non-blocking additionalContext; on a strong cross-cutting tell (self-declared
# external home, cross-repo reference, or >=2 distinct CC/tool-internals terms)
# it escalates to permissionDecision:ask. It never hard-blocks, and never fires
# on Edits, MEMORY.md, existing-file overwrites, or non-memory paths.
#
#        stop complementing /dhx:doctor memory's audit-time wrong-home/memory@3).
#
# Run: bash tests/probes/probe-memory-scope-guard.sh
#
# SAFE_FOR_LIVE: yes   (hook subshell with synthetic stdin against mktemp fixture
#                       paths only; no live repo, config, or memory-store writes.)

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$REPO/dhx/dhx-memory-scope-guard.sh"

if [[ ! -f "$HOOK" ]]; then
  echo "FAIL hook not found: $HOOK"
  exit 1
fi

TMP="$(mktemp -d)"
MEMDIR="$TMP/.ccs/instances/x/projects/-home-dhx-repos-acme-app/memory"
mkdir -p "$MEMDIR" "$TMP/repo"
NEW="$MEMDIR/reference_new.md"                 # never created — birth cells
EXISTS="$MEMDIR/reference_exists.md"           # created on disk — update cell
MEMINDEX="$MEMDIR/MEMORY.md"
NONMEM="$TMP/repo/notes.md"                     # lacks /.ccs/ … /memory/
printf 'existing\n' > "$EXISTS"
trap 'rm -rf "$TMP"' EXIT

PASSED=0
FAILED=0

# _verdict <json> → "none" | "context" | "ask" | "malformed"
_verdict() {
  local out pd ac
  out=$(printf '%s' "$1" | bash "$HOOK" 2>/dev/null)
  if [[ -z "$out" ]]; then echo "none"; return; fi
  pd=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
  if [[ -n "$pd" ]]; then echo "$pd"; return; fi
  ac=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
  if [[ -n "$ac" ]]; then echo "context"; return; fi
  echo "malformed"
}

_assert() { # $1 label, $2 expected, $3 actual
  if [[ "$2" == "$3" ]]; then
    echo "OK   $1"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL $1 (expected $2, got $3)"
    FAILED=$((FAILED + 1))
  fi
}

_json_write() { # $1 file_path, $2 content
  jq -n --arg fp "$1" --arg c "$2" \
    '{tool_name:"Write",tool_input:{file_path:$fp,content:$c}}'
}

_json_edit() { # $1 file_path
  jq -n --arg fp "$1" \
    '{tool_name:"Edit",tool_input:{file_path:$fp,old_string:"a",new_string:"b"}}'
}

BENIGN='---
name: ff-widget-quirk
description: the widget cache needs a manual flush after import
metadata:
  type: project
---
The acme-app widget importer leaves a stale cache; flush it via the reset button.'

# [1] Non-memory path (lacks /.ccs/…/memory/) -> skip
_assert "[1] non-memory path Write -> none" "none" \
  "$(_verdict "$(_json_write "$NONMEM" "$BENIGN")")"

# [2] MEMORY.md index write -> skip (pointer discipline, not a memory file)
_assert "[2] MEMORY.md write -> none" "none" \
  "$(_verdict "$(_json_write "$MEMINDEX" "- [x](y.md) — hook")")"

# [3] Edit (not Write) to a memory path -> skip (birth is a Write)
_assert "[3] Edit to memory path -> none" "none" \
  "$(_verdict "$(_json_edit "$NEW")")"

# [4] Overwrite an EXISTING memory -> skip (already cleared the bar once)
_assert "[4] existing-file overwrite -> none" "none" \
  "$(_verdict "$(_json_write "$EXISTS" "$BENIGN")")"

# [5] New benign memory -> non-blocking reminder
_assert "[5] new benign memory -> context" "context" \
  "$(_verdict "$(_json_write "$NEW" "$BENIGN")")"

# [6] New memory self-declaring an external home -> ask
_assert "[6] self-declared external home -> ask" "ask" \
  "$(_verdict "$(_json_write "$NEW" "This fact's canonical home is ~/repos/cross-repo/docs/ccs/x.md — recording a pointer.")")"

# [7] New memory with a cross-repo reference -> ask
_assert "[7] cross-repo reference -> ask" "ask" \
  "$(_verdict "$(_json_write "$NEW" "Diagnostic hook. See [[reference_cross-repo-docs]] for the full model.")")"

# [8] New memory with >=2 distinct CC/tool-internals terms (daemon-storm class) -> ask
_assert "[8] >=2 CC-internals terms -> ask" "ask" \
  "$(_verdict "$(_json_write "$NEW" "All bg sessions flash red; the daemon cycles ~52s. Scope by CLAUDE_CONFIG_DIR; kill claude agents TUIs; control.sock orphaned.")")"

# [9] New memory with EXACTLY ONE CC-internals term -> context (precision floor)
_assert "[9] single CC-internals term -> context (no over-fire)" "context" \
  "$(_verdict "$(_json_write "$NEW" "The acme-app build daemon must be restarted after a schema change.")")"

# [10] Reminder JSON is well-formed + additionalContext non-empty
AC=$(printf '%s' "$(_json_write "$NEW" "$BENIGN")" | bash "$HOOK" 2>/dev/null \
      | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
_assert "[10] additionalContext non-empty on reminder path" "yes" \
  "$([[ -n "$AC" ]] && echo yes || echo no)"

# [11] ask JSON carries a non-empty permissionDecisionReason
RSN=$(printf '%s' "$(_json_write "$NEW" "See [[reference_cross-repo-docs]].")" | bash "$HOOK" 2>/dev/null \
      | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
_assert "[11] ask carries permissionDecisionReason" "yes" \
  "$([[ -n "$RSN" ]] && echo yes || echo no)"

# [12] stderr-clean on the benign new-memory path
ERR=$(printf '%s' "$(_json_write "$NEW" "$BENIGN")" | bash "$HOOK" 2>&1 >/dev/null)
_assert "[12] no stderr noise" "" "$ERR"

echo "---"
echo "$PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]] || exit 1
exit 0
