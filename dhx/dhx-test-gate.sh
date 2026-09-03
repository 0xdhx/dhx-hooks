#!/usr/bin/env bash
# dhx-test-gate.sh — Stop hook
# Patterns: HP-001, HP-002, HP-009, HP-020, HP-028, HP-045, HP-051, HP-059
# Blocks task completion if tests fail. Dual-guard prevents infinite loops.
#
# Cgroup wrap (2026-05-03): when systemd-run + active user@.service are
# present, the test runner is wrapped in `systemd-run --user --scope` with
# MemoryMax + MemorySwapMax=0 (cgroup OOM kill → 137 when the scope's main
# process is the kernel's victim, else 143 — see HP-045) and
# RuntimeMaxSec (SIGTERM at runtime cap → exit 143). Both fail open via the
# exit-code cascade so resource-exhausted gates don't block Stop. Falls back
# to bare invocation when host preconditions are absent. Plugin manifest's
# timeout: 300 stays as defense-in-depth.
#
# Per-project config: .claude/test-gate.json (all keys optional):
#   { "enabled": true,
#     "target": "tests/test_unit",
#     "memory_max": "4G",
#     "runtime_max_sec": 60 }
#   `target` semantics (2026-05-29): a directory → the gate runs from that
#   dir's pytest rootdir (cd <rootdir> && pytest <rel-target>); a file /
#   node-id / glob → appended as a path arg with cwd = repo root.
#
# Opt-out cascade (highest precedence first):
#   1. DHX_SKIP_TEST_GATE=1 env
#   2. .claude/skip-test-gate sentinel
#   3. .claude/test-gate.json {"enabled": false}
#
# Phase-aware skip (post-source-flag, pre-runner): defers the gate when the
# project's .planning/STATE.md shows mid-execute AND a HEAD-reachable PLAN.md
# contracts intentional RED commits AND HEAD is not the GREEN-flip commit.
# Fail-soft: any check error → run the gate normally.
#
# Guard 1: stop_hook_active boolean (official API — true on second+ firing)
# Guard 2: file-based counter keyed by session_id (handles edge cases where
#          stop_hook_active resets unexpectedly: compaction, crashes, #9602)
#
# Companion: dhx-source-write-flag.sh (PostToolUse) sets a dirty flag when
# source files are written. No flag = no source changes = skip tests.
#
# Test runner detection: cascade. Config files → project type indicators →
# subdir/monorepo config discovery → ambient tools → generic fallbacks. Fails
# open if no runner found. Produces a TEST_RUNNER_ARGV array (no `eval`) that
# run_runner() composes with the cgroup prefix + optional target + extra args,
# invoked from RUN_CWD (pytest's rootdir for subdir layouts — see the
# 2026-05-29 subdir-layout decisions row).

set -uo pipefail

# --- Logging (optional — only if project has .claude/hooks/logs/) ---
LOG_DIR="${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/logs"
if [ -d "$LOG_DIR" ]; then
  LOG_FILE="$LOG_DIR/test-gate.log"
  log() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $1" >> "$LOG_FILE"; }
else
  log() { :; }
fi

# --- Resolve Python (venv-aware, cross-platform) ---
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
if [ -x "$PROJECT_DIR/.venv/Scripts/python.exe" ]; then
  PYTHON="$PROJECT_DIR/.venv/Scripts/python.exe"
elif [ -x "$PROJECT_DIR/.venv/bin/python" ]; then
  PYTHON="$PROJECT_DIR/.venv/bin/python"
else
  PYTHON="python"
fi

# --- Parse input ---
INPUT=$(cat)

if ! command -v jq &>/dev/null; then
  log "WARN: jq not found, allowing stop (fail open)"
  exit 0
fi

STOP_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')

# --- Temp directory (Windows-portable) ---
_TMPDIR="${TMPDIR:-${TEMP:-/tmp}}"
COUNTER_FILE="$_TMPDIR/claude-stop-${SESSION_ID}.count"

log "Stop hook fired. session=$SESSION_ID stop_hook_active=$STOP_ACTIVE"

