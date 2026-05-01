#!/bin/bash
# probe-installed-plugins-no-natural-heal.sh
#
# SAFE_FOR_LIVE: no   (sandbox-only via CLAUDE_CONFIG_DIR isolation; runs claude subprocess)
# RUNTIME: ~60s
#
# Supersession-watchdog probe (D-12). Asserts the negative premise that
# CC's Hn() resolver does NOT auto-rehydrate `installed_plugins.json`
# after a 0-byte clobber (HP-025 natural-heal asymmetry).
#   exit 0 = premise holds (heal-hook hardening warranted, ship Phase 6 HEAL as scoped)
#   exit 1 = upstream supersession found (retire heal hook per Phase 6 retire path)
#   exit 2 = ambiguous (auth gap, sandbox isolation failure, confounded outcome,
#            failure-class detected per cell stderr inspection,
#            pre-state abnormal — live $LIVE_IP missing)
#
# Operates on LIVE plugin cache content (which may lag repo source until
# next plugin install/reload); supersession-watchdog reads live state by
# design — RESEARCH MEDIUM-4 cache-vs-source asymmetry is correct behavior.
#
# If exit 1, file a HP-025 update + retire heal hook in Phase 6 plan.
#
# Backs:
#   - .planning/REQUIREMENTS.md PROBE-02
#   - docs/hook-patterns.md HP-025 (natural-heal asymmetry; this probe re-validates)
#   - docs/decisions.md 2026-04-30 supersession-watchdog row
#
# Run: ANTHROPIC_API_KEY=sk-ant-... bash tests/probes/probe-installed-plugins-no-natural-heal.sh
#
# D-25 set-flag discipline: file top is `set -uo pipefail` only; NO mid-script
# set -e re-enable. Targeted `set +e ... rc=$?` blocks gate every subprocess
# call so an early jq/stat exit-1 cannot abort before the ambiguous outcome
# JSON is written.
set -uo pipefail

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
cell2_rc=-1
cell1_auth_method=""
cell2_auth_method="ANTHROPIC_API_KEY"    # D-23: --bare strict-mode invariant (CLI-enforced)

# Observation defaults (used by JSON write block; refined as cells run)
pre_size=0
post_size_default=0
post_size_bare=0
json_validity_default=false
dhx_entry_present_default=false
install_path_resolves_to_expected_cache_layout=false
inode_isolated=false
cell1_stderr=""
cell2_stderr=""

# ----------------------------------------------------------------------------
# Sandbox setup
# ----------------------------------------------------------------------------
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
SANDBOX="$TMPROOT/cfg"
mkdir -p "$SANDBOX/plugins"

LIVE_CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"   # CCS-aware per CLAUDE.md
LIVE_IP="$LIVE_CFG/plugins/installed_plugins.json"

# ----------------------------------------------------------------------------
# D-24 early pre-state gate: assert LIVE_IP exists BEFORE cp -rL.
# Pre-state abnormal is meaningfully different from supersession-or-no-supersession;
# treat as ambiguous and write the outcome JSON anyway (audit trail).
# ----------------------------------------------------------------------------
if [[ ! -f "$LIVE_IP" ]]; then
  echo "FAIL pre-state-abnormal: live $LIVE_IP missing — cannot evaluate Hn() heal behavior"
  cell_outcome="ambiguous_pre_state_abnormal"
  conclusion="ambiguous_pre_state_abnormal"
  exit_code=2
  FAIL=$((FAIL+1))
  cell1_auth_method="unknown"
  SKIP_CELLS=true
else
  SKIP_CELLS=false
fi

