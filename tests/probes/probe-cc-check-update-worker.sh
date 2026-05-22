#!/bin/bash
# SAFE_FOR_LIVE: yes   (mktemp cache + stubbed PATH; CC_CACHE_FILE override points the worker at a fixture cache; never touches live ~/.cache/cc and never hits the network)
#
# Exercises the installed_at_check capture in dhx/cc-check-update-worker.js
# (RAT-06b — the auto-updater-vs-TTL `⚠ cc dev install` false-positive fix).
# The worker records the CC version it confirmed npm `latest` against
# (`claude --version`) so the renderer can suppress the dev-install warning
# when the installed binary changed since the check (the auto-updater raced
# the ~6h TTL, so installed > cache.latest is a stale-cache artifact, not a
# genuine dev build). See docs/decisions.md 2026-05-21 RAT-06b row + HP-033.
#
# Run: bash tests/probes/probe-cc-check-update-worker.sh
#
# Strategy: stub `npm` and `claude` on PATH (fixed versions, no network),
# point CC_CACHE_FILE at a tmp cache, run the worker SYNCHRONOUSLY (run
# directly, not via the detached parent spawn), then assert the cache JSON.
#   [1] both stubs succeed -> cache has latest AND installed_at_check
#   [2] claude stub fails   -> cache has latest, installed_at_check OMITTED
#       (graceful degradation: the renderer falls back to its prior unguarded
#        behavior when the field is absent — no regression, no crash)

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKER_SRC="$REPO_ROOT/dhx/cc-check-update-worker.js"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0

check() {
  local name="$1" cond="$2"
  if [ "$cond" = "ok" ]; then
    echo "OK   $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL $name"
    FAIL=$((FAIL + 1))
  fi
}

# --- Build the stub PATH -----------------------------------------------------
# `npm` and `claude` resolved via PATH by the worker's execFileSync calls.
STUBBIN="$TMPDIR/bin"
mkdir -p "$STUBBIN"

# npm view @anthropic-ai/claude-code version -> prints a fixed version.
cat > "$STUBBIN/npm" <<'NPM'
#!/bin/bash
echo "2.1.147"
NPM
chmod +x "$STUBBIN/npm"

# read_cache <key> <file> — extract a JSON string value via node (no jq dep).
# Prints the value, or empty string if the key is absent.
read_cache() {
  local key="$1" file="$2"
  node -e '
    const fs = require("fs");
    try {
      const c = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const v = c[process.argv[2]];
      process.stdout.write(v === undefined ? "" : String(v));
    } catch (e) { process.stdout.write("__ERR__"); }
  ' "$file" "$key"
}

echo "=== cc-check-update-worker.js installed_at_check capture (stubbed PATH, offline) ==="

# ---- Scenario 1: both stubs succeed -> latest + installed_at_check -----------
# claude --version prints the canonical "2.1.147 (Claude Code)" shape; the
# worker must parse the leading version token (drop the " (Claude Code)" suffix
# and any leading `v`) so it matches the bare stdin `data.version` the renderer
# compares against.
cat > "$STUBBIN/claude" <<'CLAUDE'
#!/bin/bash
echo "2.1.147 (Claude Code)"
CLAUDE
chmod +x "$STUBBIN/claude"

S1_CACHE="$TMPDIR/s1-cc-update-check.json"
PATH="$STUBBIN:$PATH" CC_CACHE_FILE="$S1_CACHE" node "$WORKER_SRC" >/dev/null 2>&1

S1_LATEST=$(read_cache latest "$S1_CACHE")
S1_INSTALLED=$(read_cache installed_at_check "$S1_CACHE")
if [ "$S1_LATEST" = "2.1.147" ] && [ "$S1_INSTALLED" = "2.1.147" ]; then
  check "[1] both stubs succeed -> latest=2.1.147 + installed_at_check=2.1.147" ok
else
  check "[1] both stubs succeed -> latest=2.1.147 + installed_at_check=2.1.147" \
    "fail (latest=$S1_LATEST installed_at_check=$S1_INSTALLED)"
fi

# ---- Scenario 2: claude probe fails -> installed_at_check omitted ------------
# A failed `claude --version` (non-zero exit) must NOT abort the cache write or
# inject a bogus value — latest is still recorded, installed_at_check is simply
# absent, and the renderer's absent-field fallback preserves prior behavior.
cat > "$STUBBIN/claude" <<'CLAUDE'
#!/bin/bash
exit 1
CLAUDE
chmod +x "$STUBBIN/claude"

S2_CACHE="$TMPDIR/s2-cc-update-check.json"
PATH="$STUBBIN:$PATH" CC_CACHE_FILE="$S2_CACHE" node "$WORKER_SRC" >/dev/null 2>&1

S2_LATEST=$(read_cache latest "$S2_CACHE")
S2_INSTALLED=$(read_cache installed_at_check "$S2_CACHE")
if [ "$S2_LATEST" = "2.1.147" ] && [ -z "$S2_INSTALLED" ]; then
  check "[2] claude probe fails -> latest recorded, installed_at_check omitted (graceful)" ok
else
  check "[2] claude probe fails -> latest recorded, installed_at_check omitted (graceful)" \
    "fail (latest=$S2_LATEST installed_at_check='$S2_INSTALLED')"
fi

echo "---"
echo "$PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
