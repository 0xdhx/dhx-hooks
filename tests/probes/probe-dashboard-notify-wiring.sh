#!/usr/bin/env bash
# SAFE_FOR_LIVE: yes  (read-only grep of the in-repo dispatcher; behavioral smoke
#   runs `dhx-dashboard.cjs notify`, which only READS feeds + writes to stdout — it
#   does NOT write the variant-*.md files, that is the separate `render` subcommand)
#
# Exercises the SessionStart wiring of the cross-repo dashboard vitals notification
# (cross-repo scripts/dhx-dashboard.cjs `notify`), wired into the hooks-repo
# dispatcher (dhx-plugin/plugins/dhx/hooks/session-start.sh) via the
# ~/.claude/dhx-tools/ indirection — the same provisioning shape as
# dhx-watch-health.cjs / cc-version-guard.sh, NOT a direct ~/repos/cross-repo/ path.
#
# Two assertion groups:
#   A. WIRING (unconditional, self-contained — backs the decisions.md row):
#      the dispatcher invokes the `notify` subcommand through the dhx-tools install
#      path, behind an [ -e ] existence guard, with < /dev/null, a fail-open
#      || true, stdout NOT redirected (the badge OSC must reach the attached pane),
#      and does NOT couple to cross-repo's private scripts/ layout by absolute path.
#   B. BEHAVIORAL SMOKE (conditional — runs only when the installed tool at
#      ~/.claude/dhx-tools/dhx-dashboard.cjs is present and `node` is available):
#      the badge byte-shape (007's SetUserVar), the ONE-NAME invariant (emits
#      dhx_inbox_open, never dhx_actionable), badge==count consistency, the
#      tmux-passthrough vs bare OSC branch, and the silent-when-0 / labeled-distinct
#      banner contract. Asserts the OUTPUT CONTRACT against live state (count may
#      vary; structure is deterministic). Skipped (not failed) when cross-repo
#      hasn't provisioned the symlink — mirrors the dispatcher's [ -e ] no-op so the
#      probe stays green in a bare hooks clone with no cross-repo checkout.
#
# Backs docs/decisions.md 2026-06-04 "dhx-dashboard notify SessionStart wiring
# (badge + vitals banner)" row.
# Run: bash tests/probes/probe-dashboard-notify-wiring.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DISPATCHER="$REPO_ROOT/dhx-plugin/plugins/dhx/hooks/session-start.sh"
INSTALLED="$HOME/.claude/dhx-tools/dhx-dashboard.cjs"

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [ "$cond" = "ok" ]; then echo "OK   $name"; PASS=$((PASS + 1))
  else echo "FAIL $name${3:+ ($3)}"; FAIL=$((FAIL + 1)); fi
}

echo "=== A. SessionStart dispatcher wiring (dhx-dashboard notify) ==="

if [ ! -f "$DISPATCHER" ]; then
  check "dispatcher present at $DISPATCHER" "fail" "file missing"
  echo "---"; echo "$PASS passed, $FAIL failed"; exit 1
fi

# Pull the single non-comment line that invokes the dashboard tool.
NOTIFY_LINE=$(grep -nE '(^|[^#].*)dhx-dashboard\.cjs' "$DISPATCHER" | grep -v '^[0-9]*:[[:space:]]*#' || true)

[ -n "$NOTIFY_LINE" ] && check "dispatcher invokes dhx-dashboard.cjs" ok \
  || check "dispatcher invokes dhx-dashboard.cjs" "fail" "no non-comment invocation found"

# The `notify` subcommand specifically (not count/data/render — notify is the
# badge+banner SessionStart surface).
printf '%s\n' "$NOTIFY_LINE" | grep -qE 'dhx-dashboard\.cjs +notify' \
  && check "invokes the 'notify' subcommand (badge + vitals banner)" ok \
  || check "invokes the 'notify' subcommand (badge + vitals banner)" "fail"

# Gated by the dhx-tools existence guard (graceful no-op pre-provisioning).
grep -qE '\[ -e ~/\.claude/dhx-tools/dhx-dashboard\.cjs \]' "$DISPATCHER" \
  && check "invocation gated by [ -e ~/.claude/dhx-tools/dhx-dashboard.cjs ] existence guard" ok \
  || check "invocation gated by [ -e ~/.claude/dhx-tools/dhx-dashboard.cjs ] existence guard" "fail"

# dhx-tools indirection (stable interface), tilde-anchored.
grep -qE 'node ~/\.claude/dhx-tools/dhx-dashboard\.cjs' "$DISPATCHER" \
  && check "invoked via ~/.claude/dhx-tools/ (dhx-tools indirection, like dhx-watch-health.cjs)" ok \
  || check "invoked via ~/.claude/dhx-tools/ (dhx-tools indirection, like dhx-watch-health.cjs)" "fail"

# Filesystem-only: stdin closed with < /dev/null.
printf '%s\n' "$NOTIFY_LINE" | grep -qE '< */dev/null' \
  && check "invoked with < /dev/null (no stdin dependency)" ok \
  || check "invoked with < /dev/null (no stdin dependency)" "fail"

# Fail-open: trailing || true.
printf '%s\n' "$NOTIFY_LINE" | grep -qE '\|\| *true *$' \
  && check "invocation is fail-open (trailing || true)" ok \
  || check "invocation is fail-open (trailing || true)" "fail"

