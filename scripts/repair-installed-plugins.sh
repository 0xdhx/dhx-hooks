#!/usr/bin/env bash
# Patterns: HP-017, HP-025
# scripts/repair-installed-plugins.sh — operator-invoked BADJSON/UNINSTALLED repair
# for $CLAUDE_CONFIG_DIR/plugins/installed_plugins.json.
#
# Phase 19 (SYM-REPAIR) D-01/D-02: the mechanism-agnostic recovery path that closes
# the HP-025 alert→command loop. CC's Hn() natural-heal is version-conditional (flipped
# at 2.1.140/2.1.145 — see .planning/backlog/2026-05-{13,19}-* flip-back briefs); this
# helper rebuilds a valid v2 registry on operator invoke regardless of WHY natural-heal
# stopped. /dhx:sym repair (skills repo) dispatches here by absolute path + [ -x ] guard.
#
# Provenance / port source (D-08):
#   The BADJSON/UNINSTALLED v2-seed logic is ported from
#   `git show 170fc61:dhx/dhx-plugin-registry-heal.sh` — the ORIGINAL 142-line heal hook.
#   (NOT working-tree dhx/dhx-plugin-registry-heal.sh:105-164 — that range is now Phase 10
#   km-path logic; the IP-path body was deleted from disk by 896c36e.) The 170fc61 jq -n
#   entry shape is verified field-faithful to the live CC 2.1.148 v2 schema:
#     { "version": 2, "plugins": { "dhx@dhx-local": [ <entry> ] } }
#   where .plugins["dhx@dhx-local"] is an ARRAY of install records.
#
# Decisions implemented:
#   D-02  repair logic lives here (locality: probes that prove it + decisions that record
#         it are hooks artifacts); /dhx:sym repair dispatches by absolute path + [ -x ] guard.
#   D-07  config-dir allow-list hardening — refuse to write outside the resolved
#         $CLAUDE_CONFIG_DIR/plugins path (realpath-pin guard, ported verbatim from the live
#         working km-heal dhx/dhx-plugin-registry-heal.sh:69-103) + cache-root allow-list for
#         the installPath provenance.
#   D-08  per-state preservation. UNINSTALLED: parse the valid JSON, insert the dhx entry,
#         preserve all other plugins. BADJSON: input is invalid-by-definition → back up the
#         corrupt original to .bak FIRST, write a minimal dhx-only v2 seed, emit a single-line
#         WARN that other marketplaces may be lost. No partial-parse salvage of malformed JSON.
#   D-09  jq is a hard dependency — refuse loudly before any mutation if absent.
#   D-16  VALIDATE-BEFORE-SWAP. Build to $TMP, then `jq -e . "$TMP"` MUST pass BEFORE the
#         atomic `mv -f` swap. On validation failure: rm the $TMP sibling, REFUSE, exit 1 —
#         the ORIGINAL registry is never replaced by an invalid write. There is intentionally
#         NO post-swap delete of the resolved target file: the prior plan draft's post-swap
#         delete removed the registry with no backup for UNINSTALLED (which has no .bak).
#         Removed entirely — the original is never replaced by an invalid write, so there is
#         no corrupt result to delete.
#
# D-22a KNOWN ASSUMPTION (gitCommitSha provenance):
#   gitCommitSha is recorded best-effort as the hooks-repo HEAD sha (faithful to the ported
#   170fc61 `jq -n` idiom). This may DIFFER from the dhx plugin cache's installed-artifact
#   commit. It is a record-keeping value only; CC rebuilds the authoritative metadata on the
#   next plugin operation. Documented here + in 19-01-SUMMARY.md.
#
# G-01 GUARD-TOPOLOGY NOTE (config-dir guard assumes a non-symlinked registry):
#   The realpath-pin guard below was disproved as a concern by targeted verification —
#   installed_plugins.json is a PLAIN FILE on this machine under both $HOME/.claude and
#   $CLAUDE_CONFIG_DIR (no symlink/hardlink), so realpath -m == readlink -f == the lexical
#   path and the guard's EXPECTED_IP_REAL/IP_REAL agree. The guard logic is UNCHANGED (ported
#   verbatim from the live working km-heal). If the registry ever BECAME a symlink, the
#   lexical/realpath mismatch would make the guard REFUSE (exit 1) BEFORE any write —
#   fail-safe direction, never a mis-write.
#
# INVARIANT (atomic write breaks the hardlink — verbatim from the 170fc61 port source):
#   uses `mv -f tmp target` for atomic replacement. This BREAKS the hardlink topology between
#   ~/.claude/plugins/installed_plugins.json and ~/.ccs/shared/plugins/installed_plugins.json
#   (single inode → two inodes after mv). Tradeoff accepted — atomicity avoids partial-write
#   corruption (the O_TRUNC clobber class the helper exists to mitigate); next
#   `claude plugin install` re-establishes topology via in-place openSync("w"). NEVER
#   `cat SRC > DST` onto a registry path (O_TRUNC foot-gun on the aliased inode chain —
#   docs/architecture.md § Plugin registry file chain).
#
# Exit discipline (mirrors install-plugin.sh): 0 = repaired-or-no-op, 1 = refusal/precondition-fail.
# Silent on the happy path beyond a single repaired-state line; WARN/REFUSE go to stderr.
# Probe: tests/probes/probe-repair-installed-plugins.sh (SC2 empirical anchor).
#
# `set -euo pipefail`: per the install-plugin.sh / install-git-hooks.sh precedent. The
# state-detect path relies on `if`/`||` guards around `jq -e` so the expected predicate-false
# exit-1 doesn't terminate the script — bash `-e` ignores non-zero exits inside `if`-conditions.
set -euo pipefail

