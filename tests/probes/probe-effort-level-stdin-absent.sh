#!/bin/bash
# probe-effort-level-stdin-absent.sh
#
# SAFE_FOR_LIVE: yes  (read-only via file-gated wrapper edit; no live mutation)
# RUNTIME: ~5s
#
# THE FILE NAME IS HISTORICAL — read the contract below, not the name.
# Authored 2026-04-30 as a supersession watchdog asserting the NEGATIVE premise
# that CC's statusline-wrapper stdin payload did NOT carry `effortLevel`/`effort`
# at the top level. That premise died 2026-05-13 and the probe kept reporting its
# own death into an informational counter for four months (see the 2026-09-18
# docs/decisions.md row). The name is kept deliberately: three committed corpus
# cells carry `probe_id: probe-effort-level-stdin-absent`, and
# scripts/verify-multi-cc-results.sh keys its allowlist on that id — a rename
# orphans them for no behavioural gain.
#
# WHAT IT ASSERTS NOW (2026-09-18): the effort level CC publishes is one the
# statusline can actually RENDER. `dhx/dhx-statusline.js` does
# `renderEffort(data.effort?.level)`, and renderEffort is a lookup into the
# five-key EFFORT_RENDER map returning '' on a miss — so a CC release that
# RENAMES or ADDS a level blanks the glyph exactly as silently as one that drops
# the key. That value-side gap is the half a single capture CAN prove.
#
#   exit 0 = the observed level renders, OR no observation was made
#   exit 1 = level present but UNRENDERABLE  (the glyph is silently broken)
#   exit 2 = malfunction (capture timed out, payload not JSON, source unreadable)
#
# Convention B (`exit_0_means_pass`) — ordinary regression-probe semantics, so a
# non-zero exit reaches run-probes.sh's default branch and is counted a FAIL by
# name. It is deliberately NOT Convention A: the only non-zero Convention-A
# family is `supersession_found_*`, which routes to the "[SUPERSESSION OBSERVED]"
# counter explicitly marked not-a-failure — the exact bucket that hid this
# probe's own dead premise. A regression must reach a human.
#
# WHY IT DOES NOT ASSERT "the effort key is present":
# one armed run captures exactly ONE payload (the wait loop below breaks on the
# first non-empty capture file, then exits). A single absence is structurally
# indistinguishable from the transient one-refresh miss that
# .planning/backlog/2026-05-02-statusline-effort-memoization.md documents as
# benign and self-correcting. So absence is RECORDED in observations and reported
# as `skipped` — never as a verdict. The temporal dimension one run lacks is
# supplied by the cross-VERSION corpus under tests/probes/.results/, which is
# where an `effort_present: false` cell would show up against the populated
# 2.1.140 / 2.1.273 / 2.1.275 cells and light that brief's trigger.
#
# Mode discrimination (D-17): if ${XDG_RUNTIME_DIR:-/tmp}/dhx-statusline-stdin-probe
# directory exists at probe-script start, run live-capture mode; otherwise run
# fixtures-only mode (the bash scripts/run-probes.sh path) and exit 0. Operator
# arms live capture by `mkdir -p ${XDG_RUNTIME_DIR:-/tmp}/dhx-statusline-stdin-probe`
# before invoking the probe. PROBE-01 #PROBE-01
#
# Backs:
#   - .planning/REQUIREMENTS.md PROBE-01 (historical — the watchdog contract)
#   - docs/decisions.md 2026-09-18 effort-watchdog-inverted-to-renderability row
#   - .planning/backlog/2026-09-18-effort-renderability-guard-has-no-firing-trigger.md
#     — WHAT IS SUPPOSED TO RUN THIS. The live arm above only fires when an
#     operator hand-creates the arming dir, so nothing in the repo ever executes
#     it; that brief's trigger_when is keyed on a CC version change so
#     cc-version-observer.sh names it at SessionStart after a bump and tells a
#     human to arm and run this probe. Do NOT auto-arm it from a hook or cron —
#     see the 2026-09-17 hermetic-tier-refuses-live-capture row.
#
# Run: bash tests/probes/probe-effort-level-stdin-absent.sh
set -uo pipefail

