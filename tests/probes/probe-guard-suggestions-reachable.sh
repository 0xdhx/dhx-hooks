#!/usr/bin/env bash
# probe-guard-suggestions-reachable.sh
#
# INVARIANT: no command form that dhx-git-destructive-guard.sh RECOMMENDS in its
# refusal text may be a form the permission layer's deny list FORBIDS. A guard
# that blocks you and then names an unreachable remedy is worse than one that
# names none: it implies the operator erred, and it teaches a recovery reflex.
#
# Authored alongside the removal of the guard's 'in-lane reset' suggestion, which
# recommended a bare `git reset --hard` that the deny list forbids outright.
#
#
# Run: bash tests/probes/probe-guard-suggestions-reachable.sh
#
# SAFE_FOR_LIVE: yes
# RUNTIME: ~1s
#
# ---------------------------------------------------------------------------
# DESIGN AND ITS BLIND SPOT (stated per the authoring prompt's requirement)
# ---------------------------------------------------------------------------
# The deny list lives in MACHINE state (~/.ccs/shared/settings.json), not repo
# state, so a probe reading it cannot be hermetic. This probe runs BOTH arms:
#
#   HERMETIC arm  — pins the deny-glob MATCHING LOGIC against a fixture deny
#                   list, including a planted denied suggestion as a positive
#                   control. Always runs. Catches matcher regressions.
#                   CANNOT catch a real deny-rule addition.
#
#   LIVE arm      — reads the real settings file and the real guard text.
#                   Catches a real deny-rule addition (the failure this probe
#                   exists to prevent). SKIPS when the settings file is absent.
#
# BLIND SPOT: on a machine without CCS (no resolvable settings.json), the live
# arm SKIPS and this probe covers NOTHING about the actual deny list — only the
# matcher logic. A skip is reported loudly and is NOT counted as a pass. The
# hermetic arm alone would re-create the original defect one level up: a check
# that stays green while the thing it checks has drifted.
#
# WHY THE SUGGESTION SIDE IS PARSED, NOT HARDCODED
# The guard's suggestion ENTRY LABELS are read out of the live heredoc, then
# mapped to runnable command forms by the table below. An entry label with no
# mapping is a FAILURE, not a skip — so adding a 4th suggestion to the guard
# cannot pass silently. The deny side is fully dynamic: ADDING a deny rule
# later re-reds this probe rather than silently re-creating the defect.
# ---------------------------------------------------------------------------

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="$REPO_ROOT/dhx/dhx-git-destructive-guard.sh"

PASS=0
FAIL=0
SKIP=0

ok()   { printf 'OK   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
skip() { printf 'SKIP %s\n' "$1"; SKIP=$((SKIP + 1)); }

# ---------------------------------------------------------------------------
# Deny-glob matcher — models Claude Code's permission matcher.
#
# A deny entry is `Bash(<pattern>)`, where <pattern> is a glob. Two rules:
#   1. Direct glob match of the command against the pattern.
#   2. HP-037 (verified 2026-05-25, CC 2.1.150): a pattern ending in ' *' ALSO
#      matches the BARE command form. This is the rule that made the removed
#      'in-lane reset' suggestion look safe to its author.
#
# The asymmetry that matters: `git reset --hard*` (no space) swallows the bare
# form outright, while `git push --force *` (one space) does NOT match
# `git push --force-with-lease` — the leading token differs at the '-'.
# ---------------------------------------------------------------------------
deny_matches() {
  local cmd="$1" pattern="$2"
  # shellcheck disable=SC2254  # glob expansion in the case pattern is the point
  case "$cmd" in
    $pattern) return 0 ;;
  esac
  if [[ "$pattern" == *' *' ]]; then
    [[ "$cmd" == "${pattern% \*}" ]] && return 0
  fi
  return 1
}

# Extract the Bash(...) patterns from a newline-delimited deny list.
bash_patterns() {
  local line
  while IFS= read -r line; do
    [[ "$line" == 'Bash('*')' ]] || continue
    line="${line#Bash(}"
    printf '%s\n' "${line%)}"
  done
}

