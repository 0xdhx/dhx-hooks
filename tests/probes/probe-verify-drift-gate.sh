#!/usr/bin/env bash
# probe-verify-drift-gate.sh
#
# Regression probe for dhx/dhx-verify-drift-gate.sh — the Phase 12 VERIFY-DRIFT
# UserPromptSubmit gate. The hook detects a missing {phase}-VERIFICATION.md when
# an operator types `/dhx:test {N}` (full-pipeline shape only) and emits a
# top-level {"decision":"block","reason":...} JSON whose `reason` names the
# three exit lanes (A wave-slice / B /dhx:execute wrapper early-exit / C
# operator-bypass closure). Subcommands (`nyquist`/`run`/`sweep`) bypass the
# gate; a dispensation row in docs/decisions.md overrides it; STATE.md parse
# faults fail-open with an exact stderr warning.
#
# Exit-A detection is PHASE-SCOPED: an unfinished `- [ ]` checkbox in any phase
# PLAN.md, OR a phase PLAN.md with no matching SUMMARY.md (#SUMMARY < #PLAN).
# It deliberately ignores STATE.md `progress.*` — those counts are
# milestone-cumulative, not phase-scoped. Scenario 10 is the regression test
# for that distinction (the D-06 design flaw the Task 5.5 live-fire surfaced).
#
# Each scenario builds a synthetic UserPromptSubmit payload, runs the hook
# inside a mktemp HOME sandbox (cd $TMP so .planning/-relative resolution
# targets the sandbox, never the live repo), and asserts the outcome.
#
# Backs:
#   - docs/decisions.md — 2026-05-15 Phase 12 VERIFY-DRIFT ship row
#   - docs/hook-patterns.md — HP-008 (UserPromptSubmit .prompt field),
#     HP-009 (block-JSON shape), HP-017 (plugin-manifest rewriter-immunity)
#
# Run: bash tests/probes/probe-verify-drift-gate.sh
#
# SAFE_FOR_LIVE: yes   (mktemp HOME isolation; no live .planning/, decisions.md,
#                       or manifest writes — scenario 6 reads the manifest only)

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$REPO_ROOT/dhx/dhx-verify-drift-gate.sh"
MANIFEST="$REPO_ROOT/dhx-plugin/plugins/dhx/hooks/hooks.json"

if [ ! -r "$HOOK" ]; then echo "FAIL hook not readable: $HOOK"; exit 1; fi
if ! command -v jq >/dev/null 2>&1; then echo "FAIL jq required but not installed"; exit 1; fi
if [ ! -r "$MANIFEST" ]; then echo "FAIL manifest not readable: $MANIFEST"; exit 1; fi

TMP=$(mktemp -d /tmp/probe-verify-drift-gate.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

# --- Helpers ---

# Build a full empirical UserPromptSubmit stdin payload (6 fields per the
# 2026-05-15 live spike schema).
build_payload() {
  local prompt="$1"
  jq -n --arg p "$prompt" --arg c "$TMP" \
    '{session_id:"probe", transcript_path:"", cwd:$c,
      permission_mode:"default", hook_event_name:"UserPromptSubmit", prompt:$p}'
}

# Run the hook in the sandbox. cd "$TMP" is load-bearing — the hook resolves
# .planning/ and docs/decisions.md relative to its CWD. The subshell parens
# keep the cd local. stderr is discarded for assertion-clean stdout capture.
run_hook() {
  local payload="$1"
  (cd "$TMP" && HOME="$TMP" bash "$HOOK" <<< "$payload") 2>/dev/null
}

# Strict block predicate — decision == "block" with a non-empty reason.
assert_blocks() {
  local label="$1" output="$2"
  if jq -e '.decision == "block" and (.reason | length > 0)' <<< "$output" >/dev/null 2>&1; then
    echo "OK   $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL $label — expected block, got: $(printf '%s' "$output" | head -c 200)"
    FAIL=$((FAIL + 1))
  fi
}

