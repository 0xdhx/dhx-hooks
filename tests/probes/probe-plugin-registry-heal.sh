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
# Assertions that could not run (e.g. no strace for the scope-guard arm). Reported
# on its own line when non-zero; the PASS/FAIL summary line keeps its exact shape
# so nothing parsing it has to change.
SKIPPED=0

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
# with a `.claude-plugin/marketplace.json` naming `dhx-local` so heal-side
# scenarios have a valid installLocation target candidate. Since 2026-09-14 the
# hook's (b) value-side guard is marketplace-manifest IDENTITY (dir exists +
# manifest parses + `.name == "dhx-local"`), not the retired D-03 roots prefix
# allow-list — the location under a marketplaces/ root is fixture legacy, not a
# requirement (scenarios 14-15 prove the live shape, outside any such root).
# seed_marketplace_manifest(dir, name) — writes the `.claude-plugin/marketplace.json`
# CC's `claude plugin marketplace add` reads to name a directory-source marketplace
# (2026-05-12 precheck § C: CC refused a dir without a valid manifest). The hook's
# (b) identity guard (2026-09-14) requires `.name` to equal "dhx-local".
seed_marketplace_manifest() {
  local dir=$1
  local name=$2
  mkdir -p "$dir/.claude-plugin"
  printf '{"name":"%s","owner":{"name":"probe","email":"probe@example.invalid"},"plugins":[]}' "$name" \
    > "$dir/.claude-plugin/marketplace.json"
}

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
  # Phase 10: seed a CCS-instance-shaped installLocation candidate; 2026-09-14:
  # seed_marketplace_manifest gives it the named manifest the identity guard reads.
  mkdir -p "$home/.ccs/instances/probe/plugins/marketplaces/dhx-local"
  seed_marketplace_manifest "$home/.ccs/instances/probe/plugins/marketplaces/dhx-local" dhx-local
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
#     AND equals source.path (Pattern B — CC writes them identical for a
#     directory-source marketplace) AND that directory's
#     .claude-plugin/marketplace.json names "dhx-local" (2026-09-14 identity
#     guard; replaced the D-03 roots-prefix assertion that mirrored the hook's
#     retired allow-list).
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
  local home=$3  # retained for call-site stability; unused since the 2026-09-14 identity check
  local expected_other_keys=$4
  local pre_snap_dir=$5
  local local_pass=1
  local fail_reason=""
  : "$home"

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
    # Pattern B: installLocation == source.path, and the directory carries a
    # manifest naming dhx-local (the hook's (b) identity guard, 2026-09-14).
    local manifest_name
    manifest_name=$(jq -r '.name // empty' "$dhx_il/.claude-plugin/marketplace.json" 2>/dev/null)
    if [[ "$dhx_il" != "$dhx_path" ]]; then
      fail_reason="installLocation '$dhx_il' != source.path '$dhx_path' (Pattern B violated)"
      local_pass=0
    elif [[ "$manifest_name" != "dhx-local" ]]; then
      fail_reason="installLocation '$dhx_il' manifest names '$manifest_name' (expected dhx-local)"
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
  if ! grep -qE "$stderr_regex" <<< "$captured_stderr"; then
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

echo "=== dhx-plugin-registry-heal.sh — 28 scenarios (8 IP no-op regression + 20 km: 9-13 Phase 10, 14-17 live-shaped + identity guard 2026-09-14, 18-28 CC acceptance shape + lock + pre-launch surface 2026-09-15) ==="

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

