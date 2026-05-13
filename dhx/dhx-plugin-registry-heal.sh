#!/usr/bin/env bash
# Patterns: HP-017, HP-025
# dhx-plugin-registry-heal.sh — SessionStart heal hook (Phase 6 surgical-slim retired)
#
# Phase 6 (2026-05-03) verify-then-retire pre-retire probes (`tests/probes/.results/
# v1.2-phase-6/`) established that CC's Hn() resolver rehydrates `installed_plugins.json`
# natively in default `claude -p` mode across all three failure branches the previous
# heal logic targeted (UNREADABLE per PROBE-02; BADJSON + UNINSTALLED:dhx@dhx-local per
# 06-01 mini-probes; all three returned `supersession_found_drop_heal` with HIGH
# confidence at CC 2.1.121).
#
# Surgical-slim retire (D-25): the IP-heal body is short-circuited via early-exit;
# script + ~/.claude/hooks/ symlink + plugin-manifest dispatch line are retained
# intentionally (D-27) as a known mount-point for the HEAL-07 follow-on (km path
# hardening — known_marketplaces.json does NOT self-heal; per 06-01 km probe
# `v1_2_work_warranted` REFUTE outcome). Retaining the plumbing avoids the
# re-introduction cost when km hardening lands.
#
# Scope (post-Phase-10 km active heal):
#   - installed_plugins.json — DO NOT heal (Hn() rehydrates upstream; 06-01 PASS)
#   - known_marketplaces.json — ACTIVE HEAL: 4-state detector + (a)+(b) realpath
#     allow-list + atomic mktemp+jq+mv + post-write jq -e validation (D-02/D-10).
#     BADJSON branch writes minimal km + emits WARN per D-14 (other marketplaces
#     lost; CC rebuilds on next plugin operation).
#
# Out of scope (handled elsewhere):
#   - MISSING:dhx-local in settings → bashrc wrapper heal (HP-017)
#   - PATH / DISABLED → structural / settings-level
#   - Cache hooks.json staleness → Phase 10.1 dot-phase (see backlog brief)
#
# Silent on happy path. No stdin parsing (filesystem state, not session context).
# Phase 6 (2026-05-03) retired IP path; Phase 10 added km active heal — see docs/decisions.md 2026-05-03 (D-25/D-27/D-29) and HP-025 v1.3 § Remediation hook.
set -uo pipefail

# ============================================================================
# Phase 10 km active heal body
# ============================================================================
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CFG/settings.json"
KM_PATH="$CFG/plugins/known_marketplaces.json"

# D-11 settings-missing branch: if settings absent or dhx-local not declared,
# heal exits 0 silently. HP-025 scope boundary — bashrc-wrapper territory.
# G-07: this is the settings-missing branch (NOT direct hostile rejection; the
# real hostile rejection lives in scenario 11 of the probe via the (a) realpath
# check below).
if [[ ! -r "$SETTINGS" ]]; then
  exit 0
fi

DHX_SOURCE_JSON=$(jq -c '.extraKnownMarketplaces["dhx-local"].source // empty' "$SETTINGS" 2>/dev/null)
if [[ -z "$DHX_SOURCE_JSON" || "$DHX_SOURCE_JSON" == "null" ]]; then
  exit 0
fi

# Compute NEW_IL per Pattern from 10-D-05-RESULT.md (CC 2.1.140: Pattern B —
# installLocation == source.path literally; D-03 allow-list still bounds the
# value-side check below to marketplace-root prefixes).
NEW_IL=$(jq -r '.path // empty' <<< "$DHX_SOURCE_JSON" 2>/dev/null)
if [[ -z "$NEW_IL" ]]; then
  echo "dhx-plugin-registry-heal: REJECT: settings.extraKnownMarketplaces.dhx-local.source.path empty or null" >&2
  exit 1
fi

