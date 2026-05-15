#!/usr/bin/env bash
# spike-schema-02-tractability-2026-05-15.sh — 4-flag permission-mode spike (Phase 11 Plan 1)
#
# SAFE_FOR_LIVE: no
# RUNTIME: ~2-4min (4 mktemp sandboxes × per-flag install + claude -p invocation)
# CONVENTION: B (exit 0 means pass; per-flag failures captured in artifact, not exit code)
#
# Source: Phase 11 Plan 1 SCHEMA-02-01 tractability spike (2026-05-15).
# Decisions: D-02 (4-flag spike), D-06 (artifact contract), D-07 (hook-firing validation),
#            D-29 (bash-array argv), D-32 (committed for Phase 15 reproducibility),
#            D-34 (### Routing block grep-able shape), D-35 (try-each-instance cred fallback).
#
# Methodology: build a fresh mktemp sandbox per flag, install dhx-plugin, run claude -p
# with the flag, capture stream-json, classify the row per D-18a (edit_invoked + guard_fired
# + hook_exit + hook_outcome). Pre/post checksum live state roots (~/.claude/,
# ~/.ccs/instances/{a,b,c}/.claude/, ~/.cache/dhx/) to prove no mutation.
#
# NEVER set +e. Use rc=$? capture after subprocess per 2026-05-03 probe-set-flag discipline.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PLUGIN_DIR="$REPO_ROOT/dhx-plugin"

# Tractability output dir (operator-inspectable; not committed)
TRAC_TMP="${TRAC_TMP:-/tmp}"
mkdir -p "$TRAC_TMP"

# === Pre-flight: claude binary + version + flag-presence ===
command -v claude >/dev/null || { echo "FATAL: claude CLI not on PATH" >&2; exit 1; }
command -v jq     >/dev/null || { echo "FATAL: jq not on PATH"          >&2; exit 1; }
[ -d "$PLUGIN_DIR" ] || { echo "FATAL: dhx-plugin dir missing: $PLUGIN_DIR" >&2; exit 1; }

CC_VERSION_FULL=$(claude --version 2>&1)
CC_VERSION=$(echo "$CC_VERSION_FULL" | awk '{print $1}')
echo "spike: CC version: $CC_VERSION_FULL"
if [[ "$CC_VERSION" != "2.1.142" ]]; then
  echo "FATAL: CC version mismatch — expected 2.1.142, got '$CC_VERSION'" >&2
  echo "Re-run tractability spike on the matching CC version before proceeding." >&2
  exit 1
fi

# === Flag declarations (D-29 — bash arrays, NOT scalar strings) ===
FLAG_1=(--permission-mode acceptEdits)
FLAG_2=(--permission-mode bypassPermissions)
FLAG_3=(--allowed-tools "Read,Edit")
FLAG_4=(--dangerously-skip-permissions)

# Verify each flag against `claude --help` (abort with diagnostic if removed in 2.1.142)
HELP_TEXT=$(claude --help 2>&1)
verify_flag_in_help() {
  local flag="$1"
  if ! echo "$HELP_TEXT" | grep -q -- "$flag"; then
    echo "FATAL: flag '$flag' not present in claude --help (CC $CC_VERSION) — flag surface drifted" >&2
    exit 1
  fi
}
verify_flag_in_help "--permission-mode"
verify_flag_in_help "--allowed-tools"
verify_flag_in_help "--dangerously-skip-permissions"

# === Pre-flight: capture live-state checksums (D-06 mutation guard, BEFORE spike) ===
checksum_root() {
  local root="$1" label="$2"
  if [[ -d "$root" ]]; then
    find "$root" -type f -print0 2>/dev/null \
      | xargs -0 sha256sum 2>/dev/null \
      | sort > "$TRAC_TMP/schema-02-trac-pre-${label}.sha256"
    find "$root" -printf '%T@ %p\n' 2>/dev/null \
      | sort > "$TRAC_TMP/schema-02-trac-pre-mtimes-${label}.txt"
  else
    : > "$TRAC_TMP/schema-02-trac-pre-${label}.sha256"
    : > "$TRAC_TMP/schema-02-trac-pre-mtimes-${label}.txt"
  fi
}
checksum_root "$HOME/.claude" "home-claude"
for I in a b c; do
  checksum_root "$HOME/.ccs/instances/$I/.claude" "ccs-$I"