# Block predicate requiring all three lane substrings in the reason text.
assert_blocks_three_lanes() {
  local label="$1" output="$2"
  if jq -e '.decision == "block"
            and (.reason | contains("Lane A"))
            and (.reason | contains("Lane B"))
            and (.reason | contains("Lane C"))' <<< "$output" >/dev/null 2>&1; then
    echo "OK   $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL $label — expected block w/ Lane A/B/C, got: $(printf '%s' "$output" | head -c 200)"
    FAIL=$((FAIL + 1))
  fi
}

# Block predicate requiring an arbitrary substring in the reason text.
assert_blocks_contains() {
  local label="$1" output="$2" substring="$3"
  if jq -e --arg s "$substring" \
       '.decision == "block" and (.reason | contains($s))' <<< "$output" >/dev/null 2>&1; then
    echo "OK   $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL $label — expected block containing '$substring', got: $(printf '%s' "$output" | head -c 200)"
    FAIL=$((FAIL + 1))
  fi
}

# Silent-allow predicate — empty stdout.
assert_silent() {
  local label="$1" output="$2"
  if [ -z "$output" ]; then
    echo "OK   $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL $label — expected no output, got: $(printf '%s' "$output" | head -c 200)"
    FAIL=$((FAIL + 1))
  fi
}

# Build sandbox fixtures.
#   $1 = phase dir base (e.g. "12-test" or "10.1-test")
#   $2 = verification_present (true|false)
#   $3 = phase_incomplete (true|false) — "incomplete" means the phase dir holds
#        a *-PLAN.md with NO matching *-SUMMARY.md (the phase-scoped Exit-A
#        signal). "complete" means the phase dir holds a *-PLAN.md AND a
#        *-SUMMARY.md. Either way a *-PLAN.md always exists so the phase dir is
#        scaffolded — the hook's Step 5 phase-dir check passes.
#   $4 = dispensation_present (true|false)
#   $5 = state_md_absent (true|false, optional; default false — when true,
#        STATE.md is NOT written, exercising the D-17 fail-open path)
#
# NOTE: the fixed hook (Step 6) ignores STATE.md `progress.*` entirely for
# Exit-A — those counts are milestone-cumulative, not phase-scoped. Exit-A is
# driven purely by phase-dir contents (`- [ ]` checkbox scan + #PLAN-vs-#SUMMARY
# count). The STATE.md written here only feeds Step 3 phase resolution (and the
# D-17 fail-open path when $5=true). Scenario 10 overrides this STATE.md shape
# to assert the milestone-cumulative counts do NOT mis-fire Exit-A.
refresh_fixtures() {
  local phase_dir="$1" verification="$2" phase_incomplete="$3" dispensation="$4"
  local state_absent="${5:-false}"
  local phase="${phase_dir%-test}"

  rm -rf "$TMP/.planning" "$TMP/docs"
  mkdir -p "$TMP/.planning/phases/$phase_dir"

  if [ "$state_absent" != "true" ]; then
    cat > "$TMP/.planning/STATE.md" <<EOF
---
stopped_at: Phase $phase context gathered
progress:
  total_plans: 1
  completed_plans: 1
---
EOF
  fi

  if [ "$verification" = "true" ]; then
    touch "$TMP/.planning/phases/$phase_dir/${phase}-VERIFICATION.md"
  fi

  # A *-PLAN.md always exists (phase dir is scaffolded). When the phase is
  # "complete" a matching *-SUMMARY.md is written alongside it; when
  # "incomplete" the *-SUMMARY.md is omitted → #SUMMARY < #PLAN → Exit-A.
  cat > "$TMP/.planning/phases/$phase_dir/${phase}-01-PLAN.md" <<EOF
# Plan
some task
EOF
  if [ "$phase_incomplete" != "true" ]; then
    cat > "$TMP/.planning/phases/$phase_dir/${phase}-01-SUMMARY.md" <<EOF
# Summary
plan complete
EOF
  fi

  if [ "$dispensation" = "true" ]; then
    mkdir -p "$TMP/docs"
    cat > "$TMP/docs/decisions.md" <<EOF
| 2026-05-15 | files | Phase $phase VERIFICATION.md drift dispensation — operator override | mechanism | refs |
EOF
  fi
}

# --- Scenario [1]: VERIFICATION.md present → silent allow (happy path) ---
refresh_fixtures 12-test true false false
PAYLOAD=$(build_payload "/dhx:test 12")
OUTPUT=$(run_hook "$PAYLOAD")
assert_silent "[1] VERIFICATION.md present → silent allow" "$OUTPUT"