# G-02 absolute-path guard: NEW_IL MUST be absolute before realpath -m.
# Closes Gemini MEDIUM (relative-path resolved against arbitrary CWD).
[[ "$NEW_IL" = /* ]] || { echo "dhx-plugin-registry-heal: REJECT: NEW_IL not absolute: $NEW_IL" >&2; exit 1; }

# (a) D-02 file-target check: KM_PATH must resolve under $CFG/plugins/
# known_marketplaces.json literal (no symlink-chain crossing into unrelated trees).
KM_REAL=$(realpath -m "$KM_PATH" 2>/dev/null || echo "$KM_PATH")
CFG_REAL=$(realpath -m "$CFG" 2>/dev/null || echo "$CFG")
EXPECTED_KM_REAL="$CFG_REAL/plugins/known_marketplaces.json"
case "$KM_REAL" in
  "$EXPECTED_KM_REAL")
    : ;;
  *)
    echo "dhx-plugin-registry-heal: REJECT: target km path resolves outside CONFIG_DIR ($KM_REAL)" >&2
    exit 1
    ;;
esac

# (b) D-02 value-side check + D-03 allow-list with G-03 nullglob locality.
NEW_IL_REAL=$(realpath -m "$NEW_IL" 2>/dev/null || echo "$NEW_IL")
shopt -q nullglob; prev_nullglob=$?
shopt -s nullglob
matched=0
for root in "$HOME"/.claude/plugins/marketplaces "$HOME"/.ccs/instances/*/plugins/marketplaces; do
  [[ -e "$root" ]] || continue
  root_real=$(realpath -m "$root" 2>/dev/null || echo "$root")
  case "$NEW_IL_REAL" in
    "$root_real"/*)
      matched=1
      break
      ;;
  esac
done
[[ $prev_nullglob -eq 0 ]] || shopt -u nullglob

if (( ! matched )); then
  echo "dhx-plugin-registry-heal: REJECT: installLocation outside allow-list ($NEW_IL_REAL)" >&2
  exit 1
fi

# 4-state detector (D-04): UNREADABLE / BADJSON / MISSING / STALE_INSTALLLOCATION / HEALTHY
STATE=""
KM_PARSED=""
if [[ ! -r "$KM_PATH" ]]; then
  STATE="UNREADABLE"
else
  if ! KM_PARSED=$(jq -c . "$KM_PATH" 2>/dev/null); then
    STATE="BADJSON"
  elif ! jq -e '."dhx-local"' <<< "$KM_PARSED" >/dev/null 2>&1; then
    STATE="MISSING"
  else
    CURRENT_IL=$(jq -r '."dhx-local".installLocation // empty' <<< "$KM_PARSED" 2>/dev/null)
    if [[ -n "$CURRENT_IL" && ! -d "$CURRENT_IL" ]]; then
      STATE="STALE_INSTALLLOCATION"
    else
      STATE="HEALTHY"
    fi
  fi
fi

if [[ "$STATE" == "HEALTHY" ]]; then
  exit 0
fi

DHX_ENTRY=$(jq -nc --argjson src "$DHX_SOURCE_JSON" --arg il "$NEW_IL" \
  '{ source: $src, installLocation: $il }' 2>/dev/null)
if [[ -z "$DHX_ENTRY" ]]; then
  echo "dhx-plugin-registry-heal: REJECT: failed to build dhx-local entry" >&2
  exit 1
fi

# Atomic write via mktemp+jq+mv (D-10 + D-11).
mkdir -p "$(dirname "$KM_PATH")"
TMP=$(mktemp "$KM_PATH.tmp.XXXXXX") || {
  echo "dhx-plugin-registry-heal: REJECT: mktemp failed for $KM_PATH" >&2
  exit 1
}

case "$STATE" in
  UNREADABLE|MISSING)
    if [[ "$STATE" == "UNREADABLE" ]]; then
      BASE='{}'
    else
      BASE="$KM_PARSED"
    fi
    if ! jq -c --argjson e "$DHX_ENTRY" '. + {"dhx-local": $e}' <<< "$BASE" > "$TMP" 2>/dev/null; then
      rm -f "$TMP"
      echo "dhx-plugin-registry-heal: jq write failed for $KM_PATH (state=$STATE)" >&2
      exit 1
    fi
    ;;
  BADJSON)
    # D-14: minimal km with only dhx-local. Other-marketplace entries lost (km
    # was corrupt — cannot preserve). Emit literal WARN signalling loss.
    if ! jq -nc --argjson e "$DHX_ENTRY" '{"dhx-local": $e}' > "$TMP" 2>/dev/null; then
      rm -f "$TMP"
      echo "dhx-plugin-registry-heal: jq write failed for $KM_PATH (state=$STATE)" >&2
      exit 1
    fi
    echo "dhx-plugin-registry-heal: WARN: BADJSON recovery — wrote minimal km (dhx-local only); other marketplaces (if any) lost; CC may rebuild official entries on next plugin operation." >&2
    ;;
  STALE_INSTALLLOCATION)
    # D-04: rewrite ONLY .dhx-local.installLocation; preserve source.source,
    # source.path, all other keys.
    if ! jq -c --arg il "$NEW_IL" '."dhx-local".installLocation = $il' <<< "$KM_PARSED" > "$TMP" 2>/dev/null; then
      rm -f "$TMP"
      echo "dhx-plugin-registry-heal: jq write failed for $KM_PATH (state=$STATE)" >&2
      exit 1
    fi
    ;;
  *)
    rm -f "$TMP"
    echo "dhx-plugin-registry-heal: REJECT: unknown detector state '$STATE'" >&2
    exit 1
    ;;
esac

# WR-04 TOCTOU mitigation: re-canonicalize the parent dir IMMEDIATELY before
# mv and re-assert the (a) prefix match. Narrows (does not fully close) the
# window between the line-76 (a) check and the mv below; full O_NOFOLLOW-style
# protection requires a helper binary (deferred — see HP-025 § Threat Model /
# Residual Risks). On a real TOCTOU race (attacker swaps $CFG/plugins/ between
# line 76 and here), this catches the swap and refuses the write. On the happy
# path it's a no-op (parent dir state unchanged during script runtime).
KM_PARENT_REAL=$(realpath -m "$(dirname "$KM_PATH")" 2>/dev/null || echo "")
EXPECTED_PARENT_REAL=$(realpath -m "$CFG/plugins" 2>/dev/null || echo "")
if [[ -z "$KM_PARENT_REAL" || "$KM_PARENT_REAL" != "$EXPECTED_PARENT_REAL" ]]; then
  rm -f "$TMP"
  echo "dhx-plugin-registry-heal: REJECT: parent dir prefix changed pre-mv (TOCTOU; $KM_PARENT_REAL != $EXPECTED_PARENT_REAL)" >&2
  exit 1
fi

# Atomic mv. Capture rc OUTSIDE `if ! cmd; then` — inside that block $? is 0
# (the negated test succeeded), not the failed cmd's rc. Per WR-01 verification:
# `if ! mv …; then mv_rc=$?; …` always captured 0 regardless of mv's failure
# mode, defeating the diagnostic. Capture mv_rc directly off `mv`'s exit.
mv "$TMP" "$KM_PATH"
mv_rc=$?
if (( mv_rc != 0 )); then
  rm -f "$TMP"
  echo "dhx-plugin-registry-heal: REJECT: mv failed for $KM_PATH (rc=$mv_rc)" >&2
  exit 1
fi

# Post-write validation (D-10) + G-06 cleanup.
if ! jq -e . "$KM_PATH" >/dev/null 2>&1; then
  rm -f "$KM_PATH"
  echo "dhx-plugin-registry-heal: POST-WRITE-CORRUPT: $KM_PATH" >&2
  exit 1
fi

exit 0
