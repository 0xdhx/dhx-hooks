#!/usr/bin/env bash
# Patterns: HP-017, HP-025
# dhx-plugin-registry-heal.sh — repairs $CLAUDE_CONFIG_DIR/plugins/known_marketplaces.json
# ("km") so Claude Code's plugin loader accepts it and the dhx-local marketplace resolves.
#
# Callers (2026-09-15, docs/decisions.md 2026-09-15 pre-launch row):
#   - dhx/dhx-prelaunch.sh, run by the launch wrappers BEFORE Claude Code starts
#     (cross-repo health/scripts/claude-capped.sh, and dotfiles bin/clodex-bridge — the
#     shared settings `processWrapper` for daemon sessions). This is the only caller that
#     can repair a registry for the session being launched: in every failure state the dhx
#     plugin does not load, so its own SessionStart cannot fire (measured, CC 2.1.272).
#     Sets DHX_REGISTRY_HEAL_SURFACE=prelaunch.
#   - dhx-plugin/plugins/dhx/hooks/session-start.sh (`_dhx_child registry-heal`), kept for
#     the mid-session case: a registry corrupted after a healthy start is repaired on
#     /clear, before the next launch (measured firing on SessionStart:clear).
#
# What CC 2.1.272 requires (km schema read from the binary; confirmed by launching it):
# every entry is an object carrying a string `installLocation` and a string `lastUpdated`.
# ONE entry missing `lastUpdated` makes CC reject the whole file ("Marketplace configuration
# file is corrupted: <name>.lastUpdated: Invalid input"), load no plugin from any
# marketplace, and never repair it (its writer re-reads the file under its lock and throws).
# CC does rebuild a missing file or a missing entry from settings.extraKnownMarketplaces —
# but only for the NEXT launch — and it never repairs an unparseable file or a stale
# installLocation.
#
# Detector — the whole file. States, any combination (canonical order):
#   UNREADABLE    km absent or unreadable
#   BADJSON       km unparseable, not a JSON object, or holding a non-object entry
#   MISSING       no dhx-local entry
#   STALE         dhx-local installLocation empty, not a string, or not an existing directory
#   NO_TIMESTAMP  some entry lacks a string lastUpdated
# No state = HEALTHY: exit 0 before anything else runs (and re-arm the first-sight markers).
#
# Repair. UNREADABLE and BADJSON start from {} — a BADJSON file cannot be parsed, so every
# other entry is lost, and a WARN says so. MISSING adds dhx-local {source, installLocation,
# lastUpdated}. STALE sets dhx-local installLocation = settings source.path (Pattern B: for a
# directory source CC writes installLocation == source.path). NO_TIMESTAMP stamps lastUpdated
# on each entry lacking one and changes no other field. Timestamps are UTC ISO-8601 with
# milliseconds, the shape CC writes.
#
# Write path, in order: value guards (G-02 absolute path, (b) marketplace-manifest identity
# — only when dhx-local's value is written) and (a) km target realpath → CC-compatible lock →
# detect again under the lock → atomic mktemp + jq + mv → post-write check (parses, every
# entry is an object with a string lastUpdated).
#
# Lock. Mirrors CC's own km lock (read from the 2.1.272 binary: lockfilePath
# `known_marketplaces.json.lock`, a directory, no `stale` option, so the bundled lock
# library's default applies — stale after 10 s, then taken over). mkdir the lock dir; if it
# exists and is older than 10 s, rename it away and retry; give up after ~1 s and log
# CONTENTION (rc 0: another writer is active; the next launch or /clear retries). Callers
# bound the whole run well under the 10 s stale window, so no mtime refresh is needed.
# Release removes the dir only while it is still the one this run created (inode match).
#
# Output. Silent when HEALTHY. Every repair, refusal, contention or write failure appends one
# line to $DHX_HOOKS_CACHE_DIR/registry-heal.log (default ~/.cache/dhx/hooks; rotated to .1
# past 256 KiB). stderr depends on the caller:
#   - default (SessionStart / direct): the long-standing contract — REJECT and POST-WRITE lines
#     and the BADJSON WARN always go to stderr; other repairs are silent. `_dhx_child`
#     surfaces a non-zero rc once per distinct message.
#   - DHX_REGISTRY_HEAL_SURFACE=prelaunch: the terminal is the user's, before Claude Code
#     draws. A repair or refusal prints ONE line the first time that outcome is seen for this
#     config dir (an atomic mkdir marker); repeats stay silent until the outcome changes or
#     the registry is HEALTHY again. Contention never prints.
#
# --- WHO REMOVES THE ENTRY, AND WHO PUTS IT BACK (attributed 2026-09-20) ---
# THE WRITER IS CCS, NOT CLAUDE CODE. `@kaitranntt/ccs`
# `dist/management/shared-manager/plugin-metadata-normalizer.js` ::
# `buildMarketplaceRegistryContent` keeps ONLY those known_marketplaces entries that have a
# physical `<cfg>/plugins/marketplaces/<name>` directory and `delete`s the rest, writing both
# `~/.claude` and the instance copy. It runs from `normalizeSharedPluginMetadataPathsLocked`
# on every `ccs <account> …` invocation. `dhx-local` is a `directory`-source marketplace
# pointing at this repo, so it has no directory under `plugins/marketplaces/` and is deleted
# every single time. Nothing about it is dhx-specific: `chrome-devtools-plugins`, the other
# directory-source marketplace here, is dropped by the same line.
# MEASURED, not read off the source: a fixture run of the real normalizer drops the entry
# with no marketplaces dir, KEEPS it when a REAL DIRECTORY exists at that path, and STILL
# DROPS IT when that path is a SYMLINK — `readdirSync(…, {withFileTypes:true})` reports the
# link, not its target, so `entry.isDirectory()` is false. A symlink shortcut does not work;
# do not reach for one. A real directory does work, but the normalizer then rewrites
# `installLocation` to that (empty) directory, which is why it is not the chosen fix.
#
# THE RESTORER IS CLAUDE CODE ITSELF, and that is what keeps this heal from being the only
# thing standing between a `ccs` invocation and an unguarded session.
# HOW IT WAS ESTABLISHED, INCLUDING THE FALSE START, because the false start is the easy
# mistake to repeat. First attempt: launch against `~/.claude` (whose registry had been
# stripped) WITHOUT the ccs wrapper, on the theory that this skipped the heal. It did skip
# the PRE-LAUNCH heal — and proved nothing about `dhx-local`, because THIS SCRIPT ALSO RUNS
# AS A SessionStart CHILD of the dispatcher, and duly logged
# `12:23:17Z /home/dhx/.claude REPAIRED`. The only clean signal in that run was
# `chrome-devtools-plugins` returning at 12:23:20.796Z, which this script never touches.
# CLEAN DEMONSTRATION: a sandbox `HOME` + `CLAUDE_CONFIG_DIR` (so no dhx hook fires at all),
# settings declaring the SAME directory source under a DIFFERENT key so this script no-ops
# on "dhx-local not declared", and a registry valid but missing the entry. `claude -p` there
# wrote the entry unaided, and the heal log gained no row. It did so while NOT LOGGED IN, so
# the marketplace reconciler runs ahead of, and independently of, auth. `claude plugin list`
# does NOT trigger it; it is a launch-path reconciler.
# NAMING, found the same way and worth knowing before reading a registry: CC registers the
# marketplace under the `name` from the source directory's own
# `.claude-plugin/marketplace.json` — `dhx-local` — NOT under the key used in
# `extraKnownMarketplaces`. The sandbox declared `sbx-local` and CC wrote `dhx-local`. A
# settings key and a registry key are therefore not the same identifier and must not be
# assumed to match.
# CONSEQUENCE FOR THIS SCRIPT'S STATUS: it is a RACE-WINNER, not the sole repairer. Running
# pre-launch, it writes the entry before CC's reconciler gets there — which is why every
# `dhx-local` `lastUpdated` on this machine matches a REPAIRED row in the log to the second,
# and why that correlation must NOT be read as "CC would not have restored it". It was read
# that way once during this very investigation and was wrong.
# WHAT IT STILL BUYS: cover for the mid-session strip (a `ccs` invocation while a session is
# already up), for config dirs nothing launches under, and for the four non-MISSING shapes
# (ABSENT / TRUNCATED / NO_TIMESTAMP / STALE) that CC does not fix. Keep it.
#
# --- CONTENTION rows: the same drop seen twice, NOT a second writer ---
# A CONTENTION row is a heal that could not take the lock within ~1 s. It is one CCS strip
# observed by a BURST of concurrent pre-launch heals — several instances launching together,
# plus CC holding its own km lock during the startup reconcile described above. The evidence
# that it is one drop and not two writers: the heal rows cluster on a single second
# (2026-09-20 saw four instances all stamped 10:31:44Z), which is one `ccs` invocation
# rewriting every copy, not independent events. CONTENTION is therefore benign by
# construction — the peer holding the lock is writing the same repair this run wanted, and
# the entry ends up present either way. It exits 0 and stays out of the pre-launch surface
# deliberately.
#
# STATUS: permanent until the upstream CCS behaviour changes. The right fix is upstream --
# the normalizer should not require a `plugins/marketplaces/<name>` directory for a
# marketplace whose declared source is a directory. Until then this heal stays.
#
# Exit: 0 healthy / repaired / contention / dhx-local not declared; 1 refusal or failed write.
# Out of scope: dhx-local not declared in settings → dhx-plugin-keys-heal.sh (HP-017), which
# dhx-prelaunch.sh runs first; PATH / DISABLED
# → settings-level.
# History: docs/decisions.md 2026-05-03 (IP path retired), 2026-05-13 (km heal), 2026-09-14
# (healthy-first, identity guard), 2026-09-15 (lastUpdated, whole-file detector, lock,
# pre-launch caller, output surfaces).
set -uo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin${PATH:+:$PATH}"

