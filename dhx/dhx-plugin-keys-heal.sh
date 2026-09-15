#!/usr/bin/env bash
# Patterns: HP-017
# dhx-plugin-keys-heal.sh — restores the two load-gating dhx plugin keys in the settings file
# Claude Code is about to read:
#   enabledPlugins["dhx@dhx-local"] = true
#   extraKnownMarketplaces["dhx-local"].source = {source: "directory", path: <dhx-plugin dir>}
# A stale-snapshot CC session can drop both with its atomic settings rewrite (HP-017). With
# either missing, CC silently skips the dhx plugin, so no hook it registers can repair them.
#
# Caller: dhx/dhx-prelaunch.sh, before Claude Code starts, ahead of
# dhx-plugin-registry-heal.sh — that heal repairs known_marketplaces.json only for a
# marketplace settings declares, so the declaration has to be back first. Until 2026-09-15 this
# repair lived in the ~/.bashrc claude() wrapper, which non-interactive shells and daemon-hosted
# sessions never reach (docs/decisions.md 2026-09-15 plugin-keys row).
#
# Detector: the canonical predicate below, byte-identical at every site that checks these keys
# (dhx-health-check.sh, scripts/install-plugin.sh, tests/probes/probe-plugin-keys.sh — parity
# enforced by tests/probes/probe-bashrc-wrapper-heal.sh). A healthy launch runs that one jq and
# exits. An explicit `false` fails the predicate too, so a hand `claude plugin disable dhx` is
# re-enabled at the next wrapped launch — the behavior the .bashrc heal had; opt out with
# DHX_PRELAUNCH_DISABLE=1.
#
# Repair: a jq merge of the two keys, NOT `claude plugin marketplace add` + `enable`. Measured
# 2026-09-15 (CC 2.1.272, sandbox config dir): those two subcommands take 2.4 s + 1.4 s, against
# a 4 s per-child bound, and a timeout would kill a CC process mid-write to the file holding the
# deny-gate. The merge writes what those commands write to settings. The known_marketplaces.json
# entry `marketplace add` also writes is the registry heal's job, run next.
#   - enabledPlugins["dhx@dhx-local"] is set to true.
#   - extraKnownMarketplaces["dhx-local"].source is written only when its path is empty or
#     absent; a declared non-empty path (another checkout) is left alone.
#
# Write path, in order: settings parses as a JSON object (else REFUSE — never rewrite a settings
# file this script cannot read) → marketplace identity guard, only when source is written (the
# directory's .claude-plugin/marketplace.json names dhx-local and lists plugin dhx) → lock →
# detect again under the lock → mktemp in the real file's directory + jq → the result passes the
# predicate AND equals the original with the two keys removed from both → the real path is
# re-resolved unchanged → mv onto the REAL file (symlinks such as ~/.claude/settings.json →
# ~/.ccs/shared/settings.json keep pointing at it) → post-write predicate check.
#
# Lock: a directory under the cache dir keyed by the real settings path; stale after 10 s and
# taken over. It serializes dhx writers only (N lanes launching at once); CC's own settings writer
# does not take it — that race is HP-017 itself, and the read→mv window here is milliseconds.
#
# Output: silent when healthy. Every repair, refusal, contention or failed write appends one line
# to $DHX_HOOKS_CACHE_DIR/plugin-keys-heal.log (default ~/.cache/dhx/hooks; rotated to .1 past
# 256 KiB). A repair prints one stderr line (it happens once per clobber). A refusal prints once
# per distinct outcome per settings file (mkdir marker); a healthy check re-arms it.
#
# Exit: 0 healthy / repaired / contention / no settings file; 1 refusal or failed write.
# Test seams: DHX_HOOKS_CACHE_DIR; DHX_PLUGIN_KEYS_MARKETPLACE_DIR (default: dhx-plugin/ beside
# this script's real dhx/ directory).
set -uo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin${PATH:+:$PATH}"

PRED='.enabledPlugins["dhx@dhx-local"] == true and (.extraKnownMarketplaces["dhx-local"].source.path // empty) != ""'

CFG="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}"
SETTINGS="$CFG/settings.json"
if [[ -n "${DHX_HOOKS_CACHE_DIR:-}" ]]; then
  CACHE_DIR="$DHX_HOOKS_CACHE_DIR"
elif [[ -n "${HOME:-}" ]]; then
  CACHE_DIR="$HOME/.cache/dhx/hooks"
else
  CACHE_DIR=""
