#!/usr/bin/env bash
# scripts/install-plugin.sh — idempotent fresh-install/post-recovery entry for the dhx plugin.
#
# Composes with the ~/.bashrc inline heal block (D-01; docs/decisions.md 2026-04-17 row).
# The bashrc heal stays as the hot path (~5ms savings per shell `claude` invocation);
# this script is the canonical fresh-install entry. Both share one jq predicate at 4 sites:
#   1. ~/.bashrc:261
#   2. dhx/dhx-health-check.sh:106
#   3. tests/probes/probe-plugin-keys.sh:17
#   4. THIS FILE
# probe-bashrc-wrapper-heal.sh asserts byte-identical parity (D-15).
#
# Detection cascade is two-file (D-22):
#   sf  = "$inst/settings.json"                  (canonical JQ_PRED check)
#   kmf = "$inst/plugins/known_marketplaces.json" (dhx-local key existence check)
# Both must pass for `installed`; either-side mismatch → `partial-install`.
# Empirically validated 2026-05-01: file mtimes show non-atomic two-file writes.
#
# --check mode exit semantics (D-23):
#   0 = installed-and-correct (BOTH sf and kmf pass for every primary instance)
#   1 = missing-or-corrupt OR partial-install OR corrupt-JSON
#   2 = NEVER in --check mode
# install-mode exit semantics:
#   0 = success/skip
#   2 = install command failed OR corrupt-JSON refusal
#
# `.ccburn*` profiles are CCS-burn transient testing instances, deliberately
# excluded (D-25 SCRIPT-02 amendment — see docs/scripts-reference.md
# install-plugin.sh "Known assumptions" + docs/decisions.md 2026-05-01 row).
#
# `set -euo pipefail`: per the install-git-hooks.sh precedent. The
# per-instance loop relies on `if`/`||` guards around jq -e so the expected
# "predicate-false" exit-1 doesn't terminate the script — bash `-e` ignores
# non-zero exits inside `if`-conditions, `&&`-chains, and `||`-fallbacks.
set -euo pipefail

EXPECTED_REPO="/home/dhx/repos/hooks"

# --- Refusal block (D-06) — mirrors install-git-hooks.sh:19-28 ---
# Resolve the canonical hooks repo via git-common-dir so worktrees under
# .claude/worktrees/ resolve to the main checkout (not the worktree path).
# git rev-parse --git-common-dir returns the main repo's .git for both the
# main checkout and any of its worktrees. Its parent IS the canonical repo.
if ! GIT_COMMON_DIR=$(git rev-parse --git-common-dir 2>/dev/null); then
  echo "install-plugin: not in a git repository — expected hooks repo at $EXPECTED_REPO" >&2
  exit 1
fi
GIT_TOPLEVEL=$(cd "$(dirname "$GIT_COMMON_DIR")" && pwd)
cd "$GIT_TOPLEVEL"
toplevel_real=$(realpath "$GIT_TOPLEVEL" 2>/dev/null || echo "$GIT_TOPLEVEL")
expected_real=$(realpath "$EXPECTED_REPO" 2>/dev/null || echo "$EXPECTED_REPO")
if [ "$toplevel_real" != "$expected_real" ]; then
  echo "install-plugin: canonical repo resolves to '$toplevel_real' — expected '$expected_real'" >&2
  echo "install-plugin: tried git-common-dir path '$GIT_COMMON_DIR'" >&2
  echo "install-plugin: expected hooks repo at $EXPECTED_REPO with dhx-plugin/.claude-plugin/marketplace.json" >&2
  exit 1
fi
if [ ! -f "dhx-plugin/.claude-plugin/marketplace.json" ]; then
  echo "install-plugin: dhx-plugin/.claude-plugin/marketplace.json not found — refusing to install" >&2
  exit 1
fi

