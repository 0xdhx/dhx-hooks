#!/bin/bash
# probe-installed-plugins-badjson-natural-heal.sh
#
# SAFE_FOR_LIVE: no   (sandbox-only via CLAUDE_CONFIG_DIR isolation; runs claude subprocess)
# RUNTIME: ~30s
# SUITE_TIMEOUT: 120  (one 30s-bounded claude child plus sandbox setup; the suite
#                      default of 30 leaves no headroom above the child's own bound)
#
# Supersession-watchdog probe (Phase 6 D-07a). Asserts the negative premise that
# CC's Hn() resolver does NOT auto-rehydrate `installed_plugins.json` after a
# BADJSON corruption (single canonical truncated shape per D-17).
#   exit 0 = premise holds (BADJSON branch warranted; surgical-slim retain per D-16)
#   exit 1 = upstream supersession found (BADJSON branch retired safely; D-15 gate PASS)
#   exit 2 = ambiguous (auth gap, sandbox isolation failure, confounded outcome,
#            failure-class detected per cell stderr inspection,
#            pre-state abnormal — live $LIVE_IP missing).
#            NOTE: a live `claude --version` absent from any hardcoded list NO
#            LONGER forces ambiguous — the cc-version allow-list is
#            RETIRED (see header "ALLOW-LIST RETIRED" note); conclusion/confidence
#            derive from the substantive observation (.observations.cell_outcome).
#
# Operates on LIVE plugin cache content (which may lag repo source until
# next plugin install/reload); supersession-watchdog reads live state by
# design — RESEARCH MEDIUM-4 cache-vs-source asymmetry is correct behavior.
#
# Backs:
#   - .planning/REQUIREMENTS.md HEAL-07 (D-15 gate consumer)
#   - docs/hook-patterns.md HP-025 (natural-heal asymmetry — Phase 6 doctrine correction)
#   - .planning/phases/06-*/06-CONTEXT.md D-07a + D-17 + D-22 (cc_version assertion)
#
# Run: ANTHROPIC_API_KEY=sk-ant-... bash tests/probes/probe-installed-plugins-badjson-natural-heal.sh [--binary PATH]
#
# BINARY (2026-09-18): ONE binary, resolved ONCE before any cell runs, used for
# BOTH the measurement AND the cell's release label. `--binary`, else the
# canonical target of ~/.local/bin/claude. Rationale, the no-fallback rule and
# why this deliberately does NOT prefer $CLAUDE_CODE_EXECPATH:
# tests/probes/lib/resolve-cc-binary.sh. Bare `claude` is never invoked — it is
# ~/.local/capbin/claude (claude-capped.sh), which re-resolves the real binary
# through $HOME, and this probe SWAPS $HOME, so the cell exited 127 and measured
# nothing (corpus: 2.1.275, cell1_rc=127).
#
# AUTH (2026-05-24 watchdog-probe auth hardening — generalized from the read-guard
# native-enforcement tripwire): a sandboxed `claude -p` (fresh CLAUDE_CONFIG_DIR) is
# logged out unless ANTHROPIC_API_KEY is inherited from env. Seeding a live
# ~/.claude/.credentials.json into the sandbox is UNSAFE — the sandboxed claude rotates
# the OAuth refresh token and writes the new one to the throwaway dir, so the provider
# invalidates the SOURCE credential (measured: a copied cred authed once then 401'd
# minutes later). So this probe gates on ANTHROPIC_API_KEY ONLY; no key → fast clean
# `skipped` (exit 2, never a false `v1_2_work_warranted`). The strengthened auth-failure
# regex in classify_failure() ensures a logged-out / invalid-key / credit-exhausted
# subprocess degrades to ambiguous, never rolls up to a positive conclusion (false-PASS
# guard). See docs/decisions.md 2026-05-24 watchdog-probe-auth-hardening row.
#
# D-25 set-flag discipline (WR-04 corrected): file top is `set -uo pipefail`
# only — `errexit` is NEVER enabled. The original draft sprinkled `set +e`
# around every subprocess; those calls were no-ops (you can't disable a flag
# that was never on) and have been removed. The actual safety mechanism is
# `rc=$?` immediately after each subprocess call: that captures the exit
# code regardless of `errexit`, so an early jq/stat exit-1 cannot abort
# before the ambiguous outcome JSON is written.
#
# ALLOW-LIST RETIRED (2026-05-26 — HP-024 matrix promotion EXECUTED; decisions
# row 220 retirement gate CLOSED). The former D-22 cc-version allow-list
# (`("2.1.121" "2.1.140" "2.1.145")`) was temporary scaffolding ("friction deliberate,
# retires at N≥3" — decisions row 220). The N≥3 gate is MET (2.1.121 / 2.1.140 / 2.1.148)
# and the promotion is now EXECUTED: the per-(cc_version) result cells under
# `tests/probes/.results/v1.3-multi-cc-ver/<ver>/` (+ the v1.2-phase-6 baseline) are THE
# source of truth for conclusion/confidence — NOT membership in a hardcoded version array.
# conclusion/confidence now derive from `.observations.cell_outcome` (the substantive
# subprocess observation). A never-before-seen CC version records a clean NEW cell, never
# a false-ambiguous (this eliminated the audit-misleading signal that cost the 2026-05-25
# plugin-registry-heal re-eval — see decisions rows 220 + 237 + HP-024 § Corpus advancement).
# `cc_version_match` is REPURPOSED to a non-gating informational signal: "is this CC version
# already represented in the on-disk corpus" (true = a cell dir already exists; false = this
# run is a NEW cell). It NEVER rewrites conclusion or downgrades confidence.
#
# CC-STDERR: filtered
#   This probe drives a real `claude -p` child and classifies its `2>&1` capture,
#   so Claude Code's settings lint is an INPUT to the classifier. The capture is
#   routed through strip_cc_config_advisories() before any regex touches it, and
#   the dropped-line count is printed so a cleaned noisy cell is distinguishable
#   from a genuinely clean one. Rationale: lib/cc-cell-stderr.sh.
#   Convention: tests/probes/README.md § "A classifier's INPUT is a surface too".
#

