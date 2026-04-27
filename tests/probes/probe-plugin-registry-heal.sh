#!/bin/bash
# Exercises dhx-plugin-registry-heal.sh — the HP-025 companion heal hook.
# Each scenario stands up an isolated $HOME + $CLAUDE_CONFIG_DIR tmpdir with a
# specific starting state for $CONFIG/plugins/installed_plugins.json and the
# cache dir, runs the hook, and asserts the resulting state.
#
# Run: bash tests/probes/probe-plugin-registry-heal.sh
#
# Pattern mirrors probe-plugin-keys.sh fake-HOME convention. Live ~/.claude
# and ~/.ccs/shared/ are never touched.

set -u

HOOK="/home/dhx/repos/hooks/dhx/dhx-plugin-registry-heal.sh"
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0

# Build a fake CLAUDE_CONFIG_DIR with a populated cache under dhx-local/dhx/<version>.
# Each scenario gets its own subdir so state never leaks between runs.
#
# Args: name, ip_content (string or "NONE" or "EMPTY")
#   - NONE: don't create installed_plugins.json
#   - EMPTY: create as 0-byte file
#   - anything else: write as the literal file content
make_case() {
  local name=$1
  local ip_content=$2
  local has_cache=${3:-1}
  local cache_version=${4:-0.1.0}

  local home="$TMPROOT/$name"
  local cfg="$home/.claude"
  local plugins="$cfg/plugins"
  local cache_dir="$plugins/cache/dhx-local/dhx/$cache_version"

  mkdir -p "$plugins"
  if (( has_cache )); then
    mkdir -p "$cache_dir/.claude-plugin" "$cache_dir/hooks"
    cat > "$cache_dir/.claude-plugin/plugin.json" <<JSON
{"name":"dhx","version":"$cache_version","description":"probe fixture"}
JSON
  fi

  case "$ip_content" in
    NONE)
      ;;
    EMPTY)
      : > "$plugins/installed_plugins.json"
      ;;
    *)
      printf '%s' "$ip_content" > "$plugins/installed_plugins.json"
      ;;
  esac

  printf '%s' "$cfg"
}

run_hook() {
  local cfg=$1
  local home
  home=$(dirname "$cfg")
  HOME="$home" CLAUDE_CONFIG_DIR="$cfg" bash "$HOOK" < /dev/null >/dev/null 2>&1
  printf '%s' "$?"
}

# Assert IP file is valid JSON containing dhx@dhx-local entry with truthful
# metadata (installPath resolves to the cache dir, version matches plugin.json).
assert_healed() {
  local name=$1
  local ip=$2
  local expected_version=${3:-0.1.0}
  if [[ ! -s "$ip" ]]; then
    printf '  \u2717 %s: installed_plugins.json missing or empty\n' "$name"
    FAIL=$((FAIL + 1)); return
  fi
  if ! jq -e . "$ip" >/dev/null 2>&1; then
    printf '  \u2717 %s: installed_plugins.json not valid JSON\n' "$name"
    FAIL=$((FAIL + 1)); return
  fi
  local has ver path
  has=$(jq -r '.plugins["dhx@dhx-local"] // [] | length' "$ip" 2>/dev/null)
  if [[ "$has" != "1" ]]; then
    printf '  \u2717 %s: dhx@dhx-local entry count = %s, expected 1\n' "$name" "$has"
    FAIL=$((FAIL + 1)); return
  fi
  ver=$(jq -r '.plugins["dhx@dhx-local"][0].version // empty' "$ip" 2>/dev/null)
  path=$(jq -r '.plugins["dhx@dhx-local"][0].installPath // empty' "$ip" 2>/dev/null)
  if [[ "$ver" != "$expected_version" ]]; then
    printf '  \u2717 %s: version = %q, expected %q\n' "$name" "$ver" "$expected_version"
    FAIL=$((FAIL + 1)); return
  fi
  if [[ "$path" != */plugins/cache/dhx-local/dhx/"$expected_version" ]]; then
    printf '  \u2717 %s: installPath = %q, expected .../cache/dhx-local/dhx/%s\n' "$name" "$path" "$expected_version"
    FAIL=$((FAIL + 1)); return
  fi
  printf '  \u2713 %s (healed: ver=%s path=%q)\n' "$name" "$ver" "$path"
  PASS=$((PASS + 1))
}

assert_unchanged() {
  local name=$1
  local ip=$2
  local expected=$3
  local got
  got=$(cat "$ip" 2>/dev/null)
  if [[ "$got" == "$expected" ]]; then
    printf '  \u2713 %s (no-op as expected)\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  \u2717 %s: file changed unexpectedly\n' "$name"
    printf '    before: %q\n' "$expected"
    printf '    after:  %q\n' "$got"
    FAIL=$((FAIL + 1))
  fi
}

