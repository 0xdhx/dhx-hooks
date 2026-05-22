#!/bin/bash
# Exercises scripts/repair-installed-plugins.sh — the HP-025 operator-invoked repair (D-02/D-10).
# SAFE_FOR_LIVE: yes   (mktemp + fake HOME + fake CLAUDE_CONFIG_DIR; never touches live `~/.claude` or `~/.ccs/shared/`; no claude subprocess, no auth, no network)
#
# Phase 19 (SYM-REPAIR) D-10: this probe is the SC2 empirical anchor. It INVERTS the retired
# heal probe (tests/probes/probe-plugin-registry-heal.sh) — where the heal probe asserts
# "scope guard early-exits, file unchanged", this probe asserts the repair ACTION landed:
#   BADJSON      → wrote a valid v2 dhx-only seed + backed up the corrupt original to .bak
#   UNINSTALLED  → inserted dhx, preserved other plugins
#   HEALTHY      → idempotent no-op
#   hostile cfg  → REFUSE (rc!=0, structured stderr, victim bytes-identical)
#   D-16         → a forced build-validation failure leaves the ORIGINAL byte-identical (no rm-after-mv)
#   HP-025 clear → post-repair the transcribed checkPluginRegistry checks both pass
#   D-22b        → a dispatch-seam-shape smoke exercising the `[ -x "$HELPER" ] && bash "$HELPER"`
#                  shape SKILL.md uses (NOT the LLM-orchestrated SKILL.md execution)
#
# D-15: SAFE_FOR_LIVE: yes — fixture-only (mktemp + fake HOME + fake CLAUDE_CONFIG_DIR); never
# mutates the live registry, spawns no `claude -p` subprocess, requires no auth/network. Unlike
# the 4 unsafe natural-heal rows (which are unsafe precisely because they spawn real `claude -p`).
#
# Backs docs/decisions.md Phase 19 row + HP-025 active doctrine.
# Run: bash tests/probes/probe-repair-installed-plugins.sh
set -u

# Resolve $HELPER relative to this probe's repo root so the probe runs correctly inside a git
# worktree (where the main repo's path would point to the unmodified script).
PROBE_REPO_ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || echo "/home/dhx/repos/hooks")
HELPER="$PROBE_REPO_ROOT/scripts/repair-installed-plugins.sh"
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0

# Build a fake CLAUDE_CONFIG_DIR with a populated cache under dhx-local/dhx/<version>.
# Each scenario gets its own subdir so state never leaks between runs.
#
# Args: name, ip_content (string or "NONE" or "EMPTY"), [has_cache=1], [cache_version=0.1.3]
#   - NONE: don't create installed_plugins.json
#   - EMPTY: create as 0-byte file
#   - anything else: write as the literal file content
make_case() {
  local name=$1
  local ip_content=$2
  local has_cache=${3:-1}
  local cache_version=${4:-0.1.3}

  local home="$TMPROOT/$name"
  local cfg="$home/.claude"
  local plugins="$cfg/plugins"
  local cache_dir="$plugins/cache/dhx-local/dhx/$cache_version"

  mkdir -p "$plugins"
  if (( has_cache )); then
    mkdir -p "$cache_dir/.claude-plugin"
    cat > "$cache_dir/.claude-plugin/plugin.json" <<JSON
{"name":"dhx","version":"$cache_version","description":"probe fixture"}
JSON
  fi

  case "$ip_content" in
    NONE) ;;
    EMPTY) : > "$plugins/installed_plugins.json" ;;
    *) printf '%s' "$ip_content" > "$plugins/installed_plugins.json" ;;
  esac

  printf '%s' "$cfg"
}

# Invoke the helper in the fake-HOME sandbox. Optional 2nd arg = state arg passed to the helper.
run_helper() {
  local cfg=$1
  local state_arg=${2:-}
  local home
  home=$(dirname "$cfg")
  HOME="$home" CLAUDE_CONFIG_DIR="$cfg" bash "$HELPER" $state_arg < /dev/null >/dev/null 2>&1
  printf '%s' "$?"
}

# Sibling capture variant that captures STDERR only (for REFUSE/WARN scenarios).
# Redirect order: `2>&1 >/dev/null` — stderr is duplicated to stdout BEFORE stdout is
# discarded. Net effect: the captured stream contains stderr only.
run_helper_capture_stderr() {
  local cfg=$1
  local state_arg=${2:-}
  local home
  home=$(dirname "$cfg")
  HOME="$home" CLAUDE_CONFIG_DIR="$cfg" bash "$HELPER" $state_arg < /dev/null 2>&1 >/dev/null
}

