#!/usr/bin/env bash
# probe-hook-advisory-commands-reachable.sh
#
# INVARIANT: across EVERY hook in this repo, no command form a hook RECOMMENDS
# in its user-visible text may be (a) forbidden by the permission deny list,
# (b) a member of the reset / force-move / stash recovery family that the
# 2026-05-08 cross-AI council removed, or (c) unrunnable as printed. Guidance
# that cannot be followed is worse than no guidance: it implies the operator
# erred, and where the command is a recovery command it teaches the exact
# reflex the doctrine exists to remove.
#
# Backs docs/decisions.md 2026-08-06 tree-sweep row and .planning/backlog/2026-08-06-hooks-tree-sweep-for-published-recovery-commands.md criteria 1-4.
#
# Run: bash tests/probes/probe-hook-advisory-commands-reachable.sh
#
# SAFE_FOR_LIVE: yes
# RUNTIME: ~2s
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS SEPARATELY FROM probe-guard-suggestions-reachable.sh
# ---------------------------------------------------------------------------
# That probe covers ONE hook (dhx-git-destructive-guard.sh) in depth, because
# that guard prints a structured `  - <label>:` list a parser can key on. No
# other hook has that structure. The 2026-08-06 sweep found the coverage gap
# was real and not theoretical: three hooks outside the guard printed advice
# that was doctrine-violating or unrunnable.
#
# DECISION (brief criterion 4, recorded rather than assumed): coverage
# generalizes into ONE probe, keyed on an INVENTORY, rather than per-hook
# probes or a forced `  - <label>:` rewrite of every hook. Rationale: the
# inventory doubles as the durable enumeration criterion 3 demands, and it
# imposes no structure on hook authors. The cost is that the inventory is
# hand-maintained — which the completeness arm below converts from a silent
# rot risk into a loud failure.
#
# THE COMPLETENESS ARM IS THE POINT
# A probe that only checked the forms listed below would go green forever
# while a new hook printed something new. So the inventory is checked in BOTH
# directions: every printed command line derived from source must match an
# inventory row (new advice cannot pass silently), and every inventory row
# must match something in source (retired advice cannot rot the table).
#
# RECOMMENDS vs MENTIONS — load-bearing
# Several hooks deliberately NAME a forbidden command in order to forbid it
# ("Do NOT 'git checkout main'"). A substring grep cannot tell that apart from
# a recommendation, and treating them alike would either red the correct hooks
# or force the doctrine text out of them. Hence the explicit class column.
#
# BLIND SPOT: the deny-collision arm needs the live settings file and SKIPS
# without it (same machine-state limit as the sibling probe). A skip is
# reported loudly and never counted as a pass.
# ---------------------------------------------------------------------------

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK_DIRS=("$REPO_ROOT/dhx" "$REPO_ROOT/dhx-plugin/plugins/dhx/hooks")

PASS=0
FAIL=0
SKIP=0

