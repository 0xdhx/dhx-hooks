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
# Args: name, ip_content (string or "NONE" or "EMPTY"), [has_cache=1], [cache_version=0.1.0], [km_content="NONE"]
#   - NONE: don't create the corresponding file
#   - EMPTY: create as 0-byte file
#   - anything else: write as the literal file content
#
# Phase 10 extension (D-08): adds 5th positional arg `km_content` for
# known_marketplaces.json fixture seeding (NONE / EMPTY / literal string).
# Also pre-seeds `$home/.ccs/instances/probe/plugins/marketplaces/dhx-local`
# so heal-side scenarios have a valid allow-list-resident installLocation
# target candidate (per D-03 allow-list `$HOME/.ccs/instances/*/plugins/marketplaces/`).
make_case() {
  local name=$1
  local ip_content=$2
  local has_cache=${3:-1}
  local cache_version=${4:-0.1.0}
  local km_content=${5:-NONE}

  local home="$TMPROOT/$name"
  local cfg="$home/.claude"
  local plugins="$cfg/plugins"
  local cache_dir="$plugins/cache/dhx-local/dhx/$cache_version"

  mkdir -p "$plugins"
  # Phase 10: seed a CCS-instance-shaped allow-list-resident installLocation candidate
  # so re-derived NEW_IL values can resolve under $HOME/.ccs/instances/*/plugins/marketplaces/.
  mkdir -p "$home/.ccs/instances/probe/plugins/marketplaces/dhx-local"
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

  case "$km_content" in
    NONE)
      ;;
    EMPTY)
      : > "$plugins/known_marketplaces.json"
      ;;
    *)
      printf '%s' "$km_content" > "$plugins/known_marketplaces.json"
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

