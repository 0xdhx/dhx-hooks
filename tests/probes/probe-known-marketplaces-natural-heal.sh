#!/bin/bash
# probe-known-marketplaces-natural-heal.sh
#
# SAFE_FOR_LIVE: no   (sandbox-only via CLAUDE_CONFIG_DIR isolation; runs claude subprocess)
# RUNTIME: ~30s
#
# Supersession-watchdog probe (Phase 6 D-11; HEAL-07 mini-probe). Asserts the
# natural-heal premise on `known_marketplaces.json` (currently in heal hook scope
# via header lock per HEAL-02). Symmetric to D-07a but for km file instead of IP;
# uses the canonical truncated shape per D-17 (Hn() rehydration is shape-agnostic).
#   exit 0 = premise holds (km branch warranted; HEAL-07 hardening shipped)
#   exit 1 = supersession found (km branch retired; HEAL-07 closes as superseded)
#   exit 2 = ambiguous (auth gap, sandbox isolation failure, confounded outcome,
#            failure-class detected per cell stderr inspection,
#            pre-state abnormal — live $LIVE_KM missing,
#            cc_version mismatch per D-22 silent-upgrade safeguard)
#
# Operates on LIVE plugin cache content (which may lag repo source until
# next plugin install/reload); supersession-watchdog reads live state by
# design — RESEARCH MEDIUM-4 cache-vs-source asymmetry is correct behavior.
#
# Backs:
#   - .planning/REQUIREMENTS.md HEAL-07 (D-15 gate consumer)
#   - docs/hook-patterns.md HP-025 (natural-heal asymmetry — Phase 6 doctrine correction)
#   - .planning/phases/06-*/06-CONTEXT.md D-11 + D-17 + D-22 (cc_version assertion)
#
# Run: ANTHROPIC_API_KEY=sk-ant-... bash tests/probes/probe-known-marketplaces-natural-heal.sh
#
# D-25 set-flag discipline (WR-04 corrected): file top is `set -uo pipefail`
# only — `errexit` is NEVER enabled. The original draft sprinkled `set +e`
# around every subprocess; those calls were no-ops (you can't disable a flag
# that was never on) and have been removed. The actual safety mechanism is
# `rc=$?` immediately after each subprocess call: that captures the exit
# code regardless of `errexit`, so an early jq/stat exit-1 cannot abort
# before the ambiguous outcome JSON is written.
#
# D-22 (cross-AI review 2026-05-03): asserts live `claude --version` matches
# baseline 2.1.121; mismatch rewrites .conclusion to "ambiguous" (gate-halting)
# and emits confidence=LOW so C2 D-15 gate halts on silent CC upgrade.
set -uo pipefail
EXPECTED_CC_VERSION="2.1.121"

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

# D-22 cc_version assertion defaults (cross-AI review 2026-05-03)
cc_version_match=false
confidence="LOW"

# Observation defaults (used by JSON write block; refined as cells run)
pre_size=0
post_size=0
json_validity_post=false
dhx_marketplace_present_post=false
known_marketplace_present_post=false   # any of the live registered marketplaces returns
inode_isolated=false
cell1_stderr=""

# ----------------------------------------------------------------------------
# Sandbox setup
# ----------------------------------------------------------------------------
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
SANDBOX="$TMPROOT/cfg"
mkdir -p "$SANDBOX/plugins"

LIVE_CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"   # CCS-aware per CLAUDE.md
LIVE_KM="$LIVE_CFG/plugins/known_marketplaces.json"

# ----------------------------------------------------------------------------
# D-24 early pre-state gate: assert LIVE_KM exists BEFORE cp -rL.
# Pre-state abnormal is meaningfully different from supersession-or-no-supersession;
# treat as ambiguous and write the outcome JSON anyway (audit trail).
# ----------------------------------------------------------------------------
if [[ ! -f "$LIVE_KM" ]]; then
  echo "FAIL pre-state-abnormal: live $LIVE_KM missing — cannot evaluate Hn() heal behavior"
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
# Capture live km marketplaces — used to detect "Hn() rehydrated SOMETHING from
# the previously-known set." dhx-local is NOT currently in live km (only github
# marketplaces are tracked). The dual-path assertion: heal verified if Hn()
# either re-adds dhx-local OR restores any known live-marketplace entry.
# ----------------------------------------------------------------------------
LIVE_KM_KEYS=""
if [[ -f "$LIVE_KM" ]]; then
  LIVE_KM_KEYS=$(jq -r 'keys[]?' "$LIVE_KM" 2>/dev/null | head -3)
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
# Auth strategy (D-23 per-cell auth_method; RESEARCH HIGH-3 strict-mode):
#   Cell 1 (default -p)  accepts .credentials.json OR ANTHROPIC_API_KEY
#   Cell 2 (--bare -p)   STRICTLY requires ANTHROPIC_API_KEY (CLI-enforced invariant)
# ----------------------------------------------------------------------------
if [[ "$SKIP_CELLS" == "false" ]]; then
  if [[ -f "$LIVE_CFG/.credentials.json" ]]; then
    cp "$(readlink -f "$LIVE_CFG/.credentials.json")" "$SANDBOX/.credentials.json"
    chmod 600 "$SANDBOX/.credentials.json"
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

  # NOTE: Cell 2 (--bare -p) DROPPED per Pattern A note 3 — D-07a is Cell 1 only.

  # Sanitized settings.json copy
  if [[ "$SKIP_CELLS" == "false" ]] && [[ -f "$LIVE_CFG/settings.json" ]]; then
    cp "$(readlink -f "$LIVE_CFG/settings.json")" "$SANDBOX/settings.json"
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
SANDBOX_KM="$SANDBOX/plugins/known_marketplaces.json"
if [[ "$SKIP_CELLS" == "false" ]]; then
  if [[ ! -f "$SANDBOX_KM" ]]; then
    echo "FATAL: sandbox known_marketplaces.json missing post cp -rL"
    cell_outcome="setup_failure"
    conclusion="ambiguous"
    exit_code=2
    FAIL=$((FAIL+1))
    SKIP_CELLS=true
  else
    sandbox_inode=$(stat -c %i "$SANDBOX_KM" 2>/dev/null)
    live_inode=$(stat -c %i "$LIVE_KM" 2>/dev/null || echo "MISSING")
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
      pre_size=$(stat -c %s "$SANDBOX_KM" 2>/dev/null || echo 0)
    fi
  fi
