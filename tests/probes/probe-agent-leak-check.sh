#!/usr/bin/env bash
# probe-agent-leak-check.sh
#
# Regression probe for dhx/dhx-agent-leak-snapshot.sh (PreToolUse:Agent) +
# dhx/dhx-agent-leak-check.sh (SubagentStop, migrated 2026-05-08 from
# PostToolUse:Agent — see decisions.md 2026-05-08 BG-AGENT-1 row).
#
# Invariant pair (D-02 + D-03):
#   PreToolUse:Agent with isolation=worktree writes baseline + sidecar pair to
#     ~/.cache/dhx/agent-leak-${SESSION}-${TIMESTAMP_NS}.{pre,meta.json}
#     under both-or-none atomicity (D-04(c)).
#   SubagentStop globs the session pairs, strict-validates schema fields (D-10),
#     atomically mv-claims the oldest unclaimed sidecar (D-08), restores cwd /
#     isolation / subagent_type from sidecar, runs the diff, removes the
#     consumed pair, and emits LEAK SUSPECTED on divergence.
#
# Both hooks:
#   - silent on non-worktree isolation
#   - silent on malformed JSON
#   - silent when .git missing
#   - paired cleanup: post-hook removes the consumed pair (siblings persist)
#
# 4-state branch (D-04(d)):
#   - both absent → silent (handles HP-012 transition window per SC#10/D-14)
#   - both present → normal compare path
#   - exactly one present → DETECTION GAP
#   - malformed .meta.json (or missing required field per D-10) → DETECTION GAP
#
# Backs: docs/decisions.md 2026-04-19 agent-leak-check row + 2026-04-20
#        detection-gap invariant row + 2026-05-08 BG-AGENT-1 migration row.
# Companion: probe-worktree-write-guard.sh covers the top-level/Skill detector.
#
# Run: bash tests/probes/probe-agent-leak-check.sh

# SAFE_FOR_LIVE: no   (writes baselines under live `$HOME/.cache/dhx/` (session-tag prefixed + trap cleanup, but writes hit the live cache directory))
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
REPO_ROOT="$REPO"
PRE="$REPO/dhx/dhx-agent-leak-snapshot.sh"
POST="$REPO/dhx/dhx-agent-leak-check.sh"

for h in "$PRE" "$POST"; do
  if [[ ! -x "$h" ]]; then
    echo "FAIL hook not found or not executable: $h"
    exit 1
  fi
done

# Isolate probe cache entries so concurrent probes don't collide
SESSION_TAG="probe-$$-$(date +%s%N)"
CACHE="$HOME/.cache/dhx"
mkdir -p "$CACHE"

# Track baseline files we create so cleanup can remove them.
# WR-07: default-initialize TMP and BASELINES BEFORE installing the EXIT trap.
# Under `set -u`, if the script aborts between `trap cleanup EXIT` (below) and
# the `mktemp -d` assignment (further down), the trap fires and references
# `$TMP` — without this default, that's an unbound-variable error inside the
# trap, the trap aborts before reaching the BASELINES sweep, and any partial
# state on disk leaks. Default-init keeps the "trap before allocation"
# robustness pattern intact AND tolerates pre-mktemp aborts.
TMP=""
BASELINES=()

cleanup() {
  [[ -n "${TMP:-}" ]] && rm -rf "$TMP" 2>/dev/null
  for b in "${BASELINES[@]}"; do
    rm -f "$b" 2>/dev/null
  done
  # Defensive sweep for any probe-$$ entries left behind, including .claimed.* artifacts
  shopt -s nullglob
  rm -f "$CACHE/agent-leak-probe-$$-"*.pre "$CACHE/agent-leak-probe-$$-"*.meta.json "$CACHE/agent-leak-probe-$$-"*.meta.json.claimed.* 2>/dev/null
  shopt -u nullglob
}
trap cleanup EXIT

# Seed a minimal fake git repo we can mutate
TMP=$(mktemp -d)
git -C "$TMP" init -q
echo "existing" > "$TMP/baseline.txt"
git -C "$TMP" add baseline.txt >/dev/null 2>&1
git -C "$TMP" -c user.email=probe@test -c user.name=probe commit -q -m "init"

PASS=0
FAIL=0

check() {
  local name="$1" cond="$2"
  if [[ "$cond" == "pass" ]]; then
    echo "OK   $name"
    PASS=$((PASS+1))
  else
    echo "FAIL $name"
    FAIL=$((FAIL+1))
  fi
}

