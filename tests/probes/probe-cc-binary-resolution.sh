#!/bin/bash
# probe-cc-binary-resolution.sh
#
# SAFE_FOR_LIVE: yes  (mktemp fixtures + fake binaries only; never spawns real
#                      Claude Code, never reads or writes live config or the corpus)
# RUNTIME: ~1s
#
# Pins tests/probes/lib/resolve-cc-binary.sh — the single-binary resolver used by
# the three probe-installed-plugins-*-natural-heal.sh supersession watchdogs to
# pick ONE Claude Code binary for both the measurement and the corpus cell's
# release label.
#
# WHY A SEPARATE PROBE. Its three consumers are all SAFE_FOR_LIVE: no, so the
# pre-commit hermetic tier can NEVER execute them: assertions written inside
# those files would not run at commit time, which is exactly the unwatched-guard
# shape the 2026-09-18 effort-probe row retired. The resolver therefore lives in
# a lib and is SOURCED here rather than transcribed — a copied regex passes while
# the shipped one is wrong — and rather than sourcing the consuming probes, which
# are executable programs that run setup, install traps and call `exit`.
#
# Section 4 is a SOURCE CENSUS, not a behaviour test: it re-reads the three
# consumers and reds if a bare `claude` invocation reappears. The resolver being
# correct is worth nothing if a future edit stops calling it, and no runtime
# assertion in the tier can catch that (the tier never runs those probes).
#
# Backs:
#   - docs/decisions.md 2026-09-18 single-binary attribution row
#   - tests/probes/lib/resolve-cc-binary.sh (the unit under test)
#   - .planning/backlog/2026-09-18-installed-plugins-probes-resolve-claude-twice-toctou-misfiles-cell.md
#
# Run: bash tests/probes/probe-cc-binary-resolution.sh
#
# CC-STDERR-EXEMPT: this IS lib/cc-cell-stderr.sh's pinning cell (§ 5). It
#   sources the lib to test it, never to clean a capture: it spawns no Claude
#   Code child at all — its "binaries" are `printf '#!/bin/sh...'` stubs — and
#   § 5 classifies a VERBATIM pinned advisory string on purpose, because that
#   string is the subject under test. Filtering it would delete the test.
#   Convention: tests/probes/README.md § "A classifier's INPUT is a surface too".
#

set -uo pipefail

PROBE_ID="probe-cc-binary-resolution"
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/resolve-cc-binary.sh
source "$HERE/lib/resolve-cc-binary.sh"
# shellcheck source=lib/cc-cell-stderr.sh
source "$HERE/lib/cc-cell-stderr.sh"

PASS=0
FAIL=0
assert_eq() {  # label expected actual
  if [[ "$2" == "$3" ]]; then
    printf 'OK   %s\n' "$1"; PASS=$((PASS + 1))
  else
    printf 'FAIL %s (expected %q, got %q)\n' "$1" "$2" "$3"; FAIL=$((FAIL + 1))
  fi
}
assert_rc() {  # label expected_rc actual_rc
  assert_eq "$1" "$2" "$3"
}

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# ---------------------------------------------------------------------------
# Fixtures: fake "binaries". Never the real Claude Code — this probe runs in the
# commit gate and must spawn nothing that authenticates, costs tokens or waits.
# ---------------------------------------------------------------------------
mkdir -p "$T/versions/2.1.999" "$T/elsewhere"
# A version-named executable: basename IS the dotted triple (the installed layout).
printf '#!/bin/sh\necho "SHOULD NOT BE CALLED"\n' > "$T/versions/2.1.999/bin"
# Name the file itself as a version, matching ~/.local/share/claude/versions/<v>
cp "$T/versions/2.1.999/bin" "$T/versions/2.1.999.exe"
mv "$T/versions/2.1.999.exe" "$T/2.1.999"
chmod +x "$T/2.1.999"
# A NON-version-named executable that answers --version with a banner.
printf '#!/bin/sh\necho "2.1.888 (Claude Code)"\n' > "$T/elsewhere/claude-build"
chmod +x "$T/elsewhere/claude-build"
# A NON-version-named executable whose --version says nothing usable.
printf '#!/bin/sh\necho "no version here"\n' > "$T/elsewhere/mute"
chmod +x "$T/elsewhere/mute"
# A non-executable file.
printf 'not a binary\n' > "$T/elsewhere/inert"
# A symlink chain pointing at the version-named binary.
ln -s "$T/2.1.999" "$T/link-to-version"

# ---------------------------------------------------------------------------
# 1. resolve_cc_binary — selection and canonicalization
# ---------------------------------------------------------------------------
echo "### 1. resolve_cc_binary"

out=$(resolve_cc_binary "$T/2.1.999"); rc=$?
assert_rc "explicit executable resolves"            0 "$rc"
assert_eq "explicit executable returns that path"   "$T/2.1.999" "$out"

