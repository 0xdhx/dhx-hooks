#!/bin/bash
# Probe: hooks.json wiring canary in dhx-health-check.sh.
#
#
# Invariants exercised:
#   1. hooks_wiring="ok" when every dhx-script command in the manifest is
#      symlinked at $DHX_HOOKS_INSTALL_DIR/<basename> AND each symlink resolves
#      back to the dhx repo source.
#   2. hooks_wiring="BROKEN:<n>" with the right count when symlinks are missing
#      (1, 3 broken).
#   3. Manifest entries that resolve under a NON-dhx path (e.g., the dispatcher
#      under dhx-plugin/, gsd scripts) check disk-presence only — symlink check
#      is skipped, NOT counted.
#   4. hooks_wiring="ok" when DHX_HOOKS_MANIFEST points at an absent file
#      (don't false-positive a fresh-clone state where the manifest hasn't been
#      generated yet).
#   5. hooks_wiring="BROKEN:1" when a dhx symlink exists but resolves to the
#      wrong target (e.g., a moved/renamed file).
#
# Fixture isolation: every case uses a fake $HOME under TMPDIR plus three env-
# var overrides (DHX_HOOKS_MANIFEST, DHX_HOOKS_REPO_ROOT, DHX_HOOKS_INSTALL_DIR)
# so the probe never touches the live dhx repo or live ~/.claude/hooks symlinks.
#
# How to run:
#   bash tests/probes/probe-hooks-wiring.sh

set -u

# Probe must run against the dhx-health-check.sh living in the same repo
# checkout that the probe lives in (worktree-aware). Without this, a probe
# in a worktree would test the main-repo copy instead of the worktree copy
# and miss WIP changes. Resolve relative to the probe's own location.
PROBE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HEALTH_CHECK="$(cd "$PROBE_DIR/../.." && pwd)/dhx/dhx-health-check.sh"
if [[ ! -f "$HEALTH_CHECK" ]]; then
  echo "FATAL: cannot locate dhx-health-check.sh from probe at $HEALTH_CHECK" >&2
  exit 99
fi

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

PASS=0
FAIL=0

# run_case <name> <build_callback> <expected>
#
# build_callback is a shell function that takes ($home, $repo, $manifest) and
# is responsible for populating: scripts under $repo/, a hooks.json at
# $manifest, and symlinks under $home/.claude/hooks/. We always create the
# fake $home and $cache; the callback chooses what else to make.
run_case() {
  local name="$1"
  local builder="$2"
  local expected="$3"

  local home="$TMPDIR_BASE/home-$name"
  local cache="$home/.cache/dhx"
  local hooks_dir="$home/.claude/hooks"
  local repo="$TMPDIR_BASE/repo-$name"
  local manifest="$TMPDIR_BASE/manifest-$name.json"

  mkdir -p "$cache" "$hooks_dir" "$repo"

  # Build per-case fixtures.
  $builder "$home" "$repo" "$manifest" "$hooks_dir"

  HOME="$home" \
    CLAUDE_CONFIG_DIR="$home/.claude" \
    DHX_HOOKS_MANIFEST="$manifest" \
    DHX_HOOKS_REPO_ROOT="$repo" \
    DHX_HOOKS_INSTALL_DIR="$hooks_dir" \
    bash "$HEALTH_CHECK" \
    <<< '{"session_id":"probe-'"$name"'"}' >/dev/null 2>&1

  local got
  got=$(jq -r '.hooks_wiring // "ERR"' "$cache/health.json" 2>/dev/null || echo "ERR")

  if [[ "$got" == "$expected" ]]; then
    printf '  OK   %-30s -> hooks_wiring=%s\n' "$name" "$got"
    PASS=$((PASS + 1))
  else
    printf '  FAIL %-30s expected=%s got=%s\n' "$name" "$expected" "$got"
    FAIL=$((FAIL + 1))
  fi
}

# Helper: write a hooks.json manifest containing the given command lines under
# SessionStart. Build a JSON array of {command} entries.
write_manifest() {
  local manifest="$1"; shift
  local entries="[]"
  for cmd in "$@"; do
    entries=$(jq --arg c "$cmd" '. + [{"type":"command","command":$c}]' <<< "$entries")
  done
  jq --argjson hooks "$entries" '{
    hooks: {
      SessionStart: [
        { matcher: "startup|resume|clear|compact", hooks: $hooks }
      ]
    }
  }' <<< '{}' > "$manifest"
}

# ---------- Case A: healthy — 3 dhx scripts, all symlinks correct ----------
build_healthy() {
  local home="$1" repo="$2" manifest="$3" hooks_dir="$4"
  for n in alpha beta gamma; do
    touch "$repo/$n.sh"
    ln -s "$repo/$n.sh" "$hooks_dir/$n.sh"
  done
  write_manifest "$manifest" \
    "bash \"$hooks_dir/alpha.sh\"" \
    "bash \"$hooks_dir/beta.sh\"" \
    "bash \"$hooks_dir/gamma.sh\""
}
run_case "healthy" build_healthy "ok"

