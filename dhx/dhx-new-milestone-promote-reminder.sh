#!/usr/bin/env bash
# dhx-new-milestone-promote-reminder.sh — PostToolUse hook (matcher: Skill)
# Patterns: HP-010
# Fires when /gsd-new-milestone is invoked and scans .planning/backlog/ for
# briefs that the upcoming cut will make promotable: `target_milestone: next`
# (exact), `next+[1-3]`, and stale-version tags. Emits a 2-line PRE-CUT
# heads-up. Non-blocking (exit 0). Silent when no matching briefs exist or
# preconditions unmet.
#
# WHAT THIS HOOK KNOWS, AND WHEN (read before retargeting it — 2026-09-04):
# PostToolUse:Skill fires at the Skill tool's RETURN — instruction load, BEFORE
# the skill body rewrites PROJECT.md. So at fire time the cut has NOT happened:
# $VERSION is the CLOSING milestone, and /dhx:backlog promote-next would exit 2
# if run at this instant. The hook therefore does NOT claim a milestone was
# declared and does NOT tell the operator to act now — it names the close and
# defers the action to "once the cut is committed". The post-cut call to action
# is owned by /dhx:new § Next Step (skills repo), which fires after the chain
# reaches its committed postcondition and is the authoritative signal; this
# hook is the pre-cut heads-up that also covers a bare /gsd-new-milestone.
# Retargeting to a later event was assessed and REJECTED 2026-09-04: the
# planner's own precondition is this same PROJECT.md heading (see PARSER
# PARITY), so later timing buys no precondition, and a cache-marker "did the
# version change" detector cannot distinguish a first observation of a repo
# from an actual declaration. See docs/decisions.md 2026-09-04 row.
#
# INVARIANT — the stale compare is <= (not <), and that is NOT an approximation:
# at fire time $VERSION is the CLOSING milestone, so briefs tagged <= closing
# are exactly the briefs that will compare < declared once the cut lands. The
# hook's <= at v1.5-closing and promote-next's < at v1.6-declared select the
# IDENTICAL set. Change one only if the other changes. Future-version tags
# (> $VERSION) are legitimate forward scoping and never count.
#
# PARSER PARITY — the version grammar below MUST mirror
# skills:scripts/backlog-promote-next.cjs (`parseProjectMilestone`,
# `parseVersionTag`, `cmpVersion`). A looser parser here makes the hook point
# at a command that then exits 2. Measured 2026-09-04 before this was aligned:
# on `## Current Milestone: v0.3.0 <Name>` the hook printed "Milestone v0.3
# declared" — a version string appearing nowhere in the file — while the
# planner returned version:null and exit 2 on the same file. Both grammars now
# accept vN, vN.M and vN.M.P, with absent components reading as 0.
# Drift teeth: tests/probes/probe-new-milestone-promote-reminder.sh (A11/A12).
#
# PARITY SCOPE — what the contract covers, and what it deliberately does not
# (2026-09-04). Parity is over the version GRAMMAR and the brief COUNT, both in
# FLAT MODE. It is NOT a claim that the two surfaces reach the same verdict in
# every mode, and since the workstream ruling it demonstrably does not: the
# planner consults gsd-core for a workstream mode and REFUSES promotion there,
# while this hook consults it only to fall SILENT. Those are different
# behaviours from the same fact, chosen per surface, not a drift to repair.
# State it rather than leave it inferred, because a green grammar assertion
# would otherwise read as evidence of an agreement it never tested: A13 and
# A16 compare parsers and counts, and NEITHER can see a mode divergence. The
# guard below is pinned by its own assertion (A17) for exactly that reason —
# the one thing the parity pair is structurally blind to gets a direct tooth.

INPUT=$(cat)
SKILL=$(echo "$INPUT" | jq -r '.tool_input.skill // empty' 2>/dev/null)
[ "$SKILL" = "gsd-new-milestone" ] || exit 0

CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$CWD" ] && CWD="$(pwd)"

BACKLOG_DIR="$CWD/.planning/backlog"
PROJECT_FILE="$CWD/.planning/PROJECT.md"

