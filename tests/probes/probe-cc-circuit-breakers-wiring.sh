#!/usr/bin/env bash
# SAFE_FOR_LIVE: yes  (read-only grep of the in-repo dispatcher; behavioural cells run the
#   monitor with CC_VERSIONS_DIR / CC_CB_BASELINE / CC_CB_CACHE_DIR pointed at a mktemp
#   sandbox holding SYNTHETIC executables — never the live ~/.local/share/claude/versions/,
#   never the live ~/.cache/dhx/)
#
# probe-cc-circuit-breakers-wiring.sh
#
# 1. Invariant: scripts/verify-cc-circuit-breakers.sh is wired into the SessionStart
#    dispatcher (filesystem-only, fail-open, NOT CI), and it behaves as a FAIL-CLOSED set-drift
#    monitor: a new bypass-immune registry key is a DRIFT (exit 1), a renamed key is a DRIFT,
#    a flipped flag is a DRIFT, a re-ordered reducer is a DRIFT, a generic ask that acquires a
#    circuitBreaker is a DRIFT, an anchor that stops matching is an EMPTY EXTRACTION (exit 2,
#    never a pass), an ABSENT generic ask is a note (exit 0), a clean verdict is cached and a
#    drift is not, a build older than the baseline's is skipped, a registry entry that carries
#    flags beyond the two fixed columns still extracts (2.1.269 shape), and a bundle embedded
#    twice in one executable yields one reducer fingerprint (2.1.270 shape).
# 2. Backs: docs/decisions.md "dhx-cd-compound-read-allow — RETIRED" row (2026-09-04).
# 3. Run: bash tests/probes/probe-cc-circuit-breakers-wiring.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DISPATCHER="$REPO/dhx-plugin/plugins/dhx/hooks/session-start.sh"
MON="$REPO/scripts/verify-cc-circuit-breakers.sh"
BASELINE="$REPO/config/cc-circuit-breakers.txt"

