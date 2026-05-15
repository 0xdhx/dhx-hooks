#!/bin/bash
# Exercises dhx/dhx-plugin-cache-staleness-detector.sh — the HP-025 cache-staleness companion detector.
# SAFE_FOR_LIVE: yes   (mktemp + fake HOME + env-overridable DHX_CACHE_STALENESS_* paths; never touches live `~/.claude/plugins/cache/dhx-local` or live `dhx-plugin/` manifest)
#
# Phase 10.1 RED scaffolding (Plan 1). The detector body does not exist yet —
# Plan 2 (GREEN) ships dhx/dhx-plugin-cache-staleness-detector.sh and flips the
# staleness scenarios RED → GREEN. In Plan 1 RED state the staleness-detection
# scenarios (single-stale / multi-stale / dispatcher-integration) FAIL
# deterministically against the not-yet-existing detector; the clean and
# cache-dir-missing scenarios pass vacuously (0 detector-prefix stderr lines
# regardless of detector existence); the empirical-arm scenario passes once the
# operator has written 10.1-D-01-RESULT.md via the `write-result` subcommand.
#
# Two invocation modes (D-18 subcommand dispatch):
#   bash tests/probes/probe-plugin-cache-staleness.sh
#       routine — runs the read-only scenario suite (exits non-zero in Plan 1 RED).
#   bash tests/probes/probe-plugin-cache-staleness.sh write-result --cache-read-path <yes|no|inconclusive> ...
#       D-18 subcommand — the ONLY path that writes 10.1-D-01-RESULT.md.
#       Routine runs are read-only by construction (D-20): write_result_artifact
#       is reachable only via this subcommand branch.
#
# Backs docs/decisions.md Phase 10.1 Plan 1 RED row + HP-020 (read-path finding
# under empirical test) + HP-025 § Cache-staleness detection (lands in Plan 2).
# Run: bash tests/probes/probe-plugin-cache-staleness.sh
set -u

# Resolve $HOOK relative to this probe's repo root so the probe runs correctly
# inside a git worktree (where the main repo's path would point to the unmodified
# script). `git rev-parse --show-toplevel` returns the worktree's toplevel.
PROBE_REPO_ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || echo "/home/dhx/repos/hooks")
HOOK="$PROBE_REPO_ROOT/dhx/dhx-plugin-cache-staleness-detector.sh"
RESULT_ARTIFACT="$PROBE_REPO_ROOT/.planning/phases/10.1-plugin-cache-hooks-json-staleness-detector/10.1-D-01-RESULT.md"
LIVE_DISPATCHER="$PROBE_REPO_ROOT/dhx-plugin/plugins/dhx/hooks/session-start.sh"
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0

# Fixed reference epoch for deterministic mtime fixtures — `touch -d @<epoch>`
# offsets are applied relative to this so "stale" / "fresh" never depends on
# wallclock at probe-run time.
BASE_EPOCH=1700000000

# Pattern H pre-snapshot stores (read-only stat boundary runtime invariant).
# Populated by snapshot_cache, consumed by assert_cache_untouched — both run in
# the MAIN shell (never under command substitution) so PASS/FAIL mutations stick.
declare -A PRE_M PRE_H