MARKETPLACE="dhx-local"
PLUGIN_KEY="dhx@dhx-local"
HOOKS_REPO="/home/dhx/repos/hooks"

# --- Pre-flight: jq hard-dependency refusal (D-09) ---
command -v jq >/dev/null 2>&1 || { echo "repair-installed-plugins: jq not on PATH — refusing" >&2; exit 1; }

# --- Resolve config-dir + IP target ---
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
IP_PATH="$CFG/plugins/installed_plugins.json"
CACHE_BASE="$CFG/plugins/cache/$MARKETPLACE/dhx"

# --- Config-dir realpath-pin guard (D-07; retargeted KM→IP from the live km-heal
#     dhx/dhx-plugin-registry-heal.sh:69-81; guard logic UNCHANGED per G-01) ---
# The IP target's real path must equal $CFG_REAL/plugins/installed_plugins.json. A hostile
# CLAUDE_CONFIG_DIR whose plugins subtree symlinks into a victim file resolves elsewhere →
# REFUSE before any write. G-01: on a plain-file topology realpath == lexical; on a symlinked
# topology the mismatch fail-safes to REFUSE (never a mis-write).
IP_REAL=$(realpath -m "$IP_PATH" 2>/dev/null || echo "$IP_PATH")
CFG_REAL=$(realpath -m "$CFG" 2>/dev/null || echo "$CFG")
EXPECTED_IP_REAL="$CFG_REAL/plugins/installed_plugins.json"
case "$IP_REAL" in
  "$EXPECTED_IP_REAL")
    : ;;
  *)
    echo "repair-installed-plugins: REFUSE: target IP resolves outside CONFIG_DIR ($IP_REAL)" >&2
    exit 1
    ;;
esac

# --- Absent-registry guard (WR-01): MISSING is LOCKED out-of-scope (19-CONTEXT <domain>, D-14) ---
# A non-existent installed_plugins.json is the MISSING state — NOT BADJSON/UNINSTALLED. Without this
# guard, self-detect misclassifies an absent file as BADJSON (jq -e . fails on a missing path) and the
# BADJSON branch's `cp "$IP_PATH" …` aborts under set -e with a raw `cp: cannot stat` (no structured
# REFUSE); an explicit UNINSTALLED arg dead-ends the same way at `cat "$IP_PATH"`. Refuse cleanly for
# ALL entry paths here. Seeding a fresh registry on absent is the OUT-OF-SCOPE MISSING repair — the
# 170fc61 port source did seed, but Phase 19 D-14 locks MISSING out (CONTEXT <domain>), so do NOT
# seed; CC rehydrates the registry on the next plugin operation.
if [[ ! -f "$IP_PATH" ]]; then
  echo "repair-installed-plugins: REFUSE: installed_plugins.json absent ($IP_PATH) — MISSING is out of scope (CC rehydrates on the next plugin operation; for broader drift see the manual recovery procedure in docs/troubleshooting.md)." >&2
  exit 1
fi

