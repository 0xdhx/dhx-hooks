#!/usr/bin/env bash
# probe-gsd-secret-guard-watch.sh — dhx/dhx-gsd-secret-guard-watch.sh + the LIVE guard it watches.
#
# TWO LAYERS, and the split is the whole point of the file:
#   [1]-[13]  the WATCHER, against fixtures. Proves it notices absence, deregistration, a
#             narrowed matcher and a changed sha, and that it speaks once per NEW STATE.
#   [14]-[18] the LIVE GUARD, fired for real. A sha match proves BYTES; it does not prove
#             the guard still refuses. Only invoking it does. This layer is why the watcher's
#             own green may never be read as "the secret-file class is covered".
#
# THE QUIET CASE IS [5]: a matcher narrowed from `Read|Grep|Bash` to `Read` leaves the file
# present, the sha unchanged and every disk-level check green while the Bash path goes bare.
# A presence-only watcher would have passed that, which is why the matcher is in the state.
#
# STILL NOT PROVEN BY ANY ARM HERE: that CC ROUTES a PreToolUse event into the guard in a
# real session. Registration is a declaration and invocation is behaviour; this probe covers
# the guard's behaviour WHEN INVOKED, not CC's routing. Nothing offline can cover that.
#
# SECRET-FILE LITERALS ARE ASSEMBLED FROM VARIABLES throughout. The live guard matches on the
# PATTERN OPERAND of a command too, so a probe that spelled the literal inline would be
# refused by the very guard it is testing — measured 2026-09-20, when a `grep -nE` carrying
# the literal in its pattern was blocked mid-investigation.
#
# Run: bash tests/probes/probe-gsd-secret-guard-watch.sh
#
# SAFE_FOR_LIVE: yes   (the WATCHER arms redirect every seam into mktemp trees —
#                       DHX_GSD_GUARD_PATH, DHX_GSD_GUARD_BASELINE, DHX_GSD_GUARD_SETTINGS,
#                       DHX_HOOKS_CACHE_DIR — so no state marker is ever planted under the
#                       live ~/.cache/dhx. The LIVE arms only EXECUTE the guard read-only with
#                       synthetic stdin and assert its verdict; the secret paths they name are
#                       never opened by the probe or by the guard, which decides on the path
#                       string alone. No writes to ~/.claude, ~/.ccs, gsd/ or the repo; no
#                       network. Nothing here modifies GSD-owned files.)

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$REPO/dhx/dhx-gsd-secret-guard-watch.sh"
BASELINE_REAL="$REPO/config/gsd-secret-guard-baseline.json"
[[ -f "$HOOK" ]] || { echo "FAIL hook not found: $HOOK"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASSED=0; FAILED=0
_assert() { if [[ "$2" == "$3" ]]; then echo "OK   $1"; PASSED=$((PASSED+1));
            else echo "FAIL $1 (expected [$2], got [$3])"; FAILED=$((FAILED+1)); fi; }

GUARD="$TMP/gsd-secret-read-guard.js"; echo 'console.log("fixture");' > "$GUARD"
GSHA=$(sha256sum "$GUARD" | cut -c1-16)
BASE="$TMP/baseline.json"
jq -n --arg s "$GSHA" '{guard_basename:"gsd-secret-read-guard.js", sha256_16:$s}' > "$BASE"

_settings() { # $1 matcher ("" = not registered at all)
  local f="$TMP/settings.$RANDOM.json"
  if [[ -z "$1" ]]; then jq -n '{hooks:{PreToolUse:[{matcher:"Write",hooks:[{type:"command",command:"bash other.sh"}]}]}}' > "$f"
  else jq -n --arg m "$1" '{hooks:{PreToolUse:[{matcher:$m,hooks:[{type:"command",command:"node \"$HOME/.claude/hooks/gsd-secret-read-guard.js\""}]}]}}' > "$f"; fi
  echo "$f"
}
_fire() { # $1 cache root, $2 settings file, $3 guard path, $4 baseline
  echo '{}' | DHX_HOOKS_CACHE_DIR="$1" DHX_GSD_GUARD_SETTINGS="$2" \
    DHX_GSD_GUARD_PATH="$3" DHX_GSD_GUARD_BASELINE="$4" bash "$HOOK" 2>&1
}

OK_SET=$(_settings "Read|Grep|Bash")

# --- [1] healthy -> silent ---
C1="$TMP/c1"; mkdir -p "$C1"
_assert "[1] present + registered + covers Bash + sha matches -> silent" "" \
  "$(_fire "$C1" "$OK_SET" "$GUARD" "$BASE")"

# --- [2] absent ---
C2="$TMP/c2"; mkdir -p "$C2"
OUT=$(_fire "$C2" "$OK_SET" "$TMP/not-there.js" "$BASE")
_assert "[2] guard file gone -> speaks ABSENT" "yes" \
  "$(grep -q 'ABSENT:' <<<"$OUT" && echo yes || echo no)"

# --- [3] present but not registered ---
C3="$TMP/c3"; mkdir -p "$C3"; NOREG=$(_settings "")
OUT=$(_fire "$C3" "$NOREG" "$GUARD" "$BASE")
_assert "[3] file present, no PreToolUse entry names it -> speaks UNREGISTERED" "yes" \
  "$(grep -q 'UNREGISTERED:' <<<"$OUT" && echo yes || echo no)"

# --- [4]-[5] THE QUIET CASE: matcher narrowed, everything else green ---
C4="$TMP/c4"; mkdir -p "$C4"; NARROW=$(_settings "Read")
OUT=$(_fire "$C4" "$NARROW" "$GUARD" "$BASE")
_assert "[4] matcher narrowed to Read -> speaks BASH UNCOVERED" "yes" \
  "$(grep -q 'BASH UNCOVERED:' <<<"$OUT" && echo yes || echo no)"
_assert "[5] ...and does NOT mis-report it as absent or unregistered" "no" \
  "$( { grep -q 'ABSENT:' <<<"$OUT" || grep -q 'UNREGISTERED:' <<<"$OUT"; } && echo yes || echo no)"

# --- [6] sha drift ---
C6="$TMP/c6"; mkdir -p "$C6"; OTHER="$TMP/other-guard.js"; echo 'console.log("different");' > "$OTHER"
OUT=$(_fire "$C6" "$OK_SET" "$OTHER" "$BASE")
_assert "[6] bytes changed under us -> speaks SHA CHANGED" "yes" \
  "$(grep -q 'SHA CHANGED:' <<<"$OUT" && echo yes || echo no)"

# --- [7] matcher "*" counts as covering Bash ---
C7="$TMP/c7"; mkdir -p "$C7"; STAR=$(_settings "*")
_assert "[7] matcher '*' covers every tool -> silent" "" \
  "$(_fire "$C7" "$STAR" "$GUARD" "$BASE")"

# --- [8]-[10] once per NEW STATE ---
C8="$TMP/c8"; mkdir -p "$C8"
FIRST=$(_fire "$C8" "$NOREG" "$GUARD" "$BASE")
SECOND=$(_fire "$C8" "$NOREG" "$GUARD" "$BASE")
_assert "[8] a steady bad state speaks once" "yes" \
  "$([[ -n "$FIRST" ]] && echo yes || echo no)"
_assert "[9] ...and is silent on the next session in the same state" "" "$SECOND"
THIRD=$(_fire "$C8" "$NARROW" "$GUARD" "$BASE")
_assert "[10] a DIFFERENT bad state speaks again (state digest, not a once-ever latch)" "yes" \
  "$([[ -n "$THIRD" ]] && echo yes || echo no)"
FOURTH=$(_fire "$C8" "$NOREG" "$GUARD" "$BASE")
_assert "[11] returning to an ALREADY-SEEN state stays silent" "" "$FOURTH"

# --- [12] guards ---
C12="$TMP/c12"; mkdir -p "$C12"
_assert "[12] DHX_SKIP_GSD_GUARD_WATCH=1 -> silent" "" \
  "$(echo '{}' | DHX_SKIP_GSD_GUARD_WATCH=1 DHX_HOOKS_CACHE_DIR="$C12" DHX_GSD_GUARD_SETTINGS="$NOREG" \
       DHX_GSD_GUARD_PATH="$TMP/not-there.js" DHX_GSD_GUARD_BASELINE="$BASE" bash "$HOOK" 2>&1)"
C13="$TMP/c13"; mkdir -p "$C13"
_assert "[13] no baseline file -> silent (nothing to compare against)" "" \
  "$(_fire "$C13" "$NOREG" "$TMP/not-there.js" "$TMP/no-baseline.json")"

# --- [14] the message states the consequence, not just the state ---
C14="$TMP/c14"; mkdir -p "$C14"
OUT=$(_fire "$C14" "$NARROW" "$GUARD" "$BASE")
_assert "[14] message names the Bash-path consequence and the sha-proves-bytes limit" "yes" \
  "$(grep -qi 'unguarded' <<<"$OUT" && grep -qi 'proves bytes' <<<"$OUT" && echo yes || echo no)"

# =====================================================================================
# LIVE BEHAVIOURAL arms — fire the real guard. Skipped, not failed, when it is absent:
# a missing guard is the WATCHER's finding to report, not this layer's to crash on.
# =====================================================================================
LIVE_GUARD="$HOME/.claude/hooks/gsd-secret-read-guard.js"
if [[ -f "$LIVE_GUARD" ]] && command -v node >/dev/null 2>&1; then
  # Assembled from fragments, never spelled inline -- and the BASENAME must be exactly the
  # protected name. The guard matches a basename of `.env` or `.env.<suffix>`, so a fixture
  # called `fixture.env` does NOT match and the arm reads rc 0, which looks exactly like a
  # guard that has stopped refusing. Caught here on the first run, and the reason this
  # comment exists: a wrong fixture shape in a security probe fails OPEN and reassures.
  D="."; EV="env"; SEC="$TMP/${D}${EV}"
  _verdict_rc() { node "$LIVE_GUARD" <<<"$1" >/dev/null 2>&1; echo $?; }

  RJ=$(jq -nc --arg p "$SEC" '{session_id:"probe",cwd:"/tmp",tool_name:"Read",tool_input:{file_path:$p}}')
  _assert "[15] LIVE guard refuses a secret-file Read (rc 2 = block, HP-009)" "2" "$(_verdict_rc "$RJ")"

  BJ=$(jq -nc --arg c "cat $SEC" '{session_id:"probe",cwd:"/tmp",tool_name:"Bash",tool_input:{command:$c}}')
  _assert "[16] LIVE guard refuses the same read on the BASH path" "2" "$(_verdict_rc "$BJ")"

  # Negative control. Without it [15]/[16] would stay green against a guard that had
  # degraded into refusing everything, which is a different broken and not a pass.
  NJ=$(jq -nc '{session_id:"probe",cwd:"/tmp",tool_name:"Read",tool_input:{file_path:"/tmp/ordinary-notes.txt"}}')
  _assert "[17] CONTROL: LIVE guard allows an ordinary path (not refuse-everything)" "0" "$(_verdict_rc "$NJ")"

  LSHA=$(sha256sum "$LIVE_GUARD" | cut -c1-16)
  BSHA=$(jq -r '.sha256_16 // ""' "$BASELINE_REAL" 2>/dev/null)
  _assert "[18] live guard bytes match the recorded baseline" "$BSHA" "$LSHA"
else
  echo "SKIP [15]-[18] live guard or node absent — the watcher reports this state, see [2]"
fi

echo "---"
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