# ----------------------------------------------------------------------------
# cp -rL deref of plugin state (RESEARCH MEDIUM-4: live cache may be stale;
# that's correct supersession-watchdog behavior — reads live cache as-of-run-time)
# D-25: targeted set +e block
# ----------------------------------------------------------------------------
if [[ "$SKIP_CELLS" == "false" ]]; then
  set +e
  cp -rL "$LIVE_CFG/plugins/." "$SANDBOX/plugins/"
  cp_rc=$?
  set +e   # remain in targeted-set mode; no set -e re-enable
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
# Auth strategy (D-23 per-cell auth_method; RESEARCH HIGH-3 strict-mode):
#   Cell 1 (default -p)  accepts .credentials.json OR ANTHROPIC_API_KEY
#   Cell 2 (--bare -p)   STRICTLY requires ANTHROPIC_API_KEY (CLI-enforced invariant)
# ----------------------------------------------------------------------------
if [[ "$SKIP_CELLS" == "false" ]]; then
  if [[ -f "$LIVE_CFG/.credentials.json" ]]; then
    set +e
    cp "$(readlink -f "$LIVE_CFG/.credentials.json")" "$SANDBOX/.credentials.json"
    chmod 600 "$SANDBOX/.credentials.json"
    set +e
    cell1_auth_method="credentials_file"
  fi
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    [[ -z "$cell1_auth_method" ]] && cell1_auth_method="ANTHROPIC_API_KEY"
  fi
  if [[ -z "$cell1_auth_method" ]]; then
    echo "FATAL: no auth available for Cell 1 (.credentials.json absent AND ANTHROPIC_API_KEY unset)"
    cell_outcome="auth_failure"
    conclusion="ambiguous"
    exit_code=2
    FAIL=$((FAIL+1))
    SKIP_CELLS=true
  fi

  # Cell 2 hard-requires ANTHROPIC_API_KEY (RESEARCH HIGH-3 / D-23):
  if [[ "$SKIP_CELLS" == "false" ]] && [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    echo "FATAL: Cell 2 requires ANTHROPIC_API_KEY (--bare never reads keychain/credentials); set ANTHROPIC_API_KEY and re-run"
    cell_outcome="auth_failure"
    conclusion="ambiguous"
    exit_code=2
    FAIL=$((FAIL+1))
    SKIP_CELLS=true
  fi

  # Sanitized settings.json copy
  if [[ "$SKIP_CELLS" == "false" ]] && [[ -f "$LIVE_CFG/settings.json" ]]; then
    set +e
    cp "$(readlink -f "$LIVE_CFG/settings.json")" "$SANDBOX/settings.json"
    set +e
  fi
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
    set +e
    jq 'del(.hooks.SessionStart)' "$HOOKS_JSON" > "$TMPROOT/hooks.tmp" \
      && mv "$TMPROOT/hooks.tmp" "$HOOKS_JSON"
    jq_rc=$?
    set +e

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
      set +e
      jq -e '.hooks | has("SessionStart")' "$HOOKS_JSON" >/dev/null 2>&1
      still_present_rc=$?
      set +e
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
    set +e
    sandbox_inode=$(stat -c %i "$SANDBOX_IP" 2>/dev/null)
    live_inode=$(stat -c %i "$LIVE_IP" 2>/dev/null || echo "MISSING")
    set +e
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
      set +e
      pre_size=$(stat -c %s "$SANDBOX_IP" 2>/dev/null || echo 0)
      set +e
    fi
  fi
fi

# ----------------------------------------------------------------------------
# Cell 1: positive cell — default `claude -p` (D-07 — full plugin sync runs;
# D-22 capture rc + stderr inspection).
# ----------------------------------------------------------------------------
if [[ "$SKIP_CELLS" == "false" ]]; then
  : > "$SANDBOX_IP"   # truncate to 0 bytes
  pre_size_cell1=$(stat -c %s "$SANDBOX_IP" 2>/dev/null || echo 0)
  echo "Cell 1 (default -p): truncated sandbox IP to $pre_size_cell1 bytes; invoking claude -p (auth: $cell1_auth_method)"
  set +e
  cell1_stderr=$(HOME="$TMPROOT" CLAUDE_CONFIG_DIR="$SANDBOX" timeout 30 claude -p "noop" </dev/null 2>&1 >/dev/null)
  cell1_rc=$?
  set +e
  post_size_default=$(stat -c %s "$SANDBOX_IP" 2>/dev/null || echo 0)

  # Validate post-state JSON shape if non-zero
  if [[ "$post_size_default" -gt 0 ]] && jq -e . "$SANDBOX_IP" >/dev/null 2>&1; then
    json_validity_default=true
    if jq -e '.plugins["dhx@dhx-local"]' "$SANDBOX_IP" >/dev/null 2>&1; then
      dhx_entry_present_default=true
      # Boolean check only — no path leakage to outcome JSON (D-08 sanitization)
      installPath=$(jq -r '.plugins["dhx@dhx-local"].installPath // empty' "$SANDBOX_IP" 2>/dev/null)
      if [[ -n "$installPath" ]] && echo "$installPath" | grep -q "plugins/cache/dhx-local/dhx"; then
        install_path_resolves_to_expected_cache_layout=true
      fi
    fi
  fi
  echo "Cell 1 result: post_size=$post_size_default json_valid=$json_validity_default dhx_entry=$dhx_entry_present_default rc=$cell1_rc"
fi

# ----------------------------------------------------------------------------
# Cell 2: negative-control — `claude --bare -p` (D-07 — skips plugin sync per
# `claude --help`; D-22 capture rc + stderr).
# ----------------------------------------------------------------------------
if [[ "$SKIP_CELLS" == "false" ]]; then
  : > "$SANDBOX_IP"   # truncate again
  pre_size_cell2=$(stat -c %s "$SANDBOX_IP" 2>/dev/null || echo 0)
  echo "Cell 2 (--bare -p): truncated sandbox IP to $pre_size_cell2 bytes; invoking claude --bare -p (auth: $cell2_auth_method)"
  set +e
  cell2_stderr=$(HOME="$TMPROOT" CLAUDE_CONFIG_DIR="$SANDBOX" timeout 30 claude --bare -p "noop" </dev/null 2>&1 >/dev/null)
  cell2_rc=$?
  set +e
  post_size_bare=$(stat -c %s "$SANDBOX_IP" 2>/dev/null || echo 0)
  echo "Cell 2 result: post_size=$post_size_bare rc=$cell2_rc"
fi

# ----------------------------------------------------------------------------
# Cell-outcome attribution + Convention A exit code (D-03 attribution table,
# D-01, D-22 failure-class extension).
#
# D-22 failure-class detection (priority over size-based attribution): inspect
# each cell's stderr/rc; any failure-class signal → ambiguous outcome.
# ----------------------------------------------------------------------------
classify_failure() {
  local rc="$1" stderr="$2"
  if [[ "$rc" -eq 124 ]] || echo "$stderr" | grep -qiE 'timeout|deadline'; then
    echo "timeout_124"; return
  fi
  if echo "$stderr" | grep -qiE '401|403|unauthorized|invalid api key|authentication'; then
    echo "auth_failure"; return
  fi
  if echo "$stderr" | grep -qiE 'network|connection|ENETUNREACH|ECONNREFUSED|EAI_'; then
    echo "network_failure"; return
  fi
  if [[ "$rc" -ne 0 ]]; then
    echo "setup_failure"; return
  fi
  echo "clean"
}

if [[ "$SKIP_CELLS" == "false" ]]; then
  cell1_class=$(classify_failure "$cell1_rc" "$cell1_stderr")
  cell2_class=$(classify_failure "$cell2_rc" "$cell2_stderr")

  if [[ "$cell1_class" != "clean" ]]; then
    cell_outcome="$cell1_class"
    conclusion="ambiguous"
    exit_code=2
    echo "FAIL cell-attribution: Cell 1 $cell1_class (rc=$cell1_rc) — investigation required"
    FAIL=$((FAIL+1))
  elif [[ "$cell2_class" != "clean" ]]; then
    cell_outcome="$cell2_class"
    conclusion="ambiguous"
    exit_code=2
    echo "FAIL cell-attribution: Cell 2 $cell2_class (rc=$cell2_rc) — investigation required"
    FAIL=$((FAIL+1))
  elif (( post_size_default > 0 )) && (( post_size_bare == 0 )); then
    cell_outcome="clean_hn_heals"
    conclusion="supersession_found_drop_heal"
    exit_code=1
    echo "OK   cell-attribution: clean_hn_heals — upstream now self-heals; retire heal hook"
    PASS=$((PASS+1))
  elif (( post_size_default == 0 )) && (( post_size_bare == 0 )); then
    cell_outcome="clean_no_heal"
    conclusion="v1_2_work_warranted"
    exit_code=0
    echo "OK   cell-attribution: clean_no_heal — HP-025 holds; heal hook hardening warranted"
    PASS=$((PASS+1))
  elif (( post_size_default > 0 )) && (( post_size_bare > 0 )); then
    cell_outcome="confounded_both_heal"
    conclusion="ambiguous"
    exit_code=2
    echo "FAIL cell-attribution: confounded_both_heal — both cells healed; investigation required"
    FAIL=$((FAIL+1))
  else
    cell_outcome="bizarre"
    conclusion="ambiguous"
    exit_code=2
    echo "FAIL cell-attribution: bizarre — Cell 1 stayed 0 but Cell 2 healed; investigation required"
    FAIL=$((FAIL+1))
  fi
fi

# ----------------------------------------------------------------------------
# Outcome JSON write (D-08 schema + sanitization; RESEARCH HIGH-1 live cc_version;
# D-22 cell{N}_rc; D-23 per-cell auth_method; D-30 hostname-hash).
# ----------------------------------------------------------------------------
set +e
CC_VERSION=$(claude --version 2>/dev/null | awk '{print $1}')
set +e
[[ -n "$CC_VERSION" ]] || CC_VERSION="unknown"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RUN_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || date +%s%N)
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "$(cd "$(dirname "$0")/../.." && pwd)")
OUT_DIR="$REPO_ROOT/tests/probes/.results/v1.2-phase-0"
mkdir -p "$OUT_DIR"
OUT_FILE="$OUT_DIR/probe-installed-plugins-no-natural-heal.json"

