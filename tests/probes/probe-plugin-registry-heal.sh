#!/bin/bash
# Exercises dhx-plugin-registry-heal.sh — the HP-025 companion heal hook.
# SAFE_FOR_LIVE: yes   (mktemp + fake HOME + fake CLAUDE_CONFIG_DIR; never touches live `~/.claude` or `~/.ccs/shared/`)
#
# Phase 6 surgical-slim retire (2026-05-03): scope guard inverts heal-write assertions.
# See block below for full context.
#
# ============================================================================
# PHASE 6 SURGICAL-SLIM RETIRE (2026-05-03)
# ============================================================================
# The dhx-plugin-registry-heal.sh hook was scope-guard-retired per docs/decisions.md
# 2026-05-03 row + .planning/phases/06-*/06-02-SUMMARY.md. The script now early-exits
# without writing installed_plugins.json (Hn() rehydrates upstream — evidence in
# tests/probes/.results/v1.2-phase-6/probe-installed-plugins-{badjson,uninstalled-dhx}-
# natural-heal.json). All scenarios that previously asserted "heal wrote IP" are
# inverted to "heal did NOT write IP" (post-state == pre-state). The km branch
# is HEAL-07 follow-on (not implemented in script body).
#
# Net script behavior post-Phase-6: top-level `exit 0` short-circuits all heal
# logic regardless of installed_plugins.json state. The probe verifies this
# invariant by setting up the same 8 scenarios the pre-retire version covered
# and asserting the file (or absence) is unchanged after the hook runs.
# ============================================================================
#
# Each scenario stands up an isolated $HOME + $CLAUDE_CONFIG_DIR tmpdir with a
# specific starting state for $CONFIG/plugins/installed_plugins.json and the
# cache dir, runs the hook, and asserts the resulting state matches pre-state.
#
# Backs docs/decisions.md 2026-04-24 registry-heal-hook row + 2026-05-03
# Phase 6 surgical-slim retire row + HP-025 active doctrine.
# Run: bash tests/probes/probe-plugin-registry-heal.sh
#
# Pattern mirrors probe-plugin-keys.sh fake-HOME convention. Live ~/.claude
# and ~/.ccs/shared/ are never touched.
set -u

# Resolve $HOOK relative to this probe's repo root so the probe runs correctly
# inside a git worktree (where the main repo's path would point to the unmodified
# script). `git rev-parse --show-toplevel` returns the worktree's toplevel.
PROBE_REPO_ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || echo "/home/dhx/repos/hooks")
HOOK="$PROBE_REPO_ROOT/dhx/dhx-plugin-registry-heal.sh"
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

# Phase 6 surgical-slim assertion: file state matches pre-state (heal early-exits,
# no write). Accepts a literal expected content; bytes-identical check.
assert_unchanged() {
  local name=$1
  local ip=$2
  local expected=$3
  local got
  got=$(cat "$ip" 2>/dev/null)
  if [[ "$got" == "$expected" ]]; then
    printf '  ✓ %s (no-op as expected — Phase 6 scope guard)\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  ✗ %s: file changed unexpectedly (Phase 6 scope guard violated)\n' "$name"
    printf '    before: %q\n' "$expected"
    printf '    after:  %q\n' "$got"
    FAIL=$((FAIL + 1))
  fi
}

# Phase 6 surgical-slim assertion: file remains 0 bytes (was EMPTY pre-hook).
assert_still_empty() {
  local name=$1
  local ip=$2
  if [[ -f "$ip" && ! -s "$ip" ]]; then
    printf '  ✓ %s (still 0-byte — Phase 6 scope guard)\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  ✗ %s: file no longer 0-byte (Phase 6 scope guard violated)\n' "$name"
    if [[ -f "$ip" ]]; then
      printf '    size: %d\n' "$(wc -c < "$ip")"
    else
      printf '    file missing\n'
    fi
    FAIL=$((FAIL + 1))
  fi
}

