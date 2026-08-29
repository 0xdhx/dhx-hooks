#!/usr/bin/env bash
# probe-read-guard-native-enforcement-tripwire.sh — supersession-watchdog.
#
# Backs the 2026-05-24 decisions.md Option C collapse row (Q3 "depend + add a
# probe"). The collapse REMOVED dhx's strong READ-BEFORE-EDIT advisory and now
# DEPENDS on CC's NATIVE runtime to block edits/writes to unread files. This probe
# is the contract tripwire: if CC WEAKENS that native enforcement, it flips red
# → revive signal (the strong advisory may need to come back).
#
# THE PREMISE IS NOW MODEL-GATED (root-caused 2026-08-29, CC 2.1.251). Read the
# guard out of the bundle and it is a three-way conjunction, not a flat rule:
#
#   guardSkipped = no prior read
#               && (remoteCall || model NOT IN R)      # R = the 4.x-and-earlier set
#               && toolset does not expose the edit tool while withholding Read/REPL
#               && a Read of THIS path would be permission-allowed
#
#   R = {claude-opus-4-6, claude-haiku-4-5, claude-opus-4-5, claude-opus-4-1,
#        claude-opus-4-0, claude-sonnet-4-5, claude-sonnet-4-0,
#        claude-3-7-sonnet, claude-3-5-sonnet, claude-3-5-haiku}
#
# The 5-family is ABSENT from R, so on this machine's configured model the guard
# is SKIPPED and unread Edit/Write SUCCEEDS. See HP-058 and the 2026-08-29
# decisions row for the measured matrix.
#
# WHY THE OLD SHAPE FALSE-PASSED (the defect this rewrite fixes). The previous
# version drove its cells at `mktemp -d` targets with NO --add-dir, so a Read of
# the target was not permission-allowed and the FOURTH conjunct failed. CC then
# blocked unconditionally — on EVERY model, including ones where the guard is
# entirely disabled. Measured 2026-08-29: the old probe reported
# [PASS] premise_holds while its own children were running claude-opus-5[1m],
# a model for which the guard does not exist. It was measuring path
# unreachability and reporting it as enforcement. A watchdog that certifies a
# dependency it never exercised is worse than no watchdog.
#
# So the cells below make the path REACHABLE (--add-dir "$WORK"), which is the
# configuration real edits run in (in-repo paths, full toolset). That is the only
# configuration in which the Option C dependency means anything.
#
# Semantics (supersession-watchdog — see tests/probes/README.md):
#   exit 0 + premise_holds      = the live model still hard-blocks unread Edit AND
#                                 Write on a reachable path → collapse warranted.
#   exit 1 + supersession_found = the live model ALLOWED an unread Edit or Write
#                                 while the legacy-model control still BLOCKED
#                                 → the Option C dependency is not in force.
#   exit 0 + skipped            = no trustworthy result (no auth, auth failure,
#                                 model declined the tool, or the POSITIVE CONTROL
#                                 failed) — NOT a failure signal, and NOT a pass.
#
# FALSE-PASS GUARD (load-bearing — 2026-05-24): premise_holds is emitted ONLY when
# BOTH live cells definitively observed CC's block. An inconclusive cell can NEVER
# roll up to premise_holds — it degrades to `skipped`.
#
# FALSE-FAIL GUARD (load-bearing — 2026-08-29): supersession_found is emitted ONLY
# when the LEGACY-MODEL POSITIVE CONTROL blocked in the same run. Without it an
# ALLOW is indistinguishable from a broken harness (wrong path, lost tool, bad
# prompt) — which is exactly how the old shape's inverse error went unnoticed.
#
# CLASSIFY ON THE TOOL RESULT, NEVER THE RAW STREAM (2026-08-29). The model
# routinely QUOTES the block string in its own prose after a successful edit, so a
# `grep 'has not been read yet'` over the whole stream reports BLOCK on cells that
# actually ALLOWED. Both directions were observed. The cells below parse
# stream-json and read only tool_result blocks.
#
# AUTH: `drive()` runs `claude -p` under a SANDBOX CLAUDE_CONFIG_DIR for isolation.
# A fresh config dir is LOGGED OUT unless ANTHROPIC_API_KEY is in the env.
# THE KEY IS AVAILABLE ON THIS HOST: `~/.env-keys` (0600). A session reporting it
# unset holds a stale launch-env snapshot, not a missing key — `dhx-keys status`
# says STALE-restart. No restart needed for a probe, which is a subprocess:
#   set -a; . ~/.env-keys; set +a
#
# WHY NOT SEED OAUTH CREDENTIALS (rejected — 2026-05-24, measured): copying a live
# ~/.claude/.credentials.json into the sandbox authenticated once, then the
# identical copy 401'd minutes later — OAuth refresh-token rotation. The sandboxed
# claude consumes the refresh token, rotates it, writes the new one into the
# throwaway dir (lost), and the provider invalidates the old one — leaving the
# SOURCE credential stale. Only ANTHROPIC_API_KEY is a safe subprocess-auth path.
#
# NOTE: a sandbox config dir carries no `model` setting, so cells 1/2 run the
# ACCOUNT default. That is deliberate — the outcome JSON records the model the
# init event actually reported (`observed_model`), so the verdict is never read
# without knowing what it was measured against.
#
# Operator-invoked. Outcome JSON → tests/probes/.results/v1.x-option-c/<cc-version>/.
#
# SAFE_FOR_LIVE: no    (spawns claude -p subprocesses; sandbox CLAUDE_CONFIG_DIR + mktemp targets)
# RUNTIME: ~90-180s    (three claude -p turns)
set -uo pipefail