# ---- 8. happy path: the scope guard early-exits, asserted BEHAVIOURALLY ----
# This arm used to FAIL when one wall-clock sample of the hook reached 100ms. It
# measured 128ms inside the pre-commit tier on 2026-09-18 and passed standalone
# minutes later, blocking every session's probe-touching commit in between.
#
# The threshold was never measuring the hook. Interleaved against bare `bash -c :`
# on this machine that day: idle 2ms/2ms, 2x-nproc 10ms/10ms, 8x-nproc 34ms/30ms —
# the hook costs LESS than starting the interpreter, and at 8x-nproc bare
# `bash -c :` alone peaked at 73ms. A 100ms absolute bound under load is a
# scheduler measurement wearing a hook's name, and docs/decisions.md's 2026-09-18
# SUITE_TIMEOUT row already ruled that a load-dependent red "trains its reader to
# ignore it".
#
# The claim this arm's own comment always made is "the scope guard early-exits
# before any check" — so assert THAT, by counting opens of the registry file.
# A syscall count does not move with load: measured 0 opens idle and 0 under
# 8x-nproc, against 1 for a hook that does read the file. The elapsed time is
# still printed, because a zero-opens assertion cannot see a hook that becomes
# slow without touching the file — but it never fails the probe again.
cfg=$(make_case "timing" "$HEALTHY_JSON")
t_start=$(date +%s%N)
HOME=$(dirname "$cfg") CLAUDE_CONFIG_DIR="$cfg" bash "$HOOK" < /dev/null >/dev/null 2>&1
t_end=$(date +%s%N)
elapsed_ms=$(( (t_end - t_start) / 1000000 ))

if command -v strace >/dev/null 2>&1 && strace -f -e trace=openat -o /dev/null true >/dev/null 2>&1; then
  # The control runs FIRST and in the same conditions: if a hook that genuinely
  # reads the registry shows zero opens, the instrument is broken and the real
  # assertion below would be a false green. Refuse to report either way then.
  ctl_hook="$(dirname "$cfg")/reads-the-registry.sh"
  printf '#!/usr/bin/env bash\ncat "$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json" >/dev/null 2>&1\n' > "$ctl_hook"
  ctl_trace=$(mktemp)
  HOME=$(dirname "$cfg") CLAUDE_CONFIG_DIR="$cfg" \
    strace -f -e trace=openat -o "$ctl_trace" bash "$ctl_hook" < /dev/null >/dev/null 2>&1
  ctl_opens=$(grep -c 'installed_plugins\.json' "$ctl_trace" 2>/dev/null || true)
  rm -f "$ctl_trace" "$ctl_hook"

  hook_trace=$(mktemp)
  HOME=$(dirname "$cfg") CLAUDE_CONFIG_DIR="$cfg" \
    strace -f -e trace=openat -o "$hook_trace" bash "$HOOK" < /dev/null >/dev/null 2>&1
  hook_opens=$(grep -c 'installed_plugins\.json' "$hook_trace" 2>/dev/null || true)
  rm -f "$hook_trace"

  if (( ctl_opens < 1 )); then
    printf '  ⚠ scope guard: SKIPPED — strace ran but the positive control saw 0 opens, so the instrument is not measuring; asserted nothing (elapsed %sms)\n' "$elapsed_ms"
    SKIPPED=$((SKIPPED + 1))
  elif (( hook_opens == 0 )); then
    printf '  ✓ scope guard: 0 opens of installed_plugins.json (control saw %s) — early-exit before any check; elapsed %sms, informational\n' "$ctl_opens" "$elapsed_ms"
    PASS=$((PASS + 1))
  else
    printf '  ✗ scope guard: %s opens of installed_plugins.json — the guard did NOT early-exit (elapsed %sms)\n' "$hook_opens" "$elapsed_ms"
    FAIL=$((FAIL + 1))
  fi