CFG="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}"
SETTINGS="$CFG/settings.json"
KM_PATH="$CFG/plugins/known_marketplaces.json"
LOCK_DIR="$KM_PATH.lock"
LOCK_STALE_S=10
MARKETPLACE_NAME="dhx-local"
if [[ -n "${DHX_HOOKS_CACHE_DIR:-}" ]]; then
  CACHE_DIR="$DHX_HOOKS_CACHE_DIR"
elif [[ -n "${HOME:-}" ]]; then
  CACHE_DIR="$HOME/.cache/dhx/hooks"
else
  CACHE_DIR=""
fi
LOG_FILE="${CACHE_DIR:+$CACHE_DIR/registry-heal.log}"
LOG_MAX_BYTES=262144
MARK_ROOT="${CACHE_DIR:+$CACHE_DIR/registry-heal-first-sight}"
SURFACE="${DHX_REGISTRY_HEAL_SURFACE:-}"

digest16() { printf '%s' "$1" | sha256sum 2>/dev/null | cut -c1-16; }

# D-11 settings-missing branch: settings absent or dhx-local not declared → nothing to heal
# (HP-025 scope boundary; dhx-plugin-keys-heal.sh territory).
[[ -r "$SETTINGS" ]] || exit 0
DHX_SOURCE_JSON=$(jq -c --arg n "$MARKETPLACE_NAME" '.extraKnownMarketplaces[$n].source // empty' "$SETTINGS" 2>/dev/null)
[[ -n "$DHX_SOURCE_JSON" && "$DHX_SOURCE_JSON" != "null" ]] || exit 0

