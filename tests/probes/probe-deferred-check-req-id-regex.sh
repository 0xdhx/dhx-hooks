#!/usr/bin/env bash
# probe-deferred-check-req-id-regex.sh
#
# Regression probe for the auto-silence REQ-ID contract consumed by
# dhx/dhx-deferred-check.sh.
#
# Invariant: the requirement-ID resolution used to decide whether a deferred
# item "has a durable home" must resolve real requirement IDs (≥2-char
# leading alpha prefix) while never resolving GSD decision/question/fork
# labels (single-char prefix: D-NN, Q-NN, F-NN, A-NN). GSD labels
# appear pervasively in ROADMAP.md, REQUIREMENTS.md, milestones/, and
# backlog/ by design — if they resolve, any deferred item citing a decision
# gets silently silenced regardless of whether it has a real durable home.
#
# Source-of-truth: as of the 2026-05-02 cross-repo extraction, the resolution
# lives in `auto_silence_deferred_lines` inside the canonical classifier
# at ~/.claude/dhx-tools/dhx-classify-deferred.sh (skills-repo authority).
# The hook sources that script and calls the helper; this probe calls the SAME
# function against a synthetic project root, so the invariant is asserted
# through the behaviour the hook actually depends on.
#
# Backs: docs/decisions.md 2026-04-20 deferred-check D-NN false-positive row,
# extended by the 2026-05-02 auto-silence-extraction row and the 2026-08-27
# de-pin row.
# Parent report: ~/repos/skills/reports/2026-04-20-defer-hook-decision-label-false-positive.md
#
# Run: bash tests/probes/probe-deferred-check-req-id-regex.sh

# SAFE_FOR_LIVE: yes   (sources the canonical classifier read-only and runs it against
#                       an mktemp fixture project; no writes outside the fixture)
#
# ---------------------------------------------------------------------------
# 2026-08-27 — DE-PINNED from the classifier's SOURCE TEXT.
#
# This probe used to do:
#     REGEX=$(grep -E '^[[:space:]]*req_ids=' "$CLASSIFIER" | ... )
# and then exercise the extracted regex directly. That is a text pin on a PEER
# repo's live working tree: ~/.claude/dhx-tools/ is a tree of symlinks into
# ~/repos/skills/scripts/, so renaming the `req_ids` local, re-indenting the
# assignment, or building the pattern from a variable would red this probe — and
# with it every hooks-repo commit — with ZERO behavioural change and nothing
# committed anywhere. Measured 2026-08-20: this probe is one of five that flip
# that way; c90d734 (2026-05-22) is a confirmed prior instance of the class.
#
# The replacement calls `auto_silence_deferred_lines` against a synthetic
# .planning/ tree and asserts WHICH ITEMS SURVIVE. That is the property the hook
# consumes. A rename no longer reds it; a genuine tightening of the extraction
# (e.g. {2,} -> {3,}, which would stop resolving UI-03 / AI-07 / HP-001) still does.
# Red-tested both directions — see the mutation controls in the decisions row.
#
# WHAT THE DE-PIN GAVE UP, stated rather than glossed: this probe no longer
# asserts the literal regex FORM, so a rewrite that happens to be behaviourally
# identical on every token below now passes silently. The cells enumerate the
# prefix-length boundary from both sides (1-char rejected, 2-char accepted), which
# is the property the invariant is actually about.
# ---------------------------------------------------------------------------

set -uo pipefail

CLASSIFIER="${DHX_TOOLS:-$HOME/.claude/dhx-tools}/dhx-classify-deferred.sh"

if [[ ! -r "$CLASSIFIER" ]]; then
  echo "FAIL canonical classifier not readable: $CLASSIFIER"
  exit 1
fi

if ! grep -qE '^auto_silence_deferred_lines\(\)' "$CLASSIFIER"; then
  echo "FAIL $CLASSIFIER does not define auto_silence_deferred_lines() — the seam this probe asserts through is gone"
  exit 1
fi

PASS=0
FAIL=0

check() { # check <label> <ok?>
  if [[ "$2" == "1" ]]; then echo "OK   $1"; PASS=$((PASS+1))
  else echo "FAIL $1"; FAIL=$((FAIL+1)); fi
}