# D-30: published_from_hostname is SHA-256 of `hostname -s`
# (synthetic identifier for cross-machine drift detection; NEVER literal hostname).
HOSTNAME_HASH=$(printf '%s' "$(hostname -s)" | sha256sum | awk '{print $1}')

OBSERVATIONS=$(jq -n \
  --argjson pre "$pre_size" \
  --argjson postd "$post_size_default" \
  --argjson postb "$post_size_bare" \
  --argjson jvd "$json_validity_default" \
  --argjson dxe "$dhx_entry_present_default" \
  --argjson ipr "$install_path_resolves_to_expected_cache_layout" \
  --arg c1auth "$cell1_auth_method" \
  --arg c2auth "$cell2_auth_method" \
  --argjson c1rc "$cell1_rc" \
  --argjson c2rc "$cell2_rc" \
  --argjson iso "$inode_isolated" \
  --arg outcome "$cell_outcome" \
  --arg published_from_hostname "$HOSTNAME_HASH" \
  '{pre_size:$pre, post_size_default:$postd, post_size_bare:$postb, json_validity_default:$jvd, dhx_entry_present_default:$dxe, install_path_resolves_to_expected_cache_layout:$ipr, cell1_auth_method:$c1auth, cell2_auth_method:$c2auth, cell1_rc:$c1rc, cell2_rc:$c2rc, inode_isolated:$iso, cell_outcome:$outcome, published_from_hostname:$published_from_hostname}')