else
  # Loud, and counted. A skipped assertion that prints nothing is the same
  # false-green class this arm was rewritten to remove.
  printf '  ⚠ scope guard: SKIPPED — strace unavailable or ptrace denied; asserted nothing (elapsed %sms)\n' "$elapsed_ms"
  SKIPPED=$((SKIPPED + 1))
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
#
# 2026-09-14 healthy-first: the hook exits 0 on a HEALTHY km before any guard
# runs, so the victim's dhx-local installLocation is STALE (nonexistent) — the
# attack only matters when the heal wants to write, and that is the fixture
# now. The hostile source dir carries a named manifest so (a) is the sole
# refusal reason (the (b) identity guard would otherwise also fire, later).
echo "EXPECT: REJECT-symlink-crossing"
HOSTILE_HOME="$TMPROOT/hostile-cfg-test/home"
HOSTILE_CFG="$TMPROOT/hostile-cfg-test/cfg"
mkdir -p "$HOSTILE_HOME/.claude/plugins" "$HOSTILE_CFG"
# Pre-populate live victim km inside the operator's "real" tree analog.
KM_LIVE='{"anthropic-agent-skills":{"source":{"source":"github"},"installLocation":"/fake/aas"},"claude-plugins-official":{"source":{"source":"github"},"installLocation":"/fake/cpo"},"dhx-local":{"source":{"source":"directory","path":"/some/legit/path"},"installLocation":"/nonexistent/victim/stale"}}'
mkdir -p "$HOSTILE_HOME/.claude/plugins/marketplaces/dhx-local"
seed_marketplace_manifest "$HOSTILE_HOME/.claude/plugins/marketplaces/dhx-local" dhx-local
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
if grep -qE '^dhx-plugin-registry-heal: REJECT: target km path resolves outside CONFIG_DIR' <<< "$hostile_stderr"; then
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
if grep -qF "WARN: BADJSON recovery" <<< "$badjson_stderr"; then
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
# fixture: source.path points to /tmp/poisoned-source, which does not exist —
# since 2026-09-14 the (b) identity guard refuses it as "not a directory" (it
# used to fall outside the retired D-03 roots allow-list). Heal MUST refuse
# with structured REJECT stderr. km is MISSING dhx-local so the healthy-first
# hook reaches the mutation path.
# Closes Blocker-B Option 3 (revision 2026-05-09): under Pattern A this scenario
# is omitted (NEW_IL bounded by construction inside allow-list); under Pattern B
# the (b) value-side check fires meaningfully on this fixture.
echo "EXPECT: REJECT-identity-nonexistent"
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
  "bad-il: settings poison names a nonexistent directory — REJECT (Pattern B, identity guard)" \
  "$cfg/plugins/known_marketplaces.json" "$expected_pre" "$stderr_captured" \
  '^dhx-plugin-registry-heal: REJECT:'

# ============================================================================
# 2026-09-14 — live-shaped fixtures + identity guard (docs/decisions.md 2026-09-14)
# ============================================================================
# Every Phase 10 fixture above put source.path under a fake marketplaces/ root —
# a shape the live host never had (the live source is the repo checkout,
# /home/dhx/repos/hooks/dhx-plugin, since 44a8155e 2026-04-16), so the probe was
# green 21/21 while the hook REJECTed on every real SessionStart for four months.
# Scenarios 14-15 fire the hook at the live shape; 16-17 pin the identity guard's
# actual boundary (what it refuses, so nobody mistakes it for a security belt).
# ============================================================================

# ---- 14. live-shape-healthy-silent (healthy-first; the brief's acceptance criterion) ----
# Fixture: source.path is a real directory OUTSIDE any marketplaces/ root, with a
# manifest naming dhx-local; km is HEALTHY with installLocation == source.path
# (Pattern B). Hook MUST exit 0, emit NOTHING on stderr, and leave km byte-identical.
echo "EXPECT: HEALTHY-live-shape-silent"
cfg=$(make_case "live-healthy" "NONE" 1 0.1.0 "NONE")
home_for_case=$(dirname "$cfg")
LIVE_SRC="$home_for_case/repos/hooks/dhx-plugin"
seed_marketplace_manifest "$LIVE_SRC" dhx-local
cat > "$cfg/settings.json" <<JSON
{"extraKnownMarketplaces":{"dhx-local":{"source":{"source":"directory","path":"$LIVE_SRC"}}}}
JSON
KM_LIVE_SHAPE='{"claude-plugins-official":{"source":{"source":"github","repo":"anthropics/claude-plugins"},"installLocation":"/fake/cpo","lastUpdated":"2026-01-01T00:00:00.000Z"},"dhx-local":{"source":{"source":"directory","path":"'"$LIVE_SRC"'"},"installLocation":"'"$LIVE_SRC"'","lastUpdated":"2026-09-13T08:10:05.466Z"}}'
km_path="$cfg/plugins/known_marketplaces.json"
printf '%s' "$KM_LIVE_SHAPE" > "$km_path"
before_hash=$(sha256sum "$km_path" | awk '{print $1}')
live_stderr=$(HOME="$home_for_case" CLAUDE_CONFIG_DIR="$cfg" bash "$HOOK" < /dev/null 2>&1 >/dev/null)
live_rc=$?
after_hash=$(sha256sum "$km_path" | awk '{print $1}')
if [[ "$live_rc" == "0" && -z "$live_stderr" && "$before_hash" == "$after_hash" ]]; then
  printf '  ✓ live-healthy: rc 0, empty stderr, km sha256-identical (source outside marketplaces/)\n'
  PASS=$((PASS + 1))
