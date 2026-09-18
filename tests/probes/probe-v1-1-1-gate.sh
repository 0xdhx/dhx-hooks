#!/bin/bash
# probe-v1-1-1-gate.sh — 5-gate verifier for v1.1.1 legacy ~/.claude/read-once/
#                        readback retirement (Phase 7 closure doctrine artifact).
#
# RUNTIME: ~2s
#
# Invariant exercised: post-`523d3ec` (2026-05-03) v1.1.1 readback removal
# state holds — no resurrection mechanism (stale-snapshot CC process,
# settings.json restoration, legacy writer firing) is currently active.
# Provides on-demand re-verifiability for any future doubt.
#
# Five gates (all read-only):
#   1. >1 week post `bc45a2e` (epoch 1777222640 = 2026-04-26 11:57:20 CDT)
#   2. `bash scripts/verify-hooks.sh` reports green (exit 0)
#   3. legacy ~/.claude/read-once/reads.jsonl mtime older than eldest CC
#      `bin/claude` process start time (NOT just >2h — HP-017 evidence row
#      proved 9.5h delayed restoration)
#   4. no `pgrep -f "bin/claude"` process predates bc45a2e's commit time
#   5. zero `read-once/(hook|compact).sh` references in ~/.ccs/shared/settings.json
#      AND <repo>/config/settings.json (D-22 jq filter from `bc45a2e`)
#
# Convention A exit semantics:
#   0 = all 5 gates green
#   1 = any gate failed (fail-closed default)
#   2 = indeterminate (jq/git/pgrep missing, settings.json unparseable, ps unreadable)
#
# Backs:
#   - .planning/REQUIREMENTS.md LEGACY-01
#   - docs/decisions.md 2026-05-04 row (Phase 7 LEGACY closure)
#   - .planning/research/PITFALLS.md Pitfall R1 (4-gate doctrine origin)
#   - docs/hook-patterns.md HP-017 (stale-snapshot clobber mechanism, 9.5h evidence)
#   - docs/hook-patterns.md HP-012 (settings.json loads at session start only)
#   - .planning/phases/07-v1-1-1-legacy-path-retirement-legacy/07-CONTEXT.md D-08 (5-gate spec)
#   - .planning/phases/07-v1-1-1-legacy-path-retirement-legacy/07-CONTEXT.md D-22 (jq filter origin)
#   - docs/templates/retirement-gate-pattern.md (template; this probe is first caller)
#
# Companion failure-state test: tests/test-probe-v1-1-1-gate.sh
# (env-var-overridable; asserts each gate's red path produces correct exit code).
#
# Hardcoded for v1.1.1 per CONTEXT.md D-02 (rule of three; copy-edit for
# future retirements per docs/templates/retirement-gate-pattern.md).
#
# Run directly:
#   bash tests/probes/probe-v1-1-1-gate.sh
#   echo $?  # 0/1/2 per Convention A

# SAFE_FOR_LIVE: yes   (read-only: git rev-parse/log, stat, pgrep, ps,
#                       jq -e against settings.json, bash scripts/verify-hooks.sh
#                       which is also read-only by design)
set -uo pipefail        # D-25 doctrine: NO errexit in probes; rc=$? capture instead

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0
INDETERMINATE=0

# Hardcoded constants (D-02; future retirements copy-edit)
BC45A2E_EPOCH=1777222640    # 2026-04-26 11:57:20 CDT (bc45a2e commit time)
SEVEN_DAYS=604800