fi
LOG_FILE="${CACHE_DIR:+$CACHE_DIR/plugin-keys-heal.log}"
LOG_MAX_BYTES=262144
MARK_ROOT="${CACHE_DIR:+$CACHE_DIR/plugin-keys-heal-first-sight}"
LOCK_STALE_S=10

# No settings file: nothing to heal. Creating one is not this script's job.
[[ -e "$SETTINGS" ]] || exit 0

digest16() { printf '%s' "$1" | sha256sum 2>/dev/null | cut -c1-16; }
SETTINGS_KEY=""

# The marker root exists only after a refusal, so a healthy launch hashes nothing.
clear_marks() {
  [[ -n "$MARK_ROOT" && -d "$MARK_ROOT" ]] || return 0
  [[ -n "$SETTINGS_KEY" ]] || SETTINGS_KEY=$(digest16 "$SETTINGS")
  [[ -n "$SETTINGS_KEY" ]] || return 0
  rm -rf "$MARK_ROOT/$SETTINGS_KEY".* 2>/dev/null
  rmdir "$MARK_ROOT" 2>/dev/null
  return 0
}

# ---- detect (the healthy path ends here) ---------------------------------------------------
if jq -e "$PRED" "$SETTINGS" >/dev/null 2>&1; then
  clear_marks
  exit 0
fi
SETTINGS_KEY=$(digest16 "$SETTINGS")

log_event() {  # outcome detail
  [[ -n "$LOG_FILE" ]] || return 0
  mkdir -p "$CACHE_DIR" 2>/dev/null || return 0
  local size
  size=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
  if (( size > LOG_MAX_BYTES )); then
    mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null
  fi
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SETTINGS" "$1" "$2" >> "$LOG_FILE" 2>/dev/null
  return 0
}

# say_once OUTCOME MESSAGE — one stderr line the first time OUTCOME is seen for this settings file.
say_once() {
  local sig
  sig=$(digest16 "$1")
  if [[ -z "$MARK_ROOT" || -z "$SETTINGS_KEY" || -z "$sig" ]]; then
    printf '⚠ %s\n' "$2" >&2
    return 0
  fi
  if mkdir -p "$MARK_ROOT" 2>/dev/null && mkdir "$MARK_ROOT/$SETTINGS_KEY.$sig" 2>/dev/null; then
    printf '⚠ %s (log: %s)\n' "$2" "$LOG_FILE" >&2
  fi
  return 0
}

LOCK_DIR=""
LOCK_INODE=""
TMP=""
cleanup() {
  [[ -n "$TMP" ]] && rm -f "$TMP" 2>/dev/null
  if [[ -n "$LOCK_INODE" && "$(stat -c %i "$LOCK_DIR" 2>/dev/null)" == "$LOCK_INODE" ]]; then
    rmdir "$LOCK_DIR" 2>/dev/null
  fi
  return 0
}
trap cleanup EXIT

refuse() {
  log_event REFUSE "$1"
  say_once "refuse:$1" "dhx-plugin-keys-heal: REFUSE: $1"
  exit 1
}

acquire_lock() {
  local i mtime away
  mkdir -p "$CACHE_DIR" 2>/dev/null || return 1
  for i in 1 2 3 4 5; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      LOCK_INODE=$(stat -c %i "$LOCK_DIR" 2>/dev/null)
      return 0
    fi
    mtime=$(stat -c %Y "$LOCK_DIR" 2>/dev/null) || continue
    if (( $(date +%s) - mtime > LOCK_STALE_S )); then
      away="$LOCK_DIR.stale.$$.$i"
      mv "$LOCK_DIR" "$away" 2>/dev/null && rm -rf "$away" 2>/dev/null
      continue
    fi
    sleep 0.2
  done
  return 1
}

# ---- mutation path ------------------------------------------------------------------------
REAL=$(readlink -f "$SETTINGS" 2>/dev/null)
[[ -n "$REAL" && -f "$REAL" && ! -L "$REAL" ]] || refuse "settings does not resolve to a regular file ($SETTINGS)"
jq -e 'type == "object"' "$REAL" >/dev/null 2>&1 || refuse "settings is not a parseable JSON object ($REAL)"

# What is missing decides whether the marketplace source is written (and so guarded).
if ! need_source=$(jq -r '(.extraKnownMarketplaces["dhx-local"].source.path // "") == ""' "$REAL" 2>/dev/null); then
  refuse "extraKnownMarketplaces has an unexpected shape ($REAL)"