assert_missing() {
  local name=$1
  local ip=$2
  if [[ ! -e "$ip" ]]; then
    printf '  \u2713 %s (file correctly not created)\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  \u2717 %s: file exists but should not\n' "$name"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== dhx-plugin-registry-heal.sh — 8 scenarios ==="

# ---- 1. healthy: valid v2 file with dhx entry → no-op ----
HEALTHY_JSON='{"version":2,"plugins":{"dhx@dhx-local":[{"scope":"user","installPath":"/fake/path","version":"0.1.0","installedAt":"2026-04-24T00:00:00.000Z","lastUpdated":"2026-04-24T00:00:00.000Z"}]}}'
cfg=$(make_case "healthy" "$HEALTHY_JSON")
run_hook "$cfg" >/dev/null
assert_unchanged "healthy: valid-with-dhx is no-op" "$cfg/plugins/installed_plugins.json" "$HEALTHY_JSON"

# ---- 2. 0-byte file ----
cfg=$(make_case "zero-byte" "EMPTY")
run_hook "$cfg" >/dev/null
assert_healed "0-byte: heal writes v2 seed" "$cfg/plugins/installed_plugins.json"

# ---- 3. unparseable JSON ----
cfg=$(make_case "bad-json" '{ not json }')
run_hook "$cfg" >/dev/null
assert_healed "bad-json: overwrite with v2 seed" "$cfg/plugins/installed_plugins.json"

# ---- 4. missing entry (valid v2, has other plugins, lacks dhx) ----
OTHER_JSON='{"version":2,"plugins":{"other@market":[{"scope":"user","installPath":"/other","version":"1.0","installedAt":"2026-01-01T00:00:00.000Z","lastUpdated":"2026-01-01T00:00:00.000Z"}]}}'
cfg=$(make_case "missing-entry" "$OTHER_JSON")
run_hook "$cfg" >/dev/null
ip="$cfg/plugins/installed_plugins.json"
assert_healed "missing-entry: dhx inserted" "$ip"
# Additional assertion: other@market preserved
other_preserved=$(jq -r '.plugins["other@market"][0].version // empty' "$ip" 2>/dev/null)
if [[ "$other_preserved" == "1.0" ]]; then
  printf '  \u2713 missing-entry: other@market entry preserved\n'
  PASS=$((PASS + 1))
else
  printf '  \u2717 missing-entry: other@market entry lost (got %q)\n' "$other_preserved"
  FAIL=$((FAIL + 1))
fi

# ---- 5. missing file (parent dir exists but file doesn't) ----
cfg=$(make_case "missing-file" "NONE")
run_hook "$cfg" >/dev/null
assert_healed "missing-file: creates file with v2 seed" "$cfg/plugins/installed_plugins.json"

# ---- 6. cache missing: no cache dir → no-op (can't fabricate metadata) ----
cfg=$(make_case "no-cache" "EMPTY" 0)
rc=$(run_hook "$cfg")
if [[ "$rc" == "0" ]]; then
  printf '  \u2713 no-cache: exit 0\n'
  PASS=$((PASS + 1))
else
  printf '  \u2717 no-cache: expected exit 0, got %s\n' "$rc"
  FAIL=$((FAIL + 1))
fi
# File should remain 0-byte (no heal attempt)
ip="$cfg/plugins/installed_plugins.json"
if [[ -f "$ip" ]] && [[ ! -s "$ip" ]]; then
  printf '  \u2713 no-cache: 0-byte file untouched (heal correctly skipped)\n'
  PASS=$((PASS + 1))
else
  printf '  \u2717 no-cache: file was modified despite absent cache\n'
  FAIL=$((FAIL + 1))
fi

# ---- 7. known_marketplaces missing dhx-local: hook does NOT attempt to heal ----
# Scenario: installed_plugins.json is healthy, but known_marketplaces.json is
# missing or lacks dhx-local. Heal hook is scoped to installed_plugins.json
# only — km drift is handled by CC's Hn() resolver. Hook must be a no-op here.
KM_UNRELATED='{"other-marketplace":{"source":{"source":"github"},"installLocation":"/x"}}'
cfg=$(make_case "wrong-class" "$HEALTHY_JSON")
printf '%s' "$KM_UNRELATED" > "$cfg/plugins/known_marketplaces.json"
run_hook "$cfg" >/dev/null
assert_unchanged "wrong-class: km drift does not trigger heal" "$cfg/plugins/installed_plugins.json" "$HEALTHY_JSON"

# ---- 8. happy-path timing: hook runs under ~100ms ----
cfg=$(make_case "timing" "$HEALTHY_JSON")
t_start=$(date +%s%N)
HOME=$(dirname "$cfg") CLAUDE_CONFIG_DIR="$cfg" bash "$HOOK" < /dev/null >/dev/null 2>&1
t_end=$(date +%s%N)
elapsed_ms=$(( (t_end - t_start) / 1000000 ))
if (( elapsed_ms < 100 )); then
  printf '  \u2713 timing: happy path = %sms (< 100ms target)\n' "$elapsed_ms"
  PASS=$((PASS + 1))
else
  printf '  \u2717 timing: happy path = %sms (>= 100ms target)\n' "$elapsed_ms"
  FAIL=$((FAIL + 1))
fi

echo "---"
echo "PASS: $PASS  FAIL: $FAIL"
exit $FAIL