# --- Opt-out cascade (env → sentinel → JSON config) ---
if [ "${DHX_SKIP_TEST_GATE:-}" = "1" ]; then
  log "DHX_SKIP_TEST_GATE=1 → allowing stop"
  rm -f "$COUNTER_FILE"
  exit 0
fi

if [ -f "$PROJECT_DIR/.claude/skip-test-gate" ]; then
  log ".claude/skip-test-gate sentinel present → allowing stop"
  rm -f "$COUNTER_FILE"
  exit 0
fi

# --- Per-project config (target, memory cap, runtime cap) ---
TEST_TARGET=""
# Initialized explicitly: read later as `[ "$MEM_FROM_CFG" = 1 ]`, and an INHERITED
# environment variable of that name would otherwise activate the DHX-7c clamp with
# no config present (found in post-implementation review, 2026-08-11).
MEM_FROM_CFG=0
TEST_BUDGET_MEM="${DHX_TEST_GATE_MEM:-4G}"
TEST_BUDGET_TIME="${DHX_TEST_GATE_RUNTIME:-60}"
CFG="$PROJECT_DIR/.claude/test-gate.json"
if [ -f "$CFG" ]; then
  # NOTE: read `.enabled` directly — `jq '.enabled // true'` is wrong because
  # jq's `//` operator treats `false` as null and falls through to the default.
  # We need to distinguish "absent" (default true) from "explicitly false."
  CFG_ENABLED=$(jq -r '.enabled' "$CFG" 2>/dev/null)
  if [ "$CFG_ENABLED" = "false" ]; then
    log ".claude/test-gate.json .enabled=false → allowing stop"
    rm -f "$COUNTER_FILE"
    exit 0
  fi
  CFG_TARGET=$(jq -r '.target // ""' "$CFG" 2>/dev/null)
  CFG_MEM=$(jq -r --arg fb "$TEST_BUDGET_MEM" '.memory_max // $fb' "$CFG" 2>/dev/null)
  CFG_TIME=$(jq -r --argjson fb "$TEST_BUDGET_TIME" '.runtime_max_sec // $fb' "$CFG" 2>/dev/null)
  # Presence is read SEPARATELY from the value, and keys on the field being a
  # USABLE STRING — not merely present-and-non-null. `.memory_max // $fb` falls back
  # to the env, so CFG_MEM is non-empty whenever the file exists; keying the DHX-7c
  # clamp off CFG_MEM alone would clamp a TRUSTED `DHX_TEST_GATE_MEM` merely because
  # an unrelated test-gate.json was present. And `has() and != null` is not enough
  # either: `{"memory_max": false}` satisfies it while jq's `//` substitutes the
  # trusted env into CFG_MEM — clamping 16G to 8G on a config that set no memory at
  # all. Type-check matches the interceptor's `if type == "string"` reader.
  CFG_MEM_PRESENT=$(jq -r 'if (.memory_max | type) == "string" then "1" else "0" end' \
                      "$CFG" 2>/dev/null)
  [ -n "$CFG_TARGET" ] && TEST_TARGET="$CFG_TARGET"
  [ -n "$CFG_MEM" ]    && { TEST_BUDGET_MEM="$CFG_MEM"
                            [ "$CFG_MEM_PRESENT" = "1" ] && MEM_FROM_CFG=1; }
  [ -n "$CFG_TIME" ]   && TEST_BUDGET_TIME="$CFG_TIME"
fi

# --- Guard 1: official boolean ---
if [ "$STOP_ACTIVE" = "true" ]; then
  log "stop_hook_active=true → allowing stop (primary guard)"
  rm -f "$COUNTER_FILE"
  exit 0
fi

# --- Guard 2: file-based counter ---
COUNT=$(cat "$COUNTER_FILE" 2>/dev/null || echo "0")
COUNT=$((COUNT + 1))
echo "$COUNT" > "$COUNTER_FILE"

if [ "$COUNT" -ge 2 ]; then
  log "Counter=$COUNT ≥ 2 → allowing stop (secondary guard)"
  rm -f "$COUNTER_FILE"
  exit 0
fi

# --- Skip if no source files written this turn ---
SOURCE_FLAG="$_TMPDIR/claude-source-dirty-${SESSION_ID}.flag"