[ -d "$BACKLOG_DIR" ] || exit 0
[ -f "$PROJECT_FILE" ] || exit 0

# FLAT-MODE ONLY (2026-09-04). Under an active workstream this hook stays
# silent, because there is nothing truthful for it to say: gsd-new-milestone
# deliberately never rewrites PROJECT.md's `## Current Milestone` heading when
# a workstream is active, so the heading below is stale — and it is stale while
# STILL PARSING, which is why "the version check already covers it" is wrong.
# Only the unparseable branch was ever covered; a stale-but-parseable heading
# hands this hook a version and it advertises a promotion that the planner now
# refuses outright (reason `workstream_active_promotion_unsupported`).
#
# This asks gsd-core ONE factual question — is a workstream active — and never
# decides policy from the answer. The policy ("promotion is flat-mode only,
# because .planning/backlog/ is shared and nothing records which briefs belong
# to which workstream") lives in the planner, which owns it. Teaching this hook
# to resolve a workstream milestone was assessed and rejected: it would put
# workstream semantics in bash while the planner stayed unaware, guaranteeing
# the two surfaces disagree.
#
# FAIL-CLOSED, in the direction that suits a reminder: the planner fails closed
# by REFUSING, this hook by staying SILENT. Both decline to assert what they
# cannot support. So anything other than a positive `"mode": "flat"` exits 0.
#
# PARSER PARITY is UNAFFECTED by this guard, and that is checkable rather than
# asserted: the version grammar below is unchanged byte-for-byte, so A13
# (grammar) and A16 (count) still compare like for like — both were re-run
# green against the workstream-aware planner on 2026-09-04, before this guard
# was written. What diverges is the SOURCE SET, not the grammar: the planner
# now consults gsd-core for a mode this hook only uses to fall silent. A13/A16
# cannot see that divergence — a grammar assertion is structurally blind to it
# — which is precisely why the new A17 pins the silence directly.
# NO `.planning/workstreams/` DIRECTORY MEANS FLAT — a positive determination
# from the directory contract, not a guess, so the resolver is skipped entirely.
# gsd-core reports flat when that directory is absent, and a session pointer
# naming a workstream whose directory no longer exists is treated as stale and
# resolves to null. This is also what keeps the guard cheap: measured 2026-09-04,
# an unconditional `node gsd-tools.cjs workstream get` cost ~350ms per fire
# against the ~12ms in this hook's birth row — a 29x regression charged to every
# flat repo, which is nearly all of them. The planner's `detectWorkstream` short-
# circuits on the same condition, so both surfaces run identical logic.
if [ -d "$CWD/.planning/workstreams" ]; then
  _GSD_TOOLS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/gsd-core/bin/gsd-tools.cjs"
  if [ -f "$_GSD_TOOLS" ]; then
    _WS_JSON=$(cd "$CWD" && node "$_GSD_TOOLS" workstream get 2>/dev/null)
    # Matched with a native bash regex, NOT `printf … | grep -q`: that shape is
    # HP-028 (an early-exiting reader closes the pipe, the writer takes SIGPIPE,
    # and under pipefail the pipeline reports failure). The payload is already in
    # a variable, so the pipe bought nothing and cost a subprocess.
    # Absent/unreadable/unparseable all land here as a non-match and exit.
    _WS_FLAT_RX='"mode"[[:space:]]*:[[:space:]]*"flat"'
    [[ "$_WS_JSON" =~ $_WS_FLAT_RX ]] || exit 0
  else
    # Workstreams exist here but nothing can say which is active.
    # Undetermined is not flat — stay silent rather than guess.
    exit 0
  fi
fi

# Milestone heading. Anchored end-to-end so the accept set matches the planner
# exactly: a version token, then optionally whitespace + a name, then EOL.
# `v0.3.0.1` is rejected here because the planner rejects it too.
MILESTONE_RX='^##[[:space:]]+Current Milestone:[[:space:]]+v[0-9]+(\.[0-9]+){0,2}([[:space:]]+.+)?[[:space:]]*$'
VERSION=$(grep -E "$MILESTONE_RX" "$PROJECT_FILE" \
  | head -1 \
  | sed -E 's/^##[[:space:]]+Current Milestone:[[:space:]]+(v[0-9]+(\.[0-9]+){0,2})([[:space:]].*)?$/\1/')