# WR-05: build JSON via `jq -n --arg`, NOT `printf '%s'`. printf-templated
# JSON is unsafe for any input containing `"`, backslash, or control chars —
# the resulting payload would be malformed and the probe's malformed-JSON
# branch [12] would start triggering for the wrong reason in OTHER scenarios.
# Current usage is ASCII-safe (session tags, mktemp paths, hardcoded subagent
# strings), but the production hooks use jq -n --arg by design (snapshot.sh:64);
# matching that pattern in the probe removes a latent foot-gun before a future
# probe extension trips it.
pre_input() {
  local sid="$1" cwd="$2" iso="${3:-worktree}" agent="${4:-test}"
  jq -n --arg sid "$sid" --arg cwd "$cwd" --arg iso "$iso" --arg agent "$agent" \
    '{session_id:$sid, cwd:$cwd, tool_input:{isolation:$iso, subagent_type:$agent}}'
}

post_input() {
  local sid="$1" cwd="$2" agent="${3:-test}"
  # SubagentStop payload (HP-021 verified key set; 4 keys sufficient — check.sh only reads session_id).
  jq -n --arg agent "$agent" --arg sid "$sid" --arg cwd "$cwd" \
    '{agent_type:$agent, session_id:$sid, cwd:$cwd, hook_event_name:"SubagentStop"}'
}

# Helper: append matching baseline + meta files for a session to BASELINES tracking.
track_session_files() {
  local sid="$1"
  shopt -s nullglob
  for f in "$CACHE/agent-leak-${sid}-"*.pre "$CACHE/agent-leak-${sid}-"*.meta.json "$CACHE/agent-leak-${sid}-"*.meta.json.claimed.*; do
    BASELINES+=("$f")
  done
  shopt -u nullglob
}

