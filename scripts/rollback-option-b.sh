#!/usr/bin/env bash
# scripts/rollback-option-b.sh — operator rollback runbook for Phase 1
#                                Option B atomic commit (D-18 V-ROLLBACK-SCRIPT)
#
# Restores the external state captured by the atomic commit:
#   1. ~/.ccs/shared/settings.json (from /tmp/settings.json.pre-option-b.bak,
#      if backup is present and timestamped within 7 days)
#   2. config/settings.json (mirrored from restored live settings)
#   3. Symlinks: re-create ~/.claude/hooks/dhx-read-partial-cache.sh
#      (post-`git revert` only — the source file is deleted in the commit,
#      so the symlink target only re-exists after revert)
#   4. ~/.claude/hooks/dhx-read-cache.sh: removed
#   5. Operator prompt: run `git revert <commit-hash>` last
#
# The "single atomic commit" claim of D-06 is HONEST only because this
# rollback script makes the external-state mutations reversible. Without
# it, `git revert` would only restore repo files; live settings, symlinks,
# and orphan-cleaned per-session caches would remain stuck post-cutover.
#
# Usage:
#   bash scripts/rollback-option-b.sh --help     # dry-run runbook to stdout
#   bash scripts/rollback-option-b.sh <hash>     # execute rollback for given commit hash
#   bash scripts/rollback-option-b.sh            # interactive — prompts for hash
#
# Closes cross-AI review concern (Codex § "Rollback is not truly single-revert").

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BACKUP="/tmp/settings.json.pre-option-b.bak"
LIVE_SETTINGS=$(readlink -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json")

# Helper: print the rollback runbook (used for --help and as preamble of execution)
print_runbook() {
  cat <<'RUNBOOK'
============================================================
ROLLBACK RUNBOOK — v1.1 Phase 1 Option B atomic commit
============================================================

External state operations (this script automates 1-4):

  1. Restore live settings from backup:
       cp /tmp/settings.json.pre-option-b.bak ~/.ccs/shared/settings.json
     Requires: backup file present AND mtime < 7 days old.

  2. Mirror restored live settings into drift snapshot:
       cp ~/.ccs/shared/settings.json <repo>/config/settings.json

  3. Restore symlink for retired partial-cache hook (post-revert ONLY):
       ln -sfn <repo>/dhx/dhx-read-partial-cache.sh \
               ~/.claude/hooks/dhx-read-partial-cache.sh
     This step is conditional: the source file is DELETED in the atomic
     commit, so it only re-exists after `git revert`. The script defers
     this step and prints a NOTE if the source is missing.

  4. Remove the new writer's symlink:
       rm -f ~/.claude/hooks/dhx-read-cache.sh

Operator-driven (this script DOES NOT automate):

  5. Run `git revert <commit-hash>` from the repo root.
     The hash is captured at /tmp/option-b-commit-hash.txt by Task 2
     of Plan 05; or pass it as an argument to this script.

  6. Restart all 21+ concurrent CC sessions to pick up restored
     plugin manifest + settings.

  7. Verify rollback success:
       bash scripts/verify-hooks.sh
       diff <(jq -S . ~/.ccs/shared/settings.json) \
            <(jq -S . config/settings.json)

============================================================
RUNBOOK
}

# --help short-circuit
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  print_runbook
  exit 0
fi

# Execution path
print_runbook
echo
echo "=== EXECUTING ROLLBACK ==="
echo

# Step 1: restore live settings from backup
if [ ! -f "$BACKUP" ]; then
  echo "FAIL: backup not present at $BACKUP — nothing to restore"
  echo "      (backup is created by Plan 04 Task 2 Step 1 prior to live edit)"
  exit 1
fi

BACKUP_AGE_SECS=$(( $(date +%s) - $(stat -c %Y "$BACKUP") ))
SEVEN_DAYS=604800
if [ "$BACKUP_AGE_SECS" -gt "$SEVEN_DAYS" ]; then
  echo "FAIL: backup at $BACKUP is older than 7 days (${BACKUP_AGE_SECS}s)"
  echo "      Aborting — manual restore required (the live settings may have"
  echo "      drifted significantly since this backup was taken)."
  exit 1
fi

cp "$BACKUP" "$LIVE_SETTINGS"
echo "OK: restored $LIVE_SETTINGS from $BACKUP"

# Step 2: mirror restored live settings into drift snapshot
cp "$LIVE_SETTINGS" "$REPO/config/settings.json"
echo "OK: mirrored to $REPO/config/settings.json"

# Step 3: restore symlink for partial-cache (conditional)
PARTIAL_SRC="$REPO/dhx/dhx-read-partial-cache.sh"
PARTIAL_LINK="$HOME/.claude/hooks/dhx-read-partial-cache.sh"
if [ -e "$PARTIAL_SRC" ]; then
  ln -sfn "$PARTIAL_SRC" "$PARTIAL_LINK"
  echo "OK: restored symlink $PARTIAL_LINK -> $PARTIAL_SRC"
else
  echo "NOTE: $PARTIAL_SRC does not exist — run \`git revert\` first, then re-run"
  echo "      this script to complete symlink restoration. (The source file is"
  echo "      deleted in the atomic commit and only re-exists post-revert.)"
fi

# Step 4: remove new writer's symlink
rm -f "$HOME/.claude/hooks/dhx-read-cache.sh"
echo "OK: removed $HOME/.claude/hooks/dhx-read-cache.sh"

# Operator handoff
echo
echo "=== OPERATOR ACTION REQUIRED ==="
HASH="${1:-}"
if [ -z "$HASH" ] && [ -f /tmp/option-b-commit-hash.txt ]; then
  HASH=$(cat /tmp/option-b-commit-hash.txt)
fi
if [ -n "$HASH" ]; then
  echo "Run from $REPO:"
  echo "    git revert $HASH"
else
  echo "Pass the atomic commit hash as the first argument, then run:"
  echo "    git revert <hash>"
fi
echo
echo "After revert: re-run this script to complete Step 3 (symlink restore)"
echo "if the source file was missing on the first pass."
echo
echo "Restart all 21+ concurrent CC sessions afterward."
echo "Final verify: bash scripts/verify-hooks.sh"
exit 0
