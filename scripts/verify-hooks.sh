#!/usr/bin/env bash
# scripts/verify-hooks.sh — post-install sanity check for dhx hook wiring.
#
# Confirms each dhx/*.{sh,js} source file has at least one symlink in
# ~/.claude/hooks/ pointing to it. Name-agnostic: resolves symlinks by
# target, so dhx/poll-guard.sh symlinked as dhx-poll-guard.sh still matches.
# Reports:
#   - OK      source is wired (shows the link name)
#   - MISS    source exists, no symlink points to it — suggests ln -s
#   - ORPHAN  symlink in hooks/ points into dhx/ but target no longer exists
#   - COUNT   settings.json dhx hook command references (jq-resolved)
#
# Does NOT verify runtime behavior. After wiring is green, dispatch an
# Agent/Write and check ~/.cache/dhx/ to confirm the hook fires —
# settings.json loads at session start only (HP-012), so newly-installed
# hooks require a session restart before they execute.
#
# Exit codes: 0 = all green, 1 = at least one missing source or orphan link.
#
# Usage: bash scripts/verify-hooks.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DHX_DIR="$REPO/dhx"
HOOKS_DIR="$HOME/.claude/hooks"
SETTINGS="$(readlink -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" 2>/dev/null || true)"

MISSING=0
ORPHAN=0
OK=0

# Build reverse index: canonical target -> link path, for every symlink in hooks/.
declare -A WIRED
if [[ -d "$HOOKS_DIR" ]]; then
  for link in "$HOOKS_DIR"/*; do
    [[ -L "$link" ]] || continue
    target=$(readlink -f "$link" 2>/dev/null || true)
    [[ -n "$target" ]] && WIRED["$target"]="$link"
  done
fi

echo "Checking dhx/*.{sh,js} wiring against ${HOOKS_DIR}..."

shopt -s nullglob
for src in "$DHX_DIR"/*.sh "$DHX_DIR"/*.js; do
  canonical=$(readlink -f "$src")
  name=$(basename "$src")

  if [[ -n "${WIRED[$canonical]:-}" ]]; then
    link_name=$(basename "${WIRED[$canonical]}")
    if [[ "$link_name" == "$name" ]]; then
      echo "  OK    $name"
    else
      echo "  OK    $name (linked as $link_name)"
    fi
    OK=$((OK+1))
  else
    echo "  MISS  $name"
    echo "        fix:  ln -s $src $HOOKS_DIR/$name"
    MISSING=$((MISSING+1))
  fi
done
shopt -u nullglob

# Orphan check: symlinks in hooks/ pointing into dhx/ with missing targets.
if [[ -d "$HOOKS_DIR" ]]; then
  for link in "$HOOKS_DIR"/*; do
    [[ -L "$link" ]] || continue
    raw_target=$(readlink "$link")
    case "$raw_target" in
      */repos/hooks/dhx/*|*/hooks/dhx/*)
        if [[ ! -e "$link" ]]; then
          echo "  ORPHAN $(basename "$link") -> $raw_target (target missing)"
          ORPHAN=$((ORPHAN+1))
        fi
        ;;
    esac
  done
fi

echo ""

if [[ -n "$SETTINGS" && -f "$SETTINGS" ]] && command -v jq >/dev/null 2>&1; then
  DHX_COUNT=$(jq -r '
    [.hooks // {} | to_entries[] | .value[] | .hooks[]? | .command // ""]
    | map(select(test("dhx-|dhx/")))
    | length
  ' "$SETTINGS" 2>/dev/null || echo "?")
  echo "settings.json dhx hook command references: ${DHX_COUNT}"
  echo "  (resolved path: $SETTINGS)"
else
  echo "settings.json: not readable or jq missing"
fi

echo ""
if [[ $MISSING -eq 0 && $ORPHAN -eq 0 ]]; then
  echo "All ${OK} dhx hook sources wired."
  echo ""
  echo "If you just installed new hooks, restart the Claude Code session —"
  echo "settings.json loads at session start only (HP-012). After restart,"
  echo "dispatch an Agent or Write to confirm the hook fires:"
  echo "  ls ~/.cache/dhx/"
  exit 0
else
  echo "Issues: ${OK} ok, ${MISSING} missing, ${ORPHAN} orphan."
  echo ""
  echo "After fixing, restart the Claude Code session — settings.json"
  echo "loads at session start only (HP-012)."
  exit 1
fi