ok()   { printf 'OK   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
skip() { printf 'SKIP %s\n' "$1"; SKIP=$((SKIP + 1)); }

# ---------------------------------------------------------------------------
# Deny-glob matcher — models Claude Code's permission matcher.
# Duplicated from probe-guard-suggestions-reachable.sh deliberately: probes in
# this suite are self-contained so a broken shared lib cannot silently disarm
# several at once. Keep the two copies in step.
#
#   1. Direct glob match of the command against the pattern.
#   2. HP-037 (2026-05-25, CC 2.1.150): a pattern ending in ' *' ALSO matches
#      the BARE command form.
# The asymmetry that matters: `git reset --hard*` (no space) swallows the bare
# form outright; `git push --force *` (one space) does NOT match
# `git push --force-with-lease`.
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

bash_patterns() {
  local line
  while IFS= read -r line; do
    [[ "$line" == 'Bash('*')' ]] || continue
    line="${line#Bash(}"
    printf '%s\n' "${line%)}"
  done
}

# ---------------------------------------------------------------------------
# THE INVENTORY  (criterion 3: the durable enumeration)
#
# One row per printed command line across every hook, as of 2026-08-06.
# Columns: <hook-basename> | <class> | <stable substring found in the source>
#
# Classes:
#   RECOMMEND  an action the operator is told to take. Deny-checked and
#              doctrine-checked. Must map to runnable forms below.
#   PATH       a RECOMMEND that invokes a script by path; the path must resolve.
#   ECHOBACK   the blocked command echoed back as diagnostic, not advice.
#   POINTER    a documentation path, not a command.
#   DATA       a rendered data row — including a hook's explanatory hint line
#              printed beneath its own ⚠ line (session-start.sh's dedup note,
#              2026-09-14: not a command, not a pointer; it explains why the
#              ⚠ line above it will not repeat; likewise its slow-child hint,
#              2026-09-19, which names the samples log — a file, not a command).
#   SLASH      a Claude slash command, not a shell command.
#   JSON       a JSON payload line.
#
# POINTER rows key on the bare substring `cross-repo`, NOT on the deny-history
# filename, so they survive the public mirror's Class E sweep — which collapses
# `.../repos/cross-repo/<docs-path>` to "the cross-repo knowledge base". Keying
# on the filename would leave these rows matching nothing in the mirrored tree,
# i.e. the inventory would rot the moment it was published.
# ---------------------------------------------------------------------------
# Class SOURCED (added 2026-08-23): heredoc body lines that are shell CODE a
# hook writes into a machine-consumed file ($CLAUDE_ENV_FILE — sourced by CC,
# never rendered to the operator). Not advice, so never actionable; rows exist
# only so the completeness arm stays loud for lines that ARE new advice.
inventory() {
  cat <<'INV'
dhx-agent-leak-check.sh|POINTER|cross-repo
dhx-grep-fn-cap.sh|SOURCED|eval "$(declare -f grep
dhx-grep-fn-cap.sh|SOURCED|if declare -F __dhx_orig_grep
dhx-grep-fn-cap.sh|SOURCED|fi
dhx-git-destructive-guard.sh|ECHOBACK|command: $CMD
dhx-git-destructive-guard.sh|ECHOBACK|segment: $SEGMENT
dhx-git-destructive-guard.sh|POINTER|cross-repo
dhx-gsd-canonical-mirror-gate.sh|PATH|$DRAFT_BUFFER add
dhx-gsd-canonical-mirror-gate.sh|RECOMMEND|cp $FILE $CANONICAL
dhx-gsd-drift-surface.sh|DATA|first seen
dhx-gsd-drift-surface.sh|SLASH|run /dhx:statusline triad
dhx-gsd-drift-surface.sh|RECOMMEND|cp ~/.claude/gsd-core/
dhx-gsd-secret-guard-watch.sh|DATA|UNREGISTERED: the file exists
dhx-gsd-secret-guard-watch.sh|DATA|BASH UNCOVERED: registered on matcher
dhx-gsd-secret-guard-watch.sh|DATA|SHA CHANGED:
dhx-gsd-secret-guard-watch.sh|ECHOBACK|INTERPRETER GONE:
dhx-gsd-secret-guard-watch.sh|DATA|Consequence: secret-file reads issued through Bash
dhx-gsd-secret-guard-watch.sh|DATA|The permissions deny list is not a fallback here
dhx-gsd-secret-guard-watch.sh|PATH|bash ~/repos/hooks/tests/probes/probe-gsd-secret-guard-watch.sh
dhx-gsd-secret-guard-watch.sh|DATA|Then re-record deliberately
dhx-gsd-secret-guard-watch.sh|DATA|Silent from here until the state changes again
dhx-key-coverage-audit.sh|DATA|deny edits land in BOTH
session-start.sh|DATA|repeats of this exact failure stay silent
session-start.sh|DATA|stays silent until the median drops back under budget
dhx-ui-vision-guard.sh|JSON|"hookSpecificOutput"
dhx-ui-vision-guard.sh|JSON|}
INV
}

# Runnable expansions for RECOMMEND/PATH rows. Hooks print placeholders and
# shell variables, which are not executable as written; these are the concrete
# forms the operator would actually run. An inventoried RECOMMEND/PATH row with
# no mapping is a FAILURE, not a skip.
forms_for_row() {
  case "$1" in
    'dhx-gsd-canonical-mirror-gate.sh|PATH|$DRAFT_BUFFER add')
      printf '%s\n' "$REPO_ROOT/scripts/dhx-draft-buffer.sh add gsd-core/workflows/x.md --reason \"why\""
      ;;
    'dhx-gsd-canonical-mirror-gate.sh|RECOMMEND|cp $FILE $CANONICAL')
      printf '%s\n' "cp $HOME/.claude/gsd-core/workflows/x.md $HOME/.claude/gsd-local-patches/gsd-core/workflows/x.md"
      ;;
    'dhx-gsd-drift-surface.sh|RECOMMEND|cp ~/.claude/gsd-core/')
      printf '%s\n' 'cp ~/.claude/gsd-core/workflows/x.md ~/.claude/gsd-local-patches/gsd-core/workflows/x.md'
      ;;
    # The watcher tells the operator to fire the LIVE guard before trusting a sha match.
    # That advice is worthless if the probe it names has moved, so it is a PATH row.
    'dhx-gsd-secret-guard-watch.sh|PATH|bash ~/repos/hooks/tests/probes/probe-gsd-secret-guard-watch.sh')
      printf '%s\n' "bash $REPO_ROOT/tests/probes/probe-gsd-secret-guard-watch.sh"
      ;;
    *) return 1 ;;
  esac
}