set -uo pipefail

PROBE_ID="probe-installed-plugins-badjson-natural-heal"

# ----------------------------------------------------------------------------
# Binary resolution (2026-09-18) — ONE binary for the measurement AND the label.
#
# Runs FIRST, before mktemp and before the auth gate: a refusal here has nothing
# to clean up and, critically, publishes NOTHING. The corpus keeps one fixed
# filename per release directory, so writing a non-observation into that slot
# destroys whatever observation held it.
#
# NO FALLBACK to bare `claude` (the d39ba983 rule): a version read from one
# binary is not evidence about an observation produced by another.
# ----------------------------------------------------------------------------
# shellcheck source=lib/resolve-cc-binary.sh
source "$(dirname "$0")/lib/resolve-cc-binary.sh"
# shellcheck source=lib/cc-cell-stderr.sh
source "$(dirname "$0")/lib/cc-cell-stderr.sh"

BIN_ARG=""
while (( $# )); do
  case "$1" in
    --binary)
      (( $# >= 2 )) || { echo "$PROBE_ID: --binary needs a value" >&2; exit 2; }
      BIN_ARG=$2; shift 2 ;;
    *) echo "$PROBE_ID: unknown argument: $1" >&2; exit 2 ;;
  esac
done

BIN=$(resolve_cc_binary "$BIN_ARG") || BIN=""
CC_VERSION=""
[[ -n "$BIN" ]] && { CC_VERSION=$(resolve_cc_version "$BIN") || CC_VERSION=""; }

if [[ -z "$BIN" || ! -x "$BIN" ]] || ! cc_version_is_sane "$CC_VERSION"; then
  echo "FAIL binary: no runnable Claude Code binary resolved (bin='${BIN:-}' version='${CC_VERSION:-}')"
  echo "     refusing WITHOUT publishing a cell — a borrowed label is not evidence"
  echo "---"
  echo "PASS: 0  FAIL: 1  cell_outcome=binary_unresolved  conclusion=ambiguous  exit_code=2"
  exit 2
fi
echo "INFO binary: CC $CC_VERSION ($BIN)"

# ----------------------------------------------------------------------------
# State (D-22 per-cell rc + failure-class enums; D-23 per-cell auth_method;
# D-24 early pre-state gate; default to ambiguous so any short-circuit path
# still produces a deterministic exit code).
# ----------------------------------------------------------------------------
PASS=0
FAIL=0
exit_code=2                              # default ambiguous; set deterministically post-cell-attribution
conclusion="ambiguous"
cell_outcome="bizarre"
cell1_rc=-1
cell1_auth_method=""

# cc_version_match: informational corpus-membership signal (allow-list RETIRED
# 2026-05-26 — non-gating). confidence defaults LOW; set HIGH at cell-attribution
# when the substantive cell produces a decisive (non-skip, non-failure) outcome.
cc_version_match=false
confidence="LOW"

# Observation defaults (used by JSON write block; refined as cells run)
pre_size=0
post_size=0
json_validity_post=false
dhx_entry_present_post=false
install_path_resolves_to_expected_cache_layout=false
inode_isolated=false
cell1_stderr=""

# ----------------------------------------------------------------------------
# Sandbox setup
# ----------------------------------------------------------------------------
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
SANDBOX="$TMPROOT/cfg"
mkdir -p "$SANDBOX/plugins" "$TMPROOT/cwd"

# launch_cell [extra-flag...] — the ONLY site that spawns Claude Code.
#
# env -i, matching probe-known-marketplaces-natural-heal.sh: HOME and
# CLAUDE_CONFIG_DIR alone are NOT isolation. The parent session exports ~15
# CLAUDE_CODE_* variables — including CLAUDE_CODE_PROCESS_WRAPPER and a live
# messaging socket + token — which a directly-invoked binary would inherit into
# the sandbox. ANTHROPIC_API_KEY is allowlisted back in because, unlike the
# marketplaces probe, this cell must authenticate. Verified 2026-09-18: this
# exact env authenticates and completes a `-p` (rc 0).
# A neutral cwd keeps project-local .claude config out of the cell.
launch_cell() {
  ( cd "$TMPROOT/cwd" && env -i PATH=/usr/bin:/bin TERM=dumb \
      HOME="$TMPROOT" CLAUDE_CONFIG_DIR="$SANDBOX" \
      ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
      timeout 30 "$BIN" "$@" </dev/null 2>&1 >/dev/null )
}

LIVE_CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"   # CCS-aware per CLAUDE.md
LIVE_IP="$LIVE_CFG/plugins/installed_plugins.json"

# ----------------------------------------------------------------------------
# Auth gate (2026-05-24 watchdog-probe auth hardening): ANTHROPIC_API_KEY ONLY.
# OAuth credentials_file seeding REMOVED — copying a live ~/.claude/.credentials.json
# into the sandbox is UNSAFE (the sandboxed claude -p rotates the refresh token and
# invalidates the SOURCE credential; see header AUTH note + decisions.md). No key →
# fast clean `skipped` (exit 2 / ambiguous family — never a false work_warranted),
# BEFORE any cp -rL or subprocess spawn. Replaces the prior "credentials_file OR
# ANTHROPIC_API_KEY" Cell-1 contract.
# ----------------------------------------------------------------------------
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "SKIP probe-installed-plugins-badjson-natural-heal: no ANTHROPIC_API_KEY (a sandboxed claude -p cannot auth via OAuth credentials_file safely — re-run with an API key)"
  cell_outcome="skipped_no_api_key"
  conclusion="skipped"
  exit_code=2
  cell1_auth_method="none"
  SKIP_CELLS=true
else
  cell1_auth_method="ANTHROPIC_API_KEY"
  SKIP_CELLS=false
fi

# ----------------------------------------------------------------------------
# D-24 early pre-state gate: assert LIVE_IP exists BEFORE cp -rL.
# Pre-state abnormal is meaningfully different from supersession-or-no-supersession;
# treat as ambiguous and write the outcome JSON anyway (audit trail).
# ----------------------------------------------------------------------------
if [[ "$SKIP_CELLS" == "false" ]] && [[ ! -f "$LIVE_IP" ]]; then
  echo "FAIL pre-state-abnormal: live $LIVE_IP missing — cannot evaluate Hn() heal behavior"
  cell_outcome="ambiguous_pre_state_abnormal"
  conclusion="ambiguous_pre_state_abnormal"
  exit_code=2
  FAIL=$((FAIL+1))
  cell1_auth_method="unknown"
  SKIP_CELLS=true
fi

# ----------------------------------------------------------------------------
# cp -rL deref of plugin state (RESEARCH MEDIUM-4: live cache may be stale;
# that's correct supersession-watchdog behavior — reads live cache as-of-run-time)
# D-25 (WR-04): cp_rc=$? captures rc directly; errexit never enabled.
# ----------------------------------------------------------------------------
if [[ "$SKIP_CELLS" == "false" ]]; then
  cp -rL "$LIVE_CFG/plugins/." "$SANDBOX/plugins/"
  cp_rc=$?
  if [[ "$cp_rc" -ne 0 ]]; then
    echo "FATAL: cp -rL failed (rc=$cp_rc) — cannot construct sandbox"
    cell_outcome="setup_failure"
    conclusion="ambiguous"
    exit_code=2
    FAIL=$((FAIL+1))
    SKIP_CELLS=true
  fi
fi

# ----------------------------------------------------------------------------
# Auth (D-23 per-cell auth_method): ANTHROPIC_API_KEY only — decided up front by the
# auth gate above (no key → skipped before this point). Cell 1 (default -p) authenticates
# via the inherited env key. The unsafe OAuth credentials_file seeding was removed
# 2026-05-24 (see header AUTH note); only the non-credential settings.json is copied
# into the sandbox. (Cell 2 / --bare was already DROPPED per Pattern A note 3 — D-07a
# is Cell 1 only.)
# ----------------------------------------------------------------------------
if [[ "$SKIP_CELLS" == "false" ]] && [[ -f "$LIVE_CFG/settings.json" ]]; then
  cp "$(readlink -f "$LIVE_CFG/settings.json")" "$SANDBOX/settings.json"
fi

# ----------------------------------------------------------------------------
# Suppress dhx SessionStart in sandbox plugin manifest — JQ PATH CORRECTION
# (RESEARCH MEDIUM-1 / PATTERNS landmine #1).
#
# CONTEXT.md D-03 line 68 had the wrong jq path (top-level .SessionStart) —
# that's a no-op against the actual {"hooks": {"SessionStart": [...]}} structure.
# The correct expression is `del(.hooks.SessionStart)`. Post-jq assertion
# confirms .hooks.SessionStart is absent.
# ----------------------------------------------------------------------------
if [[ "$SKIP_CELLS" == "false" ]]; then
  HOOKS_JSON="$SANDBOX/plugins/cache/dhx-local/dhx/0.1.0/hooks/hooks.json"
  if [[ -f "$HOOKS_JSON" ]]; then
    jq 'del(.hooks.SessionStart)' "$HOOKS_JSON" > "$TMPROOT/hooks.tmp" \
      && mv "$TMPROOT/hooks.tmp" "$HOOKS_JSON"
    jq_rc=$?

    if [[ "$jq_rc" -ne 0 ]]; then
      echo "FATAL: jq mutation failed (rc=$jq_rc)"
      cell_outcome="setup_failure"
      conclusion="ambiguous"
      exit_code=2
      FAIL=$((FAIL+1))
      SKIP_CELLS=true
    else
      # Acceptance assertion — verify the mutation actually removed SessionStart
      # (RESEARCH MEDIUM-1 acceptance criterion):
      jq -e '.hooks | has("SessionStart")' "$HOOKS_JSON" >/dev/null 2>&1
      still_present_rc=$?
      if [[ "$still_present_rc" -eq 0 ]]; then
        echo "FATAL: post-jq SessionStart still present at .hooks.SessionStart — jq path mutation failed"
        cell_outcome="setup_failure"
        conclusion="ambiguous"
        exit_code=2
        FAIL=$((FAIL+1))
        SKIP_CELLS=true
      else
        remaining=$(jq -r '.hooks | keys | length' "$HOOKS_JSON" 2>/dev/null || echo "?")
        echo "OK   hooks-jq-suppression: $remaining event keys remain (SessionStart removed)"
        PASS=$((PASS+1))
      fi
    fi
  else
    echo "NOTE: $HOOKS_JSON absent in sandbox — dhx plugin not in cache, suppression no-op"
  fi
fi

# ----------------------------------------------------------------------------
# Inode-isolation assertion — D-03 spike-derived guard (novel-in-repo).
# From the 2026-04-27 corruption incident: hardlink/symlink chain can route
# truncate to LIVE file. Fail loud rather than corrupt production state.
# ----------------------------------------------------------------------------
SANDBOX_IP="$SANDBOX/plugins/installed_plugins.json"
if [[ "$SKIP_CELLS" == "false" ]]; then
  if [[ ! -f "$SANDBOX_IP" ]]; then
    echo "FATAL: sandbox installed_plugins.json missing post cp -rL"
    cell_outcome="setup_failure"
    conclusion="ambiguous"
    exit_code=2
    FAIL=$((FAIL+1))
    SKIP_CELLS=true
  else
    sandbox_inode=$(stat -c %i "$SANDBOX_IP" 2>/dev/null)
    live_inode=$(stat -c %i "$LIVE_IP" 2>/dev/null || echo "MISSING")
    if [[ "$sandbox_inode" == "$live_inode" ]]; then
      echo "FATAL: inode collision (sandbox=$sandbox_inode live=$live_inode) — sandbox not isolated; ABORT before truncate"
      cell_outcome="setup_failure"
      conclusion="ambiguous"
      exit_code=2
      FAIL=$((FAIL+1))
      SKIP_CELLS=true
    else
      inode_isolated=true
      echo "OK   inode-isolation: sandbox=$sandbox_inode != live=$live_inode"
      PASS=$((PASS+1))

      # Capture pre-state size for outcome JSON
      pre_size=$(stat -c %s "$SANDBOX_IP" 2>/dev/null || echo 0)
    fi
  fi
fi

# ----------------------------------------------------------------------------
# Cell 1: positive cell — default `claude -p` (D-07a — full plugin sync runs).
# BADJSON fixture per D-17 (single canonical truncated shape; Hn() rehydration
# is shape-agnostic from resolver's POV).
# ----------------------------------------------------------------------------
if [[ "$SKIP_CELLS" == "false" ]]; then
  # D-17: single canonical truncated shape (Hn() rehydration is shape-agnostic from resolver's POV).
  printf '%s' '{"version": 2, "plug' > "$SANDBOX_IP"   # truncated/malformed JSON
  pre_size_cell1=$(stat -c %s "$SANDBOX_IP" 2>/dev/null || echo 0)
  pre_size="$pre_size_cell1"   # WR-01: pre_size in JSON reflects actual pre-Hn() state
                               # (post-fixture write), NOT the cp'd-live snapshot.
  echo "Cell 1 (default -p): wrote BADJSON fixture ($pre_size_cell1 bytes); invoking claude -p (auth: $cell1_auth_method)"
  cell1_stderr=$(launch_cell -p "noop")
  cell1_rc=$?
  post_size=$(stat -c %s "$SANDBOX_IP" 2>/dev/null || echo 0)

  # Validate post-state JSON shape if non-zero
  if [[ "$post_size" -gt 0 ]] && jq -e . "$SANDBOX_IP" >/dev/null 2>&1; then
    json_validity_post=true
    if jq -e '.plugins["dhx@dhx-local"]' "$SANDBOX_IP" >/dev/null 2>&1; then
      dhx_entry_present_post=true
      # Boolean check only — no path leakage to outcome JSON (D-08 sanitization)
      installPath=$(jq -r '.plugins["dhx@dhx-local"].installPath // empty' "$SANDBOX_IP" 2>/dev/null)
      if [[ -n "$installPath" ]] && grep -q "plugins/cache/dhx-local/dhx" <<<"$installPath"; then
        install_path_resolves_to_expected_cache_layout=true
      fi
    fi
  fi
  echo "Cell 1 result: post_size=$post_size json_valid=$json_validity_post dhx_entry=$dhx_entry_present_post rc=$cell1_rc"
fi

# ----------------------------------------------------------------------------
# Cell-outcome attribution + Convention A exit code (Discretion #4 enums).
#
# D-22 failure-class detection (priority over heal-detection): inspect cell
# stderr/rc; any failure-class signal → ambiguous outcome.
# ----------------------------------------------------------------------------
classify_failure() {
  local rc="$1" stderr="$2"
  # 2026-09-18: strip Claude Code's advisories ABOUT THE COPIED CONFIG before
  # pattern-matching. These probes hand the cell the operator's live
  # settings.json for fidelity, and CC lints it and quotes each questionable
  # rule verbatim — so this host's `Bash(timeout * gh *)` put the word
  # "timeout" in every cell's stderr and classified every rc=0 run as
  # `timeout_124`. Measured 3/3 the moment the single-binary fix revived these
  # live arms. The same exposure forges auth_failure and network_failure.
  # Rationale and exactly what is dropped: lib/cc-cell-stderr.sh.
  stderr=$(strip_cc_config_advisories "$stderr")
  if [[ "$rc" -eq 124 ]] || grep -qiE 'timeout|deadline' <<<"$stderr"; then
    echo "timeout_124"; return
  fi
  # Auth-failure regex broadened 2026-05-24 to mirror the read-guard tripwire's
  # AUTH_FAIL_RE — the narrow original ('401|403|unauthorized|invalid api key|
  # authentication') missed "Not logged in", "Failed to authenticate", credit
  # exhaustion, OAuth expiry, and "invalid x-api-key", any of which (on an exit-0
  # subprocess) could slip past to a false v1_2_work_warranted. False-PASS guard.
  if grep -qiE '401|403|unauthorized|not logged in|please run /login|invalid (x-)?api[- ]?key|authentication|failed to authenticate|credit balance is too low|oauth token has expired' <<<"$stderr"; then
    echo "auth_failure"; return
  fi
  if grep -qiE 'network|connection|ENETUNREACH|ECONNREFUSED|EAI_' <<<"$stderr"; then
    echo "network_failure"; return
  fi
  if [[ "$rc" -ne 0 ]]; then
    echo "setup_failure"; return
  fi
  echo "clean"
}

if [[ "$SKIP_CELLS" == "false" ]]; then
  cell1_class=$(classify_failure "$cell1_rc" "$cell1_stderr")
  echo "INFO cell1 stderr: $(count_cc_config_advisories "$cell1_stderr") config-advisory line(s) dropped before classification (lib/cc-cell-stderr.sh)"

  if [[ "$cell1_class" != "clean" ]]; then
    # Failure-class outcome (auth_failure / timeout_124 / network_failure /
    # setup_failure): genuinely indeterminate → confidence LOW (NOT version-miss).
    cell_outcome="$cell1_class"; conclusion="ambiguous"; exit_code=2; confidence="LOW"
    echo "FAIL cell-attribution: Cell 1 $cell1_class (rc=$cell1_rc) — investigation required"
    FAIL=$((FAIL+1))
  elif [[ "$json_validity_post" == "true" && "$dhx_entry_present_post" == "true" ]]; then
    # Decisive substantive outcome → confidence HIGH (cell_outcome is the source of truth).
    cell_outcome="badjson_hn_heals"; conclusion="supersession_found_drop_heal"; exit_code=1; confidence="HIGH"
    echo "OK   cell-attribution: badjson_hn_heals — Hn() rehydrated BADJSON; retire BADJSON branch"
    PASS=$((PASS+1))
  else
    # Decisive substantive outcome → confidence HIGH (cell_outcome is the source of truth).
    cell_outcome="badjson_no_heal"; conclusion="v1_2_work_warranted"; exit_code=0; confidence="HIGH"
    echo "OK   cell-attribution: badjson_no_heal — HP-025 holds for BADJSON; surgical-slim retain"
    PASS=$((PASS+1))
  fi
fi

# ----------------------------------------------------------------------------
# cc_version_match — INFORMATIONAL corpus-membership signal (allow-list RETIRED
# 2026-05-26; non-gating). true iff this CC version already has an on-disk result
# cell (v1.3-multi-cc-ver/<ver>/ OR the v1.2-phase-6 baseline); false = NEW cell.
# CRITICAL: this NEVER rewrites conclusion or downgrades confidence — those are
# owned solely by the cell-outcome attribution above. A never-before-seen CC version
# records a clean NEW cell, not a false-ambiguous (the audit-misleading signal that
# decisions row 237 documents is hereby eliminated). Resolved the same way OUT_DIR
# resolves REPO_ROOT below; a missing corpus dir yields false, never an error.
# ----------------------------------------------------------------------------
# 2026-09-18: this block used to read `claude --version` a SECOND time,
# independently of the read that labelled the cell. That is a sharper form of
# the same defect — the two LABEL reads could disagree with each other, not just
# with the measurement — so both now derive from the one resolved binary.
cc_version_full="$CC_VERSION"
cc_version_now="$CC_VERSION"
CORPUS_REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "$(cd "$(dirname "$0")/../.." && pwd)")
CORPUS_RESULTS="$CORPUS_REPO_ROOT/tests/probes/.results"
cc_version_match=false
if [[ -n "$cc_version_now" ]] \
   && { [[ -d "$CORPUS_RESULTS/v1.3-multi-cc-ver/$cc_version_now" ]] || [[ -d "$CORPUS_RESULTS/v1.2-phase-6" && "$cc_version_now" == "2.1.121" ]]; }; then
  cc_version_match=true
fi
echo "INFO cc_version_match (informational, non-gating): live='$cc_version_full' corpus-member=$cc_version_match (allow-list RETIRED — conclusion/confidence derive from cell_outcome=$cell_outcome)"

# ----------------------------------------------------------------------------
# Outcome JSON write (D-08 schema + sanitization; RESEARCH HIGH-1 live cc_version;
# D-22 cell{N}_rc; D-23 per-cell auth_method; D-30 hostname-hash).
# ----------------------------------------------------------------------------
# CC_VERSION is NOT re-read here. It was resolved once at the top from the SAME
# binary "$BIN" that produced the observation above, and there is no "unknown"
# fallback: an unresolvable version refused before any cell ran. Re-reading it
# here is the defect this probe was fixed for — between the measurement and this
# line sits a 30s-bounded subprocess, and the auto-updater rewrites
# ~/.local/bin/claude underneath a PATH lookup.
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RUN_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || date +%s%N)
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "$(cd "$(dirname "$0")/../.." && pwd)")
# CC-keyed corpus path (quick-260526-10r) — never writes to the frozen v1.2 baseline; validator scans this dir
OUT_DIR="$REPO_ROOT/tests/probes/.results/v1.3-multi-cc-ver/$CC_VERSION"
OUT_FILE="$OUT_DIR/probe-installed-plugins-badjson-natural-heal.json"

