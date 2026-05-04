#!/bin/bash
# probe-read-guard-strong-signal.sh (SCHEMA-02; READ-FUT-02 dead-signal probe)
#
# SAFE_FOR_LIVE: no   (sandboxed via D-18d cp -rL; runs claude -p subprocess
#                      with timeout 60 per cell × 18 cells = ~9-15min wallclock,
#                      exceeds run-probes.sh 30s/probe budget — operator-invoked.
#                      Read-only against live plugin/manifest state; sandbox-only
#                      mutation, but routed through SAFE_FOR_LIVE=no so default
#                      `bash scripts/run-probes.sh` (filter=yes) skips it and the
#                      pre-commit gate cannot trip on the long runtime.)
# RUNTIME: ~9-15min (20-cell matrix; operator-invoked outside run-probes.sh wrapper)
#
# Observation-only soft-verdict probe per D-03. Exits 0 unconditionally (per SCHEMA-03).
# 20-cell matrix per D-02 + D-18b: 3 instances × 3 modes × 2 sessions = 18 main cells
# + 2 negative controls = 20 total. Per-cell JSONL line emitted to schema-02-verdicts.jsonl.
# Aggregator computes HIGH/MED/LOW per dynamic SCHEMA-05 (D-18c) at end of run.
#
# WAVE 0 OQ1 OUTCOME (06-03 Task 1, 2026-05-04): claude -p in sandboxed CLAUDE_CONFIG_DIR
# context returns "Not logged in" (apiKeySource=none). Both auth-failed and resume-mode
# cells degrade to the same `inconclusive_harness_failure` verdict per D-18a. Matrix
# layout retained at 20 cells (full cross-product); operators with seeded credentials
# can switch the MODES line below to the 14-cell shrink path if they observe the
# /resume mode is unsupported in -p subprocess context AFTER successful auth.
#
# D-18 cascade (cross-AI review 2026-05-03):
#   - D-18a: per-cell verdict from CC stream-json events (tool_use Edit + hook_response
#            dhx-read-guard), NOT file content. Codex HIGH concern resolved.
#   - D-18b: 20-cell layout preserves full 3×3×2 cross-product; (c, resume) pair is
#            explicitly run, not dropped by iteration accident.
#   - D-18c: aggregator dynamic — main_cells=total-2; HIGH=100% main rejected;
#            MED=≥80%; LOW otherwise; INVALID=control failure. Replaces -ge 16.
#   - D-18d: sandbox copies dhx-plugin/ from REPO (git rev-parse) + ~/.claude/plugins/
#            from live tree, NOT from ~/.ccs/instances/<I>/ (no manifest there).
#   - D-18e: jq surgical hook removal preserves matcher entry + dhx-assessed-guard.sh
#            co-tenant. Operates on .hooks.PreToolUse (live schema), NOT .PreToolUse.
#   - D-18f: 2 control cells run as PRE-FLIGHT GATE; either failure aborts the main matrix.
#
# Backs:
#   - .planning/REQUIREMENTS.md SCHEMA-02..05 (READ-FUT-02 probe-as-decision)
#   - .planning/phases/06-*/06-CONTEXT.md D-02/D-08/D-09/D-10 + D-18a..f + Discretion #11
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
OUT_DIR="$REPO_ROOT/tests/probes/.results/v1.2-phase-6"
VERDICTS="$OUT_DIR/schema-02-verdicts.jsonl"
mkdir -p "$OUT_DIR"
: > "$VERDICTS"   # truncate verdicts file at start of run

# Matrix axes per D-02/D-08/D-09/D-18b (CONTEXT.md pre-registered)
INSTANCES=("a" "b" "c")
MODES=("default-p" "bare-p" "resume")   # If MATRIX_SHRINK=true (Wave 0 OQ1 fail), comment out and use 2-mode below
# MODES=("default-p" "bare-p")          # 14-cell shrink path
SESSIONS=("s1" "s2")

PII_HOST=$(hostname -s)

sanitize() {
  local raw="$1"
  printf '%s' "$raw" | sed -e "s|/home/[^ /]*|<sanitized>|g" -e "s|/Users/[^ /]*|<sanitized>|g" -e "s|$PII_HOST|<sanitized>|g"
}