# --- Pre-flight presence sweep (D-20) — mirrors verify-hooks.sh:84-93 ---
missing=()
command -v jq >/dev/null 2>&1 || missing+=("jq")
command -v claude >/dev/null 2>&1 || missing+=("claude (CC CLI)")
if [[ ${#missing[@]} -gt 0 ]]; then
  printf 'install-plugin: missing prerequisites:\n' >&2
  printf '  - %s\n' "${missing[@]}" >&2
  exit 1
fi

# --- Canonical jq predicate (C-1) — byte-identical to bashrc:261, dhx-health-check.sh:106, probe-plugin-keys.sh:17 ---
JQ_PRED='.enabledPlugins["dhx@dhx-local"] == true and (.extraKnownMarketplaces["dhx-local"].source.path // empty) != ""'

# --- Mode dispatch (D-07) ---
MODE="install"
[[ "${1:-}" == "--check" ]] && MODE="check"

overall_rc=0
found_any=0

# --- Per-CCS-instance loop (D-05, D-22 two-file, D-24 inline-glob, D-25 .ccburn* exclusion) ---
# D-24: inline-glob form (NOT array-loop). Matches grep regex `for inst in.*\.ccs/instances` directly.
for inst in "$HOME"/.ccs/instances/*/; do
  [[ -d "$inst" ]] || continue
  found_any=1
  base=$(basename "$inst")
  # D-25 explicit SCRIPT-02 amendment — .ccburn* transient profiles excluded
  if [[ "$base" == .ccburn* ]]; then
    echo "  SKIP  $base (.ccburn* — D-25 amendment)"
    continue
  fi

  # D-22 two-file detection cascade
  kmf="${inst}plugins/known_marketplaces.json"
  sf="${inst}settings.json"

  # Detect file state (corrupt-JSON check first in EITHER file)
  kmf_state="ok"
  sf_state="ok"
  if [[ ! -f "$kmf" ]]; then
    kmf_state="missing"
  elif ! jq empty "$kmf" 2>/dev/null; then
    kmf_state="corrupt"
  fi
  if [[ ! -f "$sf" ]]; then
    sf_state="missing"
  elif ! jq empty "$sf" 2>/dev/null; then
    sf_state="corrupt"
  fi

  # Determine combined state per D-22 cascade
  if [[ "$kmf_state" == "corrupt" || "$sf_state" == "corrupt" ]]; then
    state="corrupt"
  elif [[ "$kmf_state" == "missing" && "$sf_state" == "missing" ]]; then
    state="missing"
  else
    # Both files exist and parse — check predicates
    kmf_has_key=0
    sf_passes=0
    if [[ "$kmf_state" == "ok" ]] && jq -e '.["dhx-local"]' "$kmf" >/dev/null 2>&1; then
      kmf_has_key=1
    fi
    if [[ "$sf_state" == "ok" ]] && jq -e "$JQ_PRED" "$sf" >/dev/null 2>&1; then
      sf_passes=1
    fi
    if [[ "$kmf_has_key" -eq 1 && "$sf_passes" -eq 1 ]]; then
      state="installed"
    elif [[ "$kmf_has_key" -eq 0 && "$sf_passes" -eq 0 ]]; then
      state="needs-install"
    elif [[ "$kmf_has_key" -eq 0 ]]; then
      state="partial-install (kmf side — known_marketplaces.json missing dhx-local)"
    else
      state="partial-install (sf side — settings.json missing canonical JQ_PRED)"
    fi
  fi

  # Dispatch on (MODE:state) — single case statement, grep-friendly literal patterns.
  case "$MODE:$state" in
    check:installed)
      echo "  OK    $base installed-and-correct"
      ;;
    check:missing|check:needs-install)
      # D-23: --check exits 1 for missing/needs-install
      echo "  MISS  $base $state"
      overall_rc=1
      ;;
    check:partial-install*)
      # D-23: partial-install → exit 1 in --check mode
      echo "  PART  $base $state"
      overall_rc=1
      ;;
    check:corrupt)
      overall_rc=1   # D-23: corrupt-JSON in --check mode → exit 1 (NOT 2)
      echo "  CORR  $base corrupt JSON (kmf=$kmf_state sf=$sf_state) — exit 1 per D-23"
      ;;
    install:installed)
      echo "  SKIP  $base already installed"
      ;;
    install:missing|install:needs-install|install:partial-install*)
      # Run BOTH subcommands per D-22 two-file model — claude CLI is idempotent
      if CLAUDE_CONFIG_DIR="$inst" command claude plugin marketplace add "$GIT_TOPLEVEL/dhx-plugin" >/dev/null 2>&1 \
         && CLAUDE_CONFIG_DIR="$inst" command claude plugin enable "dhx@dhx-local" >/dev/null 2>&1; then
        echo "  OK    $base installed (kmf+sf updated)"
      else
        echo "  ERR   $base install failed" >&2
        overall_rc=2
      fi
      ;;
    install:corrupt)
      overall_rc=2   # D-23: install-mode keeps corrupt → exit 2 (refuse, don't clobber)
      echo "  ERR   $base corrupt JSON (kmf=$kmf_state sf=$sf_state) — refusing to clobber" >&2
      ;;
  esac
done

if [[ "$found_any" -eq 0 ]]; then
  echo "install-plugin: no CCS instances under ~/.ccs/instances/" >&2
  exit 1
fi

# --- Drift reminder (SCRIPT-06) — exact wording for grep-test, install-mode only ---
if [[ "$MODE" == "install" ]]; then
  echo
  echo "Run \`git diff config/settings.json\` to verify no drift before commit."
fi

exit $overall_rc
