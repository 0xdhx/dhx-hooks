#!/usr/bin/env bash
# dhx-roadmap-verification-gate.sh — PreToolUse hook (Write|Edit matcher)
# Patterns: HP-003, HP-007, HP-009
#
# Blocks (exit 2) a ROADMAP.md edit that flips a GSD phase to `- [x]` when that
# phase has NO `*-VERIFICATION.md` artifact — i.e. gsd-verifier never produced
# its report, so it did not run. Silent (exit 0) on everything else: non-ROADMAP
# writes, non-flip edits, and flips whose phase already carries a VERIFICATION.md.
#
# WHY THIS EXISTS — a /dhx:execute session ran the orchestrator's own checkpoint-11
# proof re-run and treated it as a SUBSTITUTE for spawning gsd-verifier, skipping
# the verifier entirely until the operator asked why. Post-mortem:
# ~/repos/skills/reports/execute/2026-06-18-gsd-verifier-skipped-despite-checkpoint-11-backstop.md
# The skills-side prose sharpen (dhx/execute/SKILL.md checkpoint-11 "Checkpoint 11
# is not the verifier" sub-clause) raises the bar but is still model-executed prose
# that CAN be rationalized past. This hook is the deterministic, out-of-context
# backstop: zero cost on the silent-pass path, a short deny only on the catch.
#
# ════════════════════════════════════════════════════════════════════════════
# TRIGGER POINT IS THE CONSEQUENCE, NOT THE ACT (known, bounded gap).
# ════════════════════════════════════════════════════════════════════════════
# This hook fires at the ROADMAP-`[x]` flip, which is DOWNSTREAM of the
# verifier-skip. The pre-flip window — running checkpoint-11 as a substitute,
# BEFORE any flip — is covered ONLY by the already-shipped skills prose sharpen
# (dhx/execute/SKILL.md:~147). This hook does NOT close the whole class; it closes
# the flip-time consequence. A session that skips the verifier and never flips the
# ROADMAP is not caught here (and is out of this gate's reach by construction).
#
# ════════════════════════════════════════════════════════════════════════════
# COUPLING — same invariant, different time (declare it, don't duplicate it).
# ════════════════════════════════════════════════════════════════════════════
# This hook and skills-repo tests/probe-phase-verification-completeness.sh enforce
# the SAME invariant ("a ROADMAP-complete active phase must carry a VERIFICATION.md")
# at DIFFERENT times: the probe at commit/test time (RED in tests/run.sh), this hook
# live in-session (deny at the flip). Intentional defense-in-depth. The two MUST stay
# aligned on scope + the boundary-guard regex — the phase-dir loop, the 999.* skip,
# the `num→unpadded→escaped` derivation, and the `^- \[x\].*Phase ${escaped}([^0-9.]|$)`
# match below are LIFTED VERBATIM from that probe (D-31 boundary-guard anchor). Edit one
# side → re-check the other. Full coupling doc:
#   ~/repos/cross-repo/docs/coupling/2026-06-18-roadmap-verification-gate-probe.md
#
# ════════════════════════════════════════════════════════════════════════════
# SCOPE (HP-003 reframe, 2026-04-21): fires for parent AND subagent writes.
# ════════════════════════════════════════════════════════════════════════════
# PreToolUse:Write and PreToolUse:Edit propagate from Agent subprocesses to
# parent-registered hooks. A gsd-executor subagent (or the orchestrator itself)
# flipping ROADMAP without a VERIFICATION.md is the same violation either way —
# uniform enforcement intended; the hook does NOT branch on agent_id.
#
# MultiEdit is OUT OF SCOPE: the tool is dormant on CC 2.1.112 (absent from the
# invocable surface per HP-003) and carries an edits[] array, not old_string/
# new_string. If CC restores it, a ROADMAP flip via MultiEdit would bypass this
# gate until the matcher + edits[] handling are added. Documented gap, not a fire.
#
# Hot path: a single jq parse extracts tool_input.file_path; a basename check exits
# 0 immediately for every write whose target is not ROADMAP.md. Only ROADMAP edits
# pay the phase-dir loop + the second jq for old/new content.
#
# Source-of-truth: ~/repos/hooks/dhx/dhx-roadmap-verification-gate.sh
# Symlinked to:    ~/.claude/hooks/dhx-roadmap-verification-gate.sh
#                  (installed via 'ln -sfn' — idempotent; tolerates a pre-existing
#                   stale symlink on re-run)
#
# Suppression: DHX_SKIP_ROADMAP_VERIFICATION_GATE=1
#
# No-gsd-core discipline: this hook only READS .planning/ and intercepts Edit/Write.
# It MUST NOT touch ~/.claude/get-shit-done/** or gsd-core/** (mirror-canonical
# clobber hazard). It does not.

set -uo pipefail   # NOT -e: must tolerate grep no-match (rc 1) and jq quirks

# Suppression escape valve
[ "${DHX_SKIP_ROADMAP_VERIFICATION_GATE:-0}" = "1" ] && exit 0