emit_verdict() {
  local cell_id="$1" verdict="$2" rejection_observed="$3" details="$4" guard_state="${5:-absent}"
  local file_path="${6:-<sanitized>}" edit_invoked="${7:-false}" guard_fired="${8:-false}"
  local hook_exit="${9:-null}" hook_outcome="${10:-null}"
  jq -nc \
    --arg id "$cell_id" --arg v "$verdict" \
    --argjson rej "$rejection_observed" --arg d "$(sanitize "$details")" \
    --arg gs "$guard_state" --arg fp "$(sanitize "$file_path")" \
    --argjson eti "$edit_invoked" --argjson rgf "$guard_fired" \
    --argjson hex "$hook_exit" --arg hou "$hook_outcome" \
    '{cell_id:$id, verdict:$v,
      evidence:{file_path:$fp, guard_state:$gs, rejection_observed:$rej,
                edit_tool_invoked:$eti, read_guard_fired:$rgf,
                hook_exit_code:$hex, hook_outcome:$hou,
                details:$d}}' \
    >> "$VERDICTS"
}

# D-18d sandbox builder — used by every cell
build_sandbox() {
  local instance="$1" sandbox="$2"
  mkdir -p "$sandbox"
  # Layer 1: live ~/.claude/plugins/ (installed_plugins.json + known_marketplaces.json)
  cp -rL "$HOME/.claude/plugins" "$sandbox/" 2>/dev/null || true
  # Layer 2: REPO dhx-plugin/ (the manifest the read-guard registers from)
  cp -rL "$REPO_ROOT/dhx-plugin" "$sandbox/" 2>/dev/null || true
  # Layer 3: instance-specific config (history / overrides)
  local idir="$HOME/.ccs/instances/$instance"
  if [[ -d "$idir/.claude" ]]; then
    cp -rL "$idir/.claude/"* "$sandbox/" 2>/dev/null || true
  fi
}

# D-18e jq surgical unregister — live schema verified (top-level "hooks", PreToolUse path)
unregister_read_guard() {
  local manifest="$1"
  [[ -f "$manifest" ]] || return 0
  jq '(.hooks.PreToolUse[].hooks) |= map(select((.command // "") | test("dhx-read-guard") | not))' \
    "$manifest" > "$manifest.tmp" 2>/dev/null && mv "$manifest.tmp" "$manifest"
}

# D-18a verdict classification from stream-json output
# Args: $1=stream_log_path
# Echoes 5 space-separated values: verdict edit_invoked guard_fired hook_exit_code hook_outcome
classify_from_stream() {
  local stream="$1"
  [[ -f "$stream" ]] || { echo "inconclusive_harness_failure false false null null"; return; }

  local edit_invoked="false"
  if jq -se '[.[]? | select(.type == "assistant" and (.message.content[]?.type // "") == "tool_use" and (.message.content[]?.name // "") == "Edit")] | length > 0' "$stream" 2>/dev/null | grep -q true; then
    edit_invoked="true"
  fi

  # Look for PreToolUse hook_response with hook_name matching dhx-read-guard
  local guard_fired="false" hook_exit="null" hook_outcome="null"
  local guard_event
  guard_event=$(jq -se 'first(.[]? | select(.type == "hook_response" and ((.hook_name // "") | test("dhx-read-guard"))))' "$stream" 2>/dev/null)
  if [[ -n "$guard_event" && "$guard_event" != "null" ]]; then
    guard_fired="true"
    hook_exit=$(echo "$guard_event" | jq -r ".exit_code // \"null\"" 2>/dev/null)
    hook_outcome=$(echo "$guard_event" | jq -r ".outcome // \"null\"" 2>/dev/null)
  fi

  # Detect auth/timeout/system error in stream
  local harness_error="false"
  if jq -se '[.[]? | select((.type // "") == "result" and (.is_error // false) == true) , .[]? | select((.error // "") == "authentication_failed")] | length > 0' "$stream" 2>/dev/null | grep -q true; then
    harness_error="true"
  fi

  local verdict
  if [[ "$edit_invoked" == "true" && "$harness_error" == "true" ]]; then
    verdict="inconclusive_harness_failure"
  elif [[ "$harness_error" == "true" ]]; then
    verdict="inconclusive_harness_failure"
  elif [[ "$edit_invoked" == "true" && "$guard_fired" == "true" && "$hook_exit" == "2" && "$hook_outcome" == "blocked" ]]; then
    verdict="runtime_rejected"
  elif [[ "$edit_invoked" == "true" ]]; then
    verdict="runtime_allowed"
  else
    verdict="inconclusive"
  fi

  echo "$verdict $edit_invoked $guard_fired $hook_exit $hook_outcome"
}

