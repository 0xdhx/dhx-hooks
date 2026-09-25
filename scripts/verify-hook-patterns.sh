#!/usr/bin/env bash
set -euo pipefail
# verify-hook-patterns.sh — pre-commit gate enforcing the hook pattern registry contract.
#
# Behavior:
#   1. Identify staged dhx/*.sh files (added/copied/modified; a rename is checked at its
#      new path — see staged_whole_files, which #1-#4 and #9 share).
#   2. Block any staged dhx hook missing a `# Patterns:` header line.
#   3. Block any staged dhx hook referencing an HP-NNN ID that does not
#      resolve to a `## HP-NNN ` section in docs/hook-patterns.md.
#   4. If docs/hook-patterns.md is staged, block any new `## HP-NNN`
#      section that lacks a non-empty `**Evidence:**` block.
#   5. Block any staged shell file under dhx/, dhx-plugin/plugins/dhx/hooks/,
#      scripts/ or tests/ piping into an early-exit reader (HP-028: grep/egrep/
#      fgrep/rg with -q/-m/--quiet/--silent/--max-count, any spelling or argument
#      position). Detector: scripts/lib/hp028-scan.awk, run from its STAGED copy,
#      fail-closed; shared with tests/probes/probe-sigpipe-pipefail-shapes.sh.
#   5b. Block any staged shell file under the same four roots that assigns IFS a
#      TAB-valued separator (any spelling), outside a reasoned ALLOW list — TAB is IFS
#      whitespace, so `read` collapses an EMPTY field and shifts the rest left.
#      Detector: scripts/lib/tab-ifs-scan.sh, RUN (never sourced) from its STAGED
#      copy, fail-closed; shared with tests/probes/probe-tab-ifs-field-collapse-lint.sh.
#   8. Probe suite, tiered (2026-08-20). Armed by the same narrow pathspec
#      as before (dhx/*.js or tests/probes/*), then split three ways:
#        8a HERMETIC TIER — run-probes.sh --filter LIVE_RUNTIME=no
#           --filter HERMETIC_TIER=yes. Every probe whose verdict a
#           /dhx:sym gsd-update alone CANNOT flip with the repository
#           unchanged, MINUS those too costly to run per-commit
#           (HERMETIC_TIER: no — a separate axis added 2026-09-05; a
#           reclassified probe must name a runner in its own header, and
#           probe-hermetic-tier-cost-axis.sh enforces that). That is the
#           entire guarantee.
#           It is NOT repo-purity: a probe in this tier may read live
#           config, or assert on THIS repo's absolute path, and still be
#           correctly tiered. Before building anything that reconstructs
#           a tree and runs this tier against it, read
#           tests/probes/LIVE_RUNTIME.md § "What this tier does NOT
#           guarantee" — four such oracles were measured on 2026-08-23
#           and all four produced false reds against a GREEN live tree.
#           Blocks on red, exactly as the whole suite used to.
#           GREEN TOKEN (2026-09-14): a green run leaves a token keyed on
#           HEAD + candidate tree + a snapshot (every tracked path, plus
#           untracked/ignored files under the probe input roots, minus
#           tests/probes/.results/) + git config/hooks; an attempt
#           with the same key inside DHX_PROBE_TIER_TTL (900s; 0/off forces)
#           prints a hit line and is not re-run. Never written by a red.
#           Exists because 30-deletion-audit.sh refuses the first attempt of
#           every deletion-carrying commit AFTER this leaf ran the tier.
#        8b STAGED LIVE SUBJECTS — each LIVE_RUNTIME:yes probe runs iff the
#           commit stages the probe itself or one of its declared
#           LIVE_SUBJECT files. Blocks on red. This is what keeps a live
#           differential gating the thing it actually guards.
#        8c LIVE-TIER FRESHNESS — blocks if the installed gsd-core VERSION
#           differs from the version the live tier last RAN against. The
#           fix is one command, printed in the message.
#        8e UNPAIRED RED DEBT — runs UNARMED, on every commit. A commit that
#           landed under DHX_RED_COMMIT=1 promised a paired GREEN; nothing
#           checked that it arrived. Check #8 is armed only by dhx/*.js or
#           tests/probes/*, so a RED followed by commits touching neither
#           never re-runs the tier at all — which is exactly how 24afeee hid
#           a dead drift-detector for four days. #8e re-checks only the
#           roster the RED commit recorded (DHX-Red-Probes: trailer), warns
#           while the debt is young, and BLOCKS past the grace window.
#   9. Staged multi-cc corpus cells (2026-08-23). Validates cells staged under
#      tests/probes/.results/v1.3-multi-cc-ver/ against the corpus contract,
#      reading them from the INDEX. This is where corpus blocking authority
#      lives; run-probes.sh's copy of the validator is advisory only. Same
#      ruling as the 8a/8b/8c split — gate at the event that owns the
#      invariant. An UNSTAGED artifact from a hand-run can no longer block.
#      Rationale: an install-triggered invariant was being checked at
#      commit time ~450 times per 120 days to catch ~20 possible
#      breakages, and any single live red froze all 223 trigger-matched
#      files across every concurrent session on this shared tree.
#      See docs/decisions.md 2026-08-20 + tests/probes/LIVE_RUNTIME.md.
#
# Exclusions: misc/*.sh, .planned/**, .inactive/**, gsd/**, *.js/*.cjs/*.mjs
# Bypass: git commit --no-verify (git handles natively; no extra envvar).
#
# Exit codes: 0 = pass, 1 = block.
#
# NOTE on DHX_RED_COMMIT=1: it affects ONLY check #8, and even there it never
# skips a run the green token would not skip for everyone — see 8a (token) and
# 8d (attribution). Checks #1-#7 and #9 gate regardless; #9 in
# particular, because a corpus cell staged under a TDD-RED opt-out is still
# published evidence.

REGISTRY="docs/hook-patterns.md"

# Repo root — bail out gracefully if not in a git workspace
if ! GIT_TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null); then
  echo "verify-hook-patterns: not in a git repository, skipping" >&2
  exit 0
fi
cd "$GIT_TOPLEVEL"

# ---------------------------------------------------------------------------
# Probe `set +e` discipline lint (CAL-POLISH-05 / D-07 / D-10 / D-12).
#
# Per docs/decisions.md D-25: errexit (`set -e`) is never enabled in probes, so
# a bare `set +e` is a no-op decoration (the WR-04 anti-pattern). The actual
# gate is `rc=$?` capture immediately after the subprocess. This lint BLOCKS any
# NEW `set +e` staged into tests/probes/* in a file that does NOT enable errexit.
#
# Detection is two-step (D-07): staged-diff finds candidate ADDITIONS, then the
# FULL staged content (`git show :"$file"`) gates each candidate — if errexit is
# present the `set +e` is a legitimate save/restore pair and is SKIPPED. Reading
# full content (not `git diff -U0`) avoids false-positiving on an unchanged
# top-of-file `set -e`.
#
# D-10 errexit-safety: this runs under the host's `set -euo pipefail` (line 2).
# EVERY grep / command-substitution that can legitimately match nothing carries
# `|| true` — an empty match set is rc=1 and would otherwise early-exit the host
# (e.g. a docs-only commit with no staged probe changes). The errexit-present
# GATE regex is flag-order-agnostic and catches `-o errexit` (matches set -e,
# set -eu, set -euo pipefail, set -ue, set -o errexit).
#
# D-12 test-harness seam: extracted as a callable function so
# tests/test-probe-set-flag-lint.sh can source this script and drive the lint
# against fixture-staged content directly (the script's `cd "$GIT_TOPLEVEL"`
# above makes running the whole gate against a mktemp fixture brittle, and risks
# recursion). The function increments the shared FAIL accumulator (so the gate's
# consolidated `exit 1` blocks the commit) AND returns its OWN result — a prior
# check that set FAIL=1 must not make this lint claim a set+e violation it never
# found (WR-02, Phase 20 code-review follow-up). The source-time guard below
# (DHX_SKIP_SET_FLAG_LINT_TESTS) keeps sourcing from running the gate body.
lint_probe_set_flags() {
  # Renames (2026-09-25): this check reads the staged DIFF, so it must not use the
  # whole-file collector's --no-renames. Split into D + A, a `git mv` renders the new
  # path's ENTIRE content as added, and every pre-existing `set +e` would read as new
  # (measured: rename + one appended line → `-U0 -- <new>` shows all 3 lines, while
  # `-M -U0 -- <old> <new>` shows only the appended one). So candidates come from
  # --name-status -M with R kept, and an R row is diffed as the PAIR. Plain ACM dropped
  # R outright, so a rename that added a `set +e` was never linted. Read -z straight off
  # the stream (a `$(...)` would drop the NULs): an R row is status, old, new.
  # Residual, fail-CLOSED: git's pairing is heuristic, so a rename below the similarity
  # threshold, or one git pairs with an identical file added in the same commit, reads
  # as an A and its whole content is linted as new — a false block, never a miss. A probe
  # moved in from outside tests/probes/ is an A too (the pathspec bounds the pairing),
  # which is right: it is entering this lint's scope.
  local status old file added_set_plus_e full_content
  local found=0
  while IFS= read -r -d '' status; do
    old=""
    case "$status" in
      R*) IFS= read -r -d '' old || break
          IFS= read -r -d '' file || break ;;
      *)  IFS= read -r -d '' file || break ;;
    esac
    [ -z "$file" ] && continue
    # D-10: per-file newly-added `set +e` detection; `|| true` — an empty diff
    # (no added set +e in this file) is rc=1 and would abort under errexit.
    if [ -n "$old" ]; then
      added_set_plus_e=$(git diff --cached -M -U0 -- "$old" "$file" | grep -E '^\+.*set \+e' || true)
    else
      added_set_plus_e=$(git diff --cached -U0 -- "$file" | grep -E '^\+.*set \+e' || true)
    fi
    [ -z "$added_set_plus_e" ] && continue

    # Gate on FULL staged content (D-07): skip if errexit is present (legitimate
    # save/restore pair). D-10 hardened regex — flag-order-agnostic + `-o errexit`.
    full_content=$(git show ":$file" 2>/dev/null || true)
    if grep -qE '^[[:space:]]*set[[:space:]]+(-[a-z]*e[a-z]*|-o[[:space:]]+errexit)' <<<"$full_content"; then
      continue
    fi

    cat >&2 <<EOF
