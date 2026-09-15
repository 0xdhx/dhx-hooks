#!/usr/bin/env bash
# SAFE_FOR_LIVE: yes  (static reads of the live launch wrappers — cross-repo claude-capped.sh,
#   dotfiles clodex-bridge — and of the active settings' processWrapper; every behavioral cell
#   runs those wrappers under env -i with a mktemp HOME, a mktemp CLAUDE_CONFIG_DIR and a fake
#   claude binary. The only write outside mktemp is capped's own /tmp/claude-lane-<pid> dir,
#   removed by pid right after its cell.)
#
# Guards the pre-launch seam (docs/decisions.md 2026-09-15 pre-launch row): a registry Claude
# Code would reject must be repaired BEFORE Claude Code starts, on every normal launch path —
# the dhx plugin's own SessionStart cannot fire in those states.
#   W1  claude-capped.sh runs ~/.claude/hooks/dhx-prelaunch.sh before building LAUNCH, bounded
#       by `timeout -k`, stdin from /dev/null.
#   W2  clodex-bridge runs it before its first step-aside exec, bounded, stdin from /dev/null.
#   W3  the active settings' processWrapper resolves to that same bridge (daemon-hosted
#       sessions reach only the bridge). Skipped, with a note, when no settings are readable.
#   W4  through the REAL bridge (step-aside branch): the fake binary starts after the registry
#       was repaired and receives argv (spaces intact) and the caller's stdin untouched.
#   W5  through the REAL capped launcher (CLAUDE_CAP_DISABLE=1, no bridge installed): the same,
#       via capped's own call.
#   W6  fail-open: a hanging child is cut off by the per-child bound and the launch proceeds;
#       with no pre-launch script installed the launch proceeds unchanged.
#   W7  dhx-prelaunch.sh writes nothing to stdout and exits 0 even when a child prints and fails.
# Run: bash tests/probes/probe-prelaunch-wiring.sh
set -u

REPO=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || echo /home/dhx/repos/hooks)
PRELAUNCH="$REPO/dhx/dhx-prelaunch.sh"
CAPPED="${DHX_PROBE_CAPPED:-/home/dhx/repos/cross-repo/health/scripts/claude-capped.sh}"
BRIDGE="${DHX_PROBE_BRIDGE:-/home/dhx/repos/dotfiles/bin/clodex-bridge}"
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0
check() {  # name status
  if [[ "$2" == "0" ]]; then printf '  ✓ %s\n' "$1"; PASS=$((PASS + 1))
  else printf '  ✗ %s\n' "$1"; FAIL=$((FAIL + 1)); fi
}
first_line() {  # file ERE → line number of first match, or empty
  grep -nE "$2" "$1" 2>/dev/null | head -n1 | cut -d: -f1
}

echo "=== pre-launch seam — 7 checks (W1-W7) ==="

# ---- W1 capped: bounded call before LAUNCH ----
if [[ -r "$CAPPED" ]]; then
  call=$(first_line "$CAPPED" '^[[:space:]]*timeout -k [0-9]+ [0-9]+ "\$_dhx_prelaunch" </dev/null')
  assign=$(first_line "$CAPPED" '^_dhx_prelaunch="\$HOME/\.claude/hooks/dhx-prelaunch\.sh"$')
  launch=$(first_line "$CAPPED" '^LAUNCH=\("\$REAL"\)')
  [[ -n "$call" && -n "$assign" && -n "$launch" ]] && (( assign < call && call < launch ))
  check "W1 capped: bounded, stdin-less call at line ${call:-?} precedes LAUNCH at line ${launch:-?}" $?
else
  check "W1 capped: $CAPPED readable" 1
fi

# ---- W2 bridge: bounded call before the first step-aside exec ----
if [[ -r "$BRIDGE" ]]; then
  call=$(first_line "$BRIDGE" '^[[:space:]]*/usr/bin/timeout -k [0-9]+ [0-9]+ "\$dhx_prelaunch" </dev/null')
  exec_line=$(first_line "$BRIDGE" '^[[:space:]]*exec "\$@"')
  [[ -n "$call" && -n "$exec_line" ]] && (( call < exec_line ))
  check "W2 bridge: bounded, stdin-less call at line ${call:-?} precedes first step-aside exec at line ${exec_line:-?}" $?
else
  check "W2 bridge: $BRIDGE readable" 1
fi

# ---- W3 processWrapper → the bridge ----
settings=$(readlink -f "${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/settings.json" 2>/dev/null)
if [[ -n "$settings" && -r "$settings" ]]; then
  pw=$(jq -r '.processWrapper // empty' "$settings" 2>/dev/null)
  [[ -n "$pw" && "$(readlink -f "$pw" 2>/dev/null)" == "$(readlink -f "$BRIDGE" 2>/dev/null)" ]]
  check "W3 processWrapper ($pw) resolves to the bridge that runs the pre-launch call" $?
else
  printf '  - W3 processWrapper: skipped (no readable settings.json)\n'
fi