# ============================================================================
# D-18f PRE-FLIGHT NEGATIVE-CONTROL GATE (runs BEFORE main matrix)
# ============================================================================
echo "[pre-flight] running negative controls (D-18f)"

# Cell 17: read-guard PRESENT, never-Read file Edit attempt → expected runtime_rejected
TMPROOT=$(mktemp -d); trap 'rm -rf "$TMPROOT"' EXIT
SANDBOX="$TMPROOT/cfg"
build_sandbox "a" "$SANDBOX"
NEVER_READ="$SANDBOX/_control_17_never_read.txt"
echo "control 17 baseline content" > "$NEVER_READ"
# Do NOT unregister — guard stays PRESENT
set +e
HOME="$TMPROOT" CLAUDE_CONFIG_DIR="$SANDBOX" timeout 60 \
  claude -p --output-format stream-json --include-hook-events --verbose \
  "Edit the file $NEVER_READ — replace 'baseline' with 'modified'" \
  > "$TMPROOT/c17.stream.jsonl" 2>"$TMPROOT/c17.stderr" < /dev/null
set +e
read -r v17 e17 g17 he17 ho17 < <(classify_from_stream "$TMPROOT/c17.stream.jsonl")
case "$v17" in runtime_rejected) c17_rej=true ;; *) c17_rej=false ;; esac
emit_verdict "control_17_guard_present" "$v17" "$c17_rej" "control: guard kept in manifest" "present" "$NEVER_READ" "$e17" "$g17" "$he17" "$ho17"
rm -rf "$TMPROOT"
trap - EXIT

# Cell 18: known-Read file (cache-seeded), Edit attempt with guard ABSENT → expected runtime_allowed
TMPROOT=$(mktemp -d); trap 'rm -rf "$TMPROOT"' EXIT
SANDBOX="$TMPROOT/cfg"
build_sandbox "a" "$SANDBOX"
KNOWN_READ="$SANDBOX/_control_18_readbefore.txt"
echo "control 18 baseline content" > "$KNOWN_READ"
CACHE_DIR="$TMPROOT/.cache/dhx"; mkdir -p "$CACHE_DIR"
NOW=$(date +%s)
jq -nc --arg path "$KNOWN_READ" --argjson ts "$NOW" \
  '{path:$path, source:"read", partial:false, ts:$ts}' >> "$CACHE_DIR/read-cache.jsonl"
unregister_read_guard "$SANDBOX/dhx-plugin/plugins/dhx/hooks/hooks.json"
set +e
HOME="$TMPROOT" CLAUDE_CONFIG_DIR="$SANDBOX" XDG_CACHE_HOME="$TMPROOT/.cache" timeout 60 \
  claude -p --output-format stream-json --include-hook-events --verbose \
  "Edit the file $KNOWN_READ — replace 'baseline' with 'modified'" \
  > "$TMPROOT/c18.stream.jsonl" 2>"$TMPROOT/c18.stderr" < /dev/null
set +e
read -r v18 e18 g18 he18 ho18 < <(classify_from_stream "$TMPROOT/c18.stream.jsonl")
case "$v18" in runtime_allowed) c18_allow=true ;; *) c18_allow=false ;; esac
emit_verdict "control_18_known_read" "$v18" "$c18_allow" "control: cache-seeded known-Read" "absent" "$KNOWN_READ" "$e18" "$g18" "$he18" "$ho18"
rm -rf "$TMPROOT"
trap - EXIT

# D-18f gate: BOTH controls must pass expected behavior
c17_correct=0; c18_correct=0
[[ "$v17" == "runtime_rejected" ]] && c17_correct=1
[[ "$v18" == "runtime_allowed" ]]  && c18_correct=1