# ----- Helper: ONE process-table snapshot of live CC bin/claude procs ------
# Emits `<pid><TAB><lstart>` per matching process. ONE `ps` read, so every pid
# arrives already carrying its own start time.
#
# WHY A SNAPSHOT. Gates 3 and 4 previously ran `pgrep -f bin/claude` and then a
# separate `ps -o lstart= -p <pid>` per pid. A CC process exiting between the two
# reads returned an empty lstart, and Gate 4 counted that as INDETERMINATE —
# making the whole probe exit 2 and, inside the pre-commit hermetic tier, block
# every session's probe-touching commit. Measured 2026-09-18: 15/15 runs clean at
# rest, but under churn of short-lived processes matching `bin/claude`, 22 of 40
# runs reported `PASS: 4  FAIL: 0  INDETERMINATE: 1` with Gate 4 the sole
# indeterminate — the exact signature observed in the tier that day. Gate 3
# survived the same churn only because its walk happened to `continue` past a
# vanished pid instead of flagging it.
#
# A pid that has exited is not a LIVE process, which is the only thing either
# gate asks about, so the right answer was never "indeterminate" — it was "not
# in the snapshot". The window is now closed rather than tolerated.
#
# Honors DHX_PROBE_PGREP_FAKE_OUTPUT (canned newline-separated PID list) and
# DHX_PROBE_PS_LSTART_OVERRIDE (canned lstart string) for companion-test
# injection. Nothing in tests/ or scripts/ exercised either var as of 2026-09-18.
# Return: 0 = one or more lines emitted; 1 = no CC procs; 2 = ps unusable.
cc_proc_snapshot() {
  local pid lstart
  if [[ -n "${DHX_PROBE_PGREP_FAKE_OUTPUT-}" ]]; then
    for pid in $DHX_PROBE_PGREP_FAKE_OUTPUT; do
      if [[ -n "${DHX_PROBE_PS_LSTART_OVERRIDE-}" ]]; then
        lstart="$DHX_PROBE_PS_LSTART_OVERRIDE"
      else
        lstart="$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      fi
      printf '%s\t%s\n' "$pid" "$lstart"
    done
    return 0
  fi

  # lstart is exactly 5 whitespace-separated fields (DoW Mon DD HH:MM:SS YYYY),
  # so pid is $1 and lstart is $2..$6 whatever the command line holds. The awk
  # program's own argv carries `bin\/claude`, not `bin/claude`, so it cannot
  # match itself; $1 != own-pid drops this probe's own process tree anyway.
  local out
  out="$(ps -eo pid=,lstart=,args= 2>/dev/null \
    | awk -v self="$$" '/bin\/claude/ && $1 != self { printf "%s\t%s %s %s %s %s\n", $1, $2, $3, $4, $5, $6 }')"
  [[ -z "$out" ]] && return 1
  printf '%s\n' "$out"
  return 0
}

# ----- Helper: eldest live CC bin/claude start time → epoch ------
# Stdout: epoch on success.
# Return: 0 = epoch printed; 1 = no CC procs (treated as gate-pass condition);
#         2 = parse failure (treated as INDETERMINATE).
eldest_cc_epoch() {
  local snap snap_rc oldest_epoch="" pid lstart epoch
  snap="$(cc_proc_snapshot)"; snap_rc=$?
  [[ "$snap_rc" -ne 0 ]] && return "$snap_rc"

  while IFS=$'\t' read -r pid lstart; do
    [[ -z "$pid" ]] && continue
    # Empty only on the injected path; the snapshot pairs pid with lstart.
    [[ -z "$lstart" ]] && continue
    epoch="$(date -d "$lstart" +%s 2>/dev/null)"
    [[ -z "$epoch" ]] && return 2
    if [[ -z "$oldest_epoch" || "$epoch" -lt "$oldest_epoch" ]]; then
      oldest_epoch="$epoch"
    fi
  done <<< "$snap"

  # Every entry skipped for want of a start time means no process the gate can
  # call live — the same condition as an empty snapshot, so it returns 1 (a
  # gate-pass) rather than 2. Returning 2 here was what made Gate 3 report
  # INDETERMINATE on precisely the input Gate 4 now calls GREEN, and that
  # disagreement between two gates reading ONE pid list is what made the
  # original 2026-09-18 flicker so hard to attribute.
  [[ -z "$oldest_epoch" ]] && return 1
  echo "$oldest_epoch"
  return 0
}

# ============================================================
# Gates 1-5
# ============================================================

# ----- Gate 1: > 1 week post bc45a2e --------------------------------------
# D-25 (WR-04): rc=$? captures rc directly; errexit never enabled.
NOW=$(date +%s)
BC_EPOCH_DYNAMIC=$(git -C "$REPO" log --format='%ct' -1 bc45a2e 2>/dev/null)
git_rc=$?
if [[ "$git_rc" -ne 0 || -z "$BC_EPOCH_DYNAMIC" || "$BC_EPOCH_DYNAMIC" != "$BC45A2E_EPOCH" ]]; then
  echo "Gate 1 INDETERMINATE: git lookup of bc45a2e failed or hash drift detected (dynamic=$BC_EPOCH_DYNAMIC, hardcoded=$BC45A2E_EPOCH)"
  INDETERMINATE=$((INDETERMINATE+1))