[ -n "$VERSION" ] || exit 0

# Split a vN[.M[.P]] token into three numeric components, absent ones as 0 —
# the bash mirror of the planner's parseVersionTag.
split_version() {
  local t=${1#v} maj min pat
  maj=${t%%.*}
  case "$t" in
    *.*.*) min=${t#*.}; min=${min%%.*}; pat=${t##*.} ;;
    *.*)   min=${t#*.};                 pat=0 ;;
    *)     min=0;                       pat=0 ;;
  esac
  printf '%s %s %s' "$maj" "$min" "$pat"
}

read -r VMAJ VMIN VPAT <<< "$(split_version "$VERSION")"

NEXT_COUNT=0
NEXT_PLUS_COUNT=0
STALE_COUNT=0

# Frontmatter-isolated read of one top-level key, mirroring the planner's
# parse-frontmatter-block.cjs contract: the file must OPEN with `---`, the block
# ends at the next `---`, and only column-0 `key:` lines inside it count. CRLF
# tolerated (WR-02 parity). This replaced a `head -30` window on 2026-09-04:
# briefs with long `trigger_when:` blocks push `target_milestone:` past line 30
# — measured in ~/repos/barca, 16 of 34 `next` briefs sat beyond it, deepest at
# line 76, so the reminder printed 24 where promote-next reports 34. A fixed
# window also let a BODY line reading `target_milestone: …` count as frontmatter;
# isolating the block closes both at once.
read_fm_key() {
  awk -v key="$2" '
    { sub(/\r$/, "") }
    NR == 1 && $0 != "---" { exit }
    NR == 1 { next }
    $0 == "---" { exit }
    index($0, key ":") == 1 { print substr($0, length(key) + 2); exit }
  ' "$1"
}

for brief in "$BACKLOG_DIR"/*.md; do
  [ -f "$brief" ] || continue
  tm=$(read_fm_key "$brief" target_milestone \
    | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr -d '"'"'")
  case "$tm" in
    next)           NEXT_COUNT=$((NEXT_COUNT + 1)) ;;
    next+[1-3])     NEXT_PLUS_COUNT=$((NEXT_PLUS_COUNT + 1)) ;;
    v[0-9]*)
      # Same tag grammar as the planner's parseVersionTag: vN, vN.M, vN.M.P.
      grep -qE '^v[0-9]+(\.[0-9]+){0,2}$' <<< "$tm" || continue
      read -r TMAJ TMIN TPAT <<< "$(split_version "$tm")"
      # Per-component numeric compare (v1.10 > v1.9); <= per header INVARIANT.
      if [ "$TMAJ" -lt "$VMAJ" ] \
        || { [ "$TMAJ" -eq "$VMAJ" ] && [ "$TMIN" -lt "$VMIN" ]; } \
        || { [ "$TMAJ" -eq "$VMAJ" ] && [ "$TMIN" -eq "$VMIN" ] && [ "$TPAT" -le "$VPAT" ]; }; then
        STALE_COUNT=$((STALE_COUNT + 1))
      fi ;;
  esac
done

[ $NEXT_COUNT -eq 0 ] && [ $NEXT_PLUS_COUNT -eq 0 ] && [ $STALE_COUNT -eq 0 ] && exit 0

PARTS=""
[ $NEXT_COUNT -gt 0 ] && PARTS="$NEXT_COUNT 'next'"
[ $NEXT_PLUS_COUNT -gt 0 ] && PARTS="${PARTS:+$PARTS + }$NEXT_PLUS_COUNT 'next+N'"
[ $STALE_COUNT -gt 0 ] && PARTS="${PARTS:+$PARTS + }$STALE_COUNT stale-version"
# Two lines, per the 2026-04-20 output cap. "Closing", not "declared": at fire
# time the cut has not happened and $VERSION is the milestone being left.
echo "Closing $VERSION — $PARTS backlog brief(s) await promotion."
echo "Run /dhx:backlog promote-next once the cut is committed."
exit 0
