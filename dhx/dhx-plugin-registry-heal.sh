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
#   - known_marketplaces.json — ACTIVE HEAL: 4-state detector + write-path guards
#     ((a) km-target realpath check + (b) marketplace-manifest identity check) +
#     atomic mktemp+jq+mv + post-write jq -e validation (D-02/D-10).
#     BADJSON branch writes minimal km + emits WARN per D-14 (other marketplaces
#     lost; CC rebuilds on next plugin operation).
#
# Ordering (2026-09-14, healthy-first): the detector runs FIRST and a HEALTHY km
# exits 0 before any settings-derived value is validated. The write-path guards
# run only on the mutation path, immediately before the atomic write. Rationale:
# stderr at exit 0 from a SessionStart hook is not injected into context (measured
# 2026-09-14: this fix's own session started on the old body, the REJECT went to
# stderr, and the context carried only stdout; HP-038 is the PostToolUse twin of
# the same fact) and the dispatcher masks rc, so a guard REJECT on a healthy host
# is consumed by nobody — it is a failure mode, not a self-test. The previous
# order (guard-first) exited 1 on every SessionStart from 2026-05-13 to
# 2026-09-14 on this host because the D-03 prefix allow-list
# (`$HOME/.claude/plugins/marketplaces`, `$HOME/.ccs/instances/*/plugins/marketplaces`)
# can never match a directory-source marketplace — CC writes
# `installLocation == source.path` literally (Pattern B, 10-D-05-RESULT.md), and
# the live source.path is the repo checkout, not a marketplaces/ root. The 2026-05-12
# D-05 branch-lock ("allow-list expands under Pattern B") was recorded and never
# implemented. Guard coverage now lives in the probe (STALE heal, wrong-identity,
# malformed-manifest scenarios), not in a per-fire REJECT.
#
# (b) identity guard (2026-09-14, replaces the D-03 prefix allow-list): the value
# about to be written must be an existing directory whose
# `.claude-plugin/marketplace.json` parses and names this marketplace — the field
# `claude plugin marketplace add` itself registers the marketplace under. Refuses a
# nonexistent or mistyped path and a malformed manifest. Input hygiene, not a
# security boundary: settings.json and km share an owner, so a same-owner poison
# that also plants a matching manifest passes.
#
# Out of scope (handled elsewhere):
#   - MISSING:dhx-local in settings → bashrc wrapper heal (HP-017)
#   - PATH / DISABLED → structural / settings-level
#   - Cache hooks.json staleness → Phase 10.1 dot-phase (see backlog brief)
#
# Silent on happy path. No stdin parsing (filesystem state, not session context).
# Phase 6 (2026-05-03) retired IP path; Phase 10 added km active heal — see docs/decisions.md 2026-05-03 (D-25/D-27/D-29) and HP-025 v1.3 § Remediation hook.
# 2026-09-14 healthy-first reorder + identity guard — see docs/decisions.md 2026-09-14 row.
set -uo pipefail

# ============================================================================
# Phase 10 km active heal body
# ============================================================================
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CFG/settings.json"
KM_PATH="$CFG/plugins/known_marketplaces.json"
MARKETPLACE_NAME="dhx-local"

# D-11 settings-missing branch: if settings absent or dhx-local not declared,
# heal exits 0 silently. HP-025 scope boundary — bashrc-wrapper territory.
# G-07: this is the settings-missing branch (NOT direct hostile rejection; the
# real hostile rejection lives in scenario 11 of the probe via the (a) realpath
# check below).
if [[ ! -r "$SETTINGS" ]]; then
  exit 0
fi

DHX_SOURCE_JSON=$(jq -c --arg n "$MARKETPLACE_NAME" '.extraKnownMarketplaces[$n].source // empty' "$SETTINGS" 2>/dev/null)
if [[ -z "$DHX_SOURCE_JSON" || "$DHX_SOURCE_JSON" == "null" ]]; then
  exit 0
fi

# Detector (D-04): 4 failure states (UNREADABLE, BADJSON, MISSING, STALE_INSTALLLOCATION) + HEALTHY (no-op)
STATE=""
KM_PARSED=""
if [[ ! -r "$KM_PATH" ]]; then
  STATE="UNREADABLE"
else
  if ! KM_PARSED=$(jq -c . "$KM_PATH" 2>/dev/null); then
    STATE="BADJSON"
  elif ! jq -e --arg n "$MARKETPLACE_NAME" '.[$n]' <<< "$KM_PARSED" >/dev/null 2>&1; then
    STATE="MISSING"
  else
    CURRENT_IL=$(jq -r --arg n "$MARKETPLACE_NAME" '.[$n].installLocation // empty' <<< "$KM_PARSED" 2>/dev/null)
    if [[ -n "$CURRENT_IL" && ! -d "$CURRENT_IL" ]]; then
      STATE="STALE_INSTALLLOCATION"
    else
      STATE="HEALTHY"
    fi
  fi