PROBE_DIR="${XDG_RUNTIME_DIR:-/tmp}/dhx-statusline-stdin-probe"
PASS=0
FAIL=0
SKIP=0

assert_eq() {
  local name="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    echo "OK   $name"; PASS=$((PASS+1))
  else
    echo "FAIL $name"; echo "     got:  $got"; echo "     want: $want"; FAIL=$((FAIL+1))
  fi
}

# --- Renderable-level set, DERIVED from the renderer (never copied) -----------
# A hardcoded list here would be a second source of truth that goes stale exactly
# when it matters: the whole point of this probe is to catch EFFORT_RENDER and
# CC's published vocabulary drifting apart, and a stale copy cannot see that.
# Parsed from the object literal's keys, so adding a level to dhx-statusline.js
# widens this probe automatically.
STATUSLINE_SRC=""
RENDERABLE=""
derive_levels() {
  local root src
  root=$(git rev-parse --show-toplevel 2>/dev/null || echo "$(cd "$(dirname "$0")/../.." && pwd)")
  src="$root/dhx/dhx-statusline.js"
  [[ -r "$src" ]] || return 1
  STATUSLINE_SRC="$src"
  RENDERABLE=$(sed -n '/^const EFFORT_RENDER = {/,/^};/p' "$src" \
                 | sed -nE 's|^[[:space:]]*([A-Za-z_][A-Za-z_0-9]*):[[:space:]]*\{.*|\1|p' \
                 | tr '\n' ' ')
  [[ -n "${RENDERABLE// /}" ]]
}

# classify_observation <renderability> -> "<exit_code> <conclusion>"
# The live arm's verdict mapping, factored out so the fixtures below can pin it
# on every commit. This matters more here than the factoring usually would: the
# live arm is the ONE path the pre-commit hermetic tier can never execute, so
# without this its decision would be verified only by whoever last hand-armed the
# probe — which is precisely the unwatched-guard shape this rewrite exists to
# retire. Mutation-verified end to end 2026-09-18 against synthetic captures in a
# throwaway repo (5/5: renderable/ultra/High/key-absent/level-null).
classify_observation() {
  case "$1" in
    renderable)   printf '0 validated_stable' ;;
    unrenderable) printf '1 regression_found_effort_level_unrenderable' ;;
    absent)       printf '0 skipped' ;;
    *)            printf '2 ambiguous' ;;
  esac
}

# level_renderable <level> -> "renderable" | "unrenderable" | "absent"
level_renderable() {
  local lvl="$1" k
  [[ -n "$lvl" && "$lvl" != "null" ]] || { printf 'absent'; return; }
  for k in $RENDERABLE; do
    [[ "$lvl" == "$k" ]] && { printf 'renderable'; return; }
  done
  printf 'unrenderable'
}

# --- Stdin key-detection self-test (D-19) -------------------------------------
# Inline node -e JSON parser checks top-level effortLevel/effort key presence.
# Still load-bearing: presence detection is step 1 of the pipeline (present ->
# check renderability; absent -> no observation). Does NOT import
# dhx-statusline.js (no parsePaneEffort dependency).
declare -a STDIN_FIXTURES=(
  "no-effort-keys|absent|{\"workspace\":{\"current_dir\":\"/tmp\"},\"session_id\":\"x\"}"
  "effortLevel-present|present|{\"effortLevel\":\"high\",\"workspace\":{\"current_dir\":\"/tmp\"}}"
  "effort-present|present|{\"effort\":\"max\",\"workspace\":{\"current_dir\":\"/tmp\"}}"
  "both-effort-keys|present|{\"effortLevel\":\"high\",\"effort\":\"max\",\"workspace\":{\"current_dir\":\"/tmp\"}}"
  "malformed-json|absent|not json {{{"
)