# --- Scenario [2]: VERIFICATION.md absent, phase complete (PLAN+SUMMARY) →
#     block w/ three lanes A/B/C, no-incomplete (collapsed B/C) wording (D-06) ---
# Phase dir holds a *-PLAN.md AND a matching *-SUMMARY.md → #SUMMARY == #PLAN →
# Exit-A does NOT fire → the collapsed B/C three-lane reason (else-branch) emits.
refresh_fixtures 12-test false false false
PAYLOAD=$(build_payload "/dhx:test 12")
OUTPUT=$(run_hook "$PAYLOAD")
assert_blocks_three_lanes "[2] VERIFICATION.md absent, phase complete → block w/ three lanes A/B/C" "$OUTPUT"
if jq -e '(.reason | contains("Phase has incomplete plans")) | not' <<< "$OUTPUT" >/dev/null 2>&1; then
  echo "OK   [2b] complete phase → no-incomplete wording (reason omits 'Phase has incomplete plans')"
  PASS=$((PASS + 1))
else
  echo "FAIL [2b] complete phase emitted Exit-A wording — expected no-incomplete (collapsed B/C) reason"
  FAIL=$((FAIL + 1))
fi

# --- Scenario [3]: subcommand (/dhx:test nyquist|run|sweep) → silent allow (D-05) ---
refresh_fixtures 12-test false false false
PAYLOAD=$(build_payload "/dhx:test nyquist 12")
OUTPUT=$(run_hook "$PAYLOAD")
assert_silent "[3] /dhx:test nyquist subcommand → silent allow (D-05)" "$OUTPUT"
PAYLOAD=$(build_payload "/dhx:test run 12")
OUTPUT=$(run_hook "$PAYLOAD")
assert_silent "[3b] /dhx:test run subcommand → silent allow (D-05)" "$OUTPUT"
PAYLOAD=$(build_payload "/dhx:test sweep")
OUTPUT=$(run_hook "$PAYLOAD")
assert_silent "[3c] /dhx:test sweep subcommand → silent allow (D-05)" "$OUTPUT"

# --- Scenario [4]: dispensation row present → silent allow (D-12) ---
refresh_fixtures 12-test false false true
PAYLOAD=$(build_payload "/dhx:test 12")
OUTPUT=$(run_hook "$PAYLOAD")
assert_silent "[4] dispensation row present → silent allow (D-12)" "$OUTPUT"

# --- Scenario [5]: incomplete phase (PLAN with no matching SUMMARY) →
#     block w/ Exit-A wording (D-06, phase-scoped #PLAN-vs-#SUMMARY count) ---
# Phase dir holds a *-PLAN.md but NO *-SUMMARY.md → #SUMMARY < #PLAN → Exit-A.
refresh_fixtures 12-test false true false
PAYLOAD=$(build_payload "/dhx:test 12")
OUTPUT=$(run_hook "$PAYLOAD")
assert_blocks_contains "[5] incomplete phase (PLAN, no SUMMARY) → block w/ Exit-A wording (D-06)" \
  "$OUTPUT" "Phase has incomplete plans"

echo "# --- Scenario [6]: manifest registration assertion (D-21 presence-based form) ---"
HOOK_REGISTERED=$(jq '[.hooks.UserPromptSubmit[0].hooks[].command
                       | select(contains("dhx-verify-drift-gate"))] | length' "$MANIFEST")
if [[ "$HOOK_REGISTERED" -eq 1 ]]; then
  echo "OK   [6] manifest registration — UserPromptSubmit array contains dhx-verify-drift-gate (presence-based, D-21)"
  PASS=$((PASS + 1))
else
  echo "FAIL [6] manifest missing dhx-verify-drift-gate entry (expected exactly 1, got $HOOK_REGISTERED)"
  FAIL=$((FAIL + 1))
fi

