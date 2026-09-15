#!/bin/bash
# probe-known-marketplaces-natural-heal.sh
#
# SAFE_FOR_LIVE: no   (spawns the real Claude Code binary against throwaway CLAUDE_CONFIG_DIRs; nothing live is read or written)
# RUNTIME: ~15-25s    (about 1 s per launch: 11 launches by default, 6 with --acceptance-out)
#
# Two questions about $CLAUDE_CONFIG_DIR/plugins/known_marketplaces.json ("km"), both answered by
# LAUNCHING Claude Code — the only oracle that counts: a km that parses but fails CC's schema loads
# zero plugins (docs/decisions.md 2026-09-15).
#
#   1. natural heal — does CC repair each km failure state by itself? One launch per state against a
#      sandbox whose settings declare dhx-local. "healed" = the km CC leaves behind is a schema-valid
#      object with a dhx-local entry whose installLocation exists. (CC 2.1.272: UNREADABLE and MISSING
#      heal — written on that launch, loaded on the next; BADJSON, STALE and NO_TIMESTAMP do not.)
#   2. heal acceptance — after dhx/dhx-plugin-registry-heal.sh repairs each state, does the next launch
#      register plugin hooks, with no "Marketplace configuration file is corrupted" line?
#
# Modes:
#   bash tests/probes/probe-known-marketplaces-natural-heal.sh
#       Both questions. Writes the corpus cell tests/probes/.results/v1.3-multi-cc-ver/<cc>/
#       probe-known-marketplaces-natural-heal.json (scripts/verify-multi-cc-results.sh validates it).
#       Exit — conclusion keyed on the BADJSON natural cell, as since Phase 6:
#         0  cell_outcome km_no_heal  → conclusion v1_2_work_warranted (CC leaves BADJSON broken)
#         1  cell_outcome km_hn_heals → conclusion supersession_found_drop_heal
#         2  ambiguous (no runnable binary, the healthy control did not load plugins, a launch failed)
#         3  heal output not accepted (any acceptance cell) — overrides 0 and 1
#   bash tests/probes/probe-known-marketplaces-natural-heal.sh --acceptance-out FILE [--binary BIN]
#       Question 2 only (plus the control). Writes {status: pass|fail|error, cc_version, ts, detail,
#       cells} to FILE and no corpus cell. Exit 0 pass, 3 fail, 2 error. dhx/dhx-km-acceptance.sh
#       runs this detached once per installed CC version.
#
# Binary: --binary, else CLAUDE_CODE_EXECPATH, else readlink -f ~/.local/bin/claude — resolved before
# any cell runs. (`claude` on PATH is claude-capped.sh, which re-resolves the binary through $HOME; the
# pre-2026-09-15 probe swapped HOME and every run exited 127.)
# Auth: none. The plugin loader and the declared-marketplace reconciler run before the login failure, so
# every launch ends "Not logged in" by design; env -i drops any inherited API key, so no cell spends tokens.
# Isolation: env -i, a fresh HOME + CLAUDE_CONFIG_DIR per cell, settings carry disableAllHooks:true (no
# plugin hook — the heal included — runs inside a cell). Plugin source: this checkout's dhx-plugin dir.
#
# Backs: docs/hook-patterns.md HP-025 § Remediation hook; docs/decisions.md 2026-09-15 rows.
set -uo pipefail

REPO=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || (cd "$(dirname "$0")/../.." && pwd))
HEAL="$REPO/dhx/dhx-plugin-registry-heal.sh"
SRC="$REPO/dhx-plugin"
PROBE_ID="probe-known-marketplaces-natural-heal"
STATES=(UNREADABLE MISSING BADJSON STALE NO_TIMESTAMP)

ACCEPT_OUT=""
BIN=""
while (( $# )); do
  case "$1" in
    --acceptance-out|--binary)
      (( $# >= 2 )) || { echo "$PROBE_ID: $1 needs a value" >&2; exit 2; }
      [[ "$1" == "--binary" ]] && BIN=$2 || ACCEPT_OUT=$2
      shift 2 ;;
    *) echo "$PROBE_ID: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$BIN" ]]; then
  if [[ -n "${CLAUDE_CODE_EXECPATH:-}" && -x "${CLAUDE_CODE_EXECPATH}" ]]; then
    BIN=$CLAUDE_CODE_EXECPATH
  else
    BIN=$(readlink -f "${HOME:-}/.local/bin/claude" 2>/dev/null || true)
  fi