for f in "${STDIN_FIXTURES[@]}"; do
  name=${f%%|*}; rest=${f#*|}
  expected=${rest%%|*}; body=${rest#*|}
  got=$(printf '%s' "$body" | node -e '
    let buf=""; process.stdin.on("data",c=>buf+=c).on("end",()=>{
      try {
        const d = JSON.parse(buf);
        const has = ("effortLevel" in d) || ("effort" in d);
        process.stdout.write(has ? "present" : "absent");
      } catch { process.stdout.write("absent"); }
    });')
  assert_eq "fixture: $name" "$got" "$expected"
done

# --- Renderability self-test (2026-09-18) ------------------------------------
# The firing condition this probe now exists for. `ultra` is not hypothetical
# padding: CC already uses that word for review effort, so a session-effort level
# named `ultra` is the concrete shape of the regression being guarded.
if derive_levels; then
  assert_eq "derived level set is non-empty" \
    "$([[ -n "${RENDERABLE// /}" ]] && echo yes || echo no)" "yes"
  for known in low medium high xhigh max; do
    assert_eq "renderer maps known level: $known" "$(level_renderable "$known")" "renderable"
  done
  assert_eq "unknown level is unrenderable: ultra" "$(level_renderable ultra)" "unrenderable"
  assert_eq "level lookup is case-sensitive: HIGH"  "$(level_renderable HIGH)"  "unrenderable"
  assert_eq "empty level reads as absent"           "$(level_renderable "")"    "absent"
  assert_eq "json-null level reads as absent"       "$(level_renderable null)"  "absent"
else
  echo "SKIP renderability self-test — dhx/dhx-statusline.js unreadable from $(pwd) (scratch tree?)"
  SKIP=$((SKIP+1))
fi

# --- Live-arm verdict map self-test (2026-09-18) ------------------------------
# Deliberately OUTSIDE the derive_levels branch: these need no renderer source,
# so the live arm's decision stays pinned even in a scratch tree. The composed
# rows are the ones that matter — they are the actual chain the live arm walks.
assert_eq "verdict map: renderable"     "$(classify_observation renderable)"   "0 validated_stable"
assert_eq "verdict map: unrenderable"   "$(classify_observation unrenderable)" "1 regression_found_effort_level_unrenderable"
assert_eq "verdict map: absent"         "$(classify_observation absent)"       "0 skipped"
assert_eq "verdict map: unexpected arg" "$(classify_observation bogus)"        "2 ambiguous"
if [[ -n "${RENDERABLE// /}" ]]; then
  assert_eq "composed: level 'high' -> pass"  \
    "$(classify_observation "$(level_renderable high)")"  "0 validated_stable"
  assert_eq "composed: level 'ultra' -> FAIL" \
    "$(classify_observation "$(level_renderable ultra)")" "1 regression_found_effort_level_unrenderable"
  assert_eq "composed: no level -> declines a verdict" \
    "$(classify_observation "$(level_renderable "")")"    "0 skipped"
fi

# D-17 mode discriminator: probe dir absent → fixtures-only mode → exit 0.
#
# DHX_PROBE_HERMETIC (2026-09-17) forces the same path even when the arming dir
# EXISTS. Set by run-probes.sh whenever the resolved filter set asks for
# LIVE_RUNTIME=no — i.e. the pre-commit gate (check #8a). Under that tier a live
# capture is two things the tier must not do: a live-runtime dependency its own
# filter exists to exclude, and a write into the TRACKED corpus that mutates the
# commit candidate while it is being validated. A `/tmp` arming dir left behind
# after a hand-run silently escalated this probe on every probe-touching commit
# for two days before 30-deletion-audit.sh caught the mutation. Arming remains
# the operator's deliberate publication path on every other invocation.
# See docs/decisions.md 2026-09-17 hermetic-tier-refuses-live-capture row.
if [[ ! -d "$PROBE_DIR" || "${DHX_PROBE_HERMETIC:-0}" == "1" ]]; then
  echo "---"
  if [[ -d "$PROBE_DIR" ]]; then
    echo "NOTE arming dir present but IGNORED — DHX_PROBE_HERMETIC=1 (hermetic tier refuses live capture)"
    echo "PASS: $PASS  FAIL: $FAIL  SKIP: $SKIP  mode=fixtures-only (arming dir ignored under the hermetic tier)"
  else
    echo "PASS: $PASS  FAIL: $FAIL  SKIP: $SKIP  mode=fixtures-only (probe dir absent — arm with: mkdir -p $PROBE_DIR)"
  fi
  if [[ "$FAIL" -eq 0 ]]; then
    exit 0
  else
    exit 2
  fi
fi

# --- Live-capture orchestration (D-16 — fixed-path file convention) ----------
# The live arm MAKES a claim, so unlike the fixtures path it cannot tolerate a
# missing renderer: without the derived set there is nothing to judge the
# captured level against, and a silent pass here is the hollow-check shape this
# probe is guarding elsewhere.
if [[ -z "${RENDERABLE// /}" ]]; then
  echo "FAIL renderer-source-unreadable: cannot derive the renderable level set; refusing to judge a capture"
  echo "---"
  echo "PASS: $PASS  FAIL: $((FAIL+1))  conclusion=ambiguous  exit_code=2"
  exit 2
fi

RUN_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || date +%s%N)
FLAG_FILE="$PROBE_DIR/flag"
CAPTURE_FILE="$PROBE_DIR/capture-$RUN_ID.json"

# Trap-clean only this run's flag + capture file (preserve probe dir for operator concurrency)
trap 'rm -f "$FLAG_FILE" "$CAPTURE_FILE"' EXIT

# Run-id propagation channel: flag file content (env var doesn't reach the wrapper subprocess
# launched by CC's parent process — sibling, not child, of probe's bash).
echo "$RUN_ID" > "$FLAG_FILE"
echo ""
echo "Live capture: trigger a statusline refresh (any keystroke / new turn). Waiting up to 30s..."

for i in {1..30}; do
  if [[ -s "$CAPTURE_FILE" ]]; then break; fi
  sleep 1
done

exit_code=2
conclusion="ambiguous"
if [[ ! -s "$CAPTURE_FILE" ]]; then
  echo "FAIL live-capture-timeout: no statusline refresh observed in 30s"
  FAIL=$((FAIL+1))
else
  if ! jq -e . "$CAPTURE_FILE" >/dev/null 2>&1; then
    echo "FAIL captured-payload-not-json"
    FAIL=$((FAIL+1))
  else
    PASS=$((PASS+1))
    echo "OK   captured-payload-valid-json"
  fi
fi

# --- Observation extraction + Convention B exit code -------------------------
# Detection scope: top-level effortLevel/effort keys, plus the nested
# `.effort.level` value the renderer actually consumes.
has_effort=$(jq -r '(has("effortLevel") or has("effort"))' "$CAPTURE_FILE" 2>/dev/null || echo "false")
observed_level=$(jq -r '.effort.level // ""' "$CAPTURE_FILE" 2>/dev/null || echo "")
stdin_keys_json=$(jq -c 'keys' "$CAPTURE_FILE" 2>/dev/null || echo "[]")
workspace_present=$(jq -r 'has("workspace") and (.workspace | has("current_dir"))' "$CAPTURE_FILE" 2>/dev/null || echo "false")
renderability=$(level_renderable "$observed_level")

# The verdict comes from classify_observation — the SAME function the fixtures
# above pin on every commit — so the live arm and its self-test can never drift.
if [[ "$FAIL" -gt 0 ]]; then
  read -r exit_code conclusion <<<"$(classify_observation malfunction)"
else
  read -r exit_code conclusion <<<"$(classify_observation "$renderability")"
  case "$renderability" in
    renderable)
      echo "OK   effort level '$observed_level' is renderable by EFFORT_RENDER"
      PASS=$((PASS+1))
      ;;
    unrenderable)
      echo "FAIL effort level '$observed_level' is NOT in the renderer's set [${RENDERABLE% }]"
      echo "     the statusline glyph is silently hidden for this level — see ${STATUSLINE_SRC##*/} EFFORT_RENDER"
      FAIL=$((FAIL+1))
      ;;
    *)
      # Absent. ONE capture cannot separate a structural drop from a transient
      # miss, so this records the observation and declines the verdict. The
      # cross-VERSION corpus is what accumulates the temporal evidence.
      echo "NOTE no effort.level in this capture — recorded, NOT treated as a regression"
      echo "     one capture cannot distinguish a dropped key from a transient miss;"
      echo "     compare this cell against the populated 2.1.140/2.1.273/2.1.275 cells."
      ;;
  esac