# --- Scenario [7]: .prompt field extraction (Pitfall 1) ---
# Full empirical 6-field schema; if the hook read .user_prompt instead of
# .prompt, jq returns empty, the hook silent-exits, and this scenario fails.
refresh_fixtures 12-test false false false
PAYLOAD=$(jq -n --arg c "$TMP" \
  '{session_id:"probe", transcript_path:"", cwd:$c, permission_mode:"default",
    hook_event_name:"UserPromptSubmit", prompt:"/dhx:test 12"}')
OUTPUT=$(run_hook "$PAYLOAD")
assert_blocks "[7] .prompt field extraction works (Pitfall 1)" "$OUTPUT"

# --- Scenario [8]: dot-phase 10.1 resolution (Pitfall 3 + D-13) ---
refresh_fixtures 10.1-test false false false
PAYLOAD=$(build_payload "/dhx:test 10.1")
OUTPUT=$(run_hook "$PAYLOAD")
assert_blocks_contains "[8] dot-phase 10.1 resolves correctly (Pitfall 3 + D-13)" \
  "$OUTPUT" "phase 10.1"

echo "# --- Scenario [9]: D-17 fail-open path (STATE.md missing + bare /dhx:test) ---"
refresh_fixtures 12-test false false false true   # 5th arg = state_md_absent
PAYLOAD=$(build_payload "/dhx:test")              # bare, no args — forces fallback
# Capture stdout and stderr to separate vars to assert both halves of the contract.
OUT=$( (cd "$TMP" && HOME="$TMP" bash "$HOOK" <<< "$PAYLOAD") 2>/dev/null )
ERR=$( (cd "$TMP" && HOME="$TMP" bash "$HOOK" <<< "$PAYLOAD") 2>&1 >/dev/null )
EXPECTED_STDERR="dhx-verify-drift-gate: STATE.md unreadable; gate skipped"
if [ -z "$OUT" ] && [[ "$ERR" == *"$EXPECTED_STDERR"* ]]; then
  echo "OK   [9] D-17 fail-open: empty stdout + exact stderr warning (D-19 path coverage)"
  PASS=$((PASS + 1))
else
  echo "FAIL [9] D-17 fail-open expected empty stdout + stderr containing '$EXPECTED_STDERR'; got stdout='$(printf '%s' "$OUT" | head -c 100)' stderr='$(printf '%s' "$ERR" | head -c 200)'"
  FAIL=$((FAIL + 1))
fi

# --- Scenario [10]: milestone-cumulative STATE.md must NOT mis-fire Exit-A ---
# Regression test for the D-06 design flaw surfaced by the Task 5.5 live-fire.
# The phase dir is COMPLETE (a *-PLAN.md AND a matching *-SUMMARY.md, no `- [ ]`
# checkbox, VERIFICATION.md absent). The STATE.md carries the REAL
# milestone-cumulative `progress` shape — total_plans/completed_plans span the
# whole milestone (9 of 12 done), NOT this phase. The original hook parsed those
# counts as the Exit-A fallback, so `9 < 12` forced "Phase has incomplete plans"
# for every in-progress milestone. The fixed hook is phase-scoped: it ignores
# `progress.*` entirely and counts #PLAN vs #SUMMARY in the phase dir → #SUMMARY
# == #PLAN → Exit-A does NOT fire → no-incomplete (collapsed B/C) wording.
refresh_fixtures 12-test false false false   # complete phase (PLAN+SUMMARY)
cat > "$TMP/.planning/STATE.md" <<'EOF'
---
current_phase: 12
stopped_at: Phase 12 context gathered
progress:
  total_phases: 9
  completed_phases: 5
  total_plans: 12
  completed_plans: 9
---
EOF
PAYLOAD=$(build_payload "/dhx:test 12")
OUTPUT=$(run_hook "$PAYLOAD")
if jq -e '.decision == "block"
          and (.reason | contains("Lane A"))
          and (.reason | contains("Lane B"))
          and (.reason | contains("Lane C"))
          and ((.reason | contains("Phase has incomplete plans")) | not)' \
     <<< "$OUTPUT" >/dev/null 2>&1; then
  echo "OK   [10] milestone-cumulative STATE.md (9<12) does NOT mis-fire Exit-A — phase-scoped count holds"
  PASS=$((PASS + 1))