fi
CC_VERSION=""
if [[ -n "$BIN" && -x "$BIN" ]]; then
  CC_VERSION=$(basename "$BIN")
  [[ "$CC_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || CC_VERSION=$("$BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
fi

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
PASS=0
FAIL=0
ok()  { printf 'OK   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

write_acceptance() {  # status detail cells_json
  [[ -n "$ACCEPT_OUT" ]] || return 0
  mkdir -p "$(dirname "$ACCEPT_OUT")" 2>/dev/null
  jq -n --arg status "$1" --arg detail "$2" --arg cc "${CC_VERSION:-unknown}" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson cells "$3" \
    '{status: $status, cc_version: $cc, ts: $ts, detail: $detail, cells: $cells}' \
    > "$ACCEPT_OUT.tmp" && mv -f "$ACCEPT_OUT.tmp" "$ACCEPT_OUT"
}

if [[ -z "$BIN" || ! -x "$BIN" || -z "$CC_VERSION" ]]; then
  bad "binary: no runnable Claude Code binary resolved (got '${BIN:-}')"
  write_acceptance error "no runnable Claude Code binary" '{}'
  echo "---"
  echo "PASS: $PASS  FAIL: $FAIL  exit_code=2"
  exit 2
fi
echo "INFO binary: CC $CC_VERSION"

# new_cell NAME → root with home/, cfg/plugins/, cwd/ and settings declaring dhx-local
new_cell() {
  local r="$TMPROOT/$1"
  mkdir -p "$r/home" "$r/cfg/plugins" "$r/cwd"
  jq -nc --arg p "$SRC" \
    '{enabledPlugins: {"dhx@dhx-local": true}, extraKnownMarketplaces: {"dhx-local": {source: {source: "directory", path: $p}}}, disableAllHooks: true}' \
    > "$r/cfg/settings.json"
  printf '%s' "$r"
}

# write_fixture STATE KM_PATH
write_fixture() {
  local km=$2
  case "$1" in
    HEALTHY)
      jq -nc --arg p "$SRC" '{"dhx-local": {source: {source: "directory", path: $p}, installLocation: $p, lastUpdated: "2026-01-01T00:00:00.000Z"}}' > "$km" ;;
    UNREADABLE) rm -f "$km" ;;
    MISSING) printf '{}' > "$km" ;;
    BADJSON) printf '%s' '{"version": 2, "marke' > "$km" ;;
    STALE)
      jq -nc --arg p "$SRC" '{"dhx-local": {source: {source: "directory", path: $p}, installLocation: "/nonexistent/probe-km-stale", lastUpdated: "2026-01-01T00:00:00.000Z"}}' > "$km" ;;
    NO_TIMESTAMP)
      jq -nc --arg p "$SRC" '{"dhx-local": {source: {source: "directory", path: $p}, installLocation: $p}}' > "$km" ;;
  esac
}

# launch ROOT → L_RC, L_HOOKS, L_PLUGINS (-1 when no registration line), L_REJECTED (true|false)
launch() {
  local r=$1
  local log="$r/debug.log"
  ( cd "$r/cwd" && env -i PATH=/usr/bin:/bin HOME="$r/home" CLAUDE_CONFIG_DIR="$r/cfg" TERM=dumb \
      timeout 90 "$BIN" -p noop --debug-file "$log" </dev/null >/dev/null 2>&1 )
  L_RC=$?
  local reg
  reg=$(grep -a -m1 -oE 'Registered [0-9]+ hooks from [0-9]+ plugins' "$log" 2>/dev/null)
  if [[ -n "$reg" ]]; then
    L_HOOKS=$(awk '{print $2}' <<< "$reg")
    L_PLUGINS=$(awk '{print $5}' <<< "$reg")
  else
    L_HOOKS=-1
    L_PLUGINS=-1
  fi
  if grep -aq 'Marketplace configuration file is corrupted' "$log" 2>/dev/null; then
    L_REJECTED=true
  else
    L_REJECTED=false
  fi
}

launch_failed() { (( L_RC == 124 || L_RC == 126 || L_RC == 127 )) || [[ "$L_PLUGINS" == "-1" ]]; }