# ---------------------------------------------------------------------------
# write_result_artifact — D-18 `write-result` subcommand target.
#
# Reachable ONLY via the `write-result` case-dispatch branch below. Routine
# probe runs (no subcommand) NEVER call this — the artifact-write path is
# provably read-only-by-construction on the routine path (D-20). Operator
# supplies observations as CLI flags (D-01 hybrid scaffolding) so the artifact
# is written deterministically — zero hand-edited YAML, so the Codex Q1 #1 typo
# class cannot manifest.
# ---------------------------------------------------------------------------
write_result_artifact() {
  local cache_read_path="" cc_version="" evidence="" evidence_debug=""
  local control_hook_fired="" cache_manifest_path="" live_manifest_path="" marker_log_path=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cache-read-path)     cache_read_path=${2:-}; shift 2 ;;
      --cc-version)          cc_version=${2:-}; shift 2 ;;
      --evidence)            evidence=${2:-}; shift 2 ;;
      --evidence-debug)      evidence_debug=${2:-}; shift 2 ;;
      --control-hook-fired)  control_hook_fired=${2:-}; shift 2 ;;
      --cache-manifest-path) cache_manifest_path=${2:-}; shift 2 ;;
      --live-manifest-path)  live_manifest_path=${2:-}; shift 2 ;;
      --marker-log-path)     marker_log_path=${2:-}; shift 2 ;;
      *)
        echo "write_result_artifact: unknown flag '$1'" >&2
        return 2
        ;;
    esac
  done

  # Enum validation BEFORE write (T-10.1-01 mitigation — fail loud, write nothing).
  case "$cache_read_path" in
    yes|no|inconclusive) ;;
    *)
      echo "write_result_artifact: --cache-read-path must be yes|no|inconclusive (got '$cache_read_path')" >&2
      return 2
      ;;
  esac

  # D-05 REFUTE control-hook requirement: cache_read_path=no is only a valid
  # REFUTE if a named live-manifest control hook also fired (proves CC loaded
  # hooks for the session). Otherwise "no" is indistinguishable from an
  # auth/install failure — override to inconclusive (default-safe per SPEC REQ 3).
  local override_note=""
  if [[ "$cache_read_path" == "no" && "$control_hook_fired" != "yes" ]]; then
    override_note="Auto-overridden from \`no\` → \`inconclusive\`: --control-hook-fired was not \`yes\`, so a REFUTE cannot be distinguished from an auth/install failure masquerading as REFUTE (D-05)."
    cache_read_path="inconclusive"
  fi

  local verified_at
  verified_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  mkdir -p "$(dirname "$RESULT_ARTIFACT")"
  {
    echo "---"
    echo "cache_read_path: $cache_read_path"
    echo "cc_version: $cc_version"
    echo "verified_at: $verified_at"
    echo "evidence: $evidence"
    echo "evidence_debug: $evidence_debug"
    echo "cache_manifest_path: $cache_manifest_path"
    echo "live_manifest_path: $live_manifest_path"
    echo "marker_log_path: $marker_log_path"
    echo "control_hook_fired: $control_hook_fired"
    echo "---"
    echo "# D-01 Empirical Probe Result"
    echo ""
    echo "Operator-driven sandboxed-CC empirical-arm run (D-01 hybrid scaffolding;"
    echo "mirrors the Phase 10 D-05 checkpoint:human-action pattern). Written"
    echo "deterministically by the \`write-result\` subcommand of"
    echo "\`tests/probes/probe-plugin-cache-staleness.sh\` (D-18) — operator supplied"
    echo "observations as CLI flags; no hand-edited YAML."
    echo ""
    case "$cache_read_path" in
      yes)
        echo "**Classification: AFFIRM** (\`cache_read_path: yes\`). The marker fixture"
        echo "FIRED — CC's resolver read the mutated cache \`hooks.json\` at session"
        echo "start on CC \`$cc_version\`. This falsifies the HP-020 metadata-only"
        echo "read-path claim on this CC version. Branch-lock outcome: Plan 2 bakes"
        echo "\`PREFIX_MODE=REJECT\` (failure-mode-grade detector) and must author an"
        echo "HP-020 addendum row recording the falsification."
        ;;
      no)
        echo "**Classification: REFUTE** (\`cache_read_path: no\`). The marker fixture"
        echo "did NOT fire AND the named live-manifest control hook DID fire (proving"
        echo "CC loaded hooks for this session) on CC \`$cc_version\`. This confirms the"
        echo "HP-020 read-path finding — the cache \`hooks.json\` is metadata-only,"
        echo "frozen at install. Branch-lock outcome: Plan 2 bakes \`PREFIX_MODE=WARN\`"
        echo "with an \`informational on CC $cc_version\` suffix (cosmetic-grade detector"
        echo "— still warranted for audit hygiene + documented upgrade path)."
        ;;
      inconclusive)
        echo "**Classification: INCONCLUSIVE** (\`cache_read_path: inconclusive\`)."
        echo "The empirical arm did not produce an unambiguous AFFIRM or REFUTE"
        echo "signal (both hooks fired, neither fired, the sandboxed \`claude\` exited"
        echo "non-zero / timed out, or the operator deliberately classified"
        echo "inconclusive without running the sandboxed-CC sequence). Default-safe"
        echo "per SPEC REQ 3. Branch-lock outcome: Plan 2 bakes \`PREFIX_MODE=WARN\`"
        echo "with a \`(probe inconclusive; safe default)\` suffix and must author a"
        echo "decisions-row dispensation explaining the inconclusive disposition."
        if [[ -n "$override_note" ]]; then
          echo ""
          echo "$override_note"
        fi
        ;;
    esac
    echo ""
    echo "Evidence:"
    echo "- marker-fire log: \`$evidence\`"
    echo "- \`claude --debug\` log: \`$evidence_debug\`"
    echo "- mutated cache manifest: \`$cache_manifest_path\`"
    echo "- live manifest: \`$live_manifest_path\`"
    echo "- marker log path: \`$marker_log_path\`"
    echo "- control hook fired: \`$control_hook_fired\`"
  } > "$RESULT_ARTIFACT"

  echo "write_result_artifact: wrote $RESULT_ARTIFACT (cache_read_path: $cache_read_path)"
  return 0
}

