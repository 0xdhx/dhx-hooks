#!/usr/bin/env bash
# SAFE_FOR_LIVE: yes  (read-only grep of in-repo hooks.json / banner script /
#   dispatcher; behavioral smoke runs `dhx-dashboard.cjs notify`, which only READS
#   feeds and writes a JSON {systemMessage} to stdout — no file writes, no mutation)
#
# Exercises the SessionStart cross-repo VITALS BANNER wiring: cross-repo
# scripts/dhx-dashboard.cjs `notify` → JSON {"systemMessage": …}, surfaced by the
# plugin hook dhx/dhx-vitals-banner.sh, registered as its OWN SessionStart hook in
# hooks.json.
#
# WHY a separate hook, and NOT the dispatcher (the 2026-06-04 correction): a CC hook
# CANNOT render the wezterm badge (stdout captured as model context; /dev/tty removed
# from hooks in CC 2.1.139; OSC 1337 off the terminalSequence allowlist) — the badge
# is a SHELL precmd (cross-repo dotfiles/dhx-vitals-badge.sh). The BANNER reaches the
# USER only via a JSON {systemMessage}, which must be its OWN SessionStart hook (the
# plain-text session-start.sh dispatcher concatenates children's stdout and would
# corrupt the JSON). See the cross-repo knowledge base.
#
# NOTE: the hooks.json registration is FROZEN in the running plugin cache until a
# refresh (see the staged-unblock prompt) — this probe asserts the REPO source that
# the refresh will deploy, not the live cache.
#
#   A. WIRING (unconditional): hooks.json registers dhx-vitals-banner.sh under
#      SessionStart; the banner script guards the dhx-tools symlink, calls `notify`,
#      is fail-open + exit 0, carries a `# Patterns:` header; and the dispatcher no
#      longer invokes dhx-dashboard (the dead badge-via-hook line is gone).
#   B. BEHAVIORAL SMOKE (conditional on the installed tool + node): `notify` emits
#      valid JSON whose `.systemMessage` is the vitals banner, carries NO OSC/
#      SetUserVar escape (badge is not a hook's job), and is labeled DISTINCT from
#      the digest's "Action required" awaiting_us inbox; silent (empty) at count 0.
#
# banner=systemMessage SessionStart hook" row.
# Run: bash tests/probes/probe-dashboard-notify-wiring.sh

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOKS_JSON="$REPO_ROOT/dhx-plugin/plugins/dhx/hooks/hooks.json"
BANNER="$REPO_ROOT/dhx/dhx-vitals-banner.sh"
DISPATCHER="$REPO_ROOT/dhx-plugin/plugins/dhx/hooks/session-start.sh"
INSTALLED="$HOME/.claude/dhx-tools/dhx-dashboard.cjs"

PASS=0; FAIL=0
check(){ if [ "$2" = ok ]; then echo "OK   $1"; PASS=$((PASS+1)); else echo "FAIL $1${3:+ ($3)}"; FAIL=$((FAIL+1)); fi; }

echo "=== A. Banner wiring (SessionStart systemMessage hook) ==="

if command -v jq >/dev/null 2>&1 && [ -f "$HOOKS_JSON" ]; then
  jq -e '[.hooks.SessionStart[].hooks[].command | select(test("dhx-vitals-banner\\.sh"))] | length > 0' "$HOOKS_JSON" >/dev/null 2>&1 \
    && check "hooks.json registers dhx-vitals-banner.sh under SessionStart" ok \
    || check "hooks.json registers dhx-vitals-banner.sh under SessionStart" fail
else
  check "hooks.json present + jq available" fail "missing"
fi

[ -f "$BANNER" ] && check "dhx/dhx-vitals-banner.sh present" ok || check "dhx/dhx-vitals-banner.sh present" fail
grep -q '^# Patterns:' "$BANNER" 2>/dev/null && check "banner has a # Patterns: header (verify-hook-patterns)" ok || check "banner has a # Patterns: header" fail
grep -qE '\[ -e "\$TOOL" \]' "$BANNER" 2>/dev/null && check "banner guards the dhx-tools symlink ([ -e \$TOOL ])" ok || check "banner guards the dhx-tools symlink" fail
grep -qE '"\$TOOL" notify' "$BANNER" 2>/dev/null && check "banner invokes dhx-dashboard.cjs notify" ok || check "banner invokes dhx-dashboard.cjs notify" fail
grep -qE '\|\| true' "$BANNER" 2>/dev/null && check "banner is fail-open (|| true)" ok || check "banner is fail-open (|| true)" fail

# The dead badge-via-hook dispatch line must be GONE from the dispatcher.
if grep -qE 'dhx-dashboard' "$DISPATCHER" 2>/dev/null; then
  check "dispatcher no longer references dhx-dashboard (dead badge line removed)" fail "found a reference"
else
  check "dispatcher no longer references dhx-dashboard (dead badge line removed)" ok
fi

echo "=== B. Behavioral smoke — notify systemMessage contract (live state) ==="
if [ ! -e "$INSTALLED" ] || ! command -v node >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "SKIP behavioral smoke — $INSTALLED not provisioned or node/jq absent"
else
  SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
  node "$INSTALLED" notify </dev/null >"$SB/out" 2>/dev/null || true
  COUNT=$(node "$INSTALLED" count </dev/null 2>/dev/null | tr -d '[:space:]')
  case "$COUNT" in ''|*[!0-9]*) COUNT="" ;; esac

  if [ "$COUNT" = "0" ]; then
    # Silent-when-0: empty stdout, no banner.
    [ ! -s "$SB/out" ] \
      && check "[B] count 0 -> empty output (no systemMessage, silent)" ok \
      || check "[B] count 0 -> empty output (no systemMessage, silent)" fail "non-empty at 0"
  else
    # count > 0 -> a single valid JSON object with a .systemMessage banner.
    jq -e '.systemMessage | type == "string" and (. | length > 0)' "$SB/out" >/dev/null 2>&1 \
      && check "[B1] notify emits valid JSON with a .systemMessage banner" ok \
      || check "[B1] notify emits valid JSON with a .systemMessage banner" fail
    MSG=$(jq -r '.systemMessage // ""' "$SB/out" 2>/dev/null)
    case "$MSG" in
      *"cross-repo vitals"*) check "[B2] banner is the labeled cross-repo vitals banner" ok ;;
      *) check "[B2] banner is the labeled cross-repo vitals banner" fail ;;
    esac
    # No OSC/SetUserVar escape — the badge is NOT a hook's job.
    if grep -q 'SetUserVar' "$SB/out" || LC_ALL=C grep -q $'\033' "$SB/out"; then
      check "[B3] no OSC/SetUserVar escape in the banner (badge ≠ hook)" fail "found an escape"
    else
      check "[B3] no OSC/SetUserVar escape in the banner (badge ≠ hook)" ok
    fi
    # Distinct from the digest's awaiting_us "Action required" inbox.
    case "$MSG" in
      *"Action required"*) check "[B4] distinct from the digest's 'Action required' inbox" fail ;;
      *) check "[B4] distinct from the digest's 'Action required' inbox" ok ;;
    esac
  fi
fi

echo "---"
echo "$PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
