#!/usr/bin/env bash
# scripts/verify-multi-cc-results.sh — defensive validator for the
# supersession-watchdog cross-version result corpus.
#
# Scans tests/probes/.results/v1.3-multi-cc-ver/<cc-version>/*.json and
# enforces the 6 D-08 assertions from Phase 15 (MULTI-CC-VER):
#   1. .cc_version field equals active CC (or the explicit-version arg).
#   2. .cc_version_match: true where the field is present — UNLESS the
#      conclusion is "ambiguous" (legitimate stale-anchor signal,
#      documented via D-17 fragility brief; cross-check via D-08 #5).
#   3. .probe_id ∈ the 5-name supersession-watchdog allowlist.
#   4. .conclusion matches the allowed-token regex (D-08 #4).
#   5. No JSON with conclusion="ambiguous" is cited in any docs/decisions.md
#      row that contains the literal phrase "Validated stable" (D-08 A1
#      single-pass per-row grep idiom).
#   6. Each result file resolves under the expected
#      tests/probes/.results/v1.3-multi-cc-ver/<cc-version>/ path prefix.
#
# Invocation modes (D-24):
#   bash scripts/verify-multi-cc-results.sh             # active CC (default)
#   bash scripts/verify-multi-cc-results.sh 2.1.140     # explicit version
#   bash scripts/verify-multi-cc-results.sh --all       # every <cc-ver>/ dir
#
# Exit codes:
#   0 = all assertions pass (silent on stdout).
#   1 = at least one validation FAIL (per-FAIL line on stderr).
#   2 = explicit-version arg points at a non-existent dir (D-24).
#
# Stderr prefix on each FAIL: "verify-multi-cc-results: <reason> (in <file>)".
#
# set discipline: -uo pipefail (NOT -e; Phase 3 D-25 / Phase 6 WR-04 — collect
# all violations across the corpus, exit at end). A2 defensive accessors
# ([[ -n "${var:-}" ]] guards after each jq -r) ensure missing fields surface
# as diagnostic FAILs rather than aborting the script.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
RESULTS_ROOT="$REPO/tests/probes/.results/v1.3-multi-cc-ver"

# The 5-name supersession-watchdog allowlist (D-08 #3).
ALLOWED_PROBES=(
  probe-effort-level-stdin-absent
  probe-installed-plugins-no-natural-heal
  probe-installed-plugins-badjson-natural-heal
  probe-installed-plugins-uninstalled-dhx-natural-heal
  probe-known-marketplaces-natural-heal
)

# Allowed-token regex for .conclusion (D-08 #4).
# v1_2_work_warranted is a legacy synonym for validated_stable (per
# 15-01-PLAN.md <interfaces> note + v1.2-phase-6 km baseline precedent).
ALLOWED_CONCLUSION_RE='^(validated_stable|supersession_found_[a-z_0-9]+|ambiguous|v1_2_work_warranted)$'

# Field extractors used below (documented here so the validator surface is
# greppable as a contract):
#   jq -r .cc_version           — assertion 1
#   jq -r .cc_version_match     — assertion 2
#   jq -r .probe_id             — assertion 3
#   jq -r .conclusion           — assertion 4 (token whitelist) + 5 (ambiguous gate)
# Path-prefix asserted in assertion 6:
#   tests/probes/.results/v1.3-multi-cc-ver/<cc-version>/