# Phase 6 surgical-slim assertion: file remains absent (NONE setup; heal early-exits
# before any mkdir/write).
assert_still_missing() {
  local name=$1
  local ip=$2
  if [[ ! -e "$ip" ]]; then
    printf '  ✓ %s (file correctly not created — Phase 6 scope guard)\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  ✗ %s: file exists but should not (Phase 6 scope guard violated)\n' "$name"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== dhx-plugin-registry-heal.sh — 8 scenarios (Phase 6 surgical-slim: all no-op) ==="

# ---- 1. healthy: valid v2 file with dhx entry → no-op (was no-op pre-Phase-6 too) ----
HEALTHY_JSON='{"version":2,"plugins":{"dhx@dhx-local":[{"scope":"user","installPath":"/fake/path","version":"0.1.0","installedAt":"2026-04-24T00:00:00.000Z","lastUpdated":"2026-04-24T00:00:00.000Z"}]}}'
cfg=$(make_case "healthy" "$HEALTHY_JSON")
run_hook "$cfg" >/dev/null
assert_unchanged "healthy: valid-with-dhx is no-op" "$cfg/plugins/installed_plugins.json" "$HEALTHY_JSON"

# ---- 2. 0-byte file (was: heal writes v2 seed; now: scope guard early-exit, file stays 0-byte) ----
cfg=$(make_case "zero-byte" "EMPTY")
run_hook "$cfg" >/dev/null
assert_still_empty "0-byte: scope guard early-exits, no IP write" "$cfg/plugins/installed_plugins.json"

# ---- 3. unparseable JSON (was: overwrite with v2 seed; now: scope guard early-exit, content unchanged) ----
BAD_JSON='{ not json }'
cfg=$(make_case "bad-json" "$BAD_JSON")
run_hook "$cfg" >/dev/null
assert_unchanged "bad-json: scope guard early-exits, content unchanged" "$cfg/plugins/installed_plugins.json" "$BAD_JSON"

# ---- 4. missing entry (was: dhx inserted; now: scope guard early-exit, file unchanged) ----
OTHER_JSON='{"version":2,"plugins":{"other@market":[{"scope":"user","installPath":"/other","version":"1.0","installedAt":"2026-01-01T00:00:00.000Z","lastUpdated":"2026-01-01T00:00:00.000Z"}]}}'
cfg=$(make_case "missing-entry" "$OTHER_JSON")
run_hook "$cfg" >/dev/null
ip="$cfg/plugins/installed_plugins.json"
assert_unchanged "missing-entry: scope guard early-exits, dhx NOT inserted" "$ip" "$OTHER_JSON"
# Additional assertion: other@market remains in original literal form
other_preserved=$(jq -r '.plugins["other@market"][0].version // empty' "$ip" 2>/dev/null)
if [[ "$other_preserved" == "1.0" ]]; then
  printf '  ✓ missing-entry: other@market entry untouched (Phase 6 scope guard)\n'
  PASS=$((PASS + 1))
else
  printf '  ✗ missing-entry: other@market entry changed (got %q)\n' "$other_preserved"
  FAIL=$((FAIL + 1))
fi

# ---- 5. missing file (was: creates file with v2 seed; now: scope guard early-exit, file stays missing) ----
cfg=$(make_case "missing-file" "NONE")
run_hook "$cfg" >/dev/null
assert_still_missing "missing-file: scope guard early-exits, file NOT created" "$cfg/plugins/installed_plugins.json"

# ---- 6. cache missing: no cache dir → no-op (pre-existing no-op behavior; preserved) ----
# Pre-Phase-6 the cache-source-of-truth probe early-exited. Post-Phase-6 the
# scope guard early-exits even before the cache probe. Net: still no-op.
cfg=$(make_case "no-cache" "EMPTY" 0)
rc=$(run_hook "$cfg")
if [[ "$rc" == "0" ]]; then
  printf '  ✓ no-cache: exit 0 (Phase 6 scope guard)\n'
  PASS=$((PASS + 1))
else
  printf '  ✗ no-cache: expected exit 0, got %s\n' "$rc"
  FAIL=$((FAIL + 1))
fi
ip="$cfg/plugins/installed_plugins.json"
if [[ -f "$ip" ]] && [[ ! -s "$ip" ]]; then
  printf '  ✓ no-cache: 0-byte file untouched (Phase 6 scope guard)\n'
  PASS=$((PASS + 1))
else
  printf '  ✗ no-cache: file was modified despite scope guard\n'
  FAIL=$((FAIL + 1))
fi

# ---- 7. known_marketplaces drift: still no-op for IP (pre-Phase-6 was no-op too) ----
# Scenario: installed_plugins.json is healthy, known_marketplaces.json has unrelated
# content. Pre-Phase-6 the heal hook was scoped to IP only — km drift did not
# trigger a write. Post-Phase-6 the scope guard early-exits before any check.
# Either way: IP file is no-op. (km branch is HEAL-07 follow-on; not exercised here.)
KM_UNRELATED='{"other-marketplace":{"source":{"source":"github"},"installLocation":"/x"}}'
cfg=$(make_case "wrong-class" "$HEALTHY_JSON")
printf '%s' "$KM_UNRELATED" > "$cfg/plugins/known_marketplaces.json"
run_hook "$cfg" >/dev/null
assert_unchanged "wrong-class: IP unchanged regardless of km state (Phase 6 scope guard)" "$cfg/plugins/installed_plugins.json" "$HEALTHY_JSON"

# ---- 8. happy-path timing: hook runs under ~100ms (post-Phase-6: ~1ms early-exit) ----
cfg=$(make_case "timing" "$HEALTHY_JSON")
t_start=$(date +%s%N)
HOME=$(dirname "$cfg") CLAUDE_CONFIG_DIR="$cfg" bash "$HOOK" < /dev/null >/dev/null 2>&1
t_end=$(date +%s%N)
elapsed_ms=$(( (t_end - t_start) / 1000000 ))
if (( elapsed_ms < 100 )); then
  printf '  ✓ timing: happy path = %sms (< 100ms target — scope guard early-exit)\n' "$elapsed_ms"
  PASS=$((PASS + 1))
else
  printf '  ✗ timing: happy path = %sms (>= 100ms target)\n' "$elapsed_ms"
  FAIL=$((FAIL + 1))
fi

echo "---"
echo "PASS: $PASS  FAIL: $FAIL"
exit $FAIL