fi
MP_DIR=""
if [[ "$need_source" == "true" ]]; then
  MP_DIR="${DHX_PLUGIN_KEYS_MARKETPLACE_DIR:-$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")/dhx-plugin}"
  [[ "$MP_DIR" = /* && -d "$MP_DIR" ]] || refuse "marketplace directory missing or not absolute ($MP_DIR)"
  MP_DIR=$(readlink -f "$MP_DIR")
  manifest="$MP_DIR/.claude-plugin/marketplace.json"
  jq -e '.name == "dhx-local" and ([.plugins[]? | select(.name == "dhx")] | length) > 0' "$manifest" >/dev/null 2>&1 \
    || refuse "no dhx-local marketplace manifest listing plugin dhx at $manifest"
fi

[[ -n "$CACHE_DIR" ]] || refuse "no cache dir for the lock (HOME unset)"
LOCK_DIR="$CACHE_DIR/plugin-keys-heal.$(digest16 "$REAL").lock"
if ! acquire_lock; then
  log_event CONTENTION "lock=$LOCK_DIR"
  exit 0
fi

# Another writer may have repaired it while we waited: decide again under the lock.
if jq -e "$PRED" "$REAL" >/dev/null 2>&1; then
  clear_marks
  exit 0
fi

missing=$(jq -r '[ (if .enabledPlugins["dhx@dhx-local"] == true then empty else "enabledPlugins" end),
                   (if (.extraKnownMarketplaces["dhx-local"].source.path // "") == "" then "extraKnownMarketplaces" else empty end) ]
                 | join("+")' "$REAL" 2>/dev/null)

TMP=$(mktemp "$(dirname "$REAL")/.settings.dhx-keys-heal.XXXXXX") || refuse "mktemp failed beside $REAL"
if ! jq --arg p "$MP_DIR" '
      (if (.extraKnownMarketplaces["dhx-local"].source.path // "") == ""
         then .extraKnownMarketplaces["dhx-local"].source = {source: "directory", path: $p}
         else . end)
      | .enabledPlugins["dhx@dhx-local"] = true
    ' "$REAL" > "$TMP" 2>/dev/null; then
  log_event WRITE_FAILED "jq merge failed; missing=$missing"
  say_once "write-failed" "dhx-plugin-keys-heal: jq merge failed for $REAL"
  exit 1
fi

# Everything except the two keys must be unchanged, and the keys must now pass.
STRIP='del(.enabledPlugins["dhx@dhx-local"], .extraKnownMarketplaces["dhx-local"])
       | if .enabledPlugins == {} then del(.enabledPlugins) else . end
       | if .extraKnownMarketplaces == {} then del(.extraKnownMarketplaces) else . end'
if ! jq -e "$PRED" "$TMP" >/dev/null 2>&1 \
   || [[ "$(jq -cS "$STRIP" "$TMP" 2>/dev/null)" != "$(jq -cS "$STRIP" "$REAL" 2>/dev/null)" ]]; then
  log_event WRITE_FAILED "merge result failed the predicate or changed other keys; missing=$missing"
  say_once "write-invalid" "dhx-plugin-keys-heal: merge result invalid for $REAL — not written"
  exit 1
fi
chmod --reference="$REAL" "$TMP" 2>/dev/null || chmod 0644 "$TMP" 2>/dev/null

[[ "$(readlink -f "$SETTINGS" 2>/dev/null)" == "$REAL" ]] || refuse "settings path re-resolved elsewhere before write ($SETTINGS)"
mv "$TMP" "$REAL"
mv_rc=$?
if (( mv_rc != 0 )); then
  log_event WRITE_FAILED "mv rc=$mv_rc"
  say_once "mv-failed" "dhx-plugin-keys-heal: mv failed for $REAL (rc=$mv_rc)"
  exit 1
fi
TMP=""

if ! jq -e "$PRED" "$SETTINGS" >/dev/null 2>&1; then
  log_event POST_WRITE_INVALID "missing=$missing"
  say_once "post-write" "dhx-plugin-keys-heal: keys still missing after write to $REAL"
  exit 1
fi

log_event REPAIRED "missing=$missing${MP_DIR:+ source=$MP_DIR}"
clear_marks
printf '⚠ dhx-plugin-keys-heal: restored dhx plugin keys (%s) in %s (log: %s)\n' "$missing" "$REAL" "$LOG_FILE" >&2
exit 0