# The canonicalization that closes the resolve-twice race in miniature: an
# accepted symlink would be re-resolved by the kernel at exec, so the version
# read and the launch could disagree. Every returned path is readlink -f'd.
out=$(resolve_cc_binary "$T/link-to-version"); rc=$?
assert_rc "symlink resolves"                        0 "$rc"
assert_eq "symlink is CANONICALIZED, not passed through" "$T/2.1.999" "$out"

out=$(resolve_cc_binary "$T/elsewhere/inert"); rc=$?
assert_rc "non-executable file REFUSES"             1 "$rc"
assert_eq "non-executable returns nothing"          "" "$out"

out=$(resolve_cc_binary "$T/nope/missing"); rc=$?
assert_rc "missing explicit path REFUSES"           1 "$rc"
assert_eq "missing explicit returns nothing"        "" "$out"

# The no-silent-fallback rule at the SELECTION layer. Asking for a specific
# binary and silently getting a different one is the attribution bug wearing a
# different hat, so a bad --binary must never fall through to the default.
HOME_SAVED="$HOME"
mkdir -p "$T/fakehome/.local/bin"
ln -sf "$T/2.1.999" "$T/fakehome/.local/bin/claude"
out=$(HOME="$T/fakehome" resolve_cc_binary "$T/nope/missing"); rc=$?
assert_rc "bad explicit does NOT fall back to the default"  1 "$rc"
assert_eq "bad explicit yields nothing even with a good default" "" "$out"
out=$(HOME="$T/fakehome" resolve_cc_binary ""); rc=$?
assert_rc "empty explicit uses the HOME default"    0 "$rc"
assert_eq "HOME default canonicalizes through the symlink" "$T/2.1.999" "$out"
out=$(HOME="$T/emptyhome" resolve_cc_binary ""); rc=$?
assert_rc "absent HOME default REFUSES"             1 "$rc"
export HOME="$HOME_SAVED"

# ---------------------------------------------------------------------------
# 2. resolve_cc_version — label derivation from the SAME binary
# ---------------------------------------------------------------------------
echo "### 2. resolve_cc_version"

out=$(resolve_cc_version "$T/2.1.999"); rc=$?
assert_rc "version-named basename resolves"         0 "$rc"
assert_eq "basename taken as the version"           "2.1.999" "$out"

out=$(resolve_cc_version "$T/elsewhere/claude-build"); rc=$?
assert_rc "non-version basename falls through to --version" 0 "$rc"
assert_eq "banner parsed to a bare triple"          "2.1.888" "$out"

out=$(resolve_cc_version "$T/elsewhere/mute"); rc=$?
assert_rc "unparseable --version REFUSES"           1 "$rc"
assert_eq "unparseable --version yields nothing"    "" "$out"

out=$(resolve_cc_version "$T/elsewhere/inert"); rc=$?
assert_rc "non-executable REFUSES a version"        1 "$rc"
out=$(resolve_cc_version ""); rc=$?
assert_rc "empty path REFUSES a version"            1 "$rc"

# ---------------------------------------------------------------------------
# 3. cc_version_is_sane — the label reaches a FILESYSTEM PATH
# ---------------------------------------------------------------------------
echo "### 3. cc_version_is_sane"

cc_version_is_sane "2.1.276";      assert_rc "bare triple is sane"          0 "$?"
cc_version_is_sane "";             assert_rc "empty is NOT sane"            1 "$?"
cc_version_is_sane "unknown";      assert_rc "'unknown' is NOT sane"        1 "$?"
cc_version_is_sane "../../../etc"; assert_rc "traversal is NOT a version"   1 "$?"
cc_version_is_sane "2.1.276/../x"; assert_rc "triple + traversal is NOT sane" 1 "$?"
cc_version_is_sane "2.1.276 (Claude Code)"; assert_rc "banner is NOT a bare version" 1 "$?"

# ---------------------------------------------------------------------------
# 4. Source census — the consumers must still USE the resolver
# ---------------------------------------------------------------------------
# A correct resolver that nobody calls is worth nothing, and the tier cannot
# catch that at runtime: all three consumers are SAFE_FOR_LIVE: no. So assert it
# at the source level. Comments and `echo` strings legitimately mention `claude`;
# only EXECUTABLE invocations are counted.
echo "### 4. consumers still route through the resolver"