# ----------------------------------------------------------------------------
# Non-observation must never evict an observation (2026-09-18).
#
# The corpus holds ONE fixed filename per release directory, so a write is a
# REPLACEMENT, not an append. A run that measured nothing — no API key, a
# pre-state gate refusal — still reached this block and overwrote the release's
# only cell with `skipped_no_api_key`, destroying a real verdict and leaving
# nothing on disk to say a real verdict had ever been there.
#
# D-24's audit-trail intent is preserved: a non-observation still publishes into
# an EMPTY slot, which is where an audit trail is useful and costs nothing. It
# is only the eviction of an existing cell that is refused.
# ----------------------------------------------------------------------------
if [[ "$SKIP_CELLS" == "true" && -f "$OUT_FILE" ]]; then
  echo "FAIL publish-guard: no cell ran ($cell_outcome) and $CC_VERSION already holds an observation"
  echo "     refusing to overwrite $OUT_FILE — re-run with an API key to replace it"
  echo "---"
  echo "PASS: $PASS  FAIL: $((FAIL+1))  cell_outcome=$cell_outcome  conclusion=$conclusion  exit_code=2"
  exit 2
fi
mkdir -p "$OUT_DIR"

# D-30: published_from_hostname is SHA-256 of `hostname -s`
# (synthetic identifier for cross-machine drift detection; NEVER literal hostname).
HOSTNAME_HASH=$(printf '%s' "$(hostname -s)" | sha256sum | awk '{print $1}')

