#!/bin/bash
# Patterns: HP-009, HP-016
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

# --- Plugin keys (HP-017 residual risk) ---
# enabledPlugins["dhx@dhx-local"] + extraKnownMarketplaces["dhx-local"] live in
# settings.json and are clobber-vulnerable per the 2026-04-16 rewriter
# investigation. Missing either → plugin hooks stop firing and /dhx:sym repair
# is the recovery path.
#
# Two-source resolution: the skills-repo `/dhx:sym` publisher writes
# ~/.cache/dhx/sym-health.json on every status/audit/repair invocation. That
# file is the authoritative signal (single source of truth — same process that
# runs `claude plugin enable` publishes the result). If fresh (<1h via
# checked_at), prefer its plugin_keys field. Otherwise fall back to the direct
# jq check below — defense-in-depth when the cache goes stale, the skills repo
# moves, or the publisher breaks. Resolution of settings.json via
# CLAUDE_CONFIG_DIR + realpath matches statusline-wrapper.js::hashWarnSettings().
plugin_keys=""
sym_health="$CACHE_DIR/sym-health.json"
if [[ -f "$sym_health" ]]; then
  checked_at=$(jq -r '.checked_at // empty' "$sym_health" 2>/dev/null)
  if [[ -n "$checked_at" ]]; then
    checked_epoch=$(date -u -d "$checked_at" +%s 2>/dev/null || echo 0)
    age_sec=$(( $(date +%s) - checked_epoch ))
    if (( checked_epoch > 0 && age_sec >= 0 && age_sec < 3600 )); then
      plugin_keys=$(jq -r '.plugin_keys // empty' "$sym_health" 2>/dev/null)
    fi
  fi
fi
if [[ -z "$plugin_keys" ]]; then
  plugin_keys="ok"
  settings_real=$(readlink -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" 2>/dev/null)
  if [[ ! -f "$settings_real" ]] || \
     ! jq -e '.enabledPlugins["dhx@dhx-local"] == true and (.extraKnownMarketplaces["dhx-local"].source.path // empty) != ""' "$settings_real" >/dev/null 2>&1; then
    plugin_keys="MISSING"
  fi
fi

# --- Write health cache (atomic via temp + mv) ---
tmp="$CACHE_FILE.tmp.$$"
cat > "$tmp" <<EOF
{"worktree_patches":"$wt_state","read_guard":"$rg_state","missing_symlinks":$missing,"settings_chain":"$settings_chain","plugin_keys":"$plugin_keys","checked":$(date +%s)}
EOF
mv -f "$tmp" "$CACHE_FILE"

# --- Clear THIS session's drift snapshots (scoped, not global) ---
# Wrapper now keys snapshots by (session_id, process_start_ticks), so /resume
# into a new process gets a fresh file without needing this hook to run. Hook
# still earns its keep for /clear and /compact events where process identity is
# unchanged but the user wants a fresh drift baseline. Glob matches both the
# process-stamped format (`-p<ticks>.json`) and the legacy session-id-only
# format (for macOS fallback + migration). Other sessions' snapshots intact.
if [[ -n "$SESSION_ID" ]]; then
  rm -f "$CACHE_DIR/drift-snapshot-${SESSION_ID}.json" "$CACHE_DIR"/drift-snapshot-${SESSION_ID}-*.json
fi

# --- Prune orphan drift snapshots (Linux: live-tick cross-check) ---
# Fast path: a snapshot filename carries `-p<ticks>` (HP-016 field 22) and any
# ticks value not present in a live CC process is an orphan. 1h mtime grace
# handles newly-started CC processes whose hook just fired (this session or a
# sibling coming up in the same minute). Non-Linux (no /proc) skips this block
# and relies on the 30d sweep below.
#
# Keeps the cache scannable during debugging — `ls ~/.cache/dhx/` stays a
# handful of files instead of hundreds. Not a correctness fix; hygiene only.
# Each live session still keys on its own (session_id, ticks), so no probe
# cares which dead sessions' snapshots survived.
if [[ -d /proc ]]; then
  live_ticks=$(for pid in $(pgrep -f 'bin/claude' 2>/dev/null); do
    awk '{print $22}' /proc/"$pid"/stat 2>/dev/null
  done | sort -u)
  now=$(date +%s)
  for f in "$CACHE_DIR"/drift-snapshot-*-p*.json; do
    [[ -f "$f" ]] || continue
    ticks=$(basename "$f" | sed -nE 's/^drift-snapshot-.*-p([0-9]+)\.json$/\1/p')
    [[ -z "$ticks" ]] && continue
    mtime=$(stat -c '%Y' "$f" 2>/dev/null || echo 0)
    (( now - mtime < 3600 )) && continue
    if ! grep -Fxq "$ticks" <<<"$live_ticks"; then
      rm -f "$f"
    fi
  done
fi

# --- Prune stale drift cache files (>30 days) ---
# Catchall for non-Linux (no /proc orphan sweep above) and for legacy files
# without `-p<ticks>` suffix (macOS fallback path from HP-016, pre-2026-04-16
# snapshots). Defense-in-depth: any file the orphan sweep missed, the 30d TTL
# eventually collects. session-start-*.json and session-version-*.txt were
# prior drift designs obsoleted by the snapshot-comparison scheme; nothing
# writes them anymore — one-time purge happened 2026-04-16 under the drift-fix
# orchestration.
find "$CACHE_DIR" -name 'drift-snapshot-*.json' -mtime +30 -delete 2>/dev/null

exit 0
