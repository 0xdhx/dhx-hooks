#!/usr/bin/env bash
# dhx-session-registry-end.sh — SessionEnd hook
# Patterns: HP-042 (SessionEnd fires + provides session_id + is plugin-hostable), HP-017 (plugin manifest)
#
# Appends one `end` row to the shared session registry on clean session exit. A
# crash (kill -9 / power loss) kills the process before SessionEnd fires, so a
# crashed session correctly leaves a `start` with NO matching `end` — which the
# consumer's reduce reads as "alive at crash". That is the whole mechanism: the
# absence of an end row, not its presence, is the signal.
#
# Contract: ~/repos/cross-repo/.planning/backlog/2026-06-08-alive-session-recovery-registry.md
# Registry path is LITERAL $HOME/.claude (see dhx-session-registry-start.sh header
# for the per-instance-fragmentation rationale).
#
# Row (3-field TSV — end rows need only ts,end,uuid per contract; the consumer
# keys the reduce on uuid, so the trailing instance/slug/repo/tmux fields are
# intentionally omitted, not empty-padded):
#   <iso_ts>\tend\t<uuid>
#
# Fail-open: SessionEnd cannot block termination (confirmed against the live hooks
# doc, 2026-06-08); any error => exit 0 silently. Fires on every end `reason`
# (clear|resume|logout|prompt_input_exit|bypass_permissions_disabled|other) — the
# manifest registers it with no matcher so all reasons record an end.
#
# ---------------------------------------------------------------------------
# TEMPORARY INSTRUMENT — end-reason sidecar log (added 2026-09-18)
#
# Second, SEPARATE append of `<iso_ts>\t<uuid>\t<reason>` to
# $HOME/.cache/dhx/session-end-reasons.tsv. The registry row above is untouched:
# the ratified 9-field positional contract is NOT amended, `end` rows stay
# 3-field, and no registry consumer sees a new field.
#
# WHY: SessionEnd fires MULTIPLY and NON-TERMINALLY (HP-042 — 905 same-uuid
# end-end gaps, max 75.1 d), and `reason` is on stdin but has never been
# persisted, so nothing on this machine can say WHICH reasons preserve a session
# id. One decision is blocked on that: whether /dhx:history alive's `--no-end`
# view becomes the default. A live run measured 87 recoverable held-open rows of
# which 66 were `end-seen` — rows annotated "a SessionEnd fired" with no way to
# tell a non-terminal /clear or /resume from a real close.
#
# SCOPE CEILING: `reason` is annotation-grade, never gate-grade. A nominally
# terminal reason may still be followed by recovery, so no filter or destructive
# action may ever be gated on it. HP-042's rule stands: a SessionEnd hook may
# record, and must not destroy.
#
# RETIREMENT CONDITION (written at birth, deliberately): this block and its
# append are DELETED once the reason->continuation table is written into HP-042.
# Backstop so it cannot quietly become permanent: /dhx:schedule
# sch_01M2SFTXKZ528MFDG7CBWBACTW, dated 2026-10-02 (~108 continuation events at
# the measured 7.7/day). If you are
# reading this after that table exists in docs/hook-patterns.md, the instrument
# is overdue for removal — delete it, drop the sidecar assertions from
# tests/probes/probe-session-registry.sh, and rm the .tsv.
#
# Analysis method when the table is written: take activity from the TRANSCRIPTS,
# not from this log or the registry (neither records turns). Two confounds will
# invent the finding if skipped — see
# ~/repos/cross-repo/docs/research/2026-09-18-cc-transcript-activity-scans-two-confounds.md
# ---------------------------------------------------------------------------
set -uo pipefail

REGISTRY="$HOME/.claude/dhx-session-registry.tsv"
INSTRUMENT_DIR="$HOME/.cache/dhx"
INSTRUMENT="$INSTRUMENT_DIR/session-end-reasons.tsv"

INPUT=$(cat)

# Silent exit on unparseable JSON.
echo "$INPUT" | jq -e . >/dev/null 2>&1 || exit 0

UUID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
if [ -z "$UUID" ] && [ -n "$TRANSCRIPT" ]; then
  UUID=$(basename "$TRANSCRIPT" .jsonl)
fi
[ -n "$UUID" ] || exit 0

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# The contract row FIRST — it is the load-bearing one. The instrument below is
# additive and must never be able to cost us this append.
printf '%s\t%s\t%s\n' "$TS" end "$UUID" >> "$REGISTRY"

# --- temporary instrument (see header) ---
# Enum-allowlist, not a sanitiser: anything outside the six documented values
# becomes `other`, so a tab or newline can never reach the file and the row
# stays a single atomic O_APPEND under PIPE_BUF. Asserted, not assumed.
REASON=$(echo "$INPUT" | jq -r '.reason // empty' 2>/dev/null)
case "$REASON" in
  clear|resume|logout|prompt_input_exit|bypass_permissions_disabled|other) ;;
  *) REASON=other ;;
esac
mkdir -p "$INSTRUMENT_DIR" 2>/dev/null || true
printf '%s\t%s\t%s\n' "$TS" "$UUID" "$REASON" >> "$INSTRUMENT" 2>/dev/null || true

exit 0
