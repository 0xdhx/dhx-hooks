#!/usr/bin/env bash
# scripts/hooks/pre-commit.d/10-backlog-frontmatter.sh
#
# Pre-commit check — backlog brief frontmatter canonicality gate (Phase 06).
#
# The D-16 canonical convention check-path (identical across skills + cross-repo
# so the fleet scan detects it uniformly). cross-repo's content is SELF-CONTAINED
# (D-02): it shells to scripts/lib/backlog-frontmatter-validator.cjs over the
# repo-local parse-frontmatter.cjs — it does NOT delegate to skills'
# backlog-regen.cjs (which cross-repo lacks; a verbatim port would fail-OPEN inert).
#
# Validates the commit's STAGED .planning/backlog/*.md briefs, INCLUDING the
# terminal subdirs shipped/ rejected/ superseded/ (the D-04 net-new half that
# skills' check deliberately skips). Staged-scoped: pre-existing corpus drift
# authored by another session never blocks an unrelated commit.
#
# Fail-mode (D-06):
#   - node absent OR validator absent -> exit 0 (fail-OPEN; never brick the repo).
#   - a staged brief unparseable or violating the contract -> exit 1 (fail-CLOSED,
#     propagated from the validator).
#
# Staged-path capture (D-28): NUL-delimited `git diff -z ... | mapfile -d ''` —
# robust to filenames containing newlines or shell-quoting bytes. A pure-Bash
# `case` glob filters to .planning/backlog/*.md over the NUL stream, so no
# `grep` line-split is reintroduced (which would mis-split unusual filenames).
#
# Escape hatch: `git commit --no-verify`.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
cd "$REPO_ROOT" || exit 0

VALIDATOR="$REPO_ROOT/scripts/lib/backlog-frontmatter-validator.cjs"   # absolute: validated from a temp staged-tree cwd below
[ -f "$VALIDATOR" ] || exit 0   # fail-OPEN: validator absent (D-06)

command -v node >/dev/null 2>&1 || {
  echo "pre-commit: node not found — skipping backlog frontmatter check." >&2
  exit 0   # fail-OPEN: toolchain absent (D-06)
}

# Shared staged-blob materialization helper (factored from this leaf's former
# inline loop so 10- and 20-conventions share one implementation).
# --- INLINED materialize-staged-tree helper (foreign-tree self-containment) ---
# AUTO-GENERATED into the scaffold payload by generate-payload.sh via
# inline-helper.cjs, from scripts/hooks/lib/materialize-staged-tree.sh. Do NOT
# hand-edit — edit the source helper and regenerate. (The cross-repo source leaf
# SOURCES this helper; the scaffold inlines it because a target repo has no
# scripts/hooks/lib/ to source from. Logic is byte-identical; only the
# dependency is internalized — the parallel of inline-validator.cjs.)
# scripts/hooks/lib/materialize-staged-tree.sh
#
# Shared pre-commit helper — materialize STAGED blobs into a throwaway temp tree
# so a leaf validates the staged *commit* content, not the working-tree files
# (closes the staged-vs-working TOCTOU). Sourced by pre-commit.d/* leaves; not
# executable on its own.
#
# Why a temp tree and NOT `git stash`: cross-repo is a SHARED working tree
# written by concurrent sessions; `refs/stash` is shared across worktrees, so a
# stash/unstash would corrupt a peer session's state (CLAUDE.md § Constraints).
# `git show :<path>` reads the staged blob straight from the index — no
# working-tree mutation, concurrency-safe.
#
# Contract:
#   materialize_staged_paths <dest_dir> <repo-rel-path>...
#     For each repo-relative path, write its STAGED blob to <dest_dir>/<path>
#     (creating parent dirs). The CALLER must already be at the repo root
#     (`git show :<path>` is index-relative to the repo root) and OWNS <dest_dir>
#     creation + the EXIT-trap cleanup. A staged blob that cannot be read is
#     fail-CLOSED: prints a blocking message on stderr and returns 1. Returns 0
#     when every path materialized.
#
# Proven origin: this is 10-backlog-frontmatter.sh's inline staged-blob loop
# (2026-05-22 hotfix) factored into one place so 10- and 20- share one
# implementation instead of two copies.

materialize_staged_paths() {
  local dest="$1"; shift
  local p
  for p in "$@"; do
    mkdir -p "$dest/$(dirname "$p")"
    # A staged blob the gate must inspect that cannot be read is fail-CLOSED.
    git show ":$p" > "$dest/$p" 2>/dev/null || {
      echo "pre-commit: cannot read staged blob for $p — blocking." >&2
      return 1
    }
  done
  return 0
}

# Staged .planning/backlog/*.md briefs (A/C/M — deletions skipped), captured
# NUL-delimited via `git diff -z ... | mapfile -d ''` and filtered with a
# pure-Bash `case` glob so terminal subdirs (shipped/ rejected/ superseded/)
# are INCLUDED (D-04 net-new) and unusual filenames (newlines, quoting bytes)
# are not mis-split (D-28). The `case` glob avoids reintroducing a `grep`
# line-split over the NUL stream.
# --no-renames is LOAD-BEARING: a `git mv` of a brief into a terminal subdir is
# the PRIMARY drift vector this gate exists to catch (manual close bypassing the
# tool). With rename detection ON, that move shows as R (excluded by ACM) and the
# moved brief would slip through unvalidated. --no-renames decomposes it into
# D (old, skipped) + A (new) so the moved brief is validated. (2026-05-22 hotfix.)
mapfile -d '' -t all_staged < <(git diff -z --cached --name-only --diff-filter=ACM --no-renames -- .planning/backlog/)
staged=()
for p in "${all_staged[@]}"; do
  case "$p" in
    .planning/backlog/*.md) staged+=("$p") ;;
  esac
done

[ "${#staged[@]}" -eq 0 ] && exit 0   # no backlog brief staged — no-op

# Validate the STAGED blob content, NOT the working-tree file (TOCTOU, 2026-05-22
# hotfix). The validator reads files by path; feeding it working files lets a bad
# STAGED brief through whenever the working copy differs (e.g. `git mv` of an
# unstaged-edited brief stages the OLD blob while the working copy looks clean).
# `git stash` is shared-tree-unsafe (refs/stash is shared across worktrees per
# CLAUDE.md), so instead mirror each staged blob into a temp tree at its
# repo-relative path (via the shared materialize_staged_paths helper) and
# validate THAT — running the validator FROM the temp tree so violations still
# report the real repo-relative path.
STAGED_TREE="$(mktemp -d)" || exit 0   # fail-OPEN: cannot make temp dir (D-06)
trap 'rm -rf "$STAGED_TREE"' EXIT
materialize_staged_paths "$STAGED_TREE" "${staged[@]}" || exit 1   # fail-CLOSED

# The validator names each offending brief + reason on stderr (repo-relative
# paths, because we run it from the staged tree); exit code propagates
# (0 pass, 1 block — fail-CLOSED on violation, D-06).
( cd "$STAGED_TREE" && node "$VALIDATOR" "${staged[@]}" )