ERROR: $file introduces a no-op 'set +e' (probe set-flag discipline lint).

$added_set_plus_e

Per docs/decisions.md D-25 (post-2026-05-03 WR-04 correction): errexit is
never enabled in probes, so 'set +e' is a no-op decoration. The actual gate
is 'rc=\$?' capture immediately after the subprocess. Remove the 'set +e' and
capture the return code directly instead.

This lint reads the FULL staged content (git show :$file), not just the diff,
so a legitimate 'set -e' + 'set +e' save/restore pair is exempt — only files
that never enable errexit are flagged.
EOF
    FAIL=1    # contribute to the shared gate accumulator (the gate's exit 1 blocks)
    found=1   # WR-02: track THIS function's own finding, independent of FAIL
  done < <(git diff --cached -z --name-status -M --diff-filter=ACMR -- 'tests/probes/' 2>/dev/null || true)
  # WR-02 (Phase 20 code-review follow-up): return our OWN result, not the global
  # FAIL — so the test harness (and any future caller) gets an honest verdict even
  # when an unrelated earlier check already set FAIL=1. The shared FAIL above is
  # what actually gates the commit; this return is the function's local contract.
  [ "$found" -eq 0 ]
}

# Staged paths for WHOLE-FILE checks — every caller reads the staged blob (`git show ":$f"`),
# never the staged diff. Prints added/copied/modified paths, optionally limited by the pathspec
# args. Shared by checks #1-#3 (hook headers), #4 (the HP registry), #9 (corpus cells) and the
# #5/#5b collector below, so the rename rule lives once. --no-renames is load-bearing: with
# rename detection on (git's default; diff.renames unset here) a `git mv` is status R, which
# ACM drops, so a moved file was never checked at its new path — even a rename that also edits
# it (measured 2026-09-25 on #5/#5b: R087 with both violation shapes appended, rc=0). Split
# into D + A, the new path is an A and the D is dropped. Same fix as
# scripts/hooks/pre-commit.d/1{0,1}-backlog-*.sh. NOT for a check that reads the staged DIFF:
# with --no-renames the diff renders a renamed file's whole content as added, so such a check
# must pair renames instead — lint_probe_set_flags is the worked example.
# Errexit-safe; always returns 0.
staged_whole_files() {
  git diff --cached --name-only --diff-filter=ACM --no-renames "$@" 2>/dev/null || true
}

