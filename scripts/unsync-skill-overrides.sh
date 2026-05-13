#!/usr/bin/env bash
# scripts/unsync-skill-overrides.sh — reverse scripts/sync-skill-overrides.sh.
# Run once the underlying /skills persistence root cause is fixed and you no
# longer need the propagated stopgap.
#
# BEHAVIOR:
#   For each ~/repos/*/.claude/settings.local.json:
#     - If a sibling .pre-skill-overrides-sync.bak exists → restore it (most precise:
#       returns the file to its exact pre-sync state, including any prior overrides).
#     - Else, strip the skillOverrides key in place. If that empties the file
#       (no other keys remain), delete the file entirely.
#   The source repo (~/repos/skills) is NOT touched — its hand-curated overrides
#   are preserved so they remain available as a future canonical set.
#
#   Override the source-skip via SKILL_OVERRIDES_SOURCE if you moved the canonical
#   set elsewhere; pass --include-source to nuke it too (rare).
#
# CCS PROFILE NOTE: storage is project-scoped, so one revert run covers all
# CCS profiles. Active CLAUDE_CONFIG_DIR is irrelevant.
#
# Skill toggles are read at session start. Restart Claude Code in each affected
# repo for the revert to take effect.
#
# Usage:
#   bash scripts/unsync-skill-overrides.sh [--dry-run] [--include-source]
#
# Exit codes: 0 = success, 2 = bad arg

set -uo pipefail

SOURCE="${SKILL_OVERRIDES_SOURCE:-$HOME/repos/skills/.claude/settings.local.json}"
REPOS_ROOT="${REPOS_ROOT:-$HOME/repos}"
BACKUP_SUFFIX=".pre-skill-overrides-sync.bak"
DRY_RUN=0
INCLUDE_SOURCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      sed -n '2,28p' "$0"
      exit 0
      ;;
    -n|--dry-run)
      DRY_RUN=1
      ;;
    --include-source)
      INCLUDE_SOURCE=1
      ;;
    *)
      echo "unknown arg: $1 (use --help)" >&2
      exit 2
      ;;
  esac
  shift
done

if ! command -v jq >/dev/null 2>&1; then
  echo "jq required but not installed" >&2
  exit 1
fi

source_repo_dir=""
if [[ -f "$SOURCE" ]]; then
  source_repo_dir="$(cd "$(dirname "$SOURCE")/.." && pwd)"
fi

mode_label=$([ $DRY_RUN -eq 1 ] && echo "DRY-RUN" || echo "APPLY")
echo "Targets        : $REPOS_ROOT/*/.claude/"
echo "Source-skip    : ${source_repo_dir:-<none>} $([ $INCLUDE_SOURCE -eq 1 ] && echo '(OVERRIDDEN: --include-source)')"
echo "Mode           : $mode_label"
echo

restored=0; stripped=0; removed=0; nochange=0

for claude_dir in "$REPOS_ROOT"/*/.claude; do
  [[ -d "$claude_dir" ]] || continue
  repo_dir="$(cd "$claude_dir/.." && pwd)"
  target="$claude_dir/settings.local.json"
  backup="$target$BACKUP_SUFFIX"
  rel="${repo_dir#$HOME/}"

  if [[ -n "$source_repo_dir" && "$repo_dir" == "$source_repo_dir" && $INCLUDE_SOURCE -eq 0 ]]; then
    printf "  skip (source)  : %s\n" "$rel"
    continue
  fi

  if [[ ! -f "$target" ]]; then
    continue
  fi

  has=$(jq -r 'has("skillOverrides")' "$target" 2>/dev/null || echo "false")
  if [[ "$has" != "true" ]]; then
    if [[ -f "$backup" ]]; then
      printf "  no overrides   : %s (stale backup present, leaving alone)\n" "$rel"
    fi
    ((nochange++)) || true
    continue
  fi

  if [[ -f "$backup" ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      printf "  would restore  : %s (from $BACKUP_SUFFIX)\n" "$rel"
    else
      mv "$backup" "$target"
      printf "  restored       : %s\n" "$rel"
    fi
    ((restored++)) || true
  else
    new=$(jq 'del(.skillOverrides)' "$target")
    remaining=$(echo "$new" | jq 'keys | length')

    if [[ "$remaining" -eq 0 ]]; then
      if [[ $DRY_RUN -eq 1 ]]; then
        printf "  would remove   : %s (file would become empty)\n" "$rel"
      else
        rm "$target"
        printf "  removed empty  : %s\n" "$rel"
      fi
      ((removed++)) || true
    else
      if [[ $DRY_RUN -eq 1 ]]; then
        printf "  would strip    : %s (keep %s other keys)\n" "$rel" "$remaining"
      else
        printf '%s\n' "$new" > "$target"
        printf "  stripped       : %s\n" "$rel"
      fi
      ((stripped++)) || true
    fi
  fi
done

echo
echo "Done. restored=$restored stripped=$stripped removed=$removed nochange=$nochange"
if [[ $DRY_RUN -eq 0 && $((restored + stripped + removed)) -gt 0 ]]; then
  echo "Restart Claude Code in each affected repo for the revert to take effect."
fi
