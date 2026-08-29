#!/usr/bin/env bash
# probe-grep-satisfies-read-before-edit.sh — version-gated behavior probe.
#
# Backs the read-state axis of the read-guard memory
# (reference-cc-native-read-block-vs-dhx-advisory) and the companion to
# probe-read-guard-native-enforcement-tripwire.sh.
#
# WHAT THIS PINS (the open boundary): CC 2.1.160 CHANGELOG —
#   "Edit no longer requires a separate Read after viewing a file with `grep`:
#    single-file `grep`/`egrep`/`fgrep` commands now satisfy the read-before-edit
#    check."
# i.e. CC's NATIVE read-state (the thing that emits "File has not been read yet")
# gains a NEW satisfier in 2.1.160: a single-file bash grep. Before 2.1.160 only
# the Read tool and a Write-TOOL-created file registered read-state; a bash
# `cat`/`grep` did NOT (troubleshooting.md:587; the read-guard memory's nuance
# paragraph). The tripwire probe asserts the TOTALLY-unread Edit/Write still
# blocks (and it still does on 2.1.160+ — that axis is unchanged). This probe
# asserts the ORTHOGONAL axis the tripwire cannot see: does a prior single-file
# grep now satisfy the check?
#
# SEMANTICS (version-gated assertion — distinct from the supersession-watchdog
# convention; this is Convention B: exit 0 = pass):
#   The asserted cell's EXPECTED result is keyed on the running CC version:
#     CC <  2.1.160 : expected BLOCK  (grep does NOT yet satisfy)
#     CC >= 2.1.160 : expected ALLOW  (grep satisfies — the changelog claim)
#   exit 0 + pass         = asserted cell's observed == version-expected.
#   exit 1 + fail         = asserted cell's observed CONTRADICTS the expectation
#                           (e.g. >=2.1.160 still blocked → changelog false /
#                           regressed; or <2.1.160 allowed → unexpected). Revisit
#                           the read-guard memory + decisions row.
#   exit 0 + skipped      = inconclusive (no auth, subprocess auth failure, model
#                           declined/deviated from the tool sequence, or the model
#                           used Read despite instruction) — NOT a pass, NOT a fail.
#
# BASELINE ALREADY ON RECORD (in-session, NOT this script): on 2.1.159, profile
# b, 2026-06-03 — a live-session single-file `grep beta <f>` followed by an Edit
# (no Read) hard-errored "File has not been read yet." That is the pre-change
# BLOCK baseline, captured the same way the memory's M2 / Probe-1e observations
# were (a sandboxed claude -p cannot be driven here without ANTHROPIC_API_KEY).
# Recorded at tests/probes/.results/grep-read-state/2.1.159/outcome.json with
# method=in-session-live. This SCRIPT confirms the >=2.1.160 ALLOW flip when an
# operator runs it with an API key after upgrading.
#
# OPEN BOUNDARIES (deliberately NOT asserted — no silent caps):
#   - MULTI-FILE grep (`grep PAT f1 f2`, `grep -r`): the changelog says
#     "single-file". OBSERVED 2026-06-03: BLOCK (does NOT satisfy — matches the
#     "single-file" wording). Recorded in the decisions row + read-guard memory;
#     not yet exit-asserted here (add a cell if a consumer ever depends on it).
#   - The OBSERVATIONAL Grep-TOOL cell below characterizes whether CC's own Grep
#     tool (distinct from a bash `grep` command — the changelog named only the
#     bash commands) also satisfies the check. OBSERVED 2026-06-03: BLOCK — the
#     Grep TOOL does NOT satisfy (a Grep-tool view then Edit with no Read
#     hard-errored "File has not been read yet"; control no-view Edit also
#     BLOCKed → trustworthy). Only bash grep/egrep/fgrep COMMANDS satisfy, never
#     CC's Grep tool. Measured out-of-band via a LIVE-DIR `claude -p` child (no
#     API key — the native Grep tool is absent from interactive deferred-tools
#     sessions + subagents, but a standard `claude -p` against the LIVE
#     CLAUDE_CONFIG_DIR has it + auths via live OAuth; sidesteps the 2026-05-24
#     sandbox cred-seeding hazard). Cell B still records it; not exit-asserted
#     (running Cell B needs an API key).
#
# METHOD (mirrors the tripwire): drive a real `claude -p` subprocess against a
# sandbox CLAUDE_CONFIG_DIR over a file created OUT-OF-BAND via printf (NOT the
# Write tool — a Write-tool file is "seen"), instructing the EXACT tool sequence
# and forbidding the Read tool, then scan the stream for CC's native block string
# vs the Edit-success string. The dhx guard is non-blocking additionalContext, so
# a HARD tool error is unambiguously CC-native.
#
# Each cell is driven with an EXPLICIT `--tools` surface (control: Edit; Cell A:
# Bash Edit; Cell B: Grep Edit). Two reasons: a `claude -p` child does not surface
# the Grep tool by default on this machine, so Cell B could otherwise never observe
# anything but "precondition tool did not run"; and naming the surface makes the
# "do not use Read" constraint STRUCTURAL rather than an instruction the model is
# free to ignore. Results are written beside this script (PROBE_DIR), never relative
# to $PWD, and a `skipped` run will not overwrite a real row already on record.
#
# AUTH: ANTHROPIC_API_KEY required (a sandboxed claude -p authenticates ONLY via
# an inherited API key; seeding OAuth credentials_file is UNSAFE — rotates &
# invalidates the source credential, measured 2026-05-24, see the tripwire header).
# No key → emit skipped, exit 0.
#
# Operator-invoked (NOT via run-probes.sh's 30s loop — claude -p turns exceed it;
# SAFE_FOR_LIVE=no keeps it out of the default pre-commit suite). Run:
#   ANTHROPIC_API_KEY=sk-ant-... bash tests/probes/probe-grep-satisfies-read-before-edit.sh
#
# SAFE_FOR_LIVE: no    (spawns claude -p subprocesses; sandbox CLAUDE_CONFIG_DIR + mktemp targets)
# RUNTIME: ~90-180s    (three claude -p turns: control + single-file-grep + grep-tool)
set -uo pipefail

