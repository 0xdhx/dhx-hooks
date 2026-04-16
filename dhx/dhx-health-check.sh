#!/bin/bash
# Patterns: HP-009
# DHX Health Check — SessionStart hook
# Runs fork verification and symlink checks, writes results to cache.
# Clears this session's drift snapshot so wrapper writes a fresh baseline on resume.
# Zero stdout on all paths — purely a cache writer.
# Cost: ~50ms (4 file reads + 2 greps + ls check). No network, no git, no node.

CACHE_DIR="$HOME/.cache/dhx"
CACHE_FILE="$CACHE_DIR/health.json"
DHX_SYM="$HOME/.claude/scripts/dhx-sym.sh"

mkdir -p "$CACHE_DIR"

# Read stdin — session_id available since CC added it to SessionStart events
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)

# --- Worktree patches ---
wt_state="patched"
if [[ -x "$DHX_SYM" ]]; then
  "$DHX_SYM" verify-worktree-patches >/dev/null 2>&1
  case $? in
    0) wt_state="patched" ;;
    1) wt_state="REGRESSED" ;;
    2) wt_state="REVIEW" ;;
    3) wt_state="DRIFT" ;;
  esac
fi

# --- Read-guard fork ---
rg_state="patched"
if [[ -x "$DHX_SYM" ]]; then
  "$DHX_SYM" verify-read-guard-fork >/dev/null 2>&1
  case $? in
    0) rg_state="patched" ;;
    1) rg_state="REGRESSED" ;;
    2) rg_state="REVIEW" ;;
    3) rg_state="DRIFT" ;;
  esac
fi

# --- Symlink health (active profile only) ---
# In a CCS profile, items must be symlinks to ~/.claude. In ~/.claude itself,
# they're the real thing. A real dir where a symlink belongs means invisible
# drift — e.g., a botched GSD install writing into the profile instead of
# following the symlink to ~/.claude.
missing=0
config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
for item in get-shit-done hooks gsd-file-manifest.json gsd-local-patches package.json; do
  p="$config_dir/$item"
  if [[ ! -e "$p" ]]; then
    missing=$((missing + 1))
  elif [[ "$config_dir" != "$HOME/.claude" && ! -L "$p" ]]; then
    missing=$((missing + 1))
  fi
done

# --- Settings chain integrity ---
# Canonical: ~/.claude/settings.json -> ~/.ccs/shared/settings.json (real file).
# The .bashrc claude() wrapper enforces this on session exit, but can be
# bypassed (subshells, repair scripts using `mv tmp target` on the symlink).
# When the chain breaks, ~/.claude/settings.json silently stops tracking CCS
# changes — no user-visible error, just drift.
settings_chain="ok"
claude_settings="$HOME/.claude/settings.json"
shared_settings="$HOME/.ccs/shared/settings.json"
if [[ ! -f "$shared_settings" ]] || [[ -L "$shared_settings" ]]; then
  settings_chain="SHARED_MISSING"
elif [[ ! -L "$claude_settings" ]]; then
  settings_chain="REAL_FILE"
elif [[ "$(readlink -f "$claude_settings")" != "$(readlink -f "$shared_settings")" ]]; then
  settings_chain="WRONG_TARGET"
fi

# --- Write health cache (atomic via temp + mv) ---
tmp="$CACHE_FILE.tmp.$$"
cat > "$tmp" <<EOF
{"worktree_patches":"$wt_state","read_guard":"$rg_state","missing_symlinks":$missing,"settings_chain":"$settings_chain","checked":$(date +%s)}
EOF
mv -f "$tmp" "$CACHE_FILE"

# --- Clear THIS session's drift snapshot (scoped, not global) ---
# /exit + resume reuses session_id but reloads hooks/settings/binary, making
# the existing snapshot baseline stale. Only delete the current session's
# snapshot — other concurrent sessions keep their baselines intact.
if [[ -n "$SESSION_ID" ]]; then
  rm -f "$CACHE_DIR/drift-snapshot-${SESSION_ID}.json"
fi

# --- Prune stale drift cache files (all formats, >30 days) ---
find "$CACHE_DIR" -name 'drift-snapshot-*.json' -mtime +30 -delete 2>/dev/null
find "$CACHE_DIR" -name 'session-start-*.json' -mtime +30 -delete 2>/dev/null
find "$CACHE_DIR" -name 'session-version-*.txt' -mtime +30 -delete 2>/dev/null

exit 0