fi

# ----------------------------------------------------------------------------
# Cell 1: positive cell — default `claude -p` (D-11 — full plugin sync runs).
# BADJSON fixture per D-17 (single canonical truncated shape; Hn() rehydration
# is shape-agnostic from resolver's POV) — symmetric to D-07a but for km file.
# ----------------------------------------------------------------------------
if [[ "$SKIP_CELLS" == "false" ]]; then
  # D-17: single canonical truncated shape (Hn() rehydration is shape-agnostic from resolver's POV).
  printf '%s' '{"version": 2, "marke' > "$SANDBOX_KM"   # truncated/malformed JSON
  pre_size_cell1=$(stat -c %s "$SANDBOX_KM" 2>/dev/null || echo 0)
  pre_size="$pre_size_cell1"   # WR-01: pre_size in JSON reflects actual pre-Hn() state
                               # (post-fixture write), NOT the cp'd-live snapshot.
  echo "Cell 1 (default -p): wrote km BADJSON fixture ($pre_size_cell1 bytes); invoking claude -p (auth: $cell1_auth_method)"
  cell1_stderr=$(HOME="$TMPROOT" CLAUDE_CONFIG_DIR="$SANDBOX" timeout 30 claude -p "noop" </dev/null 2>&1 >/dev/null)
  cell1_rc=$?
  post_size=$(stat -c %s "$SANDBOX_KM" 2>/dev/null || echo 0)

  # Validate post-state JSON shape if non-zero
  if [[ "$post_size" -gt 0 ]] && jq -e . "$SANDBOX_KM" >/dev/null 2>&1; then
    json_validity_post=true
    # Dual-path dhx-local check: defends against `marketplaces` wrapper key OR top-level entry.
    # Live km schema is keyed top-level by marketplace name (no `marketplaces` wrapper); the
    # `marketplaces` fallback covers a hypothetical schema-evolution variant.
    if jq -e '.marketplaces["dhx-local"] // .["dhx-local"]' "$SANDBOX_KM" >/dev/null 2>&1; then
      dhx_marketplace_present_post=true
    fi
    # Heal also indicated if any of the previously-known live marketplaces returns —
    # dhx-local is NOT currently in live km (only github-source marketplaces are tracked),
    # so this dual-signal is the primary heal indicator.
    while IFS= read -r km_key; do
      [[ -z "$km_key" ]] && continue
      if jq -e --arg k "$km_key" '.marketplaces[$k] // .[$k]' "$SANDBOX_KM" >/dev/null 2>&1; then
        known_marketplace_present_post=true
        break
      fi
    done <<< "$LIVE_KM_KEYS"
  fi
  echo "Cell 1 result: post_size=$post_size json_valid=$json_validity_post dhx_marketplace=$dhx_marketplace_present_post known_marketplace=$known_marketplace_present_post rc=$cell1_rc"
fi

# ----------------------------------------------------------------------------
# Cell-outcome attribution + Convention A exit code (Discretion #4 enums).
#
# D-22 failure-class detection (priority over heal-detection): inspect cell
# stderr/rc; any failure-class signal → ambiguous outcome.
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

  # Heal verified if Hn() rehydrates the file with valid JSON AND restores either
  # dhx-local OR any previously-known live marketplace entry (dhx-local is NOT
  # currently registered as a github-source marketplace, so dual-signal is required).
  if [[ "$cell1_class" != "clean" ]]; then
    cell_outcome="$cell1_class"; conclusion="ambiguous"; exit_code=2
    echo "FAIL cell-attribution: Cell 1 $cell1_class (rc=$cell1_rc) — investigation required"
    FAIL=$((FAIL+1))
  elif [[ "$json_validity_post" == "true" ]] && [[ "$dhx_marketplace_present_post" == "true" || "$known_marketplace_present_post" == "true" ]]; then
    cell_outcome="km_hn_heals"; conclusion="supersession_found_drop_heal"; exit_code=1
    echo "OK   cell-attribution: km_hn_heals — Hn() rehydrated km file; retire km branch"
    PASS=$((PASS+1))
  else
    cell_outcome="km_no_heal"; conclusion="v1_2_work_warranted"; exit_code=0
    echo "OK   cell-attribution: km_no_heal — HP-025 holds for km BADJSON; HEAL-07 hardening warranted"
    PASS=$((PASS+1))
  fi