else
  printf '  ✗ live-healthy: rc=%s stderr=%q km-changed=%s\n' "$live_rc" "$live_stderr" "$([[ "$before_hash" != "$after_hash" ]] && echo yes || echo no)"
  FAIL=$((FAIL + 1))
fi

# ---- 15. live-shape-stale-healed (the guard passes the live shape on the WRITE path) ----
# Same live shape, but km's dhx-local installLocation is stale (nonexistent).
# Hook MUST rewrite ONLY installLocation to source.path; other keys byte-preserved.
echo "EXPECT: HEAL-live-shape-stale"
cfg=$(make_case "live-stale" "NONE" 1 0.1.0 "NONE")
home_for_case=$(dirname "$cfg")
LIVE_SRC="$home_for_case/repos/hooks/dhx-plugin"
seed_marketplace_manifest "$LIVE_SRC" dhx-local
cat > "$cfg/settings.json" <<JSON
{"extraKnownMarketplaces":{"dhx-local":{"source":{"source":"directory","path":"$LIVE_SRC"}}}}
JSON
STALE_LIVE_IL='/nonexistent/live/stale'
KM_LIVE_STALE='{"claude-plugins-official":{"source":{"source":"github","repo":"anthropics/claude-plugins"},"installLocation":"/fake/cpo","lastUpdated":"2026-01-01T00:00:00.000Z"},"dhx-local":{"source":{"source":"directory","path":"'"$LIVE_SRC"'"},"installLocation":"'"$STALE_LIVE_IL"'","lastUpdated":"2026-01-01T00:00:00.000Z"}}'
km_path="$cfg/plugins/known_marketplaces.json"
printf '%s' "$KM_LIVE_STALE" > "$km_path"
pre_snap_dir="$TMPROOT/live-stale.snap"
mkdir -p "$pre_snap_dir"
jq -c '.["claude-plugins-official"]' "$km_path" > "$pre_snap_dir/claude-plugins-official.json"
run_hook "$cfg" >/dev/null
assert_km_installlocation_only_rewritten \
  "live-stale: installLocation rewritten to source.path outside marketplaces/; other keys byte-preserved" \
  "$km_path" "$STALE_LIVE_IL" "claude-plugins-official" "$pre_snap_dir"
healed_il=$(jq -r '."dhx-local".installLocation // empty' "$km_path" 2>/dev/null)
if [[ "$healed_il" == "$LIVE_SRC" ]]; then
  printf '  ✓ live-stale: healed installLocation == source.path (Pattern B)\n'
  PASS=$((PASS + 1))
else
  printf '  ✗ live-stale: healed installLocation %q != source.path %q\n' "$healed_il" "$LIVE_SRC"
  FAIL=$((FAIL + 1))
fi