else
  EFFECTIVE_BC_EPOCH="${DHX_PROBE_BC_EPOCH_OVERRIDE:-$BC45A2E_EPOCH}"
  ELAPSED=$((NOW - EFFECTIVE_BC_EPOCH))
  if [[ "$ELAPSED" -lt "$SEVEN_DAYS" ]]; then
    echo "Gate 1 RED: only $((ELAPSED / 86400))d elapsed since bc45a2e (need 7d)"
    FAIL=$((FAIL+1))
  else
    echo "Gate 1 GREEN: $((ELAPSED / 86400))d elapsed since bc45a2e"
    PASS=$((PASS+1))
  fi
fi

# ----- Gate 2: verify-hooks.sh exits green --------------------------------
if [[ -n "${DHX_PROBE_VERIFY_HOOKS_RC-}" ]]; then
  vh_rc="$DHX_PROBE_VERIFY_HOOKS_RC"
else
  bash "$REPO/scripts/verify-hooks.sh" >/dev/null 2>&1
  vh_rc=$?
fi
if [[ "$vh_rc" -eq 0 ]]; then
  echo "Gate 2 GREEN: verify-hooks.sh exited 0"
  PASS=$((PASS+1))
else
  echo "Gate 2 RED: verify-hooks.sh exited $vh_rc"
  FAIL=$((FAIL+1))
fi

# ----- Gate 3: legacy mtime older than eldest CC process ------------------
LEGACY_FILE="${DHX_PROBE_LEGACY_FILE:-$HOME/.claude/read-once/reads.jsonl}"
if [[ ! -e "$LEGACY_FILE" && -z "${DHX_PROBE_LEGACY_MTIME_OVERRIDE-}" ]]; then
  echo "Gate 3 GREEN: legacy file absent ($LEGACY_FILE) — strongest possible signal"
  PASS=$((PASS+1))
else
  if [[ -n "${DHX_PROBE_LEGACY_MTIME_OVERRIDE-}" ]]; then
    LEGACY_MTIME="$DHX_PROBE_LEGACY_MTIME_OVERRIDE"
  else
    LEGACY_MTIME="$(stat -c %Y "$LEGACY_FILE" 2>/dev/null)"
  fi
  if [[ -z "$LEGACY_MTIME" ]]; then
    echo "Gate 3 INDETERMINATE: could not stat $LEGACY_FILE"
    INDETERMINATE=$((INDETERMINATE+1))
  else
    ELDEST_OUT="$(eldest_cc_epoch)"
    eldest_rc=$?
    case "$eldest_rc" in
      0)
        ELDEST_CC_EPOCH="$ELDEST_OUT"
        if [[ "$LEGACY_MTIME" -lt "$ELDEST_CC_EPOCH" ]]; then
          echo "Gate 3 GREEN: legacy mtime $LEGACY_MTIME < eldest CC epoch $ELDEST_CC_EPOCH"
          PASS=$((PASS+1))
        else
          echo "Gate 3 RED: legacy mtime $LEGACY_MTIME >= eldest CC epoch $ELDEST_CC_EPOCH (legacy writer may have fired post-restart)"
          FAIL=$((FAIL+1))
        fi
        ;;
      1)
        echo "Gate 3 GREEN: no live CC procs to compare against (legacy mtime $LEGACY_MTIME)"
        PASS=$((PASS+1))
        ;;
      *)
        echo "Gate 3 INDETERMINATE: eldest_cc_epoch helper failed (rc=$eldest_rc)"
        INDETERMINATE=$((INDETERMINATE+1))
        ;;
    esac
  fi
fi

# ----- Gate 4: no live bin/claude proc predates bc45a2e -------------------
gate4_snap="$(cc_proc_snapshot)"; gate4_snap_rc=$?

if [[ "$gate4_snap_rc" -eq 1 || -z "$gate4_snap" ]]; then
  echo "Gate 4 GREEN: no live bin/claude procs in the process-table snapshot"
  PASS=$((PASS+1))
elif [[ "$gate4_snap_rc" -ne 0 ]]; then
  echo "Gate 4 INDETERMINATE: process-table snapshot unreadable (rc=$gate4_snap_rc)"
  INDETERMINATE=$((INDETERMINATE+1))