OBSERVATIONS=$(jq -n \
  --argjson pre "$pre_size" \
  --argjson post "$post_size" \
  --argjson jvp "$json_validity_post" \
  --argjson dxe "$dhx_entry_present_post" \
  --argjson ipr "$install_path_resolves_to_expected_cache_layout" \
  --arg c1auth "$cell1_auth_method" \
  --argjson c1rc "$cell1_rc" \
  --argjson iso "$inode_isolated" \
  --arg outcome "$cell_outcome" \
  --arg published_from_hostname "$HOSTNAME_HASH" \
  '{pre_size:$pre, post_size:$post, json_validity_post:$jvp, dhx_entry_present_post:$dxe, install_path_resolves_to_expected_cache_layout:$ipr, cell1_auth_method:$c1auth, cell1_rc:$c1rc, inode_isolated:$iso, cell_outcome:$outcome, published_from_hostname:$published_from_hostname}')

# JSON-time sanitizer: refuse to write if observations contain /home/, /Users/,
# or system hostname. Defense-in-depth pairs with D-09 sync-public-mirror.sh scrub.
# WR-05: empty $HOST would make the regex `(/home/|/Users/|)` match everything
# (false-positive PII rejection); a hostname with regex specials (`host.local`)
# would also expand to a non-literal match. Sentinel-substitute empty/localhost,
# then escape regex specials before splicing into the alternation.
HOST=$(hostname -s 2>/dev/null)
if [[ -z "$HOST" ]] || [[ "$HOST" == "localhost" ]]; then
  HOST="__no_host_check__"   # sentinel that won't match any real string