# Scripts a PATH row invokes; each must resolve to an executable file.
path_targets() {
  printf '%s\n' "$REPO_ROOT/scripts/dhx-draft-buffer.sh"
  printf '%s\n' "$REPO_ROOT/tests/probes/probe-gsd-secret-guard-watch.sh"
}

# ---------------------------------------------------------------------------
# Derive printed command lines from hook source.
#   (a) heredoc body lines, (b) echo/printf whose literal payload starts with
# two spaces. A printed command line is indented exactly two spaces then a
# non-space, non-dash char — the de-facto "here is a command" convention.
# The dash exclusion skips the destructive guard's `  - <label>:` list, which
# probe-guard-suggestions-reachable.sh owns in depth.
# ---------------------------------------------------------------------------
derive_printed_lines() {
  awk '
    /^[[:space:]]*#/ { next }
    hd == "" {
      if (match($0, /<<-?[[:space:]]*['"'"'"]?[A-Za-z_][A-Za-z0-9_]*['"'"'"]?/)) {
        tok = substr($0, RSTART, RLENGTH)
        gsub(/^<<-?[[:space:]]*/, "", tok)
        gsub(/['"'"'"]/, "", tok)
        hd = tok
        next
      }
    }
    hd != "" {
      line = $0
      sub(/[[:space:]]+$/, "", line)
      if (line == hd) { hd = ""; next }
      if (line ~ /^  [^ -]/) {
        n = split(FILENAME, parts, "/")
        print parts[n] "\t" line
      }
      next
    }
    /^[[:space:]]*(echo|printf)[[:space:]]/ {
      if ($0 ~ /['"'"'"]  [^ -]/) {
        body = $0
        sub(/^[[:space:]]*(echo|printf)[[:space:]]+/, "", body)
        n = split(FILENAME, parts, "/")
        print parts[n] "\t" body
      }
    }
  ' "$@"
}

# Collect hook sources that exist.
HOOK_FILES=()
for d in "${HOOK_DIRS[@]}"; do
  [[ -d "$d" ]] || continue
  while IFS= read -r f; do HOOK_FILES+=("$f"); done < <(find "$d" -maxdepth 1 -name '*.sh' -type f | sort)
done

printf '\n== inventory integrity ==\n'

INV_ROWS="$(inventory)"
INV_COUNT="$(printf '%s\n' "$INV_ROWS" | grep -c '[^[:space:]]')"

[[ "${#HOOK_FILES[@]}" -ge 20 ]] \
  && ok "non-vacuity: found ${#HOOK_FILES[@]} hook source files to scan" \
  || bad "non-vacuity: only ${#HOOK_FILES[@]} hook files found — scan scope broke"

[[ "$INV_COUNT" -ge 5 ]] \
  && ok "non-vacuity: inventory holds $INV_COUNT row(s)" \
  || bad "non-vacuity: inventory is empty or truncated"

# Every RECOMMEND/PATH row must have a runnable mapping — fails closed.
UNMAPPED=0
while IFS= read -r row; do
  [[ -n "$row" ]] || continue
  case "$row" in
    *'|RECOMMEND|'*|*'|PATH|'*)
      if ! forms_for_row "$row" >/dev/null 2>&1; then
        UNMAPPED=1
        printf '     unmapped actionable row: %s\n' "$row"
      fi
      ;;
  esac
done <<<"$INV_ROWS"
[[ "$UNMAPPED" -eq 0 ]] \
  && ok "every RECOMMEND/PATH row maps to runnable command form(s)" \
  || bad "an actionable inventory row has no runnable mapping — add it to forms_for_row()"

printf '\n== completeness: source -> inventory (new advice cannot pass silently) ==\n'

DERIVED="$(derive_printed_lines "${HOOK_FILES[@]}")"
DERIVED_COUNT="$(printf '%s\n' "$DERIVED" | grep -c '[^[:space:]]')"

