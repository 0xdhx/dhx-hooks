#!/bin/bash
# Patterns: HP-009
# DHX Health Check — SessionStart hook
# Runs fork verification and symlink checks, writes results to cache.
# Zero stdout on all paths — purely a cache writer.
# Cost: ~50ms (4 file reads + 2 greps + ls check). No network, no git, no node.

CACHE_DIR="$HOME/.cache/dhx"
CACHE_FILE="$CACHE_DIR/health.json"
DHX_SYM="$HOME/.claude/scripts/dhx-sym.sh"

mkdir -p "$CACHE_DIR"

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
missing=0
config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
for item in get-shit-done hooks gsd-file-manifest.json gsd-local-patches package.json; do
  [[ -e "$config_dir/$item" ]] || missing=$((missing + 1))
done

# --- Write cache (atomic via temp + mv) ---
tmp="$CACHE_FILE.tmp.$$"
cat > "$tmp" <<EOF
{"worktree_patches":"$wt_state","read_guard":"$rg_state","missing_symlinks":$missing,"checked":$(date +%s)}
EOF
mv -f "$tmp" "$CACHE_FILE"

exit 0
