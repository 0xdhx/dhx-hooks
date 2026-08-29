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
#   - The OBSERVATIONAL COMPOUND cell (Cell D) pins the half of the rule that is
#     operationally load-bearing and went unpinned until 2026-08-29: a `;`-compound
#     command disqualifies the satisfier EVEN with a single literal absolute path and
#     grep in first position. Expect BLOCK. This corrects a superseded reading that
#     blamed an unexpanded `$VAR` for the block — defining a variable requires a `;`,
#     so that test could never separate the variable from the compound. A lone simple
#     `grep PAT "$HOME/f.txt"` ALLOWs; `$TMPDIR` and shell-locals BLOCK.
#
# METHOD (mirrors the tripwire): drive a real `claude -p` subprocess against a
# sandbox CLAUDE_CONFIG_DIR over a file created OUT-OF-BAND via printf (NOT the
# Write tool — a Write-tool file is "seen"), instructing the EXACT tool sequence
# and forbidding the Read tool, then scan the stream for CC's native block string
# vs the Edit-success string. The dhx guard is non-blocking additionalContext, so
# a HARD tool error is unambiguously CC-native.
#
# Each cell is driven with an EXPLICIT `--tools` surface (control: Edit; Cell A:
# Bash Edit; Cell B: Grep Edit; Cell D: Bash Edit). Two reasons: a `claude -p` child does not surface
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
# THE KEY EXISTS ON THIS HOST: `~/.env-keys` (chmod 600) holds ANTHROPIC_API_KEY.
# A running Claude Code session carries the env snapshot it launched with, so a
# session started before the key was added reports it unset and `dhx-keys status`
# shows STALE-restart. You do NOT need to restart to run this probe — it is a
# subprocess, so sourcing the file in the invoking shell is enough:
#   set -a; . ~/.env-keys; set +a; bash tests/probes/probe-grep-satisfies-read-before-edit.sh
# Never echo the value; `dhx-keys status` prints length + last-4 only.
#
# Operator-invoked (NOT via run-probes.sh's 30s loop — claude -p turns exceed it;
# SAFE_FOR_LIVE=no keeps it out of the default pre-commit suite).
#
# SAFE_FOR_LIVE: no    (spawns claude -p subprocesses; sandbox CLAUDE_CONFIG_DIR + mktemp targets)
# RUNTIME: ~120-240s   (four claude -p turns: control + single-file-grep + grep-tool + compound)
set -uo pipefail

