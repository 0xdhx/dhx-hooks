#!/bin/bash
# Probes the plugin-keys resolution in dhx-health-check.sh. Exercises:
#   A. Direct jq-check fallback (sym-health.json absent, stale, malformed, or
#      plugin_keys field empty) against fixture settings.json shapes.
#   B. sym-health.json fast-path precedence when fresh (<1h) — including the
#      case where sym claims "ok" but the live settings.json is corrupted
#      (fast-path wins within the 1h window; SessionStart on the next session
#      will re-derive once the cache ages out).
#   C. Staleness cutoff: a >1h checked_at must not be trusted.
# Does not mutate live ~/.cache/dhx/sym-health.json — all fixture I/O happens
# inside an isolated HOME-like tmpdir and a disposable settings.json path.
set -u

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

CHECK='.enabledPlugins["dhx@dhx-local"] == true and (.extraKnownMarketplaces["dhx-local"].source.path // empty) != ""'

# ---- A. Direct jq-check fixtures (no sym-health present) ----
declare -a JQ_FIXTURES=(
  "healthy|ok|{\"enabledPlugins\":{\"dhx@dhx-local\":true,\"other\":true},\"extraKnownMarketplaces\":{\"dhx-local\":{\"source\":{\"source\":\"directory\",\"path\":\"/home/dhx/repos/hooks/dhx-plugin\"}}}}"
  "enabledPlugins-absent|MISSING|{\"enabledPlugins\":{\"other\":true},\"extraKnownMarketplaces\":{\"dhx-local\":{\"source\":{\"source\":\"directory\",\"path\":\"/home/dhx/repos/hooks/dhx-plugin\"}}}}"
  "enabledPlugins-false|MISSING|{\"enabledPlugins\":{\"dhx@dhx-local\":false},\"extraKnownMarketplaces\":{\"dhx-local\":{\"source\":{\"source\":\"directory\",\"path\":\"/home/dhx/repos/hooks/dhx-plugin\"}}}}"
  "marketplace-absent|MISSING|{\"enabledPlugins\":{\"dhx@dhx-local\":true},\"extraKnownMarketplaces\":{}}"
  "marketplace-empty-path|MISSING|{\"enabledPlugins\":{\"dhx@dhx-local\":true},\"extraKnownMarketplaces\":{\"dhx-local\":{\"source\":{\"source\":\"directory\",\"path\":\"\"}}}}"
  "both-keys-missing|MISSING|{\"permissions\":{}}"
  "malformed-json|MISSING|not json {{{"
)

PASS=0
FAIL=0

