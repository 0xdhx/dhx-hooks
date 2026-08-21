#!/usr/bin/env bash
# scripts/hooks/pre-commit.d/11-backlog-strict-yaml.sh
#
# Pre-commit check -- strict-YAML gate over the ACTIVE backlog tier.
# Ported into hooks on 2026-08-21, re-vendored 2026-08-21 from skills@06382ed3b
# (skills:scripts/hooks/pre-commit.d/11-backlog-strict-yaml.sh). The executable
# half below is byte-identical to that source; only this header is local.
#
# RULINGS LIVE IN THE SKILLS REPO AND ARE NOT REACHABLE FROM THIS TREE:
#   ~/repos/skills/docs/decisions/2026-07-22-backlog-strict-yaml-active-tier-gate.md
#     -- the origin ruling: tier scoping, why a SEPARATE leaf, fail-OPEN posture.
#   ~/repos/skills/docs/decisions/2026-08-20-strict-yaml-fleet-port-and-repair-baseline.md
#     -- the fleet extension that authorized this install.
#   ~/repos/cross-repo/docs/conventions/2026-08-20-backlog-strict-yaml-fleet-gating.md
#     -- the fleet pointer, if you are reading from a cross-repo session.
#
# INSTALL EVIDENCE (2026-08-21). This repo measured 44/44 active-tier
# briefs passing yaml.safe_load with line-anchored extraction at install time --
# a 5-brief sweep. Firing was demonstrated here, not assumed: a known-bad brief
# staged in an isolated tree exited 1 and named the offending file, and a
# known-good brief exited 0. See "PROVE IT FIRES" below -- this matters more than
# it looks.
#
# -- Scope: ACTIVE tier only --------------------------------------------------
# Only top-level .planning/backlog/*.md is strict-checked. The terminal subdirs
# shipped/ rejected/ superseded/ are deliberately EXCLUDED as read-only history:
# no consumer scopes a strict read there, and each edit carries real corruption
# risk because the line-based consumers read quotes literally. This repo's
# archive carries 8 failing brief(s) of 60, left untouched on purpose -- do NOT
# conclude the exclusion is a shortcut around them. It
# is what stops a future `git mv` of an archived brief from blocking on unrelated
# work, and the archive converges LAZILY on the REOPEN vector: `git mv
# shipped/x.md ./x.md` lands a brief in the active tier, where this gate DOES
# apply, so a dirty legacy brief is fixed exactly when it re-enters service.
#
# One further exclusion: the exact filename .planning/backlog/BACKLOG.md. Some
# repos keep the AUTO-GENERATED backlog index inside the briefs directory rather
# than at .planning/BACKLOG.md; it carries no frontmatter and never can, so
# without the exclusion this leaf would block on it every time it is staged, over
# a file with no author to fix. The pattern is the EXACT name, not a prefix glob:
# a real brief merely named BACKLOG-something.md is still a brief.
#
# --no-renames is LOAD-BEARING for that reopen vector: with rename detection ON a
# `git mv` shows as R (excluded by --diff-filter=ACM) and the reopened brief would
# slip through unvalidated. --no-renames decomposes it into D (old, skipped) +
# A (new active path, checked).
#
# -- Why a SEPARATE leaf and not an extension of 10- --------------------------
# This repo is a scaffold TARGET. 10-backlog-frontmatter.sh and
# scripts/lib/backlog-frontmatter-validator.cjs are GENERATED payload that
# cross-repo:conventions/scaffolds/backlog-frontmatter-gate/install.sh COPIES over
# those exact paths -- a hand-edit there is silently reverted by the next install.
# 11- is not in that payload file list, so install.sh can never touch it.
#
# 10- also CANNOT catch this class on its own: its validator parses frontmatter
# with a line-regex parser that is PERMISSIVE BY DESIGN and silently skips any
# line it cannot match, so a brief that breaks a real YAML parser passes it with
# every required key reported present. This leaf is the strict half.
#
# -- Frontmatter extraction: LINE-ANCHORED, never split('---', 2) -------------
# The frontmatter is the span from the first line that is EXACTLY `---` to the
# next line that is EXACTLY `---`. Splitting on the first `---` found ANYWHERE
# truncates mid-value on any brief whose frontmatter VALUE contains an inline
# `---`, then reports that perfectly healthy brief as broken. Measured fleet-wide
# 2026-08-20: the naive method reports 121 failing briefs against the correct 113
# -- nine false positives, four of them in a tier a live gate holds at zero.
# This repo currently has NO brief carrying an inline `---` in a value, so it has
# no local negative control for that behaviour; the contract is pinned upstream by
# skills:tests/probe-backlog-strict-yaml.sh (16 cases, 9 mutations killed), which
# does NOT travel with this file.
#
# -- PROVE IT FIRES, do not just observe green -------------------------------
# This leaf has four `exit 0` paths that run BEFORE any validation: no staged
# active brief, no python3/PyYAML, an unmakeable temp dir, and a non-git cwd. So
# "commits still pass" is satisfied perfectly by a leaf doing nothing at all. To
# re-verify after any change to this file, this repo's hook wiring, or its python
# environment, run from a skills checkout:
#
#   bash ~/repos/skills/scripts/strict-yaml-gate-firecheck.sh ~/repos/hooks
#
# It stages a known-bad brief in an isolated worktree-or-clone (never this repo's
# own index) and asserts exit 1 WITH the brief named. Nothing else watches this
# leaf in this repo, and that is accepted.
#
# Fail-mode:
#   - python3 or PyYAML absent -> warn + exit 0 (fail-OPEN; never brick the repo).
#   - a staged active brief that will not parse -> exit 1 (fail-CLOSED).
# Escape hatch: `git commit --no-verify`.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
cd "$REPO_ROOT" || exit 0

