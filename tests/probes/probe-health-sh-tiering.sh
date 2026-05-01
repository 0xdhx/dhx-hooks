#!/bin/bash
# Probe: scripts/health.sh exit-code tier matrix (D-18 critical-wins precedence)
# + 30s timeout-as-fail mapping (D-19 timeout shape) + D-30 NDJSON empty-array
# shape (`critical_failures` is `[]`, NOT `[""]`, when no critical fails).
#
# Builds a fake repo under mktemp containing stub leaf-tools that exit with
# controlled return codes; invokes scripts/health.sh under DHX_HEALTH_REPO_ROOT
# pointing at the fake repo; asserts the script's overall exit matches the
# expected tier matrix:
#   - all-ok                    → 0
#   - 1 critical fails          → 1
#   - 1 advisory fails          → 2
#   - both critical + advisory  → 1 (critical wins, D-18)
#   - 1 stub sleeps 35s         → 1 (timeout maps to fail in critical tier)
#
# Then runs --json mode against an all-ok stub set and asserts:
#   - aggregate `_aggregate` is the LAST line (D-08)
#   - `critical_failures == []` (D-30 — empty arrays must be `[]` not `[""]`)
#   - `critical_failures | type == "array"` (defends against jq-pipeline drift)
#   - `advisory_failures == []` (D-30 same applies to advisory side)
#
# Backs decisions.md 2026-05-01 row "health.sh tiered exit precedence" + D-30
# NDJSON aggregate empty-array shape (jq -n --args form).
# Run: bash tests/probes/probe-health-sh-tiering.sh
# SAFE_FOR_LIVE: no   (mktemp + fake HOME confines writes; uses stub-leaf-tool fixtures)
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
    echo "     got:  $got"
    echo "     want: $want"
    fail=$((fail+1))
  fi
}

# Stage a fake repo containing stub leaf-tools. Each stub honors a per-call
# rc value passed through filename. The git stub on PATH returns the rc passed
# in via the GIT_DIFF_RC envar so health.sh's `git diff --quiet config/...`
# check returns the desired status.
stage_fakerepo() {
  local root="$1"
  local verify_rc="$2" plugkeys_rc="$3" bashheal_rc="$4" \
        settpath_rc="$5" hookwire_rc="$6" \
        sleep_in_verify="$7"
  mkdir -p "$root/scripts" "$root/tests/probes" \
           "$root/dhx-plugin/.claude-plugin" \
           "$root/scripts/lib"
  echo '{}' > "$root/dhx-plugin/.claude-plugin/marketplace.json"

  # verify-hooks.sh stub (optionally sleep 35 to trigger timeout)
  {
    echo '#!/bin/bash'
    [[ "$sleep_in_verify" == "yes" ]] && echo 'sleep 35'
    echo "exit $verify_rc"
  } > "$root/scripts/verify-hooks.sh"

  printf '#!/bin/bash\nexit %s\n' "$plugkeys_rc"  > "$root/tests/probes/probe-plugin-keys.sh"
  printf '#!/bin/bash\nexit %s\n' "$bashheal_rc"  > "$root/tests/probes/probe-bashrc-wrapper-heal.sh"
  printf '#!/bin/bash\nexit %s\n' "$settpath_rc"  > "$root/tests/probes/probe-settings-path-invariant.sh"
  printf '#!/bin/bash\nexit %s\n' "$hookwire_rc"  > "$root/tests/probes/probe-hooks-wiring.sh"
  chmod +x "$root/scripts/verify-hooks.sh" "$root/tests/probes/"*.sh

  # Copy tiers.{json,sh} so health.sh can source them under fake repo
  cp "$REPO/scripts/lib/tiers.json" "$root/scripts/lib/"
  cp "$REPO/scripts/lib/tiers.sh"   "$root/scripts/lib/"
}

# git shim: PATH override. Inspects argv for the `diff` token (matching
# health.sh's `git -C REPO diff --quiet config/settings.json` invocation
# shape) and exits with the configured rc. All non-diff calls fall through
# to /usr/bin/git so other usage isn't disrupted.
make_git_shim() {
  local bindir="$1" diff_rc="$2"
  mkdir -p "$bindir"
  # NOTE: heredoc body is intentionally quoted ('GITSHIM') so backticks and
  # $-expansions in the comments below don't run at write-time. The diff_rc
  # value is sed-injected after.
  cat > "$bindir/git" <<'GITSHIM'
#!/bin/bash
# match: git -C REPO diff --quiet config/settings.json
for a in "$@"; do
  if [[ "$a" == "diff" ]]; then exit __DIFF_RC__; fi
done
exec /usr/bin/git "$@"
GITSHIM
  sed -i "s/__DIFF_RC__/$diff_rc/" "$bindir/git"
  chmod +x "$bindir/git"
}