done
checksum_root "$HOME/.cache/dhx" "cache-dhx"

echo "spike: pre-state checksums captured at $TRAC_TMP/schema-02-trac-pre-*"

# === Per-flag spike loop ===
RESULTS_FILE="$TRAC_TMP/schema-02-trac-results.jsonl"
: > "$RESULTS_FILE"

run_one_flag() {
  local N="$1"
  local flag_arr_name="FLAG_$N"
  declare -n FLAG="$flag_arr_name"
  local argv_used="${FLAG[*]}"

  echo ""
  echo "=== flag $N: $argv_used ==="

  # Per-row sandbox build
  local SANDBOX
  SANDBOX=$(mktemp -d -t schema-02-trac-XXXXXX)
  mkdir -p "$SANDBOX/home" "$SANDBOX/config"
  export HOME="$SANDBOX/home" CLAUDE_CONFIG_DIR="$SANDBOX/config"

  # === Credential seeding with try-each-instance fallback (D-35) ===
  local SEED_FROM=""
  for I in c b a; do
    if [[ -f $HOME_ORIG/.ccs/instances/$I/.credentials.json ]]; then
      SEED_FROM=$I
      break
    fi
  done
  if [[ -z "$SEED_FROM" ]]; then
    echo "FATAL flag $N: no .credentials.json found across instances c,b,a" >&2
    rm -rf "$SANDBOX"
    return 1
  fi
  cp "$(readlink -f $HOME_ORIG/.ccs/instances/$SEED_FROM/.credentials.json)" "$CLAUDE_CONFIG_DIR/.credentials.json"
  chmod 600 "$CLAUDE_CONFIG_DIR/.credentials.json"
  echo "    creds_sourced_from: $SEED_FROM"

  # === Install pattern (D-16 verbatim from scripts/install-plugin.sh:163) ===
  local install_succeeded="false"
  local install_stderr="$SANDBOX/install.stderr"
  if claude plugin marketplace add "$PLUGIN_DIR" >/dev/null 2>"$install_stderr"; then
    if claude plugin install dhx >/dev/null 2>>"$install_stderr"; then
      install_succeeded="true"
    fi
  fi
  echo "    install_succeeded: $install_succeeded"

  # === Post-install plugin-registration jq -e check (D-06 + D-14 Layer 6 shape) ===
  # CC 2.1.142 installed_plugins.json schema (observed live):
  #   { "version": 2, "plugins": { "dhx@dhx-local": [ { "installPath": "...", "version": "...", ... } ] } }
  # The composite key "dhx@dhx-local" (plugin-name@marketplace) holds an array of installations.
  # We assert the array is non-empty AND .installPath resolves to a real directory containing hooks.
  local plugin_registered="false"
  local hooks_path_resolved="null"
  local installed_plugins="$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
  if [[ -f "$installed_plugins" ]]; then
    if hooks_path_resolved=$(jq -er '.plugins["dhx@dhx-local"][0].installPath // empty' "$installed_plugins" 2>/dev/null); then
      # Verify the installPath cache dir exists and has a hooks.json under it
      if [[ -n "$hooks_path_resolved" && -d "$hooks_path_resolved" ]]; then
        local hooks_json
        hooks_json=$(find "$hooks_path_resolved" -maxdepth 3 -name hooks.json 2>/dev/null | head -1)
        if [[ -n "$hooks_json" && -f "$hooks_json" ]]; then
          plugin_registered="true"
        fi
      fi
    else
      hooks_path_resolved="null"
    fi
  fi
  echo "    plugin_registered: $plugin_registered (installPath: $hooks_path_resolved)"

  # === Read-guard target + invocation ===
  local TARGET="$SANDBOX/_diag_never_read.txt"
  echo "schema-02 trac target" > "$TARGET"
  local STREAM="$TRAC_TMP/schema-02-trac-flag-$N.stream.jsonl"
  local STDERR="$TRAC_TMP/schema-02-trac-flag-$N.stderr"
  local PROMPT="Edit the file $TARGET — append a trailing newline. Do NOT call the Read tool first; invoke the Edit tool directly."

  # Time the invocation (best-effort wallclock)
  local t0 t1 wallclock_s rc
  t0=$(date +%s)
  # Direct array expansion — D-29 evidence (multi-word flags pass correctly).
  # errexit is never enabled (file top is set -uo pipefail only, no -e), so
  # claude's non-zero exit is captured via rc=$? immediately after the call.
  # No errexit-disable required — Phase 6 WR-04 / Phase 10.1 D-25 set-flag discipline.
  timeout 60 claude -p "${FLAG[@]}" --output-format stream-json --include-hook-events --verbose \
    "$PROMPT" \
    > "$STREAM" 2>"$STDERR" < /dev/null
  rc=$?
  t1=$(date +%s)
  wallclock_s=$(( t1 - t0 ))
  echo "    claude -p exit: $rc, wallclock_s: $wallclock_s"

  # === Per-row verdict from stream-json (D-18a / D-07 contract) ===
  local edit_invoked="false" guard_fired="false" hook_exit="null" hook_outcome="null"

  if [[ -s "$STREAM" ]]; then
    # edit_invoked: scan for any tool_use Edit event in assistant messages
    if jq -se '[.[]? | select(.type == "assistant") | (.message.content // []) | .[]? | select((.type // "") == "tool_use" and (.name // "") == "Edit")] | length > 0' "$STREAM" 2>/dev/null | grep -q true; then
      edit_invoked="true"
    fi

    # guard_fired: find hook_response with hook_name matching dhx-read-guard
    local guard_event
    guard_event=$(jq -sc 'first(.[]? | select(.type == "hook_response" and ((.hook_name // "") | test("dhx-read-guard"))))' "$STREAM" 2>/dev/null || echo "null")
    if [[ -n "$guard_event" && "$guard_event" != "null" ]]; then
      guard_fired="true"
      hook_exit=$(echo "$guard_event" | jq -r '.exit_code // "null"' 2>/dev/null)
      hook_outcome=$(echo "$guard_event" | jq -r '.outcome // "null"' 2>/dev/null)
    fi
  fi
  echo "    edit_invoked=$edit_invoked guard_fired=$guard_fired hook_exit=$hook_exit hook_outcome=$hook_outcome"

  # === Row outcome classification ===
  local row_outcome
  if [[ "$install_succeeded" == "false" ]]; then
    row_outcome="NO_INSTALL"
  elif [[ "$plugin_registered" == "false" ]]; then
    row_outcome="NO_REGISTRATION"
  elif [[ "$edit_invoked" == "true" && "$guard_fired" == "true" && "$hook_exit" == "2" && "$hook_outcome" == "blocked" ]]; then
    row_outcome="WINNER"
  elif [[ "$edit_invoked" == "true" && "$guard_fired" == "true" ]]; then
    row_outcome="FALLBACK_CANDIDATE"
  elif [[ "$edit_invoked" == "true" ]]; then
    row_outcome="NO_HOOK"
  else
    row_outcome="NO_TOOL"
  fi
  echo "    row_outcome: $row_outcome"

  # === Append to results file (JSONL, structured for artifact composition) ===
  jq -nc \
    --argjson n "$N" \
    --arg argv "$argv_used" \
    --arg creds "$SEED_FROM" \
    --argjson inst_ok "$( [[ "$install_succeeded" == "true" ]] && echo true || echo false )" \
    --argjson reg_ok "$( [[ "$plugin_registered" == "true" ]] && echo true || echo false )" \
    --arg hooks_path "$hooks_path_resolved" \
    --argjson edit_inv "$( [[ "$edit_invoked" == "true" ]] && echo true || echo false )" \
    --argjson guard "$( [[ "$guard_fired" == "true" ]] && echo true || echo false )" \
    --arg hex "$hook_exit" \
    --arg hou "$hook_outcome" \
    --arg outcome "$row_outcome" \
    --argjson rc "$rc" \
    --argjson wall "$wallclock_s" \
    '{
       n:$n, argv_used:$argv, creds_sourced_from:$creds,
       install_succeeded:$inst_ok, plugin_registered:$reg_ok, hooks_path:$hooks_path,
       edit_invoked:$edit_inv, guard_fired:$guard, hook_exit:$hex, hook_outcome:$hou,
       claude_exit:$rc, wallclock_s:$wall, row_outcome:$outcome
     }' >> "$RESULTS_FILE"

  # === Cleanup per-row sandbox ===
  rm -rf "$SANDBOX"

  # Restore HOME to original for the next iteration's cred lookup
  export HOME="$HOME_ORIG"
}