# === [1] Pre-snapshot creates baseline + sidecar pair (D-03 keying) ===
SID="${SESSION_TAG}-1"
pre_input "$SID" "$TMP" | "$PRE" >/dev/null 2>&1
shopt -s nullglob
BASELINE_FILES=("$CACHE/agent-leak-${SID}-"*.pre)
META_FILES_1=("$CACHE/agent-leak-${SID}-"*.meta.json)
shopt -u nullglob
track_session_files "$SID"
[[ ${#BASELINE_FILES[@]} -ge 1 && -f "${BASELINE_FILES[0]}" ]] && check "[1a] pre-hook writes .pre baseline (D-03 keyed)" pass || check "[1a] pre-hook writes .pre baseline" fail
[[ ${#META_FILES_1[@]} -ge 1 && -f "${META_FILES_1[0]}" ]] && check "[1b] pre-hook writes .meta.json sidecar (D-02 schema)" pass || check "[1b] pre-hook writes .meta.json sidecar" fail
if [[ ${#META_FILES_1[@]} -ge 1 ]]; then
  jq -e '.schema_version == 1 and (.cwd | length > 0) and (.isolation == "worktree") and (.dispatched_at | length > 0)' "${META_FILES_1[0]}" >/dev/null 2>&1 \
    && check "[1c] sidecar matches D-02 schema" pass \
    || check "[1c] sidecar matches D-02 schema" fail
fi

# === [2] Post-check silent when main repo unchanged ===
SID="${SESSION_TAG}-2"
pre_input "$SID" "$TMP" | "$PRE" >/dev/null 2>&1
track_session_files "$SID"
OUT=$(post_input "$SID" "$TMP" | "$POST" 2>/dev/null || true)
[[ -z "$OUT" ]] && check "[2] post-hook silent when clean" pass || check "[2] post-hook silent when clean — emitted: $OUT" fail

# === [3] Post-check warns on new untracked file ===
SID="${SESSION_TAG}-3"
pre_input "$SID" "$TMP" "worktree" "gsd-executor" | "$PRE" >/dev/null 2>&1
track_session_files "$SID"
echo "leaked" > "$TMP/leaked-file.txt"   # simulate leak
OUT=$(post_input "$SID" "$TMP" "gsd-executor" | "$POST" 2>/dev/null || true)
echo "$OUT" | grep -q "LEAK SUSPECTED" && check "[3a] post-hook emits LEAK SUSPECTED" pass || check "[3a] post-hook missing warning" fail
echo "$OUT" | grep -q "leaked-file.txt" && check "[3b] warning includes filename" pass || check "[3b] warning missing filename" fail
echo "$OUT" | grep -q "36182" && check "[3c] warning cites upstream issue" pass || check "[3c] warning missing issue ref" fail
echo "$OUT" | grep -q "gsd-executor" && check "[3d] warning names subagent_type from sidecar" pass || check "[3d] warning missing subagent_type" fail
echo "$OUT" | grep -q "stash" && check "[3e] warning includes recovery hint" pass || check "[3e] warning missing recovery hint" fail
rm -f "$TMP/leaked-file.txt"

# === [4] Non-worktree isolation → pre-hook silent, no baseline written ===
SID="${SESSION_TAG}-4"
pre_input "$SID" "$TMP" "none" | "$PRE" >/dev/null 2>&1
shopt -s nullglob
NONE_BASELINES=("$CACHE/agent-leak-${SID}-"*.pre)
NONE_METAS=("$CACHE/agent-leak-${SID}-"*.meta.json)
shopt -u nullglob
[[ ${#NONE_BASELINES[@]} -eq 0 && ${#NONE_METAS[@]} -eq 0 ]] && check "[4] pre-hook skips isolation=none" pass || check "[4] pre-hook fired on isolation=none" fail

# === [5a] Post-hook silent when no sidecar exists for session (D-14/SC#10 transition window) ===
# (After 2026-05-08 migration: no .meta.json AND no .pre for this session → silent skip.
#  Pre-existing legacy ${SESSION}.pre files from old PostToolUse:Agent registration
#  are silently skipped — graceful no-crash transition window per HP-012.)
SID="${SESSION_TAG}-ghost"
OUT=$(post_input "$SID" "$TMP" | "$POST" 2>/dev/null || true)
[[ -z "$OUT" ]] && check "[5a] D-14/SC#10: post-hook silent when no sidecar exists (transition window)" pass || check "[5a] post-hook NOT silent when no sidecar — emitted: $OUT" fail

# === [5b] Orphan .pre file (sidecar missing) → DETECTION GAP per D-13 ===
SID="${SESSION_TAG}-ghost-orphan"
ORPHAN_TS="$(date +%s%N)"
ORPHAN_PRE="$CACHE/agent-leak-${SID}-${ORPHAN_TS}.pre"
: > "$ORPHAN_PRE"  # empty .pre, no .meta.json
BASELINES+=("$ORPHAN_PRE")
OUT=$(post_input "$SID" "$TMP" | "$POST" 2>/dev/null || true)
echo "$OUT" | grep -q "DETECTION GAP" && check "[5b] D-13: orphan .pre emits DETECTION GAP" pass || check "[5b] D-13: orphan .pre missing detection-gap diagnostic" fail
echo "$OUT" | grep -q "orphan baseline" && check "[5b-msg] orphan-detection message uses 'orphan baseline' wording" pass || check "[5b-msg] orphan-detection message wording" fail

# === [5c] Nested-worktree CWD via SIDECAR cwd → silent (D-04(e) sidecar-cwd skip) ===
# Snapshot hook skips at snapshot:38 when dispatching FROM inside a worktree;
# check.sh re-derives nested-skip from the SIDECAR's cwd, NOT SubagentStop stdin's.
SID="${SESSION_TAG}-ghost-nested"
NESTED_5C="$TMP/.claude/worktrees/agent-5c"
mkdir -p "$NESTED_5C"
# WR-06: do NOT swallow `cp` failures. The earlier `2>/dev/null || true` masked
# disk-full / permission errors — when cp failed, snapshot.sh exited at the
# .git-presence check (snapshot.sh:34) instead of the nested-worktree skip
# (snapshot.sh:38). The probe assertion "no baseline written" then passed for
# the WRONG reason: it was actually testing the .git check, not the
# nested-worktree skip. Fail loudly on fixture-setup failures.
cp -r "$TMP/.git" "$NESTED_5C/"
[[ -d "$NESTED_5C/.git" ]] || { echo "FAIL fixture: $NESTED_5C/.git not seeded"; exit 1; }
# Snapshot will see nested cwd at line 38 and silently skip — no baseline+sidecar written.
pre_input "$SID" "$NESTED_5C" | "$PRE" >/dev/null 2>&1
track_session_files "$SID"
OUT=$(post_input "$SID" "$NESTED_5C" | "$POST" 2>/dev/null || true)
[[ -z "$OUT" ]] && check "[5c] nested-worktree dispatch: snapshot skipped → check silent" pass || check "[5c] nested-worktree dispatch: check emitted: $OUT" fail

# === [6] Malformed JSON → both hooks silent ===
OUT=$(echo 'not json' | "$PRE" 2>/dev/null || true)
[[ -z "$OUT" ]] && check "[6a] pre-hook silent on malformed JSON" pass || check "[6a] pre-hook output on malformed JSON" fail
OUT=$(echo 'not json' | "$POST" 2>/dev/null || true)
[[ -z "$OUT" ]] && check "[6b] post-hook silent on malformed JSON" pass || check "[6b] post-hook output on malformed JSON" fail

# === [7] Post-hook removes consumed pair after running ===
SID="${SESSION_TAG}-7"
pre_input "$SID" "$TMP" | "$PRE" >/dev/null 2>&1
track_session_files "$SID"
post_input "$SID" "$TMP" | "$POST" >/dev/null 2>&1
shopt -s nullglob
REMAINING_PRE=("$CACHE/agent-leak-${SID}-"*.pre)
REMAINING_META=("$CACHE/agent-leak-${SID}-"*.meta.json)
shopt -u nullglob
[[ ${#REMAINING_PRE[@]} -eq 0 && ${#REMAINING_META[@]} -eq 0 ]] && check "[7] consumed pair cleaned up post-compare" pass || check "[7] consumed pair leaked (pre=${#REMAINING_PRE[@]}, meta=${#REMAINING_META[@]})" fail

# === [8] Pre-hook skips when cwd is already inside a worktree ===
SID="${SESSION_TAG}-8"
# Seed fake worktree path under the tmp repo
mkdir -p "$TMP/.claude/worktrees/agent-inner"
# WR-06: same rationale as [5c] — failed `cp` masquerading as nested-worktree
# skip is testing the wrong code path. Fail loudly on fixture-setup failures.
cp -r "$TMP/.git" "$TMP/.claude/worktrees/agent-inner/"
[[ -d "$TMP/.claude/worktrees/agent-inner/.git" ]] || { echo "FAIL fixture: agent-inner/.git not seeded"; exit 1; }
pre_input "$SID" "$TMP/.claude/worktrees/agent-inner" | "$PRE" >/dev/null 2>&1
shopt -s nullglob
NESTED_PRES=("$CACHE/agent-leak-${SID}-"*.pre)
NESTED_METAS=("$CACHE/agent-leak-${SID}-"*.meta.json)
shopt -u nullglob
[[ ${#NESTED_PRES[@]} -eq 0 && ${#NESTED_METAS[@]} -eq 0 ]] && check "[8] pre-hook skips nested worktree cwd" pass || check "[8] pre-hook fired for nested worktree cwd" fail

# === [9] Cross-scenario: scenario_3's pair was cleaned up ===
shopt -s nullglob
S3_REMAINING=("$CACHE/agent-leak-${SESSION_TAG}-3-"*.pre "$CACHE/agent-leak-${SESSION_TAG}-3-"*.meta.json)
shopt -u nullglob
[[ ${#S3_REMAINING[@]} -eq 0 ]] && check "[9] scenario 3 pair also cleaned" pass || check "[9] scenario 3 pair leaked (count=${#S3_REMAINING[@]})" fail

# === [10] backgrounded-dispatch: PreToolUse:Agent fires snapshot, SubagentStop fires check (BG-AGENT-1-05) ===
SID="${SESSION_TAG}-bg"
pre_input "$SID" "$TMP" "worktree" "gsd-executor" | "$PRE" >/dev/null 2>&1
track_session_files "$SID"
echo "bg-leaked" > "$TMP/bg-leaked-file.txt"  # simulate leak between dispatch and completion
OUT=$(post_input "$SID" "$TMP" "gsd-executor" | "$POST" 2>/dev/null || true)
echo "$OUT" | grep -q "LEAK SUSPECTED" && check "[10a] backgrounded-dispatch emits LEAK SUSPECTED" pass || check "[10a] backgrounded-dispatch emits LEAK SUSPECTED" fail
echo "$OUT" | grep -q "bg-leaked-file.txt" && check "[10b] backgrounded-dispatch warning includes leak filename" pass || check "[10b] backgrounded-dispatch warning includes leak filename" fail
echo "$OUT" | grep -q "gsd-executor" && check "[10c] backgrounded-dispatch warning names subagent_type from sidecar" pass || check "[10c] backgrounded-dispatch warning names subagent_type from sidecar" fail
echo "$OUT" | grep -q "isolation=worktree" && check "[10d] backgrounded-dispatch warning names isolation from sidecar" pass || check "[10d] backgrounded-dispatch warning names isolation from sidecar" fail
rm -f "$TMP/bg-leaked-file.txt"

# === [11] parallel-dispatch: 3 snapshots, 3 completions, distinct pairs (D-03/D-08) ===
SID="${SESSION_TAG}-par"
pre_input "$SID" "$TMP" "worktree" "exec-1" | "$PRE" >/dev/null 2>&1
sleep 0.05   # D-16: CI timer-resolution safety margin (was 0.005)
pre_input "$SID" "$TMP" "worktree" "exec-2" | "$PRE" >/dev/null 2>&1
sleep 0.05   # D-16: CI timer-resolution safety margin (was 0.005)
pre_input "$SID" "$TMP" "worktree" "exec-3" | "$PRE" >/dev/null 2>&1
track_session_files "$SID"
shopt -s nullglob
META_BEFORE=("$CACHE/agent-leak-${SID}-"*.meta.json)
shopt -u nullglob
[[ ${#META_BEFORE[@]} -eq 3 ]] && check "[11a] 3 snapshots produce 3 sidecar pairs" pass || check "[11a] 3 snapshots produce 3 sidecar pairs (got ${#META_BEFORE[@]})" fail

# WR-03 / WR-01: assert D-08 identity using the canonical FIFO key — the
# filename's TIMESTAMP_NS suffix (nanosecond resolution from `date +%s%N`).
# Previously this used `ls -t | tail -1` (mtime-based), which was flaky around
# 1-second wall-clock boundaries because mtime can have second-resolution on
# some filesystems and the indirect coupling to second-resolution `dispatched_at`
# in production code (WR-01 fix) means a probe that disagrees with check.sh's
# selection key produces silent false positives. The fix:
#   - Pick "oldest" by smallest TIMESTAMP_NS suffix among the filenames.
#   - This matches check.sh's fifo_key() semantics exactly (see WR-01 fix).
oldest_meta_by_filename() {
  # Reads sidecar paths from stdin (one per line); writes the path with the
  # smallest TIMESTAMP_NS suffix (per filename `agent-leak-${SID}-${NS}.meta.json`).
  local path best_ns="" best_path="" ns
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    ns="${path##*/}"
    ns="${ns%.meta.json}"
    ns="${ns##agent-leak-${SID}-}"
    if [[ -z "$best_ns" || "$ns" < "$best_ns" ]]; then
      best_ns="$ns"
      best_path="$path"
    fi
  done
  printf '%s' "$best_path"
}

# Capture the OLDEST sidecar's path BEFORE first SubagentStop fires.
shopt -s nullglob
META_GLOB=("$CACHE/agent-leak-${SID}-"*.meta.json)
shopt -u nullglob
OLDEST_BEFORE=$(printf '%s\n' "${META_GLOB[@]}" | oldest_meta_by_filename)

post_input "$SID" "$TMP" | "$POST" >/dev/null 2>&1
# D-08 identity-based assertion: the oldest sidecar should be GONE
# (consumed pair removed at end of normal compare path), and the .pre half also gone.
PAIRED_PRE_BEFORE="${OLDEST_BEFORE%.meta.json}.pre"
[[ ! -f "$OLDEST_BEFORE" && ! -f "$PAIRED_PRE_BEFORE" ]] && check "[11b] D-08: first completion atomically claimed and consumed the smallest-ns pair" pass || check "[11b] D-08: first completion claimed wrong pair (smallest-ns still on disk: $OLDEST_BEFORE)" fail

shopt -s nullglob; META_AFTER1=("$CACHE/agent-leak-${SID}-"*.meta.json); shopt -u nullglob
[[ ${#META_AFTER1[@]} -eq 2 ]] && check "[11c] siblings persist after first completion" pass || check "[11c] siblings persist after first completion (got ${#META_AFTER1[@]})" fail

# Second completion claims the next-smallest-ns (different timestamp from first).
SECOND_OLDEST=$(printf '%s\n' "${META_AFTER1[@]}" | oldest_meta_by_filename)
[[ "$SECOND_OLDEST" != "$OLDEST_BEFORE" ]] && check "[11d] D-08: second completion's pair has a different ns timestamp" pass || check "[11d] D-08: second completion picked same path as first (impossible without reuse)" fail

post_input "$SID" "$TMP" | "$POST" >/dev/null 2>&1
post_input "$SID" "$TMP" | "$POST" >/dev/null 2>&1
shopt -s nullglob; META_AFTER3=("$CACHE/agent-leak-${SID}-"*.meta.json); shopt -u nullglob
[[ ${#META_AFTER3[@]} -eq 0 ]] && check "[11e] all 3 completions consume all 3 pairs" pass || check "[11e] all 3 completions consume all 3 pairs (got ${#META_AFTER3[@]})" fail

# === [12] malformed .meta.json → DETECTION GAP, distinct from missing (D-02) ===
SID="${SESSION_TAG}-mal"
pre_input "$SID" "$TMP" | "$PRE" >/dev/null 2>&1
shopt -s nullglob; META_FILES=("$CACHE/agent-leak-${SID}-"*.meta.json); shopt -u nullglob
META_FILE="${META_FILES[0]:-}"
[[ -n "$META_FILE" ]] || check "[12-pre] valid sidecar present" fail
echo "not json {" > "$META_FILE"   # corrupt the meta file
track_session_files "$SID"
OUT=$(post_input "$SID" "$TMP" | "$POST" 2>/dev/null || true)
echo "$OUT" | grep -q "DETECTION GAP" && check "[12a] malformed meta emits DETECTION GAP" pass || check "[12a] malformed meta emits DETECTION GAP" fail
echo "$OUT" | grep -qE "malformed|unparseable" && check "[12b] malformed-meta message distinct from missing-meta" pass || check "[12b] malformed-meta message distinct from missing-meta" fail
# Pair preserved on disk for forensics (D-04(d) malformed branch contract):
[[ -f "$META_FILE" ]] && check "[12c] malformed pair preserved on disk for forensics" pass || check "[12c] malformed pair preserved on disk for forensics" fail

# === [13] manifest integration: leak-snapshot on PreToolUse:Agent;
#         leak-check on SubagentStop; PostToolUse:Agent block fully removed (D-04(h)) ===
MANIFEST="$REPO_ROOT/dhx-plugin/plugins/dhx/hooks/hooks.json"
jq -e '.hooks.PreToolUse[] | select(.matcher == "Agent") | .hooks[] | select(.command | contains("dhx-agent-leak-snapshot.sh"))' "$MANIFEST" >/dev/null 2>&1 \
  && check "[13a] leak-snapshot still registered on PreToolUse:Agent" pass \
  || check "[13a] leak-snapshot still registered on PreToolUse:Agent" fail
jq -e '.hooks.SubagentStop[] | .hooks[] | select(.command | contains("dhx-agent-leak-check.sh"))' "$MANIFEST" >/dev/null 2>&1 \
  && check "[13b] leak-check registered on SubagentStop (matcher-less)" pass \
  || check "[13b] leak-check registered on SubagentStop" fail
PA_AGENT_BLOCKS=$(jq '[.hooks.PostToolUse[] | select(.matcher == "Agent")] | length' "$MANIFEST" 2>/dev/null)
[[ "$PA_AGENT_BLOCKS" == "0" ]] && check "[13c] PostToolUse:Agent block REMOVED" pass || check "[13c] PostToolUse:Agent block REMOVED (got $PA_AGENT_BLOCKS)" fail
# WR-04: assert leak-check is the LAST entry in the SubagentStop block, not
# that the block has exactly 4 entries. Hardcoding count==4 is brittle — the
# next legitimate hook added to SubagentStop (catch-all event for subagent
# completion; obvious roadmap appetite for new SubagentStop hooks) breaks
# this assertion even though leak-check is still correctly registered. The
# semantically meaningful invariant — "leak-check IS in the block" — is
# already covered by [13b]; the additional ordering invariant ("leak-check
# is the LAST entry, i.e. fires AFTER the other SubagentStop hooks") is
# robust to future SubagentStop additions and still catches accidental
# de-registration / displacement.
LAST_CMD=$(jq -r '.hooks.SubagentStop[0].hooks[-1].command' "$MANIFEST" 2>/dev/null)
case "$LAST_CMD" in
  *dhx-agent-leak-check.sh*) check "[13d] leak-check is LAST in SubagentStop block (ordering invariant)" pass ;;
  *) check "[13d] leak-check is LAST in SubagentStop block (got tail=${LAST_CMD})" fail ;;
esac

# === [14] D-07 FIFO correlation: parent-state mutation between back-to-back snapshots ===
# Premise (D-07): wave-execute parent-state is invariant within a back-to-back
# snapshot window. This scenario explicitly violates the premise to verify the
# FIFO loop attributes the mutation to the correct dispatch (oldest pair).
SID="${SESSION_TAG}-fifo"
pre_input "$SID" "$TMP" "worktree" "exec-A" | "$PRE" >/dev/null 2>&1
sleep 0.05   # ensure distinct ns timestamps (D-16 margin)
# MUTATION FIXTURE: untracked write between snapshot 1 and snapshot 2.
# (Claude's Discretion at execute: could also be modify-tracked-file. Default: untracked write.)
echo "fifo-leak-marker" > "$TMP/fifo-mutation.txt"
pre_input "$SID" "$TMP" "worktree" "exec-B" | "$PRE" >/dev/null 2>&1
track_session_files "$SID"

# First SubagentStop consumes pair-A (oldest by dispatched_at). pair-A's baseline
# was captured BEFORE the mutation → diff against current state surfaces the leak.
OUT_A=$(post_input "$SID" "$TMP" "exec-A" | "$POST" 2>/dev/null || true)
echo "$OUT_A" | grep -q "LEAK SUSPECTED" && check "[14a] D-07: first completion (pair-A) detects mutation as leak" pass || check "[14a] D-07: first completion (pair-A) detects mutation as leak" fail
echo "$OUT_A" | grep -q "fifo-mutation.txt" && check "[14b] D-07: first completion warning names mutation file" pass || check "[14b] D-07: first completion warning names mutation file" fail
echo "$OUT_A" | grep -q "exec-A" && check "[14c] D-07: leak attributed to pair-A's subagent (FIFO oldest-first)" pass || check "[14c] D-07: leak attributed to pair-A's subagent (FIFO oldest-first)" fail

# Second SubagentStop consumes pair-B. pair-B's baseline was captured AFTER the
# mutation, so current state matches baseline → no leak. (Demonstrates FIFO
# correctly partitions state-mutation across multi-baseline accumulator.)
OUT_B=$(post_input "$SID" "$TMP" "exec-B" | "$POST" 2>/dev/null || true)
echo "$OUT_B" | grep -q "LEAK SUSPECTED" && check "[14d] D-07: second completion (pair-B) sees clean state (no leak)" fail || check "[14d] D-07: second completion (pair-B) sees clean state (no leak)" pass
rm -f "$TMP/fifo-mutation.txt"

# === [15] D-10 strict schema validation: missing required field → DETECTION GAP (D-11) ===
# 3 sub-cases: 15a missing dispatched_at, 15b missing cwd, 15c missing schema_version.
# Each writes a sidecar with valid JSON minus the named field; baseline .pre exists;
# SubagentStop fires; assert DETECTION GAP message names the missing field.

run_schema_subcase() {
  local subcase="$1" missing_field="$2" sid_suffix="$3"
  local sid="${SESSION_TAG}-schema-${sid_suffix}"
  local ts="$(date +%s%N)"
  local pre_path="$CACHE/agent-leak-${sid}-${ts}.pre"
  local meta_path="$CACHE/agent-leak-${sid}-${ts}.meta.json"
  # Write a valid .pre baseline (empty git status).
  : > "$pre_path"
  # Build sidecar JSON with valid JSON minus the named field.
  case "$missing_field" in
    dispatched_at)
      jq -n --arg cwd "$TMP" --arg iso "worktree" '{schema_version: 1, cwd: $cwd, isolation: $iso, subagent_type: "test"}' > "$meta_path"
      ;;
    cwd)
      jq -n --arg iso "worktree" --arg ts "2026-05-08T00:00:00Z" '{schema_version: 1, isolation: $iso, subagent_type: "test", dispatched_at: $ts}' > "$meta_path"
      ;;
    schema_version)
      jq -n --arg cwd "$TMP" --arg iso "worktree" --arg ts "2026-05-08T00:00:00Z" '{cwd: $cwd, isolation: $iso, subagent_type: "test", dispatched_at: $ts}' > "$meta_path"
      ;;
  esac
  BASELINES+=("$pre_path" "$meta_path")
  local out
  out=$(post_input "$sid" "$TMP" | "$POST" 2>/dev/null || true)
  echo "$out" | grep -q "DETECTION GAP" \
    && check "[${subcase}a] missing ${missing_field} emits DETECTION GAP" pass \
    || check "[${subcase}a] missing ${missing_field} emits DETECTION GAP" fail
  echo "$out" | grep -qE "missing required field" \
    && check "[${subcase}b] missing-field message uses 'missing required field' wording" pass \
    || check "[${subcase}b] missing-field message uses 'missing required field' wording" fail
  echo "$out" | grep -q "${missing_field}" \
    && check "[${subcase}c] missing-field message names the missing field (${missing_field})" pass \
    || check "[${subcase}c] missing-field message names the missing field (${missing_field})" fail
  # D-04(d) malformed-branch contract: pair preserved on disk for forensics.
  [[ -f "$meta_path" ]] \
    && check "[${subcase}d] missing-field pair preserved on disk for forensics" pass \
    || check "[${subcase}d] missing-field pair preserved on disk for forensics" fail
}

run_schema_subcase "15a" "dispatched_at" "ts"
run_schema_subcase "15b" "cwd" "cwd"
run_schema_subcase "15c" "schema_version" "ver"

# === [16] BL-01 regression: malformed sidecar must NOT block sibling valid pairs ===
# Pre-fix bug: a single malformed/missing-field sidecar triggered `exit 0`
# inside the schema-validation loop, so any sibling valid pair iterated AFTER
# it was permanently skipped. Across repeated SubagentStop fires the malformed
# sidecar persisted on disk (intentional, for forensics), so it kept being
# iterated first, kept tripping the exit, and valid sibling pairs leaked
# undetected forever (silent #36182 regression — exactly what BG-AGENT-1 was
# supposed to close).
#
# This scenario exercises the BLOCKER fix: the loop must `continue` past
# malformed sidecars (preserving them on disk) and still consume valid
# siblings. We construct 3 sidecars with explicit, KNOWN ns suffixes:
#   - T_MAL = NOW         (smallest ns; malformed → would trip pre-fix exit)
#   - T_V1  = NOW + 1000  (next; valid → SHOULD be consumed first under fix)
#   - T_V2  = NOW + 2000  (largest; valid → consumed second)
# Ordering matters: malformed has the smallest ns so it sorts FIRST in glob
# expansion. Under the pre-fix code, the loop would iterate T_MAL first,
# emit DETECTION GAP, exit 0, and never even examine T_V1/T_V2. Under the
# post-fix code, T_MAL is recorded in SCHEMA_GAPS (preserved on disk), then
# T_V1 is selected as smallest-ns VALID and consumed.
SID="${SESSION_TAG}-bl01"
NOW_NS=$(date +%s%N)
T_MAL_NS="$NOW_NS"
T_V1_NS="$((NOW_NS + 1000))"
T_V2_NS="$((NOW_NS + 2000))"

# Valid pair 1 (V1, ns just after malformed).
V1_PRE="$CACHE/agent-leak-${SID}-${T_V1_NS}.pre"
V1_META="$CACHE/agent-leak-${SID}-${T_V1_NS}.meta.json"
: > "$V1_PRE"
jq -n --arg cwd "$TMP" --arg iso "worktree" --arg sa "exec-bl01-V1" --arg ts "2026-05-08T00:00:01Z" \
  '{schema_version: 1, cwd: $cwd, isolation: $iso, subagent_type: $sa, dispatched_at: $ts}' > "$V1_META"

# Malformed pair (MAL, smallest ns — iterated FIRST in glob alphabetic order).
MAL_PRE="$CACHE/agent-leak-${SID}-${T_MAL_NS}.pre"
MAL_META="$CACHE/agent-leak-${SID}-${T_MAL_NS}.meta.json"
: > "$MAL_PRE"
echo "not json {" > "$MAL_META"   # corrupt the meta file (jq parse failure)

# Valid pair 2 (V2, largest ns).
V2_PRE="$CACHE/agent-leak-${SID}-${T_V2_NS}.pre"
V2_META="$CACHE/agent-leak-${SID}-${T_V2_NS}.meta.json"
: > "$V2_PRE"
jq -n --arg cwd "$TMP" --arg iso "worktree" --arg sa "exec-bl01-V2" --arg ts "2026-05-08T00:00:02Z" \
  '{schema_version: 1, cwd: $cwd, isolation: $iso, subagent_type: $sa, dispatched_at: $ts}' > "$V2_META"

BASELINES+=("$V1_PRE" "$V1_META" "$MAL_PRE" "$MAL_META" "$V2_PRE" "$V2_META")

# Sanity: confirm the 3 sidecars exist before the fire.
shopt -s nullglob; BL01_BEFORE=("$CACHE/agent-leak-${SID}-"*.meta.json); shopt -u nullglob
[[ ${#BL01_BEFORE[@]} -eq 3 ]] && check "[16a] BL-01 fixture: 3 sidecars present (V1+MAL+V2)" pass || check "[16a] BL-01 fixture: 3 sidecars present (got ${#BL01_BEFORE[@]})" fail

# First SubagentStop fire.
OUT_BL01_1=$(post_input "$SID" "$TMP" | "$POST" 2>/dev/null || true)

# Assertion 16b: DETECTION GAP message MUST be emitted (malformed must be reported).
echo "$OUT_BL01_1" | grep -q "DETECTION GAP" && check "[16b] BL-01 first fire: emits DETECTION GAP for malformed sibling" pass || check "[16b] BL-01 first fire: missing DETECTION GAP for malformed sibling" fail

# Assertion 16c: DETECTION GAP must name the malformed sidecar's filename
# (parameter expansion strips directory; check substring match against the
# basename for portability across DETECTION GAP wording variants).
echo "$OUT_BL01_1" | grep -q "${T_MAL_NS}.meta.json" && check "[16c] BL-01 first fire: DETECTION GAP names malformed pair filename" pass || check "[16c] BL-01 first fire: DETECTION GAP did not name malformed pair (${T_MAL_NS}.meta.json)" fail

# Assertion 16d: V1 (smallest-ns valid pair) was consumed — both .meta.json
# and .pre half should be GONE from disk.
[[ ! -f "$V1_META" && ! -f "$V1_PRE" ]] && check "[16d] BL-01 first fire: V1 (smallest-ns valid) pair consumed" pass || check "[16d] BL-01 first fire: V1 pair NOT consumed (meta=$V1_META exists=$([[ -f $V1_META ]] && echo yes || echo no))" fail

# Assertion 16e: V2 (largest-ns valid) pair PERSISTS — ready for the next fire.
[[ -f "$V2_META" && -f "$V2_PRE" ]] && check "[16e] BL-01 first fire: V2 valid sibling pair persists" pass || check "[16e] BL-01 first fire: V2 valid sibling pair was NOT preserved" fail

# Assertion 16f: malformed pair PERSISTS on disk for forensic inspection.
[[ -f "$MAL_META" && -f "$MAL_PRE" ]] && check "[16f] BL-01 first fire: malformed pair preserved on disk" pass || check "[16f] BL-01 first fire: malformed pair NOT preserved" fail

# Second SubagentStop fire — V2 should now be the smallest-ns VALID, get consumed.
OUT_BL01_2=$(post_input "$SID" "$TMP" | "$POST" 2>/dev/null || true)
[[ ! -f "$V2_META" && ! -f "$V2_PRE" ]] && check "[16g] BL-01 second fire: V2 (remaining valid) pair consumed" pass || check "[16g] BL-01 second fire: V2 pair NOT consumed" fail
echo "$OUT_BL01_2" | grep -q "DETECTION GAP" && check "[16h] BL-01 second fire: DETECTION GAP still surfaces malformed (preserved across fires)" pass || check "[16h] BL-01 second fire: DETECTION GAP did not re-fire for persistent malformed" fail
[[ -f "$MAL_META" && -f "$MAL_PRE" ]] && check "[16i] BL-01 second fire: malformed pair STILL preserved on disk" pass || check "[16i] BL-01 second fire: malformed pair was cleaned up (forensics contract violated)" fail

echo ""
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
