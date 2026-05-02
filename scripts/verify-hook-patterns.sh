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
#   8. Run scripts/run-probes.sh when dhx/*.js or tests/probes/* are
#      staged. Catches wrapper require-boundary changes that don't
#      update fake-$HOME fixtures + probe edits that break their own
#      assertions. Trigger scoped narrowly so dhx/*.sh edits don't pay
#      the probe-suite cost (sed-extraction + citation-check at #6/#7
#      already cover hook-side regressions).
#
# Exclusions: misc/*.sh, .planned/**, .inactive/**, gsd/**, *.js/*.cjs/*.mjs
# Bypass: git commit --no-verify (git handles natively; no extra envvar).
#
# Exit codes: 0 = pass, 1 = block.

REGISTRY="docs/hook-patterns.md"

# Repo root — bail out gracefully if not in a git workspace
if ! GIT_TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null); then
  echo "verify-hook-patterns: not in a git repository, skipping" >&2
  exit 0
fi
cd "$GIT_TOPLEVEL"

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

# 8. Run probe suite when dhx/*.js or tests/probes/* are staged. Catches
#    the silent-red incident class — wrapper require-boundary changes that
#    don't update fake-$HOME fixtures, probe edits that break their own
#    assertions. Companion to the 2026-04-28 fixture centralization in
#    tests/probes/_make-fake-home.js: the helper provides a single fix-point
#    for new wrapper requires; this gate ensures that fix-point is in fact
#    updated before the regression lands. Trigger scoped narrowly: dhx/*.sh
#    edits don't pay the suite cost (#6/#7 cover hook-side regressions).
#
#    DHX_RED_COMMIT=1 opt-out: TDD-RED probe commits intentionally fail
#    the suite (target machinery for the assertion doesn't exist yet — the
#    paired GREEN commit closes RED). Setting DHX_RED_COMMIT=1 skips ONLY
#    this check; the other 7 checks above still gate. Targeted bypass
#    preferred over `--no-verify` (which disables all 8). Repo precedent:
#    f8fbab1, ae2e5db, b7333b4, 3aa2eed all needed this opt-out.
PROBE_TRIGGER=$(git diff --cached --name-only -- 'dhx/*.js' 'tests/probes/' || true)
if [ -n "$PROBE_TRIGGER" ] && [ -x "scripts/run-probes.sh" ]; then
  if [ "${DHX_RED_COMMIT:-0}" = "1" ]; then
    echo "Skipping probe suite — DHX_RED_COMMIT=1 (TDD-RED commit; pair with GREEN to close)."
  else
    echo "Running probe suite (dhx/*.js or tests/probes/* staged)..."
    bash scripts/run-probes.sh || { echo "FAILED: probe suite"; exit 1; }
  fi
fi

if [ "$FAIL" -ne 0 ]; then
  echo "" >&2
  echo "verify-hook-patterns: commit blocked. Fix the issues above or rerun with --no-verify (be deliberate)." >&2
  exit 1
fi

exit 0