fi

# --- Outcome JSON write (D-08 schema; D-30 hostname-hash; live cc_version) ---
CC_VERSION=$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
[[ -n "$CC_VERSION" ]] || CC_VERSION="unknown"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "$(cd "$(dirname "$0")/../.." && pwd)")
# CC-keyed corpus path (quick-260526-10r) — never writes to the frozen v1.2 baseline; validator scans this dir
OUT_DIR="$REPO_ROOT/tests/probes/.results/v1.3-multi-cc-ver/$CC_VERSION"
mkdir -p "$OUT_DIR"
OUT_FILE="$OUT_DIR/probe-effort-level-stdin-absent.json"

# D-30: published_from_hostname is SHA-256 of hostname -s (synthetic identifier)
HOSTNAME_HASH=$(printf '%s' "$(hostname -s)" | sha256sum | awk '{print $1}')

OBSERVATIONS=$(jq -n \
  --argjson keys "$stdin_keys_json" \
  --argjson effortLevel_present "$(jq -r 'has("effortLevel")' "$CAPTURE_FILE" 2>/dev/null || echo false)" \
  --argjson effort_present "$(jq -r 'has("effort")' "$CAPTURE_FILE" 2>/dev/null || echo false)" \
  --arg effort_level_observed "$observed_level" \
  --arg effort_level_renderability "$renderability" \
  --arg renderer_level_set "${RENDERABLE% }" \
  --argjson workspace_current_dir_present "$workspace_present" \
  --arg published_from_hostname "$HOSTNAME_HASH" \
  '{stdin_payload_top_level_keys:$keys, effortLevel_present:$effortLevel_present, effort_present:$effort_present, effort_level_observed:$effort_level_observed, effort_level_renderability:$effort_level_renderability, renderer_level_set:$renderer_level_set, workspace_current_dir_present:$workspace_current_dir_present, published_from_hostname:$published_from_hostname}')