# --- Fixture -----------------------------------------------------------------
#
# The CONTEXT.md lives under a phase dir numbering to ZERO so `phase_num` resolves
# to "0" and Check 3 (source_phase brief matching) is skipped by the helper's own
# gate. Items below deliberately contain no `YYYY-MM-DD-slug` token, so Check 2
# (dated-filename resolution) cannot fire either. That leaves Check 1 — REQ-ID
# resolution — as the ONLY path that can silence anything here, which is what makes
# a surviving/silenced verdict attributable to the contract under test.

FIXTURE=$(mktemp -d /tmp/probe-req-id-behaviour.XXXXXX)
trap 'rm -rf "$FIXTURE"' EXIT

mkdir -p "$FIXTURE/.planning/phases/00-fixture" "$FIXTURE/.planning/backlog" "$FIXTURE/.planning/todos"
CTX="$FIXTURE/.planning/phases/00-fixture/CONTEXT.md"
: > "$CTX"

# Definitions use BOTH anchor shapes the helper accepts: bold body definition and
# first-column traceability row. Single-char-prefix GSD labels are defined here TOO —
# that is the point. They are present and resolvable-looking, and must still never
# silence an item, because they are never extracted as requirement IDs in the first
# place.
cat > "$FIXTURE/.planning/REQUIREMENTS.md" <<'EOF'
# Requirements

**REQ-V2-004** MCP elicitation rollback path
**DATA-F01** data fixture requirement
**STEL-02** stale-entry requirement
**QUAL-01** quality bar
**BACK-01** backlog requirement
**HP-001** hook pattern one
**UI-03** two-char prefix, UI domain
**AI-07** two-char prefix, AI domain
**REVIEW-CODE** artifact-shaped token that IS a defined requirement here

| ID | Description |
|---|---|
| REQ-TABLE-09 | defined only as a traceability row, never in bold |

GSD labels, deliberately defined so a false positive would have somewhere to land:

**D-19** a decision label
**Q-03** a question label
**F-02** a fork label
**A-01** a single-letter label
**B-05** another single-letter label
EOF

# Run one item through the helper. Echoes "SURVIVED" or "SILENCED".
verdict() { # verdict <item>
  local out
  out=$(printf '%s\n' "$1" | bash -c '. "'"$CLASSIFIER"'"; auto_silence_deferred_lines "'"$CTX"'"')
  if [[ -z "$out" ]]; then echo "SILENCED"; else echo "SURVIVED"; fi
}

# --- Section 1: single-char-prefix GSD labels must NEVER resolve ---
#
# Each token below IS defined in REQUIREMENTS.md above in the exact bold shape the
# helper anchors on. The only reason the item must survive is that the extraction
# never yields a single-char-prefix token as a requirement ID. If the prefix floor
# were dropped to {1,}, every one of these would silence and every deferred item
# citing a decision would vanish from the hook's surface.

for token in "D-19" "D-01" "Q-03" "F-02" "A-01" "B-05"; do
  v=$(verdict "- Wider carve-out (see $token in ROADMAP)")
  [[ "$v" == "SURVIVED" ]] && check "GSD label $token does not resolve — item surfaces" 1 \
                           || check "GSD label $token resolved and SILENCED the item — prefix floor regressed" 0
done

# --- Section 2: real requirement IDs must resolve ---
#
# UI-03, AI-07 and HP-001 are the boundary cells: a two-char alpha prefix. A
# tightening of the extraction to a three-char floor reds exactly these three and
# leaves the rest green, which is the signal that distinguishes "the floor moved"
# from "resolution broke entirely".

for token in "REQ-V2-004" "DATA-F01" "STEL-02" "QUAL-01" "BACK-01" "HP-001" "UI-03" "AI-07"; do
  v=$(verdict "- Deferred work tracked under $token")
  [[ "$v" == "SILENCED" ]] && check "requirement ID $token resolves — item silenced" 1 \
                           || check "requirement ID $token did NOT resolve — item surfaced unexpectedly" 0
done

# --- Section 3: the traceability-row anchor ---
# REQ-TABLE-09 appears ONLY as a `| REQ-TABLE-09 |` row, never in bold. The helper
# accepts either anchor; this cell keeps the table arm from rotting unnoticed.
v=$(verdict "- Work item covered by REQ-TABLE-09")
[[ "$v" == "SILENCED" ]] && check "traceability-row anchor resolves (| REQ-TABLE-09 | row, no bold def)" 1 \
                         || check "traceability-row anchor did NOT resolve — table arm regressed" 0