fi

# ----------------------------------------------------------------------------
# D-22 (cross-AI review 2026-05-03): cc_version match assertion. Mismatch →
# confidence=LOW + conclusion=ambiguous (gate-halting safeguard).
#
# Review concern: a silent CC upgrade between probe authoring and execution
# would otherwise produce false-confident PASS in C2's D-15 pre-flight gate.
# ----------------------------------------------------------------------------
cc_version_full=$(claude --version 2>/dev/null | head -1)
if printf '%s' "$cc_version_full" | grep -qF "$EXPECTED_CC_VERSION"; then
  cc_version_match=true
  confidence="HIGH"
  echo "OK   cc_version_match: live='$cc_version_full' contains expected '$EXPECTED_CC_VERSION'"
  PASS=$((PASS+1))
else
  cc_version_match=false
  confidence="LOW"
  # Override conclusion to halt C2 D-15 gate on version drift — review concern:
  # a silent CC upgrade between authoring + execution would otherwise produce false-confident PASS.
  conclusion="ambiguous"
  exit_code=2
  echo "FAIL cc_version_match: live='$cc_version_full' lacks expected '$EXPECTED_CC_VERSION' — confidence=LOW; conclusion=ambiguous"
  FAIL=$((FAIL+1))
fi

# ----------------------------------------------------------------------------
# Outcome JSON write (D-08 schema + sanitization; RESEARCH HIGH-1 live cc_version;
# D-22 cell{N}_rc; D-23 per-cell auth_method; D-30 hostname-hash).
# ----------------------------------------------------------------------------
CC_VERSION=$(claude --version 2>/dev/null | awk '{print $1}')
[[ -n "$CC_VERSION" ]] || CC_VERSION="unknown"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RUN_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || date +%s%N)
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "$(cd "$(dirname "$0")/../.." && pwd)")
OUT_DIR="$REPO_ROOT/tests/probes/.results/v1.2-phase-6"
mkdir -p "$OUT_DIR"
OUT_FILE="$OUT_DIR/probe-known-marketplaces-natural-heal.json"

# D-30: published_from_hostname is SHA-256 of `hostname -s`
# (synthetic identifier for cross-machine drift detection; NEVER literal hostname).
HOSTNAME_HASH=$(printf '%s' "$(hostname -s)" | sha256sum | awk '{print $1}')

OBSERVATIONS=$(jq -n \
  --argjson pre "$pre_size" \
  --argjson post "$post_size" \
  --argjson jvp "$json_validity_post" \
  --argjson dxe "$dhx_marketplace_present_post" \
  --argjson kmp "$known_marketplace_present_post" \
  --arg c1auth "$cell1_auth_method" \
  --argjson c1rc "$cell1_rc" \
  --argjson iso "$inode_isolated" \
  --arg outcome "$cell_outcome" \
  --arg published_from_hostname "$HOSTNAME_HASH" \
  '{pre_size:$pre, post_size:$post, json_validity_post:$jvp, dhx_marketplace_present_post:$dxe, known_marketplace_present_post:$kmp, cell1_auth_method:$c1auth, cell1_rc:$c1rc, inode_isolated:$iso, cell_outcome:$outcome, published_from_hostname:$published_from_hostname}')

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
if echo "$OBSERVATIONS" | grep -qE "(/home/|/Users/|$HOST_ESCAPED)"; then
  echo "FATAL: observations contain PII; refusing write"
  exit 2
fi

jq -n \
  --arg id "probe-known-marketplaces-natural-heal" \
  --argjson code "$exit_code" \
  --arg cc "$CC_VERSION" \
  --argjson ccm "$cc_version_match" \
  --arg conf "$confidence" \
  --arg ts "$TS" \
  --arg run "$RUN_ID" \
  --argjson obs "$OBSERVATIONS" \
  --arg conc "$conclusion" \
  '{probe_id:$id, exit_code:$code, exit_code_convention:"exit_0_means_v1_2_work_warranted", cc_version:$cc, cc_version_match:$ccm, confidence:$conf, ts:$ts, run_id:$run, observations:$obs, conclusion:$conc}' \
  > "$OUT_FILE"

echo "OK   outcome-json-written: $OUT_FILE"
PASS=$((PASS+1))

# ----------------------------------------------------------------------------
# Summary + exit
# ----------------------------------------------------------------------------
echo "---"
echo "PASS: $PASS  FAIL: $FAIL  cell_outcome=$cell_outcome  conclusion=$conclusion  cc_version_match=$cc_version_match  confidence=$confidence  cell1_rc=$cell1_rc  exit_code=$exit_code"
exit $exit_code