# Snapshot HOME before any sandbox export overrides it
HOME_ORIG="$HOME"
export HOME_ORIG

# === Run all 4 flags in order ===
for N in 1 2 3 4; do
  run_one_flag "$N" || echo "    flag $N aborted with non-zero return"
done

# Restore HOME (defensive)
export HOME="$HOME_ORIG"
unset CLAUDE_CONFIG_DIR

# === Post-spike checksum capture + diff (D-06 boundary invariant) ===
checksum_root_post() {
  local root="$1" label="$2"
  if [[ -d "$root" ]]; then
    find "$root" -type f -print0 2>/dev/null \
      | xargs -0 sha256sum 2>/dev/null \
      | sort > "$TRAC_TMP/schema-02-trac-post-${label}.sha256"
    find "$root" -printf '%T@ %p\n' 2>/dev/null \
      | sort > "$TRAC_TMP/schema-02-trac-post-mtimes-${label}.txt"
  else
    : > "$TRAC_TMP/schema-02-trac-post-${label}.sha256"
    : > "$TRAC_TMP/schema-02-trac-post-mtimes-${label}.txt"
  fi
}
checksum_root_post "$HOME/.claude" "home-claude"
for I in a b c; do
  checksum_root_post "$HOME/.ccs/instances/$I/.claude" "ccs-$I"
