#!/bin/bash
# Exercises the plugin-registry drift detector added to
# dhx/statusline-wrapper.js (checkPluginRegistry / readHealthCache wiring).
#
# Backs docs/decisions.md 2026-04-24 plugin-registry-drift row + HP-025.
# Run: bash tests/probes/probe-plugin-registry.sh
#
# For each of the 6 drift states we stand up an isolated tmpdir-as-config
# (never touching live $CLAUDE_CONFIG_DIR), populate
#   plugins/known_marketplaces.json, plugins/installed_plugins.json,
#   settings.json -> settings-real.json
# with the mutation, invoke node dhx/statusline-wrapper.js with synthesized
# stdin, and assert the expected `registry:<STATE>:<key>` substring appears
# in stdout. Final case asserts a clean shape — everything consistent — emits
# no `registry:` segment.
#
# Safety note: tmpdir is created per-run and cleaned on EXIT. Live registry
# files are never mutated. The directory-source marketplace path used in the
# fixtures is `/home/dhx/repos/hooks/dhx-plugin`, which exists; a tmpdir
# alternative path is also used to synthesize the PATH mismatch case.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WRAPPER="$REPO_ROOT/dhx/statusline-wrapper.js"
LIVE_MK_PATH="/home/dhx/repos/hooks/dhx-plugin"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0

make_case_dir() {
  local name=$1
  local cfg="$TMPDIR/$name"
  mkdir -p "$cfg/plugins" "$cfg/cache-dhx"
  echo "$cfg"
}

# Build a consistent baseline pair for a given CFG — marketplace declared +
# registered at LIVE_MK_PATH, plugin enabled + installed. Individual cases
# overwrite one field to synthesize each drift state.
write_baseline() {
  local cfg=$1
  # settings.json via real-file + symlink so the wrapper's realpathSync
  # resolves cleanly.
  cat > "$cfg/settings-real.json" <<JSON
{
  "enabledPlugins": {"dhx@dhx-local": true},
  "extraKnownMarketplaces": {
    "dhx-local": {
      "source": {"source": "directory", "path": "$LIVE_MK_PATH"}
    }
  }
}
JSON
  ln -sf "$cfg/settings-real.json" "$cfg/settings.json"

  cat > "$cfg/plugins/known_marketplaces.json" <<JSON
{
  "dhx-local": {
    "source": {"source": "directory", "path": "$LIVE_MK_PATH"},
    "installLocation": "$LIVE_MK_PATH",
    "lastUpdated": "2026-04-24T00:00:00.000Z"
  }
}
JSON

  cat > "$cfg/plugins/installed_plugins.json" <<JSON
{
  "version": 2,
  "plugins": {
    "dhx@dhx-local": [
      {
        "scope": "user",
        "installPath": "/dev/null",
        "version": "0.1.0",
        "installedAt": "2026-04-24T00:00:00.000Z",
        "lastUpdated": "2026-04-24T00:00:00.000Z"
      }
    ]
  }
}
JSON
}

run_wrapper() {
  local cfg=$1
  # Unique session id + throwaway transcript → wrapper skips cache-age segment
  # and writes a fresh drift snapshot per case (nothing carries across cases).
  local sid="probe-plugin-registry-$RANDOM"
  local stdin="{\"session_id\":\"$sid\",\"workspace\":{\"current_dir\":\"$REPO_ROOT\"},\"transcript_path\":\"/tmp/none\"}"
  CLAUDE_CONFIG_DIR="$cfg" \
    HOME="$cfg/cache-dhx-home" \
    node "$WRAPPER" <<< "$stdin" 2>/dev/null || true
  # HOME override isolates ~/.cache/dhx/ — the wrapper silently no-ops missing
  # health.json so the probe output stays free of live health signals.
}

