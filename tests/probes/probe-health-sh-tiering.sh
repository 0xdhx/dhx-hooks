#!/bin/bash
# Probe: scripts/health.sh exit-code tier matrix (D-18 critical-wins precedence)
# + timeout-as-fail mapping (D-19 timeout shape) + D-30 NDJSON empty-array
# shape (`critical_failures` is `[]`, NOT `[""]`, when no critical fails)
# + DHX_HEALTH_TIMEOUT env-var support (G-04-01 closure — see 04-04-PLAN.md).
#
# Builds a fake repo under mktemp containing stub leaf-tools that exit with
# controlled return codes; invokes scripts/health.sh under DHX_HEALTH_REPO_ROOT
# pointing at the fake repo; asserts the script's overall exit matches the
# expected tier matrix:
#   - all-ok                    → 0
#   - 1 critical fails          → 1
#   - 1 advisory fails          → 2
#   - both critical + advisory  → 1 (critical wins, D-18)
#   - 1 stub sleeps 4s under DHX_HEALTH_TIMEOUT=2 → 1 (timeout maps to fail
#     in critical tier; reduced from the prior 35-second stub sleep to keep
#     probe inside D-16's 30s budget per G-04-01)
#
# Then runs --json mode against an all-ok stub set and asserts:
#   - aggregate `_aggregate` is the LAST line (D-08)
#   - `critical_failures == []` (D-30 — empty arrays must be `[]` not `[""]`)
#   - `critical_failures | type == "array"` (defends against jq-pipeline drift)
#   - `advisory_failures == []` (D-30 same applies to advisory side)
#
# Plus a separate timeout-staged block under DHX_HEALTH_TIMEOUT=2 asserts
# duration_ms=2000 (PLANNER CALL #2 dynamic-duration_ms invariant under
# override) AND a separate bare-output block asserts `[TIMEOUT 2s]` (bare
# side of CALL #2). Default-unchanged loose-regex grep (D-34) locks the
# `${DHX_HEALTH_TIMEOUT-30}` no-colon form (D-32). Strict-refusal block
# asserts foo / empty / 0 / -1 all exit 1 with diagnostic.
#
# Backs decisions.md 2026-05-01 row "health.sh tiered exit precedence" + D-30
# NDJSON aggregate empty-array shape (jq -n --args form) + G-04-01 closure
# (DHX_HEALTH_TIMEOUT operator-ergonomics fix).
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

  # verify-hooks.sh stub (optionally sleeps to trigger the timeout case;
  # length is 4s, calibrated for DHX_HEALTH_TIMEOUT=2 to keep total probe
  # runtime well inside D-16's 30s budget — see G-04-01 closure)
  {
    echo '#!/bin/bash'
    [[ "$sleep_in_verify" == "yes" ]] && echo 'sleep 4'
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
#       gitdiff_rc, sleep_in_verify, expected_health_rc, [case_env_pairs]
#
# case_env_pairs (optional, default empty): a SPACE-SEPARATED string of
# KEY=VAL tokens (e.g. "DHX_HEALTH_TIMEOUT=2") injected via POSIX `env`
# form per D-33. The original draft `$extra_env PATH=... bash ...` is
# UNSAFE — Bash recognizes assignment words SYNTACTICALLY before parameter
# expansion, so an expanded `$case_env_pairs` token containing
# `DHX_HEALTH_TIMEOUT=2` is parsed as a command name (rc=127), NOT as an
# env assignment. POSIX `env` form composes correctly with the existing
# `PATH=` and `DHX_HEALTH_REPO_ROOT=` assignment words and is no-op when
# `$case_env_pairs` is empty.
#
# `$case_env_pairs` is INTENTIONALLY unquoted in the env invocation so
# word-splitting expands `"DHX_HEALTH_TIMEOUT=2"` into a single env-pair
# argument to `env`.
run_case() {
  local name="$1" verify_rc="$2" plugkeys_rc="$3" bashheal_rc="$4" \
        settpath_rc="$5" hookwire_rc="$6" gitdiff_rc="$7" \
        sleep_in_verify="$8" expected_health_rc="$9"
  local case_env_pairs="${10:-}"

  local TMP
  TMP=$(mktemp -d)
  trap "rm -rf '$TMP'" RETURN

  stage_fakerepo "$TMP/fakerepo" "$verify_rc" "$plugkeys_rc" \
                 "$bashheal_rc" "$settpath_rc" "$hookwire_rc" \
                 "$sleep_in_verify"
  make_git_shim "$TMP/bin" "$gitdiff_rc"

  # D-33: POSIX `env` form for safe composition of optional case env pairs.
  # `$case_env_pairs` is intentionally unquoted (word-splitting required).
  env $case_env_pairs PATH="$TMP/bin:$PATH" \
      DHX_HEALTH_REPO_ROOT="$TMP/fakerepo" \
      bash "$REPO/scripts/health.sh" >/dev/null 2>&1
  local got=$?
  assert_eq "$name (expected exit $expected_health_rc)" "$got" "$expected_health_rc"
}

# Tier matrix scenarios
run_case "all-ok"                       0 0 0 0 0 0 no  0  ""
run_case "verify-hooks fail (critical)" 1 0 0 0 0 0 no  1  ""
run_case "git-diff fail (advisory)"     0 0 0 0 0 1 no  2  ""
run_case "both critical+advisory fail"  1 0 0 0 0 1 no  1  ""
run_case "verify-hooks timeout"         0 0 0 0 0 0 yes 1  "DHX_HEALTH_TIMEOUT=2"

# ── PLANNER DISCRETION CALL — verify health.sh default behavior is preserved.
# Loose-regex form per D-34: tolerates whitespace, comment additions, line-splitting.
# Note `-30` (no colon) per D-32 — `${VAR:-30}` would silently fall back to 30 on
# empty-string and defeat the strict-refusal contract.
if grep -qE 'TIMEOUT_S=.*DHX_HEALTH_TIMEOUT-30' "$REPO/scripts/health.sh"; then
  echo "OK   default DHX_HEALTH_TIMEOUT fallback expression (no-colon form) is 30"; pass=$((pass+1))
else
  echo "FAIL default DHX_HEALTH_TIMEOUT fallback expression not found in health.sh"; fail=$((fail+1))
fi
if grep -qE 'timeout "\$TIMEOUT_S" bash -c' "$REPO/scripts/health.sh"; then
  echo "OK   main-loop uses TIMEOUT_S indirection"; pass=$((pass+1))
else
  echo "FAIL main-loop timeout invocation does not use \$TIMEOUT_S"; fail=$((fail+1))
fi

# ── PLANNER DISCRETION CALL #1 — strict refusal on invalid DHX_HEALTH_TIMEOUT
INVALID_OUT=$(DHX_HEALTH_TIMEOUT=foo bash "$REPO/scripts/health.sh" 2>&1; echo "RC=$?")
if echo "$INVALID_OUT" | grep -qE 'invalid DHX_HEALTH_TIMEOUT' && echo "$INVALID_OUT" | grep -qE 'RC=1$'; then
  echo "OK   DHX_HEALTH_TIMEOUT=foo refused with diagnostic + exit 1"; pass=$((pass+1))
else
  echo "FAIL DHX_HEALTH_TIMEOUT=foo did not refuse correctly"
  echo "     output: $INVALID_OUT"
  fail=$((fail+1))
fi
# Also test empty + zero + negative
# NOTE: empty-string ('') tests the no-colon ${VAR-30} form — ${VAR:-30} would
# silently fall back to 30 here and the assertion would FAIL. D-32 fix is load-bearing.
for bad in '' '0' '-1'; do
  BAD_OUT=$(DHX_HEALTH_TIMEOUT="$bad" bash "$REPO/scripts/health.sh" 2>&1; echo "RC=$?")
  if echo "$BAD_OUT" | grep -qE 'RC=1$' && echo "$BAD_OUT" | grep -qE 'invalid DHX_HEALTH_TIMEOUT'; then
    echo "OK   DHX_HEALTH_TIMEOUT='$bad' refused"; pass=$((pass+1))
  else
    echo "FAIL DHX_HEALTH_TIMEOUT='$bad' not refused"
    echo "     output: $BAD_OUT"
    fail=$((fail+1))
  fi
done

# All three tmpdirs created upfront so a single EXIT trap (D-38) can cover
# them. Per-block `rm -rf` at end-of-block is vulnerable to leak on early-exit
# under `set -uo pipefail` + assertion-failure accumulator, hence the single
# extended-trap pattern. Trap declared ONCE here at first new-tmpdir creation
# site; not redeclared per block.
JSON_TMP=$(mktemp -d)
JSON_DYN_TMP=$(mktemp -d)
BARE_DYN_TMP=$(mktemp -d)
trap "rm -rf '$JSON_TMP' '$JSON_DYN_TMP' '$BARE_DYN_TMP'" EXIT

# ── PLANNER DISCRETION CALL #2 — dynamic duration_ms reflects DHX_HEALTH_TIMEOUT
# Stage a timeout-triggering stub set (sleep 4 in verify-hooks) under
# DHX_HEALTH_TIMEOUT=2 and assert the resulting per-check JSON object has
# .status == "timeout" AND .duration_ms == 2000 (NOT the hardcoded 30000).
stage_fakerepo "$JSON_DYN_TMP/fakerepo" 0 0 0 0 0 yes
make_git_shim "$JSON_DYN_TMP/bin" 0
# D-33: POSIX `env` form for assignment-word safety (consistent with run_case).
env DHX_HEALTH_TIMEOUT=2 PATH="$JSON_DYN_TMP/bin:$PATH" \
    DHX_HEALTH_REPO_ROOT="$JSON_DYN_TMP/fakerepo" \
    bash "$REPO/scripts/health.sh" --json > "$JSON_DYN_TMP/out.json" 2>/dev/null
# Find the timeout-status line for verify-hooks
timeout_line=$(grep -E '"check":"verify-hooks"' "$JSON_DYN_TMP/out.json" || true)
if jq -e '.status == "timeout" and .duration_ms == 2000' <<<"$timeout_line" >/dev/null 2>&1; then
  echo "OK   D-19 + CALL#2 — duration_ms=2000 under DHX_HEALTH_TIMEOUT=2 (NOT 30000)"; pass=$((pass+1))
else
  dur_got=$(jq -c '.duration_ms' <<<"$timeout_line" 2>/dev/null || echo '<unparseable>')
  echo "FAIL CALL#2 — duration_ms expected 2000, got $dur_got"
  echo "     timeout_line: $timeout_line"
  fail=$((fail+1))
fi

# ── PLANNER DISCRETION CALL #2 — bare-output dynamic timeout string
# Stage same timeout-triggering stub set; assert bare output emits
# `[TIMEOUT 2s]` (NOT `[TIMEOUT 30s]`) under DHX_HEALTH_TIMEOUT=2.
# D-38: BARE_DYN_TMP cleanup is owned by the single EXIT trap above; do NOT
# rm -rf at end of block (early-exit under set -uo pipefail would leak).
stage_fakerepo "$BARE_DYN_TMP/fakerepo" 0 0 0 0 0 yes
make_git_shim "$BARE_DYN_TMP/bin" 0
# D-33: POSIX `env` form for assignment-word safety (consistent with run_case).
BARE_OUT=$(env DHX_HEALTH_TIMEOUT=2 PATH="$BARE_DYN_TMP/bin:$PATH" \
               DHX_HEALTH_REPO_ROOT="$BARE_DYN_TMP/fakerepo" \
               bash "$REPO/scripts/health.sh" 2>&1 || true)
if echo "$BARE_OUT" | grep -qE '\[TIMEOUT 2s\] verify-hooks'; then
  echo "OK   bare output emits [TIMEOUT 2s] under DHX_HEALTH_TIMEOUT=2"; pass=$((pass+1))
else
  echo "FAIL bare output did not emit [TIMEOUT 2s]"
  echo "     output: $BARE_OUT"
  fail=$((fail+1))
fi
# NO `rm -rf "$BARE_DYN_TMP"` here — owned by the EXIT trap (D-38).

# JSON-mode well-formedness + D-30 empty-array shape under all-ok
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