if [ ! -f "$SOURCE_FLAG" ]; then
  log "No source files written this turn → skipping tests"
  rm -f "$COUNTER_FILE"
  exit 0
fi

# Flag exists → source was written. Consume it.
rm -f "$SOURCE_FLAG"
log "Source files written this turn → running tests"

# --- Phase-aware skip: defer gate during intentional-RED phase windows ---
# When a multi-plan phase is mid-execute and a HEAD-reachable PLAN.md
# contracts intentional RED commits (D-05(v) bisectable RED→GREEN), the Stop
# hook fires between Wave-1 RED and Wave-2 GREEN-flip and reports
# RED-by-design tests as failures. Skip when ALL THREE conditions hold; the
# user's `/dhx:test {phase}` is the structured verification path. Defense-in-
# depth alongside any plan-side `it.fails()`-style convention.
#
# Fail-soft: any check that errors → don't skip → run the gate normally. The
# skip path must NOT be more trusted than the alarm path.
PHASE_SKIP_REASON=""
PHASE_SKIP_PHASE=""
STATE_FILE="$PROJECT_DIR/.planning/STATE.md"
if [ -f "$STATE_FILE" ] && \
   grep -qiE '^status:[[:space:]]*executing' "$STATE_FILE" 2>/dev/null; then
  # HEAD-reachable PLAN.md walk. `git log -50` narrows search; sort -u dedupes
  # plans modified across multiple commits. Any pipeline error → empty list.
  PLAN_FILES=$(cd "$PROJECT_DIR" 2>/dev/null && \
    git log -50 --pretty=format: --name-only 2>/dev/null \
      | grep -E '^\.planning/phases/.+/.+-PLAN\.md$' | sort -u || true)
  if [ -n "$PLAN_FILES" ]; then
    while IFS= read -r plan; do
      [ -z "$plan" ] && continue
      plan_content=$(cd "$PROJECT_DIR" 2>/dev/null && git show "HEAD:$plan" 2>/dev/null) || continue
      if grep -qE '(RED|D-05\(v\)|intentional.*failure|expected.*failure|bisectable)' <<< "$plan_content" 2>/dev/null; then
        PHASE_SKIP_PHASE=$(echo "$plan" | sed -nE 's|.*/phases/([^/]+)/.*|\1|p')
        PHASE_SKIP_REASON="phase contracts intentional RED at $plan"
        break
      fi
    done <<< "$PLAN_FILES"
  fi
  # Override: if HEAD's commit subject names GREEN/flip, the user wants the
  # gate to run and verify the flip — clear the skip reason.
  if [ -n "$PHASE_SKIP_REASON" ]; then
    HEAD_MSG=$(cd "$PROJECT_DIR" 2>/dev/null && git log -1 --format=%s HEAD 2>/dev/null) || HEAD_MSG=""
    if grep -qiE '\b(green|flip)\b|\(GREEN\)' <<< "$HEAD_MSG" 2>/dev/null; then
      log "Phase-aware: HEAD subject names GREEN/flip ('$HEAD_MSG') → running gate"
      PHASE_SKIP_REASON=""
    fi
  fi
fi

if [ -n "$PHASE_SKIP_REASON" ]; then
  PHASE_DISPLAY="${PHASE_SKIP_PHASE:-the active phase}"
  SKIP_MSG="[stop-hook] Skipping test-gate: $PHASE_SKIP_REASON. Re-run /dhx:test $PHASE_DISPLAY for verification."
  log "Phase-aware skip: $PHASE_SKIP_REASON (phase=$PHASE_DISPLAY)"
  # Stop schema rejects hookSpecificOutput (validator allows it only for
  # Pre/PostToolUse/UserPromptSubmit/PostToolBatch). systemMessage is the
  # universal top-level advisory channel and matches the non-blocking,
  # exit-0 intent of this skip path.
  jq -nc --arg msg "$SKIP_MSG" '{systemMessage:$msg}'
  rm -f "$COUNTER_FILE"
  exit 0
fi

# --- Detect test runner (cascade → TEST_RUNNER_ARGV array) ---
cd "$PROJECT_DIR" || exit 0

