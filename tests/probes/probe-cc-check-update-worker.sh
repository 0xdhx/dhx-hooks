#!/bin/bash
# SAFE_FOR_LIVE: yes   (mktemp cache + stubbed PATH; CC_CACHE_FILE override points the worker at a fixture cache; never touches live ~/.cache/cc and never hits the network)
#
# Exercises the npm-probe + cache write in dhx/cc-check-update-worker.js:
#   - installed_at_check capture (RAT-06b — the auto-updater-vs-TTL
#     `⚠ cc dev install` false-positive fix). The worker records the CC version
#     it confirmed npm `latest` against (`claude --version`) so the renderer can
#     suppress the dev-install warning when the installed binary changed since
#     the check. See docs/decisions.md 2026-05-21 RAT-06b row + HP-033 inv 7.
#   - max_published capture (RAT-06c — the latest-tag-lag false-positive fix).
#     The worker now runs ONE combined `npm view … version versions --json` and
#     records `max_published` = the SEMVER-MAX of every published version. The
#     renderer compares the installed binary against max_published (not the
#     `latest` dist-tag) for dev-install, because npm moves `latest` separately
#     from (and hours after) publishing a version. See docs/decisions.md
#     2026-05-29 RAT-06c row + HP-033 invariant 8.
#
# Run: bash tests/probes/probe-cc-check-update-worker.sh
#
# Strategy: stub `npm` and `claude` on PATH (fixed output, no network), point
# CC_CACHE_FILE at a tmp cache, run the worker SYNCHRONOUSLY (run directly, not
# via the detached parent spawn), then assert the cache JSON.
#   [1] both stubs succeed -> cache has latest (from .version) AND installed_at_check
#   [2] max_published = SEMVER-MAX of versions[] (NOT the last element, NOT the
#       `latest` tag) -> proves the worker computes max, not "take .version"
#   [3] claude stub fails  -> latest + max_published recorded, installed_at_check
#       OMITTED (graceful degradation: the renderer falls back to its prior
#       unguarded behavior when the field is absent — no regression, no crash)
#   [4] npm emits non-JSON -> latest='unknown', max_published OMITTED (graceful:
#       the combined-call JSON.parse throws, both fields degrade, no crash)

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

# npm view @anthropic-ai/claude-code version versions --json -> combined JSON.
# `.version` is the `latest` dist-tag version (2.1.147). `.versions` is the full
# published list, deliberately UNSORTED with its semver-max (2.1.150) NOT last
# and HIGHER than the `latest` tag — so a correct worker must (a) read latest
# from .version and (b) compute max_published as the semver-max of the array,
# distinct from both the last element (2.1.147) and the latest tag (2.1.147).
cat > "$STUBBIN/npm" <<'NPM'
#!/bin/bash
echo '{"version":"2.1.147","versions":["2.1.150","2.1.145","2.1.148","2.1.147"]}'
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

echo "=== cc-check-update-worker.js npm-probe + cache write (stubbed PATH, offline) ==="

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
S1_MAXPUB=$(read_cache max_published "$S1_CACHE")
if [ "$S1_LATEST" = "2.1.147" ] && [ "$S1_INSTALLED" = "2.1.147" ]; then
  check "[1] both stubs succeed -> latest=2.1.147 (from .version) + installed_at_check=2.1.147" ok
else
  check "[1] both stubs succeed -> latest=2.1.147 (from .version) + installed_at_check=2.1.147" \
    "fail (latest=$S1_LATEST installed_at_check=$S1_INSTALLED)"
fi

# ---- Scenario 2: max_published = semver-max of versions[] --------------------
# The versions array {2.1.150, 2.1.145, 2.1.148, 2.1.147} has semver-max 2.1.150,
# which is NEITHER the last element (2.1.147) NOR the latest tag (2.1.147). A
# worker that took the last element or reused .version would write 2.1.147.
if [ "$S1_MAXPUB" = "2.1.150" ]; then
  check "[2] max_published=2.1.150 = SEMVER-MAX of unsorted versions[] (not last, not latest-tag)" ok
else
  check "[2] max_published=2.1.150 = SEMVER-MAX of unsorted versions[] (not last, not latest-tag)" \
    "fail (max_published=$S1_MAXPUB)"
fi

# ---- Scenario 3: claude probe fails -> installed_at_check omitted ------------
# A failed `claude --version` (non-zero exit) must NOT abort the cache write or
# inject a bogus value — latest + max_published are still recorded,
# installed_at_check is simply absent, and the renderer's absent-field fallback
# preserves prior behavior.
cat > "$STUBBIN/claude" <<'CLAUDE'
#!/bin/bash
exit 1
CLAUDE
chmod +x "$STUBBIN/claude"

S3_CACHE="$TMPDIR/s3-cc-update-check.json"
PATH="$STUBBIN:$PATH" CC_CACHE_FILE="$S3_CACHE" node "$WORKER_SRC" >/dev/null 2>&1

S3_LATEST=$(read_cache latest "$S3_CACHE")
S3_INSTALLED=$(read_cache installed_at_check "$S3_CACHE")
S3_MAXPUB=$(read_cache max_published "$S3_CACHE")
if [ "$S3_LATEST" = "2.1.147" ] && [ "$S3_MAXPUB" = "2.1.150" ] && [ -z "$S3_INSTALLED" ]; then
  check "[3] claude probe fails -> latest + max_published recorded, installed_at_check omitted (graceful)" ok
else
  check "[3] claude probe fails -> latest + max_published recorded, installed_at_check omitted (graceful)" \
    "fail (latest=$S3_LATEST max_published=$S3_MAXPUB installed_at_check='$S3_INSTALLED')"
fi

# ---- Scenario 4: npm emits non-JSON -> latest=unknown, max_published omitted -
# An old npm, a registry error page, or any non-JSON on stdout makes the
# combined-call JSON.parse throw. Both latest and max_published degrade: latest
# is recorded as 'unknown' (so the renderer's whole cc-version block is skipped)
# and max_published is omitted. No crash, valid cache written.
cat > "$STUBBIN/npm" <<'NPM'
#!/bin/bash
echo "this is not json"
NPM
chmod +x "$STUBBIN/npm"
# (claude stub still exits 1 from Scenario 3 — irrelevant here)

S4_CACHE="$TMPDIR/s4-cc-update-check.json"
PATH="$STUBBIN:$PATH" CC_CACHE_FILE="$S4_CACHE" node "$WORKER_SRC" >/dev/null 2>&1

S4_LATEST=$(read_cache latest "$S4_CACHE")
S4_MAXPUB=$(read_cache max_published "$S4_CACHE")
if [ "$S4_LATEST" = "unknown" ] && [ -z "$S4_MAXPUB" ]; then
  check "[4] npm non-JSON -> latest='unknown', max_published omitted (graceful, no crash)" ok
else
  check "[4] npm non-JSON -> latest='unknown', max_published omitted (graceful, no crash)" \
    "fail (latest=$S4_LATEST max_published='$S4_MAXPUB')"
fi

echo "---"
echo "$PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