if [[ "$c17_correct" -ne 1 || "$c18_correct" -ne 1 ]]; then
  echo "[pre-flight FAIL] negative-control gate failed (D-18f harness validation)"
  echo "  control_17_guard_present: $v17 (expected runtime_rejected)"
  echo "  control_18_known_read:    $v18 (expected runtime_allowed)"
  echo "ABORT: main matrix not run. Classification: INVALID."
  echo "SCHEMA-02 N=2: rejected=$c17_correct allowed=$c18_correct inconclusive=0 classification=INVALID"
  exit 0   # observation-only per D-03 — even on harness failure
fi
echo "[pre-flight OK] both controls report expected behavior — proceed with main matrix"

# ============================================================================
# MAIN MATRIX (3 instances × 3 modes × 2 sessions = 18 cells per D-18b; or 12 if shrink)
# ============================================================================
cell_count=0
for instance in "${INSTANCES[@]}"; do
  INSTANCE_DIR="$HOME/.ccs/instances/$instance"
  if [[ ! -d "$INSTANCE_DIR" ]]; then
    echo "[skip] instance dir absent: $INSTANCE_DIR"
    continue
  fi
  for mode in "${MODES[@]}"; do
    for session in "${SESSIONS[@]}"; do
      cell_count=$((cell_count + 1))
      # D-18b: NO `cell_count > 16` cap. Run the full cross-product.
      cell_id="s${session#s}_m${mode}_i${instance}"

      TMPROOT=$(mktemp -d); trap 'rm -rf "$TMPROOT"' EXIT
      SANDBOX="$TMPROOT/cfg"
      build_sandbox "$instance" "$SANDBOX"

      NEVER_READ="$SANDBOX/_never_read_$cell_id.txt"
      echo "synthetic content for SCHEMA-02 cell $cell_id" > "$NEVER_READ"

      # WR-02: inode-isolation guard removed — the synthetic NEVER_READ file is
      # created fresh in $TMPROOT (mktemp -d) and has no live counterpart. The
      # PROBE-02 pattern protects against routing a truncate to a live file via
      # hardlink/symlink chain; here there's no truncate and no live file. mktemp -d
      # failure short-circuits earlier via `set -uo pipefail`. If a future regression
      # re-points NEVER_READ at a live path, replace this comment with a positive
      # path-prefix assertion (`[[ "$NEVER_READ" == "$SANDBOX/"* ]]`).

      # D-18e surgical jq unregister (preserves matcher + dhx-assessed-guard.sh)
      unregister_read_guard "$SANDBOX/dhx-plugin/plugins/dhx/hooks/hooks.json"

      # Mode-specific invocation — all use stream-json + include-hook-events + verbose per D-18a
      set +e
      case "$mode" in
        default-p)
          HOME="$TMPROOT" CLAUDE_CONFIG_DIR="$SANDBOX" timeout 60 \
            claude -p --output-format stream-json --include-hook-events --verbose \
            "Edit the file $NEVER_READ — replace 'synthetic' with 'modified'" \
            > "$TMPROOT/cell.stream.jsonl" 2>"$TMPROOT/cell.stderr" < /dev/null
          ;;
        bare-p)
          HOME="$TMPROOT" CLAUDE_CONFIG_DIR="$SANDBOX" timeout 60 \
            claude --bare -p --output-format stream-json --include-hook-events --verbose \
            "Edit the file $NEVER_READ — replace 'synthetic' with 'modified'" \
            > "$TMPROOT/cell.stream.jsonl" 2>"$TMPROOT/cell.stderr" < /dev/null
          ;;
        resume)
          first_out=$(HOME="$TMPROOT" CLAUDE_CONFIG_DIR="$SANDBOX" timeout 30 \
            claude -p --output-format stream-json --include-hook-events --verbose "noop" 2>&1 < /dev/null)
          SID=$(echo "$first_out" | grep -oE "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}" | head -1)
          if [[ -z "$SID" ]]; then
            emit_verdict "$cell_id" "inconclusive" "false" "setup_failure: could not mint session_id for resume mode" "absent" "$NEVER_READ" "false" "false" "null" "null"
            rm -rf "$TMPROOT"; trap - EXIT
            continue
          fi
          HOME="$TMPROOT" CLAUDE_CONFIG_DIR="$SANDBOX" timeout 60 \
            claude --session-id "$SID" -p --output-format stream-json --include-hook-events --verbose \
            "Edit the file $NEVER_READ — replace 'synthetic' with 'modified'" \
            > "$TMPROOT/cell.stream.jsonl" 2>"$TMPROOT/cell.stderr" < /dev/null
          ;;
      esac
      set +e

      read -r verdict edit_inv guard_fire hex hou < <(classify_from_stream "$TMPROOT/cell.stream.jsonl")
      case "$verdict" in runtime_rejected) rej=true ;; *) rej=false ;; esac
      stderr_excerpt=$(head -c 300 "$TMPROOT/cell.stderr" 2>/dev/null | tr '\n' ' ')
      emit_verdict "$cell_id" "$verdict" "$rej" "stream parsed; stderr_head=$stderr_excerpt" "absent" "$NEVER_READ" "$edit_inv" "$guard_fire" "$hex" "$hou"

      rm -rf "$TMPROOT"; trap - EXIT
    done
  done
