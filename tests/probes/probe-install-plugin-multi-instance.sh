#!/bin/bash
# Probe: scripts/install-plugin.sh writes to ALL primary CCS instances
# (a/b/c) AND skips `.ccburn*` profiles AND updates BOTH per-instance
# `settings.json` (canonical JQ_PRED) AND `plugins/known_marketplaces.json`
# (`dhx-local` key) per the D-22 two-file detection cascade.
#
# Tests:
#   1  install-plugin.sh exits 0 against fake topology with 3 primary
#      instances (a/b/c) AND a `.ccburn*` instance.
#   2  All 3 primary instances have `dhx-local` key in plugins/known_marketplaces.json
#      (kmf side of D-22).
#   3  All 3 primary instances satisfy the canonical JQ_PRED in settings.json
#      (sf side of D-22).
#   4  `.ccburn*` instance is SKIPPED — neither file is touched (D-25 SCRIPT-02
#      amendment).
#
# `.ccburn*` instances are CCS-burn transient testing profiles, deliberately
# excluded per D-25. SCRIPT-02 'every CCS instance' is interpreted as 'every
# primary CCS instance (a/b/c)'.
#
# Backs: Phase 4 Plan 01 (install-plugin.sh shape), CONTEXT.md decisions D-05,
#   D-13, D-14, D-22, D-25.
# Run: bash tests/probes/probe-install-plugin-multi-instance.sh
# SAFE_FOR_LIVE: no   (mktemp + fake HOME confines writes; invokes install-plugin.sh subprocess against fake CCS topology and a fake `claude` CLI shim under fake PATH)
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

pass=0
fail=0

assert() {
  local name="$1" cond="$2"
  if eval "$cond"; then
    echo "OK   $name"
    pass=$((pass+1))
  else
    echo "FAIL $name"
    fail=$((fail+1))
  fi
}

assert_eq() {
  local name="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    echo "OK   $name"
    pass=$((pass+1))
  else
    echo "FAIL $name"
    echo "     got:  $got"
    echo "     want: $want"
    fail=$((fail+1))
  fi
}

# Build fake CCS topology with 3 primary instances + 1 `.ccburn*` instance
setup_fake() {
  local home="$1"
  mkdir -p "$home"/.ccs/instances/a/plugins
  mkdir -p "$home"/.ccs/instances/b/plugins
  mkdir -p "$home"/.ccs/instances/c/plugins
  mkdir -p "$home"/.ccs/instances/.ccburntest/plugins
  mkdir -p "$home"/.ccs/shared "$home"/.claude
  for inst in a b c .ccburntest; do
    echo '{}' > "$home/.ccs/instances/$inst/plugins/known_marketplaces.json"
    echo '{}' > "$home/.ccs/instances/$inst/settings.json"
  done
  echo '{}' > "$home/.ccs/shared/settings.json"
  ln -sf "$home/.ccs/shared/settings.json" "$home/.claude/settings.json"
}

# Stage a fake `claude` CLI shim — same shim shape as probe-install-plugin-idempotency.sh
mkdir -p "$TMPDIR/bin"
cat > "$TMPDIR/bin/claude" <<'SHIM'
#!/bin/bash
INST="${CLAUDE_CONFIG_DIR:-}"
[ -z "$INST" ] && exit 0
case "$1 $2" in
  "plugin marketplace")
    kmf="$INST/plugins/known_marketplaces.json"
    [ -f "$kmf" ] || { mkdir -p "$(dirname "$kmf")"; echo '{}' > "$kmf"; }
    tmp=$(mktemp)
    if jq '. + {"dhx-local": {"name":"dhx-local","source":{"source":"directory","path":"/path/to/dhx-plugin"}}}' "$kmf" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$kmf"
    else
      rm -f "$tmp"
      exit 1
    fi
    ;;
  "plugin enable")
    sf="$INST/settings.json"
    [ -f "$sf" ] || echo '{}' > "$sf"
    tmp=$(mktemp)
    if jq '. + {"enabledPlugins":((.enabledPlugins // {}) + {"dhx@dhx-local":true}), "extraKnownMarketplaces":((.extraKnownMarketplaces // {}) + {"dhx-local":{"source":{"source":"directory","path":"/path/to/dhx-plugin"}}})}' "$sf" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$sf"
    else
      rm -f "$tmp"
      exit 1
    fi
    ;;
esac
exit 0
SHIM
chmod +x "$TMPDIR/bin/claude"

setup_fake "$TMPDIR"

# Capture .ccburn fixture content BEFORE install (D-25 exclusion check)
BURN_KMF_BEFORE=$(cat "$TMPDIR/.ccs/instances/.ccburntest/plugins/known_marketplaces.json")
BURN_SF_BEFORE=$(cat "$TMPDIR/.ccs/instances/.ccburntest/settings.json")

HOME="$TMPDIR" CLAUDE_CONFIG_DIR="$TMPDIR/.claude" PATH="$TMPDIR/bin:$PATH" \
  bash "$REPO/scripts/install-plugin.sh" > "$TMPDIR/out" 2>&1
INSTALL_RC=$?

# ---- Test 1: install-plugin.sh exits 0 ----
assert_eq "install-plugin.sh exits 0 against fresh fake topology" "$INSTALL_RC" "0"

# ---- Test 2+3: D-22 two-file — BOTH kmf and sf updated per primary instance ----
echo "=== D-22 two-file verification (kmf + sf per instance) ==="
for inst in a b c; do
  if jq -e '.["dhx-local"]' "$TMPDIR/.ccs/instances/$inst/plugins/known_marketplaces.json" >/dev/null 2>&1; then
    echo "OK   instance $inst kmf has dhx-local key"
    pass=$((pass+1))
  else
    echo "FAIL instance $inst kmf missing dhx-local key"
    fail=$((fail+1))
  fi
  if jq -e '.enabledPlugins["dhx@dhx-local"] == true and (.extraKnownMarketplaces["dhx-local"].source.path // empty) != ""' \
        "$TMPDIR/.ccs/instances/$inst/settings.json" >/dev/null 2>&1; then
    echo "OK   instance $inst sf passes canonical JQ_PRED"
    pass=$((pass+1))
  else
    echo "FAIL instance $inst sf missing canonical predicate"
    fail=$((fail+1))
  fi
done

# ---- Test 4: D-25 .ccburn* exclusion (files MUST remain untouched) ----
echo "=== D-25 .ccburn* exclusion ==="
BURN_KMF_AFTER=$(cat "$TMPDIR/.ccs/instances/.ccburntest/plugins/known_marketplaces.json")
BURN_SF_AFTER=$(cat "$TMPDIR/.ccs/instances/.ccburntest/settings.json")

assert_eq ".ccburn* kmf untouched (D-25 exclusion)" "$BURN_KMF_AFTER" "$BURN_KMF_BEFORE"
assert_eq ".ccburn* sf untouched (D-25 exclusion)" "$BURN_SF_AFTER" "$BURN_SF_BEFORE"

echo
echo "$pass passed, $fail failed"
exit $fail