# ---- 16. wrong-identity-rejected (the guard's real boundary: an EXISTING dir, wrong marketplace) ----
# Fixture: source.path is a real directory with a manifest naming "other-market";
# km MISSING dhx-local so the mutation path is reached. Hook MUST refuse with the
# identity REJECT and leave km byte-identical. This is the case a presence-only
# check would have accepted.
echo "EXPECT: REJECT-identity-wrong-name"
cfg=$(make_case "wrong-identity" "NONE" 1 0.1.0 "$KM_BAD_PRE")
home_for_case=$(dirname "$cfg")
OTHER_SRC="$home_for_case/repos/other-market"
seed_marketplace_manifest "$OTHER_SRC" other-market
cat > "$cfg/settings.json" <<JSON
{"extraKnownMarketplaces":{"dhx-local":{"source":{"source":"directory","path":"$OTHER_SRC"}}}}
JSON
expected_pre=$(cat "$cfg/plugins/known_marketplaces.json")
stderr_captured=$(run_hook_capture_stderr "$cfg")
assert_km_unchanged_with_stderr_match \
  "wrong-identity: existing dir whose manifest names another marketplace — REJECT" \
  "$cfg/plugins/known_marketplaces.json" "$expected_pre" "$stderr_captured" \
  "^dhx-plugin-registry-heal: REJECT: marketplace manifest names 'other-market', expected 'dhx-local'"

# ---- 17. malformed-manifest-rejected (existing dir, unparseable manifest) ----
echo "EXPECT: REJECT-identity-malformed"
cfg=$(make_case "malformed-manifest" "NONE" 1 0.1.0 "$KM_BAD_PRE")
home_for_case=$(dirname "$cfg")
BAD_SRC="$home_for_case/repos/bad-manifest"
mkdir -p "$BAD_SRC/.claude-plugin"
printf 'not json {{{' > "$BAD_SRC/.claude-plugin/marketplace.json"
cat > "$cfg/settings.json" <<JSON
{"extraKnownMarketplaces":{"dhx-local":{"source":{"source":"directory","path":"$BAD_SRC"}}}}
JSON
expected_pre=$(cat "$cfg/plugins/known_marketplaces.json")
stderr_captured=$(run_hook_capture_stderr "$cfg")
assert_km_unchanged_with_stderr_match \
  "malformed-manifest: existing dir with unparseable manifest — REJECT" \
  "$cfg/plugins/known_marketplaces.json" "$expected_pre" "$stderr_captured" \
  '^dhx-plugin-registry-heal: REJECT: marketplace manifest unparseable or unnamed'

# ============================================================================
# 2026-09-15 — CC acceptance shape, whole-file detector, lock, pre-launch surface
# (docs/decisions.md 2026-09-15 pre-launch row)
# ============================================================================
# CC 2.1.272 rejects the WHOLE km when any entry lacks a string lastUpdated — zero plugins
# load — and the Phase 10 heal wrote exactly that shape for UNREADABLE / MISSING / BADJSON
# while every jq-level assertion above stayed green. These scenarios pin the accepted shape
# hermetically; the real-binary check of the same outputs is
# probe-known-marketplaces-natural-heal.sh (operator-run, and once per installed CC version
# via dhx/dhx-km-acceptance.sh).
# ============================================================================

# assert_all_entries_timestamped(name, km_path)
assert_all_entries_timestamped() {
  local name=$1
  local km_path=$2
  if jq -e 'type == "object" and ([.[] | type == "object" and ((.lastUpdated | type) == "string")] | all)' \
       "$km_path" >/dev/null 2>&1; then
    printf '  ✓ %s (every entry carries a string lastUpdated)\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  ✗ %s: entries without a string lastUpdated: %s\n' "$name" \
      "$(jq -c '[to_entries[] | select((.value.lastUpdated | type) != "string") | .key]' "$km_path" 2>/dev/null)"
    FAIL=$((FAIL + 1))
  fi
}

# check(name, condition-exit-status) — one assertion from a test already evaluated.
check() {
  local name=$1
  local status=$2
  if [[ "$status" == "0" ]]; then
    printf '  ✓ %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  ✗ %s\n' "$name"
    FAIL=$((FAIL + 1))
  fi
}