# Staged backlog briefs (A/C/M — deletions skipped), NUL-delimited so filenames
# containing newlines or quoting bytes are not mis-split (D-28).
mapfile -d '' -t all_staged < <(git diff -z --cached --name-only --diff-filter=ACM --no-renames -- .planning/backlog/)

# Filter to the ACTIVE tier. PATTERN ORDER IS LOAD-BEARING: in a bash `case`
# glob, `*` DOES match `/` (unlike pathname expansion), so the bare
# `.planning/backlog/*.md` pattern alone would also match
# `.planning/backlog/shipped/example.md`. The nested-path pattern MUST come first
# to peel terminal subdirs off. Pinned by the probe's scope cases.
# (`example.md` and not a fictional `foo.md` because this leaf is PORTED: a target
# repo's own pointer-rot gate classifies any non-resolving path as rot unless it
# sits in the reserved `example` namespace, so an illustrative path here blocks the
# install. Measured 2026-08-21 in forgefinder. Same rule for any path added below.)
staged=()
for p in "${all_staged[@]}"; do
  case "$p" in
    .planning/backlog/*/*)  : ;;                # any subdir — out of scope
    .planning/backlog/BACKLOG.md) : ;;          # GENERATED index, not a brief
    .planning/backlog/*.md) staged+=("$p") ;;   # active tier
  esac
done

[ "${#staged[@]}" -eq 0 ] && exit 0   # no active brief staged — no-op

if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import yaml' >/dev/null 2>&1; then
  echo "pre-commit: python3+PyYAML not found — skipping backlog strict-YAML check." >&2
  exit 0   # fail-OPEN: toolchain absent (D-06)
fi

# Validate the STAGED blob, NOT the working tree (TOCTOU — a `git mv` of an
# unstaged-edited brief stages the OLD blob while the working copy looks clean).
# `git stash` is shared-tree-unsafe (refs/stash is shared across worktrees per
# CLAUDE.md), so mirror each staged blob into a temp tree at its repo-relative
# path and check THAT, running from the temp tree so violations still report the
# real repo-relative path. Same shape as 20-decisions-corpus.sh; 10-'s helper is
# inlined into its own leaf and cannot be sourced.
STAGED_TREE="$(mktemp -d)" || exit 0   # fail-OPEN: cannot make temp dir (D-06)
trap 'rm -rf "$STAGED_TREE"' EXIT

for p in "${staged[@]}"; do
  mkdir -p "$STAGED_TREE/$(dirname "$p")"
  git show ":$p" > "$STAGED_TREE/$p" 2>/dev/null || {
    echo "pre-commit: cannot read staged blob for $p — blocking." >&2
    exit 1   # fail-CLOSED: a blob the gate must inspect is unreadable
  }
done

( cd "$STAGED_TREE" && python3 - "${staged[@]}" <<'PY'
import sys, yaml

violations = []

for p in sys.argv[1:]:
    try:
        with open(p, encoding='utf-8') as fh:
            text = fh.read()
    except OSError as e:
        violations.append((p, None, f"cannot read staged brief ({e})"))
        continue

    # Line-anchored extraction. `.rstrip('\r')` tolerates CRLF input the same way
    # parse-frontmatter.cjs does (Phase 10 WR-02) — without it a CRLF brief would
    # never match the closing `---` and would be reported as fenceless.
    lines = text.split('\n')
    if not lines or lines[0].rstrip('\r') != '---':
        violations.append((p, 1, "no opening '---' frontmatter fence on line 1"))
        continue
    end = -1
    for i in range(1, len(lines)):
        if lines[i].rstrip('\r') == '---':
            end = i
            break
    if end == -1:
        violations.append((p, None, "no closing '---' frontmatter fence"))
        continue

    block = '\n'.join(line.rstrip('\r') for line in lines[1:end])

    try:
        doc = yaml.safe_load(block)
    except yaml.YAMLError as e:
        # PyYAML line numbers are 0-indexed and relative to the block, which
        # starts at file line 2 -> +2 gives the real file line.
        mark = getattr(e, 'problem_mark', None)
        line = mark.line + 2 if mark is not None else None
        detail = getattr(e, 'problem', None) or str(e).split('\n')[0]
        violations.append((p, line, detail))
        continue

    if not isinstance(doc, dict):
        kind = 'empty' if doc is None else type(doc).__name__
        violations.append((p, None, f"frontmatter must parse to a mapping (got {kind})"))

if violations:
    sys.stderr.write(
        "pre-commit: backlog brief(s) fail strict YAML parsing — blocking.\n")
    for p, line, detail in violations:
        loc = f"{p}:{line}" if line is not None else p
        sys.stderr.write(f"  {loc}: {detail}\n")
    sys.stderr.write(
        "\n"
        "Active-tier frontmatter must parse under yaml.safe_load. Usual cause: an\n"
        "unquoted value containing ': ', or a value starting with a backtick.\n"
        "\n"
        "Fix recipe — wrap the value in the quote style it does NOT already\n"
        "contain: no \" in the value -> wrap in \"...\"; a \" in the value ->\n"
        "wrap in '...'. That needs NO escaping, so what every consumer extracts\n"
        "stays byte-identical to what it extracted before.\n"
        "  Do NOT 'swap inner \" to ' and then wrap' — that parses fine and\n"
        "  silently REWRITES the value. It is what produced the two 2026-08-21\n"
        "  fleet regressions this gate's own advice was meant to prevent.\n"
        "  Value contains BOTH quote styles? SCALAR fields may escape (\\\" inside\n"
        "  \"...\", or '' inside '...'): both frontmatter readers share\n"
        "  scripts/lib/parse-frontmatter-scalar.cjs, which UNESCAPES (2026-08-15).\n"
        "  Block-LIST items may NOT — backlog-close.cjs's list wrapper strips the\n"
        "  outer quotes only, so an escape leaks into the value verbatim.\n"
        "  Verify each edit on the ROUND TRIP (consumer view before vs after),\n"
        "  not on parse-success — parse-success accepts an edit that silently\n"
        "  changes what the line-based consumers extract.\n"
        "\n"
        "The reported line is a LEAD, not always the root cause — a break earlier\n"
        "in the block routinely surfaces at a later line.\n"
        "\n"
        "Escape hatch: git commit --no-verify\n")
    sys.exit(1)   # fail-CLOSED (D-06)

sys.exit(0)
PY
)
