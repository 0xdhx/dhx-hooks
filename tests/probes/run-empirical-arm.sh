#!/usr/bin/env bash
# Phase 10.1 / Plan 1 / Task 2 — empirical-arm operator helper.
#
# Drives steps 1–8 of the D-01 checkpoint:human-action runbook
# (the same runbook printed by `probe-plugin-cache-staleness.sh` scenario 6).
# Step 9 (write-result) is operator action — this script prints the exact
# write-result command with values pre-filled.
#
# Re-runnable: each invocation provisions a fresh mktemp sandbox; existing
# plugin install in $HOME is not touched (sandbox is isolated).
#
# Sandbox is PRESERVED on exit so you can re-inspect logs/manifest. Clean up
# manually when done (path printed at end).

#
# CC-STDERR-EXEMPT: this arm classifies $DEBUG_LOG (`--debug-file`), not a 2>&1
#   capture, and the settings lint never reaches that file — measured 2026-09-19
#   on CC 2.1.278, 2/2 lint-provoking cells: `Permission allow rule (...)` on stderr
#   (positive control), 0 lines of that shape in the debug file; `--debug` changes
#   nothing. What DOES reach it is every loaded permission rule's text, verbatim
#   (`Applying permission update: Adding 1 allow rule(s) to destination
#   'userSettings': ["Bash(SessionStart)"]`, 4/4 rule cells, lint-independent) —
#   but this sandbox swaps HOME and CLAUDE_CONFIG_DIR, so the live settings are
#   never read; the only read-through is <cwd>/.claude/settings.local.json (0
#   matching rules in ~/repos/hooks today; project settings.json allow rules are
#   dropped in an untrusted workspace). Re-measure if the arm is ever run from a
#   cwd whose settings.local.json carries a rule naming SessionStart.
#   Evidence: reports/2026-09-19-h3-debug-file-settings-lint-cc-2.1.278/
#   Convention: tests/probes/README.md § "A classifier's INPUT is a surface too".
#
# ORACLE (2026-09-19, H5): the verdict is computed by lib/empirical-arm-classify.sh
#   and 8c is LOAD-BEARING — REFUTE requires >=1 Stop-dispatch line in $DEBUG_LOG
#   besides marker-absent + control-fired. Unauthenticated, CC ends the turn at
#   the API auth error BEFORE Stop dispatches, so the marker cannot fire and the
#   old two-signal rule printed a vacuous REFUTE (H5 run 1). Credentials are
#   therefore required up front (pre-flight below) — the swapped HOME hides any
#   /login credential from the child, so they must come from the environment.
#   Regression probe: tests/probes/probe-empirical-arm-oracle.sh.
#

set -uo pipefail

HOOKS_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MARKER_FIXTURE="$HOOKS_REPO/tests/probes/fixtures/dhx-cache-probe-marker.sh"
PROBE="$HOOKS_REPO/tests/probes/probe-plugin-cache-staleness.sh"
PLUGIN_DIR="$HOOKS_REPO/dhx-plugin"
# shellcheck source=lib/empirical-arm-classify.sh
source "$HOOKS_REPO/tests/probes/lib/empirical-arm-classify.sh"