# live_case(name) — live-shaped fixture: source.path is a real dir outside any
# marketplaces/ root with a manifest naming dhx-local; settings declare it; no km yet.
live_case() {
  local cfg home src
  cfg=$(make_case "$1" "NONE" 1 0.1.0 "NONE")
  home=$(dirname "$cfg")
  src="$home/repos/hooks/dhx-plugin"
  seed_marketplace_manifest "$src" dhx-local
  printf '{"extraKnownMarketplaces":{"dhx-local":{"source":{"source":"directory","path":"%s"}}}}' "$src" \
    > "$cfg/settings.json"
  printf '%s' "$cfg"
}

run_hook_prelaunch_stderr() {
  local cfg=$1
  local home
  home=$(dirname "$cfg")
  HOME="$home" CLAUDE_CONFIG_DIR="$cfg" DHX_REGISTRY_HEAL_SURFACE=prelaunch bash "$HOOK" < /dev/null 2>&1 >/dev/null
}

OFFICIAL_ENTRY='"claude-plugins-official":{"source":{"source":"github","repo":"anthropics/claude-plugins"},"installLocation":"/fake/cpo","lastUpdated":"2026-01-01T00:00:00.000Z"}'

# ---- 18. unreadable-healed-timestamped: absent km → dhx-local seeded WITH lastUpdated; lock released ----
echo "EXPECT: HEAL-unreadable-timestamped"
cfg=$(live_case "ts-unreadable")
km_path="$cfg/plugins/known_marketplaces.json"
run_hook "$cfg" >/dev/null
assert_km_dhx_local_healed "ts-unreadable: absent km → dhx-local seeded (Pattern B)" \
  "$km_path" "$(dirname "$cfg")" "" "$TMPROOT"
assert_all_entries_timestamped "ts-unreadable" "$km_path"
[[ ! -e "$km_path.lock" ]]; check "ts-unreadable: lock directory released after the write" $?

# ---- 19. missing-healed-timestamped: dhx-local absent beside a CC-written entry ----
echo "EXPECT: HEAL-missing-timestamped"
cfg=$(live_case "ts-missing")
km_path="$cfg/plugins/known_marketplaces.json"
printf '{%s}' "$OFFICIAL_ENTRY" > "$km_path"
pre_snap_dir="$TMPROOT/ts-missing.snap"
mkdir -p "$pre_snap_dir"
jq -c '.["claude-plugins-official"]' "$km_path" > "$pre_snap_dir/claude-plugins-official.json"
run_hook "$cfg" >/dev/null
assert_km_dhx_local_healed "ts-missing: dhx-local added; official entry byte-preserved" \
  "$km_path" "$(dirname "$cfg")" "claude-plugins-official" "$pre_snap_dir"
assert_all_entries_timestamped "ts-missing" "$km_path"

# ---- 20. badjson-healed-timestamped: minimal km still carries lastUpdated ----
echo "EXPECT: HEAL-badjson-timestamped"
cfg=$(live_case "ts-badjson")
km_path="$cfg/plugins/known_marketplaces.json"
printf '%s' '{"version": 2, "marke' > "$km_path"
ts_badjson_stderr=$(HOME="$(dirname "$cfg")" CLAUDE_CONFIG_DIR="$cfg" bash "$HOOK" < /dev/null 2>&1 >/dev/null)
grep -qF "WARN: BADJSON recovery" <<< "$ts_badjson_stderr"; check "ts-badjson: WARN on stderr (default surface)" $?
assert_all_entries_timestamped "ts-badjson" "$km_path"

# ---- 21. no-timestamp-dhx-local: the 2026-09-14 live damage shape (dir exists, no lastUpdated) ----
# The pre-2026-09-15 detector called this HEALTHY and never repaired it (measured on the damaged
# ~/.claude file: rc 0, bytes unchanged).
echo "EXPECT: HEAL-no-timestamp-dhx-local"
cfg=$(live_case "no-ts-dhx")
src="$(dirname "$cfg")/repos/hooks/dhx-plugin"
km_path="$cfg/plugins/known_marketplaces.json"
printf '{%s,"dhx-local":{"source":{"source":"directory","path":"%s"},"installLocation":"%s"}}' \
  "$OFFICIAL_ENTRY" "$src" "$src" > "$km_path"
