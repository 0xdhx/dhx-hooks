#!/bin/bash
# Probe: scripts/health.sh produces zero filesystem mutations under fake HOME
# (D-15-equivalent for health.sh; SCRIPT-15). Pure read-only invariant —
# health.sh exists to compose check exit codes, not write any state. If a
# future refactor accidentally adds a write (e.g. caching health.json under
# ~/.cache/dhx/), this probe catches it before merge.
#
# Snapshot strategy: build a fake HOME tree with stub leaf-tools, snapshot
# every file via md5sum, run `bash health.sh` then `bash health.sh --json`,
# re-snapshot, assert byte-equal. Both modes must produce zero mutations.
#
# Run: bash tests/probes/probe-health-sh-no-side-effects.sh
# SAFE_FOR_LIVE: no   (mktemp + fake HOME; full env-var isolation)
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

pass=0; fail=0
assert_eq() {
  local name="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    echo "OK   $name"
    pass=$((pass+1))
  else
    echo "FAIL $name"
    echo "     got/want differ (truncated)"
    diff <(echo "$got") <(echo "$want") | head -20 || true
    fail=$((fail+1))
  fi
}

snapshot() {
  find "$1" -type f -print0 2>/dev/null | sort -z | xargs -0 md5sum 2>/dev/null
}

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Build minimal fake HOME with sub-dirs that health.sh might touch
mkdir -p "$TMPDIR/.ccs/shared" \
         "$TMPDIR/.cache/dhx" \
         "$TMPDIR/.claude/hooks" \
         "$TMPDIR/fakerepo/scripts/lib" \
         "$TMPDIR/fakerepo/tests/probes" \
         "$TMPDIR/fakerepo/dhx-plugin/.claude-plugin" \
         "$TMPDIR/bin"

echo '{}' > "$TMPDIR/.ccs/shared/settings.json"
echo '{}' > "$TMPDIR/fakerepo/dhx-plugin/.claude-plugin/marketplace.json"

# Stub leaf-tools — all return 0 (all-ok)
printf '#!/bin/bash\nexit 0\n' > "$TMPDIR/fakerepo/scripts/verify-hooks.sh"
for p in probe-plugin-keys probe-bashrc-wrapper-heal \
         probe-settings-path-invariant probe-hooks-wiring; do
  printf '#!/bin/bash\nexit 0\n' > "$TMPDIR/fakerepo/tests/probes/$p.sh"
done
chmod +x "$TMPDIR/fakerepo/scripts/verify-hooks.sh" \
         "$TMPDIR/fakerepo/tests/probes/"*.sh

# git shim — `diff --quiet` returns 0
cat > "$TMPDIR/bin/git" <<'GITSHIM'
#!/bin/bash
for a in "$@"; do
  if [[ "$a" == "diff" ]]; then exit 0; fi
done
exec /usr/bin/git "$@"
GITSHIM
chmod +x "$TMPDIR/bin/git"

# Copy real tiers.{json,sh} into fake repo
cp "$REPO/scripts/lib/tiers.json" "$TMPDIR/fakerepo/scripts/lib/"
cp "$REPO/scripts/lib/tiers.sh"   "$TMPDIR/fakerepo/scripts/lib/"

# Sanity: scripts/health.sh must exist + be executable. This makes the probe a
# proper RED gate during TDD — without this, a missing health.sh would error
# silently and produce a vacuously-true "no mutations" pass.
if [[ ! -x "$REPO/scripts/health.sh" ]]; then
  echo "FAIL pre-flight: $REPO/scripts/health.sh not found or not executable"
  fail=$((fail+1))
  echo
  echo "$pass passed, $fail failed"
  exit $fail
fi

SNAP_BEFORE=$(snapshot "$TMPDIR")

HOME="$TMPDIR" CLAUDE_CONFIG_DIR="$TMPDIR/.claude" PATH="$TMPDIR/bin:$PATH" \
  DHX_HEALTH_REPO_ROOT="$TMPDIR/fakerepo" \
  bash "$REPO/scripts/health.sh" >/dev/null 2>&1

SNAP_AFTER=$(snapshot "$TMPDIR")
assert_eq "health.sh bare run mutates nothing" "$SNAP_AFTER" "$SNAP_BEFORE"

HOME="$TMPDIR" CLAUDE_CONFIG_DIR="$TMPDIR/.claude" PATH="$TMPDIR/bin:$PATH" \
  DHX_HEALTH_REPO_ROOT="$TMPDIR/fakerepo" \
  bash "$REPO/scripts/health.sh" --json >/dev/null 2>&1

SNAP_AFTER_JSON=$(snapshot "$TMPDIR")
assert_eq "health.sh --json mutates nothing" "$SNAP_AFTER_JSON" "$SNAP_BEFORE"

echo
echo "$pass passed, $fail failed"
exit $fail