CONSUMERS=(
  "probe-installed-plugins-no-natural-heal.sh"
  "probe-installed-plugins-badjson-natural-heal.sh"
  "probe-installed-plugins-uninstalled-dhx-natural-heal.sh"
)
for c in "${CONSUMERS[@]}"; do
  f="$HERE/$c"
  if [[ ! -f "$f" ]]; then
    printf 'FAIL consumer missing: %s\n' "$c"; FAIL=$((FAIL + 1)); continue
  fi
  # Strip comments and echo lines, then look for an executable bare `claude`.
  stray=$(grep -nE '(timeout [0-9]+ claude\b|[^-[:alnum:]_/"]claude (--version|-p|--bare)\b)' "$f" \
            | grep -vE ':[[:space:]]*#' | grep -v 'echo ' || true)
  assert_eq "$c: no executable bare \`claude\`" "" "$stray"

  n=$(grep -c 'source "$(dirname "$0")/lib/resolve-cc-binary.sh"' "$f" || true)
  assert_eq "$c: sources the resolver lib"     "1" "$n"

  n=$(grep -c 'resolve_cc_binary' "$f" || true)
  [[ "$n" -ge 1 ]] && n=ok
  assert_eq "$c: calls resolve_cc_binary"      "ok" "$n"

  # Every measurement goes through the single launch helper, so cell 1 and the
  # --bare control cannot drift onto different binaries (the filed brief covered
  # only cell 1; converting one measurement leaves the window open for the other).
  n=$(grep -c 'timeout 30 "\$BIN"' "$f" || true)
  assert_eq "$c: launch helper invokes the pinned \$BIN" "1" "$n"

  # No "unknown" label fallback may survive: a borrowed label is not evidence.
  n=$(grep -c 'CC_VERSION="unknown"' "$f" || true)
  assert_eq "$c: no 'unknown' version fallback" "0" "$n"

  # The publish guard that stops a non-observation evicting an observation.
  n=$(grep -c 'publish-guard' "$f" || true)
  [[ "$n" -ge 1 ]] && n=ok
  assert_eq "$c: has the publish guard"        "ok" "$n"
done

# ---------------------------------------------------------------------------
# 5. strip_cc_config_advisories — the cell's OUTCOME vs advisories about its INPUT
# ---------------------------------------------------------------------------
# The regression this pins is not hypothetical: it is the VERBATIM stderr that
# made all three consumers report `timeout_124` on rc=0 cells the moment the
# single-binary fix revived them (2026-09-18, 3/3).
echo "### 5. strip_cc_config_advisories"

LIVE_ADVISORY='Permission allow rule (../cfg/settings.json): Bash(timeout * gh *) has a wildcard before the rest of the command, so it also matches any options inserted at that position and approves them without a prompt. Replace that * with the exact value you mean, or only use * after the subcommand.'
HOOK_NOISE='SessionEnd hook [bash "$HOME/.claude/hooks/dhx-session-registry-end.sh"] failed: bash: /tmp/x/.claude/hooks/dhx-session-registry-end.sh: No such file or directory'

out=$(strip_cc_config_advisories "$LIVE_ADVISORY")
assert_eq "the live 'Bash(timeout * gh *)' advisory is dropped"  "" "$out"
# The point of dropping it: the timeout classifier must no longer match.
if grep -qiE 'timeout|deadline' <<<"$out"; then
  printf 'FAIL cleaned advisory still matches the timeout regex\n'; FAIL=$((FAIL + 1))
else
  printf 'OK   cleaned advisory no longer matches the timeout regex\n'; PASS=$((PASS + 1))
fi
# ...and it DID match before cleaning — a positive control, so this cell proves
# the filter acts rather than merely agreeing with an already-clean input.
if grep -qiE 'timeout|deadline' <<<"$LIVE_ADVISORY"; then
  printf 'OK   positive control: raw advisory DOES match the timeout regex\n'; PASS=$((PASS + 1))
else
  printf 'FAIL positive control: raw advisory should have matched\n'; FAIL=$((FAIL + 1))
fi

out=$(strip_cc_config_advisories "$HOOK_NOISE")
assert_eq "sandbox hook-failure noise is dropped"            "" "$out"

out=$(strip_cc_config_advisories 'Permission deny rule (x): Bash(curl *) whatever')
assert_eq "deny-rule advisories are dropped too"             "" "$out"

# The D-22 false-PASS guard must SURVIVE: real failures are not filtered.
REAL_AUTH='Invalid API key · Please run /login'
out=$(strip_cc_config_advisories "$REAL_AUTH")
assert_eq "a real auth failure is PRESERVED"                 "$REAL_AUTH" "$out"
REAL_NET='Error: connect ECONNREFUSED 127.0.0.1:443'
out=$(strip_cc_config_advisories "$REAL_NET")
assert_eq "a real network failure is PRESERVED"              "$REAL_NET" "$out"
REAL_TIMEOUT='Request timed out after 30000ms'
out=$(strip_cc_config_advisories "$REAL_TIMEOUT")
assert_eq "a real timeout message is PRESERVED"              "$REAL_TIMEOUT" "$out"

# Mixed input: advisories go, the real signal stays — the case that matters,
# since a noisy cell that ALSO genuinely failed must still classify as failed.
MIXED="$LIVE_ADVISORY
$REAL_AUTH
$HOOK_NOISE"
out=$(strip_cc_config_advisories "$MIXED")
assert_eq "mixed input keeps ONLY the real failure"          "$REAL_AUTH" "$out"

assert_eq "empty stderr stays empty"                         "" "$(strip_cc_config_advisories '')"
assert_eq "advisory count on the live 3-line capture"        "2" "$(count_cc_config_advisories "$MIXED")"
assert_eq "advisory count is 0 on a clean cell"              "0" "$(count_cc_config_advisories "$REAL_AUTH")"

echo "---"
echo "PASS: $PASS  FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
