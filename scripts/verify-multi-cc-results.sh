#!/usr/bin/env bash
# scripts/verify-multi-cc-results.sh — defensive validator for the
# supersession-watchdog cross-version result corpus.
#
# Scans tests/probes/.results/v1.3-multi-cc-ver/<cc-version>/*.json and
# enforces the 6 D-08 assertions from Phase 15 (MULTI-CC-VER):
#   1. .cc_version field equals active CC (or the explicit-version arg).
#   2. .cc_version_match (INFORMATIONAL only as of 2026-05-26 — the probe-internal
#      EXPECTED_CC_VERSIONS allow-list is RETIRED; the field now signals on-disk
#      corpus-membership, NOT a stale-anchor gate). Assertion 2 no longer fails on
#      cc_version_match=false: a NEW corpus cell with a decisive conclusion legitimately
#      carries cc_version_match=false. The has()-guard preserves validation of old
#      on-disk cells that still carry the boolean. See docs/decisions.md row 220 (gate
#      closed) + HP-024 § Corpus advancement.
#   3. .probe_id ∈ the 5-name supersession-watchdog allowlist.
#   4. .conclusion matches the allowed-token regex (D-08 #4) — the shared
#      taxonomy, which since 2026-08-23 admits `skipped` and `ambiguous_*`
#      (both emitted by design; see the ALLOWED_CONCLUSION_RE comment).
#   5. No JSON with a NON-DECISIVE conclusion (skipped / ambiguous / ambiguous_*)
#      is cited in any docs/decisions.md row that contains the literal phrase
#      "Validated stable" (D-08 A1 single-pass per-row grep idiom). Widened from
#      exact `ambiguous` on 2026-08-23 in the same change that admitted the two
#      new tokens — admitting a token to assertion 4 without covering it here
#      would open a hole, not close one.
#   6. Each result file resolves under the expected
#      tests/probes/.results/v1.3-multi-cc-ver/<cc-version>/ path prefix.
#
# Invocation modes (D-24) — exactly ONE argument, or none:
#   bash scripts/verify-multi-cc-results.sh             # active CC (default)
#   bash scripts/verify-multi-cc-results.sh 2.1.140     # explicit version
#   bash scripts/verify-multi-cc-results.sh --all       # every <cc-ver>/ dir
#
# Argv discipline (2026-09-19): the version positional must look like a
# version (`^[0-9]+(\.[0-9]+)+$`); any other `-`-prefixed token is an unknown
# option; a second argument is an error. All three exit 2 with a usage line.
# Before this, `--all --verbose` and `2.1.278 --verbose` silently DROPPED the
# trailing token and exited 0 — a flag-as-positional false clean on the one
# command an adoption run reads as "corpus valid" (cross-repo 2.1.278 adoption
# ledger, D7). A lone `--verbose` was already exit 2 (it was tried as a version
# dir); the D7 row's "exits 0" was that message read without its rc.
#
# Exit codes:
#   0 = all assertions pass (silent on stdout).
#   1 = at least one validation FAIL (per-FAIL line on stderr).
#   2 = usage error (unknown option, extra argument, non-version positional),
#       or explicit-version arg points at a non-existent dir (D-24).
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

# Allowed-token regex for .conclusion (D-08 #4) — the SHARED taxonomy.
# v1_2_work_warranted is a legacy synonym for validated_stable (per
# 15-01-PLAN.md <interfaces> note + v1.2-phase-6 km baseline precedent).
#
# 2026-08-23: `skipped` and `ambiguous_*` ADDED. Both are emitted BY DESIGN by
# all four *-natural-heal probes — `skipped` when no ANTHROPIC_API_KEY is present
# (a deliberate fast clean self-skip) and `ambiguous_pre_state_abnormal` when the
# live pre-state is missing (whose own comment says "write the outcome JSON
# anyway (audit trail)"). Neither had ever been in this set, and the old regex is
# ANCHORED, so `ambiguous` never covered `ambiguous_pre_state_abnormal`. The
# whitelist was the stale surface, not the write: a keyless hand-run therefore
# published a cell this validator refused, which blocked every probe-touching
# commit repo-wide (2026-07-09, and again 2026-08-23).
#
# Keeping the artifacts is deliberate — they record that a run happened and why
# it observed nothing, which suppressing the write would destroy. What they must
# NOT do is masquerade as a verdict: assertion 5 below therefore covers every
# NON-DECISIVE conclusion, so a `skipped` or `ambiguous_*` cell can never be
# cited as "Validated stable".
#
# 2026-09-18: `regression_found_*` ADDED — the first DECISIVE NEGATIVE token in
# this set. Every other decisive token here reports on whether OUR scoped work is
# still warranted; this one reports that a runtime dependency we already shipped
# has BROKEN. Written by Convention-B probes (first: the inverted
# probe-effort-level-stdin-absent.sh, whose non-zero exit reaches run-probes.sh's
# default branch and is counted a FAIL by name). It is deliberately NOT a
# `supersession_found_*` spelling: that family routes to the informational
# "[SUPERSESSION OBSERVED]" counter that is explicitly not a failure, which is
# precisely how a dead premise sat unreported for four months. A regression must
# reach a human. Under Convention A the token is unknown and correctly fail-SAFEs
# to FAIL via the runner's `*)` arm — asserted, not assumed.
#
# Consumers that must stay in step: the producers (tests/probes/probe-*natural-heal.sh,
# tests/probes/probe-effort-level-stdin-absent.sh),
# run-probes.sh's Convention-A routing branch, and this file.
# Companion assertions: tests/probes/probe-conclusion-taxonomy.sh.
ALLOWED_CONCLUSION_RE='^(validated_stable|supersession_found_[a-z_0-9]+|regression_found_[a-z_0-9]+|ambiguous|ambiguous_[a-z_0-9]+|skipped|v1_2_work_warranted)$'

