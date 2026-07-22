#!/usr/bin/env bash
# probe-publisher-scripts-rehearse-by-default.sh
#
# Convention lint: EVERY script in this repo whose steady-state effect is an OUTWARD
# PUBLISH must rehearse by default. Publishing must require an explicit opt-in flag.
#
# INVARIANT: for each script matching a publish verb (`git push`, `gh issue create`,
# `gh issue comment`, `gh pr create`, `gh release create`, `gh api …POST`), the file must
# contain BOTH:
#   (a) a rehearse-by-default gate  — an unconditional `DRY_RUN=1` or the
#       `DRY_RUN="${DRY_RUN:-1}"` default form, and
#   (b) an explicit publish opt-in  — a `--push` / `--publish` / `--live` argv case.
#
# Why a lint and not a note in a doc: the 2026-07-21 incident was not caused by anyone
# lacking the knowledge that a dry-run flag existed — it was caused by the flag not being
# parsed while the DEFAULT was live. A convention that lives only in prose gets
# re-litigated by whoever writes the next publisher at 2am. This fails the probe suite
# instead. `probe-sync-mirror-publish-gate.sh` is the deep behavioral check for the one
# publisher that exists today; this is the sweep that catches the next one.
#
# Adding a legitimately-exempt script: add it to EXEMPT below WITH a reason. An exemption
# is a decision, so it should read like one.
#
# KNOWN LIMIT — read before trusting a green (Codex adversarial review 2026-07-21,
# finding 5). This lint proves TOKEN CO-LOCATION, not CONTROL FLOW. This synthetic file
# passes every assertion while publishing unconditionally:
#
#     DRY_RUN="${DRY_RUN:-1}"
#     case "$1" in --push) DRY_RUN=0 ;; esac
#     git push --force public HEAD:main      # <-- never consults DRY_RUN
#
# Proving the gate DOMINATES every publish path needs shell tokenization + reachability,
# which is out of scope here for the same reason HP-037 scoped it out of the destructive
# guard. So: a green means "the shape is present", never "the gate is wired". The deep
# behavioral proof for the one publisher that exists lives in
# probe-sync-mirror-publish-gate.sh, and any NEW publisher needs its own equivalent —
# this lint's job is to make a missing gate loud, not to certify a present one.
#
# Backs: docs/decisions.md 2026-07-21 sync-mirror publish-gate row.
#
# Run: bash tests/probes/probe-publisher-scripts-rehearse-by-default.sh
#
# SAFE_FOR_LIVE: yes   (read-only static analysis — greps scripts/ and dhx/; executes
#                       nothing, writes nothing, no network.)

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"

PASSED=0
FAILED=0

_assert() { # $1 label, $2 expected, $3 actual
  if [[ "$2" == "$3" ]]; then
    echo "OK   $1"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL $1 (expected [$2], got [$3])"
    FAILED=$((FAILED + 1))
  fi
}

# Scripts that contain a publish verb but are NOT publishers in the relevant sense.
# Each entry states why, because an unexplained exemption is how a lint dies.
_is_exempt() { # $1 repo-relative path
  case "$1" in
    # The escape hatch for the D-12 gate: names gh verbs only inside its own refusal
    # and help text. It writes a marker file; it publishes nothing.
    scripts/dhx-upstream-bypass.sh) return 0 ;;
    # PreToolUse guards: they MATCH publish verbs in order to block them. A guard that
    # rehearsed by default would be a guard that does nothing.
    dhx/dhx-git-destructive-guard.sh) return 0 ;;
    dhx-plugin/plugins/dhx/hooks/pre-tool-use-gh-issue-write.sh) return 0 ;;
    # Sandbox-escape allowlist: `git push` appears as an ANCHORED PATTERN STRING in the
    # trusted-shapes array (line ~19), never as an executed command. Same guard class as
    # the two above — it decides about publishes, it does not perform them.
    dhx/dhx-sandbox-escape-allow.sh) return 0 ;;
    *) return 1 ;;
  esac
}

# Widened after Codex adversarial review 2026-07-21 (finding 6): the first version
# required an ADJACENT `git push`, so the ordinary `git -C <path> push` spelling — and
# every non-git publisher — was invisible. A lint that silently matches nothing looks
# exactly like a lint that passes.
PUBLISH_VERB='git([[:space:]]+-[Cc][[:space:]]+[^[:space:]]+)*[[:space:]]+push|gh[[:space:]]+issue[[:space:]]+(create|comment)|gh[[:space:]]+pr[[:space:]]+(create|comment)|gh[[:space:]]+release[[:space:]]+create|gh[[:space:]]+api.*(-X|--method)[[:space:]]+POST|npm[[:space:]]+publish|twine[[:space:]]+upload|curl[^|]*(api\\.github\\.com|-X[[:space:]]+(POST|PUT|PATCH))'

# Only lines that would EXECUTE the verb — a comment mentioning `git push` is prose, not
# a publish. Strips leading-# and leading-// lines before matching.
_publisher_files() {
  local f
  while IFS= read -r f; do
    if grep -vE '^[[:space:]]*(#|//)' "$REPO/$f" 2>/dev/null | grep -qE "$PUBLISH_VERB"; then
      echo "$f"
    fi
  # Glob widened per finding 6 — nested paths and non-.sh publishers were invisible to
  # the original three patterns. Scope stays the PRODUCTION trees (scripts/, dhx/,
  # dhx-plugin/): `tests/` is deliberately excluded as a class, because a probe that
  # exercises a publish verb against a fixture under a credential lockout is asserting
  # ABOUT publishing, not publishing. Demanding a rehearse-default there would be a
  # category error that trains people to add decorative gates to satisfy a linter.
  done < <(cd "$REPO" && git ls-files 'scripts/*' 'dhx/*' 'dhx-plugin/*' 2>/dev/null \
             | grep -E '\.(sh|bash|py|js|cjs|mjs)$' 2>/dev/null)
}

FOUND=0
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  if _is_exempt "$f"; then
    echo "SKIP $f (documented exemption)"
    continue
  fi
  FOUND=$((FOUND + 1))

  # Accepts either safe-init shape: an unconditional `DRY_RUN=1` (what the mirror script
  # uses now that the env publish path was removed) or the `${DRY_RUN:-1}` default form.
  HAS_DEFAULT=$(grep -qE '^[[:space:]]*DRY_RUN=("?\$\{DRY_RUN:-1\}"?|1([[:space:]]|$))' "$REPO/$f" \
                  && echo yes || echo no)
  _assert "[$f] rehearses by default (DRY_RUN defaults to 1)" "yes" "$HAS_DEFAULT"

  HAS_OPTIN=$(grep -qE '^\s*(\*\|)?--(push|publish|live)\)' "$REPO/$f" \
                && echo yes || echo no)
  _assert "[$f] has an explicit publish opt-in flag" "yes" "$HAS_OPTIN"
done < <(_publisher_files)

# A lint that silently matches nothing is a lint that has stopped working — the most
# common way a convention check rots (a path glob drifts, and it passes forever).
_assert "[meta] the lint actually found a publisher to check" "yes" \
  "$([[ "$FOUND" -ge 1 ]] && echo yes || echo no)"

echo "---"
echo "$PASSED passed, $FAILED failed ($FOUND publisher script(s) checked)"
[[ "$FAILED" -eq 0 ]] || exit 1
exit 0
