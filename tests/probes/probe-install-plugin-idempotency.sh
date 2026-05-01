#!/bin/bash
# Probe: scripts/install-plugin.sh is idempotent across two consecutive runs
# AND its --check mode is read-only AND respects the D-22 two-file detection
# cascade + D-23 exit semantics.
#
# install-plugin.sh is the canonical fresh-install / post-recovery entry for
# the dhx plugin (composes with bashrc heal block per D-01). The probe asserts
# the contract that planning-phase 4 locked:
#
#   D-22 two-file detection cascade — BOTH per-instance settings.json (canonical
#        JQ_PRED) AND plugins/known_marketplaces.json (`dhx-local` key existence)
#        MUST pass for the `installed` state. Either-side mismatch produces
#        `partial-install` and surfaces as exit 1 in --check mode.
#   D-23 --check mode exit semantics — 0 = installed-and-correct;
#        1 = missing-or-corrupt OR partial-install OR corrupt-JSON;
#        2 NEVER in --check mode (install errors are install-mode only).
#        install-mode keeps corrupt-JSON → exit 2 (refuse-with-diagnostic).
#
# Tests:
#   1+2  Two consecutive install-mode runs produce byte-identical snapshots
#        across BOTH kmf and sf files (idempotency, D-22 two-file).
#   3+4  --check after successful install exits 0 AND mutates nothing.
#   5    Partial-install (kmf side missing `dhx-local`, sf passes JQ_PRED) →
#        --check exits 1 with diagnostic naming the kmf side (D-22).
#   6    Partial-install (sf side missing canonical predicate, kmf has
#        `dhx-local`) → --check exits 1 (D-22).
#   7    Corrupt JSON in --check mode → exit 1 (NOT 2) per D-23.
#   8    Corrupt JSON in install mode → exit 2 (refuse-with-diagnostic) per D-23.
#
# Backs: Phase 4 Plan 01 (install-plugin.sh shape), CONTEXT.md decisions D-01,
#   D-05, D-06, D-07, D-15, D-20, D-22, D-23, D-24, D-25.
# Run: bash tests/probes/probe-install-plugin-idempotency.sh
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

# Build fake CCS topology under $1 (D-22 two-file model — BOTH files per instance)
setup_fake() {
  local home="$1"
  mkdir -p "$home"/.ccs/instances/a/plugins
  mkdir -p "$home"/.ccs/instances/b/plugins
  mkdir -p "$home"/.ccs/instances/c/plugins
  mkdir -p "$home"/.ccs/shared "$home"/.claude
  for inst in a b c; do
    echo '{}' > "$home/.ccs/instances/$inst/plugins/known_marketplaces.json"
    echo '{}' > "$home/.ccs/instances/$inst/settings.json"
  done
  echo '{}' > "$home/.ccs/shared/settings.json"
  ln -sf "$home/.ccs/shared/settings.json" "$home/.claude/settings.json"
}

# Stage a fake `claude` CLI shim under $TMPDIR/bin so install-plugin.sh can
# delegate without invoking the real CLI. The shim writes to BOTH settings.json
# (D-22 sf side) AND known_marketplaces.json (D-22 kmf side) per CLAUDE_CONFIG_DIR.
mkdir -p "$TMPDIR/bin"
cat > "$TMPDIR/bin/claude" <<'SHIM'
#!/bin/bash
# Fake claude CLI shim — simulates `claude plugin marketplace add` + `enable`.
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

# ---- Test 1+2: idempotency (two consecutive install-mode runs) ----
echo "=== Test 1+2: idempotency (two-file snapshot equality) ==="
HOME_1="$TMPDIR/home1"
setup_fake "$HOME_1"

HOME="$HOME_1" CLAUDE_CONFIG_DIR="$HOME_1/.claude" PATH="$TMPDIR/bin:$PATH" \
  bash "$REPO/scripts/install-plugin.sh" >/dev/null 2>&1
RUN1_RC=$?

SNAP1=$(find "$HOME_1/.ccs" -type f -exec md5sum {} + 2>/dev/null | sort)

HOME="$HOME_1" CLAUDE_CONFIG_DIR="$HOME_1/.claude" PATH="$TMPDIR/bin:$PATH" \
  bash "$REPO/scripts/install-plugin.sh" >/dev/null 2>&1
RUN2_RC=$?

SNAP2=$(find "$HOME_1/.ccs" -type f -exec md5sum {} + 2>/dev/null | sort)

assert_eq "first install run exits 0" "$RUN1_RC" "0"
assert_eq "second install run exits 0" "$RUN2_RC" "0"
assert_eq "second run produces no drift (kmf+sf both stable)" "$SNAP2" "$SNAP1"

# ---- Test 3+4: --check no-mutation after successful install ----
echo "=== Test 3+4: --check exits 0 + read-only after install ==="
SNAP_BEFORE=$(find "$HOME_1/.ccs" -type f -exec md5sum {} + 2>/dev/null | sort)
HOME="$HOME_1" CLAUDE_CONFIG_DIR="$HOME_1/.claude" PATH="$TMPDIR/bin:$PATH" \
  bash "$REPO/scripts/install-plugin.sh" --check >/dev/null 2>&1