echo "=== A. Direct jq-check (no sym-health cache) ==="
for f in "${JQ_FIXTURES[@]}"; do
  name=${f%%|*}; rest=${f#*|}
  expected=${rest%%|*}; body=${rest#*|}
  path="$TMPDIR/$name.json"
  printf '%s' "$body" > "$path"

  if jq -e "$CHECK" "$path" >/dev/null 2>&1; then
    got="ok"
  else
    got="MISSING"
  fi

  if [[ "$got" == "$expected" ]]; then
    printf '  \u2713 %s (%s)\n' "$name" "$got"
    PASS=$((PASS + 1))
  else
    printf '  \u2717 %s: expected %s, got %s\n' "$name" "$expected" "$got"
    FAIL=$((FAIL + 1))
  fi
done

# Live shared sanity
LIVE=$(readlink -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" 2>/dev/null)
if [[ -f "$LIVE" ]]; then
  if jq -e "$CHECK" "$LIVE" >/dev/null 2>&1; then got="ok"; else got="MISSING"; fi
  if [[ "$got" == "ok" ]]; then
    printf '  \u2713 live shared (%s)\n' "$got"
    PASS=$((PASS + 1))
  else
    printf '  \u2717 live shared: expected ok, got %s\n' "$got"
    FAIL=$((FAIL + 1))
  fi
fi

# ---- B. sym-health.json precedence (fresh) + C. Staleness cutoff ----
# Invoke dhx-health-check.sh end-to-end with a fake HOME so we control both the
# sym-health.json fixture and the output cache path. CLAUDE_CONFIG_DIR points at
# a tmp dir containing a settings.json fixture. Behavior verified by reading
# the resulting health.json.
echo ""
echo "=== B/C. dhx-health-check.sh end-to-end under fake HOME ==="

run_script_case() {
  local name=$1
  local sym_json=$2        # content for sym-health.json; pass "NONE" to skip
  local settings_json=$3   # content for the resolved settings.json
  local expected=$4

  local home="$TMPDIR/home-$name"
  local cache="$home/.cache/dhx"
  local cfg="$home/.claude"
  mkdir -p "$cache" "$cfg"

  # Real settings file + symlink chain — matches canonical layout enough that
  # `readlink -f "$cfg/settings.json"` resolves to it.
  printf '%s' "$settings_json" > "$cfg/settings-real.json"
  ln -sf "$cfg/settings-real.json" "$cfg/settings.json"

  if [[ "$sym_json" != "NONE" ]]; then
    printf '%s' "$sym_json" > "$cache/sym-health.json"
  fi

  HOME="$home" CLAUDE_CONFIG_DIR="$cfg" \
    bash /home/dhx/repos/hooks/dhx/dhx-health-check.sh <<< '{"session_id":"probe"}' >/dev/null 2>&1

  local got
  got=$(jq -r '.plugin_keys // "ERR"' "$cache/health.json" 2>/dev/null || echo "ERR")

  if [[ "$got" == "$expected" ]]; then
    printf '  \u2713 %s → plugin_keys=%s\n' "$name" "$got"
    PASS=$((PASS + 1))
  else
    printf '  \u2717 %s: expected %s, got %s\n' "$name" "$expected" "$got"
    FAIL=$((FAIL + 1))
  fi
}

GOOD_SETTINGS='{"enabledPlugins":{"dhx@dhx-local":true},"extraKnownMarketplaces":{"dhx-local":{"source":{"source":"directory","path":"/p"}}}}'
BAD_SETTINGS='{"enabledPlugins":{}}'

# B1: fresh sym=ok + good settings → ok (consistent; publishers agree)
now_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
run_script_case "fresh-sym-ok-good-settings" \
  "{\"plugin_keys\":\"ok\",\"checked_at\":\"$now_utc\"}" \
  "$GOOD_SETTINGS" "ok"

# B2: fresh sym=MISSING overrides good settings (publisher says broken; trust it
# — /dhx:sym knows something about repair state settings alone can't express)
run_script_case "fresh-sym-MISSING-wins-over-good-settings" \
  "{\"plugin_keys\":\"MISSING\",\"checked_at\":\"$now_utc\"}" \
  "$GOOD_SETTINGS" "MISSING"

# B3: fresh sym=ok overrides bad settings (publisher just repaired — fast path
# means the statusline clears within 60s without SessionStart)
run_script_case "fresh-sym-ok-wins-over-bad-settings" \
  "{\"plugin_keys\":\"ok\",\"checked_at\":\"$now_utc\"}" \
  "$BAD_SETTINGS" "ok"

# B4: malformed sym cache → fall through to direct jq check against settings
run_script_case "malformed-sym-falls-through" \
  "not json {{{" \
  "$GOOD_SETTINGS" "ok"

# B5: sym with empty plugin_keys field → fall through (cache without the
# field we need — treat as no signal)
run_script_case "sym-empty-plugin_keys-falls-through" \
  "{\"plugin_keys\":\"\",\"checked_at\":\"$now_utc\"}" \
  "$BAD_SETTINGS" "MISSING"

# C1: sym stale (2h old) → ignored, fall through to direct check
stale_utc=$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)
run_script_case "stale-sym-2h-ignored" \
  "{\"plugin_keys\":\"ok\",\"checked_at\":\"$stale_utc\"}" \
  "$BAD_SETTINGS" "MISSING"

# C2: sym future-dated (clock skew) → age_sec < 0, skip → fall through
future_utc=$(date -u -d '1 hour' +%Y-%m-%dT%H:%M:%SZ)
run_script_case "future-dated-sym-ignored" \
  "{\"plugin_keys\":\"ok\",\"checked_at\":\"$future_utc\"}" \
  "$BAD_SETTINGS" "MISSING"

# C3: sym missing checked_at → age unresolvable, skip → fall through
run_script_case "sym-missing-checked_at-falls-through" \
  "{\"plugin_keys\":\"ok\"}" \
  "$BAD_SETTINGS" "MISSING"

echo "---"
echo "PASS: $PASS  FAIL: $FAIL"
exit $FAIL