# mkfix NAME → a root with: home/.claude/hooks/dhx-prelaunch.sh (→ this checkout), cfg whose km
# is MISSING dhx-local, a marketplace source dir with a named manifest, and bin/claude (a fake
# that records what it saw at start).
mkfix() {
  local r="$TMPROOT/$1"
  mkdir -p "$r/home/.claude/hooks" "$r/cfg/plugins" "$r/src/.claude-plugin" "$r/bin"
  printf '{"name":"dhx-local","owner":{"name":"probe"},"plugins":[]}' > "$r/src/.claude-plugin/marketplace.json"
  printf '{"extraKnownMarketplaces":{"dhx-local":{"source":{"source":"directory","path":"%s"}}}}' "$r/src" \
    > "$r/cfg/settings.json"
  printf '{}' > "$r/cfg/plugins/known_marketplaces.json"
  ln -s "$PRELAUNCH" "$r/home/.claude/hooks/dhx-prelaunch.sh"
  cat > "$r/bin/claude" <<'FAKE'
#!/bin/bash
km="$CLAUDE_CONFIG_DIR/plugins/known_marketplaces.json"
{
  printf 'pid=%s\n' "$$"
  if jq -e '(."dhx-local" | type) == "object" and ([.[] | (.lastUpdated | type) == "string"] | all)' "$km" >/dev/null 2>&1; then
    echo "repaired=yes"
  else
    echo "repaired=no"
  fi
  printf 'argc=%s\n' "$#"
  printf 'arg=%s\n' "$@"
  printf 'stdin=%s\n' "$(cat)"
} > "$FAKE_RECORD"
FAKE
  chmod +x "$r/bin/claude"
  printf '%s' "$r"
}

# ---- W4 real bridge, step-aside branch ----
r=$(mkfix bridge)
printf 'STDIN-PAYLOAD' | env -i PATH=/usr/bin:/bin HOME="$r/home" CLAUDE_CONFIG_DIR="$r/cfg" \
  ANTHROPIC_BASE_URL=http://probe.invalid FAKE_RECORD="$r/record" \
  sh "$BRIDGE" "$r/bin/claude" one "two words" >/dev/null 2>&1
grep -qx 'repaired=yes' "$r/record" 2>/dev/null \
  && grep -qx 'argc=2' "$r/record" && grep -qx 'arg=one' "$r/record" && grep -qx 'arg=two words' "$r/record" \
  && grep -qx 'stdin=STDIN-PAYLOAD' "$r/record"
check "W4 bridge: registry repaired before launch; argv and stdin reach the binary intact" $?

# ---- W5 real capped launcher ----
r=$(mkfix capped)
mkdir -p "$r/home/.local/bin"
ln -s "$r/bin/claude" "$r/home/.local/bin/claude"
printf 'CAPPED-STDIN' | env -i PATH=/usr/bin:/bin HOME="$r/home" CLAUDE_CONFIG_DIR="$r/cfg" \
  CLAUDE_CAP_DISABLE=1 FAKE_RECORD="$r/record" bash "$CAPPED" alpha >/dev/null 2>&1
lane_pid=$(sed -n 's/^pid=\([0-9][0-9]*\)$/\1/p' "$r/record" 2>/dev/null)
[[ -n "$lane_pid" && -d "/tmp/claude-lane-$lane_pid" ]] && rm -rf "/tmp/claude-lane-$lane_pid"
grep -qx 'repaired=yes' "$r/record" 2>/dev/null && grep -qx 'arg=alpha' "$r/record" \
  && grep -qx 'stdin=CAPPED-STDIN' "$r/record"
check "W5 capped: registry repaired before launch (capped's own call); argv and stdin intact" $?

# ---- W6 fail-open: hanging child bounded; missing script harmless ----
r=$(mkfix hang)
mkdir -p "$r/stub"
printf '#!/bin/bash\nsleep 20\n' > "$r/stub/dhx-plugin-registry-heal.sh"
t0=$(date +%s)
env -i PATH=/usr/bin:/bin HOME="$r/home" CLAUDE_CONFIG_DIR="$r/cfg" ANTHROPIC_BASE_URL=http://probe.invalid \
  DHX_PRELAUNCH_HOOKS_DIR="$r/stub" DHX_PRELAUNCH_CHILD_BOUND_S=1 FAKE_RECORD="$r/record" \
  sh "$BRIDGE" "$r/bin/claude" </dev/null >/dev/null 2>&1
elapsed=$(( $(date +%s) - t0 ))
[[ -f "$r/record" ]] && (( elapsed < 5 ))
check "W6 fail-open: a hanging child is cut off (launched after ${elapsed}s, bound 1s)" $?
r=$(mkfix absent)
rm -f "$r/home/.claude/hooks/dhx-prelaunch.sh"
env -i PATH=/usr/bin:/bin HOME="$r/home" CLAUDE_CONFIG_DIR="$r/cfg" ANTHROPIC_BASE_URL=http://probe.invalid \
  FAKE_RECORD="$r/record" sh "$BRIDGE" "$r/bin/claude" </dev/null >/dev/null 2>&1
grep -qx 'repaired=no' "$r/record" 2>/dev/null
check "W6 fail-open: no pre-launch script installed → launch proceeds unchanged" $?

# ---- W7 no stdout, exit 0 ----
mkdir -p "$TMPROOT/loud"
printf '#!/bin/bash\necho LEAKED-TO-STDOUT\nexit 3\n' > "$TMPROOT/loud/dhx-plugin-registry-heal.sh"
out=$(env -i PATH=/usr/bin:/bin HOME="$TMPROOT" DHX_PRELAUNCH_HOOKS_DIR="$TMPROOT/loud" bash "$PRELAUNCH" </dev/null 2>/dev/null)
rc=$?
[[ -z "$out" && "$rc" == "0" ]]
check "W7 dhx-prelaunch.sh: stdout empty and exit 0 when a child prints and fails" $?

echo "---"
echo "PASS: $PASS  FAIL: $FAIL"
exit $FAIL