else
  gate4_failed_pid=""
  gate4_failed_epoch=""
  gate4_unparsed_pid=""
  while IFS=$'\t' read -r pid lstart; do
    [[ -z "$pid" ]] && continue
    if [[ -z "$lstart" ]]; then
      # Reachable only via DHX_PROBE_PGREP_FAKE_OUTPUT. A pid the snapshot could
      # not pair with a start time is not a live process, which is the only thing
      # this gate asks about — so it is skipped, not counted indeterminate.
      continue
    fi
    epoch="$(date -d "$lstart" +%s 2>/dev/null)"
    if [[ -z "$epoch" ]]; then
      # A start time the snapshot DID produce but `date` cannot read is a real
      # parse failure, not a vanished process. That is worth an INDETERMINATE.
      gate4_unparsed_pid="$pid"
      continue
    fi
    if [[ "$epoch" -lt "$BC45A2E_EPOCH" ]]; then
      gate4_failed_pid="$pid"
      gate4_failed_epoch="$epoch"
      break
    fi
  done <<< "$gate4_snap"

  if [[ -n "$gate4_failed_pid" ]]; then
    echo "Gate 4 RED: PID $gate4_failed_pid lstart epoch $gate4_failed_epoch < bc45a2e epoch $BC45A2E_EPOCH (HP-017 stale-snapshot risk)"
    FAIL=$((FAIL+1))
  elif [[ -n "$gate4_unparsed_pid" ]]; then
    echo "Gate 4 INDETERMINATE: \`date\` could not parse the start time the snapshot gave for PID $gate4_unparsed_pid — a locale/format fault, NOT a process that exited mid-read (the snapshot pairs pid with start time in one ps call, so that race cannot reach here)"
    INDETERMINATE=$((INDETERMINATE+1))
  else
    echo "Gate 4 GREEN: all live bin/claude procs started post-bc45a2e ($BC45A2E_EPOCH)"
    PASS=$((PASS+1))
  fi
fi

# ----- Gate 5: zero read-once/(hook|compact).sh refs in both settings ----
# D-22 byte-identical jq filter from bc45a2e — DO NOT REWORD.
SHARED_SETTINGS="${DHX_PROBE_SHARED_SETTINGS:-$HOME/.ccs/shared/settings.json}"
REPO_SETTINGS="${DHX_PROBE_REPO_SETTINGS:-$REPO/config/settings.json}"

classify_jq_rc() {
  # Args: <gate-label> <rc>; echoes status; sets $1_status global.
  local label="$1" rc="$2"
  case "$rc" in
    0) echo "green" ;;
    1) echo "red" ;;
    *) echo "indeterminate" ;;
  esac
}

jq -e '[.. | strings? | select(test("read-once/(hook|compact).sh"))] | length == 0' "$SHARED_SETTINGS" >/dev/null 2>&1
gate5a_rc=$?
jq -e '[.. | strings? | select(test("read-once/(hook|compact).sh"))] | length == 0' "$REPO_SETTINGS" >/dev/null 2>&1
gate5b_rc=$?

gate5a_status=$(classify_jq_rc "Gate 5a" "$gate5a_rc")
gate5b_status=$(classify_jq_rc "Gate 5b" "$gate5b_rc")

if [[ "$gate5a_status" == "indeterminate" || "$gate5b_status" == "indeterminate" ]]; then
  echo "Gate 5 INDETERMINATE: shared=$gate5a_status (rc=$gate5a_rc), repo=$gate5b_status (rc=$gate5b_rc) — settings.json unparseable or jq missing"
  INDETERMINATE=$((INDETERMINATE+1))
elif [[ "$gate5a_status" == "red" || "$gate5b_status" == "red" ]]; then
  echo "Gate 5 RED: read-once/(hook|compact).sh references found — shared=$gate5a_status, repo=$gate5b_status"
  FAIL=$((FAIL+1))
else
  echo "Gate 5 GREEN: zero read-once/(hook|compact).sh refs in $SHARED_SETTINGS AND $REPO_SETTINGS"
  PASS=$((PASS+1))
fi

# ----- Summary + exit (Convention A) ------------------------
echo "---"
echo "PASS: $PASS  FAIL: $FAIL  INDETERMINATE: $INDETERMINATE"
if [[ "$INDETERMINATE" -gt 0 ]]; then
  exit_code=2
elif [[ "$FAIL" -gt 0 ]]; then
  exit_code=1
else
  exit_code=0
fi
exit $exit_code