km_valid_healed() {  # km path
  jq -e 'type == "object" and ([.[] | type == "object" and ((.lastUpdated | type) == "string")] | all) and ((."dhx-local" | type) == "object")' \
    "$1" >/dev/null 2>&1 || return 1
  local il
  il=$(jq -r '."dhx-local".installLocation // empty' "$1" 2>/dev/null)
  [[ -n "$il" && -d "$il" ]]
}

# ---- control: a healthy registry must load plugins, or no cell below means anything ----
r=$(new_cell control)
write_fixture HEALTHY "$r/cfg/plugins/known_marketplaces.json"
launch "$r"
CONTROL_PLUGINS=$L_PLUGINS
if launch_failed || (( L_PLUGINS < 1 )) || [[ "$L_REJECTED" == true ]]; then
  bad "control: healthy registry did not load plugins (launch_rc=$L_RC plugins=$L_PLUGINS rejected=$L_REJECTED)"
  CONTROL_OK=false
else
  ok "control: healthy registry → $L_HOOKS hooks from $L_PLUGINS plugins"
  CONTROL_OK=true
fi

# ---- question 2: heal acceptance ----
ACC_JSON='{}'
ACC_FAILED=()
for s in "${STATES[@]}"; do
  r=$(new_cell "accept-$s")
  km="$r/cfg/plugins/known_marketplaces.json"
  write_fixture "$s" "$km"
  env -i PATH=/usr/bin:/bin HOME="$r/home" CLAUDE_CONFIG_DIR="$r/cfg" bash "$HEAL" </dev/null >/dev/null 2>"$r/heal.err"
  hrc=$?
  launch "$r"
  if (( hrc != 0 )); then verdict=heal_failed
  elif launch_failed; then verdict=launch_failed
  elif [[ "$L_REJECTED" == true ]] || (( L_PLUGINS < 1 )); then verdict=rejected
  else verdict=accepted
  fi
  ACC_JSON=$(jq -c --arg s "$s" --arg v "$verdict" --argjson p "$L_PLUGINS" '. + {($s): {verdict: $v, plugins: $p}}' <<< "$ACC_JSON")
  if [[ "$verdict" == "accepted" ]]; then
    ok "acceptance $s: heal, then the next launch registers $L_HOOKS hooks from $L_PLUGINS plugins"
  else
    bad "acceptance $s: $verdict (heal_rc=$hrc launch_rc=$L_RC plugins=$L_PLUGINS rejected=$L_REJECTED)"
    ACC_FAILED+=("$s:$verdict")
  fi
done