else
  echo "FAIL [10] milestone-cumulative STATE.md mis-fired Exit-A — phase-scoped count regressed; got: $(printf '%s' "$OUTPUT" | head -c 200)"
  FAIL=$((FAIL + 1))
fi

# --- Scenario [11]: WR-01 — /dhx:test-prefixed but NOT /dhx:test → silent allow ---
# The prefix filter is word-boundary anchored: `/dhx:test` must be followed by
# whitespace or end-of-string. /dhx:testify and /dhx:test-harness start with the
# literal `/dhx:test` but are different commands — the gate must NOT fire.
refresh_fixtures 12-test false false false
PAYLOAD=$(build_payload "/dhx:testify 12")
OUTPUT=$(run_hook "$PAYLOAD")
assert_silent "[11] /dhx:testify 12 → silent allow (WR-01 prefix-glob anchor)" "$OUTPUT"
PAYLOAD=$(build_payload "/dhx:test-harness 12")
OUTPUT=$(run_hook "$PAYLOAD")
assert_silent "[11b] /dhx:test-harness 12 → silent allow (WR-01 prefix-glob anchor)" "$OUTPUT"

# --- Scenario [12]: WR-02 — run-prefixed but NOT the `run` subcommand → BLOCK ---
# The subcommand filter is word-boundary anchored too. `/dhx:test runner` is NOT
# the `run` subcommand — with no resolvable phase arg and a STATE.md current_phase
# the hook must proceed to the gate and BLOCK, not bypass as a subcommand.
refresh_fixtures 12-test false false false
cat > "$TMP/.planning/STATE.md" <<'EOF'
---
current_phase: 12
---
EOF
PAYLOAD=$(build_payload "/dhx:test runner")
OUTPUT=$(run_hook "$PAYLOAD")
assert_blocks "[12] /dhx:test runner → BLOCK, not run-subcommand bypass (WR-02)" "$OUTPUT"

# --- Scenario [13]: CR-01 — annotated current_phase must resolve to bare phase ---
# `current_phase: 12 (wave 3 in progress)` must parse as phase 12. The earlier
# `awk gsub(/[^0-9.]/,"")` corrupted this to `123` (no 123-* dir → silent skip).
# The fixed bash-native [[ =~ ]] extraction takes the leading N token → block 12.
refresh_fixtures 12-test false false false
cat > "$TMP/.planning/STATE.md" <<'EOF'
---
current_phase: 12 (wave 3 in progress)
stopped_at: Phase 12 context gathered
---
EOF
PAYLOAD=$(build_payload "/dhx:test")   # bare — forces STATE.md resolution
OUTPUT=$(run_hook "$PAYLOAD")
assert_blocks_contains "[13] annotated current_phase '12 (wave 3 in progress)' → block phase 12 (CR-01)" \
  "$OUTPUT" "phase 12"

# --- Scenario [14]: WR-03 — two dirs matching ${PHASE}-* → fail-open ---
# A renamed-but-not-removed stale phase dir leaves two ${PHASE}-* matches. The
# fixed hook collects all matches, detects ambiguity, and fails open with a
# one-line stderr warning (D-17 stance) rather than silently picking one.
refresh_fixtures 12-test false false false
mkdir -p "$TMP/.planning/phases/12-alpha" "$TMP/.planning/phases/12-beta"
PAYLOAD=$(build_payload "/dhx:test 12")
OUT=$( (cd "$TMP" && HOME="$TMP" bash "$HOOK" <<< "$PAYLOAD") 2> "$TMP/err14" )
ERR=$(cat "$TMP/err14")
EXPECTED_AMBIG="dhx-verify-drift-gate: phase 12 matches"
if [ -z "$OUT" ] && [[ "$ERR" == *"$EXPECTED_AMBIG"* ]]; then
  echo "OK   [14] ambiguous phase-dir glob → fail-open: empty stdout + stderr warning (WR-03)"
  PASS=$((PASS + 1))
else
  echo "FAIL [14] ambiguous phase-dir expected empty stdout + stderr containing '$EXPECTED_AMBIG'; got stdout='$(printf '%s' "$OUT" | head -c 100)' stderr='$(printf '%s' "$ERR" | head -c 200)'"
  FAIL=$((FAIL + 1))
fi