BLOCK_RE='has not been read yet'
EDIT_OK_RE='updated successfully|has been updated'
AUTH_FAIL_RE='Not logged in|Please run /login|Invalid API key|invalid x-api-key|authentication_error|authentication_failed|Invalid authentication credentials|Failed to authenticate|api_error_status":401|Credit balance is too low|OAuth token has expired'
# The model defeating the test by reading first → cell is invalid, never a result.
READ_USED_RE='"name":"Read"'

SANDBOX=$(mktemp -d)
WORK=$(mktemp -d)
trap 'rm -rf "$SANDBOX" "$WORK"' EXIT

CC_VERSION=$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")

# ver_ge A B → 0 (true) iff A >= B by semantic-version sort.
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }

if ver_ge "$CC_VERSION" "2.1.160"; then
  EXPECTED="ALLOW"
else
  EXPECTED="BLOCK"   # also the value when CC_VERSION=unknown (fail toward pre-change)
fi

# Results land beside THIS script, never relative to $PWD. The previous form
# ("tests/probes/.results/...") silently wrote elsewhere — or nowhere — whenever the
# probe was invoked from any directory but the repo root, and the `|| true` guards
# turned that into a clean exit with no row on record. A dropped row is worse than a
# loud failure: the version series is the whole point of this probe.
PROBE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