# LOAD-BEARING: stdout must NOT be redirected. The badge OSC reaches wezterm only
# by flowing to the SessionStart surface (attached pane); a `>/dev/null` here would
# silently swallow the badge. stderr (2>/dev/null) is fine; a bare or 1- stdout
# redirect is the failure. (od -c byte-shape itself is covered cross-repo + by 007.)
if printf '%s\n' "$NOTIFY_LINE" | grep -qE '(^|[^2])>[ ]*/dev/null|1>[ ]*/dev/null'; then
  check "stdout NOT redirected (badge OSC reaches the attached pane)" "fail" \
    "found a stdout redirect — the badge would be swallowed"
else
  check "stdout NOT redirected (badge OSC reaches the attached pane)" ok
fi

# Decoupling invariant: no absolute ~/repos/cross-repo/ working-tree path.
if grep -qE '/repos/cross-repo/.*dhx-dashboard' "$DISPATCHER"; then
  check "dispatcher does NOT hardcode a ~/repos/cross-repo/ path for the tool" "fail" \
    "found direct cross-repo working-tree coupling"
else
  check "dispatcher does NOT hardcode a ~/repos/cross-repo/ path for the tool" ok
fi

echo "=== B. Behavioral smoke — notify output contract (live state) ==="

if [ ! -e "$INSTALLED" ] || ! command -v node >/dev/null 2>&1; then
  echo "SKIP behavioral smoke — $INSTALLED not provisioned or node absent (run cross-repo install-dhx-tools.sh)"
else
  SB=$(mktemp -d)
  trap 'rm -rf "$SB"' EXIT

  # Run notify in both tmux states. notify reads live feeds; the COUNT may vary but
  # the output CONTRACT is deterministic.
  TMUX=fake node "$INSTALLED" notify </dev/null >"$SB/tmux.out" 2>/dev/null || true
  env -u TMUX node "$INSTALLED" notify </dev/null >"$SB/notmux.out" 2>/dev/null || true
  COUNT=$(node "$INSTALLED" count </dev/null 2>/dev/null | tr -d '[:space:]')
  case "$COUNT" in ''|*[!0-9]*) COUNT="" ;; esac

  # B1: badge present + correct var name (the live Lua reads dhx_inbox_open).
  grep -q 'SetUserVar=dhx_inbox_open=' "$SB/tmux.out" \
    && check "[B1] emits the dhx_inbox_open badge (matches live ~/.wezterm.lua)" ok \
    || check "[B1] emits the dhx_inbox_open badge (matches live ~/.wezterm.lua)" "fail"

  # B2: ONE-NAME invariant — never the retired spike var dhx_actionable.
  if grep -q 'dhx_actionable' "$SB/tmux.out"; then
    check "[B2] one var name — no dhx_actionable (don't ship two names)" "fail" "found dhx_actionable"
  else
    check "[B2] one var name — no dhx_actionable (don't ship two names)" ok
  fi

  # B3: tmux-passthrough wrapper present under $TMUX; absent without it.
  if grep -q 'Ptmux;' "$SB/tmux.out" && ! grep -q 'Ptmux;' "$SB/notmux.out"; then
    check "[B3] tmux DCS passthrough under \$TMUX; bare OSC without it" ok
  else
    check "[B3] tmux DCS passthrough under \$TMUX; bare OSC without it" "fail"
  fi

  # B4: badge payload == `count` (base64 of the same integer). Strip only the known
  # prefix — a greedy `.*=` would eat the base64 `==` padding (it did, once).
  B64=$(grep -oE 'SetUserVar=dhx_inbox_open=[A-Za-z0-9+/=]+' "$SB/notmux.out" | head -1)
  B64="${B64#SetUserVar=dhx_inbox_open=}"
  DECODED=$(printf '%s' "$B64" | base64 -d 2>/dev/null)
  if [ -n "$COUNT" ] && [ "$DECODED" = "$COUNT" ]; then
    check "[B4] badge payload base64-decodes to the count ($COUNT)" ok
  else
    check "[B4] badge payload base64-decodes to the count" "fail" "decoded='$DECODED' count='$COUNT'"
  fi

  # B5: banner contract — distinct from the awaiting_us "Action required" inbox, and
  # silent-when-0 (deterministic via the decoded count).
  if grep -q 'Action required' "$SB/tmux.out"; then
    check "[B5a] vitals banner does NOT reuse 'Action required' (labeled-distinct)" "fail"
  else
    check "[B5a] vitals banner does NOT reuse 'Action required' (labeled-distinct)" ok
  fi
  if [ "$DECODED" = "0" ]; then
    grep -q 'cross-repo vitals' "$SB/tmux.out" \
      && check "[B5b] count 0 -> badge only, no visible vitals banner (silent-when-0)" "fail" "banner present at 0" \
      || check "[B5b] count 0 -> badge only, no visible vitals banner (silent-when-0)" ok
  else
    grep -q 'cross-repo vitals' "$SB/tmux.out" \
      && check "[B5b] count >0 -> labeled vitals banner present" ok \
      || check "[B5b] count >0 -> labeled vitals banner present" "fail"
  fi
fi

echo "---"
echo "$PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
