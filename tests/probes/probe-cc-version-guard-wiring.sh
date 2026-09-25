#!/usr/bin/env bash
# SAFE_FOR_LIVE: yes  (read-only grep of the in-repo dispatcher; behavioral smoke
#   runs the guard with CC_* override seams pointed at a mktemp sandbox — never
#   reads or writes live ~/.local/bin/claude or ~/.ccs/shared/cc-pinned-version)
#
# Exercises the SessionStart wiring of the fleet CC version-LOCK guard
# (cross-repo scripts/fleet/cc-version-guard.sh), wired into the hooks-repo
# dispatcher (dhx-plugin/plugins/dhx/hooks/session-start.sh) via the
# ~/.claude/dhx-tools/ indirection — the same provisioning shape as
# dhx-watch-health.cjs, NOT a direct ~/repos/cross-repo/ working-tree path.
#
# Two assertion groups:
#   A. WIRING (unconditional, self-contained — backs the decisions.md row):
#      the dispatcher invokes the guard through the dhx-tools install path,
#      behind an [ -e ] existence guard, with < /dev/null and a fail-open
#      || true, and does NOT couple to cross-repo's private scripts/fleet/
#      layout by absolute working-tree path.
#   B. BEHAVIORAL SMOKE (conditional — runs only when the installed guard at
#      ~/.claude/dhx-tools/cc-version-guard.sh is present & executable): T1 on-pin
#      silent no-op, T2 drift->repoint, T3 missing-pinned-binary WARNING+no-crash,
#      T4 missing lock-file silent. Sandboxed via CC_PINNED_VERSION_FILE /
#      CC_BIN_LINK / CC_VERSIONS_DIR seams. Skipped (not failed) when the guard
#      isn't provisioned, so the probe stays green in a fresh hooks clone with no
#      cross-repo checkout — matching the dispatcher's own [ -e ] graceful no-op.
#
# (dhx-tools indirection)" row.
# Run: bash tests/probes/probe-cc-version-guard-wiring.sh

#
# CC-STDERR-EXEMPT: spawns no Claude Code child. `$SB/bin/claude` is a symlink
#   PASSED to the dhx guard as CC_BIN_LINK and never executed; the classified
#   string is `$SB/err`, the guard script's own stderr, captured from
#   `bash "$INSTALLED_GUARD" < /dev/null 2>"$SB/err"`.
#   Convention: tests/probes/README.md § "A classifier's INPUT is a surface too".
#

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DISPATCHER="$REPO_ROOT/dhx-plugin/plugins/dhx/hooks/session-start.sh"
INSTALLED_GUARD="$HOME/.claude/dhx-tools/cc-version-guard.sh"

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [ "$cond" = "ok" ]; then echo "OK   $name"; PASS=$((PASS + 1))
  else echo "FAIL $name${3:+ ($3)}"; FAIL=$((FAIL + 1)); fi
}

echo "=== A. SessionStart dispatcher wiring (cc-version-guard) ==="

if [ ! -f "$DISPATCHER" ]; then
  check "dispatcher present at $DISPATCHER" "fail" "file missing"
  echo "---"; echo "$PASS passed, $FAIL failed"; exit 1
fi

# Pull the single non-comment line that invokes the guard.
GUARD_LINE=$(grep -nE '(^|[^#].*)cc-version-guard\.sh' "$DISPATCHER" | grep -v '^[0-9]*:[[:space:]]*#' || true)

[ -n "$GUARD_LINE" ] && check "dispatcher invokes cc-version-guard.sh" ok \
  || check "dispatcher invokes cc-version-guard.sh" "fail" "no non-comment invocation found"

# Invocation goes through the dhx-tools install path (stable interface), tilde-anchored.
grep -qE '\[ -e ~/\.claude/dhx-tools/cc-version-guard\.sh \]' "$DISPATCHER" \
  && check "invocation gated by [ -e ~/.claude/dhx-tools/cc-version-guard.sh ] existence guard" ok \
  || check "invocation gated by [ -e ~/.claude/dhx-tools/cc-version-guard.sh ] existence guard" "fail"

grep -qE 'bash ~/\.claude/dhx-tools/cc-version-guard\.sh' "$DISPATCHER" \
  && check "guard invoked via ~/.claude/dhx-tools/ (dhx-tools indirection, like dhx-watch-health.cjs)" ok \
  || check "guard invoked via ~/.claude/dhx-tools/ (dhx-tools indirection, like dhx-watch-health.cjs)" "fail"

# Filesystem-only: stdin closed with < /dev/null on the guard invocation line.
grep -qE '< */dev/null' <<<"$GUARD_LINE" \
  && check "guard invoked with < /dev/null (no stdin dependency)" ok \
  || check "guard invoked with < /dev/null (no stdin dependency)" "fail"