pass=0; fail=0
ok()  { echo "OK   $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; fail=$((fail+1)); }
ck()  { if [ "$1" -eq 0 ]; then ok "$2"; else bad "$2"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "--- A. SessionStart wiring ---"
[ -f "$DISPATCHER" ]; ck $? "dispatcher present"
LINE=$(grep -nE 'verify-cc-circuit-breakers\.sh' "$DISPATCHER" | grep -v '^[0-9]*:[[:space:]]*#' | head -1)
[ -n "$LINE" ]; ck $? "dispatcher invokes verify-cc-circuit-breakers.sh (non-comment line)"
printf '%s\n' "$LINE" | grep -q '< */dev/null'; ck $? "invoked with < /dev/null (filesystem-only)"
printf '%s\n' "$LINE" | grep -qE '\|\| *true *$'; ck $? "invocation is fail-open (trailing || true)"
printf '%s\n' "$LINE" | grep -q '\[ -e '; ck $? "invocation is behind an [ -e ] existence guard"
! grep -q 'verify-cc-circuit-breakers' "$REPO/.github/workflows/publish-mirror.yml" 2>/dev/null
ck $? "monitor is NOT wired into the CI workflow (the hosted runner has no CC binary — it would pass vacuously)"
[ -x "$MON" ]; ck $? "monitor script is executable"
[ -r "$BASELINE" ]; ck $? "baseline config/cc-circuit-breakers.txt present"
grep -q '^# baseline-build: ' "$BASELINE"; ck $? "baseline records the build it was taken from"
grep -q '^registry dangerousRemoval bypassImmune=1' "$BASELINE"; ck $? "baseline carries the registry (dangerousRemoval present)"
! grep -q '^registry deniedPathInsideDirectory' "$BASELINE"; ck $? "baseline does NOT carry deniedPathInsideDirectory (the 2.1.259-only key)"
grep -q '^reducer "bypassPermissions"' "$BASELINE"; ck $? "baseline carries the reducer fingerprint (bypassPermissions literal)"
grep -q '^generic other$' "$BASELINE"; ck $? "baseline pins the generic cd-compound-read ask as type:\"other\""

echo "--- B. behavioural cells against SYNTHETIC executables ---"
# A synthetic "binary": the three anchored regions in a plausible minified shape. The reducer
# text is a faithful abridgement of the real one (same literal/property sequence order).
mk() {  # mk <path> <registry-entries> <generic-decisionReason> [reducer-extra-before-allow]
  local p=$1 reg=$2 gen=$3 extra=${4:-}
  {
    printf 'PADDING%.0s' $(seq 1 40); printf '\n'
    printf 'var Pse=`x`,Lur={%s,...{}};function EUe(e){return e.circuitBreaker!==void 0&&Lur[e.circuitBreaker]?.bypassImmune===!0}\n' "$reg"
    printf 'function inner(e,n,r,o){let v={behavior:"passthrough",message:ql(e.name)};try{let F=e.inputSchema.parse(n);v=await e.checkPermissions(F,r)}catch(F){}if(v?.behavior==="deny")return v;if(!Hzt(e)&&e.requiresUserInteraction?.())return{behavior:"ask",message:ql(e.name),decisionReason:{type:"other",reason:"requiresUserInteraction"}};return null}\n'
    printf 'async function Rfo(e,n,r,o){let v={behavior:"passthrough",message:ql(e.name)};try{let me=e.inputSchema.parse(n);v=await e.checkPermissions(me,r)}catch(me){}if(v?.behavior==="deny")return v;let x=tE(d,e,n,"ask");if(x)return{behavior:"ask",decisionReason:{type:"rule",rule:x},message:ql(e.name)};if(e.requiresUserInteraction?.())return v?.behavior==="ask"?v:{behavior:"ask",message:ql(e.name),decisionReason:{type:"other",reason:"requiresUserInteraction"}};if(e.mcpInfo?.effectiveMaxPermission==="ask"){return{behavior:"ask"}}%slet F=fe(r),B=_x(e,F),U=B==="bypassPermissions"||B==="plan"&&F.isBypassPermissionsModeAvailable&&r.forRemoteExecution!==!0;if(v?.behavior==="ask"&&(cS(v.decisionReason)||v.decisionReason?.type==="sandboxOverride"))return v;if(U)return{behavior:"allow",updatedInput:vdn(v,n),decisionReason:{type:"mode",mode:B}};}\n' "$extra"
    printf 'function grepBranch(e){return{behavior:"ask",message:`${e} reads a file`,decisionReason:{%s}}}\n' "$gen"
    printf 'TRAILER%.0s' $(seq 1 40); printf '\n'
  } > "$p"
}
REG6='dangerousRemoval:{bypassImmune:!0,classifierRouted:!0},backgroundOperator:{bypassImmune:!1,classifierRouted:!0},suspiciousWindowsPath:{bypassImmune:!1,classifierRouted:!0},isolatePeerMachines:{bypassImmune:!0,classifierRouted:!1},restrictedMode:{bypassImmune:!0,classifierRouted:!1},outsideReadsBlocked:{bypassImmune:!0,classifierRouted:!1}'
GEN_OTHER='type:"other",reason:"Compound command contains cd",bashMissKind:"cd-compound-read"'

mkdir -p "$TMP/v" "$TMP/cache"
mk "$TMP/v/9.0.0" "$REG6" "$GEN_OTHER"
BASE="$TMP/baseline.txt"
bash "$MON" --print "$TMP/v/9.0.0" > "$BASE" 2>"$TMP/err"; rc=$?
[ $rc -eq 0 ] && grep -q '^registry outsideReadsBlocked bypassImmune=1 classifierRouted=0$' "$BASE" && grep -q '^generic other$' "$BASE"
ck $? "--print on a synthetic build extracts registry + reducer + generic (rc=$rc)"
[ "$(grep -c '^registry ' "$BASE")" = 6 ]; ck $? "registry parsed to the object terminator: 6 of 6 synthetic keys"

run() { CC_VERSIONS_DIR="$TMP/v" CC_CB_BASELINE="$BASE" CC_CB_CACHE_DIR="$TMP/cache" bash "$MON" "$@" 2>"$TMP/err"; echo $?; }

rc=$(run --no-cache); [ "$rc" = 0 ] && [ ! -s "$TMP/err" ]; ck $? "T1 clean build: exit 0, silent (rc=$rc)"
ls "$TMP/cache"/9.0.0.*.ok >/dev/null 2>&1; ck $? "T1 clean verdict is cached"
rc=$(run); [ "$rc" = 0 ] && [ ! -s "$TMP/err" ]; ck $? "T1b cached re-run: exit 0, silent"

mk "$TMP/v/9.0.1" "$REG6,deniedPathInsideDirectory:{bypassImmune:!0,classifierRouted:!1}" "$GEN_OTHER"
rc=$(run --no-cache); [ "$rc" = 1 ] && grep -q 'DRIFT on 9.0.1' "$TMP/err" && grep -q 'deniedPathInsideDirectory' "$TMP/err"
ck $? "T2 NEW registry key on a newer build: exit 1, diff names the key (rc=$rc)"
! ls "$TMP/cache"/9.0.1.*.ok >/dev/null 2>&1; ck $? "T2 a drift is never cached"
rm -f "$TMP/v/9.0.1"

mk "$TMP/v/9.0.1" "${REG6/isolatePeerMachines/isolatePeerHosts}" "$GEN_OTHER"
rc=$(run --no-cache); [ "$rc" = 1 ] && grep -q 'isolatePeerHosts' "$TMP/err"
ck $? "T3 RENAMED key: exit 1 (a tag-name grep would have missed this) (rc=$rc)"
rm -f "$TMP/v/9.0.1"

mk "$TMP/v/9.0.1" "${REG6/backgroundOperator:\{bypassImmune:!1/backgroundOperator:\{bypassImmune:!0}" "$GEN_OTHER"
rc=$(run --no-cache); [ "$rc" = 1 ] && grep -q 'backgroundOperator bypassImmune=1' "$TMP/err"
ck $? "T4 FLIPPED bypassImmune flag on a known key: exit 1 (rc=$rc)"
rm -f "$TMP/v/9.0.1"

mk "$TMP/v/9.0.1" "$REG6" "$GEN_OTHER" 'if(v?.decisionReason?.bashMissKind==="cd-compound-read")return v;'
rc=$(run --no-cache); [ "$rc" = 1 ] && grep -q 'reducer' "$TMP/err"
ck $? "T5 early-ask exception inserted before the bypass allow: exit 1, reducer fingerprint moved (rc=$rc)"
rm -f "$TMP/v/9.0.1"

mk "$TMP/v/9.0.1" "$REG6" 'type:"safetyCheck",reason:"x",classifierApprovable:!1,circuitBreaker:"relativeReadAfterCd",bashMissKind:"cd-compound-read"'
rc=$(run --no-cache); [ "$rc" = 1 ] && grep -q "generic cd-compound-read ask is now 'generic circuit'" "$TMP/err"
ck $? "T6 generic ask acquires a circuitBreaker under a NEW tag: exit 1 (rc=$rc)"
rm -f "$TMP/v/9.0.1"

mk "$TMP/v/9.0.1" "$REG6" 'type:"other",reason:"unrelated"'
sed -i 's/bashMissKind:"cd-compound-read"//' "$TMP/v/9.0.1"
rc=$(run --no-cache); [ "$rc" = 0 ] && grep -q 'no longer carries the generic' "$TMP/err"
ck $? "T7 generic ask ABSENT: exit 0 with a note (premise strengthened, not a drift) (rc=$rc)"
rm -f "$TMP/v/9.0.1"

printf 'NOTHING TO SEE HERE\n' > "$TMP/v/9.0.1"
rc=$(run --no-cache); [ "$rc" = 2 ] && grep -q 'EMPTY EXTRACTION on 9.0.1' "$TMP/err"
ck $? "T8 anchors absent: exit 2 EMPTY EXTRACTION, never a pass (rc=$rc)"
rm -f "$TMP/v/9.0.1"

mk "$TMP/v/8.9.9" "$REG6,deniedPathInsideDirectory:{bypassImmune:!0,classifierRouted:!1}" "$GEN_OTHER"
rc=$(run --no-cache); [ "$rc" = 0 ] && [ ! -s "$TMP/err" ]
ck $? "T9 a build OLDER than the baseline build is skipped silently even with the extra key (rc=$rc)"
rm -f "$TMP/v/8.9.9"

rm -rf "$TMP/v"; mkdir -p "$TMP/v"
rc=$(run --no-cache); [ "$rc" = 2 ]; ck $? "T10 empty versions dir: exit 2 (nothing inspected is not a pass) (rc=$rc)"

# 2.1.269 widened every registry entry to four flags (`hostPersonOnly`, `localProjectionOnly`);
# the two-flag entry regex then matched nothing and the monitor reported EMPTY EXTRACTION on
# every newer build. The entry match now runs to the entry's own `}` and emits any extra flags
# after the two fixed columns, so a widened entry still extracts and a flipped extra flag is a
# visible drift.
REG4="${REG6//classifierRouted:!0\}/classifierRouted:!0,hostPersonOnly:!1,localProjectionOnly:!1\}}"
REG4="${REG4//classifierRouted:!1\}/classifierRouted:!1,hostPersonOnly:!1,localProjectionOnly:!1\}}"
mk "$TMP/v/9.1.0" "$REG4,claudeSettingsFile:{bypassImmune:!1,classifierRouted:!1,hostPersonOnly:!0,localProjectionOnly:!1}" "$GEN_OTHER"
out=$(bash "$MON" --print "$TMP/v/9.1.0" 2>/dev/null); rc=$?
[ $rc -eq 0 ] && [ "$(printf '%s\n' "$out" | grep -c '^registry ')" = 7 ] \
  && printf '%s\n' "$out" | grep -q '^registry outsideReadsBlocked bypassImmune=1 classifierRouted=0 hostPersonOnly=0 localProjectionOnly=0$' \
  && printf '%s\n' "$out" | grep -q '^registry claudeSettingsFile bypassImmune=0 classifierRouted=0 hostPersonOnly=1 localProjectionOnly=0$'
ck $? "T11 four-flag entries (2.1.269 shape): 7 of 7 keys extract, extra flags emitted after the fixed columns (rc=$rc)"

# 2.1.270 carries the JS bundle twice in one executable (byte-identical, +178,229,248 bytes), so
# every reducer anchor hits twice. Identical fingerprints must collapse to one, or the doubled
# reducer block reads as a drift against a single-copy baseline.
cat "$TMP/v/9.1.0" "$TMP/v/9.1.0" > "$TMP/v/9.1.1"; rm -f "$TMP/v/9.1.0"
out2=$(bash "$MON" --print "$TMP/v/9.1.1" 2>/dev/null); rc=$?
[ $rc -eq 0 ] && [ "$(printf '%s\n' "$out2" | grep -c '^reducer ')" = "$(printf '%s\n' "$out" | grep -c '^reducer ')" ] \
  && [ "$(printf '%s\n' "$out2" | grep -v '^#')" = "$(printf '%s\n' "$out" | grep -v '^#')" ]
ck $? "T12 bundle embedded twice (2.1.270 shape): one reducer fingerprint, snapshot identical to the single copy (rc=$rc)"
rm -f "$TMP/v/9.1.1"

echo "--- C. the LIVE baseline still matches the newest installed build (informational if none) ---"
if ls "${CC_VERSIONS_DIR:-$HOME/.local/share/claude/versions}"/* >/dev/null 2>&1; then
  out=$(CC_CB_CACHE_DIR="$TMP/livecache" bash "$MON" --no-cache 2>&1); rc=$?
  [ $rc -eq 0 ]; ck $? "live monitor against the committed baseline: exit $rc${out:+ — $out}"
else
  echo "NOTE no installed CC builds — live cell skipped"
fi

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