done
checksum_root_post "$HOME/.cache/dhx" "cache-dhx"

# Diff each pair
echo ""
echo "=== Live-state mutation guard diffs ==="
MUTATION_DETECTED="false"
MUTATION_PATHS=""
for label in home-claude ccs-a ccs-b ccs-c cache-dhx; do
  pre="$TRAC_TMP/schema-02-trac-pre-${label}.sha256"
  post="$TRAC_TMP/schema-02-trac-post-${label}.sha256"
  diff_out="$TRAC_TMP/schema-02-trac-diff-${label}.txt"
  diff "$pre" "$post" > "$diff_out" 2>&1
  if [[ -s "$diff_out" ]]; then
    MUTATION_DETECTED="true"
    MUTATION_PATHS="$MUTATION_PATHS $label"
    echo "[FAIL] mutation detected at: $label (see $diff_out)"
  else
    echo "[OK]   $label — diff empty"
  fi
done

# === Summary ===
echo ""
echo "=== Spike summary ==="
echo "Results JSONL: $RESULTS_FILE"
cat "$RESULTS_FILE"
echo ""
if [[ "$MUTATION_DETECTED" == "true" ]]; then
  echo "WARNING: live-state mutation detected at:$MUTATION_PATHS"
fi

# Determine winner + fallback (in test order: 1, 2, 3, 4)
WINNER_N=""
FALLBACK_N=""
while IFS= read -r line; do
  n=$(echo "$line" | jq -r '.n')
  outcome=$(echo "$line" | jq -r '.row_outcome')
  if [[ "$outcome" == "WINNER" && -z "$WINNER_N" ]]; then
    WINNER_N="$n"
  fi
done < "$RESULTS_FILE"
# Pick fallback as next WINNER or FALLBACK_CANDIDATE that is not WINNER_N
while IFS= read -r line; do
  n=$(echo "$line" | jq -r '.n')
  outcome=$(echo "$line" | jq -r '.row_outcome')
  if [[ ( "$outcome" == "WINNER" || "$outcome" == "FALLBACK_CANDIDATE" ) && "$n" != "$WINNER_N" && -z "$FALLBACK_N" ]]; then
    FALLBACK_N="$n"
  fi
done < "$RESULTS_FILE"

if [[ -n "$WINNER_N" ]]; then
  WINNER_ARGV=$(jq -r --argjson n "$WINNER_N" 'select(.n == $n) | .argv_used' "$RESULTS_FILE")
  echo "WINNER: flag $WINNER_N — $WINNER_ARGV"
else
  echo "WINNER: (none — verdict NO)"
fi

if [[ -n "$FALLBACK_N" ]]; then
  FALLBACK_ARGV=$(jq -r --argjson n "$FALLBACK_N" 'select(.n == $n) | .argv_used' "$RESULTS_FILE")
  echo "FALLBACK: flag $FALLBACK_N — $FALLBACK_ARGV"
else
  echo "FALLBACK: (none)"
fi

exit 0