# --- Cache source-of-truth probe (D-08/T-19-06) ---
# Without the plugin cache directory we cannot synthesize truthful metadata
# (installPath, version). Refuse rather than fabricate — a repair that invents
# paths makes state worse (same defensive posture as the 170fc61 port source).
if [[ ! -d "$CACHE_BASE" ]]; then
  echo "repair-installed-plugins: REFUSE: cache dir absent ($CACHE_BASE) — cannot synthesize truthful metadata" >&2
  exit 1
fi

shopt -s nullglob
_dirs=( "$CACHE_BASE"/*/ )
shopt -u nullglob
if (( ${#_dirs[@]} == 0 )); then
  echo "repair-installed-plugins: REFUSE: no versioned cache dir under $CACHE_BASE — cannot synthesize metadata" >&2
  exit 1
fi

# Highest-version cache dir (normally exactly one exists). Strip trailing slash.
INSTALL_PATH=$(printf '%s\n' "${_dirs[@]%/}" | sort -V | tail -1)

# --- Cache-root allow-list (D-07 installPath provenance; nullglob-locality loop
#     ported from the live km-heal dhx/dhx-plugin-registry-heal.sh:83-103, retargeted
#     marketplaces→cache) ---
# INSTALL_PATH MUST canonicalize under a vetted plugin-cache root. The allow-list mirrors the
# config-dir hardening brief (.planning/backlog/shipped/2026-04-27-heal-hook-config-dir-path-
# dependent-write-hardening.md § Approach sketch).
INSTALL_PATH_REAL=$(realpath -m "$INSTALL_PATH" 2>/dev/null || echo "$INSTALL_PATH")
# Capture prior nullglob state. `shopt -q` returns exit-1 when OFF — guard so
# `set -e` does not terminate here (install-plugin.sh `if`/`||` precedent).
if shopt -q nullglob; then _prev_nullglob=0; else _prev_nullglob=1; fi
shopt -s nullglob
_matched=0
for _root in "$HOME"/.claude/plugins/cache "$HOME"/.ccs/shared/plugins/cache "$HOME"/.ccs/instances/*/plugins/cache; do
  [[ -e "$_root" ]] || continue
  _root_real=$(realpath -m "$_root" 2>/dev/null || echo "$_root")
  case "$INSTALL_PATH_REAL" in
    "$_root_real"/*)
      _matched=1
      break
      ;;
  esac
done
[[ $_prev_nullglob -eq 0 ]] || shopt -u nullglob
if (( ! _matched )); then
  echo "repair-installed-plugins: REFUSE: installPath outside cache allow-list ($INSTALL_PATH_REAL)" >&2
  exit 1
fi

PLUGIN_JSON="$INSTALL_PATH/.claude-plugin/plugin.json"
if [[ ! -f "$PLUGIN_JSON" ]]; then
  echo "repair-installed-plugins: REFUSE: cache plugin.json absent ($PLUGIN_JSON) — cannot read version" >&2
  exit 1
fi
VERSION=$(jq -r '.version // empty' "$PLUGIN_JSON" 2>/dev/null)
if [[ -z "$VERSION" ]]; then
  echo "repair-installed-plugins: REFUSE: cache plugin.json has no version — cannot synthesize entry" >&2
  exit 1
fi

# --- Detect state ---
# Accept an optional state arg validated via a `case` allow-list (V5; T-19-05 — a non-
# BADJSON/UNINSTALLED value must NOT drive an unexpected branch), OR self-detect via the
# HP-025 taxonomy transcribed to bash (statusline-wrapper.js::checkPluginRegistry).
STATE_ARG="${1:-}"
case "$STATE_ARG" in
  BADJSON|UNINSTALLED)
    STATE="$STATE_ARG"
    ;;
  "")
    if ! jq -e . "$IP_PATH" >/dev/null 2>&1; then
      STATE="BADJSON"
    elif ! jq -e '.plugins["dhx@dhx-local"]' "$IP_PATH" >/dev/null 2>&1; then
      STATE="UNINSTALLED"
    else
      STATE="HEALTHY"
    fi
    ;;
  *)
    echo "repair-installed-plugins: REFUSE: unknown state arg '$STATE_ARG' (expected BADJSON|UNINSTALLED or none)" >&2
    exit 1
    ;;
esac

# HEALTHY → idempotent no-op.
if [[ "$STATE" == "HEALTHY" ]]; then
  echo "repair-installed-plugins: HEALTHY — no repair needed (idempotent no-op)"
  exit 0
fi

# --- Build DHX_ENTRY (port the cache-source-of-truth idiom from 170fc61) ---
# gitCommitSha is the hooks-repo HEAD sha — D-22a KNOWN ASSUMPTION (may differ from the cache
# plugin's artifact commit; best-effort, CC rebuilds authoritative metadata on next plugin op).
GIT_SHA=$(git -C "$HOOKS_REPO" rev-parse HEAD 2>/dev/null || echo "")
NOW=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)

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
  echo "repair-installed-plugins: REFUSE: failed to build dhx entry" >&2
  exit 1
fi

# --- Per-state JSON build (D-08) ---
NEW_JSON=""
case "$STATE" in
  UNINSTALLED)
    # Parse the valid JSON, insert dhx as a 1-element array, preserve all other plugins.
    CURRENT_JSON=$(cat "$IP_PATH")
    NEW_JSON=$(printf '%s' "$CURRENT_JSON" | jq \
      --arg k "$PLUGIN_KEY" \
      --argjson entry "$DHX_ENTRY" \
      '.version = 2 | .plugins = ((.plugins // {}) | .[$k] = [$entry])' 2>/dev/null)
    ;;
  BADJSON)
    # Input is invalid-by-definition JSON. Back up the corrupt original to .bak FIRST, then
    # write a minimal dhx-only v2 seed + WARN that other marketplaces may be lost. No partial-
    # parse salvage of malformed JSON (D-08).
    # WR-02: sub-second (%3N) + per-pid ($$) suffix so two BADJSON repairs in the same wall-clock
    # second cannot clobber each other's backup (mirrors the $$-scoped TMP idiom below). The absent-
    # registry guard above guarantees $IP_PATH exists here, so the cp source is always present; the
    # `|| REFUSE` covers permission/IO failure (never a raw `cp: cannot stat` abort under set -e).
    BAK="$IP_PATH.bak.$(date -u +%Y%m%dT%H%M%S.%3NZ).$$"
    cp "$IP_PATH" "$BAK" \
      || { echo "repair-installed-plugins: REFUSE: failed to back up corrupt original to $BAK" >&2; exit 1; }
    NEW_JSON=$(jq -n \
      --arg k "$PLUGIN_KEY" \
      --argjson entry "$DHX_ENTRY" \
      '{version:2, plugins:{($k):[$entry]}}' 2>/dev/null)
    echo "repair-installed-plugins: WARN: BADJSON recovery — wrote minimal dhx-only seed; other plugins (if any) lost; CC rebuilds official entries on next plugin operation." >&2
    ;;
esac

if [[ -z "$NEW_JSON" ]]; then
  echo "repair-installed-plugins: REFUSE: failed to build new registry JSON (state=$STATE)" >&2
  exit 1
fi

# --- Atomic write with VALIDATE-BEFORE-SWAP (D-09 + D-16) ---
# Port the tail from 170fc61: mkdir parent, readlink -f the real target (keeps the symlink
# chain intact on a symlinked CCS-instance view), per-pid tmp-sibling, write, THEN validate
# the tmp file BEFORE the swap. On validation failure: rm the tmp + REFUSE + exit 1 — the
# ORIGINAL registry is never replaced by an invalid write (D-16). There is NO post-swap
# delete of the resolved target (the prior data-loss-with-no-backup path is removed).
PLUGINS_DIR=$(dirname "$IP_PATH")
mkdir -p "$PLUGINS_DIR"

if [[ -e "$IP_PATH" ]]; then
  TARGET_REAL=$(readlink -f "$IP_PATH" 2>/dev/null || printf '%s' "$IP_PATH")
else
  TARGET_REAL="$IP_PATH"
fi

TMP="$TARGET_REAL.tmp.$$"
printf '%s\n' "$NEW_JSON" > "$TMP" || { rm -f "$TMP"; echo "repair-installed-plugins: REFUSE: failed to write tmp file" >&2; exit 1; }

# D-16: validate the built JSON in the tmp file BEFORE the atomic swap.
jq -e . "$TMP" >/dev/null 2>&1 || { rm -f "$TMP"; echo "repair-installed-plugins: REFUSE: built JSON failed validation" >&2; exit 1; }

# Only after validation passes: atomic replace.
mv -f "$TMP" "$TARGET_REAL"

echo "repair-installed-plugins: repaired $STATE — wrote valid v2 registry to $IP_PATH"
exit 0