# ---------------------------------------------------------------------------
# make_case_staleness — per-scenario sandbox factory (adapts heal probe make_case).
#
#   make_case_staleness(name, live_mtime_delta_sec, cache_versions_with_mtime_deltas, has_cache_root=1)
#     name                              — sandbox subdir under $TMPROOT
#     live_mtime_delta_sec              — int offset from BASE_EPOCH for the live manifest fixture
#     cache_versions_with_mtime_deltas  — space-sep "<ver>:<delta>" entries (empty string = none)
#     has_cache_root                    — 1 (default) builds .../cache/dhx-local/dhx/;
#                                         0 omits the cache dir entirely (D-13/Z3 fixture)
#
# A cache version is "stale" when its mtime < the live manifest mtime.
# Echoes the sandbox $home path.
# ---------------------------------------------------------------------------
make_case_staleness() {
  local name=$1
  local live_delta=$2
  local cache_specs=$3
  local has_cache_root=${4:-1}

  local home="$TMPROOT/$name"
  local live_manifest="$home/repos/hooks/dhx-plugin/plugins/dhx/hooks/hooks.json"
  local cache_root="$home/.claude/plugins/cache/dhx-local"

  mkdir -p "$(dirname "$live_manifest")"
  printf '{"hooks":{"SessionStart":[]}}' > "$live_manifest"
  touch -d "@$((BASE_EPOCH + live_delta))" "$live_manifest"

  if (( has_cache_root )); then
    mkdir -p "$cache_root/dhx"
    local spec ver delta cache_file
    for spec in $cache_specs; do
      ver=${spec%%:*}
      delta=${spec##*:}
      cache_file="$cache_root/dhx/$ver/hooks/hooks.json"
      mkdir -p "$(dirname "$cache_file")"
      printf '{"hooks":{"SessionStart":[]}}' > "$cache_file"
      touch -d "@$((BASE_EPOCH + delta))" "$cache_file"
    done
  fi

  printf '%s' "$home"
}

# ---------------------------------------------------------------------------
# run_hook_capture_stderr_staleness — invoke the detector against a sandbox,
# capture stderr only. Augments the heal probe's run_hook_capture_stderr with
# the two DHX_CACHE_STALENESS_* env overrides (D-14) so fixtures never drift
# onto the live filesystem.
#
# Redirect order `2>&1 >/dev/null` is load-bearing: stderr is duplicated to
# stdout BEFORE stdout is discarded — the captured stream contains stderr only
# (Phase 10 D-08 convention). The function's exit status is the hook's rc;
# callers capture it via `$?` immediately after the command substitution.
# ---------------------------------------------------------------------------
run_hook_capture_stderr_staleness() {
  local home=$1
  HOME="$home" \
  CLAUDE_CONFIG_DIR="$home/.claude" \
  DHX_CACHE_STALENESS_LIVE_MANIFEST="$home/repos/hooks/dhx-plugin/plugins/dhx/hooks/hooks.json" \
  DHX_CACHE_STALENESS_CACHE_ROOT="$home/.claude/plugins/cache/dhx-local" \
    bash "$HOOK" < /dev/null 2>&1 >/dev/null
}

# ---------------------------------------------------------------------------
# Pattern H — read-only stat boundary as a RUNTIME invariant.
# snapshot_cache captures mtime + sha256 of every cache hooks.json BEFORE the
# detector runs; assert_cache_untouched re-snapshots AFTER and FAILs on any
# drift. The detector is stat-only by contract (Pattern E) — this locks that
# claim at runtime, not just at code review. Both run in the MAIN shell.
# ---------------------------------------------------------------------------
snapshot_cache() {
  local home=$1
  local cache_root="$home/.claude/plugins/cache/dhx-local"
  PRE_M=()
  PRE_H=()
  local cache saved
  saved=$(shopt -p nullglob || true)
  shopt -s nullglob
  for cache in "$cache_root"/dhx/*/hooks/hooks.json; do
    PRE_M["$cache"]=$(stat -c %Y "$cache")
    PRE_H["$cache"]=$(sha256sum "$cache" | awk '{print $1}')
  done
  eval "$saved"
}

assert_cache_untouched() {
  local name=$1
  if (( ${#PRE_M[@]} == 0 )); then
    return 0   # no cache fixtures present — Pattern H vacuously holds
  fi
  local drift=0 c
  for c in "${!PRE_M[@]}"; do
    [[ "$(stat -c %Y "$c" 2>/dev/null)" == "${PRE_M[$c]}" ]] || drift=1
    [[ "$(sha256sum "$c" 2>/dev/null | awk '{print $1}')" == "${PRE_H[$c]}" ]] || drift=1
  done
  if (( drift )); then
    printf '  ✗ %s: Pattern H — cache hooks.json mtime/sha256 drifted (detector must be stat-only/read-only)\n' "$name"
    FAIL=$((FAIL + 1))
  else
    printf '  ✓ %s: Pattern H — cache hooks.json mtime+sha256 byte-identical pre/post\n' "$name"
    PASS=$((PASS + 1))
  fi
}

# ---------------------------------------------------------------------------
# D-18 subcommand-mode dispatch (mirrors ~/repos/skills/scripts/dhx-sym.sh's
# cmd_* case-dispatch precedent). write_result_artifact is the ONLY
# artifact-mutating path and is reachable ONLY when "$1" == "write-result";
# every routine run (no subcommand) falls through to the read-only scenario
# suite below (D-20 read-only-routine invariant).
#
# The `case` expands "${1:-}" so the only place the scenario-suite arm token
# appears is the arm itself — which sits AFTER the write_result_artifact call.
# That keeps the D-20 source-audit range clean (it must find zero
# write_result_artifact references in the routine scenario path).
# ---------------------------------------------------------------------------
case "${1:-}" in
  write-result)
    shift
    write_result_artifact "$@"
    exit $?
    ;;
  run-scenarios|"")
    : # fall through to the read-only scenario suite below
    ;;
  *)
    echo "Usage: $0 [write-result --cache-read-path <yes|no|inconclusive> --cc-version ... | (no subcommand)]" >&2
    exit 2
    ;;
esac

# ===========================================================================
# Scenario suite (routine invocation — read-only).
# Each scenario emits exactly one `EXPECT: <state>` token on stdout (G-05)
# BEFORE its assertions fire.
# ===========================================================================

echo "=== probe-plugin-cache-staleness.sh — Phase 10.1 RED scaffolding ==="
if [[ ! -f "$HOOK" ]]; then
  echo "(RED state: detector $HOOK does not exist yet — Plan 2 GREEN ships it; staleness scenarios FAIL deterministically)"
fi

# ---- 1. clean — no cache older than live manifest ----
# Asserts ONLY on detector-prefix stderr line count (0). Vacuously holds
# pre-detector: a missing $HOOK emits no `dhx-plugin-cache-staleness:` lines.
# Plan 2 GREEN additionally verifies rc=0 + silent exit.
echo "EXPECT: 0-lines"
home=$(make_case_staleness "clean" 0 "0.1.0:100" 1)
snapshot_cache "$home"
captured=$(run_hook_capture_stderr_staleness "$home"); rc=$?
plines=$(grep -cE '^dhx-plugin-cache-staleness:' <<< "$captured" || true)
if [[ "$plines" == "0" ]]; then
  printf '  ✓ clean: 0 detector-prefix stderr lines (cache newer than live — not stale)\n'
  PASS=$((PASS + 1))
else
  printf '  ✗ clean: expected 0 detector-prefix stderr lines (got %s)\n' "$plines"
  FAIL=$((FAIL + 1))
fi
assert_cache_untouched "clean"

# ---- 2. single-stale — one cache version older than live ----
# Mode is conditioned on 10.1-D-01-RESULT.md: AFFIRM (cache_read_path: yes) →
# REJECT prefix; otherwise → WARN prefix. RED state: detector absent → rc != 1,
# 0 prefix lines → scenario FAILS deterministically.
if [[ -f "$RESULT_ARTIFACT" ]] && grep -q '^cache_read_path: yes' "$RESULT_ARTIFACT"; then
  echo "EXPECT: 1-line+REJECT"; expect_mode="REJECT"
else
  echo "EXPECT: 1-line+WARN"; expect_mode="WARN"
fi
home=$(make_case_staleness "single-stale" 0 "0.1.3:-21600" 1)
snapshot_cache "$home"
captured=$(run_hook_capture_stderr_staleness "$home"); rc=$?
plines=$(grep -cE '^dhx-plugin-cache-staleness:' <<< "$captured" || true)
if [[ "$rc" == "1" && "$plines" == "1" ]] \
   && grep -qE "^dhx-plugin-cache-staleness: ${expect_mode}: .*mtime=[0-9]+ older than live mtime=[0-9]+" <<< "$captured"; then
  printf '  ✓ single-stale: rc=1, exactly 1 %s line w/ mtime body\n' "$expect_mode"
  PASS=$((PASS + 1))
else
  printf '  ✗ single-stale: expected rc=1 + 1 %s line w/ mtime body (got rc=%s, %s prefix lines) [RED until Plan 2]\n' \
    "$expect_mode" "$rc" "$plines"
  FAIL=$((FAIL + 1))
fi
assert_cache_untouched "single-stale"

# ---- 3. multi-stale — two cache versions stale; sort -V iteration order (D-08) ----
# 0.1.2 (1d stale) must be reported BEFORE 0.1.3 (6h stale) per semantic-version
# sort. RED state: detector absent → scenario FAILS deterministically.
if [[ -f "$RESULT_ARTIFACT" ]] && grep -q '^cache_read_path: yes' "$RESULT_ARTIFACT"; then
  echo "EXPECT: 2-lines+REJECT"; expect_mode="REJECT"
else
  echo "EXPECT: 2-lines+WARN"; expect_mode="WARN"
fi
home=$(make_case_staleness "multi-stale" 0 "0.1.2:-86400 0.1.3:-21600" 1)
snapshot_cache "$home"
captured=$(run_hook_capture_stderr_staleness "$home"); rc=$?
plines=$(grep -cE '^dhx-plugin-cache-staleness:' <<< "$captured" || true)
line_012=$(grep -nE '^dhx-plugin-cache-staleness:.*0\.1\.2' <<< "$captured" | head -1 | cut -d: -f1)
line_013=$(grep -nE '^dhx-plugin-cache-staleness:.*0\.1\.3' <<< "$captured" | head -1 | cut -d: -f1)
order_ok=0
if [[ -n "$line_012" && -n "$line_013" && "$line_012" -lt "$line_013" ]]; then
  order_ok=1
fi
if [[ "$rc" == "1" && "$plines" == "2" && "$order_ok" == "1" ]]; then
  printf '  ✓ multi-stale: rc=1, exactly 2 %s lines, sort -V order (0.1.2 before 0.1.3)\n' "$expect_mode"
  PASS=$((PASS + 1))
else
  printf '  ✗ multi-stale: expected rc=1 + 2 %s lines in sort -V order (got rc=%s, %s lines, order_ok=%s) [RED until Plan 2]\n' \
    "$expect_mode" "$rc" "$plines" "$order_ok"
  FAIL=$((FAIL + 1))
fi
assert_cache_untouched "multi-stale"

# ---- 4. dispatcher-integration (D-11/Z1 + D-17 informational) ----
# Builds a SANDBOXED copy of the live session-start.sh, neutralizes every
# live-hook dispatch into an ordering-marker stub (SAFE_FOR_LIVE — no live hook
# executes), then inserts the detector dispatch line AFTER the registry-heal
# anchor and BEFORE the stale-worktree-sweep anchor — exactly the D-17
# dispatcher-only shape Plan 2 lands in the real session-start.sh (NO
# plugin-manifest 3rd entry). Asserts: dispatcher exits 0 (`|| true` swallows
# detector rc); detector prefix line present (FAILS in RED — detector absent);
# ordering heal < detector < sweep.
echo "EXPECT: dispatcher-integration"
home=$(make_case_staleness "dispatcher-integration" 0 "0.1.3:-21600" 1)
sandbox_dispatcher="$home/session-start-sandbox.sh"
if [[ -f "$LIVE_DISPATCHER" ]]; then
  cp "$LIVE_DISPATCHER" "$sandbox_dispatcher"
  # Neutralize every `bash /home/dhx/.claude/hooks/<name>.sh` dispatch into an
  # ordering-marker stub; redirect the /tmp probe-log write into the sandbox.
  sed -i 's#bash /home/dhx/\.claude/hooks/\([a-zA-Z0-9_-]*\)\.sh#echo "DISPATCH:\1"#g' "$sandbox_dispatcher"
  sed -i "s#/tmp/dhx-plugin-probe.log#$home/dhx-plugin-probe.log#g" "$sandbox_dispatcher"
  # D-17 dispatcher-only shape: insert the detector dispatch line right after
  # the registry-heal anchor (mirrors Plan 2's session-start.sh edit position).
  sed -i '/echo "DISPATCH:dhx-plugin-registry-heal"/a bash "'"$HOOK"'" < /dev/null || true' "$sandbox_dispatcher"
  disp_out=$(
    HOME="$home" \
    CLAUDE_CONFIG_DIR="$home/.claude" \
    DHX_CACHE_STALENESS_LIVE_MANIFEST="$home/repos/hooks/dhx-plugin/plugins/dhx/hooks/hooks.json" \
    DHX_CACHE_STALENESS_CACHE_ROOT="$home/.claude/plugins/cache/dhx-local" \
      bash "$sandbox_dispatcher" < /dev/null 2>&1
  )
  disp_rc=$?
  heal_ln=$(grep -nF 'DISPATCH:dhx-plugin-registry-heal' <<< "$disp_out" | head -1 | cut -d: -f1)
  det_ln=$(grep -nE '^dhx-plugin-cache-staleness:' <<< "$disp_out" | head -1 | cut -d: -f1)
  sweep_ln=$(grep -nF 'DISPATCH:dhx-stale-worktree-sweep' <<< "$disp_out" | head -1 | cut -d: -f1)
  di_ok=1; di_reason=""
  [[ "$disp_rc" == "0" ]] || { di_ok=0; di_reason="dispatcher rc=$disp_rc (expected 0 — || true should swallow detector rc)"; }
  if [[ -z "$det_ln" ]]; then
    di_ok=0
    di_reason="${di_reason:+$di_reason; }no detector-prefix line emitted via session-start.sh [RED until Plan 2]"
  elif [[ -n "$heal_ln" && -n "$sweep_ln" ]]; then
    if ! (( heal_ln < det_ln && det_ln < sweep_ln )); then
      di_ok=0
      di_reason="${di_reason:+$di_reason; }ordering wrong (heal=$heal_ln detector=$det_ln sweep=$sweep_ln; expected heal<detector<sweep)"
    fi
  fi
  if (( di_ok )); then
    printf '  ✓ dispatcher-integration: detector fires via session-start.sh dispatch line, ordered heal<detector<sweep\n'
    PASS=$((PASS + 1))
  else
    printf '  ✗ dispatcher-integration: %s\n' "$di_reason"
    FAIL=$((FAIL + 1))
  fi
else
  printf '  ✗ dispatcher-integration: live dispatcher not found at %s\n' "$LIVE_DISPATCHER"
  FAIL=$((FAIL + 1))
fi

# ---- 5. cache-dir-missing (D-13/Z3) ----
# Fresh-install / immediately-post-clone state: $DHX_CACHE_STALENESS_CACHE_ROOT/dhx/
# does not exist → no glob expansion → no candidates → no comparisons. Asserts
# ONLY on detector-prefix stderr line count (0); vacuously holds pre-detector.
# Plan 2 GREEN additionally verifies rc=0 + no glob-expansion error output.
echo "EXPECT: 0-lines"
home=$(make_case_staleness "cache-dir-missing" 0 "" 0)
captured=$(run_hook_capture_stderr_staleness "$home"); rc=$?
plines=$(grep -cE '^dhx-plugin-cache-staleness:' <<< "$captured" || true)
if [[ "$plines" == "0" ]]; then
  printf '  ✓ cache-dir-missing: 0 detector-prefix stderr lines (no cache dir — nothing to compare)\n'
  PASS=$((PASS + 1))
else
  printf '  ✗ cache-dir-missing: expected 0 detector-prefix stderr lines (got %s)\n' "$plines"
  FAIL=$((FAIL + 1))
fi

# ---- 6. empirical-arm (D-01 hybrid + D-18 subcommand surface + D-20 read-only-routine invariant) ----
# D-20: this scenario NEVER writes 10.1-D-01-RESULT.md. The artifact-write path
# (write_result_artifact) is reachable ONLY via the `write-result` case-dispatch
# branch above. Routine probe runs (this path) either print the operator runbook
# to stdout or, with DHX_CACHE_PROBE_SKIP_EMPIRICAL=1, skip straight to the
# artifact-existence assertion.
echo "EXPECT: empirical-arm-result-artifact"
if [[ "${DHX_CACHE_PROBE_SKIP_EMPIRICAL:-0}" != "1" ]]; then
  cat <<RUNBOOK
  --- empirical-arm operator runbook (D-01 / D-03 / D-04 / D-05) ---
  1. mktemp -d a fresh HOME + CLAUDE_CONFIG_DIR sandbox; export both.
  2. claude --version                                  # capture for --cc-version
  3. claude plugin marketplace add --source <dhx-plugin marketplace dir>
  4. claude plugin install dhx
  5. Locate the cache manifest:
       \$HOME/.claude/plugins/cache/dhx-local/dhx/<ver>/hooks/hooks.json
  6. jq-append an additional hook into the EXISTING Stop matcher block's
     hooks array (.hooks.Stop[0].hooks += [...]), pointing at the absolute
     path of tests/probes/fixtures/dhx-cache-probe-marker.sh. D-25 amends
     D-03: Stop fires reliably under claude -p, and appending to the existing
     matcher block (NOT a new "matcher": "" block) eliminates schema-filter
     ambiguity. The marker is a peer of the 4 original Stop commands; live
     source still has 4, cache has 5. The existing SessionStart session-start.sh
     hook remains the REFUTE control per D-05.
  7. DHX_CACHE_PROBE_MARKER_LOG=/tmp/dhx-cache-probe-marker-<sid>.log \\
       claude --debug-file=/tmp/dhx-cache-probe-debug-<sid>.log -p "hi"
  8. Observe + classify per D-05 (decisive on -p because Stop fires):
       AFFIRM       = marker FIRED                                   -> --cache-read-path yes
       REFUTE       = marker did NOT fire AND control hook DID fire  -> --cache-read-path no --control-hook-fired yes
       INCONCLUSIVE = neither fired (claude failed / install error)  -> --cache-read-path inconclusive
  9. Write the artifact deterministically via the D-18 subcommand:
       bash tests/probes/probe-plugin-cache-staleness.sh write-result \\
         --cache-read-path <yes|no|inconclusive> --cc-version "\$(claude --version)" \\
         --evidence <marker-log> --evidence-debug <debug-log> \\
         --control-hook-fired <yes|no> --cache-manifest-path <abs> \\
         --live-manifest-path <abs> --marker-log-path <abs>
 10. Re-run this probe (routine, no subcommand) — the empirical-arm scenario
     then PASSES. (DHX_CACHE_PROBE_SKIP_EMPIRICAL=1 suppresses this runbook.)
  ------------------------------------------------------------------
RUNBOOK
fi
if [[ -f "$RESULT_ARTIFACT" ]] && grep -qE '^cache_read_path: (yes|no|inconclusive)$' "$RESULT_ARTIFACT"; then
  crp=$(awk -F': ' '/^cache_read_path:/ {print $2; exit}' "$RESULT_ARTIFACT")
  printf '  ✓ empirical-arm: 10.1-D-01-RESULT.md present (cache_read_path: %s)\n' "$crp"
  PASS=$((PASS + 1))
else
  printf '  ✗ empirical-arm: 10.1-D-01-RESULT.md absent or cache_read_path not in {yes,no,inconclusive}\n'
  printf '      -> run the operator runbook above, then: bash %s write-result --cache-read-path ...\n' "$0"
  FAIL=$((FAIL + 1))
fi

# ---- timing (D-22): SOURCE-PRESENCE gate in Plan 1 RED; BEHAVIORAL gate is Plan 2 ----
# Plan 1 RED state: the detector does not exist, so a behavioral assertion would
# measure probe-scaffolding overhead, not detector performance — meaningless.
# This block is authored-time evidence the < 50ms gate is WIRED in the probe
# source; Plan 2 (after the detector lands) makes it a hard FAIL gate. Plan 1
# emits the measurement informationally and never FAILs on it.
home=$(make_case_staleness "timing" 0 "0.1.0:100" 1)
t_start=$(date +%s%N)
run_hook_capture_stderr_staleness "$home" >/dev/null 2>&1
t_end=$(date +%s%N)
elapsed_ms=$(( (t_end - t_start) / 1000000 ))
if (( elapsed_ms < 50 )); then
  printf '  ✓ timing: happy path = %sms (< 50ms target — read-only stat boundary)\n' "$elapsed_ms"
else
  printf '  ⚠ timing: happy path = %sms (informational in Plan 1 RED; behavioral < 50ms gate is Plan 2)\n' "$elapsed_ms"
fi

echo "---"
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
exit "$FAIL"