pass() { printf '  ✓ %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL + 1)); }

# assert_v2_seed_written: BADJSON repair wrote a valid v2 dhx-only seed AND a .bak of the
# corrupt original exists.
assert_v2_seed_written() {
  local name=$1 cfg=$2
  local ip="$cfg/plugins/installed_plugins.json"
  if ! jq -e '.version == 2 and (.plugins["dhx@dhx-local"] | type == "array" and length > 0)' "$ip" >/dev/null 2>&1; then
    fail "$name: post-repair file is not a valid v2 dhx-only seed"
    return 1
  fi
  shopt -s nullglob
  local baks=( "$ip".bak.* )
  shopt -u nullglob
  if (( ${#baks[@]} == 0 )); then
    fail "$name: no .bak of the corrupt original found (glob $ip.bak.*)"
    return 1
  fi
  pass "$name (v2 seed written + .bak of corrupt original exists: ${baks[0]##*/})"
}

# assert_dhx_inserted_others_preserved: UNINSTALLED repair inserted dhx AND kept the fake-other.
assert_dhx_inserted_others_preserved() {
  local name=$1 cfg=$2 other_key=$3
  local ip="$cfg/plugins/installed_plugins.json"
  if ! jq -e '.plugins["dhx@dhx-local"] | type == "array" and length > 0' "$ip" >/dev/null 2>&1; then
    fail "$name: dhx@dhx-local not inserted as a non-empty array"
    return 1
  fi
  if ! jq -e --arg k "$other_key" '.plugins[$k]' "$ip" >/dev/null 2>&1; then
    fail "$name: other plugin '$other_key' was NOT preserved"
    return 1
  fi
  pass "$name (dhx inserted + '$other_key' preserved)"
}

# assert_idempotent: HEALTHY repair is a semantic no-op (content unchanged, exit 0).
assert_idempotent() {
  local name=$1 cfg=$2 before=$3 rc=$4
  local ip="$cfg/plugins/installed_plugins.json"
  local after
  after=$(cat "$ip" 2>/dev/null)
  if [[ "$rc" != "0" ]]; then
    fail "$name: expected exit 0, got $rc"
    return 1
  fi
  if [[ "$before" != "$after" ]]; then
    fail "$name: HEALTHY file changed (expected idempotent no-op)"
    return 1
  fi
  pass "$name (idempotent no-op, exit 0)"
}

# assert_hp025_clears: after repair, the transcribed checkPluginRegistry checks both pass
# (jq -e . parses AND .plugins["dhx@dhx-local"] is present) — the BADJSON/UNINSTALLED token clears.
assert_hp025_clears() {
  local name=$1 cfg=$2
  local ip="$cfg/plugins/installed_plugins.json"
  # Transcribed from statusline-wrapper.js::checkPluginRegistry (BADJSON :532, UNINSTALLED :559).
  if ! jq -e . "$ip" >/dev/null 2>&1; then
    fail "$name: post-repair still BADJSON (jq -e . fails)"
    return 1
  fi
  if ! jq -e '.plugins["dhx@dhx-local"]' "$ip" >/dev/null 2>&1; then
    fail "$name: post-repair still UNINSTALLED (.plugins[\"dhx@dhx-local\"] absent)"
    return 1
  fi
  pass "$name (HP-025 taxonomy: BADJSON + UNINSTALLED tokens both clear post-repair)"
}

echo "=== repair-installed-plugins.sh — repair-action probe (SC2 empirical anchor; D-10/D-15/D-16/D-22b) ==="

# ---- 1. BADJSON: invalid JSON → v2 seed + .bak + WARN ----
cfg=$(make_case "badjson" '{ not json }')
run_helper "$cfg" >/dev/null
assert_v2_seed_written "BADJSON: repair wrote valid v2 dhx-only seed + .bak" "$cfg"
# WARN assertion (D-08).
cfg2=$(make_case "badjson-warn" '{ also not json {{{')
badjson_stderr=$(run_helper_capture_stderr "$cfg2")
if grep -qF "WARN: BADJSON recovery" <<< "$badjson_stderr"; then
  pass "BADJSON: WARN substring present on stderr (D-08)"
else
  fail "BADJSON: WARN substring missing from stderr (got: $badjson_stderr)"
fi

# ---- 2. UNINSTALLED: valid JSON, dhx absent, fake-other present → dhx inserted, other preserved ----
UNINST_JSON='{"version":2,"plugins":{"other@mp":[{"scope":"user","installPath":"/other","version":"1.0","installedAt":"2026-01-01T00:00:00.000Z","lastUpdated":"2026-01-01T00:00:00.000Z"}]}}'
cfg=$(make_case "uninstalled" "$UNINST_JSON")
run_helper "$cfg" >/dev/null
assert_dhx_inserted_others_preserved "UNINSTALLED: dhx inserted, other@mp preserved" "$cfg" "other@mp"

# ---- 3. HEALTHY: valid v2 file with dhx entry → idempotent no-op ----
HEALTHY_JSON='{"version":2,"plugins":{"dhx@dhx-local":[{"scope":"user","installPath":"/fake/path","version":"0.1.3","installedAt":"2026-04-24T00:00:00.000Z","lastUpdated":"2026-04-24T00:00:00.000Z"}]}}'
cfg=$(make_case "healthy" "$HEALTHY_JSON")
before=$(cat "$cfg/plugins/installed_plugins.json")
rc=$(run_helper "$cfg")
assert_idempotent "HEALTHY: repair is idempotent no-op" "$cfg" "$before" "$rc"

# ---- 4. post-repair HP-025 token clears (BADJSON repaired → both checks pass) ----
cfg=$(make_case "hp025-badjson" '{ broken')
run_helper "$cfg" >/dev/null
assert_hp025_clears "HP-025: BADJSON repaired → taxonomy clean" "$cfg"
# UNINSTALLED repaired → both checks pass.
cfg=$(make_case "hp025-uninstalled" "$UNINST_JSON")
run_helper "$cfg" >/dev/null
assert_hp025_clears "HP-025: UNINSTALLED repaired → taxonomy clean" "$cfg"

# ---- 5. D-16: build-validation failure leaves the ORIGINAL byte-identical (no rm-after-mv) ----
# Arrange the helper to produce an invalid built JSON by shadowing `jq` on PATH so the
# validate-step `jq -e . "$TMP"` returns non-zero (the shim fails ONLY for *.tmp.* args, so the
# earlier jq -e/jq -n calls still succeed). Seed a known-good UNINSTALLED ORIGINAL (no .bak path)
# and assert the original sha256 is UNCHANGED post-run — proves there is no rm-after-mv data loss.
echo "EXPECT: D-16 build-validation-failure-preserves-original"
cfg=$(make_case "d16-validate" "$UNINST_JSON")
home=$(dirname "$cfg")
ip="$cfg/plugins/installed_plugins.json"
ORIG_HASH=$(sha256sum "$ip" | awk '{print $1}')
shimdir="$TMPROOT/jq-shim"
mkdir -p "$shimdir"
cat > "$shimdir/jq" <<'SHIM'
#!/bin/bash
# Fail ONLY when validating a tmp-sibling file (the D-16 validate-before-swap step).
for a in "$@"; do case "$a" in *.tmp.*) exit 1;; esac; done
exec /usr/bin/jq "$@"
SHIM
chmod +x "$shimdir/jq"
d16_stderr=$(HOME="$home" CLAUDE_CONFIG_DIR="$cfg" PATH="$shimdir:$PATH" bash "$HELPER" UNINSTALLED < /dev/null 2>&1 >/dev/null)
d16_rc=$?
AFTER_HASH=$(sha256sum "$ip" 2>/dev/null | awk '{print $1}')
if [[ "$d16_rc" != "0" ]]; then
  pass "D-16: helper REFUSEd on build-validation failure (rc=$d16_rc)"
else
  fail "D-16: helper returned rc=0 (expected non-zero REFUSE)"
fi
if grep -q 'built JSON failed validation' <<< "$d16_stderr"; then
  pass "D-16: 'built JSON failed validation' on stderr"
else
  fail "D-16: validation-failure stderr missing (got: $d16_stderr)"
fi
if [[ -f "$ip" && "$ORIG_HASH" == "$AFTER_HASH" ]]; then
  pass "D-16: ORIGINAL registry byte-identical pre→post (sha256 invariant; no rm-after-mv data loss)"
else
  fail "D-16: ORIGINAL registry DIVERGED or DELETED (before=$ORIG_HASH after=$AFTER_HASH; exists=$([ -f "$ip" ] && echo yes || echo no))"
fi

# ---- 6. hostile-config-dir-rejected (D-07 — copy near-verbatim from heal probe :538-599) ----
# Sandbox $CONFIG_DIR points at an attacker-controlled tree whose `plugins` subdir is a symlink
# chain into the REAL operator's `.claude/plugins`. The helper's realpath-pin check MUST refuse
# before any write. $HOSTILE_HOME + $HOSTILE_CFG are both rooted inside $TMPROOT (containment) —
# even if the guard were missing, any write lands inside $TMPROOT, never live state.
#
# Three inline assertions:
#   (1) rc != 0   — helper refused the write
#   (2) stderr matches structured REFUSE regex
#   (3) live victim IP bytes-identical sha256 pre→post (no symlink-chain write)
echo "EXPECT: REFUSE-symlink-crossing"
HOSTILE_HOME="$TMPROOT/hostile-cfg-test/home"
HOSTILE_CFG="$TMPROOT/hostile-cfg-test/cfg"
mkdir -p "$HOSTILE_HOME/.claude/plugins" "$HOSTILE_CFG"
# Pre-populate live victim IP inside the operator's "real" tree analog (corrupt → would tempt repair).
IP_LIVE='{ corrupt victim registry }'
printf '%s' "$IP_LIVE" > "$HOSTILE_HOME/.claude/plugins/installed_plugins.json"
BEFORE_HASH=$(sha256sum "$HOSTILE_HOME/.claude/plugins/installed_plugins.json" | awk '{print $1}')
# Seed a cache under the hostile cfg's victim tree so the cache probe passes (the attack must be
# caught by the IP realpath-pin, not by a missing cache).
mkdir -p "$HOSTILE_HOME/.claude/plugins/cache/dhx-local/dhx/0.1.3/.claude-plugin"
echo '{"name":"dhx","version":"0.1.3"}' > "$HOSTILE_HOME/.claude/plugins/cache/dhx-local/dhx/0.1.3/.claude-plugin/plugin.json"
# Attack: $HOSTILE_CFG/plugins symlinks into $HOSTILE_HOME/.claude/plugins. The helper opening
# "$CFG/plugins/installed_plugins.json" follows through to the live victim.
ln -s "$HOSTILE_HOME/.claude/plugins" "$HOSTILE_CFG/plugins"
hostile_stderr=$(HOME="$HOSTILE_HOME" CLAUDE_CONFIG_DIR="$HOSTILE_CFG" bash "$HELPER" BADJSON < /dev/null 2>&1 >/dev/null)
hostile_rc=$?
AFTER_HASH=$(sha256sum "$HOSTILE_HOME/.claude/plugins/installed_plugins.json" | awk '{print $1}')
if [[ "$hostile_rc" != "0" ]]; then
  pass "hostile-config-dir: helper returned non-zero (rc=$hostile_rc)"
else
  fail "hostile-config-dir: helper returned rc=0 (expected non-zero REFUSE)"
fi
if grep -qE '^repair-installed-plugins: REFUSE:' <<< "$hostile_stderr"; then
  pass "hostile-config-dir: stderr matches REFUSE regex with structured prefix"
else
  fail "hostile-config-dir: stderr does not match REFUSE regex (got: $hostile_stderr)"
fi
if [[ "$BEFORE_HASH" == "$AFTER_HASH" ]]; then
  pass "hostile-config-dir: live victim IP bytes-identical pre→post (sha256 invariant; no symlink-chain write)"
else
  fail "hostile-config-dir: TAINTED — live victim IP bytes diverged (before=$BEFORE_HASH after=$AFTER_HASH)"
fi

# ---- 7. dispatch-seam-shape smoke (D-22b) ----
# A sandboxed simulation of the SKILL.md `[ -x "$HELPER" ] && bash "$HELPER" "$STATE"` dispatch
# SHAPE — it exercises the [ -x ] && bash shape SKILL.md uses (validates the D-02 seam shape).
# This is NOT the LLM-orchestrated SKILL.md execution and is not labeled as such.
echo "EXPECT: dispatch-seam-shape-smoke"
cfg=$(make_case "dispatch-smoke" '{ corrupt')
home=$(dirname "$cfg")
STATE=BADJSON
dispatch_rc=1
if [ -x "$HELPER" ]; then
  HOME="$home" CLAUDE_CONFIG_DIR="$cfg" bash "$HELPER" "$STATE" < /dev/null >/dev/null 2>&1
  dispatch_rc=$?
fi
ip="$cfg/plugins/installed_plugins.json"
if [[ "$dispatch_rc" == "0" ]] && jq -e '.plugins["dhx@dhx-local"]' "$ip" >/dev/null 2>&1; then
  pass "dispatch-seam-shape smoke: [ -x ] && bash \"\$HELPER\" \"\$STATE\" reached the helper and repaired the fixture"
else
  fail "dispatch-seam-shape smoke: dispatch shape did not repair the fixture (rc=$dispatch_rc)"
fi

echo "---"
echo "$PASS passed, $FAIL failed"
exit $FAIL