# JSON-time sanitizer (D-21 load-bearing gate): refuse to write if observations contain PII
HOST=$(hostname -s)
# Herestring, NOT `echo | grep -q` (2026-09-17). Under this probe's `set -o
# pipefail`, a pipeline whose READER exits early reports failure: grep -q stops
# at the first matching LINE, the writer takes SIGPIPE, and the pipeline goes
# non-zero — so the `if` reads FALSE and this refusal is SKIPPED exactly when
# PII is present. Fail-OPEN on a sanitizer, not a false red. Measured: match on
# an early short line with ~200 KB after it gives PIPESTATUS "141 0" on 3 of 3
# runs under both the ugrep wrapper and `command grep`; a match inside ONE long
# line gives "0 0", because grep cannot decide a line matched until it sees that
# line's newline. Both legs are needed — shape AND bulk past ~70-100 KB — and
# observations are jq-pretty-printed (28 lines, 593 bytes measured), so the SHAPE
# already qualifies and only the size keeps this latent. A herestring has no pipe
# and no reader to die, so the gate cannot invert at any size. See the peer brief
# 6098e475 for the other 53 sites of this pattern.
if grep -qE "(/home/|/Users/|$HOST)" <<<"$OBSERVATIONS"; then
  echo "FATAL: observations contain PII; refusing write"
  exit 2
fi

jq -n \
  --arg id "probe-effort-level-stdin-absent" \
  --argjson code "$exit_code" \
  --arg cc "$CC_VERSION" \
  --arg ts "$TS" \
  --arg run "$RUN_ID" \
  --argjson obs "$OBSERVATIONS" \
  --arg conc "$conclusion" \
  '{probe_id:$id, exit_code:$code, exit_code_convention:"exit_0_means_pass", cc_version:$cc, ts:$ts, run_id:$run, observations:$obs, conclusion:$conc}' \
  > "$OUT_FILE"

echo "OK   outcome-json-written: $OUT_FILE"
PASS=$((PASS+1))

# --- Summary + exit (Convention B) -------------------------------------------
echo "---"
echo "PASS: $PASS  FAIL: $FAIL  conclusion=$conclusion  exit_code=$exit_code"
exit $exit_code