CHECK_RC=$?
SNAP_AFTER=$(find "$HOME_1/.ccs" -type f -exec md5sum {} + 2>/dev/null | sort)

assert_eq "--check exits 0 after successful install" "$CHECK_RC" "0"
assert_eq "--check produces no mutation (snapshot stable)" "$SNAP_AFTER" "$SNAP_BEFORE"

# ---- Test 5: D-22 partial-install (kmf side missing dhx-local) ----
echo "=== Test 5: D-22 partial-install (kmf side) ==="
PARTIAL="$TMPDIR/partial-kmf"
setup_fake "$PARTIAL"
# Make instance `a` pass on sf side but kmf side still empty
jq '. + {"enabledPlugins":{"dhx@dhx-local":true}, "extraKnownMarketplaces":{"dhx-local":{"source":{"source":"directory","path":"/x"}}}}' \
  "$PARTIAL/.ccs/instances/a/settings.json" > "$PARTIAL/.ccs/instances/a/settings.json.tmp"
mv "$PARTIAL/.ccs/instances/a/settings.json.tmp" "$PARTIAL/.ccs/instances/a/settings.json"
# kmf still {} — partial-install state on kmf side

HOME="$PARTIAL" CLAUDE_CONFIG_DIR="$PARTIAL/.claude" PATH="$TMPDIR/bin:$PATH" \
  bash "$REPO/scripts/install-plugin.sh" --check > "$PARTIAL/out" 2>&1
PARTIAL_KMF_RC=$?

assert_eq "partial-install (kmf side) → --check exits 1 (D-23)" "$PARTIAL_KMF_RC" "1"
assert "diagnostic names kmf side (partial-install|known_marketplaces|kmf)" \
  "grep -qiE 'partial-install|known_marketplaces|kmf' '$PARTIAL/out'"

# ---- Test 6: D-22 partial-install (sf side; kmf has dhx-local but sf empty) ----
echo "=== Test 6: D-22 partial-install (sf side) ==="
PARTIAL2="$TMPDIR/partial-sf"
setup_fake "$PARTIAL2"
# Make instance `a` have `dhx-local` in kmf but sf still {}
jq '. + {"dhx-local":{"name":"dhx-local","source":{"source":"directory","path":"/x"}}}' \
  "$PARTIAL2/.ccs/instances/a/plugins/known_marketplaces.json" > "$PARTIAL2/.ccs/instances/a/plugins/known_marketplaces.json.tmp"
mv "$PARTIAL2/.ccs/instances/a/plugins/known_marketplaces.json.tmp" "$PARTIAL2/.ccs/instances/a/plugins/known_marketplaces.json"
# sf still {} — partial-install state on sf side

HOME="$PARTIAL2" CLAUDE_CONFIG_DIR="$PARTIAL2/.claude" PATH="$TMPDIR/bin:$PATH" \
  bash "$REPO/scripts/install-plugin.sh" --check > "$PARTIAL2/out" 2>&1
PARTIAL_SF_RC=$?

assert_eq "partial-install (sf side) → --check exits 1 (D-23)" "$PARTIAL_SF_RC" "1"
assert "diagnostic mentions partial-install" \
  "grep -qi 'partial-install' '$PARTIAL2/out'"

# ---- Test 7: D-23 corrupt JSON in --check (exit 1, NOT 2) ----
echo "=== Test 7: D-23 corrupt JSON in --check → exit 1 ==="
CORRUPT="$TMPDIR/corrupt-check"
setup_fake "$CORRUPT"
echo 'this-is-not-json{{{' > "$CORRUPT/.ccs/instances/a/plugins/known_marketplaces.json"

HOME="$CORRUPT" CLAUDE_CONFIG_DIR="$CORRUPT/.claude" PATH="$TMPDIR/bin:$PATH" \
  bash "$REPO/scripts/install-plugin.sh" --check > "$CORRUPT/out" 2>&1
CORRUPT_CHECK_RC=$?

assert_eq "corrupt JSON in --check mode → exit 1 (D-23, NOT 2)" "$CORRUPT_CHECK_RC" "1"

# ---- Test 8: D-23 corrupt JSON in install-mode (exit 2) ----
echo "=== Test 8: D-23 corrupt JSON in install-mode → exit 2 ==="
CORRUPT2="$TMPDIR/corrupt-install"
setup_fake "$CORRUPT2"
echo 'this-is-not-json{{{' > "$CORRUPT2/.ccs/instances/a/plugins/known_marketplaces.json"

HOME="$CORRUPT2" CLAUDE_CONFIG_DIR="$CORRUPT2/.claude" PATH="$TMPDIR/bin:$PATH" \
  bash "$REPO/scripts/install-plugin.sh" > "$CORRUPT2/out" 2>&1
CORRUPT_INSTALL_RC=$?

assert_eq "corrupt JSON in install-mode → exit 2 (D-23 install-mode refuse)" "$CORRUPT_INSTALL_RC" "2"

echo
echo "$pass passed, $fail failed"
exit $fail