# ---------------------------------------------------------------------------
# Label -> runnable command forms.
#
# One entry per suggestion label printed by the guard. The label is READ from
# the guard; only the runnable expansion lives here, because the guard prints
# placeholders (`<path>`, `../<dir>`) that are not executable as written and
# because the force-push entry prints bare flags with the verb implied.
# ---------------------------------------------------------------------------
forms_for_label() {
  case "$1" in
    'force-push')
      printf '%s\n' \
        'git push --force-with-lease' \
        'git push --force-with-lease --force-if-includes' \
        'git push --force-with-lease=main:abc123 origin main'
      ;;
    'isolated branch')
      printf '%s\n' 'git worktree add ../wt -b feature'
      ;;
    'staging')
      printf '%s\n' 'git add -- path/to/file' 'git add -- a.txt b.txt'
      ;;
    *) return 1 ;;
  esac
}

# Pull the suggestion-entry labels out of a guard body on stdin.
extract_labels() {
  awk '
    /^Safe alternatives:$/            { inblock = 1; next }
    /^If this command is genuinely/   { inblock = 0 }
    inblock && /^  - [^:]+:/ {
      line = $0
      sub(/^  - /, "", line)
      sub(/:.*$/, "", line)
      print line
    }
  '
}

printf '\n== hermetic arm (fixture deny list; always runs) ==\n'

FIXTURE_DENY=$'Bash(git push --force *)\nBash(git push -f *)\nBash(git reset --hard*)\nRead(./.env*)'
FIXTURE_PATTERNS="$(printf '%s\n' "$FIXTURE_DENY" | bash_patterns)"

# --- matcher semantics ---
deny_matches 'git reset --hard' 'git reset --hard*' \
  && ok "matcher: bare 'git reset --hard' IS denied by 'git reset --hard*'" \
  || bad "matcher: bare 'git reset --hard' should be denied by 'git reset --hard*'"

deny_matches 'git reset --hard HEAD~1' 'git reset --hard*' \
  && ok "matcher: 'git reset --hard HEAD~1' IS denied" \
  || bad "matcher: 'git reset --hard HEAD~1' should be denied"

deny_matches 'git push --force' 'git push --force *' \
  && ok "matcher: HP-037 — bare 'git push --force' denied by trailing-space glob" \
  || bad "matcher: HP-037 bare-form rule not applied to 'git push --force *'"

deny_matches 'git push --force-with-lease' 'git push --force *' \
  && bad "matcher: substring trap — '--force-with-lease' must NOT match 'git push --force *'" \
  || ok "matcher: substring trap avoided — '--force-with-lease' not denied by 'git push --force *'"

deny_matches 'git push --force-if-includes' 'git push -f *' \
  && bad "matcher: '--force-if-includes' must NOT match 'git push -f *'" \
  || ok "matcher: '--force-if-includes' not denied by 'git push -f *'"

# --- planted defect: the exact suggestion this probe exists to keep out ---
PLANTED='git reset --hard'
PLANTED_HIT=0
while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  deny_matches "$PLANTED" "$p" && PLANTED_HIT=1
done <<<"$FIXTURE_PATTERNS"
[[ "$PLANTED_HIT" -eq 1 ]] \
  && ok "planted defect: a re-added bare 'git reset --hard' suggestion IS caught" \
  || bad "planted defect NOT caught — probe is vacuous, matcher or fixture broken"

# --- negative control: the three real suggestion forms clear the fixture ---
FIXTURE_CLEAN=1
for label in 'force-push' 'isolated branch' 'staging'; do
  while IFS= read -r form; do
    [[ -n "$form" ]] || continue
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      if deny_matches "$form" "$p"; then
        FIXTURE_CLEAN=0
        printf '     collision: [%s] %s  <=  Bash(%s)\n' "$label" "$form" "$p"
      fi
    done <<<"$FIXTURE_PATTERNS"
  done < <(forms_for_label "$label")
done
[[ "$FIXTURE_CLEAN" -eq 1 ]] \
  && ok "negative control: all mapped suggestion forms clear the fixture deny list" \
  || bad "negative control: a mapped suggestion form is denied by the fixture list"

# --- unmapped label fails closed ---
forms_for_label 'in-lane reset' >/dev/null 2>&1 \
  && bad "fail-closed: an unmapped label must NOT resolve to forms" \
  || ok "fail-closed: unmapped label ('in-lane reset') yields no forms -> FAIL path"

printf '\n== guard text (repo state; always runs) ==\n'

if [[ ! -r "$GUARD" ]]; then
  bad "guard not readable at $GUARD"