pre_snap_dir="$TMPROOT/no-ts-dhx.snap"
mkdir -p "$pre_snap_dir"
jq -c '.["claude-plugins-official"]' "$km_path" > "$pre_snap_dir/claude-plugins-official.json"
rc=$(run_hook "$cfg")
[[ "$rc" == "0" ]]; check "no-ts-dhx: exit 0" $?
assert_km_dhx_local_healed "no-ts-dhx: installLocation kept; official entry byte-preserved" \
  "$km_path" "$(dirname "$cfg")" "claude-plugins-official" "$pre_snap_dir"
assert_all_entries_timestamped "no-ts-dhx" "$km_path"

# ---- 22. no-timestamp-other-marketplace: rejection is file-wide, so another entry is repaired too ----
echo "EXPECT: HEAL-no-timestamp-other"
cfg=$(live_case "no-ts-other")
src="$(dirname "$cfg")/repos/hooks/dhx-plugin"
km_path="$cfg/plugins/known_marketplaces.json"
printf '{"dhx-local":{"source":{"source":"directory","path":"%s"},"installLocation":"%s","lastUpdated":"2026-01-01T00:00:00.000Z"},"other":{"source":{"source":"github","repo":"a/b"},"installLocation":"/fake/other","autoUpdate":true}}' \
  "$src" "$src" > "$km_path"
pre_other=$(jq -c '.other' "$km_path")
pre_dhx=$(jq -c '."dhx-local"' "$km_path")
run_hook "$cfg" >/dev/null
assert_all_entries_timestamped "no-ts-other" "$km_path"
[[ "$(jq -c '.other | del(.lastUpdated)' "$km_path" 2>/dev/null)" == "$pre_other" ]]
check "no-ts-other: other entry gains only lastUpdated (every other field identical)" $?
[[ "$(jq -c '."dhx-local"' "$km_path" 2>/dev/null)" == "$pre_dhx" ]]
check "no-ts-other: dhx-local entry byte-preserved" $?

# ---- 23. empty-installlocation-rederived ----
echo "EXPECT: HEAL-empty-installlocation"
cfg=$(live_case "empty-il")
src="$(dirname "$cfg")/repos/hooks/dhx-plugin"
km_path="$cfg/plugins/known_marketplaces.json"
printf '{%s,"dhx-local":{"source":{"source":"directory","path":"%s"},"installLocation":"","lastUpdated":"2026-01-01T00:00:00.000Z"}}' \
  "$OFFICIAL_ENTRY" "$src" > "$km_path"
pre_snap_dir="$TMPROOT/empty-il.snap"
mkdir -p "$pre_snap_dir"
jq -c '.["claude-plugins-official"]' "$km_path" > "$pre_snap_dir/claude-plugins-official.json"
run_hook "$cfg" >/dev/null
assert_km_installlocation_only_rewritten "empty-il: empty installLocation rewritten; other keys byte-preserved" \
  "$km_path" "" "claude-plugins-official" "$pre_snap_dir"
[[ "$(jq -r '."dhx-local".installLocation' "$km_path" 2>/dev/null)" == "$src" ]]
check "empty-il: installLocation == source.path" $?

# ---- 24. lock-held-fresh-contention: CC's lock dir is fresh → no write, lock untouched, CONTENTION logged ----
echo "EXPECT: CONTENTION-fresh-lock"
cfg=$(live_case "lock-fresh")
km_path="$cfg/plugins/known_marketplaces.json"
printf '{}' > "$km_path"
mkdir "$km_path.lock"
before_hash=$(sha256sum "$km_path" | awk '{print $1}')
rc=$(run_hook "$cfg")
[[ "$rc" == "0" ]]; check "lock-fresh: exit 0 (contention is not a failure)" $?
[[ "$(sha256sum "$km_path" | awk '{print $1}')" == "$before_hash" ]]; check "lock-fresh: km byte-identical" $?
[[ -d "$km_path.lock" ]]; check "lock-fresh: the other writer's lock directory is left in place" $?
[[ "$(tail -n1 "$(dirname "$cfg")/.cache/dhx/hooks/registry-heal.log" 2>/dev/null | cut -f3)" == "CONTENTION" ]]
check "lock-fresh: CONTENTION logged" $?