[[ "$DERIVED_COUNT" -ge 5 ]] \
  && ok "non-vacuity: derived $DERIVED_COUNT printed command line(s) from source" \
  || bad "non-vacuity: derived $DERIVED_COUNT lines — the awk parser is broken, probe is inert"

UNKNOWN=0
while IFS=$'\t' read -r file line; do
  [[ -n "${file:-}" ]] || continue
  matched=0
  while IFS='|' read -r inv_file inv_class inv_sub; do
    [[ -n "${inv_file:-}" ]] || continue
    [[ "$inv_file" == "$file" ]] || continue
    if [[ "$line" == *"$inv_sub"* ]]; then matched=1; break; fi
  done <<<"$INV_ROWS"
  if [[ "$matched" -eq 0 ]]; then
    UNKNOWN=1
    printf '     UNINVENTORIED: %s :: %s\n' "$file" "$line"
  fi
done <<<"$DERIVED"
[[ "$UNKNOWN" -eq 0 ]] \
  && ok "every printed command line in the tree matches an inventory row" \
  || bad "a hook prints advice this probe has never classified — classify it in inventory()"

printf '\n== completeness: inventory -> source (retired advice cannot rot the table) ==\n'

STALE=0
while IFS='|' read -r inv_file inv_class inv_sub; do
  [[ -n "${inv_file:-}" ]] || continue
  found=0
  while IFS=$'\t' read -r file line; do
    [[ -n "${file:-}" ]] || continue
    [[ "$file" == "$inv_file" ]] || continue
    if [[ "$line" == *"$inv_sub"* ]]; then found=1; break; fi
  done <<<"$DERIVED"
  if [[ "$found" -eq 0 ]]; then
    STALE=1
    printf '     STALE ROW (matches nothing in source): %s|%s|%s\n' "$inv_file" "$inv_class" "$inv_sub"
  fi
done <<<"$INV_ROWS"
[[ "$STALE" -eq 0 ]] \
  && ok "every inventory row still matches live source" \
  || bad "an inventory row describes advice no hook prints — prune it"

printf '\n== doctrine: no hook RECOMMENDS a reset/force-move/stash recovery ==\n'

# Grep the whole tree for recovery-family INVOCATION SHAPES. Bare-word greps
# are useless here: the fixed hooks name these commands negatively on purpose
# ("a stash or reset also pockets..."), so only an invocation shape discriminates.
#
# Comment lines are excluded, anchored on grep's `file:lineno:` prefix. That
# exclusion is necessary and slightly dangerous: the hooks fixed on 2026-08-06
# document the deleted recipe IN A COMMENT, so an unanchored filter would both
# miss real hits and (as first written) red on the deletion notice itself.
DOCTRINE_HITS="$(grep -nE '(^|[^a-zA-Z-])(git stash push|git stash save|git reset --hard|git checkout -B|git switch --discard-changes)' \
  "${HOOK_FILES[@]}" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"

if [[ -z "$DOCTRINE_HITS" ]]; then
  ok "no recovery-family invocation printed by any hook"
else
  bad "a hook prints a recovery-family command — DELETE it, do not swap it (D-2/D-7)"
  printf '%s\n' "$DOCTRINE_HITS" | sed 's|^|     |'
fi

# The two 2026-08-06 deletions must stay deleted.
# Both hooks record the deletion in a header comment that necessarily quotes
# the deleted command, so these must read UNCOMMENTED source only.
uncommented() { grep -v '^[[:space:]]*#' "$1" 2>/dev/null; }

if grep -q 'git stash push' < <(uncommented "$REPO_ROOT/dhx/dhx-agent-leak-check.sh"); then
  bad "dhx-agent-leak-check.sh: the git-stash recovery recipe is back (deleted 2026-08-06)"
else
  ok "dhx-agent-leak-check.sh: git-stash recovery recipe stays deleted"
fi

if grep -qF 'git checkout main && git merge' < <(uncommented "$REPO_ROOT/dhx/dhx-merge-reminder.sh"); then
  bad "dhx-merge-reminder.sh: the checkout-main round trip is back (deleted 2026-08-06)"
else
  ok "dhx-merge-reminder.sh: checkout-main round trip stays deleted"
fi

# ...and the hooks that name those commands NEGATIVELY must keep the negation,
# or the citation silently becomes a recommendation again.
grep -q 'No merge command is printed here' "$REPO_ROOT/dhx/dhx-merge-reminder.sh" 2>/dev/null \
  && ok "dhx-merge-reminder.sh: 'git checkout main' citation still framed as a negation" \
  || bad "dhx-merge-reminder.sh: negation framing gone — the citation now reads as advice"