else
  LABELS="$(extract_labels <"$GUARD")"
  LABEL_COUNT="$(printf '%s\n' "$LABELS" | grep -c '[^[:space:]]')"

  [[ "$LABEL_COUNT" -ge 1 ]] \
    && ok "non-vacuity: extracted $LABEL_COUNT suggestion label(s) from the guard" \
    || bad "non-vacuity: extracted ZERO labels — parser broken or block renamed"

  # Every extracted label must be mapped. A new suggestion cannot pass silently.
  ALL_MAPPED=1
  while IFS= read -r label; do
    [[ -n "$label" ]] || continue
    if ! forms_for_label "$label" >/dev/null 2>&1; then
      ALL_MAPPED=0
      printf '     unmapped suggestion label: %s\n' "$label"
    fi
  done <<<"$LABELS"
  [[ "$ALL_MAPPED" -eq 1 ]] \
    && ok "every guard suggestion label has a runnable-form mapping" \
    || bad "guard prints a suggestion label this probe cannot evaluate — add it to forms_for_label()"

  # The removed entry must stay removed.
  if grep -q 'in-lane reset' "$GUARD"; then
    bad "the 'in-lane reset' suggestion is back in the guard (council-locked D-1/D-2)"
  else
    ok "no 'in-lane reset' suggestion in the guard"
  fi

  # The doctrine pointer must be present and absolute.
  if grep -q '^  /home/dhx/repos/cross-repo/docs/research/2026-05-08-git-reset-hard-worktree-deny-history\.md$' "$GUARD"; then
    ok "doctrine pointer present, by absolute path (cross-repo is unreachable from this tree)"
  else
    bad "doctrine pointer missing — the reader who trips this guard has nowhere to land"
  fi
fi

printf '\n== live arm (real deny list; SKIPS if settings unresolvable) ==\n'

SETTINGS=""
CANDIDATE="$(readlink -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" 2>/dev/null || true)"
if [[ -n "$CANDIDATE" && -r "$CANDIDATE" ]]; then
  SETTINGS="$CANDIDATE"
elif [[ -r "$HOME/.ccs/shared/settings.json" ]]; then
  SETTINGS="$HOME/.ccs/shared/settings.json"
fi

if [[ -z "$SETTINGS" ]]; then
  skip "no resolvable settings.json — LIVE DENY LIST NOT CHECKED (see BLIND SPOT in header)"
elif ! command -v jq >/dev/null 2>&1; then
  skip "jq unavailable — LIVE DENY LIST NOT CHECKED (see BLIND SPOT in header)"
else
  LIVE_PATTERNS="$(jq -r '.permissions.deny[]? // empty' "$SETTINGS" 2>/dev/null | bash_patterns)"
  LIVE_COUNT="$(printf '%s\n' "$LIVE_PATTERNS" | grep -c '[^[:space:]]')"

  printf '     settings: %s (%s Bash deny pattern(s))\n' "$SETTINGS" "$LIVE_COUNT"

  [[ "$LIVE_COUNT" -ge 1 ]] \
    && ok "live: read $LIVE_COUNT Bash deny pattern(s) from the real settings file" \
    || bad "live: ZERO Bash deny patterns read — arm is vacuous, not passing"

  # Non-vacuity against the real list: the defect string MUST still be denied.
  # If this goes green-by-absence the whole live arm means nothing.
  LIVE_RESET_DENIED=0
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    deny_matches 'git reset --hard' "$p" && LIVE_RESET_DENIED=1
  done <<<"$LIVE_PATTERNS"
  [[ "$LIVE_RESET_DENIED" -eq 1 ]] \
    && ok "live non-vacuity: bare 'git reset --hard' IS denied by the real list (D-1 still locked)" \
    || bad "live non-vacuity: bare 'git reset --hard' NOT denied — D-1 changed, or the arm is inert"

  # The actual assertion.
  LIVE_CLEAN=1
  while IFS= read -r label; do
    [[ -n "$label" ]] || continue
    while IFS= read -r form; do
      [[ -n "$form" ]] || continue
      while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        if deny_matches "$form" "$p"; then
          LIVE_CLEAN=0
          printf '     collision: [%s] %s  <=  Bash(%s)\n' "$label" "$form" "$p"
        fi
      done <<<"$LIVE_PATTERNS"
    done < <(forms_for_label "$label")
  done <<<"$(extract_labels <"$GUARD")"

  [[ "$LIVE_CLEAN" -eq 1 ]] \
    && ok "live: no command form the guard recommends is denied by the real deny list" \
    || bad "live: the guard recommends a command the deny list forbids — fix the GUARD, not permissions.deny"
fi

printf '\n%d passed, %d failed' "$PASS" "$FAIL"
[[ "$SKIP" -gt 0 ]] && printf ', %d SKIPPED (coverage gap — see header)' "$SKIP"
printf '\n'

[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