fi

# Healthy-first (2026-09-14): nothing to write, nothing to validate.
if [[ "$STATE" == "HEALTHY" ]]; then
  exit 0
fi

# ============================================================================
# Mutation path — every guard below runs only when a write is about to happen.
# ============================================================================

# Compute NEW_IL per Pattern B from 10-D-05-RESULT.md (CC 2.1.140+: installLocation
# == source.path literally for directory-source marketplaces).
NEW_IL=$(jq -r '.path // empty' <<< "$DHX_SOURCE_JSON" 2>/dev/null)
if [[ -z "$NEW_IL" ]]; then
  echo "dhx-plugin-registry-heal: REJECT: settings.extraKnownMarketplaces.$MARKETPLACE_NAME.source.path empty or null" >&2
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

# (b) D-02 value-side check — marketplace-manifest identity (2026-09-14; replaces
# the D-03 prefix allow-list, see header). The directory must exist and its
# manifest must name this marketplace.
NEW_IL_REAL=$(realpath -m "$NEW_IL" 2>/dev/null || echo "$NEW_IL")
MANIFEST="$NEW_IL_REAL/.claude-plugin/marketplace.json"
if [[ ! -d "$NEW_IL_REAL" ]]; then
  echo "dhx-plugin-registry-heal: REJECT: installLocation is not a directory ($NEW_IL_REAL)" >&2
  exit 1
fi
if [[ ! -r "$MANIFEST" ]]; then
  echo "dhx-plugin-registry-heal: REJECT: no marketplace manifest at $MANIFEST" >&2
  exit 1
fi
MANIFEST_NAME=$(jq -r '.name // empty' "$MANIFEST" 2>/dev/null)
if [[ -z "$MANIFEST_NAME" ]]; then
  echo "dhx-plugin-registry-heal: REJECT: marketplace manifest unparseable or unnamed ($MANIFEST)" >&2
  exit 1
fi
if [[ "$MANIFEST_NAME" != "$MARKETPLACE_NAME" ]]; then
  echo "dhx-plugin-registry-heal: REJECT: marketplace manifest names '$MANIFEST_NAME', expected '$MARKETPLACE_NAME' ($NEW_IL_REAL)" >&2
  exit 1
fi

DHX_ENTRY=$(jq -nc --argjson src "$DHX_SOURCE_JSON" --arg il "$NEW_IL" \
  '{ source: $src, installLocation: $il }' 2>/dev/null)
if [[ -z "$DHX_ENTRY" ]]; then
  echo "dhx-plugin-registry-heal: REJECT: failed to build $MARKETPLACE_NAME entry" >&2
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
    if ! jq -c --arg n "$MARKETPLACE_NAME" --argjson e "$DHX_ENTRY" '. + {($n): $e}' <<< "$BASE" > "$TMP" 2>/dev/null; then
      rm -f "$TMP"
      echo "dhx-plugin-registry-heal: jq write failed for $KM_PATH (state=$STATE)" >&2
      exit 1
    fi
    ;;
  BADJSON)
    # D-14: minimal km with only dhx-local. Other-marketplace entries lost (km
    # was corrupt — cannot preserve). Emit literal WARN signalling loss.
    if ! jq -nc --arg n "$MARKETPLACE_NAME" --argjson e "$DHX_ENTRY" '{($n): $e}' > "$TMP" 2>/dev/null; then
      rm -f "$TMP"
      echo "dhx-plugin-registry-heal: jq write failed for $KM_PATH (state=$STATE)" >&2
      exit 1
    fi
    echo "dhx-plugin-registry-heal: WARN: BADJSON recovery — wrote minimal km (dhx-local only); other marketplaces (if any) lost; CC may rebuild official entries on next plugin operation." >&2
    ;;
  STALE_INSTALLLOCATION)
    # D-04: rewrite ONLY .dhx-local.installLocation; preserve source.source,
    # source.path, all other keys.
    if ! jq -c --arg n "$MARKETPLACE_NAME" --arg il "$NEW_IL" '.[$n].installLocation = $il' <<< "$KM_PARSED" > "$TMP" 2>/dev/null; then
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
# window between the (a) check above and the mv below; full O_NOFOLLOW-style
# protection requires a helper binary (deferred — see HP-025 § Threat Model /
# Residual Risks). On a real TOCTOU race (attacker swaps $CFG/plugins/ between
# the (a) check and here), this catches the swap and refuses the write. On the
# happy path it's a no-op (parent dir state unchanged during script runtime).
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