if [[ -n "$ACCEPT_OUT" ]]; then
  cells=$(jq -c --argjson c "$CONTROL_PLUGINS" '. + {control_plugins: $c}' <<< "$ACC_JSON")
  if [[ "$CONTROL_OK" != true ]]; then
    write_acceptance error "healthy control launch did not load plugins" "$cells"; code=2
  elif (( ${#ACC_FAILED[@]} )); then
    write_acceptance fail "not accepted: ${ACC_FAILED[*]}" "$cells"; code=3
  else
    write_acceptance pass "" "$cells"; code=0
  fi
  echo "---"
  echo "PASS: $PASS  FAIL: $FAIL  acceptance=$(jq -r '.status' "$ACCEPT_OUT" 2>/dev/null)  exit_code=$code"
  exit $code
fi

# ---- question 1: natural heal ----
NAT_JSON='{}'
BAD_VERDICT=launch_failed
BAD_RC=-1
pre_size=21
post_size=0
json_validity_post=false
dhx_marketplace_present_post=false
for s in "${STATES[@]}"; do
  r=$(new_cell "natural-$s")
  km="$r/cfg/plugins/known_marketplaces.json"
  write_fixture "$s" "$km"
  launch "$r"
  if launch_failed; then verdict=launch_failed
  elif km_valid_healed "$km"; then verdict=healed
  else verdict=not_healed
  fi
  NAT_JSON=$(jq -c --arg s "$s" --arg v "$verdict" '. + {($s): $v}' <<< "$NAT_JSON")
  echo "INFO natural $s: $verdict (launch_rc=$L_RC)"
  if [[ "$s" == "BADJSON" ]]; then
    BAD_VERDICT=$verdict
    BAD_RC=$L_RC
    post_size=$(stat -c %s "$km" 2>/dev/null || echo 0)
    jq -e . "$km" >/dev/null 2>&1 && json_validity_post=true
    jq -e '."dhx-local"' "$km" >/dev/null 2>&1 && dhx_marketplace_present_post=true
  fi
done

if [[ "$CONTROL_OK" != true || "$BAD_VERDICT" == "launch_failed" ]]; then
  cell_outcome=setup_failure; conclusion=ambiguous; exit_code=2; confidence=LOW
elif [[ "$BAD_VERDICT" == "healed" ]]; then
  cell_outcome=km_hn_heals; conclusion=supersession_found_drop_heal; exit_code=1; confidence=HIGH
else
  cell_outcome=km_no_heal; conclusion=v1_2_work_warranted; exit_code=0; confidence=HIGH
fi
acceptance_status=pass
if (( ${#ACC_FAILED[@]} )); then
  acceptance_status=fail
  (( exit_code == 2 )) || exit_code=3
fi
echo "INFO conclusion: cell_outcome=$cell_outcome conclusion=$conclusion acceptance=$acceptance_status"

# ---- corpus cell ----
CORPUS="$REPO/tests/probes/.results"
cc_version_match=false
if [[ -d "$CORPUS/v1.3-multi-cc-ver/$CC_VERSION" ]] || [[ -d "$CORPUS/v1.2-phase-6" && "$CC_VERSION" == "2.1.121" ]]; then
  cc_version_match=true
fi
OUT_DIR="$CORPUS/v1.3-multi-cc-ver/$CC_VERSION"
mkdir -p "$OUT_DIR"
OUT_FILE="$OUT_DIR/$PROBE_ID.json"
HOSTNAME_HASH=$(printf '%s' "$(hostname -s)" | sha256sum | awk '{print $1}')

OBSERVATIONS=$(jq -n \
  --argjson pre "$pre_size" --argjson post "$post_size" \
  --argjson jvp "$json_validity_post" --argjson dxe "$dhx_marketplace_present_post" \
  --argjson c1rc "$BAD_RC" --arg outcome "$cell_outcome" \
  --argjson natural "$NAT_JSON" --argjson acceptance "$ACC_JSON" \
  --argjson control "$CONTROL_PLUGINS" --arg acc_status "$acceptance_status" \
  --arg host "$HOSTNAME_HASH" \
  '{pre_size: $pre, post_size: $post, json_validity_post: $jvp, dhx_marketplace_present_post: $dxe,
    known_marketplace_present_post: $dxe, cell1_auth_method: "none", cell1_rc: $c1rc, inode_isolated: true,
    cell_outcome: $outcome, natural: $natural, acceptance: $acceptance, acceptance_status: $acc_status,
    control_plugins: $control, published_from_hostname: $host}')

# JSON-time sanitizer: refuse to write if observations carry a home path or the literal hostname.
HOST=$(hostname -s 2>/dev/null)
[[ -z "$HOST" || "$HOST" == "localhost" ]] && HOST="__no_host_check__"
HOST_ESCAPED=$(printf '%s' "$HOST" | sed 's/[][\\.*^$/+?(){}|]/\\&/g')
if grep -qE "(/home/|/Users/|$HOST_ESCAPED)" <<< "$OBSERVATIONS"; then
  echo "FATAL: observations contain PII; refusing write"
  exit 2
fi

jq -n --arg id "$PROBE_ID" --argjson code "$exit_code" --arg cc "$CC_VERSION" \
  --argjson ccm "$cc_version_match" --arg conf "$confidence" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg run "$(cat /proc/sys/kernel/random/uuid 2>/dev/null || date +%s%N)" \
  --argjson obs "$OBSERVATIONS" --arg conc "$conclusion" \
  '{probe_id: $id, exit_code: $code, exit_code_convention: "exit_0_means_v1_2_work_warranted", cc_version: $cc,
    cc_version_match: $ccm, confidence: $conf, ts: $ts, run_id: $run, observations: $obs, conclusion: $conc}' \
  > "$OUT_FILE"
ok "outcome-json-written: $OUT_FILE"

echo "---"
echo "PASS: $PASS  FAIL: $FAIL  cell_outcome=$cell_outcome  conclusion=$conclusion  acceptance=$acceptance_status  confidence=$confidence  exit_code=$exit_code"
exit $exit_code