# run_case: stage fake repo + git shim, invoke health.sh, assert exit code.
# Args: name, verify_rc, plugkeys_rc, bashheal_rc, settpath_rc, hookwire_rc,
#       gitdiff_rc, sleep_in_verify, expected_health_rc
run_case() {
  local name="$1" verify_rc="$2" plugkeys_rc="$3" bashheal_rc="$4" \
        settpath_rc="$5" hookwire_rc="$6" gitdiff_rc="$7" \
        sleep_in_verify="$8" expected_health_rc="$9"

  local TMP
  TMP=$(mktemp -d)
  trap "rm -rf '$TMP'" RETURN

  stage_fakerepo "$TMP/fakerepo" "$verify_rc" "$plugkeys_rc" \
                 "$bashheal_rc" "$settpath_rc" "$hookwire_rc" \
                 "$sleep_in_verify"
  make_git_shim "$TMP/bin" "$gitdiff_rc"

  PATH="$TMP/bin:$PATH" \
  DHX_HEALTH_REPO_ROOT="$TMP/fakerepo" \
    bash "$REPO/scripts/health.sh" >/dev/null 2>&1
  local got=$?
  assert_eq "$name (expected exit $expected_health_rc)" "$got" "$expected_health_rc"
}

# Tier matrix scenarios
run_case "all-ok"                       0 0 0 0 0 0 no  0
run_case "verify-hooks fail (critical)" 1 0 0 0 0 0 no  1
run_case "git-diff fail (advisory)"     0 0 0 0 0 1 no  2
run_case "both critical+advisory fail"  1 0 0 0 0 1 no  1
run_case "verify-hooks timeout"         0 0 0 0 0 0 yes 1

# JSON-mode well-formedness + D-30 empty-array shape under all-ok
JSON_TMP=$(mktemp -d)
trap "rm -rf '$JSON_TMP'" EXIT

stage_fakerepo "$JSON_TMP/fakerepo" 0 0 0 0 0 no
make_git_shim "$JSON_TMP/bin" 0

PATH="$JSON_TMP/bin:$PATH" \
DHX_HEALTH_REPO_ROOT="$JSON_TMP/fakerepo" \
  bash "$REPO/scripts/health.sh" --json > "$JSON_TMP/out.json" 2>/dev/null

# Last line is the aggregate?
last_line=$(tail -n1 "$JSON_TMP/out.json")
if jq -e '.check == "_aggregate"' <<<"$last_line" >/dev/null 2>&1; then
  echo "OK   --json aggregate is last line"; pass=$((pass+1))
else
  echo "FAIL --json aggregate not last line"
  echo "     last_line: $last_line"
  fail=$((fail+1))
fi

# D-30: empty critical_failures must be `[]`, NOT `[""]` (printf-pipeline bug)
if jq -e '.critical_failures == []' <<<"$last_line" >/dev/null 2>&1; then
  echo "OK   D-30 empty critical_failures is [] (not [\"\"])"; pass=$((pass+1))
else
  empty_got=$(jq -c '.critical_failures' <<<"$last_line" 2>/dev/null || echo '<unparseable>')
  echo "FAIL D-30 empty critical_failures expected [], got $empty_got"
  fail=$((fail+1))
fi

# D-30: explicit type-array assertion (defense against jq-pipeline drift)
if jq -e '.critical_failures | type == "array"' <<<"$last_line" >/dev/null 2>&1; then
  echo "OK   D-30 critical_failures type is array"; pass=$((pass+1))
else
  echo "FAIL D-30 critical_failures not an array"
  fail=$((fail+1))
fi

# D-30: same for advisory_failures
if jq -e '.advisory_failures == []' <<<"$last_line" >/dev/null 2>&1; then
  echo "OK   D-30 empty advisory_failures is []"; pass=$((pass+1))
else
  adv_got=$(jq -c '.advisory_failures' <<<"$last_line" 2>/dev/null || echo '<unparseable>')
  echo "FAIL D-30 empty advisory_failures expected [], got $adv_got"
  fail=$((fail+1))
fi

echo
echo "$pass passed, $fail failed"
exit $fail