# --- Section 4: extraction is permissive, RESOLUTION is what filters ---
#
# Deliberate contract, NOT a bug: extraction is permissive across naming schemes, so
# an artifact-name fragment like REVIEW-CODE or MILESTONE-AUDIT is a valid REQ-ID
# *shape* and IS extracted. Precision lives at the resolution layer — the helper is
# definition-anchored, so a fragment that is not DEFINED cannot bare-substring-match
# REQUIREMENTS.md prose and silently silence a marker-less deferred bullet.
#
# These two cells are the pair that proves it, and they are why this section is a
# differential rather than a single assertion: REVIEW-CODE is defined above and must
# silence; MILESTONE-AUDIT is not defined and must survive. Same shape, opposite
# verdicts, so neither can pass vacuously.
#
# A future reader who sees extraction accept REVIEW-CODE should NOT mistake it for a
# leak; see report:
# ~/repos/skills/reports/done/2026-05-22-classify-deferred-auto-silence-false-positive.md

v=$(verdict "- Chunked output from REVIEW-CODE needs a home")
[[ "$v" == "SILENCED" ]] && check "artifact-shaped token REVIEW-CODE resolves when DEFINED" 1 \
                         || check "REVIEW-CODE is defined but did not resolve" 0

v=$(verdict "- Chunked output from MILESTONE-AUDIT needs a home")
[[ "$v" == "SURVIVED" ]] && check "artifact-shaped token MILESTONE-AUDIT does NOT resolve when undefined (resolution filters)" 1 \
                         || check "undefined MILESTONE-AUDIT silenced an item — the definition anchor regressed" 0

# --- Section 5: undefined requirement-shaped tokens must not resolve ---
v=$(verdict "- Undefined token ZZ-99 has no durable home anywhere")
[[ "$v" == "SURVIVED" ]] && check "undefined ZZ-99 does not resolve — item surfaces" 1 \
                         || check "undefined ZZ-99 silenced an item — definition anchor bypassed" 0

# --- Section 6: realistic mixed-content lines ---

# Mixed line: a real REQ-ID and a D-NN together. The REQ-ID resolves, so the item is
# silenced — and the D-NN's presence must not be what did it (Section 1 already
# proved D-NN alone cannot).
v=$(verdict "- MCP elicitation rollback path — REQ-V2-004 (tracked under D-01)")
[[ "$v" == "SILENCED" ]] && check "mixed line with REQ-V2-004 + D-01 silences on the real ID" 1 \
                         || check "mixed line did not silence despite a resolvable REQ-V2-004" 0

# Prose noise: incidental single-letter-dash tokens must not resolve, and the real ID
# in the same line must still carry the verdict.
v=$(verdict "- The A-team considered option B-1 before picking QUAL-01")
[[ "$v" == "SILENCED" ]] && check "prose with A-team/B-1 noise still silences on QUAL-01" 1 \
                         || check "prose noise blocked resolution of QUAL-01" 0

# Same prose noise WITHOUT a real ID must survive — the negative half of the pair.
v=$(verdict "- The A-team considered option B-1 and never filed anything")
[[ "$v" == "SURVIVED" ]] && check "prose with A-team/B-1 noise ALONE does not resolve — item surfaces" 1 \
                         || check "A-team/B-1 prose noise resolved as a requirement ID" 0

# --- Section 7: multi-ID line ---
# All three resolve; any one of them is sufficient for a durable home.
v=$(verdict "- Cross-ref: DATA-F01 and QUAL-01 both gate STEL-02")
[[ "$v" == "SILENCED" ]] && check "multi-ID line silences" 1 \
                         || check "multi-ID line did not silence" 0

# --- Section 8: structural negative control ---
#
# Proves the fixture is wired at all. With NO .planning tree to resolve against, the
# helper's own guard passes everything through, so an item that silences in every
# cell above must survive here. Without this control, a helper that silently returned
# its input unchanged would fail Sections 2/3/4/6/7 loudly — but a helper that
# silenced EVERYTHING would pass them all and only this cell catches it.
EMPTY=$(mktemp -d /tmp/probe-req-id-empty.XXXXXX)
out=$(printf '%s\n' "- Deferred work tracked under REQ-V2-004" \
      | bash -c '. "'"$CLASSIFIER"'"; auto_silence_deferred_lines "'"$EMPTY"'/nowhere/CONTEXT.md"')
rm -rf "$EMPTY"
[[ -n "$out" ]] && check "negative control — no .planning corpus, everything passes through" 1 \
                || check "negative control FAILED — helper silenced an item with no corpus to resolve against" 0

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]