# --- Scenario [15]: garbage / non-JSON stdin → graceful exit 0 (silent) ---
# The hook reads stdin via `jq -r '.prompt // empty'`; non-JSON input makes jq
# fail, the `2>/dev/null` swallows the diagnostic, PROMPT is empty → silent exit.
refresh_fixtures 12-test false false false
OUTPUT=$( (cd "$TMP" && HOME="$TMP" bash "$HOOK" <<< 'this is not json at all {{{') 2>/dev/null )
assert_silent "[15] garbage non-JSON stdin → graceful silent exit 0" "$OUTPUT"
OUTPUT=$( (cd "$TMP" && HOME="$TMP" bash "$HOOK" <<< '') 2>/dev/null )
assert_silent "[15b] empty stdin → graceful silent exit 0" "$OUTPUT"

# --- Scenario [16]: Exit-D awaiting-upstream lane — recognized → silent allow ---
# Closure class: {phase}-UAT.md status:complete + upstream-routing marker
# (CONTEXT.md phase_status OR ROADMAP.md `Closed `awaiting-upstream`` line) →
# Exit-D fires silently without operator intervention. Fixture mirrors Phase 11
# shape: 3 *-PLAN.md files + 1 *-SUMMARY.md → #SUMMARY (1) < #PLAN (3) so
# without Exit-D, Exit-A would fire with "Phase has incomplete plans".
#
# [16] = ROADMAP.md marker route (the live Phase 11 shape on this repo).

refresh_fixtures 99-test false true false   # PLAN+no-SUMMARY for plan 99-01
# Add the extra by-design non-executing plans (no matching SUMMARY) — gets
# #SUMMARY (1) < #PLAN (3) shape the bare Exit-A signal trips on.
cat > "$TMP/.planning/phases/99-test/99-02-PLAN.md" <<EOF
# Plan
non-executing per D-08 contingency
EOF
cat > "$TMP/.planning/phases/99-test/99-03-PLAN.md" <<EOF
# Plan
non-executing per D-08 contingency
EOF
cat > "$TMP/.planning/phases/99-test/99-UAT.md" <<EOF
---
phase: 99
type: uat
status: complete
created: 2026-05-17
verifier: /dhx:test 99
scope: plan-1-only-spot-check
---
# Phase 99 UAT
EOF
cat > "$TMP/.planning/ROADMAP.md" <<'EOF'
# Roadmap
- [x] **Phase 99: Foo (FOO-99)** — Closed `awaiting-upstream` 2026-05-17
EOF
PAYLOAD=$(build_payload "/dhx:test 99")
OUTPUT=$(run_hook "$PAYLOAD")
assert_silent "[16] Exit-D via ROADMAP.md marker → silent allow (UAT.md status:complete + Closed awaiting-upstream)" "$OUTPUT"

# [16b] = CONTEXT.md marker route — drop ROADMAP.md, add CONTEXT.md frontmatter
refresh_fixtures 99-test false true false
cat > "$TMP/.planning/phases/99-test/99-02-PLAN.md" <<EOF
# Plan
non-executing
EOF
cat > "$TMP/.planning/phases/99-test/99-03-PLAN.md" <<EOF
# Plan
non-executing
EOF
cat > "$TMP/.planning/phases/99-test/99-UAT.md" <<EOF
---
phase: 99
type: uat
status: complete
---
EOF
cat > "$TMP/.planning/phases/99-test/99-CONTEXT.md" <<EOF
---
phase: 99
phase_status: awaiting-upstream
---
# Phase 99 CONTEXT
EOF
PAYLOAD=$(build_payload "/dhx:test 99")
OUTPUT=$(run_hook "$PAYLOAD")
assert_silent "[16b] Exit-D via CONTEXT.md phase_status marker → silent allow" "$OUTPUT"