assert_contains() {
  local name=$1
  local needle=$2
  local haystack=$3
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  \u2713 %s (saw %q)\n' "$name" "$needle"
    PASS=$((PASS + 1))
  else
    printf '  \u2717 %s: expected substring %q\n      output: %q\n' "$name" "$needle" "$haystack"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local name=$1
  local needle=$2
  local haystack=$3
  if [[ "$haystack" != *"$needle"* ]]; then
    printf '  \u2713 %s (no %q)\n' "$name" "$needle"
    PASS=$((PASS + 1))
  else
    printf '  \u2717 %s: unexpected substring %q\n      output: %q\n' "$name" "$needle" "$haystack"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== plugin-registry drift detector (tmpdir-isolated) ==="

# ---- 1. UNREADABLE on known_marketplaces.json ----
cfg=$(make_case_dir "unreadable-km")
write_baseline "$cfg"
rm -f "$cfg/plugins/known_marketplaces.json"
out=$(run_wrapper "$cfg")
assert_contains "UNREADABLE:known_marketplaces.json" "registry:UNREADABLE:known_marketplaces.json" "$out"

# ---- 2. UNREADABLE on installed_plugins.json ----
cfg=$(make_case_dir "unreadable-ip")
write_baseline "$cfg"
rm -f "$cfg/plugins/installed_plugins.json"
out=$(run_wrapper "$cfg")
assert_contains "UNREADABLE:installed_plugins.json" "registry:UNREADABLE:installed_plugins.json" "$out"

# ---- 3. BADJSON on known_marketplaces.json ----
cfg=$(make_case_dir "badjson-km")
write_baseline "$cfg"
printf '{ this is not json ' > "$cfg/plugins/known_marketplaces.json"
out=$(run_wrapper "$cfg")
assert_contains "BADJSON:known_marketplaces.json" "registry:BADJSON:known_marketplaces.json" "$out"

# ---- 4. BADJSON on installed_plugins.json ----
cfg=$(make_case_dir "badjson-ip")
write_baseline "$cfg"
printf '}}}' > "$cfg/plugins/installed_plugins.json"
out=$(run_wrapper "$cfg")
assert_contains "BADJSON:installed_plugins.json" "registry:BADJSON:installed_plugins.json" "$out"

# ---- 5. MISSING: km lacks the dhx-local key ----
cfg=$(make_case_dir "missing")
write_baseline "$cfg"
cat > "$cfg/plugins/known_marketplaces.json" <<'JSON'
{
  "other-marketplace": {
    "source": {"source": "github", "repo": "foo/bar"},
    "installLocation": "/dev/null"
  }
}
JSON
out=$(run_wrapper "$cfg")
assert_contains "MISSING:dhx-local" "registry:MISSING:dhx-local" "$out"

# ---- 6. PATH: km points at a different directory than settings ----
cfg=$(make_case_dir "path")
write_baseline "$cfg"
BOGUS_DIR="$cfg/bogus-location"
mkdir -p "$BOGUS_DIR"
cat > "$cfg/plugins/known_marketplaces.json" <<JSON
{
  "dhx-local": {
    "source": {"source": "directory", "path": "$BOGUS_DIR"},
    "installLocation": "$BOGUS_DIR",
    "lastUpdated": "2026-04-24T00:00:00.000Z"
  }
}
JSON
out=$(run_wrapper "$cfg")
assert_contains "PATH:dhx-local" "registry:PATH:dhx-local" "$out"

# ---- 7. UNINSTALLED: plugin absent from installed_plugins ----
cfg=$(make_case_dir "uninstalled")
write_baseline "$cfg"
cat > "$cfg/plugins/installed_plugins.json" <<'JSON'
{
  "version": 2,
  "plugins": {
    "other-plugin@other-marketplace": []
  }
}
JSON
out=$(run_wrapper "$cfg")
assert_contains "UNINSTALLED:dhx@dhx-local" "registry:UNINSTALLED:dhx@dhx-local" "$out"

# ---- 8. DISABLED: installed but enabledPlugins[...] !== true ----
cfg=$(make_case_dir "disabled")
write_baseline "$cfg"
cat > "$cfg/settings-real.json" <<JSON
{
  "enabledPlugins": {"dhx@dhx-local": false},
  "extraKnownMarketplaces": {
    "dhx-local": {
      "source": {"source": "directory", "path": "$LIVE_MK_PATH"}
    }
  }
}
JSON
out=$(run_wrapper "$cfg")
assert_contains "DISABLED:dhx@dhx-local" "registry:DISABLED:dhx@dhx-local" "$out"

# ---- 9. Clean (positive case): baseline everything, no mutation ----
cfg=$(make_case_dir "clean")
write_baseline "$cfg"
out=$(run_wrapper "$cfg")
assert_not_contains "clean-state-no-registry-segment" "registry:" "$out"

# Advisory: report what live CLAUDE_CONFIG_DIR looks like but do NOT gate
# pass/fail on it. The whole point of this detector is to surface real-world
# drift — if the machine is incidentally drifted when the probe runs, that's
# a signal not a test failure. The 6 isolated-tmpdir tests above are the
# contract.
LIVE_CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [[ -d "$LIVE_CFG/plugins" ]]; then
  sid="probe-plugin-registry-live-$RANDOM"
  stdin="{\"session_id\":\"$sid\",\"workspace\":{\"current_dir\":\"$REPO_ROOT\"},\"transcript_path\":\"/tmp/none\"}"
  out=$(node "$WRAPPER" <<< "$stdin" 2>/dev/null || true)
  live_segment=$(printf '%s' "$out" | grep -oE 'registry:[A-Z]+:[A-Za-z0-9@_.-]+' | head -1 || true)
  if [[ -z "$live_segment" ]]; then
    printf '  \u2139 live CLAUDE_CONFIG_DIR clean (no registry: segment)\n'
  else
    printf '  \u2139 live CLAUDE_CONFIG_DIR DRIFTED — detector firing: %s\n' "$live_segment"
    printf '    (informational — probe contract is the 6 isolated states above)\n'
  fi
fi

echo "---"
echo "PASS: $PASS  FAIL: $FAIL"
exit $FAIL