LEGACY_CONTROL_MODEL="claude-sonnet-4-5"   # in R → guard active → must BLOCK
BLOCK_RE='has not been read yet'
AUTH_FAIL_RE='Not logged in|Please run /login|Invalid API key|invalid x-api-key|authentication_error|authentication_failed|Invalid authentication credentials|Failed to authenticate|api_error_status":401|Credit balance is too low|OAuth token has expired'

SANDBOX=$(mktemp -d)
WORK=$(mktemp -d)
trap 'rm -rf "$SANDBOX" "$WORK"' EXIT

CC_VERSION=$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
OBSERVED_MODEL="unknown"

emit_outcome() { # $1 = conclusion, $2 = note
  local outdir="tests/probes/.results/v1.x-option-c/${CC_VERSION}"
  if ! mkdir -p "$outdir" 2>/dev/null; then
    echo "WARN: cannot create $outdir — outcome not recorded" >&2; return
  fi
  printf '{"probe":"read-guard-native-enforcement-tripwire","cc_version":"%s","conclusion":"%s","observed_model":"%s","legacy_control_model":"%s","path_reachable":true,"note":"%s","ts":%s}\n' \
    "$CC_VERSION" "$1" "$OBSERVED_MODEL" "$LEGACY_CONTROL_MODEL" "$2" "$(date +%s)" \
    > "$outdir/outcome.json" 2>/dev/null \
    || echo "WARN: cannot write $outdir/outcome.json" >&2
}

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "SKIP read-guard-native-enforcement-tripwire: no ANTHROPIC_API_KEY (it lives in ~/.env-keys — 'set -a; . ~/.env-keys; set +a' then re-run)"
  emit_outcome "skipped" "no ANTHROPIC_API_KEY (credentials_file is not a safe sandbox-auth path)"
  exit 0
fi

# Drive one claude -p turn: the named tool on an out-of-band file, no prior Read,
# on a REACHABLE path (--add-dir) with the full toolset. Both are load-bearing —
# withholding either re-creates the false pass this rewrite fixes.
drive() { # $1 = tool (Edit|Write), $2 = target path, $3 = model ("" = account default)
  local tool="$1" tgt="$2" model="$3" prompt
  local -a model_arg=(); [ -n "$model" ] && model_arg=(--model "$model")
  if [ "$tool" = "Edit" ]; then
    prompt="Use the Edit tool to change the first line of ${tgt} from 'a' to 'A'. Do NOT read the file first — attempt the Edit directly. If the tool errors, report the exact error text."
  else
    prompt="Use the Write tool to overwrite ${tgt} with the single line 'Z'. Do NOT read the file first — attempt the Write directly. If the tool errors, report the exact error text."
  fi
  CLAUDE_CONFIG_DIR="$SANDBOX/.claude" timeout 180 \
    claude -p "$prompt" --output-format stream-json --include-hook-events --verbose \
      --permission-mode acceptEdits --add-dir "$WORK" "${model_arg[@]}" 2>&1 || true
}