# === Pre-flight ===
err=0
command -v claude >/dev/null || { echo "ERROR: claude CLI not on PATH" >&2; err=1; }
command -v jq     >/dev/null || { echo "ERROR: jq not on PATH"          >&2; err=1; }
[ -x "$MARKER_FIXTURE" ] || { echo "ERROR: marker fixture not executable: $MARKER_FIXTURE" >&2; err=1; }
[ -x "$PROBE" ]          || { echo "ERROR: probe not executable: $PROBE"                 >&2; err=1; }
[ -d "$PLUGIN_DIR" ]     || { echo "ERROR: dhx-plugin dir missing: $PLUGIN_DIR"          >&2; err=1; }
# Credentials up front (H5, 2026-09-19). The sandbox swaps HOME and CLAUDE_CONFIG_DIR,
# so a /login credential is invisible to the child; unauthenticated it prints
# `Not logged in · Please run /login` and ends the turn at `Could not resolve
# authentication method` BEFORE any Stop hook dispatches — the arm then measures
# nothing. Refuse before provisioning a sandbox rather than classify a vacuous run.
if [ -z "${ANTHROPIC_API_KEY:-}${ANTHROPIC_AUTH_TOKEN:-}${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  echo "ERROR: no credential in the environment — set ANTHROPIC_API_KEY (or ANTHROPIC_AUTH_TOKEN /" >&2
  echo "       CLAUDE_CODE_OAUTH_TOKEN). The sandboxed child cannot see a /login credential; without" >&2
  echo "       one CC ends the turn before Stop dispatches and the verdict is INCONCLUSIVE by construction." >&2
  echo "       e.g.  ( . ~/.env-keys && bash tests/probes/run-empirical-arm.sh )   # subshell: nothing leaks" >&2
  err=1
fi
[ $err -eq 0 ] || exit 2

SID="$$-$(date +%s)"
MARKER_LOG="/tmp/dhx-cache-probe-marker-$SID.log"
DEBUG_LOG="/tmp/dhx-cache-probe-debug-$SID.log"

banner() { printf '\n=== %s ===\n' "$*"; }

# === 1. Fresh sandbox ===
banner "1. Sandbox"
SANDBOX=$(mktemp -d -t dhx-cache-probe-XXXXXX)
mkdir -p "$SANDBOX/home" "$SANDBOX/config"
export HOME="$SANDBOX/home" CLAUDE_CONFIG_DIR="$SANDBOX/config"
echo "    HOME              = $HOME"
echo "    CLAUDE_CONFIG_DIR = $CLAUDE_CONFIG_DIR"

# === 2. CC version ===
banner "2. CC version"
CC_VER=$(claude --version)
echo "    $CC_VER"

# === 3–4. Install dhx plugin via local marketplace ===
banner "3–4. Install dhx plugin"
claude plugin marketplace add "$PLUGIN_DIR"
claude plugin install dhx

# === 5. Locate cache manifest ===
# CC plugin cache lives under CLAUDE_CONFIG_DIR/plugins/cache (default: $HOME/.claude).
# In this sandbox we set CLAUDE_CONFIG_DIR explicitly, so search there.
banner "5. Locate cache hooks.json"
CACHE_ROOT="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache"
CACHE_HOOKS=$(find "$CACHE_ROOT" -name hooks.json -path '*dhx*' 2>/dev/null | head -1)
if [ -z "$CACHE_HOOKS" ]; then
  echo "ERROR: cache hooks.json not found under $CACHE_ROOT" >&2
  echo "Tree:" >&2
  find "$CACHE_ROOT" -maxdepth 5 2>/dev/null >&2 || echo "(cache dir absent)" >&2
  exit 3
fi
LIVE_HOOKS="$CACHE_HOOKS"   # plugin is sole registration in this sandbox
echo "    cache: $CACHE_HOOKS"
echo "    live:  $LIVE_HOOKS"

# === 6. jq-inject additional Stop hook → marker fixture (D-25 amends D-03) ===
# Append the marker as a sibling hook INSIDE the existing Stop matcher block
# (.hooks.Stop[0].hooks += [...]), NOT as a new matcher block. A separate
# matcher block with "matcher": "" introduces schema ambiguity (CC may filter
# it), making marker absence non-decisive. Appending to the existing block
# eliminates that ambiguity: the marker is a peer of the 4 original commands.
banner "6. Inject additional Stop hook → marker fixture (D-25)"
cp "$CACHE_HOOKS" "$CACHE_HOOKS.pre-inject"
jq --arg cmd "bash \"$MARKER_FIXTURE\"" '
  .hooks.Stop[0].hooks += [{ type: "command", command: $cmd }]
' "$CACHE_HOOKS.pre-inject" > "$CACHE_HOOKS"
echo "    pre-inject Stop hook count: $(jq '.hooks.Stop[0].hooks | length' "$CACHE_HOOKS.pre-inject")"
echo "    post-inject Stop hook count: $(jq '.hooks.Stop[0].hooks | length' "$CACHE_HOOKS")"
echo "    diff:"
diff -u "$CACHE_HOOKS.pre-inject" "$CACHE_HOOKS" | sed 's/^/        /' || true

# === 7. Run CC one-shot ===
banner "7. Run claude (one-shot, --debug-file capture)"
echo "    cmd: DHX_CACHE_PROBE_MARKER_LOG=$MARKER_LOG claude --debug-file $DEBUG_LOG -p 'hi'"
DHX_CACHE_PROBE_MARKER_LOG="$MARKER_LOG" \
  claude --debug-file "$DEBUG_LOG" -p "hi" \
  || echo "    (claude exited non-zero — continuing to inspection)"

# === 8. Inspect signals ===
banner "8a. Marker log ($MARKER_LOG)"
if [ -s "$MARKER_LOG" ]; then
  sed 's/^/    /' "$MARKER_LOG"
  MARKER_FIRED=yes
else
  echo "    (absent or empty — marker did NOT fire)"
  MARKER_FIRED=no
fi

banner "8b. Debug log: SessionStart control trace (session-start.sh)"
if grep -E "session-start|SessionStart" "$DEBUG_LOG" 2>/dev/null | head -10 | sed 's/^/    /'; then
  if grep -qE "session-start|SessionStart" "$DEBUG_LOG" 2>/dev/null; then
    CONTROL_FIRED=yes
  else
    CONTROL_FIRED=no
  fi
else
  CONTROL_FIRED=no
fi
[ "$CONTROL_FIRED" = "yes" ] || echo "    (no SessionStart trace found in debug log)"

banner "8c. Debug log: Stop-dispatch trace (LOAD-BEARING — REFUTE needs >= 1 line)"
STOPS_DISPATCHED=$(arm_stop_dispatched "$DEBUG_LOG")
grep -E "$ARM_STOP_RE" "$DEBUG_LOG" 2>/dev/null | head -10 | sed 's/^/    /'
echo "    Stop-dispatch lines: $STOPS_DISPATCHED  (pattern: $ARM_STOP_RE)"
AUTH_FAILED=$(arm_auth_failed "$DEBUG_LOG")
if [ "$AUTH_FAILED" = "yes" ]; then
  echo "    AUTH FAILURE in debug log — the child never reached the model:"
  grep -E "$ARM_AUTH_FAIL_RE" "$DEBUG_LOG" 2>/dev/null | head -2 | cut -c1-160 | sed 's/^/      /'
fi

# === D-05 classification (lib/empirical-arm-classify.sh) ===
banner "D-05 classification (verify before write-result)"
# D-25: marker injected under Stop event-class — fires reliably under `claude -p`
# ONLY IF Stop dispatched. Marker absence + control fired + >=1 Stop-dispatch
# line → REFUTE is decisive (the Stop event did trigger; the only explanation
# for marker absence is cache-not-read). With 0 Stop-dispatch lines the marker
# could not have fired and the verdict is INCONCLUSIVE, never REFUTE (H5 run 1).
arm_classify "$MARKER_FIRED" "$CONTROL_FIRED" "$STOPS_DISPATCHED" "$AUTH_FAILED"
echo "    Suggested: $CLASS_LABEL"
echo "    Args:      $CLASS_ARGS"
echo "    Manual verification: review $DEBUG_LOG + $MARKER_LOG before accepting."
echo "    --control-hook-fired observed: $CONTROL_FIRED"
echo "    Stop-dispatch lines observed:  $STOPS_DISPATCHED"

# === Ready-to-run write-result command ===
cat <<EOF

=== Step 9 — run write-result (substitute classification if needed) ===

cd $HOOKS_REPO
bash tests/probes/probe-plugin-cache-staleness.sh write-result \\
  $CLASS_ARGS \\
  --cc-version "$CC_VER" \\
  --evidence "<short narrative of observed signals>" \\
  --evidence-debug "$DEBUG_LOG" \\
  --cache-manifest-path "$CACHE_HOOKS" \\
  --live-manifest-path "$LIVE_HOOKS" \\
  --marker-log-path "$MARKER_LOG"

=== Step 10 — verify artifact + re-run probe ===

ls -la tests/probes/fixtures/10.1-D-01-RESULT.md   # write-result's target — the probe-owned fixture
bash tests/probes/probe-plugin-cache-staleness.sh    # empirical-arm should now PASS

=== Cleanup (when done) ===

rm -rf "$SANDBOX"
rm -f  "$MARKER_LOG" "$DEBUG_LOG"

EOF