done

# ============================================================================
# D-18c DYNAMIC AGGREGATOR (replaces hardcoded -ge 16)
# ============================================================================
total=$(wc -l < "$VERDICTS")
main_cells=$((total - 2))    # subtract the 2 control cells

main_rejected=$(grep -E '"cell_id":"s' "$VERDICTS" | grep -c '"verdict":"runtime_rejected"' || true)
main_allowed=$(grep -E '"cell_id":"s' "$VERDICTS" | grep -c '"verdict":"runtime_allowed"' || true)
main_inconclusive=$(grep -E '"cell_id":"s' "$VERDICTS" | grep -c '"verdict":"inconclusive' || true)
# IN-02: main_inconclusive is computed for the summary line + outcome JSON only;
# it does NOT factor into the classification ladder. Inconclusive cells implicitly
# count toward (main_cells - main_rejected), depressing the rejected percentage.
# An all-inconclusive run produces LOW (rejected=0), which is the correct floor
# per SCHEMA-05 (LOW → REFUTE). If a future regression demands an explicit
# inconclusive-floor branch (e.g., "majority-inconclusive degrades verdict"),
# the place to add it is between the HIGH and MEDIUM branches below.

c17_correct=$(grep -E '"cell_id":"control_17' "$VERDICTS" | grep -c '"verdict":"runtime_rejected"' || true)
c18_correct=$(grep -E '"cell_id":"control_18' "$VERDICTS" | grep -c '"verdict":"runtime_allowed"' || true)

# D-18c dynamic classification (no hardcoded -ge 16; main_cells determines threshold)
# WR-03: zero-cell guard — when all instance dirs are absent, main_cells=0 and
# `0 -eq 0` would otherwise evaluate to HIGH ("100% main rejected"), pushing
# READ-FUT-02-IMPL on zero observations. INVALID is the correct verdict for
# no-evidence scenarios.
if [[ "$c17_correct" -ne 1 || "$c18_correct" -ne 1 ]]; then
  classification="INVALID"
elif [[ "$main_cells" -eq 0 ]]; then
  classification="INVALID"   # no observations — not a verdict
elif [[ "$main_rejected" -eq "$main_cells" ]]; then
  classification="HIGH"
elif (( main_rejected * 5 >= main_cells * 4 )); then     # ≥ 80%
  classification="MEDIUM"
else
  classification="LOW"
fi

echo "SCHEMA-02 N=$total: rejected=$main_rejected allowed=$main_allowed inconclusive=$main_inconclusive classification=$classification"
echo "Controls: c17_guard_present_rejected=$c17_correct c18_known_read_allowed=$c18_correct"
echo "Main cells: $main_cells (HIGH=100% rejected; MEDIUM=>=80%; LOW=<80%; INVALID=control failure)"
echo "(Per SCHEMA-05: only HIGH triggers READ-FUT-02-IMPL. MEDIUM/LOW/INVALID default to REFUTE.)"

exit 0   # observation-only per D-03 / SCHEMA-03