# Fail-open: trailing || true on the guard invocation line.
grep -qE '\|\| *true *$' <<<"$GUARD_LINE" \
  && check "guard invocation is fail-open (trailing || true)" ok \
  || check "guard invocation is fail-open (trailing || true)" "fail"

# Decoupling invariant: the dispatcher must NOT reach into cross-repo's private
# working-tree layout by absolute path (the Option-1 coupling we rejected). The
# stable ~/.claude/dhx-tools/ install path is the contract instead.
if grep -qE '/repos/cross-repo/.*cc-version-guard' "$DISPATCHER"; then
  check "dispatcher does NOT hardcode a ~/repos/cross-repo/ path for the guard" "fail" \
    "found direct cross-repo working-tree coupling"
else
  check "dispatcher does NOT hardcode a ~/repos/cross-repo/ path for the guard" ok
fi

echo "=== B. Behavioral smoke via override seams (sandboxed) ==="

# Resolve the guard the dispatcher would actually run. Skip the behavioral group
# (not fail) when cross-repo hasn't provisioned the symlink — mirrors the
# dispatcher's [ -e ] graceful no-op so the probe is green in a bare hooks clone.
if [ ! -e "$INSTALLED_GUARD" ] || [ ! -x "$(readlink -f "$INSTALLED_GUARD" 2>/dev/null)" ]; then
  echo "SKIP behavioral smoke — $INSTALLED_GUARD not provisioned (run cross-repo install-dhx-tools.sh)"
else
  SB=$(mktemp -d)
  trap 'rm -rf "$SB"' EXIT
  mkdir -p "$SB/versions" "$SB/bin"
  printf '#!/bin/sh\necho 2.1.159\n' > "$SB/versions/2.1.159"; chmod +x "$SB/versions/2.1.159"
  printf '#!/bin/sh\necho 2.1.153\n' > "$SB/versions/2.1.153"; chmod +x "$SB/versions/2.1.153"
  LOCK="$SB/cc-pinned-version"; LINK="$SB/bin/claude"; VDIR="$SB/versions"
  run_guard() {
    CC_PINNED_VERSION_FILE="$LOCK" CC_BIN_LINK="$LINK" CC_VERSIONS_DIR="$VDIR" \
      bash "$INSTALLED_GUARD" < /dev/null 2>"$SB/err"; echo "$?"
  }

  # T1: on-pin -> silent no-op, exit 0, link unchanged
  echo 2.1.159 > "$LOCK"; ln -sfn "$VDIR/2.1.159" "$LINK"
  rc=$(run_guard); errsz=$(wc -c < "$SB/err")
  [ "$rc" = "0" ] && [ "$errsz" -eq 0 ] && [ "$(basename "$(readlink "$LINK")")" = "2.1.159" ] \
    && check "[T1] on-pin -> silent no-op (rc=0, no stderr, link unchanged)" ok \
    || check "[T1] on-pin -> silent no-op (rc=0, no stderr, link unchanged)" "fail" "rc=$rc errsz=$errsz link=$(basename "$(readlink "$LINK")")"

  # T2: drift -> repoint to pinned, exit 0, stderr advisory present
  echo 2.1.159 > "$LOCK"; ln -sfn "$VDIR/2.1.153" "$LINK"
  rc=$(run_guard)
  [ "$rc" = "0" ] && [ "$(basename "$(readlink "$LINK")")" = "2.1.159" ] && grep -q 'repointed' "$SB/err" \
    && check "[T2] drift -> repoint to pinned (rc=0, link=2.1.159, stderr advisory)" ok \
    || check "[T2] drift -> repoint to pinned (rc=0, link=2.1.159, stderr advisory)" "fail" "rc=$rc link=$(basename "$(readlink "$LINK")")"

  # T3: drift but pinned binary missing -> WARNING, no crash (rc=0), link unchanged
  echo 2.1.999 > "$LOCK"; ln -sfn "$VDIR/2.1.153" "$LINK"
  rc=$(run_guard)
  [ "$rc" = "0" ] && [ "$(basename "$(readlink "$LINK")")" = "2.1.153" ] && grep -q 'WARNING' "$SB/err" \
    && check "[T3] missing pinned binary -> WARNING, fail-open (rc=0), link unchanged" ok \
    || check "[T3] missing pinned binary -> WARNING, fail-open (rc=0), link unchanged" "fail" "rc=$rc link=$(basename "$(readlink "$LINK")")"

  # T4: no lock file -> exit 0, silent, link unchanged
  rm -f "$LOCK"; ln -sfn "$VDIR/2.1.153" "$LINK"
  rc=$(run_guard); errsz=$(wc -c < "$SB/err")
  [ "$rc" = "0" ] && [ "$errsz" -eq 0 ] \
    && check "[T4] missing lock file -> exit 0 silent" ok \
    || check "[T4] missing lock file -> exit 0 silent" "fail" "rc=$rc errsz=$errsz"
fi

echo "---"
echo "$PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