BLOCK_RE='has not been read yet'
EDIT_OK_RE='updated successfully|has been updated'
AUTH_FAIL_RE='Not logged in|Please run /login|Invalid API key|invalid x-api-key|authentication_error|authentication_failed|Invalid authentication credentials|Failed to authenticate|api_error_status":401|Credit balance is too low|OAuth token has expired'
# The model defeating the test by reading first → cell is invalid, never a result.
READ_USED_RE='"name":"Read"'
# CC refuses a Bash grep whose file arg escapes the session's allowed working dirs.
# The precondition regex cannot see this (a Bash call DID happen), so without an
# explicit detector the refusal masquerades as a genuine BLOCK — a false FAIL.
SEARCH_REFUSED_RE='was blocked\. For security, Claude Code may only search'

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
  # Emit the observed cells as FIRST-CLASS fields, not just prose in `note`. The two
  # hand-written baselines (2.1.159 / 2.1.161) carry method + observed_* and are what a
  # consumer actually queries; a generated row without them is not comparable to them.
  # `${x:-}` throughout: emit_outcome also fires on the early auth-skip path, before any
  # cell variable exists, and `set -u` would abort there.
  if ! printf '{"probe":"grep-satisfies-read-before-edit","cc_version":"%s","exit_code_convention":"exit_0_means_pass","expected_single_file_grep":"%s","conclusion":"%s","method":"sandbox-claude-p","observed_no_view_control":"%s","observed_single_file_grep":"%s","observed_grep_tool":"%s","observed_compound_literal_path":"%s","note":"%s","ts":%s}\n' \
    "$CC_VERSION" "$EXPECTED" "$1" \
    "$([ "${CONTROL_OK:-0}" = "1" ] && echo BLOCK || echo NOT-OBSERVED)" \
    "${A_OBSERVED:-NOT-RUN}" "${B_OBSERVED:-NOT-RUN}" "${D_OBSERVED:-NOT-RUN}" \
    "$2" "$(date +%s)" > "$outdir/outcome.json" 2>/dev/null; then
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
# --add-dir "$WORK" is LOAD-BEARING, not hygiene. Targets are created under
# `mktemp -d` (/tmp), which is outside the child's allowed working directories, and
# CC refuses a Bash `grep` whose file argument escapes them:
#   grep in '<path>' was blocked. For security, Claude Code may only search for
#   patterns in files from the allowed working directories for this session: '<dir>'.
# The precondition grep then never runs, no read-state is registered, and the Edit
# blocks — so Cell A reported BLOCK, tripped the version gate, and exited FAIL as
# though the 2.1.160 changelog claim had regressed. It had not; the probe was
# measuring its own sandbox's directory policy. Diagnosed 2026-08-29 by dumping the
# stream: the tool_result on the grep is an explicit refusal, and the identical
# prompt against a LIVE config dir (where /tmp is reachable) ALLOWs.
# Note this failure mode is invisible without instrumentation — the cell's
# precondition regex only checks that a Bash call HAPPENED, not that it succeeded.
#
# --permission-mode acceptEdits is the SECOND half of the same problem. With
# --add-dir alone the grep succeeds but the Edit dies on a permission gate:
#   Claude requested permissions to write to <path>, but you haven't granted it yet.
# A bare sandbox config has no allow rules and a headless child has nobody to ask,
# so the Edit never reaches a read-state verdict and the cell reads INCONCLUSIVE.
# The two gates fire in a fixed order — read-state FIRST, write-permission SECOND
# (measured 2026-08-29: without --add-dir the Edit returns "File has not been read
# yet"; with it, the same Edit returns the permission error instead) — which is why
# the control cell remains the trustworthiness anchor: it must still BLOCK on
# read-state UNDER acceptEdits, proving the mode did not disable the thing under
# test. If the control ever stops blocking here, this probe is measuring nothing.
drive() { # $1 = prompt; $2.. = exact tool names to expose
  local prompt="$1"; shift
  CLAUDE_CONFIG_DIR="$SANDBOX/.claude" timeout 120 \
    claude -p "$prompt" --output-format stream-json --include-hook-events --verbose \
      --permission-mode acceptEdits --add-dir "$WORK" --tools "$@" 2>&1 || true
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
  elif grep -qE "$SEARCH_REFUSED_RE" <<< "$out"; then echo "SKIP $label → the precondition grep was REFUSED (target outside the child's allowed working dirs) — this is NOT a read-state observation; check --add-dir" >&2; observed="INCONCLUSIVE";
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

# ---- Cell D (observational only): COMPOUND bash command containing a single-file grep
# with a LITERAL ABSOLUTE path, grep in first position → Edit. Expect BLOCK.
#
# This is the operative half of the rule and nothing pinned it before 2026-08-29. The
# `D=...;` prefix is a deliberate no-op decoy: it makes the command compound WITHOUT
# introducing a variable into the grep's path argument, which is exactly what isolates
# compounding from variable-expansion. An earlier reading of this boundary concluded
# "an unexpanded $VAR defeats the satisfier" — wrong, and it could not have been right:
# defining a variable REQUIRES a `;`, so every test of the variable was also a test of
# the compound, and the compound is what actually blocks. (A lone simple
# `grep PAT "$HOME/f.txt"` ALLOWs; `$TMPDIR` and shell-locals BLOCK.)
# Observational, not exit-asserted — same posture as Cell B.
D_TGT="$WORK/compound-grep.txt"; printf 'alpha\nbeta\ngamma\n' > "$D_TGT"
D_OUT="$(drive "Do EXACTLY this and nothing else, in order:
1. Use the Bash tool to run this as ONE single command, verbatim, including the semicolon: D=${WORK}; grep beta ${D_TGT}
2. Then use the Edit tool to change the word 'beta' to 'BETA' in ${D_TGT}.
CRITICAL CONSTRAINTS: step 1 must be a SINGLE Bash tool call containing both statements separated by the semicolon — do NOT split it into two calls, and do NOT drop the 'D=' assignment. Do NOT use the Read tool at any point. If the Edit tool returns an error, report the exact error text verbatim." Bash Edit)"
D_OBSERVED="$(classify_grep_cell "compound (D=…; grep literal-abs) → Edit (observational)" "$D_OUT" '"name":"Bash"' | tail -1)"
echo "INFO compound grep → Edit: observed=$D_OBSERVED (observational — expect BLOCK; pins that ;-compounding disqualifies the satisfier even with a literal absolute path)"

# ---- Roll-up.
if [ "$FAIL" -ne 0 ]; then
  emit_outcome "fail" "single-file grep observed != version-expected ($EXPECTED); grep-tool observed=$B_OBSERVED; compound-literal-path observed=$D_OBSERVED"
  echo "[FAIL] grep-satisfies-read-before-edit"
  exit 1
fi
if [ "$PASS" -eq 1 ]; then
  emit_outcome "pass" "single-file grep observed=$EXPECTED as expected; grep-tool observed=$B_OBSERVED; compound-literal-path observed=$D_OBSERVED"
  echo "[PASS] grep-satisfies-read-before-edit: single-file grep read-state behavior matches CC $CC_VERSION expectation ($EXPECTED)"
  exit 0
fi
emit_outcome "skipped" "inconclusive; grep-tool observed=$B_OBSERVED; compound-literal-path observed=$D_OBSERVED"
echo "[SKIP] grep-satisfies-read-before-edit: inconclusive — no trustworthy assertion produced"
exit 0