# ---------- Case B: one symlink missing ----------
build_one_missing() {
  local home="$1" repo="$2" manifest="$3" hooks_dir="$4"
  for n in alpha beta gamma; do touch "$repo/$n.sh"; done
  ln -s "$repo/alpha.sh" "$hooks_dir/alpha.sh"
  # beta intentionally NOT symlinked (broken)
  ln -s "$repo/gamma.sh" "$hooks_dir/gamma.sh"
  write_manifest "$manifest" \
    "bash \"$hooks_dir/alpha.sh\"" \
    "bash \"$hooks_dir/beta.sh\"" \
    "bash \"$hooks_dir/gamma.sh\""
}
run_case "one-missing-symlink" build_one_missing "BROKEN:1"

# ---------- Case C: 5 in manifest, 3 symlinks missing ----------
build_multi_broken() {
  local home="$1" repo="$2" manifest="$3" hooks_dir="$4"
  for n in a b c d e; do touch "$repo/$n.sh"; done
  ln -s "$repo/a.sh" "$hooks_dir/a.sh"
  ln -s "$repo/b.sh" "$hooks_dir/b.sh"
  # c, d, e NOT symlinked (3 broken)
  write_manifest "$manifest" \
    "bash \"$hooks_dir/a.sh\"" \
    "bash \"$hooks_dir/b.sh\"" \
    "bash \"$hooks_dir/c.sh\"" \
    "bash \"$hooks_dir/d.sh\"" \
    "bash \"$hooks_dir/e.sh\""
}
run_case "multi-broken-3" build_multi_broken "BROKEN:3"

# ---------- Case D: non-dhx script entry — symlink check skipped ----------
# One dhx script (must be symlinked) + one path NOT under dhx-repo-root (e.g.,
# simulating the dispatcher under dhx-plugin/, or a gsd-owned script). Both
# scripts present on disk; only the dhx one is symlinked. Expected: ok — the
# non-dhx entry's missing symlink does not count.
build_non_dhx_skipped() {
  local home="$1" repo="$2" manifest="$3" hooks_dir="$4"
  touch "$repo/dhx-script.sh"
  ln -s "$repo/dhx-script.sh" "$hooks_dir/dhx-script.sh"

  # Non-dhx script: present on disk under a different path entirely
  local non_dhx_dir="$TMPDIR_BASE/non-dhx-${RANDOM}"
  mkdir -p "$non_dhx_dir"
  touch "$non_dhx_dir/dispatcher.sh"

  write_manifest "$manifest" \
    "bash \"$hooks_dir/dhx-script.sh\"" \
    "bash \"$non_dhx_dir/dispatcher.sh\""
}
run_case "non-dhx-script-skipped" build_non_dhx_skipped "ok"

# ---------- Case E: manifest absent ----------
build_manifest_absent() {
  local home="$1" repo="$2" manifest="$3" hooks_dir="$4"
  # Don't write the manifest at all.
  :
}
run_case "manifest-absent" build_manifest_absent "ok"

# ---------- Case F: symlink resolves to a different target ----------
# dhx script exists, symlink exists, but symlink resolves to a DIFFERENT path
# (not back to the dhx repo). Counted as broken.
build_target_mismatch() {
  local home="$1" repo="$2" manifest="$3" hooks_dir="$4"
  touch "$repo/real-target.sh"
  # Create a decoy file that the symlink will point at instead of the repo file.
  local decoy_dir="$TMPDIR_BASE/decoy-${RANDOM}"
  mkdir -p "$decoy_dir"
  touch "$decoy_dir/real-target.sh"
  ln -s "$decoy_dir/real-target.sh" "$hooks_dir/real-target.sh"
  write_manifest "$manifest" \
    "bash \"$hooks_dir/real-target.sh\""
}
run_case "symlink-target-mismatch" build_target_mismatch "BROKEN:1"

# ---------- Case G: script missing from disk entirely ----------
# Manifest references a script that doesn't exist anywhere — counts as broken
# (most fundamental drift class).
build_script_missing() {
  local home="$1" repo="$2" manifest="$3" hooks_dir="$4"
  # Don't create any scripts; manifest references a path that doesn't exist.
  write_manifest "$manifest" \
    "bash \"$hooks_dir/nonexistent.sh\""
}
run_case "script-missing-from-disk" build_script_missing "BROKEN:1"

# ---------- Case H: node interpreter parses correctly ----------
# Verify the parser handles `node "<path>"` lines as well as `bash "<path>"`.
build_node_interpreter() {
  local home="$1" repo="$2" manifest="$3" hooks_dir="$4"
  touch "$repo/something.js"
  ln -s "$repo/something.js" "$hooks_dir/something.js"
  write_manifest "$manifest" \
    "node \"$hooks_dir/something.js\""
}
run_case "node-interpreter-parses" build_node_interpreter "ok"

echo ""
echo "PASS: $PASS  FAIL: $FAIL"
exit $FAIL