# Subdir/monorepo layout helpers (2026-05-29). A repo can keep its pytest
# config (pytest.ini / pyproject[tool.pytest] / setup.cfg / tox.ini) in a
# subdirectory rather than at the repo root. pytest resolves rootdir by walking
# UP from its args/cwd, so bare pytest from the repo root never sees a subdir
# config — its addopts/markers are silently dropped and a broader/wrong
# selection runs. These helpers let the gate anchor on the config dir (= pytest
# rootdir) and run from there. See docs/decisions.md 2026-05-29 row.

# _has_pytest_cfg DIR — true if DIR holds a recognized pytest config.
_has_pytest_cfg() {
  local d="$1"
  [ -f "$d/pytest.ini" ] && return 0
  [ -f "$d/pyproject.toml" ] && grep -qE '^\[tool\.pytest' "$d/pyproject.toml" 2>/dev/null && return 0
  [ -f "$d/setup.cfg" ] && grep -q '^\[tool:pytest\]' "$d/setup.cfg" 2>/dev/null && return 0
  [ -f "$d/tox.ini" ] && grep -q '^\[pytest\]' "$d/tox.ini" 2>/dev/null && return 0
  return 1
}

# walk_up_for_pytest_config START — echo the nearest ancestor (incl. START)
# holding a pytest config, walking up to PROJECT_DIR ('.'). START is relative
# to PROJECT_DIR. Echo nothing + return 1 if none found.
walk_up_for_pytest_config() {
  local d="${1#./}"
  while :; do
    if _has_pytest_cfg "$d"; then printf '%s\n' "$d"; return 0; fi
    [ "$d" = "." ] && break
    d=$(dirname "$d")
  done
  return 1
}

# discover_subdir_pytest_rootdir — bounded-depth search for a pytest config in
# a SUBDIRECTORY (repo root already handled by the cascade). Echo the single
# unambiguous config dir (relative, no leading ./) + return 0; on zero or
# multiple matches echo nothing + return 1 (logging the ambiguous case). Only
# reached when no root config/runner matched, so the find cost is bounded to
# the already-misfiring layouts.
discover_subdir_pytest_rootdir() {
  local f dir
  local -a dirs=()
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    dir=$(dirname "$f"); dir="${dir#./}"
    [ "$dir" = "." ] && continue
    case "$(basename "$f")" in
      pytest.ini)     dirs+=("$dir") ;;
      pyproject.toml) grep -qE '^\[tool\.pytest' "$f" 2>/dev/null && dirs+=("$dir") ;;
      setup.cfg)      grep -q '^\[tool:pytest\]' "$f" 2>/dev/null && dirs+=("$dir") ;;
      tox.ini)        grep -q '^\[pytest\]' "$f" 2>/dev/null && dirs+=("$dir") ;;
    esac
  done < <(find . -maxdepth 3 \
             \( -name .git -o -name node_modules -o -name .venv -o -name venv \
                -o -name dist -o -name build -o -name .tox -o -name '*.egg-info' \) -prune -o \
             -type f \( -name pytest.ini -o -name pyproject.toml \
                        -o -name setup.cfg -o -name tox.ini \) -print 2>/dev/null)
  [ "${#dirs[@]}" -eq 0 ] && return 1
  local uniq
  uniq=$(printf '%s\n' "${dirs[@]}" | sort -u)
  if [ "$(printf '%s\n' "$uniq" | wc -l)" -eq 1 ]; then
    printf '%s\n' "$uniq"
    return 0
  fi
  log "Multiple subdir pytest configs found (ambiguous): $(printf '%s ' $uniq)→ not anchoring; running from repo root"
  return 1
}

IS_PYTEST=0
DISCOVERED_ROOTDIR=""
TEST_RUNNER_ARGV=()
if [ -f "pytest.ini" ] || [ -f "pytest.toml" ] || [ -f ".pytest.toml" ]; then
  TEST_RUNNER_ARGV=("$PYTHON" -m pytest --tb=short -q)
  IS_PYTEST=1
elif [ -f "pyproject.toml" ] && grep -qE '^\[tool\.pytest' pyproject.toml 2>/dev/null; then
  TEST_RUNNER_ARGV=("$PYTHON" -m pytest --tb=short -q)
  IS_PYTEST=1