# ---- 25. lock-stale-taken-over: lock dir older than CC's 10 s stale window → taken over, repaired, released ----
echo "EXPECT: HEAL-stale-lock-takeover"
cfg=$(live_case "lock-stale")
km_path="$cfg/plugins/known_marketplaces.json"
printf '{}' > "$km_path"
mkdir "$km_path.lock"
touch -d '-60 seconds' "$km_path.lock"
run_hook "$cfg" >/dev/null
jq -e '."dhx-local"' "$km_path" >/dev/null 2>&1; check "lock-stale: dhx-local repaired after takeover" $?
[[ ! -e "$km_path.lock" ]]; check "lock-stale: lock directory released" $?

# ---- 26. prelaunch-first-sight: one line per distinct outcome; repeats silent; HEALTHY re-arms ----
echo "EXPECT: SURFACE-prelaunch-first-sight"
cfg=$(live_case "surface")
km_path="$cfg/plugins/known_marketplaces.json"
surface_counts=""
for step in break break healthy break; do
  [[ "$step" == "break" ]] && printf '{}' > "$km_path"
  e=$(run_hook_prelaunch_stderr "$cfg")
  surface_counts="$surface_counts$(printf '%s' "$e" | grep -c .)"
done
[[ "$surface_counts" == "1001" ]]
check "surface: stderr lines per step break,break,healthy,break = 1,0,0,1 (got $surface_counts)" $?
[[ "$(grep -c $'\tREPAIRED\t' "$(dirname "$cfg")/.cache/dhx/hooks/registry-heal.log" 2>/dev/null)" == "3" ]]
check "surface: every repair logged, printed or not (3 REPAIRED lines)" $?

# ---- 27. prelaunch-reject-once: a refusal prints once per config dir, exits 1 every time ----
echo "EXPECT: SURFACE-prelaunch-reject-once"
cfg=$(make_case "reject-once" "NONE" 1 0.1.0 '{}')
printf '{"extraKnownMarketplaces":{"dhx-local":{"source":{"source":"directory","path":"/nonexistent/reject-once"}}}}' \
  > "$cfg/settings.json"
e1=$(run_hook_prelaunch_stderr "$cfg"); rc1=$?
e2=$(run_hook_prelaunch_stderr "$cfg"); rc2=$?
[[ "$rc1" == "1" && "$rc2" == "1" ]]; check "reject-once: exit 1 on both runs" $?
[[ "$(printf '%s' "$e1" | grep -c 'REJECT: installLocation is not a directory')" == "1" && -z "$e2" ]]
check "reject-once: REJECT printed on the first run only" $?

# ---- 28. non-object-entry-badjson: a non-object entry fails CC's schema like a parse error ----
echo "EXPECT: HEAL-non-object-entry"
cfg=$(live_case "non-object")
src="$(dirname "$cfg")/repos/hooks/dhx-plugin"
km_path="$cfg/plugins/known_marketplaces.json"
printf '{"dhx-local":{"source":{"source":"directory","path":"%s"},"installLocation":"%s","lastUpdated":"2026-01-01T00:00:00.000Z"},"junk":5}' \
  "$src" "$src" > "$km_path"
junk_stderr=$(HOME="$(dirname "$cfg")" CLAUDE_CONFIG_DIR="$cfg" bash "$HOOK" < /dev/null 2>&1 >/dev/null)
grep -qF "WARN: BADJSON recovery" <<< "$junk_stderr"; check "non-object: treated as BADJSON (WARN)" $?
jq -e 'has("junk") | not' "$km_path" >/dev/null 2>&1; check "non-object: junk entry gone" $?
assert_all_entries_timestamped "non-object" "$km_path"

echo "---"
echo "PASS: $PASS  FAIL: $FAIL"
(( SKIPPED > 0 )) && echo "SKIPPED: $SKIPPED  (assertions that could not run — see the ⚠ lines above)"
exit $FAIL