resolve_active_cc() {
  local cc_full cc
  cc_full=$(claude --version 2>/dev/null)
  cc=$(printf '%s' "$cc_full" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  printf '%s' "$cc"
}

in_allowlist() {
  local needle="$1"
  local p
  for p in "${ALLOWED_PROBES[@]}"; do
    [[ "$p" == "$needle" ]] && return 0
  done
  return 1
}

# validate_dir <cc-version>
# Runs all 6 assertions against $RESULTS_ROOT/<cc-version>/*.json.
# Echoes the FAIL count on stdout (0 if all pass); per-assertion diagnostics go
# to stderr. Callers capture the count via command substitution — NOT the exit
# status, which is taken mod 256 and would wrap a 256-failure dir to "clean"
# (IN-04). validate_dir is stdout-silent otherwise, so stdout carries only the count.
validate_dir() {
  local cc="$1"
  local dir="$RESULTS_ROOT/$cc"
  local fails=0
  local f field_cc match pid conc

  if [[ ! -d "$dir" ]]; then
    # Bare mode (active CC) treats this as non-blocking (D-21 wording);
    # explicit-version mode handles the absent case as exit 2 at top level.
    printf '%s\n' 0
    return 0
  fi

  shopt -s nullglob
  for f in "$dir"/*.json; do
    # Assertion 6: path-shape (iteration already constrains this, but
    # realpath-round-trip catches symlink-traversal anomalies).
    local real expected_prefix
    real=$(realpath "$f" 2>/dev/null || printf '%s' "$f")
    expected_prefix="$REPO/tests/probes/.results/v1.3-multi-cc-ver/$cc/"
    if [[ "$real" != "$expected_prefix"* ]]; then
      echo "verify-multi-cc-results: path-shape anomaly (resolves outside $expected_prefix) (in $f)" >&2
      fails=$((fails+1))
    fi

    # Assertion 1: cc_version
    field_cc=$(jq -r '.cc_version // empty' "$f" 2>/dev/null)
    if [[ -z "${field_cc:-}" ]]; then
      echo "verify-multi-cc-results: missing .cc_version field (in $f)" >&2
      fails=$((fails+1))
    elif [[ "$field_cc" != "$cc" ]]; then
      echo "verify-multi-cc-results: cc_version mismatch (expected $cc, got $field_cc) (in $f)" >&2
      fails=$((fails+1))
    fi

    # Assertion 4: conclusion (read first so #2 can cross-check on ambiguous).
    conc=$(jq -r '.conclusion // empty' "$f" 2>/dev/null)
    if [[ -z "${conc:-}" ]]; then
      echo "verify-multi-cc-results: missing .conclusion field (in $f)" >&2
      fails=$((fails+1))
    elif [[ ! "$conc" =~ $ALLOWED_CONCLUSION_RE ]]; then
      echo "verify-multi-cc-results: .conclusion '$conc' not in allowed token set (in $f)" >&2
      fails=$((fails+1))
    fi

    # Assertion 2: cc_version_match: true where present — UNLESS conclusion
    # is "ambiguous" (legitimate stale-anchor signal preserved via D-17
    # fragility brief; assertion #5 cross-checks against decisions.md
    # so ambiguous cells cannot pollute Validated stable rows).
    # Note: do NOT use `// empty` here — boolean `false` is falsy in jq's //
    # operator, so we use a `has(...) | <bool>|tostring` form to preserve the
    # literal "false" string.
    if jq -e 'has("cc_version_match")' "$f" >/dev/null 2>&1; then
      match=$(jq -r 'if has("cc_version_match") then (.cc_version_match | tostring) else "" end' "$f" 2>/dev/null)
      if [[ -z "${match:-}" ]]; then
        echo "verify-multi-cc-results: cc_version_match present but null (in $f)" >&2
        fails=$((fails+1))
      elif [[ "$match" != "true" ]] && [[ "$conc" != "ambiguous" ]]; then
        echo "verify-multi-cc-results: cc_version_match=$match but conclusion='$conc' (expected true for non-ambiguous) (in $f)" >&2
        fails=$((fails+1))
      fi
    fi

    # Assertion 3: probe_id in allowlist
    pid=$(jq -r '.probe_id // empty' "$f" 2>/dev/null)
    if [[ -z "${pid:-}" ]]; then
      echo "verify-multi-cc-results: missing .probe_id field (in $f)" >&2
      fails=$((fails+1))
    elif ! in_allowlist "$pid"; then
      echo "verify-multi-cc-results: .probe_id '$pid' not in supersession-watchdog allowlist (in $f)" >&2
      fails=$((fails+1))
    fi

    # Assertion 5 (D-08 A1 single-pass per-row grep idiom): if this JSON
    # has conclusion=="ambiguous", no docs/decisions.md row may simultaneously
    # cite THIS version's cell AND contain "Validated stable" verdict text.
    #
    # Version-scoped (Phase 19 fix): the row must cite this cell's
    # version-scoped path ("v1.3-multi-cc-ver/<cc>/<pid>") on the same line as
    # the "Validated stable" verdict — NOT merely the bare probe basename.
    # A bare-basename grep cross-contaminated versions: a fresh 2.1.148
    # `ambiguous` cell falsely matched the 2.1.140 "Validated stable" row
    # (which legitimately validates the SEPARATE 2.1.140 cell). Validated-stable
    # rows always cite the full versioned path, so the version-scoped match is
    # exact: an ambiguous cell can only trip on a row claiming THAT SAME cell
    # is stable — the real corpus-integrity hazard.
    if [[ "$conc" == "ambiguous" ]] && [[ -n "${pid:-}" ]] && [[ -f "$REPO/docs/decisions.md" ]]; then
      # Order-independent same-line match: the row must reference BOTH this
      # cell's version-scoped path AND the "Validated stable" verdict (grep the
      # path first, then re-grep that row for the verdict — robust to whichever
      # table column each token lands in).
      # grep -F (IN-03): the cell path is a literal substring, not a regex. -F
      # treats ERE metacharacters in the operator-supplied $cc (and $pid) as
      # literal, so a version like '2.1.*' cannot over-match decisions.md rows.
      if grep -F "v1.3-multi-cc-ver/${cc}/${pid}" "$REPO/docs/decisions.md" 2>/dev/null \
           | grep -F "Validated stable" >/dev/null 2>&1; then
        echo "verify-multi-cc-results: $pid (cc $cc) has conclusion=ambiguous but its $cc cell is cited in a 'Validated stable' row of docs/decisions.md (in $f)" >&2
        fails=$((fails+1))
      fi
    fi
  done
  shopt -u nullglob

  printf '%s\n' "$fails"
}

# --- Arg parsing (D-24) ---
MODE="active"
TARGET_VERSION=""
case "${1:-}" in
  "")
    MODE="active"
    ;;
  --all)
    MODE="all"
    ;;
  -h|--help)
    sed -n '2,32p' "$0"
    exit 0
    ;;
  *)
    MODE="explicit"
    TARGET_VERSION="$1"
    ;;
esac

# --- Dispatch ---
GLOBAL_FAILS=0

case "$MODE" in
  active)
    cc=$(resolve_active_cc)
    if [[ -z "$cc" ]]; then
      echo "verify-multi-cc-results: could not resolve active CC version via 'claude --version'" >&2
      exit 1
    fi
    # Non-blocking when target dir absent (D-21 wording).
    if [[ ! -d "$RESULTS_ROOT/$cc" ]]; then
      exit 0
    fi
    GLOBAL_FAILS=$(validate_dir "$cc")
    ;;
  explicit)
    if [[ ! -d "$RESULTS_ROOT/$TARGET_VERSION" ]]; then
      echo "verify-multi-cc-results: requested version dir does not exist: $RESULTS_ROOT/$TARGET_VERSION" >&2
      exit 2
    fi
    GLOBAL_FAILS=$(validate_dir "$TARGET_VERSION")
    ;;
  all)
    shopt -s nullglob
    found_any=0
    for verdir in "$RESULTS_ROOT"/*/; do
      [[ -d "$verdir" ]] || continue
      ver=$(basename "$verdir")
      found_any=1
      echo "verify-multi-cc-results: scanning $ver" >&2
      rc=$(validate_dir "$ver")
      if (( rc > 0 )); then
        GLOBAL_FAILS=$((GLOBAL_FAILS + rc))
        echo "verify-multi-cc-results: $ver failed ($rc assertion(s))" >&2
      fi
    done
    shopt -u nullglob
    if (( found_any == 0 )); then
      echo "verify-multi-cc-results: no <cc-version>/ subdirs under $RESULTS_ROOT" >&2
      exit 0
    fi
    ;;
esac

if (( GLOBAL_FAILS > 0 )); then
  echo "verify-multi-cc-results: $GLOBAL_FAILS assertion failure(s)" >&2
  exit 1
fi
exit 0