elif [ -f "setup.cfg" ] && grep -q '^\[tool:pytest\]' setup.cfg 2>/dev/null; then
  TEST_RUNNER_ARGV=("$PYTHON" -m pytest --tb=short -q)
  IS_PYTEST=1
elif [ -f "Cargo.toml" ]; then
  TEST_RUNNER_ARGV=(cargo test)
elif [ -f "go.mod" ]; then
  TEST_RUNNER_ARGV=(go test ./...)
elif [ -f "package.json" ] && grep -q '"test"' package.json 2>/dev/null && \
     ! grep -q 'no test specified' package.json 2>/dev/null; then
  TEST_RUNNER_ARGV=(npm test)
elif DISCOVERED_ROOTDIR=$(discover_subdir_pytest_rootdir) && [ -n "$DISCOVERED_ROOTDIR" ]; then
  # No root config matched, but a single unambiguous subdir pytest config
  # exists → anchor on it. run_runner cd's to $RUN_CWD (set below) so pytest
  # resolves rootdir from the config dir. Placed AFTER the package.json branch
  # so a real root npm suite still wins (preserves the 2026-04-14 cascade
  # ordering); fires only where the gate would otherwise fall to ambient/fail-open.
  TEST_RUNNER_ARGV=("$PYTHON" -m pytest --tb=short -q)
  IS_PYTEST=1
  log "Subdir pytest config discovered at $DISCOVERED_ROOTDIR → cwd=$DISCOVERED_ROOTDIR"
elif "$PYTHON" -m pytest --version &>/dev/null 2>&1; then
  TEST_RUNNER_ARGV=("$PYTHON" -m pytest --tb=short -q)
  IS_PYTEST=1
elif ls tests/test_*.py &>/dev/null 2>&1 || ls test_*.py &>/dev/null 2>&1; then
  TEST_RUNNER_ARGV=("$PYTHON" -m unittest discover -v)
elif [ -f "Makefile" ] && grep -q '^test:' Makefile 2>/dev/null; then
  TEST_RUNNER_ARGV=(make test)
else
  log "No test runner detected → allowing stop (fail open)"
  rm -f "$COUNTER_FILE"
  exit 0
fi

