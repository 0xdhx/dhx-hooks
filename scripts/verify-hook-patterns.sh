#!/usr/bin/env bash
set -euo pipefail
# verify-hook-patterns.sh — pre-commit gate enforcing the hook pattern registry contract.
#
# Behavior:
#   1. Identify staged dhx/*.sh files (added/copied/modified).
#   2. Block any staged dhx hook missing a `# Patterns:` header line.
#   3. Block any staged dhx hook referencing an HP-NNN ID that does not
#      resolve to a `## HP-NNN ` section in docs/hook-patterns.md.
#   4. If docs/hook-patterns.md is staged, block any new `## HP-NNN`
#      section that lacks a non-empty `**Evidence:**` block.
#   5. Block any staged dhx hook introducing a SIGPIPE+pipefail-prone
#      `cmd | grep -[qm] PATTERN` shape (HP-028). Covers grep -q AND
#      grep -m N (both structurally truth-signal readers in if-conditions
#      — same SIGPIPE-bites-control-flow class). Comment lines and lines
#      containing the literal `HP-028` are exempt. Companion at-rest
#      invariant: tests/probes/probe-sigpipe-pipefail-shapes.sh.
#   8. Probe suite, tiered (2026-08-20). Armed by the same narrow pathspec
#      as before (dhx/*.js or tests/probes/*), then split three ways:
#        8a HERMETIC TIER — run-probes.sh --filter LIVE_RUNTIME=no. Every
#           probe whose verdict a /dhx:sym gsd-update alone CANNOT flip
#           with the repository unchanged. That is the entire guarantee.
#           It is NOT repo-purity: a probe in this tier may read live
#           config, or assert on THIS repo's absolute path, and still be
#           correctly tiered. Before building anything that reconstructs
#           a tree and runs this tier against it, read
#           tests/probes/LIVE_RUNTIME.md § "What this tier does NOT
#           guarantee" — four such oracles were measured on 2026-08-23
#           and all four produced false reds against a GREEN live tree.
#           Blocks on red, exactly as the whole suite used to.
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
# NOTE on DHX_RED_COMMIT=1: it affects ONLY check #8, and even there it no
# longer skips anything — see 8d. Checks #1-#7 and #9 gate regardless; #9 in
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
  # D-10: `|| true` so a no-candidate (docs-only) commit doesn't abort the host.
  local candidates
  candidates=$(git diff --cached --name-only --diff-filter=ACM -- 'tests/probes/' || true)
  [ -z "$candidates" ] && return 0

  local file added_set_plus_e full_content
  local found=0
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    # D-10: per-file newly-added `set +e` detection; `|| true` — an empty diff
    # (no added set +e in this file) is rc=1 and would abort under errexit.
    added_set_plus_e=$(git diff --cached -U0 -- "$file" | grep -E '^\+.*set \+e' || true)
    [ -z "$added_set_plus_e" ] && continue

    # Gate on FULL staged content (D-07): skip if errexit is present (legitimate
    # save/restore pair). D-10 hardened regex — flag-order-agnostic + `-o errexit`.
    full_content=$(git show ":$file" 2>/dev/null || true)
    if printf '%s\n' "$full_content" | grep -qE '^[[:space:]]*set[[:space:]]+(-[a-z]*e[a-z]*|-o[[:space:]]+errexit)'; then
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
  done <<< "$candidates"
  # WR-02 (Phase 20 code-review follow-up): return our OWN result, not the global
  # FAIL — so the test harness (and any future caller) gets an honest verdict even
  # when an unrelated earlier check already set FAIL=1. The shared FAIL above is
  # what actually gates the commit; this return is the function's local contract.
  [ "$found" -eq 0 ]
}

# D-12 source-time guard: when tests/test-probe-set-flag-lint.sh sources this
# script to import lint_probe_set_flags, return BEFORE running any gate check
# (and before the test wiring below re-invokes the harness — recursion guard).
if [ "${DHX_SKIP_SET_FLAG_LINT_TESTS:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

# 1. Collect staged dhx hook files (Added/Copied/Modified only — ignore deletes)
STAGED=$(git diff --cached --name-only --diff-filter=ACM | grep -E '^dhx/.*\.sh$' || true)

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
REG_STAGED=$(git diff --cached --name-only --diff-filter=ACM | grep -E "^${REGISTRY}\$" || true)
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

# 5. Block staged dhx hooks that introduce SIGPIPE+pipefail-prone shapes.
#    HP-028: `cmd | grep -q PATTERN` silently drops the match when LHS
#    output exceeds the OS pipe buffer (~64 KiB) under pipefail. Comment
#    lines and lines containing the literal `HP-028` are exempt — same
#    exclusions as the at-rest invariant probe at
#    tests/probes/probe-sigpipe-pipefail-shapes.sh (BRE regex parity).
if [ -n "$STAGED" ]; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    BLOB=$(git show ":$f" 2>/dev/null || true)
    [ -z "$BLOB" ] && continue
    SHAPE_HITS=$(grep -n '| *grep -[qm]' <<< "$BLOB" || true)
    [ -z "$SHAPE_HITS" ] && continue
    while IFS=: read -r lineno content; do
      [ -z "$lineno" ] && continue
      trimmed="${content#"${content%%[![:space:]]*}"}"
      case "$trimmed" in '#'*) continue ;; esac
      case "$content" in *HP-028*) continue ;; esac
      cat >&2 <<EOF
ERROR: $f:$lineno introduces a SIGPIPE+pipefail-prone shape (HP-028).

  $content

  Replace 'cmd | grep -q PAT' (or 'cmd | grep -m N PAT') with one of:
    grep -q PAT <<< "\$VAR"        # for variable inputs
    grep -q PAT < <(cmd args)     # for command outputs
    (same swap shape applies to grep -m N)

  See docs/hook-patterns.md HP-028 for the full pattern. Exempt the line
  by adding an 'HP-028' reference comment (intentional documentation,
  heredoc bodies, etc.).
EOF
      FAIL=1
    done <<< "$SHAPE_HITS"
  done <<< "$STAGED"
fi

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
#    TO BE RED, not a skip. The tier runs either way. On red it is honoured
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
    # either way; DHX_RED_COMMIT=1 changes only what happens when it comes back
    # red. That is a friction increase over the old instant skip and it is the
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
    echo "Running hermetic probe tier (dhx/*.js or tests/probes/* staged)..."
    TIER_LOG=$(mktemp)
    set +e
    bash scripts/run-probes.sh --filter SAFE_FOR_LIVE=yes --filter LIVE_RUNTIME=no 2>&1 | tee "$TIER_LOG"
    TIER_RC=${PIPESTATUS[0]}
    set -e

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
STAGED_CELLS=$(git diff --cached --name-only --diff-filter=ACM -- 'tests/probes/.results/v1.3-multi-cc-ver/' || true)
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