# Staged shell files for the commit-time lints #5 and #5b — ONE collector, so the two checks
# cannot disagree about which staged files are shell. Prints staged whole-file candidates
# (staged_whole_files above, so a rename is scanned at its new path — a revived .inactive/
# spike included) that are regular blobs (mode 100…, no symlink/gitlink) under dhx/,
# dhx-plugin/plugins/dhx/hooks/, scripts/ and tests/ and are `*.sh` or carry a shell shebang
# on the STAGED blob's first line (scripts/hooks/commit-msg has no suffix). NO path exclusions
# here: each check applies the gate-wide `Exclusions:` line in this file's header itself — #5
# and #5b both skip .inactive/ and .planned/, as their at-rest probes do. Errexit-safe; always
# returns 0.
staged_shell_files() {
  local candidates f mode first
  candidates=$(staged_whole_files -- dhx dhx-plugin/plugins/dhx/hooks scripts tests)
  [ -z "$candidates" ] && return 0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    mode=$(git ls-files -s -- "$f" 2>/dev/null || true)
    case "${mode:0:3}" in 100) ;; *) continue ;; esac
    if [[ "$f" != *.sh ]]; then
      first=""
      IFS= read -r first < <(git show ":$f" 2>/dev/null) || true
      [[ "$first" =~ ^\#!.*[/[:space:]](ba|z|k|da)?sh([[:space:]]|$) ]] || continue
    fi
    printf '%s\n' "$f"
  done <<< "$candidates"
  return 0
}

# 5. HP-028 SIGPIPE+pipefail shapes — `p | grep -q X` and every other spelling of a pipe
# into an early-exit reader. ONE detector, scripts/lib/hp028-scan.awk, shared with the
# at-rest probe tests/probes/probe-sigpipe-pipefail-shapes.sh — neither carries its own
# pattern (2026-09-25 row: this check's own `'| *grep -[qm]'` had drifted from the probe
# and scanned staged dhx/*.sh only, so a scripts/ or tests/ site passed every commit).
#
# Scope: staged (ACM) files under the probe's four roots that are shell — `*.sh` or a
# shell shebang on the STAGED blob's first line (scripts/hooks/commit-msg has no suffix).
# The scanner runs from ITS OWN STAGED COPY, never the worktree: this gate executes from
# the worktree of every concurrent session, and a peer's half-saved scanner must not
# change another commit's verdict. FAIL CLOSED: when shell files need scanning and that
# copy is missing, empty or makes awk error, the commit blocks naming the scanner — an
# unusable detector reading as "zero hits" is the silent pass this check exists to stop.
#
# Fixture coupling: a probe that copies THIS script into a fixture repo must copy
# scripts/lib/hp028-scan.awk beside it — staging any shell file there otherwise blocks
# (by design). Five do: probe-red-commit-attribution, probe-red-debt-pairing,
# probe-multi-cc-validator-decoupling, probe-hermetic-tier-green-token, probe-live-runtime-tier.
#
# Callable seam (same shape as lint_probe_set_flags): the probe sources this script with
# DHX_SKIP_SET_FLAG_LINT_TESTS=1 inside a fixture repo and calls it. Sets the shared FAIL
# accumulator and returns its OWN verdict. Errexit-safe: every command that may
# legitimately fail is inside an `if` or carries `|| true`.
lint_hp028_staged() {
  local listed f scanner errf out found=0
  local -a shell_files=()
  listed=$(staged_shell_files)
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in */.inactive/*|*/.planned/*) continue ;; esac   # the header's Exclusions line
    shell_files+=("$f")
  done <<< "$listed"
  [ "${#shell_files[@]}" -eq 0 ] && return 0

  scanner=$(mktemp) errf=$(mktemp)
  if ! git show ":scripts/lib/hp028-scan.awk" > "$scanner" 2>/dev/null || [ ! -s "$scanner" ]; then
    cat >&2 <<EOF
ERROR: HP-028 gate cannot run — scripts/lib/hp028-scan.awk is not in the index.

  ${#shell_files[@]} staged shell file(s) need the HP-028 scan, and this gate fails
  CLOSED rather than read a missing detector as zero hits. Restore and stage it:
    git checkout HEAD -- scripts/lib/hp028-scan.awk && git add scripts/lib/hp028-scan.awk
EOF
    rm -f "$scanner" "$errf"; FAIL=1; return 1
  fi
  for f in "${shell_files[@]}"; do
    if ! out=$(awk -v label="$f" -f "$scanner" < <(git show ":$f" 2>/dev/null) 2>"$errf"); then
      cat >&2 <<EOF
ERROR: HP-028 gate cannot run — the staged scripts/lib/hp028-scan.awk fails on $f:

$(cat "$errf")

  Failing CLOSED. Fix the scanner (its own probe is
  tests/probes/probe-sigpipe-pipefail-shapes.sh), then re-stage it.
EOF
      FAIL=1; found=1; break
    fi
    [ -z "$out" ] && continue
    while IFS= read -r hit; do
      [ -z "$hit" ] && continue
      cat >&2 <<EOF
ERROR: ${hit%%:*}:$(cut -d: -f2 <<<"$hit") introduces a SIGPIPE+pipefail-prone shape (HP-028).

  $(cut -d: -f3- <<<"$hit")

  A pipe into an early-exit reader (grep/egrep/fgrep/rg with -q, -m, --quiet,
  --silent or --max-count, in any spelling or argument position). Replace, BY PRODUCER:
    grep -q PAT <<<"\$VAR"                 # echo "\$VAR" or printf '%s\n' "\$VAR"
    grep -q PAT < <(printf '%s' "\$VAR")   # printf '%s' — NO trailing newline
    grep -q PAT < <(cmd args)              # any command output

  See docs/hook-patterns.md HP-028. A fixture that constructs the broken form on
  purpose is exempted by an 'HP-028' token on the same line.
EOF
      FAIL=1; found=1
    done <<< "$out"
  done
  rm -f "$scanner" "$errf"
  [ "$found" -eq 0 ]
}

# 5b. TAB-valued IFS — `read` with a TAB-valued IFS, in every spelling. TAB is IFS whitespace, so
# `read` collapses a run of tabs: an EMPTY leading or middle field vanishes and every later field
# shifts one variable left, silently. ONE detector, scripts/lib/tab-ifs-scan.sh — pattern, ALLOW
# list and judgement — shared with the at-rest probe tests/probes/probe-tab-ifs-field-collapse-lint.sh
# (docs/decisions.md 2026-09-25 gate-check row: that probe arms at commit only when tests/probes/*
# or dhx/*.js is staged, so a site staged anywhere else passed every commit — measured in a
# fixture repo, gate rc=0).
#
# Same contract as #5, three differences. (1) The detector is bash, RUN as a child process from
# its STAGED copy, never sourced: a sourced staged file would share this gate's FAIL, shell
# options and traps. (2) The staged blobs are written into a temp root and the scanner runs over
# them there — the code path the probe runs over the worktree, so equal bytes get equal verdicts.
# (3) ALLOW judgement is strict: every entry naming a staged file must match exactly one of its
# lines (converting an exempt site forces dropping its entry in the same commit), and when the
# scanner itself is staged, EVERY entry is judged against its path's INDEX copy, so an ALLOW-only
# edit cannot slip through. FAIL CLOSED: the scanner missing or empty in the index, or any exit
# other than 0 (clean) / 1 (findings), blocks naming the scanner. Skips .inactive/ and .planned/
# per the header's `Exclusions:` line: a dormant file is not live code, and reviving one means
# moving it to a live path, which stages it THERE — where this check scans it.
#
# Fixture coupling: probes copying this script into a fixture repo seed its scripts/lib files
# through tests/probes/lib/gate-fixture-libs.sh — one list, and a cell in the TAB-IFS probe fails
# when this file names a scripts/lib path the list lacks.
lint_tab_ifs_staged() {
  local listed f p l tmp rc out errtxt found=0 scanner_staged=0
  local -a rel=() args=()
  local -A seen=()
  listed=$(staged_shell_files)
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in */.inactive/*|*/.planned/*) continue ;; esac   # the header's Exclusions line
    rel+=("$f"); seen[$f]=1
    [ "$f" = "scripts/lib/tab-ifs-scan.sh" ] && scanner_staged=1
  done <<< "$listed"
  [ "${#rel[@]}" -eq 0 ] && return 0

  tmp=$(mktemp -d)
  if ! git show ":scripts/lib/tab-ifs-scan.sh" > "$tmp/scanner.sh" 2>/dev/null || [ ! -s "$tmp/scanner.sh" ]; then
    cat >&2 <<EOF
ERROR: TAB-IFS gate cannot run — scripts/lib/tab-ifs-scan.sh is not in the index.

  ${#rel[@]} staged shell file(s) need the TAB-IFS scan, and this gate fails
  CLOSED rather than read a missing detector as zero hits. Restore and stage it:
    git checkout HEAD -- scripts/lib/tab-ifs-scan.sh && git add scripts/lib/tab-ifs-scan.sh
EOF
    rm -rf "$tmp"; FAIL=1; return 1
  fi
  # Parse the whole file first: bash parses as it runs, so a syntax error past the scanner's
  # last `exit` would otherwise never be seen.
  if ! bash -n "$tmp/scanner.sh" 2>"$tmp/err"; then
    cat >&2 <<EOF
ERROR: TAB-IFS gate cannot run — the staged scripts/lib/tab-ifs-scan.sh does not parse:

$(cat "$tmp/err")

  Failing CLOSED. Fix the scanner (its own probe is
  tests/probes/probe-tab-ifs-field-collapse-lint.sh), then re-stage it.
EOF
    rm -rf "$tmp"; FAIL=1; return 1
  fi
  if [ "$scanner_staged" -eq 1 ]; then
    args+=(--all-allow)
    # A --list-allow failure is not handled here: the full run below fails the same way.
    if out=$(bash "$tmp/scanner.sh" --list-allow 2>/dev/null); then
      while IFS= read -r p; do
        p=${p%%|*}
        { [ -n "$p" ] && [ -z "${seen[$p]:-}" ]; } || continue
        git cat-file -e ":$p" 2>/dev/null || continue   # not in the index: judged 0 hits, STALE
        rel+=("$p"); seen[$p]=1
      done <<< "$out"
    fi
  fi
  for f in "${rel[@]}"; do
    mkdir -p "$tmp/root/$(dirname "$f")"
    git show ":$f" > "$tmp/root/$f" 2>/dev/null || true
  done
  if out=$(bash "$tmp/scanner.sh" --root "$tmp/root" "${args[@]}" -- "${rel[@]}" 2>"$tmp/err"); then rc=0; else rc=$?; fi
  errtxt=$(cat "$tmp/err" 2>/dev/null || true)
  rm -rf "$tmp"
  case "$rc" in
    0) return 0 ;;
    1) ;;
    *) cat >&2 <<EOF
ERROR: TAB-IFS gate cannot run — the staged scripts/lib/tab-ifs-scan.sh exited $rc:

${errtxt:-  (no diagnostic)}

  Failing CLOSED. Fix the scanner (its own probe is
  tests/probes/probe-tab-ifs-field-collapse-lint.sh), then re-stage it.
EOF
       FAIL=1; return 1 ;;
  esac
  while IFS= read -r l; do
    case "$l" in
      "UNALLOWED "*)
        l=${l#UNALLOWED }
        cat >&2 <<EOF
ERROR: ${l%%:*}:$(cut -d: -f2 <<<"$l") assigns IFS a TAB-valued separator.

  $(cut -d: -f3- <<<"$l")

  TAB is IFS whitespace: read collapses an EMPTY field and shifts every later
  field one variable left, silently. Use instead:
    NUL framing      jq -j with "\u0000" after every field, one read -r -d '' per field
    delimiter split  mapfile -t -d \$'\t' F <<<"\$row"
    unit separator   a row joined and split on \x1f
  An exemption needs a fixed-format external producer and a reason, in the ALLOW
  list of scripts/lib/tab-ifs-scan.sh (see its header).
EOF
        FAIL=1; found=1 ;;
      "STALE "*)
        l=${l#STALE }
        cat >&2 <<EOF
ERROR: TAB-IFS ALLOW entry ${l% (matches*} is stale in the staged tree (${l##* (}

  0 hits: its exempt site was converted away — delete the entry from the ALLOW
          list in scripts/lib/tab-ifs-scan.sh in this same commit.
  2+ hits: a second TAB-valued IFS line hides behind the entry's anchor — convert it.
EOF
        FAIL=1; found=1 ;;
    esac
  done <<< "$out"
  [ "$found" -eq 0 ]
}

# D-12 source-time guard: when tests/test-probe-set-flag-lint.sh sources this
# script to import lint_probe_set_flags, return BEFORE running any gate check
# (and before the test wiring below re-invokes the harness — recursion guard).
if [ "${DHX_SKIP_SET_FLAG_LINT_TESTS:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

# 1. Collect staged dhx hook files (Added/Copied/Modified only — ignore deletes; a rename is
#    checked at its new path, see staged_whole_files)
STAGED=$(staged_whole_files | grep -E '^dhx/.*\.sh$' || true)

FAIL=0

# 2/3. Per-hook checks
if [ -n "$STAGED" ]; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    # Read from the staged blob, not the working tree, so partial stages still work
    STAGED_CONTENT=$(git show ":$f" 2>/dev/null || true)
    if [ -z "$STAGED_CONTENT" ]; then
      continue
    fi

    # Parse ALL '# Patterns:' lines in the file, not just the first. This
    # ensures appended/duplicate header lines (legitimate or malicious) are
    # validated too — the gate is a contract on the entire file.
    PATTERNS_LINES=$(printf '%s\n' "$STAGED_CONTENT" | grep '^# Patterns:' || true)

    if [ -z "$PATTERNS_LINES" ]; then
      cat >&2 <<EOF
ERROR: $f is missing a '# Patterns:' header line.

Every hook in dhx/ must declare its runtime assumptions. Either:
  (a) Reference existing pattern IDs from docs/hook-patterns.md
      (format: # Patterns: HP-001, HP-002, HP-003)
  (b) Write a probe to verify a new assumption, add an HP-NNN entry
      to docs/hook-patterns.md, then reference it here

See docs/hook-dev-guide.md § "Adding a new hook" for the full workflow.
EOF
      FAIL=1
      continue
    fi

    IDS=$(printf '%s\n' "$PATTERNS_LINES" | grep -oE 'HP-[0-9]+' | sort -u || true)
    if [ -z "$IDS" ]; then
      cat >&2 <<EOF
ERROR: $f has a '# Patterns:' header but no HP-NNN IDs were parsed.

The line must reference at least one HP-NNN identifier from
docs/hook-patterns.md. Example:
  # Patterns: HP-001, HP-007, HP-009
EOF
      FAIL=1
      continue
    fi

    for id in $IDS; do
      if ! grep -q "^## $id " "$REGISTRY" 2>/dev/null; then
        cat >&2 <<EOF
ERROR: $f references unknown pattern $id.

Add the pattern to docs/hook-patterns.md first, with verified
evidence (probe, code trace, dry-run, or upstream link). Then
rerun this commit.

If the assumption is novel, write a probe:
  1. Create .inactive/probe-<claim>.sh
  2. Install temporarily via ~/.claude/settings.json
  3. Trigger the scenario, collect /tmp/probe-<claim>.log
  4. Add the HP-NNN entry with the probe as evidence
  5. Remove from settings.json, leave the probe file
EOF
        FAIL=1
      fi
    done
  done <<< "$STAGED"
fi

# 4. If the registry itself is staged, every HP section must carry evidence
REG_STAGED=$(staged_whole_files | grep -E "^${REGISTRY}\$" || true)
if [ -n "$REG_STAGED" ]; then
  REG_BLOB=$(git show ":${REGISTRY}" 2>/dev/null || true)
  if [ -n "$REG_BLOB" ]; then
    # Walk each ## HP-NNN section and confirm a non-empty Evidence bullet exists
    # before the next ## or end of file.
    # Here-strings (<<<) avoid the `printf | awk {exit}` SIGPIPE false-positive that
    # pipefail surfaces once REG_BLOB exceeds the pipe buffer (~64KB). awk reads from
    # a temp file bash creates for the here-string — no pipe, no SIGPIPE.
    SECTION_IDS=$(grep -oE '^## HP-[0-9]+' <<< "$REG_BLOB" | awk '{print $2}' | sort -u)
    for id in $SECTION_IDS; do
      # Extract the section body: from this header up to the next ## header
      SECTION_BODY=$(awk -v id="$id" '
        $0 ~ "^## "id" " {grab=1; next}
        grab && /^## / {exit}
        grab {print}
      ' <<< "$REG_BLOB")
      # Pull the lines following the **Evidence:** marker until a blank-line break
      # or another bold marker, then check at least one bullet exists.
      EVIDENCE_BULLETS=$(awk '
        /^\*\*Evidence:\*\*/ {grab=1; next}
        grab && /^\*\*[A-Za-z]/ {exit}
        grab && /^## / {exit}
        grab && /^- / {print}
      ' <<< "$SECTION_BODY")
      if [ -z "$EVIDENCE_BULLETS" ]; then
        cat >&2 <<EOF
ERROR: docs/hook-patterns.md § $id has no evidence.

Every pattern entry requires at least one evidence link: probe,
code, dry-run, or upstream reference. An unverified claim is not
a pattern — it's an assumption pretending to be one.
EOF
        FAIL=1
      fi
    done
  fi
fi

# 5. HP-028 SIGPIPE+pipefail shapes — body and rationale at lint_hp028_staged above.
lint_hp028_staged || true

# 5b. TAB-valued IFS — body and rationale at lint_tab_ifs_staged above.
lint_tab_ifs_staged || true

# 6. Run sed extraction tests when relevant files are staged
STAGED_HOOKS=$(git diff --cached --name-only -- 'dhx/*.sh' 'tests/' || true)
if [ -n "$STAGED_HOOKS" ] && [ -x "tests/test-sed-extraction.sh" ]; then
  echo "Running sed extraction tests..."
  bash tests/test-sed-extraction.sh || { echo "FAILED: sed extraction tests"; exit 1; }
fi

# 7. Run citation-check tests when relevant files are staged
if [ -n "$STAGED_HOOKS" ] && [ -x "tests/test-citation-check.sh" ]; then
  echo "Running citation-check tests..."
  bash tests/test-citation-check.sh || { echo "FAILED: citation-check tests"; exit 1; }
fi

# 7b. Probe `set +e` discipline lint (CAL-POLISH-05 / D-07). Runs the extracted
#     lint function (defined above) against the staged index. Placed STRICTLY
#     BEFORE the DHX_RED_COMMIT opt-out branch (check #8) — this is a
#     code-quality lint, NOT a probe-suite run, so it must fire even on TDD-RED
#     commits (per the brief, set +e doesn't change probe pass/fail; it just
#     produces misleading no-op code). The function increments FAIL on a hit;
#     the consolidated `exit 1` at the bottom blocks the commit.
lint_probe_set_flags || true

# 7c. Run the set-flag lint test harness when probe/test files are staged. The
#     harness is a test-* (not a probe-*), so run-probes.sh won't auto-run it —
#     mirror check #6's shape (the `[ -x ]` guard is why the harness is chmod +x
#     at creation). DHX_SKIP_SET_FLAG_LINT_TESTS guards against recursion: it is
#     set inside the harness, and the source-time guard above honors it so the
#     gate is never re-entered.
if [ "${DHX_SKIP_SET_FLAG_LINT_TESTS:-0}" != "1" ] && [ -n "$STAGED_HOOKS" ] && [ -x "tests/test-probe-set-flag-lint.sh" ]; then
  echo "Running probe set-flag lint tests..."
  bash tests/test-probe-set-flag-lint.sh || { echo "FAILED: set-flag lint tests"; exit 1; }
fi

# 8. Run probe suite when dhx/*.js or tests/probes/* are staged. Catches
#    the silent-red incident class — wrapper require-boundary changes that
#    don't update fake-$HOME fixtures, probe edits that break their own
#    assertions. Companion to the 2026-04-28 fixture centralization in
#    tests/probes/_make-fake-home.js: the helper provides a single fix-point
#    for new wrapper requires; this gate ensures that fix-point is in fact
#    updated before the regression lands. Trigger scoped narrowly: dhx/*.sh
#    edits don't pay the suite cost (#6/#7 cover hook-side regressions).
#
#    DHX_RED_COMMIT=1 (8d, reworked 2026-08-23): the opt-out buys PERMISSION
#    TO BE RED, not a skip. The tier runs as it would unflagged (8a's green
#    token skips it for everyone or for no one). On red it is honoured
#    only when every probe in the `red:` roster is a probe file THIS commit
#    stages — the mechanical form of "a TDD-RED commit is red because of its
#    own new assertion". It also demands DHX_RED_COMMIT_REASON up front and
#    refuses outright if the commit-msg audit hook is not wired.
#
#    It used to be a bare unconditional `skip`, which is a different and much
#    wider contract than its own comment claimed. Audit of all five
#    identifiable uses: f8fbab1, ae2e5db, b7333b4, 3aa2eed (2026-05-01, all
#    probe-only, all genuine TDD-RED — all still ALLOWED under attribution)
#    and 24afeee (2026-08-23), which shipped production hooks under a red it
#    did not cause and concealed a dead drift-detector for four days — REFUSED
#    under attribution, because none of its reds were probes it staged.
#    Still preferred over `--no-verify`, which disables all nine checks and is
#    equally untraceable.
PROBE_TRIGGER=$(git diff --cached --name-only -- 'dhx/*.js' 'tests/probes/' || true)
if [ -n "$PROBE_TRIGGER" ] && [ -x "scripts/run-probes.sh" ]; then
  {
    STAGED_ALL=$(git diff --cached --name-only || true)

    # ---- 8d. DHX_RED_COMMIT preconditions — CHEAP, before the tier runs ----
    # The opt-out no longer buys SPEED, only PERMISSION TO BE RED. The tier runs
    # exactly as it would without the flag (a green token skips it for everyone
    # or for no one — 8a); DHX_RED_COMMIT=1 changes only what happens when it
    # comes back red. That is a friction increase over the old instant skip and it is the
    # point: the bypass was never meant to be a speed feature, and an unmeasured
    # skip is exactly how 24afeee shipped production hooks under a red it did
    # not cause, hiding a dead drift-detector for four days.
    RED_COMMIT=0
    if [ "${DHX_RED_COMMIT:-0}" = "1" ]; then
      RED_COMMIT=1

      # A reason, before anything expensive. The commit-msg hook turns this into
      # a DHX-Red-Commit: trailer so the bypass is greppable in history.
      if [ -z "${DHX_RED_COMMIT_REASON:-}" ]; then
        echo "" >&2
        echo "BLOCKED: DHX_RED_COMMIT=1 requires DHX_RED_COMMIT_REASON." >&2
        echo "" >&2
        echo "  The opt-out leaves no record on its own. Say why, once:" >&2
        echo "    DHX_RED_COMMIT=1 DHX_RED_COMMIT_REASON='<why>' git commit ..." >&2
        echo "" >&2
        echo "  The commit-msg hook writes it into the message as a" >&2
        echo "  'DHX-Red-Commit: <reason>' trailer; you do not type it twice." >&2
        echo "" >&2
        exit 1
      fi

      # FAIL CLOSED on a missing audit hook. `scripts/hooks/commit-msg` existing
      # in the tree is NOT deployment — install-hooks.sh's sweep only wires it
      # when the installer is RUN, and this repo sets core.hooksPath to the fleet
      # dispatcher, which chains to <common-dir>/hooks/<event>. Without this
      # check the very commit that introduces the trailer gate — and every clone
      # until it reruns the installer — could bypass with no trace at all.
      _cdir=$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")
      case "$_cdir" in /*) ;; *) _cdir="$GIT_TOPLEVEL/$_cdir" ;; esac
      if [ ! -e "$_cdir/hooks/commit-msg" ]; then
        echo "" >&2
        echo "BLOCKED: DHX_RED_COMMIT=1 refused — the commit-msg audit hook is not installed." >&2
        echo "  expected: $_cdir/hooks/commit-msg" >&2
        echo "" >&2
        echo "  Without it the opt-out leaves no trace in history, which is half of what" >&2
        echo "  this gate exists to fix. Wire it (idempotent, one command):" >&2
        echo "    bash scripts/install-hooks.sh" >&2
        echo "" >&2
        exit 1
      fi
    fi

    # ---- 8a. Hermetic tier ----------------------------------------------
    # Phase 25 D-06 (2026-05-24) re-synced the hooks-side `### Gate 6` doc section
    # to the cross-repo canonical byte-for-byte and retired the
    # DHX_PROBE_ALLOW_CROSS_REPO_DIVERGENCE override that previously masked the
    # by-design divergence here. probe-gate-6-cross-repo-parity.sh now passes
    # plainly; a mismatch again means real drift and blocks (its original
    # REQ-04 contract).
    # GREEN TOKEN (2026-09-14). The tier is ~2.4 min on this machine (measured
    # 2026-09-14: real 142.6s, 128 passed) and 30-deletion-audit.sh, which runs
    # AFTER this leaf, refuses the FIRST attempt of every deletion-carrying
    # commit — so a probe-touching deletion commit paid the tier twice, and on
    # one 2026-09-14 retry the second run went transiently red on an unchanged
    # tree. A green run therefore leaves a token, keyed on everything in-tree
    # the tier can read, and an attempt whose key already has a token inside
    # DHX_PROBE_TIER_TTL (default 900s; 0 or off forces the run) is reported as
    # a hit and NOT re-run.
    #   KEY = sha1(HEAD, candidate write-tree, worktree snapshot, git-meta)
    #     candidate  — `git write-tree` of the index git hands the hook
    #                  (30-deletion-audit.sh keys on exactly this pair);
    #     snapshot   — write-tree of a THROWAWAY index (never the hook's
    #                  GIT_INDEX_FILE, never the real one): read-tree HEAD, then
    #                  `git add -u` of EVERY tracked path (edits and deletions
    #                  anywhere), then `git add -A -f` of the probe INPUT ROOTS
    #                  — tests/probes dhx dhx-plugin scripts config — untracked
    #                  AND ignored, because run-probes.sh globs
    #                  tests/probes/probe-* from the WORKTREE and a probe hidden
    #                  by .git/info/exclude still runs (adversarial pass,
    #                  reports/2026-09-14-hermetic-tier-token-presteer-codex/),
    #                  minus tests/probes/.results/, which the tier WRITES into.
    #                  Untracked files OUTSIDE those roots (reports/, docs/,
    #                  .planning/, tmp/) are deliberately not keyed: no probe
    #                  reads them from the real tree (measured 2026-09-14:
    #                  reports/ and .planning/ appear in probes only under a
    #                  fixture path), and concurrent sessions write there
    #                  constantly — a peer's Codex evidence under reports/ and
    #                  an n9 suite log under docs/research/ each moved a
    #                  whole-worktree key between a refusal and its retry on
    #                  2026-09-14, which is a MISS every time, never a false hit,
    #                  and leaves the token inert on a busy machine. A tracked
    #                  file under those dirs is still keyed via add -u.
    #     git-meta   — `git config --list` plus the hook files in the hooks
    #                  dirs, which two hermetic probes read.
    #   Measured 1.3s per armed attempt, stable across consecutive runs.
    #   Written ONLY by a green run (TIER_RC 0) — never by a red — and honoured
    #   on any attempt with the same key, DHX_RED_COMMIT=1 included: the token
    #   certifies an OBSERVED green on identical in-tree state, so honouring it
    #   hides no red, which is the invariant 8d protects (ruled 2026-09-14 over
    #   the literal "runs either way"; see docs/decisions.md).
    #   NOT covered, and bounded only by the TTL: $HOME, the installed CC, a
    #   chmod under core.fileMode=false, and a change landing between the
    #   snapshot and the hit decision. Any failure below → no key → the tier
    #   runs (fail toward running, never toward skipping).
    TIER_TTL="${DHX_PROBE_TIER_TTL:-900}"
    case "$TIER_TTL" in off|OFF) TIER_TTL=0 ;; ''|*[!0-9]*) TIER_TTL=900 ;; esac
    TIER_TOKEN=""
    TIER_HIT=0
    _tt_snap=""
    if [ "$TIER_TTL" -gt 0 ]; then
      _tt_dir=$(git rev-parse --git-path dhx-probe-tier 2>/dev/null || true)
      _tt_head=$(git rev-parse --verify HEAD 2>/dev/null || true)
      _tt_cand=$(git write-tree 2>/dev/null || true)
      if [ -n "$_tt_dir" ] && [ -n "$_tt_head" ] && [ -n "$_tt_cand" ]; then
        _tt_idx=$(mktemp)
        # Only roots that exist: a missing pathspec aborts `git add`, and that
        # would silently turn every attempt into a run (a checkout or fixture
        # without dhx-plugin/ or config/ must still get a key).
        _tt_roots=()
        for _tt_r in tests/probes dhx dhx-plugin scripts config; do
          [ -d "$_tt_r" ] && _tt_roots+=("$_tt_r")
        done
        if GIT_INDEX_FILE="$_tt_idx" git read-tree HEAD 2>/dev/null \
           && GIT_INDEX_FILE="$_tt_idx" git add -u -- . 2>/dev/null \
           && { [ "${#_tt_roots[@]}" -eq 0 ] || GIT_INDEX_FILE="$_tt_idx" git add -A -f -- "${_tt_roots[@]}" ':(exclude)tests/probes/.results' 2>/dev/null; }; then
          _tt_snap=$(GIT_INDEX_FILE="$_tt_idx" git write-tree 2>/dev/null || true)
        fi
        rm -f "$_tt_idx"
      fi
      if [ -n "$_tt_snap" ]; then
        _tt_meta=$(
          {
            git config --list 2>/dev/null
            for _hd in "$(git rev-parse --git-path hooks 2>/dev/null)" "$(git rev-parse --git-common-dir 2>/dev/null)/hooks"; do
              [ -d "$_hd" ] || continue
              find "$_hd" -maxdepth 1 -type f -print0 2>/dev/null | sort -z | xargs -0 sha1sum 2>/dev/null
            done
          } | sha1sum | cut -d' ' -f1
        )
        _tt_key=$(printf '%s %s %s %s' "$_tt_head" "$_tt_cand" "$_tt_snap" "$_tt_meta" | sha1sum | cut -d' ' -f1)
        if [ -n "$_tt_key" ]; then
          mkdir -p "$_tt_dir" 2>/dev/null || true
          find "$_tt_dir" -maxdepth 1 -type f -mmin "+$(( (TIER_TTL + 59) / 60 ))" -delete 2>/dev/null || true
          TIER_TOKEN="$_tt_dir/$_tt_key"
          [ -f "$TIER_TOKEN" ] && TIER_HIT=1
        fi
      fi
    fi

    if [ "$TIER_HIT" -eq 1 ]; then
      _tt_prev=$(head -c 120 "$TIER_TOKEN" 2>/dev/null | tr -d '\n' || true)
      _tt_when=$(date -r "$TIER_TOKEN" '+%H:%M:%S' 2>/dev/null || echo '?')
      echo "hermetic probe tier: GREEN for this exact candidate + worktree (${_tt_snap:0:8}) at ${_tt_when}${_tt_prev:+ — $_tt_prev}; identical rerun, not re-run. Set DHX_PROBE_TIER_TTL=0 to force."
      TIER_LOG=$(mktemp)
      TIER_RC=0
    else
      echo "Running hermetic probe tier (dhx/*.js or tests/probes/* staged)..."
      TIER_LOG=$(mktemp)
      set +e
      bash scripts/run-probes.sh --filter SAFE_FOR_LIVE=yes --filter LIVE_RUNTIME=no --filter HERMETIC_TIER=yes 2>&1 | tee "$TIER_LOG"
      TIER_RC=${PIPESTATUS[0]}
      set -e
      # Write-after-emit: the token lands only once the run's output is out and
      # the verdict is GREEN. A red writes nothing, so a red never gets reused.
      if [ "$TIER_RC" -eq 0 ] && [ -n "$TIER_TOKEN" ]; then
        _tt_sum=$(sed -n '/^Probes: /{s/^Probes: //p;q}' "$TIER_LOG" 2>/dev/null || true)
        if printf '%s\n' "$_tt_sum" > "$TIER_TOKEN.tmp.$$" 2>/dev/null; then
          mv -f "$TIER_TOKEN.tmp.$$" "$TIER_TOKEN" 2>/dev/null || rm -f "$TIER_TOKEN.tmp.$$"
        fi
      fi
    fi

    if [ "$TIER_RC" -ne 0 ]; then
      if [ "$RED_COMMIT" -eq 1 ]; then
        # ---- 8d. ATTRIBUTION -------------------------------------------------
        # A TDD-RED commit is red BECAUSE OF ITS OWN NEW ASSERTION. So the opt-out
        # is honoured exactly when every probe in the `red:` roster is a probe
        # file THIS commit stages. Anything else is someone else's red.
        #
        # This replaces the brief's proposed "run the tier against a git archive
        # HEAD export" oracle, which was measured on 2026-08-23 against a live
        # tree that is green and does not work:
        #     git archive HEAD                    -> 4 false reds
        #     git worktree add --detach           -> VETOED by the XR-29 guard
        #     git clone --shared                  -> 2 false reds
        #     git clone --shared + install-hooks  -> 1 false red, IRREDUCIBLE
        # The irreducible one is probe-v1-1-1-gate.sh, which is in this very tier
        # and shells out to verify-hooks.sh, which asserts that ~/.claude/hooks/*
        # resolve into this repo's absolute path. No copy of the repo anywhere
        # else can satisfy it. Every reconstruction has a false-red floor, and a
        # gate that false-reds refuses LEGITIMATE RED halves — which pushes
        # people to --no-verify, wider and equally untraceable. Attribution needs
        # no reconstruction: it reads the roster of the run that just happened.
        #
        # Companion assertions: tests/probes/probe-red-commit-attribution.sh.
        RED_NAMES=$(sed -n 's/^  red: //p' "$TIER_LOG" || true)
        rm -f "$TIER_LOG"

        if [ -z "$RED_NAMES" ]; then
          echo "" >&2
          echo "BLOCKED: DHX_RED_COMMIT=1 refused — the tier failed without naming any probe." >&2
          echo "  Nothing can be attributed to this commit, so the opt-out cannot apply." >&2
          echo "  Read the tier output above; this is a runner-level failure, not a red probe." >&2
          echo "" >&2
          exit 1
        fi

        UNATTRIBUTED=""
        for _rn in $RED_NAMES; do
          if grep -qxF "tests/probes/$_rn" <<<"$STAGED_ALL"; then continue; fi
          UNATTRIBUTED="$UNATTRIBUTED $_rn"
        done

        if [ -n "$UNATTRIBUTED" ]; then
          echo "" >&2
          echo "BLOCKED: DHX_RED_COMMIT=1 refused — the tier is red on probe(s) this commit does not touch." >&2
          echo "" >&2
          for _rn in $UNATTRIBUTED; do echo "  unattributed red: $_rn" >&2; done
          echo "" >&2
          echo "  A TDD-RED commit is red because of its OWN new assertion. These reds are" >&2
          echo "  inherited, so this commit cannot be the RED half of a pair — it would be" >&2
          echo "  committing past a red someone else left. That is exactly how a dead" >&2
          echo "  production guard stayed hidden for four days (24afeee, 2026-08-23)." >&2
          echo "" >&2
          echo "  Diagnose them:" >&2
          for _rn in $UNATTRIBUTED; do echo "    bash tests/probes/$_rn" >&2; done
          echo "" >&2
          exit 1
        fi

        echo "DHX_RED_COMMIT=1 honoured — every red probe is staged in this commit."
        for _rn in $RED_NAMES; do echo "  attributed red: $_rn"; done
        echo "  Pair this with a GREEN commit that closes it."

        # ---- 8d. ROSTER HANDOFF to the commit-msg trailer -------------------
        # "Pair this with a GREEN commit" was, until 2026-08-23, advice with
        # nothing behind it. Check #8e now enforces it — but #8e needs to know
        # WHICH probes were red, and re-running the whole tier to find out costs
        # ~4 min on every commit, which is the kind of tax that pushes people to
        # --no-verify. So the roster is recorded in history, in a DHX-Red-Probes:
        # trailer, and #8e re-checks only those probes (seconds).
        #
        # commit-msg is a SEPARATE process and cannot see $RED_NAMES, but it is
        # the only hook that can write the message (git's order: pre-commit ->
        # prepare-commit-msg -> commit-msg). The handoff is a file under the git
        # dir, stamped with the sha this roster was measured against. The stamp
        # is the load-bearing half: pre-commit can run and commit-msg never
        # follow (an abandoned editor, a failed later check), and an unstamped
        # leftover would then attach a stale roster to an unrelated commit days
        # later. commit-msg refuses any drop whose stamp is not the current HEAD.
        _rd_pending="$(git rev-parse --git-dir 2>/dev/null || echo .git)/dhx-red-probes.pending"
        {
          git rev-parse HEAD 2>/dev/null || echo "none"
          for _rn in $RED_NAMES; do echo "$_rn"; done
        } > "$_rd_pending" 2>/dev/null || true
      else
        rm -f "$TIER_LOG"
        echo "FAILED: hermetic probe tier"
        exit 1
      fi
    else
      rm -f "$TIER_LOG"
      if [ "$RED_COMMIT" -eq 1 ]; then
        echo "DHX_RED_COMMIT=1 was unnecessary — the tier is green. Nothing was skipped."
      fi
    fi

    # ---- 8b. Live probes whose own subject is staged ---------------------
    # A live differential must still gate the file it mirrors. `grep -qxF` reads
    # a herestring, never a pipe — the HP-028 SIGPIPE+pipefail shape check #5
    # blocks is deliberately avoided here too.
    LIVE_PROBES=$(grep -lE '^(# |// )LIVE_RUNTIME: yes\b' tests/probes/probe-*.js tests/probes/probe-*.sh 2>/dev/null || true)
    for lp in $LIVE_PROBES; do
      subjects=$(sed -nE 's|^(# \|// )LIVE_SUBJECT:[[:space:]]*(.*)$|\2|p' "$lp" || true)
      hit=""
      for cand in "$lp" $subjects; do
        if grep -qxF -- "$cand" <<<"$STAGED_ALL"; then hit="$cand"; break; fi
      done
      [ -n "$hit" ] || continue
      echo "Running live probe $(basename "$lp") — its subject '$hit' is staged..."
      case "$lp" in
        *.js) node "$lp" ;;
        *.sh) bash "$lp" ;;
      esac || { echo "FAILED: $(basename "$lp") (staged subject: $hit)"; exit 1; }
    done

    # ---- 8c. Live-tier freshness against the installed gsd-core ----------
    # The one thing that makes the split safe: a live differential cannot
    # silently stop running, because an install moves VERSION and the stamp
    # does not follow until the live tier is actually executed. The stamp
    # records the RUN, not the verdict (see run-probes.sh --stamp), so a slow
    # live red never deadlocks the repo — it only holds commits that stage the
    # failing probe's own subject, via 8b.
    LIVE_VER_FILE="$HOME/.claude/gsd-core/VERSION"
    STAMP_FILE="tests/probes/.results/live-tier/status.json"
    if [ -r "$LIVE_VER_FILE" ]; then
      live_ver=$(tr -d '[:space:]' < "$LIVE_VER_FILE")
      stamped=""
      stamp_failing=""
      if [ -r "$STAMP_FILE" ] && command -v jq >/dev/null 2>&1; then
        stamped=$(jq -r '.gsd_version // ""' "$STAMP_FILE" 2>/dev/null || true)
        stamp_failing=$(jq -r '.failing[]?' "$STAMP_FILE" 2>/dev/null || true)
      fi
      if [ "$stamped" != "$live_ver" ]; then
        echo "" >&2
        echo "BLOCKED: the live-runtime probe tier has not run against the installed gsd-core." >&2
        echo "  installed gsd-core: $live_ver" >&2
        echo "  live tier last ran: ${stamped:-<never>}" >&2
        echo "" >&2
        echo "  Run it — this takes seconds and clears the block whether it passes or fails:" >&2
        echo "    bash scripts/run-probes.sh --filter SAFE_FOR_LIVE=yes --filter LIVE_RUNTIME=yes --stamp" >&2
        echo "" >&2
        echo "  Any probe that reds there will then gate only commits staging its own" >&2
        echo "  LIVE_SUBJECT, not this one. See tests/probes/LIVE_RUNTIME.md." >&2
        exit 1
      fi
      if [ -n "$stamp_failing" ]; then
        echo "" >&2
        echo "NOTE: live tier ran against gsd-core $live_ver with failures outstanding:" >&2
        printf '  red: %s\n' $stamp_failing >&2
        echo "  These do NOT block this commit — they block only commits staging their" >&2
        echo "  declared LIVE_SUBJECT. Reconcile them before they accumulate." >&2
        echo "" >&2
      fi
    fi
  }
fi

# 8e. Unpaired RED debt — the GREEN half of a TDD-RED pair, enforced.
#
#     DELIBERATELY OUTSIDE check #8's `if [ -n "$PROBE_TRIGGER" ]`. That is the
#     entire point. #8d already makes an ARMED commit unable to inherit a red:
#     it runs the tier unconditionally and refuses by name when a red probe is
#     not one this commit stages. The hole is the arming pathspec — a RED commit
#     followed by any number of commits touching neither dhx/*.js nor
#     tests/probes/* never re-runs the tier, so the red is simply invisible. The
#     harm in 24afeee (2026-08-23) was not the red; it was four days of nobody
#     being told. This check is the telling.
#
#     COST. The common path is one `git log` over a 7-day window that finds
#     nothing — RED commits are rare (5 in this repo's entire history). When one
#     IS outstanding, only its recorded roster re-runs, via run-probes.sh --only
#     so the conclusion taxonomy stays single-sourced (a private re-read of exit
#     codes here would be a fourth consumer, and Convention A probes would be
#     misjudged: exit 2 + supersession_found_* is informational, not a failure).
#
#     WARN-THEN-BLOCK, not block-on-sight. A hard block on the first inherited
#     red freezes the repo on someone else's failure with no escape but
#     --no-verify — the 2026-08-19 blast radius the 2026-08-20 tier split exists
#     to prevent. The grace window leaves room for a genuine multi-hour fix; past
#     it, the four-day-invisible case becomes a hard stop. Reverting the RED
#     commit is always an honest exit and is named in the message.
#
#     Companion assertions: tests/probes/probe-red-debt-pairing.sh.
RED_DEBT_LOOKBACK_DAYS=7
RED_DEBT_GRACE_DAYS=2

_rd_log=$(git log --since="${RED_DEBT_LOOKBACK_DAYS} days ago" \
            --grep='^DHX-Red-Commit:' --format='%H%x09%ct' HEAD 2>/dev/null || true)

if [ -n "$_rd_log" ] && [ -x "scripts/run-probes.sh" ]; then
  declare -A _rd_ct=() _rd_sha=()
  _rd_names=""
  _rd_precontract=""

  # Herestring, never a pipe: the loop must run in THIS shell or the arrays it
  # fills vanish with the subshell (and HP-028's SIGPIPE shape is avoided too).
  while IFS=$'\t' read -r _sha _ct; do
    [ -n "$_sha" ] || continue
    _roster=$(git log -1 --format='%(trailers:key=DHX-Red-Probes,valueonly)' "$_sha" 2>/dev/null | tr '\n' ' ')
    if [ -z "${_roster// /}" ]; then
      # A RED commit from before the trailer existed (or one that bypassed it).
      # Nothing to re-check; say so rather than silently reporting no debt.
      _rd_precontract="$_rd_precontract ${_sha:0:8}"
      continue
    fi
    for _pn in $_roster; do
      # A probe deleted since the RED commit is not an outstanding debt. Filtered
      # HERE and not by run-probes.sh, which treats an unmatched --only as an
      # error precisely so a typo cannot read as "paid".
      [ -f "tests/probes/$_pn" ] || continue
      case " $_rd_names " in *" $_pn "*) ;; *) _rd_names="$_rd_names $_pn" ;; esac
      if [ -z "${_rd_ct[$_pn]:-}" ] || [ "$_ct" -lt "${_rd_ct[$_pn]}" ]; then
        _rd_ct[$_pn]=$_ct
        _rd_sha[$_pn]=$_sha
      fi
    done
  done <<< "$_rd_log"

  if [ -n "$_rd_precontract" ]; then
    echo "NOTE: RED commit(s) with no DHX-Red-Probes: roster —$_rd_precontract" >&2
    echo "  Predate the 2026-08-23 trailer contract; their debt cannot be re-checked." >&2
  fi

  if [ -n "${_rd_names// /}" ]; then
    _rd_only=()
    for _pn in $_rd_names; do _rd_only+=(--only "$_pn"); done
    _rd_tmp=$(mktemp)
    set +e
    bash scripts/run-probes.sh --filter SAFE_FOR_LIVE=yes "${_rd_only[@]}" >"$_rd_tmp" 2>&1
    _rd_rc=$?
    set -e
    _rd_still=$(sed -n 's/^  red: //p' "$_rd_tmp" || true)

    if [ "$_rd_rc" -ne 0 ] && [ -z "$_rd_still" ]; then
      # Red without a roster line is a runner-level failure, not a probe verdict.
      # Surface it; do not silently treat an unreadable answer as "paid".
      echo "" >&2
      echo "NOTE: RED-debt re-check could not be resolved (run-probes exited $_rd_rc," >&2
      echo "  naming no probe). Treating the debt as unresolved but NOT blocking." >&2
      echo "  Reproduce: bash scripts/run-probes.sh --filter SAFE_FOR_LIVE=yes${_rd_only[*]/#/ }" >&2
      echo "" >&2
    fi
    rm -f "$_rd_tmp"

    if [ -n "$_rd_still" ]; then
      _rd_now=$(date +%s)
      _rd_worst=0
      _rd_worst_sha=""
      for _pn in $_rd_still; do
        _c=${_rd_ct[$_pn]:-$_rd_now}
        _d=$(( (_rd_now - _c) / 86400 ))
        if [ "$_d" -ge "$_rd_worst" ]; then
          _rd_worst=$_d
          _rd_worst_sha=${_rd_sha[$_pn]:-}
        fi
      done
      _rd_reason=$(git log -1 --format='%(trailers:key=DHX-Red-Commit,valueonly)' "$_rd_worst_sha" 2>/dev/null | head -1)

      echo "" >&2
      if [ "$_rd_worst" -gt "$RED_DEBT_GRACE_DAYS" ]; then
        echo "BLOCKED: a DHX_RED_COMMIT shipped red ${_rd_worst}d ago and is still red." >&2
      else
        echo "WARNING: a DHX_RED_COMMIT shipped red ${_rd_worst}d ago and is still red." >&2
      fi
      echo "" >&2
      echo "  red commit: ${_rd_worst_sha:0:8}  ($(git log -1 --format='%s' "$_rd_worst_sha" 2>/dev/null | cut -c1-52))" >&2
      [ -n "$_rd_reason" ] && echo "  its reason: $_rd_reason" >&2
      echo "" >&2
      for _pn in $_rd_still; do echo "  still red: $_pn" >&2; done
      echo "" >&2
      echo "  The opt-out buys permission to be red, on the promise of a paired GREEN." >&2
      echo "  That GREEN has not landed. Check #8 is armed only by dhx/*.js and" >&2
      echo "  tests/probes/*, so commits touching neither never re-run the tier —" >&2
      echo "  which is how 24afeee concealed a dead drift-detector for four days." >&2
      echo "" >&2
      echo "  Diagnose:" >&2
      for _pn in $_rd_still; do echo "    bash tests/probes/$_pn" >&2; done
      echo "" >&2
      if [ "$_rd_worst" -gt "$RED_DEBT_GRACE_DAYS" ]; then
        echo "  Past the ${RED_DEBT_GRACE_DAYS}-day grace window, so this now blocks. Land the fix, or" >&2
        echo "  revert ${_rd_worst_sha:0:8} — reverting is an honest exit, --no-verify is not." >&2
        FAIL=1
      else
        echo "  Grace: ${RED_DEBT_GRACE_DAYS} days. This does NOT block yet; past that it will." >&2
      fi
      echo "" >&2
    fi
  fi
fi

# 9. Staged multi-cc corpus cells — validate the INDEX, never the worktree.
#    This is where corpus blocking authority LIVES as of 2026-08-23. It used to
#    live in run-probes.sh, folded into the probe tier's own FAIL counter, so a
#    machine-local side-artifact from a keyless hand-run blocked every
#    probe-touching commit repo-wide under the message "FAILED: hermetic probe
#    tier" — with the tier green (2026-07-09, 2026-08-23). Same ruling as the
#    2026-08-20 tier split: gate at the event that OWNS the invariant. Corpus
#    integrity is owned by PUBLISHING a cell, not by an unrelated probe run.
#
#    Reading the INDEX is the load-bearing half. The cells under
#    tests/probes/.results/v1.3-multi-cc-ver/ are a MIXED surface — 16 are
#    tracked evidence, while a hand-run drops untracked siblings beside them in
#    the live CC-version dir. Validating the worktree conflates the two and
#    re-creates the exact repo-wide block this check exists to remove. Every
#    cell here therefore comes from `git show :<path>`, so an untracked orphan
#    in the same directory is invisible to it.
#    Companion assertions: tests/probes/probe-multi-cc-validator-decoupling.sh (D/E).
STAGED_CELLS=$(staged_whole_files -- 'tests/probes/.results/v1.3-multi-cc-ver/')
if [ -n "$STAGED_CELLS" ] && [ -x "scripts/verify-multi-cc-results.sh" ]; then
  echo "Validating staged multi-cc corpus cells..."
  CORPUS_TMP=$(mktemp -d)
  mkdir -p "$CORPUS_TMP/scripts" "$CORPUS_TMP/docs"
  cp scripts/verify-multi-cc-results.sh "$CORPUS_TMP/scripts/"
  chmod +x "$CORPUS_TMP/scripts/verify-multi-cc-results.sh"
  # decisions.md from the INDEX too — assertion 5 cross-checks non-decisive
  # cells against "Validated stable" rows, and the row that matters is the one
  # being committed, not the one on disk.
  git show :docs/decisions.md > "$CORPUS_TMP/docs/decisions.md" 2>/dev/null || : > "$CORPUS_TMP/docs/decisions.md"
  CORPUS_VERS=""
  while IFS= read -r cell; do
    [ -n "$cell" ] || continue
    case "$cell" in *.json) ;; *) continue ;; esac
    mkdir -p "$CORPUS_TMP/$(dirname "$cell")"
    git show ":$cell" > "$CORPUS_TMP/$cell" 2>/dev/null || continue
    cver=$(basename "$(dirname "$cell")")
    case " $CORPUS_VERS " in *" $cver "*) ;; *) CORPUS_VERS="$CORPUS_VERS $cver" ;; esac
  done <<< "$STAGED_CELLS"
  CORPUS_RC=0
  CORPUS_OUT=""
  for cver in $CORPUS_VERS; do
    vout=$(bash "$CORPUS_TMP/scripts/verify-multi-cc-results.sh" "$cver" 2>&1) || CORPUS_RC=1
    [ -n "$vout" ] && CORPUS_OUT="$CORPUS_OUT$vout"$'\n'
  done
  rm -rf "$CORPUS_TMP"
  if [ "$CORPUS_RC" -ne 0 ]; then
    echo "" >&2
    echo "BLOCKED: a multi-cc corpus cell staged in this commit fails validation." >&2
    echo "" >&2
    printf '%s' "$CORPUS_OUT" | sed 's|^|  |' >&2
    echo "" >&2
    echo "  Staged cells in this commit:" >&2
    printf '%s\n' "$STAGED_CELLS" | sed 's|^|    |' >&2
    echo "" >&2
    echo "  These cells are committed EVIDENCE — fix or unstage them. This is not the" >&2
    echo "  old repo-wide block: an UNSTAGED artifact from a hand-run cannot reach this" >&2
    echo "  check, and never blocks a commit again." >&2
    FAIL=1
  fi
fi

if [ "$FAIL" -ne 0 ]; then
  echo "" >&2
  echo "verify-hook-patterns: commit blocked. Fix the issues above or rerun with --no-verify (be deliberate)." >&2
  exit 1
fi

exit 0
