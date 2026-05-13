#!/usr/bin/env bash
# scripts/sync-skill-overrides.sh — propagate the canonical /skills disabled-set
# from ~/repos/skills/.claude/settings.local.json to every repo under ~/repos/*.
#
# WHY THIS EXISTS (stopgap):
#   /skills writes per-project; toggles do not transfer between repos. Re-toggling
#   ~50 entries per repo is killing context budget. This script copies the curated
#   set (currently 118 entries) forward so suppressed skills stay suppressed
#   everywhere. Pair: scripts/unsync-skill-overrides.sh removes them once the
#   underlying /skills persistence root cause is fixed.
#
# CCS PROFILE NOTE:
#   /skills is project-scoped, NOT profile-scoped. The same .claude/settings.local.json
#   is read by every CCS profile (a/b/c) when cwd matches the project. So one sync run
#   covers all profiles. The script is profile-agnostic — the active CLAUDE_CONFIG_DIR
#   is irrelevant.
#
# BEHAVIOR:
#   - Source: $SKILL_OVERRIDES_SOURCE (default ~/repos/skills/.claude/settings.local.json)
#   - Targets: ~/repos/*/.claude/ (depth-1 only — worktrees skipped)
#   - Skips the source repo itself
#   - Skips repos where skillOverrides already matches source (idempotent)
#   - Creates settings.local.json if missing; merges into existing JSON otherwise,
#     preserving all non-skillOverrides keys (permissions, etc.)
#   - Backs up overwritten files to <target>.pre-skill-overrides-sync.bak
#
# Skill toggles are read at session start. Restart Claude Code in each affected
# repo for new overrides to take effect.
#
# Usage:
#   bash scripts/sync-skill-overrides.sh [--dry-run]
#
# Exit codes: 0 = success (any number of applies), 1 = source missing/empty, 2 = bad arg

set -uo pipefail

SOURCE="${SKILL_OVERRIDES_SOURCE:-$HOME/repos/skills/.claude/settings.local.json}"
REPOS_ROOT="${REPOS_ROOT:-$HOME/repos}"
BACKUP_SUFFIX=".pre-skill-overrides-sync.bak"
DRY_RUN=0

case "${1:-}" in
  -h|--help)
    sed -n '2,30p' "$0"
    exit 0
    ;;
  -n|--dry-run)
    DRY_RUN=1
    ;;
  "")
    ;;
  *)
    echo "unknown arg: $1 (use --help)" >&2
    exit 2
    ;;
esac

if ! command -v jq >/dev/null 2>&1; then
  echo "jq required but not installed" >&2
  exit 1
fi

if [[ ! -f "$SOURCE" ]]; then
  echo "source missing: $SOURCE" >&2
  exit 1
fi

SOURCE_OVERRIDES=$(jq -c '.skillOverrides // {}' "$SOURCE")
SOURCE_COUNT=$(echo "$SOURCE_OVERRIDES" | jq 'length')

if [[ "$SOURCE_COUNT" -eq 0 ]]; then
  echo "source has no skillOverrides: $SOURCE" >&2
  exit 1
fi

mode_label=$([ $DRY_RUN -eq 1 ] && echo "DRY-RUN" || echo "APPLY")
echo "Source : $SOURCE ($SOURCE_COUNT entries)"
echo "Targets: $REPOS_ROOT/*/.claude/"
echo "Mode   : $mode_label"
echo

source_repo_dir="$(cd "$(dirname "$SOURCE")/.." && pwd)"
applied=0; created=0; unchanged=0; skipped=0

for claude_dir in "$REPOS_ROOT"/*/.claude; do
  [[ -d "$claude_dir" ]] || continue
  repo_dir="$(cd "$claude_dir/.." && pwd)"
  target="$claude_dir/settings.local.json"
  rel="${repo_dir#$HOME/}"

  if [[ "$repo_dir" == "$source_repo_dir" ]]; then
    printf "  skip (source) : %s\n" "$rel"
    ((skipped++)) || true
    continue
  fi

  if [[ -f "$target" ]]; then
    current=$(jq -cS '.skillOverrides // {}' "$target")
    desired=$(echo "$SOURCE_OVERRIDES" | jq -cS .)
    if [[ "$current" == "$desired" ]]; then
      printf "  unchanged     : %s\n" "$rel"
      ((unchanged++)) || true
      continue
    fi
    merged=$(jq -s '.[0] * {skillOverrides: .[1].skillOverrides}' "$target" "$SOURCE")
    verb="apply"; past="applied"
  else
    merged=$(jq -n --argjson o "$SOURCE_OVERRIDES" '{skillOverrides: $o}')
    verb="create"; past="created"
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    printf "  would %-7s : %s\n" "$verb" "$rel"
  else
    if [[ -f "$target" ]]; then
      cp "$target" "$target$BACKUP_SUFFIX"
    fi
    printf '%s\n' "$merged" > "$target"
    printf "  %-13s : %s\n" "$past" "$rel"
  fi

  if [[ "$past" == "created" ]]; then
    ((created++)) || true
  else
    ((applied++)) || true
  fi
done

echo
echo "Done. applied=$applied created=$created unchanged=$unchanged skipped=$skipped"
if [[ $DRY_RUN -eq 0 && $((applied + created)) -gt 0 ]]; then
  echo "Restart Claude Code in each affected repo to load the new overrides."
  echo "To revert: bash scripts/unsync-skill-overrides.sh"
fi