emit_outcome() { # $1 = conclusion, $2 = note
  local outdir="$PROBE_DIR/.results/grep-read-state/${CC_VERSION}"
  # A `skipped` run must never clobber a real result already on record for this same
  # CC version. Without this, the overwhelmingly common invocation on this machine —
  # no ANTHROPIC_API_KEY, so the auth branch fires immediately — silently replaces a
  # measured pass/fail row with a content-free "no ANTHROPIC_API_KEY" stub. Observed
  # doing exactly that on 2026-08-29 while regression-testing the results-path fix.
  if [ "$1" = "skipped" ] && [ -f "$outdir/outcome.json" ] \
     && ! grep -q '"conclusion":"skipped"' "$outdir/outcome.json" 2>/dev/null; then
    echo "INFO emit_outcome: $CC_VERSION already holds a non-skipped result — keeping it, skip NOT recorded" >&2
    return 0
  fi
  if ! mkdir -p "$outdir" 2>/dev/null; then
    echo "WARN emit_outcome: cannot create $outdir — result NOT recorded" >&2
    return 0
  fi
  if ! printf '{"probe":"grep-satisfies-read-before-edit","cc_version":"%s","exit_code_convention":"exit_0_means_pass","expected_single_file_grep":"%s","conclusion":"%s","note":"%s","ts":%s}\n' \
    "$CC_VERSION" "$EXPECTED" "$1" "$2" "$(date +%s)" > "$outdir/outcome.json" 2>/dev/null; then
    echo "WARN emit_outcome: cannot write $outdir/outcome.json — result NOT recorded" >&2
    return 0
  fi
  echo "INFO recorded → $outdir/outcome.json" >&2
}

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "SKIP grep-satisfies-read-before-edit: no ANTHROPIC_API_KEY (a sandboxed claude -p cannot auth via OAuth credentials_file safely — re-run with an API key). The 2.1.159 pre-change BLOCK baseline is on record from an in-session observation (see header)."
  emit_outcome "skipped" "no ANTHROPIC_API_KEY"
  exit 0
fi

# Drive one claude -p turn with a fixed prompt; return the captured stream.
# The tool surface is passed EXPLICITLY per cell (--tools last, so the variadic list
# cannot swallow a following flag). Without it, Cell B could never measure anything:
# a `claude -p` child does not surface the Grep tool by default on this machine, so the
# cell tripped "precondition tool did not run" and returned INCONCLUSIVE forever
# (measured 2026-08-29). Naming the surface also makes the cells structurally airtight —
# the model cannot reach for Read when Read is not on the list.
drive() { # $1 = prompt; $2.. = exact tool names to expose
  local prompt="$1"; shift
  CLAUDE_CONFIG_DIR="$SANDBOX/.claude" timeout 120 \
    claude -p "$prompt" --output-format stream-json --include-hook-events --verbose \
      --tools "$@" 2>&1 || true
}

PASS=0; FAIL=0; INCONCLUSIVE=0

# ---- Cell C0 (control): no prior view action → Edit MUST block on ALL versions.
# Proves the harness can see a real block; if this is inconclusive the whole run is
# untrustworthy (auth / model deviation), so the asserted cell degrades to skipped.
C0_TGT="$WORK/ctrl.txt"; printf 'alpha\nbeta\ngamma\n' > "$C0_TGT"
C0_OUT="$(drive "Use the Edit tool to change the word 'beta' to 'BETA' in ${C0_TGT}. Do NOT read the file first — attempt the Edit directly. Do NOT use any other tool. If the tool errors, report the exact error text verbatim." Edit)"

CONTROL_OK=0
if grep -qiE "$AUTH_FAIL_RE" <<< "$C0_OUT"; then
  echo "SKIP control → subprocess could not authenticate — whole run inconclusive"
  emit_outcome "skipped" "control cell: auth failure"
  exit 0
elif grep -qi "$BLOCK_RE" <<< "$C0_OUT"; then
  echo "OK   control (no-action Edit) → CC blocked (harness sees the native block)"
  CONTROL_OK=1
else
  echo "WARN control (no-action Edit) did NOT block — harness untrustworthy (model may have deviated). Asserted cell will degrade to skipped."
fi

# ---- Cell A (asserted): single-file bash grep, THEN Edit, no Read.
A_TGT="$WORK/single-grep.txt"; printf 'alpha\nbeta\ngamma\n' > "$A_TGT"
A_OUT="$(drive "Do EXACTLY this and nothing else, in order:
1. Use the Bash tool to run this single command: grep beta ${A_TGT}
2. Then use the Edit tool to change the word 'beta' to 'BETA' in ${A_TGT}.
CRITICAL CONSTRAINTS: Do NOT use the Read tool at any point. Use ONLY the Bash tool (step 1) and the Edit tool (step 2). If the Edit tool returns an error, report the exact error text verbatim." Bash Edit)"