STATES=""
KM_PARSED=""

# has_state NAME — true when NAME is in $STATES.
has_state() { [[ " $STATES " == *" $1 "* ]]; }

# detect — sets STATES (canonical order, empty when HEALTHY) and KM_PARSED.
detect() {
  STATES=""
  KM_PARSED=""
  if [[ ! -r "$KM_PATH" ]]; then
    STATES="UNREADABLE"
    return 0
  fi
  if ! KM_PARSED=$(jq -c . "$KM_PATH" 2>/dev/null) || [[ -z "$KM_PARSED" ]]; then
    STATES="BADJSON"
    KM_PARSED=""
    return 0
  fi
  local verdict
  if ! verdict=$(jq -r --arg n "$MARKETPLACE_NAME" '
      if type != "object" or ([.[] | type != "object"] | any) then "BADJSON"
      else
        [ (if has($n) then empty else "MISSING" end),
          (if has($n) and ((.[$n].installLocation | type) != "string" or .[$n].installLocation == "")
             then "STALE" else empty end),
          (if [.[] | (.lastUpdated | type) != "string"] | any then "NO_TIMESTAMP" else empty end)
        ] | join(" ")
      end' <<< "$KM_PARSED" 2>/dev/null); then
    STATES="BADJSON"
    KM_PARSED=""
    return 0
  fi
  if [[ "$verdict" == "BADJSON" ]]; then
    STATES="BADJSON"
    KM_PARSED=""
    return 0
  fi
  STATES="$verdict"
  if ! has_state MISSING && ! has_state STALE; then
    local il
    il=$(jq -r --arg n "$MARKETPLACE_NAME" '.[$n].installLocation' <<< "$KM_PARSED" 2>/dev/null)
    if [[ ! -d "$il" ]]; then
      # Keep canonical order: STALE precedes NO_TIMESTAMP.
      if has_state NO_TIMESTAMP; then STATES="STALE NO_TIMESTAMP"; else STATES="STALE"; fi
    fi
  fi
  return 0
}

log_event() {  # outcome detail
  [[ -n "$LOG_FILE" ]] || return 0
  mkdir -p "$CACHE_DIR" 2>/dev/null || return 0
  local size
  size=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
  if (( size > LOG_MAX_BYTES )); then
    mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null
  fi
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CFG" "$1" "$2" >> "$LOG_FILE" 2>/dev/null
  return 0
}

# say OUTCOME MESSAGE — stderr per the caller's surface contract (see header).
say() {
  local outcome=$1 msg=$2
  if [[ "$SURFACE" != "prelaunch" ]]; then
    printf '%s\n' "$msg" >&2
    return 0
  fi
  local cfg_key sig
  cfg_key=$(digest16 "$CFG")
  sig=$(digest16 "$outcome")
  if [[ -z "$MARK_ROOT" || -z "$cfg_key" || -z "$sig" ]]; then
    printf '⚠ %s\n' "$msg" >&2
    return 0
  fi
  # mkdir is the whole test-and-set: exactly one of N racing launches prints.
  if mkdir -p "$MARK_ROOT" 2>/dev/null && mkdir "$MARK_ROOT/$cfg_key.$sig" 2>/dev/null; then
    printf '⚠ %s (log: %s)\n' "$msg" "$LOG_FILE" >&2
  fi
  return 0
}

clear_marks() {
  [[ -n "$MARK_ROOT" && -d "$MARK_ROOT" ]] || return 0
  local cfg_key
  cfg_key=$(digest16 "$CFG")
  [[ -n "$cfg_key" ]] || return 0
  rm -rf "$MARK_ROOT/$cfg_key".* 2>/dev/null
  return 0
}

reject() {
  log_event REJECT "$1"
  say "reject:$1" "dhx-plugin-registry-heal: REJECT: $1"
  exit 1
}

LOCK_INODE=""
release_lock() {
  [[ -n "$LOCK_INODE" ]] || return 0
  if [[ "$(stat -c %i "$LOCK_DIR" 2>/dev/null)" == "$LOCK_INODE" ]]; then
    rmdir "$LOCK_DIR" 2>/dev/null
  fi
  LOCK_INODE=""
  return 0
}

acquire_lock() {
  local i now mtime away
  for i in 1 2 3 4 5; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      LOCK_INODE=$(stat -c %i "$LOCK_DIR" 2>/dev/null)
      return 0
    fi
    now=$(date +%s)
    if ! mtime=$(stat -c %Y "$LOCK_DIR" 2>/dev/null); then
      continue  # released between mkdir and stat — retry at once
    fi
    if (( now - mtime > LOCK_STALE_S )); then
      away="$LOCK_DIR.dhx-stale.$$.$i"
      if mv "$LOCK_DIR" "$away" 2>/dev/null; then
        # A holder may have re-acquired between the stat and the rename; if what moved is
        # fresh, put it back and treat the lock as held.
        if (( $(date +%s) - $(stat -c %Y "$away" 2>/dev/null || echo 0) > LOCK_STALE_S )); then
          rm -rf "$away" 2>/dev/null
          continue
        fi
        mv "$away" "$LOCK_DIR" 2>/dev/null || rm -rf "$away" 2>/dev/null
      fi
    fi
    sleep 0.2
  done
  return 1
}

NEW_IL=""
# prepare_dhx_value — derive and guard the dhx-local installLocation (Pattern B) when a state
# requires writing it. Refuses (exit 1) on any guard failure.
prepare_dhx_value() {
  has_state UNREADABLE || has_state BADJSON || has_state MISSING || has_state STALE || return 0
  [[ -n "$NEW_IL" ]] && return 0
  NEW_IL=$(jq -r '.path // empty' <<< "$DHX_SOURCE_JSON" 2>/dev/null)
  [[ -n "$NEW_IL" ]] || reject "settings.extraKnownMarketplaces.$MARKETPLACE_NAME.source.path empty or null"
  # G-02: absolute before realpath -m (a relative path would resolve against an arbitrary cwd).
  [[ "$NEW_IL" = /* ]] || reject "NEW_IL not absolute: $NEW_IL"
  # (b) identity: an existing directory whose manifest names this marketplace. Input hygiene,
  # not a security boundary — settings.json and km share an owner.
  local new_il_real manifest manifest_name
  new_il_real=$(realpath -m "$NEW_IL" 2>/dev/null || echo "$NEW_IL")
  manifest="$new_il_real/.claude-plugin/marketplace.json"
  [[ -d "$new_il_real" ]] || reject "installLocation is not a directory ($new_il_real)"
  [[ -r "$manifest" ]] || reject "no marketplace manifest at $manifest"
  manifest_name=$(jq -r '.name // empty' "$manifest" 2>/dev/null)
  [[ -n "$manifest_name" ]] || reject "marketplace manifest unparseable or unnamed ($manifest)"
  [[ "$manifest_name" == "$MARKETPLACE_NAME" ]] \
    || reject "marketplace manifest names '$manifest_name', expected '$MARKETPLACE_NAME' ($new_il_real)"
  return 0
}

# ---- detect (lock-free; the healthy path ends here) ----------------------------------------
detect
if [[ -z "$STATES" ]]; then
  clear_marks
  exit 0
fi

# ---- mutation path ------------------------------------------------------------------------
# (a) D-02 file-target check: km must resolve to $CFG/plugins/known_marketplaces.json literally
# (no symlink chain crossing into another tree).
KM_REAL=$(realpath -m "$KM_PATH" 2>/dev/null || echo "$KM_PATH")
CFG_REAL=$(realpath -m "$CFG" 2>/dev/null || echo "$CFG")
[[ "$KM_REAL" == "$CFG_REAL/plugins/known_marketplaces.json" ]] \
  || reject "target km path resolves outside CONFIG_DIR ($KM_REAL)"
prepare_dhx_value

mkdir -p "$(dirname "$KM_PATH")" 2>/dev/null
trap release_lock EXIT
if ! acquire_lock; then
  log_event CONTENTION "states=$STATES lock=$LOCK_DIR"
  exit 0
fi

# Another writer may have changed the file while we waited: decide again under the lock.
detect
if [[ -z "$STATES" ]]; then
  release_lock
  clear_marks
  exit 0
fi
prepare_dhx_value

NOW=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
ADD=false
FIXIL=false
BASE="$KM_PARSED"
if has_state UNREADABLE || has_state BADJSON; then
  BASE='{}'
  ADD=true
elif has_state MISSING; then
  ADD=true
elif has_state STALE; then
  FIXIL=true
fi

TMP=$(mktemp "$KM_PATH.tmp.XXXXXX") || reject "mktemp failed for $KM_PATH"
if ! jq -c --arg n "$MARKETPLACE_NAME" --arg il "$NEW_IL" --arg now "$NOW" \
      --argjson src "$DHX_SOURCE_JSON" --argjson add "$ADD" --argjson fixil "$FIXIL" '
      (if $add then . + {($n): {source: $src, installLocation: $il, lastUpdated: $now}} else . end)
      | (if $fixil then .[$n].installLocation = $il else . end)
      | with_entries(if (.value.lastUpdated | type) == "string" then . else .value.lastUpdated = $now end)
    ' <<< "$BASE" > "$TMP" 2>/dev/null; then
  rm -f "$TMP"
  log_event WRITE_FAILED "jq transform failed; states=$STATES"
  say "write-failed:$STATES" "dhx-plugin-registry-heal: jq write failed for $KM_PATH (states=$STATES)"
  exit 1
fi
chmod --reference="$KM_PATH" "$TMP" 2>/dev/null || chmod 0644 "$TMP" 2>/dev/null

# WR-04 TOCTOU narrowing: re-canonicalize the parent immediately before mv and re-assert (a).
KM_PARENT_REAL=$(realpath -m "$(dirname "$KM_PATH")" 2>/dev/null || echo "")
EXPECTED_PARENT_REAL=$(realpath -m "$CFG/plugins" 2>/dev/null || echo "")
if [[ -z "$KM_PARENT_REAL" || "$KM_PARENT_REAL" != "$EXPECTED_PARENT_REAL" ]]; then
  rm -f "$TMP"
  reject "parent dir prefix changed pre-mv (TOCTOU; $KM_PARENT_REAL != $EXPECTED_PARENT_REAL)"
fi

# Capture mv's rc directly — inside `if ! mv …; then` $? is the negation's, not mv's (WR-01).
mv "$TMP" "$KM_PATH"
mv_rc=$?
if (( mv_rc != 0 )); then
  rm -f "$TMP"
  reject "mv failed for $KM_PATH (rc=$mv_rc)"
fi

# Post-write check (D-10, extended 2026-09-15): the file CC reads must pass CC's own schema
# shape, not merely parse. On failure remove it — an absent km is the state CC rebuilds.
if ! jq -e 'type == "object" and ([.[] | type == "object" and ((.lastUpdated | type) == "string")] | all)' \
     "$KM_PATH" >/dev/null 2>&1; then
  rm -f "$KM_PATH"
  log_event POST_WRITE_INVALID "states=$STATES"
  say "post-write-invalid:$STATES" "dhx-plugin-registry-heal: POST-WRITE-CORRUPT: $KM_PATH"
  exit 1
fi

log_event REPAIRED "states=$STATES"
if has_state BADJSON; then
  say "repaired:$STATES" "dhx-plugin-registry-heal: WARN: BADJSON recovery — wrote minimal km (dhx-local only); other marketplaces lost; Claude Code rebuilds those declared in settings on a later launch."
elif [[ "$SURFACE" == "prelaunch" ]]; then
  say "repaired:$STATES" "dhx-plugin-registry-heal: repaired known_marketplaces.json ($STATES) in $CFG"
fi
exit 0