# JSON-time sanitizer: refuse to write if observations contain /home/, /Users/,
# or system hostname. Defense-in-depth pairs with D-09 sync-public-mirror.sh scrub.
HOST=$(hostname -s)
if echo "$OBSERVATIONS" | grep -qE "(/home/|/Users/|$HOST)"; then
  echo "FATAL: observations contain PII; refusing write"
  exit 2
fi

jq -n \
  --arg id "probe-installed-plugins-no-natural-heal" \
  --argjson code "$exit_code" \
  --arg cc "$CC_VERSION" \
  --arg ts "$TS" \
  --arg run "$RUN_ID" \
  --argjson obs "$OBSERVATIONS" \
  --arg conc "$conclusion" \
  '{probe_id:$id, exit_code:$code, exit_code_convention:"exit_0_means_v1_2_work_warranted", cc_version:$cc, ts:$ts, run_id:$run, observations:$obs, conclusion:$conc}' \
  > "$OUT_FILE"

echo "OK   outcome-json-written: $OUT_FILE"
PASS=$((PASS+1))

# ----------------------------------------------------------------------------
# Summary + exit
# ----------------------------------------------------------------------------
echo "---"
echo "PASS: $PASS  FAIL: $FAIL  cell_outcome=$cell_outcome  conclusion=$conclusion  cell1_rc=$cell1_rc  cell2_rc=$cell2_rc  exit_code=$exit_code"
exit $exit_code