# A conclusion is DECISIVE when the probe actually reached a verdict. Everything
# else (skipped / ambiguous / ambiguous_*) recorded an attempt, not an answer.
is_non_decisive() {
  case "$1" in
    skipped|ambiguous|ambiguous_*) return 0 ;;
    *) return 1 ;;
  esac
}

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

    # NOTE, not an assertion (ruling 2026-09-19, docs/decisions.md): a cell whose
    # cell_outcome is setup_failure is one whose producer could not launch the
    # binary at all (2.1.275: cell1_rc=127, every installed-plugins cell, see
    # binary_attribution=no_producing_binary). It stays under `ambiguous` — the
    # two provenance fields already say "not measured, and why" — and it is
    # PRINTED, never refused: the cell is the audit trail that a run happened
    # and could not launch, which a refusal would only push someone to delete.
    # Assertion 5 already stops it being cited as stable. Deliberately not the
    # "(in <file>)" suffix, which run-probes.sh parses as a finding.
    if [[ "$(jq -r '.observations.cell_outcome // .cell_outcome // empty' "$f" 2>/dev/null)" == "setup_failure" ]]; then
      echo "verify-multi-cc-results: NOTE $cc cell $(basename "$f" .json) is setup_failure — no producing binary; not a measurement, not a failure: $f" >&2
    fi

    # Assertion 2 (LOOSENED 2026-05-26 — allow-list RETIRED): cc_version_match is now
    # an INFORMATIONAL corpus-membership signal, NOT a stale-anchor gate. A NEW corpus
    # cell with a decisive (non-ambiguous) conclusion legitimately carries
    # cc_version_match=false, so we NO LONGER fail on cc_version_match=false. The only
    # surviving check is shape: if the field is present it must not be null/empty (old
    # on-disk cells still carry the boolean; the has()-guard skips cells that drop it).
    # Note: do NOT use `// empty` here — boolean `false` is falsy in jq's //
    # operator, so we use a `has(...) | <bool>|tostring` form to preserve the
    # literal "false" string.
    if jq -e 'has("cc_version_match")' "$f" >/dev/null 2>&1; then
      match=$(jq -r 'if has("cc_version_match") then (.cc_version_match | tostring) else "" end' "$f" 2>/dev/null)
      if [[ -z "${match:-}" ]]; then
        echo "verify-multi-cc-results: cc_version_match present but null (in $f)" >&2
        fails=$((fails+1))
      fi
      # cc_version_match=false is admissible for any conclusion (informational, non-gating).
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
    if is_non_decisive "$conc" && [[ -n "${pid:-}" ]] && [[ -f "$REPO/docs/decisions.md" ]]; then
      # Order-independent same-line match: the row must reference BOTH this
      # cell's version-scoped path AND the "Validated stable" verdict (grep the
      # path first, then re-grep that row for the verdict — robust to whichever
      # table column each token lands in).
      # grep -F (IN-03): the cell path is a literal substring, not a regex. -F
      # treats ERE metacharacters in the operator-supplied $cc (and $pid) as
      # literal, so a version like '2.1.*' cannot over-match decisions.md rows.
      if grep -F "v1.3-multi-cc-ver/${cc}/${pid}" "$REPO/docs/decisions.md" 2>/dev/null \
           | grep -F "Validated stable" >/dev/null 2>&1; then
        echo "verify-multi-cc-results: $pid (cc $cc) has NON-DECISIVE conclusion '$conc' but its $cc cell is cited in a 'Validated stable' row of docs/decisions.md (in $f)" >&2
        fails=$((fails+1))
      fi
    fi
  done
  shopt -u nullglob

  printf '%s\n' "$fails"
}

# --- Arg parsing (D-24) ---
# One argument or none. Anything the case below does not name is a usage error,
# never a version dir — the "<dir> does not exist" branch is for a real version
# that has no cells, not for a mistyped flag.
usage_error() {
  echo "verify-multi-cc-results: $1" >&2
  echo "usage: $(basename "$0") [<cc-version>|--all|-h]" >&2
  exit 2
}
if (( $# > 1 )); then
  usage_error "unexpected extra argument(s): ${*:2} (one argument or none)"
fi
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
    sed -n '2,46p' "$0"
    exit 0
    ;;
  -*)
    usage_error "unknown option: $1"
    ;;
  *)
    if [[ ! "$1" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
      usage_error "version positional must look like N.N.N, got: $1"
    fi
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