# Phase 10 D-08: sibling capture variant that captures STDERR only.
# Redirect order: `2>&1 >/dev/null` — stderr is duplicated to stdout BEFORE
# stdout is discarded. Net effect: the captured stream contains stderr only.
# Used by REJECT/REFUSE scenarios that assert on the structured stderr prefix
# `dhx-plugin-registry-heal: REJECT: <reason>` per D-06.
run_hook_capture_stderr() {
  local cfg=$1
  local home
  home=$(dirname "$cfg")
  HOME="$home" CLAUDE_CONFIG_DIR="$cfg" bash "$HOOK" < /dev/null 2>&1 >/dev/null
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

# ============================================================================
# Phase 10 D-08 — new km-side assertion families
# ============================================================================
# (a) assert_km_dhx_local_healed
#     Verifies the km file parses; ."dhx-local".source.source == "directory";
#     ."dhx-local".source.path non-empty; ."dhx-local".installLocation non-empty
#     AND resolves under $HOME/.claude/plugins/marketplaces OR
#     $HOME/.ccs/instances/*/plugins/marketplaces (via realpath -m).
#     G-04 strengthening: for each key in expected_other_keys, byte-equality
#     check vs pre-snapshot file in $pre_snap_dir/<key>.json. Failure messages
#     distinguish "key missing" vs "bytes diverged" so the executor can debug.
# (b) assert_km_unchanged_with_stderr_match
#     Bytes-identical km pre→post AND captured stderr matches the regex.
# (c) assert_km_installlocation_only_rewritten
#     ."dhx-local".installLocation MUST differ from $original_il; source.source +
#     source.path unchanged; for each key in expected_other_keys, byte-equality
#     vs pre-snapshot (G-04 strengthening).
# ============================================================================

# assert_km_dhx_local_healed(name, km_path, home, expected_other_keys_space_sep, pre_snap_dir)
assert_km_dhx_local_healed() {
  local name=$1
  local km_path=$2
  local home=$3
  local expected_other_keys=$4
  local pre_snap_dir=$5
  local local_pass=1
  local fail_reason=""

  if [[ ! -f "$km_path" ]]; then
    printf '  ✗ %s: km file does not exist post-heal: %s\n' "$name" "$km_path"
    FAIL=$((FAIL + 1))
    return 1
  fi
  if ! jq -e . "$km_path" >/dev/null 2>&1; then
    printf '  ✗ %s: km file does not parse as JSON post-heal\n' "$name"
    FAIL=$((FAIL + 1))
    return 1
  fi

  local dhx_source dhx_path dhx_il
  dhx_source=$(jq -r '."dhx-local".source.source // empty' "$km_path" 2>/dev/null)
  dhx_path=$(jq -r '."dhx-local".source.path // empty' "$km_path" 2>/dev/null)
  dhx_il=$(jq -r '."dhx-local".installLocation // empty' "$km_path" 2>/dev/null)

  if [[ "$dhx_source" != "directory" ]]; then
    fail_reason="dhx-local.source.source != 'directory' (got '$dhx_source')"
    local_pass=0
  elif [[ -z "$dhx_path" ]]; then
    fail_reason="dhx-local.source.path is empty"
    local_pass=0
  elif [[ -z "$dhx_il" ]]; then
    fail_reason="dhx-local.installLocation is empty"
    local_pass=0
  else
    # installLocation must canonicalize under an allow-list root.
    local il_resolved root_claude root_ccs_glob
    il_resolved=$(realpath -m "$dhx_il" 2>/dev/null)
    root_claude=$(realpath -m "$home/.claude/plugins/marketplaces" 2>/dev/null)
    local matched=0
    if [[ -n "$il_resolved" && -n "$root_claude" ]]; then
      case "$il_resolved" in
        "$root_claude"/*) matched=1 ;;
      esac
    fi
    if (( ! matched )); then
      local g
      for g in "$home"/.ccs/instances/*/plugins/marketplaces; do
        [[ -e "$g" ]] || continue
        local rg
        rg=$(realpath -m "$g" 2>/dev/null)
        case "$il_resolved" in
          "$rg"/*) matched=1; break ;;
        esac
      done
    fi
    if (( ! matched )); then
      fail_reason="installLocation '$dhx_il' (resolved '$il_resolved') falls outside allow-list"
      local_pass=0
    fi
  fi

  if (( local_pass )); then
    # G-04 byte-preservation check on other-marketplace keys.
    local k pre_snap post_snap
    for k in $expected_other_keys; do
      pre_snap="$pre_snap_dir/$k.json"
      if [[ ! -f "$pre_snap" ]]; then
        fail_reason="pre-snapshot missing for key '$k' at $pre_snap"
        local_pass=0
        break
      fi
      if ! jq -e --arg k "$k" '.[$k]' "$km_path" >/dev/null 2>&1; then
        fail_reason="key '$k' missing from healed km (pre-snapshot existed; expected byte-preservation)"
        local_pass=0
        break
      fi
      post_snap=$(jq -c --arg k "$k" '.[$k]' "$km_path" 2>/dev/null)
      local pre_bytes
      pre_bytes=$(cat "$pre_snap" 2>/dev/null)
      if [[ "$post_snap" != "$pre_bytes" ]]; then
        fail_reason="key '$k' bytes diverged (pre=$pre_bytes post=$post_snap)"
        local_pass=0
        break
      fi
    done
  fi

  if (( local_pass )); then
    printf '  ✓ %s (dhx-local seeded + other keys byte-preserved)\n' "$name"
    PASS=$((PASS + 1))
    return 0
  else
    printf '  ✗ %s: %s\n' "$name" "$fail_reason"
    FAIL=$((FAIL + 1))
    return 1
  fi
}

# assert_km_unchanged_with_stderr_match(name, km_path, expected_pre_content_str, captured_stderr_str, stderr_regex)
assert_km_unchanged_with_stderr_match() {
  local name=$1
  local km_path=$2
  local expected_pre=$3
  local captured_stderr=$4
  local stderr_regex=$5
  local got
  got=$(cat "$km_path" 2>/dev/null)
  if [[ "$got" != "$expected_pre" ]]; then
    printf '  ✗ %s: km bytes mutated (pre=%q post=%q)\n' "$name" "$expected_pre" "$got"
    FAIL=$((FAIL + 1))
    return 1
  fi
  if ! echo "$captured_stderr" | grep -qE "$stderr_regex"; then
    printf '  ✗ %s: captured stderr does not match REJECT regex /%s/ (got: %q)\n' \
      "$name" "$stderr_regex" "$captured_stderr"
    FAIL=$((FAIL + 1))
    return 1
  fi
  printf '  ✓ %s (km bytes-identical pre→post + stderr matches REJECT regex)\n' "$name"
  PASS=$((PASS + 1))
  return 0
}

# assert_km_installlocation_only_rewritten(name, km_path, original_il_value, expected_other_keys_space_sep, pre_snap_dir)
assert_km_installlocation_only_rewritten() {
  local name=$1
  local km_path=$2
  local original_il=$3
  local expected_other_keys=$4
  local pre_snap_dir=$5
  local local_pass=1
  local fail_reason=""

  if [[ ! -f "$km_path" ]] || ! jq -e . "$km_path" >/dev/null 2>&1; then
    printf '  ✗ %s: km file missing or unparseable post-heal\n' "$name"
    FAIL=$((FAIL + 1))
    return 1
  fi

  local new_il dhx_source dhx_path
  new_il=$(jq -r '."dhx-local".installLocation // empty' "$km_path" 2>/dev/null)
  dhx_source=$(jq -r '."dhx-local".source.source // empty' "$km_path" 2>/dev/null)
  dhx_path=$(jq -r '."dhx-local".source.path // empty' "$km_path" 2>/dev/null)

  if [[ "$new_il" == "$original_il" ]]; then
    fail_reason="installLocation unchanged (still '$original_il') — expected rewrite"
    local_pass=0
  elif [[ -z "$new_il" ]]; then
    fail_reason="installLocation emptied (expected non-empty new value)"
    local_pass=0
  elif [[ "$dhx_source" != "directory" ]]; then
    fail_reason="dhx-local.source.source mutated (got '$dhx_source'; expected 'directory')"
    local_pass=0
  elif [[ -z "$dhx_path" ]]; then
    fail_reason="dhx-local.source.path mutated to empty"
    local_pass=0
  fi

  if (( local_pass )); then
    # G-04 byte-preservation on other-marketplace keys.
    local k pre_snap post_snap pre_bytes
    for k in $expected_other_keys; do
      pre_snap="$pre_snap_dir/$k.json"
      if [[ ! -f "$pre_snap" ]]; then
        fail_reason="pre-snapshot missing for key '$k' at $pre_snap"
        local_pass=0
        break
      fi
      if ! jq -e --arg k "$k" '.[$k]' "$km_path" >/dev/null 2>&1; then
        fail_reason="key '$k' missing from km post-heal (expected byte-preservation)"
        local_pass=0
        break
      fi
      post_snap=$(jq -c --arg k "$k" '.[$k]' "$km_path" 2>/dev/null)
      pre_bytes=$(cat "$pre_snap" 2>/dev/null)
      if [[ "$post_snap" != "$pre_bytes" ]]; then
        fail_reason="key '$k' bytes diverged (pre=$pre_bytes post=$post_snap)"
        local_pass=0
        break
      fi
    done
  fi

  if (( local_pass )); then
    printf '  ✓ %s (installLocation rewritten; source.source/source.path + other keys byte-preserved)\n' "$name"
    PASS=$((PASS + 1))
    return 0
  else
    printf '  ✗ %s: %s\n' "$name" "$fail_reason"
    FAIL=$((FAIL + 1))
    return 1
  fi
}

echo "=== dhx-plugin-registry-heal.sh — 13 scenarios (8 IP no-op regression + 5 km active heal including scenario 13 bad-installlocation-rejected under Pattern B) ==="

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

# ============================================================================
# Phase 10 D-08 — IP-noop-regression-preserved (umbrella label)
# ============================================================================
# The 8 scenarios above stay verbatim as Phase 10's explicit guard that the
# retired IP path stays retired. If a future commit reintroduces IP heal logic
# inadvertently, scenarios 1-8 catch it here.
# ============================================================================

# ---- 9. km-uninstalled-dhx-local-healed (D-08 + D-11 + G-04 + G-05) ----
# Fixture: anthropic-agent-skills + claude-plugins-official present; dhx-local ABSENT.
# Settings seeded inside $CONFIG_DIR with extraKnownMarketplaces.dhx-local so heal
# traverses past the D-11 settings-missing branch. Heal must seed dhx-local AND
# preserve the two other-marketplace entries BYTE-IDENTICAL (G-04 helper).
# G-05: emit the EXPECT state token BEFORE assertions (one line per active scenario).
echo "EXPECT: HEAL-uninstalled-dhx-local"
KM_OTHERS='{"anthropic-agent-skills":{"source":{"source":"github","repo":"anthropics/agent-skills"},"installLocation":"/fake/aas","lastUpdated":"2026-01-01T00:00:00.000Z"},"claude-plugins-official":{"source":{"source":"github","repo":"anthropics/claude-plugins"},"installLocation":"/fake/cpo","lastUpdated":"2026-01-01T00:00:00.000Z"}}'
cfg=$(make_case "km-uninstalled-dhx-local-healed" "NONE" 1 0.1.0 "$KM_OTHERS")
home_for_case=$(dirname "$cfg")
# Seed settings.json INSIDE $CONFIG_DIR with dhx-local entry so heal sees it declared.
cat > "$cfg/settings.json" <<JSON
{"extraKnownMarketplaces":{"dhx-local":{"source":{"source":"directory","path":"$home_for_case/.ccs/instances/probe/plugins/marketplaces/dhx-local"}}}}
JSON
# Capture pre-heal byte snapshots for G-04 byte-preservation assertion.
pre_snap_dir="$TMPROOT/km-uninstalled-dhx-local-healed.snap"
mkdir -p "$pre_snap_dir"
km_path="$cfg/plugins/known_marketplaces.json"
for k in anthropic-agent-skills claude-plugins-official; do
  jq -c --arg k "$k" '.[$k]' "$km_path" > "$pre_snap_dir/$k.json"
done
run_hook "$cfg" >/dev/null
assert_km_dhx_local_healed \
  "km-uninstalled-dhx-local-healed: heal seeds dhx-local; other keys byte-preserved (G-04)" \
  "$km_path" "$home_for_case" "anthropic-agent-skills claude-plugins-official" "$pre_snap_dir"

# ---- 10. km-stale-installlocation-rederived (D-04 4th state + D-08 + G-04 + G-05) ----
# Fixture: all three marketplace entries; dhx-local has bogus installLocation
# /nonexistent/stale/path. Heal must rewrite ONLY that field (preserving
# source.source, source.path, anthropic-agent-skills, claude-plugins-official).
echo "EXPECT: HEAL-stale-installlocation"
STALE_IL='/nonexistent/stale/path'
KM_STALE='{"dhx-local":{"source":{"source":"directory","path":"'"$TMPROOT"'/km-stale-il/.ccs/instances/probe/plugins/marketplaces/dhx-local"},"installLocation":"'"$STALE_IL"'","lastUpdated":"2026-01-01T00:00:00.000Z"},"anthropic-agent-skills":{"source":{"source":"github","repo":"anthropics/agent-skills"},"installLocation":"/fake/aas","lastUpdated":"2026-01-01T00:00:00.000Z"},"claude-plugins-official":{"source":{"source":"github","repo":"anthropics/claude-plugins"},"installLocation":"/fake/cpo","lastUpdated":"2026-01-01T00:00:00.000Z"}}'
cfg=$(make_case "km-stale-il" "NONE" 1 0.1.0 "$KM_STALE")
home_for_case=$(dirname "$cfg")
cat > "$cfg/settings.json" <<JSON
{"extraKnownMarketplaces":{"dhx-local":{"source":{"source":"directory","path":"$home_for_case/.ccs/instances/probe/plugins/marketplaces/dhx-local"}}}}
JSON
pre_snap_dir="$TMPROOT/km-stale-il.snap"
mkdir -p "$pre_snap_dir"
km_path="$cfg/plugins/known_marketplaces.json"
for k in anthropic-agent-skills claude-plugins-official; do
  jq -c --arg k "$k" '.[$k]' "$km_path" > "$pre_snap_dir/$k.json"
done
run_hook "$cfg" >/dev/null
assert_km_installlocation_only_rewritten \
  "km-stale-il: installLocation rewritten; source fields + other keys byte-preserved (G-04)" \
  "$km_path" "$STALE_IL" "anthropic-agent-skills claude-plugins-official" "$pre_snap_dir"

# ---- 11. hostile-config-dir-rejected (D-02 (a) symlink-chain-crossing REJECT + G-05) ----
# Canonical Phase 3 spike attack vector: sandbox $CONFIG_DIR points at an
# attacker-controlled tree whose `plugins` subdir is a symlink chain into the
# REAL operator's `~/.claude/plugins`. Heal's (a) realpath check MUST refuse
# before any write. We construct $HOSTILE_HOME and $HOSTILE_CFG both rooted
# inside $TMPROOT (containment); even if (a) check were missing, any write
# lands inside $TMPROOT — never the operator's live state.
#
# Scenario emits THREE inline assertions:
#  (1) rc != 0   — heal refused the write
#  (2) stderr matches REJECT regex with structured prefix
#  (3) live victim km bytes-identical sha256 pre→post (no symlink-chain write)
#
# Phase 10 active heal: (1) heal refused (rc=1), (2) structured REJECT stderr,
# (3) live victim km bytes-identical pre→post sha256 invariant (no write).
echo "EXPECT: REJECT-symlink-crossing"
HOSTILE_HOME="$TMPROOT/hostile-cfg-test/home"
HOSTILE_CFG="$TMPROOT/hostile-cfg-test/cfg"
mkdir -p "$HOSTILE_HOME/.claude/plugins" "$HOSTILE_CFG"
# Pre-populate live victim km inside the operator's "real" tree analog.
KM_LIVE='{"anthropic-agent-skills":{"source":{"source":"github"},"installLocation":"/fake/aas"},"claude-plugins-official":{"source":{"source":"github"},"installLocation":"/fake/cpo"},"dhx-local":{"source":{"source":"directory","path":"/some/legit/path"},"installLocation":"'"$HOSTILE_HOME"'/.claude/plugins/marketplaces/dhx-local"}}'
mkdir -p "$HOSTILE_HOME/.claude/plugins/marketplaces/dhx-local"
printf '%s' "$KM_LIVE" > "$HOSTILE_HOME/.claude/plugins/known_marketplaces.json"
BEFORE_HASH=$(sha256sum "$HOSTILE_HOME/.claude/plugins/known_marketplaces.json" | awk '{print $1}')
# D-02 (a) attack: $HOSTILE_CFG/plugins symlinks into $HOSTILE_HOME/.claude/plugins.
# Heal opening "$CFG/plugins/known_marketplaces.json" follows through to the live victim.
ln -s "$HOSTILE_HOME/.claude/plugins" "$HOSTILE_CFG/plugins"
# Seed settings INSIDE the hostile CFG so heal traverses past settings-missing branch.
cat > "$HOSTILE_CFG/settings.json" <<JSON
{"extraKnownMarketplaces":{"dhx-local":{"source":{"source":"directory","path":"$HOSTILE_HOME/.claude/plugins/marketplaces/dhx-local"}}}}
JSON
# Invoke heal capturing stderr separately from $? — must NOT use run_hook (which
# swallows stderr and only returns rc); use a manual invocation with $? capture.
hostile_stderr=$(HOME="$HOSTILE_HOME" CLAUDE_CONFIG_DIR="$HOSTILE_CFG" bash "$HOOK" < /dev/null 2>&1 >/dev/null)
hostile_rc=$?
AFTER_HASH=$(sha256sum "$HOSTILE_HOME/.claude/plugins/known_marketplaces.json" | awk '{print $1}')
# Assertion 1 — rc != 0 (heal refused).
if [[ "$hostile_rc" != "0" ]]; then
  printf '  ✓ hostile-config-dir: heal returned non-zero (rc=%s)\n' "$hostile_rc"
  PASS=$((PASS + 1))
else
  printf '  ✗ hostile-config-dir: heal returned rc=0 (expected non-zero REJECT)\n'
  FAIL=$((FAIL + 1))
fi
# Assertion 2 — stderr matches REJECT regex (allow either "target km path resolves
# outside CONFIG_DIR" wording or the broader "REJECT: <reason>" framing). The
# canonical wording is documented above; Plan 2 lands the literal stderr message.
if echo "$hostile_stderr" | grep -qE '^dhx-plugin-registry-heal: REJECT: target km path resolves outside CONFIG_DIR'; then
  printf '  ✓ hostile-config-dir: stderr matches REJECT regex with structured prefix\n'
  PASS=$((PASS + 1))
else
  printf '  ✗ hostile-config-dir: stderr does not match REJECT regex (got: %q)\n' "$hostile_stderr"
  FAIL=$((FAIL + 1))
fi
# Assertion 3 — live victim km bytes-identical (sha256 invariant).
if [[ "$BEFORE_HASH" == "$AFTER_HASH" ]]; then
  printf '  ✓ hostile-config-dir: live km bytes-identical pre→post (sha256 invariant; no symlink-chain write)\n'
  PASS=$((PASS + 1))
else
  printf '  ✗ hostile-config-dir: TAINTED — live km bytes diverged (before=%s after=%s)\n' "$BEFORE_HASH" "$AFTER_HASH"
  FAIL=$((FAIL + 1))
fi

# ---- 12. semantic-validity-of-healed-entry (Codex Q2 + G-04 byte-preservation + G-05) ----
# Same fixture as scenario 9 (KM_OTHERS_PRE) — anthropic-agent-skills +
# claude-plugins-official present, dhx-local absent. Validates semantic-validity
# of the healed dhx-local entry (source.source == "directory", source.path
# non-empty, installLocation under allow-list). G-04 byte-preservation already
# inside the helper; an additional explicit `jq -c` byte-comparison loop
# INSIDE the scenario reasserts the G-04 contract using pre_snap_dir directly
# (defense-in-depth — ensures byte-preservation is verified even if the helper
# signature evolves).
echo "EXPECT: HEAL-semantic-validity"
KM_OTHERS_PRE='{"anthropic-agent-skills":{"source":{"source":"github","repo":"anthropics/agent-skills"},"installLocation":"/fake/aas","lastUpdated":"2026-01-01T00:00:00.000Z"},"claude-plugins-official":{"source":{"source":"github","repo":"anthropics/claude-plugins"},"installLocation":"/fake/cpo","lastUpdated":"2026-01-01T00:00:00.000Z"}}'
cfg=$(make_case "semantic-validity-of-healed-entry" "NONE" 1 0.1.0 "$KM_OTHERS_PRE")
home_for_case=$(dirname "$cfg")
cat > "$cfg/settings.json" <<JSON
{"extraKnownMarketplaces":{"dhx-local":{"source":{"source":"directory","path":"$home_for_case/.ccs/instances/probe/plugins/marketplaces/dhx-local"}}}}
JSON
pre_snap_dir="$TMPROOT/semantic-validity-of-healed-entry.snap"
mkdir -p "$pre_snap_dir"
km_path="$cfg/plugins/known_marketplaces.json"
for k in anthropic-agent-skills claude-plugins-official; do
  jq -c --arg k "$k" '.[$k]' "$km_path" > "$pre_snap_dir/$k.json"
done
run_hook "$cfg" >/dev/null
assert_km_dhx_local_healed \
  "semantic-validity-of-healed-entry: semantic-validity asserted; G-04 byte-preservation in helper" \
  "$km_path" "$home_for_case" "anthropic-agent-skills claude-plugins-official" "$pre_snap_dir"
# Defense-in-depth: explicit byte-comparison loop INSIDE the scenario.
sem_dod_pass=1
sem_dod_reason=""
if [[ -f "$km_path" ]] && jq -e . "$km_path" >/dev/null 2>&1; then
  for k in anthropic-agent-skills claude-plugins-official; do
    pre_bytes=$(cat "$pre_snap_dir/$k.json" 2>/dev/null)
    post_bytes=$(jq -c --arg k "$k" '.[$k]' "$km_path" 2>/dev/null)
    if [[ "$pre_bytes" != "$post_bytes" ]]; then
      sem_dod_reason="key '$k' bytes diverged in defense-in-depth recheck (pre=$pre_bytes post=$post_bytes)"
      sem_dod_pass=0
      break
    fi
  done
else
  sem_dod_reason="km file missing or unparseable in defense-in-depth recheck"
  sem_dod_pass=0
fi
if (( sem_dod_pass )); then
  printf '  ✓ semantic-validity (defense-in-depth recheck): other-marketplace keys byte-preserved\n'
  PASS=$((PASS + 1))
else
  printf '  ✗ semantic-validity (defense-in-depth recheck): %s\n' "$sem_dod_reason"
  FAIL=$((FAIL + 1))
fi

# ---- 12.5 km-badjson-warn-recovery (Phase 10 D-14 — minimal-km + WARN stderr substring) ----
# Fixture: settings declares dhx-local; km is intentionally corrupt JSON. Heal MUST
# (1) exit 0 (BADJSON recovery is not a refusal), (2) overwrite with a minimal km
# containing a parseable dhx-local entry, (3) emit the literal D-14 WARN substring
# on stderr signalling other-marketplace loss. Asserts the WARN substring is present
# via direct grep against captured stderr.
echo "EXPECT: HEAL-badjson-warn-recovery"
KM_BADJSON='not json {{{'
cfg=$(make_case "km-badjson-warn" "NONE" 1 0.1.0 "$KM_BADJSON")
home_for_case=$(dirname "$cfg")
cat > "$cfg/settings.json" <<JSON
{"extraKnownMarketplaces":{"dhx-local":{"source":{"source":"directory","path":"$home_for_case/.ccs/instances/probe/plugins/marketplaces/dhx-local"}}}}
JSON
km_path="$cfg/plugins/known_marketplaces.json"
badjson_stderr=$(HOME="$home_for_case" CLAUDE_CONFIG_DIR="$cfg" bash "$HOOK" < /dev/null 2>&1 >/dev/null)
badjson_rc=$?
# Assertion 1 — rc 0 (BADJSON recovery is not a refusal).
if [[ "$badjson_rc" == "0" ]]; then
  printf '  ✓ km-badjson-warn-recovery: heal returned 0 (BADJSON recovery non-refusal)\n'
  PASS=$((PASS + 1))
else
  printf '  ✗ km-badjson-warn-recovery: heal returned rc=%s (expected 0)\n' "$badjson_rc"
  FAIL=$((FAIL + 1))
fi
# Assertion 2 — post-heal km parses + has dhx-local entry.
if jq -e '."dhx-local"' "$km_path" >/dev/null 2>&1; then
  printf '  ✓ km-badjson-warn-recovery: post-heal km parses + dhx-local entry present\n'
  PASS=$((PASS + 1))
else
  printf '  ✗ km-badjson-warn-recovery: post-heal km unparseable or missing dhx-local\n'
  FAIL=$((FAIL + 1))
fi
# Assertion 3 — D-14 WARN literal substring on captured stderr.
if echo "$badjson_stderr" | grep -qF "WARN: BADJSON recovery"; then
  printf '  ✓ km-badjson-warn-recovery: WARN substring present on stderr (D-14)\n'
  PASS=$((PASS + 1))
else
  printf '  ✗ km-badjson-warn-recovery: WARN substring missing from stderr (got: %q)\n' "$badjson_stderr"
  FAIL=$((FAIL + 1))
fi

# ---- 13. bad-installlocation-rejected (Pattern B — D-02 (b) value-side REJECT exercised) ----
# Pattern B branch (per .planning/phases/10-heal-hook-km-path-hardening-heal-07/10-D-05-RESULT.md):
# CC 2.1.140's directory-source resolver writes installLocation == source.path
# LITERALLY. Heal re-derives NEW_IL as source.path verbatim. Settings poison
# fixture: source.path points to /tmp/poisoned-source which resolves OUTSIDE
# the D-03 allow-list ($HOME/.claude/plugins/marketplaces + $HOME/.ccs/instances/
# */plugins/marketplaces). Heal MUST refuse with structured REJECT stderr.
# Closes Blocker-B Option 3 (revision 2026-05-09): under Pattern A this scenario
# is omitted (NEW_IL bounded by construction inside allow-list); under Pattern B
# the (b) value-side check fires meaningfully on this fixture.
echo "EXPECT: REJECT-allow-list"
SETTINGS_BAD='{"enabledPlugins":{"dhx@dhx-local":true},"extraKnownMarketplaces":{"dhx-local":{"source":{"source":"directory","path":"/tmp/poisoned-source"}}}}'
# Pre-existing km with other-marketplace entries — heal must REFUSE before writing.
KM_BAD_PRE='{"anthropic-agent-skills":{"source":{"source":"github","repo":"anthropics/agent-skills"},"installLocation":"/fake/aas","lastUpdated":"2026-01-01T00:00:00.000Z"}}'
cfg=$(make_case "bad-il" "NONE" 1 0.1.0 "$KM_BAD_PRE")
home_for_case=$(dirname "$cfg")
# Settings INSIDE $CONFIG_DIR (settings-derived poison; NOT $HOME/.claude).
printf '%s' "$SETTINGS_BAD" > "$cfg/settings.json"
expected_pre=$(cat "$cfg/plugins/known_marketplaces.json")
stderr_captured=$(run_hook_capture_stderr "$cfg")
assert_km_unchanged_with_stderr_match \
  "bad-il: settings poison resolves outside allow-list — REJECT (Pattern B)" \
  "$cfg/plugins/known_marketplaces.json" "$expected_pre" "$stderr_captured" \
  '^dhx-plugin-registry-heal: REJECT:'

echo "---"
echo "PASS: $PASS  FAIL: $FAIL"
exit $FAIL
