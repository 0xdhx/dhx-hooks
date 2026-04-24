#!/usr/bin/env bash
# Patterns: HP-017, HP-025
# dhx-plugin-registry-heal.sh — SessionStart heal hook (companion to HP-025 detector)
#
# Closes the detection→remediation loop for HP-025 by writing a valid v2
# installed_plugins.json seed with a dhx@dhx-local entry when the file is
# unreadable, unparseable, or missing the dhx entry. Pulls truthful metadata
# from the cache dir (version + installPath) + hooks repo HEAD (gitCommitSha)
# so the healed record matches what `claude plugin install` would have produced.
#
# Scope (mirrors HP-025 detector):
#   - UNREADABLE:installed_plugins.json  → write v2 seed
#   - BADJSON:installed_plugins.json     → overwrite with v2 seed
#   - UNINSTALLED:dhx@dhx-local          → insert dhx entry, preserve others
# Out of scope (handled elsewhere):
#   - known_marketplaces.json drift      → CC self-heals via Hn() at session init
#   - MISSING:dhx-local in settings      → bashrc wrapper heal (HP-017)
#   - PATH / DISABLED                    → structural / settings-level
#
# Silent on happy path. No stdin parsing (filesystem state, not session context).
# ~50ms budget: no subprocess spawns beyond jq, no network, no disk walks.
#
# INVARIANT: uses `mv tmp target` for atomic replacement. This BREAKS the
# hardlink topology between ~/.claude/plugins/installed_plugins.json and
# ~/.ccs/shared/plugins/installed_plugins.json (single inode → two inodes
# after mv). Tradeoff accepted — atomicity avoids partial-write corruption
# (the Wj() bug class the hook exists to mitigate); next `claude plugin
# install` re-establishes topology via in-place openSync("w"). Per-profile
# SessionStart firings heal each profile's own CLAUDE_CONFIG_DIR view.
# Probe: tests/probes/probe-plugin-registry-heal.sh

set -uo pipefail

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
IP_PATH="$CONFIG_DIR/plugins/installed_plugins.json"
MARKETPLACE="dhx-local"
PLUGIN_KEY="dhx@dhx-local"
CACHE_BASE="$CONFIG_DIR/plugins/cache/$MARKETPLACE/dhx"
HOOKS_REPO="/home/dhx/repos/hooks"

# --- Cache source-of-truth probe ---
# Without the plugin cache directory we cannot synthesize truthful metadata
# (installPath, version). Exit silently — detector will keep firing, which is
# the correct behavior: a heal that fabricates paths would make state worse.
if [[ ! -d "$CACHE_BASE" ]]; then
  exit 0
fi

shopt -s nullglob
_dirs=( "$CACHE_BASE"/*/ )
shopt -u nullglob
if (( ${#_dirs[@]} == 0 )); then
  exit 0
fi

# Highest-version cache dir (normally exactly one exists). Strip trailing slash.
INSTALL_PATH=$(printf '%s\n' "${_dirs[@]%/}" | sort -V | tail -1)
PLUGIN_JSON="$INSTALL_PATH/.claude-plugin/plugin.json"
if [[ ! -f "$PLUGIN_JSON" ]]; then
  exit 0
fi

VERSION=$(jq -r '.version // empty' "$PLUGIN_JSON" 2>/dev/null)
if [[ -z "$VERSION" ]]; then
  exit 0
fi

GIT_SHA=$(git -C "$HOOKS_REPO" rev-parse HEAD 2>/dev/null || echo "")
NOW=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)

# --- Determine heal need ---
# Four states, matching the prompt's heal scope:
#   - file missing or 0 bytes  → NEED_HEAL=1, start from empty seed
#   - file present but !valid  → NEED_HEAL=1, start from empty seed
#   - valid JSON lacking dhx   → NEED_HEAL=1, preserve existing plugins object
#   - valid JSON with dhx      → no-op, exit 0
NEED_HEAL=0
CURRENT_JSON='{"version":2,"plugins":{}}'

if [[ ! -s "$IP_PATH" ]]; then
  NEED_HEAL=1
elif ! jq -e . "$IP_PATH" >/dev/null 2>&1; then
  NEED_HEAL=1
else
  HAS_DHX=$(jq -r --arg k "$PLUGIN_KEY" '.plugins[$k] // [] | length' "$IP_PATH" 2>/dev/null || echo 0)
  if [[ "$HAS_DHX" == "0" || -z "$HAS_DHX" ]]; then
    NEED_HEAL=1
    CURRENT_JSON=$(cat "$IP_PATH")
  fi
fi

if (( NEED_HEAL == 0 )); then
  exit 0
fi

# --- Build entry ---
DHX_ENTRY=$(jq -n \
  --arg installPath "$INSTALL_PATH" \
  --arg version "$VERSION" \
  --arg installedAt "$NOW" \
  --arg lastUpdated "$NOW" \
  --arg gitCommitSha "$GIT_SHA" \
  '{
    scope: "user",
    installPath: $installPath,
    version: $version,
    installedAt: $installedAt,
    lastUpdated: $lastUpdated
  } + (if $gitCommitSha == "" then {} else {gitCommitSha: $gitCommitSha} end)' 2>/dev/null)

if [[ -z "$DHX_ENTRY" ]]; then
  exit 0
fi

# --- Merge entry into (possibly preserved) plugins object ---
NEW_JSON=$(printf '%s' "$CURRENT_JSON" | jq \
  --arg k "$PLUGIN_KEY" \
  --argjson entry "$DHX_ENTRY" \
  '.version = 2 | .plugins = ((.plugins // {}) | .[$k] = [$entry])' 2>/dev/null)

if [[ -z "$NEW_JSON" ]]; then
  exit 0
fi

# --- Atomic write ---
# Ensure parent dir exists (missing-file scenario can hit a case where
# ~/.claude/plugins doesn't exist at all). readlink -f handles the symlinked
# CCS-instance case: mv targets the real file so the symlink chain stays intact.
PLUGINS_DIR=$(dirname "$IP_PATH")
mkdir -p "$PLUGINS_DIR" 2>/dev/null || exit 0

if [[ -e "$IP_PATH" ]]; then
  TARGET_REAL=$(readlink -f "$IP_PATH" 2>/dev/null || printf '%s' "$IP_PATH")
else
  TARGET_REAL="$IP_PATH"
fi

TMP="$TARGET_REAL.tmp.$$"
printf '%s\n' "$NEW_JSON" > "$TMP" 2>/dev/null || { rm -f "$TMP" 2>/dev/null; exit 0; }
mv -f "$TMP" "$TARGET_REAL" 2>/dev/null || rm -f "$TMP" 2>/dev/null

exit 0