# --- Resolve effective working directory + target arg (subdir/monorepo) ---
# RUN_CWD = directory the runner is invoked from (pytest's rootdir when a config
# lives there). RUN_TARGET = optional path arg, relative to RUN_CWD. Reproduces
# the canonical `cd <config-dir> && <runner> [rel-target]`: `python -m` puts cwd
# on sys.path, addopts/markers load, .pytest_cache anchors at the rootdir.
# See docs/decisions.md 2026-05-29 row.
RUN_CWD="$PROJECT_DIR"
RUN_TARGET=""
if [ -n "$TEST_TARGET" ] && [[ "$TEST_TARGET" != /* ]] && [ -d "$TEST_TARGET" ]; then
  # Explicit target is a (relative) directory → anchor on its pytest rootdir.
  _cfgdir=$(walk_up_for_pytest_config "$TEST_TARGET" || true)
  if [ -n "$_cfgdir" ]; then
    RUN_CWD="$PROJECT_DIR/$_cfgdir"
    [ "$TEST_TARGET" != "$_cfgdir" ] && RUN_TARGET="${TEST_TARGET#"$_cfgdir"/}"
    log "Target '$TEST_TARGET' is a dir; pytest rootdir=$_cfgdir → cwd=$_cfgdir, target=${RUN_TARGET:-<none>}"
  else
    RUN_CWD="$PROJECT_DIR/$TEST_TARGET"
    log "Target '$TEST_TARGET' is a dir with no pytest config above it → cwd=$TEST_TARGET"
  fi
elif [ -n "$TEST_TARGET" ]; then
  # File / node-id / glob / absolute path → append as an arg, cwd = repo root.
  RUN_TARGET="$TEST_TARGET"
elif [ -n "$DISCOVERED_ROOTDIR" ]; then
  RUN_CWD="$PROJECT_DIR/$DISCOVERED_ROOTDIR"
fi

# --- Cgroup wrap factory (single-sourced via dhx-cgroup-cap.sh) ---
# MemoryMax + MemorySwapMax=0 → cgroup OOM kill on overrun. The status is 137
# when the scope's MAIN process is the kernel's victim and 143 when it is not
# (systemd SIGTERMs the survivors under OOMPolicy=stop) — isolated 2026-09-03,
# HP-045; cap magnitude is not causal. The exit code still does NOT distinguish a
# memory kill from a runtime kill: for that, read the named scope's UNIT_RESULT
# (`oom-kill` vs `timeout`), not `$?`. (MemoryMax alone is advisory on hosts with swap available —
# verified empirically on this
# WSL2 host; see reports/2026-05-03-test-gate-collection-cost.md). RuntimeMaxSec
# is the systemd-native runtime ceiling (NOT TimeoutStopSec, which is the
# SIGTERM→SIGKILL grace period after stop is requested) — fires at the cap
# with SIGTERM/exit 143. Both 137 and 143 fail open via the exit-code cascade
# below. Empty array on hosts without systemd-run + active user@.service —
# graceful fallback to bare invocation. Outer `timeout` deliberately not
# layered on top: RuntimeMaxSec is the systemd-native bound; double-killing
# would obscure which surface fired. Plugin manifest's `timeout: 300` is the
# defense-in-depth layer for hosts where neither cgroup nor RuntimeMaxSec
# applies.
#
# The cap construction lives in dhx-cgroup-cap.sh (sourced from this hook's own
# dir — the symlink dir in live, the repo dir under the probe) so the gate and
# the mid-session interceptor (dhx-pytest-cgroup-cap.sh, DHX-7) share ONE wrap
# source and can't copy-drift. The mapfile'd token array with the runtime budget
# present is byte-for-byte what this block built inline before the extraction.
# If the lib is absent/truncated or the host lacks support, CGROUP_PREFIX stays
# empty → bare invocation (unchanged fail-open behavior).
#
# DHX-7c (2026-08-11) — budget validation lives HERE, adjacent to the one place the
# value is used, and the lib is sourced ONCE for both validation and construction.
# The first cut put this before the guards; that ran arithmetic and a source on every
# second Stop firing and on turns with no source flag, and double-sourced the lib.
# Ceiling raised 8G -> 12G 2026-08-14: statforge's full suite measures 9.44 GiB
# under `-n 4 --dist loadfile` (cgroup-summed, uncensored; 6.87 GiB serial) — the
# 8G ceiling sat below legitimate demand. 12G keeps ~3x margin under the ~37 GB
# runaway class. Matches the interceptor's MEM_CEILING (dhx-pytest-cgroup-cap.sh).
TEST_GATE_MEM_CEILING="12G"
TEST_GATE_MEM_FALLBACK="4G"   # known-good; the pre-config default
CGROUP_PREFIX=()
_CAP_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dhx-cgroup-cap.sh"
if [ -f "$_CAP_LIB" ] && . "$_CAP_LIB" 2>/dev/null && dhx_cgroup_available; then

  # (a) UNTRUSTED repo config is ceiling-clamped. `.claude/test-gate.json`
  # `.memory_max` reached `MemoryMax=` with no grammar and no ceiling before DHX-7c,
  # so `{"memory_max":"999G"}` raised the machine-safety cap outright. A repo may
  # lower the cap, never raise it. Non-numeric systemd forms (`infinity`, `50%`) are
  # NOT honored from a repo — they cannot be compared to a ceiling, and `infinity`
  # from an untrusted source is the bypass by another name; they fall back below.
  # `DHX_TEST_GATE_MEM` is operator-set: trusted, unbounded, never clamped (matching
  # the interceptor's `DHX_PYTEST_CAP_MEM`).
  if [ "$MEM_FROM_CFG" = "1" ] && declare -F dhx_cgroup_mem_bytes >/dev/null 2>&1; then
    _tg_bytes=$(dhx_cgroup_mem_bytes "$TEST_BUDGET_MEM"); _tg_rc=$?
    _tg_ceil=$(dhx_cgroup_mem_bytes "$TEST_GATE_MEM_CEILING"); _tg_ceil_rc=$?
    if [ "$_tg_ceil_rc" -ne 0 ]; then
      # The ceiling is a compile-time constant; if it will not convert, the clamp
      # cannot be evaluated at all. Refuse the repo value outright rather than
      # leaving it active — an unevaluable ceiling must never mean "no ceiling".
      log "DHX-7c: ceiling '$TEST_GATE_MEM_CEILING' unconvertible (rc=$_tg_ceil_rc) → refusing repo value, using $TEST_GATE_MEM_FALLBACK"
      TEST_BUDGET_MEM="$TEST_GATE_MEM_FALLBACK"
    elif [ "$_tg_rc" -eq 2 ]; then
      log "test-gate.json memory_max='$TEST_BUDGET_MEM' malformed → using ${DHX_TEST_GATE_MEM:-$TEST_GATE_MEM_FALLBACK}"
      TEST_BUDGET_MEM="${DHX_TEST_GATE_MEM:-$TEST_GATE_MEM_FALLBACK}"
    elif [ "$_tg_rc" -eq 1 ] || [ "$_tg_bytes" -gt "$_tg_ceil" ]; then
      log "test-gate.json memory_max='$TEST_BUDGET_MEM' exceeds ceiling → clamped to $TEST_GATE_MEM_CEILING"
      TEST_BUDGET_MEM="$TEST_GATE_MEM_CEILING"
    fi
  fi

  # (b) The EFFECTIVE value — whatever its source, including the trusted env — must
  # be a systemd spec the factory will accept. Without this an invalid value reaches
  # `dhx_cgroup_prefix_tokens`, which refuses and emits nothing, and `mapfile`
  # discards that refusal (HP-051) leaving an EMPTY prefix — i.e. the suite runs
  # UNCAPPED. Uncapped must never be a validation outcome.
  if declare -F dhx_cgroup_mem_spec_valid >/dev/null 2>&1 \
     && ! dhx_cgroup_mem_spec_valid "$TEST_BUDGET_MEM"; then
    log "DHX-7c: effective memory budget '$TEST_BUDGET_MEM' is not a valid systemd spec → using $TEST_GATE_MEM_FALLBACK"
    TEST_BUDGET_MEM="$TEST_GATE_MEM_FALLBACK"
  fi

  # (b2) Scope LABEL — `dhx-cap-testgate-<repo>-…` (2026-09-02). The factory names
  # every scope it builds so a `journalctl --user` OOM-kill record is attributable
  # without a session of forensics; the repo half answers WHICH suite, which a bare
  # consumer label cannot. `dhx_cgroup_unit_label` sanitizes and never refuses, so a
  # weird basename cannot become an empty prefix (i.e. an uncapped run). See that
  # function's header and `dhx_cgroup_prefix_tokens`' NAMING block.
  # `${x##*/}` not `basename`: this is on the Stop path and a fork per firing buys
  # nothing. A trailing slash or a bare `.` yields an empty/`.` tail, which the
  # sanitizer collapses to plain `testgate` — degraded, never broken.
  _TG_CAP_LABEL="testgate-${PROJECT_DIR##*/}"

  mapfile -t CGROUP_PREFIX < <(dhx_cgroup_prefix_tokens "$TEST_BUDGET_MEM" "$TEST_BUDGET_TIME" "$_TG_CAP_LABEL")

  # (c) HP-051 backstop. `mapfile` cannot report the producer's refusal, so assert
  # the OUTCOME instead of trusting the status. An empty array here means the factory
  # refused a value (b) thought was fine — a logic error, not a host-capability miss.
  # Retry once with the known-good fallback; if that also yields nothing, log loudly
  # and accept the bare invocation (the gate's contract is fail-open — it must not
  # block Stop — but the operator gets a breadcrumb instead of silence).
  if [ "${#CGROUP_PREFIX[@]}" -eq 0 ]; then
    log "DHX-7c/HP-051: factory emitted no prefix for mem='$TEST_BUDGET_MEM' → retrying with $TEST_GATE_MEM_FALLBACK"
    TEST_BUDGET_MEM="$TEST_GATE_MEM_FALLBACK"
    mapfile -t CGROUP_PREFIX < <(dhx_cgroup_prefix_tokens "$TEST_BUDGET_MEM" "$TEST_BUDGET_TIME" "$_TG_CAP_LABEL")
    [ "${#CGROUP_PREFIX[@]}" -eq 0 ] && \
      log "DHX-7c/HP-051: WARNING factory still emitted no prefix → runner will be UNCAPPED"
  fi
fi

# --- Helper: compose argv with cgroup prefix + runner + optional target +
# extra args; invoke directly via "${argv[@]}" — no eval, no string fragility.
run_runner() {
  local extra=("$@")
  local argv=("${CGROUP_PREFIX[@]}" "${TEST_RUNNER_ARGV[@]}")
  if [ -n "$RUN_TARGET" ]; then
    argv+=("$RUN_TARGET")
  fi
  if [ "${#extra[@]}" -gt 0 ]; then
    argv+=("${extra[@]}")
  fi
  [ "$RUN_CWD" != "$PROJECT_DIR" ] && log "Runner cwd: $RUN_CWD"
  log "Running: ${argv[*]}"
  # Subshell cd so the runner resolves pytest's rootdir from the config dir
  # (addopts/markers, sys.path via `python -m`, .pytest_cache). RUN_CWD is
  # always a validated existing dir (PROJECT_DIR, a discovered config dir, or a
  # `-d`-checked target), so the cd does not fail in practice.
  ( cd "$RUN_CWD" && "${argv[@]}" 2>&1 )
}

# --- pytest --last-failed branch (primary; no dead -x full-suite fallback) ---
if [ "$IS_PYTEST" = "1" ] && [ -d "$RUN_CWD/.pytest_cache" ]; then
  LF_EXIT=0
  LF_OUTPUT=$(run_runner --last-failed --last-failed-no-failures none) || LF_EXIT=$?

  case "$LF_EXIT" in
    0)
      if grep -q "no tests ran" <<< "$LF_OUTPUT"; then
        log "No previously-failed tests (suite was clean) → allowing stop"
      else
        log "Previously-failed tests now pass → allowing stop"
      fi
      rm -f "$COUNTER_FILE"
      exit 0
      ;;
    5)
      log "No tests collected (pytest exit 5) → allowing stop"
      rm -f "$COUNTER_FILE"
      exit 0
      ;;
    137|143|124)
      log "Test runner exceeded resource budget (exit $LF_EXIT, mem=$TEST_BUDGET_MEM, runtime=${TEST_BUDGET_TIME}s) → fail open. Tune via .claude/test-gate.json."
      rm -f "$COUNTER_FILE"
      exit 0
      ;;
    *)
      log "Last-failed tests still failing (exit $LF_EXIT) → blocking stop"
      echo "Test suite failed. Fix these failures before completing:" >&2
      tail -n 60 <<< "$LF_OUTPUT" >&2
      exit 2
      ;;
  esac
fi

# --- Non-pytest fallback OR pytest with no .pytest_cache: bounded full suite ---
TEST_EXIT=0
TEST_OUTPUT=$(run_runner) || TEST_EXIT=$?

case "$TEST_EXIT" in
  0)
    log "Tests passed → allowing stop"
    rm -f "$COUNTER_FILE"
    exit 0
    ;;
  5)
    if [ "$IS_PYTEST" = "1" ]; then
      log "No tests collected (pytest exit 5) → allowing stop"
      rm -f "$COUNTER_FILE"
      exit 0
    fi
    log "Tests FAILED (exit 5) → blocking stop"
    echo "Test suite failed. Fix these failures before completing:" >&2
    tail -n 60 <<< "$TEST_OUTPUT" >&2
    exit 2
    ;;
  137|143|124)
    log "Test runner exceeded resource budget (exit $TEST_EXIT, mem=$TEST_BUDGET_MEM, runtime=${TEST_BUDGET_TIME}s) → fail open. Tune via .claude/test-gate.json."
    rm -f "$COUNTER_FILE"
    exit 0
    ;;
  *)
    log "Tests FAILED (exit $TEST_EXIT) → blocking stop"
    echo "Test suite failed. Fix these failures before completing:" >&2
    tail -n 60 <<< "$TEST_OUTPUT" >&2
    exit 2
    ;;
esac