fi
HOST_ESCAPED=$(printf '%s' "$HOST" | sed 's/[][\\.*^$/+?(){}|]/\\&/g')
# Herestring, NOT `echo | grep -q`: under this file's `set -o pipefail` a pipe here
# FAILS OPEN. `grep -q` exits at the first complete matching line, `echo` takes
# SIGPIPE, the pipeline goes non-zero, and this refusal is SKIPPED exactly when
# PII is present and the payload is large. See HP-028 and the 2026-09-17
# decisions row; behaviour asserted by tests/probes/probe-pii-gate-fail-open.sh.
if grep -qE "(/home/|/Users/|$HOST_ESCAPED)" <<<"$OBSERVATIONS"; then
  echo "FATAL: observations contain PII; refusing write"
  exit 2
fi

jq -n \
  --arg id "probe-installed-plugins-badjson-natural-heal" \
  --argjson code "$exit_code" \
  --arg cc "$CC_VERSION" \
  --argjson ccm "$cc_version_match" \
  --arg conf "$confidence" \
  --arg ts "$TS" \
  --arg run "$RUN_ID" \
  --argjson obs "$OBSERVATIONS" \
  --arg conc "$conclusion" \
  '{probe_id:$id, exit_code:$code, exit_code_convention:"exit_0_means_v1_2_work_warranted", cc_version:$cc, cc_version_match:$ccm, confidence:$conf, ts:$ts, run_id:$run, observations:$obs, conclusion:$conc}' \
  > "$OUT_FILE.tmp" && mv -f "$OUT_FILE.tmp" "$OUT_FILE"

echo "OK   outcome-json-written: $OUT_FILE"
PASS=$((PASS+1))

# ----------------------------------------------------------------------------
# Summary + exit
# ----------------------------------------------------------------------------
echo "---"
echo "PASS: $PASS  FAIL: $FAIL  cell_outcome=$cell_outcome  conclusion=$conclusion  cc_version_match=$cc_version_match  confidence=$confidence  cell1_rc=$cell1_rc  exit_code=$exit_code"
exit $exit_code