# [16c] = real-world Phase 11 shape — phase 11 + line text verbatim from
# .planning/ROADMAP.md:54 (single-quoted HEREDOC keeps the backticks literal).
refresh_fixtures 11-test false true false
cat > "$TMP/.planning/phases/11-test/11-02-PLAN.md" <<EOF
# Plan
non-executing per D-08
EOF
cat > "$TMP/.planning/phases/11-test/11-03-PLAN.md" <<EOF
# Plan
non-executing per D-08
EOF
cat > "$TMP/.planning/phases/11-test/11-UAT.md" <<EOF
---
phase: 11
type: uat
status: complete
created: 2026-05-15
verifier: /dhx:test 11
scope: plan-1-only-spot-check
---
EOF
cat > "$TMP/.planning/ROADMAP.md" <<'EOF'
# Roadmap
- [x] **Phase 11: Sandboxed-CC harness library + SCHEMA-02 main matrix (SCHEMA-02)** — Closed `awaiting-upstream` 2026-05-15. Plan 11-01 tractability spike returned **NO** on CC 2.1.142.
EOF
PAYLOAD=$(build_payload "/dhx:test 11")
OUTPUT=$(run_hook "$PAYLOAD")
assert_silent "[16c] Exit-D real-world Phase 11 shape → silent allow (verbatim ROADMAP.md L54 marker)" "$OUTPUT"

# --- Scenario [17]: Exit-D fall-through paths → Exit-A wave-slice block ---
# Locks the fail-open invariant: missing UAT.md, status:incomplete, OR missing
# routing marker → Exit-D does NOT fire; falls through to Exit-A which sees
# #SUMMARY (1) < #PLAN (3) and emits "Phase has incomplete plans" block-JSON.

# [17] = UAT.md status:incomplete (with valid marker) → fall through to Exit-A
refresh_fixtures 99-test false true false
cat > "$TMP/.planning/phases/99-test/99-02-PLAN.md" <<EOF
# Plan
EOF
cat > "$TMP/.planning/phases/99-test/99-03-PLAN.md" <<EOF
# Plan
EOF
cat > "$TMP/.planning/phases/99-test/99-UAT.md" <<EOF
---
phase: 99
type: uat
status: incomplete
---
EOF
cat > "$TMP/.planning/ROADMAP.md" <<'EOF'
# Roadmap
- [x] **Phase 99: Foo (FOO-99)** — Closed `awaiting-upstream` 2026-05-17
EOF
PAYLOAD=$(build_payload "/dhx:test 99")
OUTPUT=$(run_hook "$PAYLOAD")
assert_blocks_contains "[17] UAT.md status:incomplete → fall through to Exit-A (fail-open)" \
  "$OUTPUT" "Phase has incomplete plans"

# [17b] = UAT.md missing entirely → fall through to Exit-A
refresh_fixtures 99-test false true false
cat > "$TMP/.planning/phases/99-test/99-02-PLAN.md" <<EOF
# Plan
EOF
cat > "$TMP/.planning/phases/99-test/99-03-PLAN.md" <<EOF
# Plan
EOF
cat > "$TMP/.planning/ROADMAP.md" <<'EOF'
# Roadmap
- [x] **Phase 99: Foo (FOO-99)** — Closed `awaiting-upstream` 2026-05-17
EOF
PAYLOAD=$(build_payload "/dhx:test 99")
OUTPUT=$(run_hook "$PAYLOAD")
assert_blocks_contains "[17b] UAT.md missing → fall through to Exit-A (fail-open)" \
  "$OUTPUT" "Phase has incomplete plans"

# [17c] = UAT.md status:complete BUT no routing marker (no ROADMAP line, no
# CONTEXT.md phase_status) → structural marker required, not optional.
refresh_fixtures 99-test false true false
cat > "$TMP/.planning/phases/99-test/99-02-PLAN.md" <<EOF
# Plan
EOF
cat > "$TMP/.planning/phases/99-test/99-03-PLAN.md" <<EOF
# Plan
EOF
cat > "$TMP/.planning/phases/99-test/99-UAT.md" <<EOF
---
phase: 99
type: uat
status: complete
---
EOF
# Intentionally NO ROADMAP.md and NO CONTEXT.md with phase_status — Exit-D
# must NOT fire on UAT alone.
PAYLOAD=$(build_payload "/dhx:test 99")
OUTPUT=$(run_hook "$PAYLOAD")
assert_blocks_contains "[17c] UAT.md complete but no routing marker → fall through to Exit-A (structural marker required)" \
  "$OUTPUT" "Phase has incomplete plans"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