# Stdin envelope (HP-009 graceful-degrade — never block on a bad envelope)
INPUT=$(cat 2>/dev/null || true)
[ -z "$INPUT" ] && exit 0

# jq precondition — without jq the gate cannot reason; fail open (exit 0)
command -v jq >/dev/null 2>&1 || exit 0
echo "$INPUT" | jq -e . >/dev/null 2>&1 || exit 0

# Hot path: extract file_path, exit 0 unless this is a ROADMAP.md edit.
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$FILE" ] && exit 0
case "$(basename "$FILE")" in
  ROADMAP.md) ;;     # the only target we gate
  *) exit 0 ;;       # any other write — silent pass
esac

# Resolve the phase dir as the probe does: <planning>/phases/ next to ROADMAP.md.
# A ROADMAP.md with no sibling phases/ dir is not a GSD active-milestone roadmap
# (or has no phases yet) — nothing to check.
PLANNING_DIR=$(dirname "$FILE")
PHASES_DIR="$PLANNING_DIR/phases"
[ -d "$PHASES_DIR" ] || exit 0

# Determine the proposed-complete source (NEW_CONTENT) and the was-already-complete
# source (OLD_CONTENT). A flip = complete in NEW and NOT complete in OLD.
#   Edit:  NEW = new_string, OLD = old_string (fragments; see flip-semantics note).
#   Write: NEW = content,    OLD = on-disk ROADMAP (empty if the file is new).
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
case "$TOOL" in
  Edit)
    NEW_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty' 2>/dev/null)
    OLD_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.old_string // empty' 2>/dev/null)
    ;;
  Write)
    NEW_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty' 2>/dev/null)
    OLD_CONTENT=$(cat "$FILE" 2>/dev/null || true)
    ;;
  *)
    exit 0   # matcher should prevent this; defensive
    ;;
esac
[ -z "$NEW_CONTENT" ] && exit 0

# Flip-semantics note (Edit fragments): old_string/new_string are the before/after
# of the SAME span. A `- [x] Phase N` line present in new_string but absent from
# old_string was introduced by THIS edit (a `[ ]`→`[x]` change inside the span, or
# a freshly added completed line) — a genuine flip. A line unchanged by the edit
# appears in BOTH fragments → matches OLD → not a flip. So fragment-vs-fragment is
# correct for the flip test, while still using the probe's exact line regex.

# returns 0 if $1 (content) marks Phase $2 (escaped) complete — probe regex, verbatim.
# Here-string (not 'printf | grep -q') per HP-028: a pipe into grep -q is SIGPIPE+
# pipefail-prone; `<<<` feeds the content with no pipe and is line-for-line identical.
marks_complete() {
  grep -qE "^- \[x\].*Phase ${2}([^0-9.]|\$)" <<< "$1"
}

VIOLATIONS=""
for dir in "$PHASES_DIR"/*/; do
  [ -d "$dir" ] || continue
  base=$(basename "$dir")
  # phase number = leading [0-9]+(.[0-9]+)? before the first '-'  (probe line 34-35)
  num=$(printf '%s' "$base" | grep -oE '^[0-9]+(\.[0-9]+)?' || true)
  [ -z "$num" ] && continue
  # skip synthetic 999-scratch fixtures — never real milestone phases (probe line 39)
  case "$num" in 999|999.*) continue ;; esac
  # unpadded form for ROADMAP match (08 -> 8, 09 -> 9; 10 / 11.1 unchanged)
  unpadded=$(printf '%s' "$num" | sed 's/^0\+\([0-9]\)/\1/')
  # escape dots so 11.1 matches literally, not "11X1"
  escaped=$(printf '%s' "$unpadded" | sed 's/\./\\./g')

  # Flip = newly-complete: complete in the proposed edit, NOT already complete before.
  marks_complete "$NEW_CONTENT" "$escaped" || continue
  marks_complete "$OLD_CONTENT" "$escaped" && continue

  # Newly-[x] phase — assert its VERIFICATION.md exists (probe line 47 glob).
  if ! ls "${dir}"*-VERIFICATION.md >/dev/null 2>&1; then
    VIOLATIONS="${VIOLATIONS}${unpadded}"$'\n'
  fi
done

[ -z "$VIOLATIONS" ] && exit 0

# Deny — surface the block reason on stderr (CC feeds PreToolUse stderr back to
# Claude as the rejection on exit 2; matches dhx-gsd-canonical-mirror-gate.sh).
{
  while IFS= read -r N; do
    [ -z "$N" ] && continue
    echo "Phase ${N} marked complete but no ${N}-VERIFICATION.md exists — gsd-verifier did not run. Spawn it (Agent subagent_type=gsd-verifier) and let it write VERIFICATION.md before flipping ROADMAP to [x]. Checkpoint-11's own proof re-run is additive, never a substitute for the verifier."
  done <<< "$VIOLATIONS"
} >&2

exit 2