# Progress goes to STDERR, the verdict to STDOUT — the caller captures this in $(...),
# so anything printed on stdout other than the verdict is either lost or corrupts it.
# Previously every SKIP/observed line was written to stdout and then discarded by the
# caller's `| tail -1`, so an operator watching a run saw the bare verdict and never
# learned WHY a cell was inconclusive.
classify_grep_cell() { # $1=label $2=out $3=precondition-regex(tool that should have run)
  local label="$1" out="$2" pre_re="$3" observed=""
  if grep -qiE "$AUTH_FAIL_RE" <<< "$out"; then echo "SKIP $label → auth failure" >&2; observed="INCONCLUSIVE";
  elif grep -qE "$READ_USED_RE" <<< "$out"; then echo "SKIP $label → model used Read despite instruction (cell invalid)" >&2; observed="INCONCLUSIVE";
  elif ! grep -qE "$pre_re" <<< "$out"; then echo "SKIP $label → precondition tool did not run (model deviated, or the tool is absent from the --tools surface)" >&2; observed="INCONCLUSIVE";
  elif grep -qi "$BLOCK_RE" <<< "$out"; then echo "  → $label observed BLOCK" >&2; observed="BLOCK";
  elif grep -qiE "$EDIT_OK_RE" <<< "$out"; then echo "  → $label observed ALLOW (Edit succeeded after grep)" >&2; observed="ALLOW";
  else echo "SKIP $label → inconclusive (no block, no success string)" >&2; observed="INCONCLUSIVE"; fi
  echo "$observed"
}

A_OBSERVED="$(classify_grep_cell "single-file grep → Edit" "$A_OUT" '"name":"Bash"' | tail -1)"

if [ "$CONTROL_OK" -ne 1 ] || [ "$A_OBSERVED" = "INCONCLUSIVE" ]; then
  echo "SKIP grep-satisfies-read-before-edit: inconclusive (control_ok=$CONTROL_OK, single-file-grep observed=$A_OBSERVED). No trustworthy result; re-run with working auth."
  INCONCLUSIVE=1
elif [ "$A_OBSERVED" = "$EXPECTED" ]; then
  echo "OK   single-file grep → Edit: observed=$A_OBSERVED == expected=$EXPECTED (CC $CC_VERSION)"
  PASS=1
else
  echo "FAIL single-file grep → Edit: observed=$A_OBSERVED != expected=$EXPECTED (CC $CC_VERSION) — changelog claim contradicted or behavior regressed. Revisit the read-guard memory + a decisions.md row."
  FAIL=1
fi

# ---- Cell B (observational only): Grep TOOL, then Edit, no Read / no Bash.
# The changelog named bash grep/egrep/fgrep, NOT the Grep tool. Record observed
# for whoever pins this boundary later; do NOT gate exit on it.
B_TGT="$WORK/grep-tool.txt"; printf 'alpha\nbeta\ngamma\n' > "$B_TGT"
B_OUT="$(drive "Do EXACTLY this and nothing else, in order:
1. Use the Grep tool with pattern 'beta' and path ${B_TGT}.
2. Then use the Edit tool to change the word 'beta' to 'BETA' in ${B_TGT}.
CRITICAL CONSTRAINTS: Do NOT use the Read tool or the Bash tool at any point. Use ONLY the Grep tool (step 1) and the Edit tool (step 2). If the Edit tool returns an error, report the exact error text verbatim." Grep Edit)"
B_OBSERVED="$(classify_grep_cell "Grep-tool → Edit (observational)" "$B_OUT" '"name":"Grep"' | tail -1)"
echo "INFO Grep-tool → Edit: observed=$B_OBSERVED (observational — not asserted; pins the bash-grep-vs-Grep-tool boundary)"

# ---- Roll-up.
if [ "$FAIL" -ne 0 ]; then
  emit_outcome "fail" "single-file grep observed != version-expected ($EXPECTED); grep-tool observed=$B_OBSERVED"
  echo "[FAIL] grep-satisfies-read-before-edit"
  exit 1
fi
if [ "$PASS" -eq 1 ]; then
  emit_outcome "pass" "single-file grep observed=$EXPECTED as expected; grep-tool observed=$B_OBSERVED"
  echo "[PASS] grep-satisfies-read-before-edit: single-file grep read-state behavior matches CC $CC_VERSION expectation ($EXPECTED)"
  exit 0
fi
emit_outcome "skipped" "inconclusive; grep-tool observed=$B_OBSERVED"
echo "[SKIP] grep-satisfies-read-before-edit: inconclusive — no trustworthy assertion produced"
exit 0