grep -q "Do NOT 'git checkout main'" "$REPO_ROOT/dhx/dhx-off-main-detector.sh" 2>/dev/null \
  && ok "dhx-off-main-detector.sh: 'git checkout main' citation still framed as a negation" \
  || bad "dhx-off-main-detector.sh: negation framing gone — the citation now reads as advice"

printf '\n== reachability: PATH rows resolve to an executable ==\n'

while IFS= read -r target; do
  [[ -n "$target" ]] || continue
  if [[ -x "$target" ]]; then
    ok "path resolves and is executable: ${target#$REPO_ROOT/}"
  else
    bad "path does NOT resolve to an executable: $target"
  fi
done < <(path_targets)

# The mirror gate must print an ABSOLUTE driver path. It fires on writes to
# ~/.claude/gsd-core/ from ANY cwd, so the repo-relative form it printed before
# 2026-08-06 was unrunnable for the operator who tripped it.
if grep -qE '^[[:space:]]*echo "  scripts/dhx-draft-buffer\.sh' "$REPO_ROOT/dhx/dhx-gsd-canonical-mirror-gate.sh" 2>/dev/null; then
  bad "dhx-gsd-canonical-mirror-gate.sh: relative draft-buffer path is back — unrunnable outside the hooks repo"
else
  ok "dhx-gsd-canonical-mirror-gate.sh: draft-buffer path is not repo-relative"
fi

printf '\n== deny collision: hermetic arm (fixture list; always runs) ==\n'

FIXTURE_DENY=$'Bash(git push --force *)\nBash(git push -f *)\nBash(git reset --hard*)\nBash(cp *)'
FIXTURE_PATTERNS="$(printf '%s\n' "$FIXTURE_DENY" | bash_patterns)"

# Positive control: the fixture plants `Bash(cp *)`, which MUST collide with the
# two inventoried cp recommendations. If this does not fire, the arm is inert.
PLANTED_HITS=0
while IFS= read -r row; do
  [[ -n "$row" ]] || continue
  case "$row" in *'|RECOMMEND|'*|*'|PATH|'*) ;; *) continue ;; esac
  while IFS= read -r form; do
    [[ -n "$form" ]] || continue
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      deny_matches "$form" "$p" && PLANTED_HITS=$((PLANTED_HITS + 1))
    done <<<"$FIXTURE_PATTERNS"
  done < <(forms_for_row "$row")
done <<<"$INV_ROWS"
[[ "$PLANTED_HITS" -ge 2 ]] \
  && ok "planted defect: fixture 'Bash(cp *)' caught $PLANTED_HITS inventoried cp recommendation(s)" \
  || bad "planted defect NOT caught (hits=$PLANTED_HITS) — arm is vacuous"

printf '\n== deny collision: live arm (real deny list; SKIPS if unresolvable) ==\n'

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

  # Non-vacuity against the real list: if this goes green-by-absence, the arm
  # means nothing.
  LIVE_RESET_DENIED=0
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    deny_matches 'git reset --hard' "$p" && LIVE_RESET_DENIED=1
  done <<<"$LIVE_PATTERNS"
  [[ "$LIVE_RESET_DENIED" -eq 1 ]] \
    && ok "live non-vacuity: bare 'git reset --hard' IS denied by the real list (D-1 still locked)" \
    || bad "live non-vacuity: bare 'git reset --hard' NOT denied — D-1 changed, or the arm is inert"

  LIVE_CLEAN=1
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    case "$row" in *'|RECOMMEND|'*|*'|PATH|'*) ;; *) continue ;; esac
    while IFS= read -r form; do
      [[ -n "$form" ]] || continue
      while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        if deny_matches "$form" "$p"; then
          LIVE_CLEAN=0
          printf '     collision: [%s] %s  <=  Bash(%s)\n' "${row%%|*}" "$form" "$p"
        fi
      done <<<"$LIVE_PATTERNS"
    done < <(forms_for_row "$row")
  done <<<"$INV_ROWS"

  [[ "$LIVE_CLEAN" -eq 1 ]] \
    && ok "live: no command any hook recommends is denied by the real deny list" \
    || bad "live: a hook recommends a command the deny list forbids — fix the HOOK, not permissions.deny"
fi

printf '\n%d passed, %d failed' "$PASS" "$FAIL"
[[ "$SKIP" -gt 0 ]] && printf ', %d SKIPPED (coverage gap — see header)' "$SKIP"
printf '\n'

[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