# Extract the init event's model id from a captured stream.
stream_model() { python3 -c '
import json,sys
for line in sys.stdin:
    line=line.strip()
    if not line.startswith("{"): continue
    try: d=json.loads(line)
    except Exception: continue
    if d.get("type")=="system" and d.get("subtype")=="init":
        print(d.get("model","unknown")); break
' <<< "$1" 2>/dev/null || echo unknown; }

# Concatenate ONLY tool_result payloads — never the model's prose (see header).
stream_tool_results() { python3 -c '
import json,sys
for line in sys.stdin:
    line=line.strip()
    if not line.startswith("{"): continue
    try: d=json.loads(line)
    except Exception: continue
    if d.get("type")!="user": continue
    cont=d.get("message",{}).get("content")
    if not isinstance(cont,list): continue
    for c in cont:
        if c.get("type")=="tool_result": print(json.dumps(c.get("content")))
' <<< "$1" 2>/dev/null; }

FAIL=0
PASS_COUNT=0
INCONCLUSIVE=0
CONTROL_BLOCKED=0

# Classify one cell from its tool_result payloads only.
check_cell() { # $1 = label, $2 = raw stream, $3 = allow-regex, $4 = role (live|control)
  local label="$1" out="$2" allow_re="$3" role="$4" results
  if grep -qiE "$AUTH_FAIL_RE" <<< "$out"; then
    echo "SKIP $label → subprocess could not authenticate — inconclusive"
    INCONCLUSIVE=1; return
  fi
  results=$(stream_tool_results "$out")
  if [ -z "$results" ]; then
    echo "WARN $label → no tool_result in stream (model declined the tool); inconclusive"
    INCONCLUSIVE=1; return
  fi
  if grep -qi "$BLOCK_RE" <<< "$results"; then
    echo "OK   $label → CC blocked (native enforcement present)"
    [ "$role" = "control" ] && CONTROL_BLOCKED=1 || PASS_COUNT=$((PASS_COUNT + 1))
    return
  fi
  if grep -qiE "$allow_re" <<< "$results"; then
    if [ "$role" = "control" ]; then
      echo "WARN $label → POSITIVE CONTROL did not block; the harness is not measuring enforcement — inconclusive"
      INCONCLUSIVE=1
    else
      echo "FAIL $label → NO native block on a reachable path (enforcement absent for this model)"
      FAIL=1
    fi
    return
  fi
  echo "WARN $label inconclusive (unrecognized tool_result); re-run or inspect stream"
  INCONCLUSIVE=1
}

EDIT_ALLOW_RE='updated successfully|has been updated'
WRITE_ALLOW_RE='wrote|has been (written|created|updated)'

# Cell 1 — live/default model, Edit on an unread, out-of-band-created file.
EDIT_TGT="$WORK/tripwire-edit.txt"; printf 'a\nb\nc\n' > "$EDIT_TGT"
OUT1=$(drive Edit "$EDIT_TGT" "")
OBSERVED_MODEL=$(stream_model "$OUT1")
check_cell "Edit on unread file (model=$OBSERVED_MODEL)" "$OUT1" "$EDIT_ALLOW_RE" live

# Cell 2 — live/default model, Write on an unread, out-of-band-created EXISTING file.
WRITE_TGT="$WORK/tripwire-write.txt"; printf 'a\nb\nc\n' > "$WRITE_TGT"
check_cell "Write on unread existing file (model=$OBSERVED_MODEL)" "$(drive Write "$WRITE_TGT" "")" "$WRITE_ALLOW_RE" live

# Cell 3 — POSITIVE CONTROL. A model inside R, where the guard is still active.
# Its BLOCK is what makes an ALLOW above trustworthy rather than a broken harness.
CTRL_TGT="$WORK/tripwire-control.txt"; printf 'a\nb\nc\n' > "$CTRL_TGT"
check_cell "CONTROL: Edit on unread file (model=$LEGACY_CONTROL_MODEL)" "$(drive Edit "$CTRL_TGT" "$LEGACY_CONTROL_MODEL")" "$EDIT_ALLOW_RE" control

# --- Roll-up. ---
if [ "$FAIL" -ne 0 ]; then
  if [ "$CONTROL_BLOCKED" -ne 1 ]; then
    echo "SKIP read-guard-native-enforcement-tripwire: an ALLOW was observed but the positive control did not block — the measurement is not trustworthy. No verdict."
    emit_outcome "skipped" "allow observed but legacy-model control failed to block"
    exit 0
  fi
  echo "CC did NOT block an unread Edit/Write on a reachable path for ${OBSERVED_MODEL}, while ${LEGACY_CONTROL_MODEL} still blocked. The Option C collapse removed dhx's strong advisory assuming this block holds; that assumption is not in force for this model. Revisit docs/decisions.md Option C row + HP-058."
  emit_outcome "supersession_found_revive_signal" "guard skipped for ${OBSERVED_MODEL}; legacy control blocked"
  exit 1
fi

if [ "$PASS_COUNT" -eq 2 ] && [ "$CONTROL_BLOCKED" -eq 1 ]; then
  echo "[PASS] read-guard-native-enforcement-tripwire: CC native enforcement holds for ${OBSERVED_MODEL} (Edit + Write blocked on a reachable path; control blocked)"
  emit_outcome "premise_holds_collapse_warranted" "CC blocked unread Edit and Write for ${OBSERVED_MODEL}"
  exit 0
fi

echo "SKIP read-guard-native-enforcement-tripwire: inconclusive — ${PASS_COUNT}/2 live cells blocked, control_blocked=${CONTROL_BLOCKED}. No trustworthy baseline; re-run with working auth."
emit_outcome "skipped" "inconclusive: ${PASS_COUNT}/2 live cells blocked, control_blocked=${CONTROL_BLOCKED}"
exit 0
