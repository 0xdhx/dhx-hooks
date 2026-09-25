#!/usr/bin/env bash
# pre-tool-use-gh-issue-write.sh — PreToolUse:Bash matcher (Phase 7 — REQ-UPSTR-01)
# Patterns: HP-049 (structured PreToolUse surface / exit-0 JSON), HP-009 (exit 2
#           blocks / exit 1 does not), HP-043 ($CLAUDE_CODE_SESSION_ID in tool subprocs)
#
# HARD-DENY (D-12 landed 2026-07-21; was soft-warn 2026-07-10..2026-07-21): blocks a
# FOREIGN-repo MUTATION of an issue or PR thread — create, comment, edit, close, reopen,
# review, merge, ready, a `gh api` write method, or a graphql mutation — when it runs outside
# the /dhx:upstream gated pre-flight. Upstream writes are
# irreversible and one-shot; a soft warning could only ever inform the SECOND call
# (PreToolUse `additionalContext` on an `allow` reaches the model alongside the tool
# result — structurally too late). See docs/decisions.md 2026-07-21 + 2026-08-03 rows.
#
# Four ways past this gate, in order of preference:
#   1. `/dhx:upstream <report-path>`  — new issue (the create driver writes the marker at Stage 7)
#   2. `/dhx:upstream reply <issue>`  — anything on an existing ISSUE: post a comment, amend a
#                                        comment already posted, or edit the issue body
#                                        (the reply driver writes the identical marker)
#   3. `/dhx:upstream revise <pr>`     — anything on an existing PR: response comment, retitle,
#                                        body edit, published-comment correction. NO marker on
#                                        any of them — the child-process invisibility below is
#                                        the mechanism, and every such driver lands BEFORE the
#                                        verb it needs is widened in, precisely so the deny
#                                        routes into a sanctioned path rather than the bypass.
#   4. `dhx-upstream-bypass.sh --reason "<why>"` — deliberate, audited, SINGLE-USE 60s window
#      (the script writes an audit line; this gate requires that line, then CONSUMES the
#      window on the write it allows — see the gated-path check below)
#   DELIBERATELY NOT ENUMERATED HERE OR IN THE DENY REASON: the driver script FILENAMES, and
#   the skills-repo rule for when an edit beats a follow-up. Both are another repo's canon on
#   another repo's clock; enumerating them aged this file three separate ways in three weeks
#   (see the 2026-08-25 row in docs/decisions.md). Route by SKILL MODE — those names are the
#   stable surface — and let the skill own its own route list and its own doctrine.
# Own-owner writes (see OWN_OWNERS) never reach the gate at all — silent allow.
#
# --- Ownership scoping (the no-friction-on-my-own-repos rule) ---
# The upstream discipline protects credibility with OTHER projects' maintainers; it has
# nothing to say about the operator filing an issue on their own repo. Since 2026-09-25 the
# owner is the UNION of every source the command names — every `--repo`/`-R`/`GH_REPO`
# spelling, the hook's own `$GH_REPO`, every `repos/<owner>/` path (api arm), every
# `github.com/<owner>/` URL, and the cwd's `origin` — and the write is silent only when EVERY
# one is in OWN_OWNERS. It was a precedence ladder (first rung that resolved won) until then,
# and precedence was the hole: an own-looking signal on a high rung hid foreign evidence on a
# lower one (four such foreign writes verified by an adversarial pass). A union cannot be
# spoofed by ADDING text, only made to deny more. UNRESOLVABLE owner -> deny (fail-closed:
# ambiguity on an outward write defaults to the gate, and the bypass script is the door).
# ACCEPTED COST of the union, priced before it shipped: an own write run from a checkout whose
# origin is foreign denies (2 such checkouts under ~/repos), as does an own write whose body
# quotes a foreign URL or `--repo` (0 of 27 explicit own-repo writes in the transcript corpus).
#
# --- Marker contract (unchanged, verified 2026-07-21) ---
# `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/dhx-tools/.upstream-marker-<session-id>`, written
# by run.sh (create path) and run-comment.sh (reply path) at Stage 7 start, both deleted
# on EXIT by file-and-wire.sh / comment-and-wire.sh. (Line pins removed 2026-08-02 — the
# four they carried had all drifted; resolve these by content.) 5-min TTL — do NOT
# extend it; a long TTL rots hard mode back into soft. The bypass marker is a SEPARATE
# path (`.upstream-bypass-<session-id>`, 60s TTL) so the audit trail stays distinguishable.
# The BYPASS marker is not merely read: as of 2026-09-20 an allow on that branch requires a
# matching audit line and then CONSUMES the window (marker removed, consume recorded). The
# SKILL marker is read-only by comparison — it legitimately covers several calls inside one
# Stage 7, so consuming it would break the flow it exists to permit.
#
# NOTE: /dhx:upstream's own gh calls run INSIDE file-and-wire.sh / comment-and-wire.sh,
# so PreToolUse (which sees only the top-level Bash command) never matches them. The
# fresh-marker allow branch is therefore belt-and-braces for a model-issued gh call made
# mid-flow — not the mechanism that keeps the skill working.
#
# --- Emit shape (HP-049 + HP-009) ---
# Structured deny on **exit 0**. CC reads stdout JSON on exit 0; `exit 2` blocks via
# stderr but discards the structured reason (cf. `updatedInput` "Ignored on exit 2",
# docs/hook-dev-guide.md L160) — so an exit-2 deny would block with no routing, and the
# routing IS the point. `exit 2` is kept as the emit-failure fallback ONLY, paired with
# an explicit stderr line so the block still carries a reason. Same shape as the sibling
# `dhx/dhx-worktree-bash-guard.sh:126-140`.
#
# Wiring: registered in this plugin's `hooks.json` PreToolUse array as a
# `Bash` matcher (RESEARCH Track 3 Q3.1 Option A — plugin-manifest channel,
# NOT shared settings.json). Auto-distributes across CCS instances when the
# plugin updates.
#
# --- Matcher scope (token-anchored) ---
# The verb set is MUTATION-shaped, not creation-shaped, since 2026-08-03. It was creation-only
# until then, and that gap was measured rather than theorised: two foreign mutations went out
# ungated in one session (a `--title` retitle of open-gsd/gsd-core#2493, and a PATCH rewriting an
# already-published maintainer-visible comment). An edit is as publishable as a post and worse in
# one respect — it silently rewrites text a maintainer may already have read, with no marker in
# the thread. See reports/2026-08-03-gh-write-deny-covers-create-not-edit.md.
# COVERED:
#   - `gh issue create --title x --body y`            (canonical create)
#   - `gh issue comment 123 --body y`                 (canonical comment / reply path)
#   - `gh pr comment <url|num> --body-file b`         (revise path; widened 2026-08-02)
#   - `gh issue edit|close|reopen`                    (widened 2026-08-03)
#   - `gh pr edit|review|close|reopen|merge|ready`    (widened 2026-08-03; `review` would
#     otherwise let a session approve or request-changes on a FOREIGN PR ungated)
#   - `gh api repos/o/r/issues/1/comments -X POST`    (raw-API detour; also --method, and the
#     `pulls` variant. Method set widened POST -> POST|PATCH|PUT|DELETE on 2026-08-03: PATCH on
#     the identical path was the measured bypass, same owner-resolution inputs and same
#     publication consequence, passing on one verb token)
#   - `gh api graphql … mutation …`                   (widened 2026-08-03 — see the residual below)
#   - `bash -c '…'` wrappers, pipes, leading/trailing whitespace
# ALREADY covered before 2026-08-03, do NOT "add" it: `gh issue comment --edit-last` and
#   `gh pr comment --edit-last` match on their `issue comment` / `pr comment` tokens. A probe arm
#   written for them would have been green before the widening and would prove nothing.
# STATED RESIDUAL — `gh api graphql`. The api branch cannot key on owner for graphql: there is no
#   `repos/<o>/<r>/` path in a mutation, and its targets are opaque node IDs, so owner resolution
#   has nothing to read unless the caller happens to pass `--repo` or names a github.com URL. The
#   detector therefore matches `graphql` + a `mutation` token and falls through to the SAME owner
#   resolution as every other branch — which for a typical node-ID mutation resolves NOTHING and
#   therefore DENIES (fail-closed, consistent with the unresolvable-owner posture since D-12).
#   Honest consequence, stated rather than discovered later, and MEASURED not assumed (probes
#   [62]-[64b]): the cwd-origin rung still resolves, so a graphql mutation run from inside an
#   own-repo checkout stays SILENT — the residual is narrower than "all own-repo graphql denies".
#   What denies is a mutation whose owner resolves NOWHERE: no `--repo`, no github.com URL, and a
#   cwd that is not an own-owner git repo. That is accepted — measured zero legitimate top-level
#   consumers (the only live `gh api graphql` in the
#   trees is cross-repo `scripts/upstream/ci-verdict.sh`, a read-only QUERY carrying no `mutation`
#   token, and it runs inside a script this hook cannot see anyway). The deny is loud and names
#   the bypass; a silent ungated graphql mutation is the failure worth trading it for.
# NOT COVERED — deliberate non-goals, each with a live legitimate consumer that a deny
# would break (do NOT "close the gap" without reading these first):
#   (`gh pr comment` WAS listed here and was WIDENED IN on 2026-08-02 — see the covered
#   list below. It was a non-goal because /dhx:upstream revise RV9 posted one as a
#   top-level model call; that write moved into cross-repo scripts/upstream/
#   post-pr-comment.sh, so the sanctioned path is now a child process this hook cannot
#   see. /dhx:review still posts own-repo review bodies with it and is unaffected because
#   it passes a BARE PR NUMBER, so ownership resolves from its cwd origin — pinned as a
#   permanent tooth by probe [44], not assumed.)
#   - `gh pr create` — /dhx:upstream's PR path runs it inside run-pr.sh behind 10 gates,
#     and /gsd-ship uses it routinely on own repos.
#   - raw `curl` POSTs to api.github.com — unbounded shape; not worth the false-positive
#     surface for a detour nothing in the toolchain takes.
#   Precedent for pinning a known gap at the widening site rather than closing it:
#   reports/2026-07-08-worktree-bash-guard-gap-is-loadbearing-for-deliberate-cross-tree-writes.md
#
# LIVE CONSUMERS OF THE 2026-08-03 VERBS THAT SURVIVE ON OWNERSHIP SCOPING, NOT ON THE VERB SET.
# Measured before the widening, not assumed — these are why the scoping must never be narrowed:
#   - `/gsd-inbox` (gsd-core workflows/inbox.md) runs `gh issue edit|close` and `gh pr edit|close`
#     to triage an inbox, and `/gsd-ship` (workflows/ship.md) runs `gh pr edit --add-reviewer`.
#   - `/dhx:upstream revise` RV7's retitle and RV9.5's comment correction (both now inside
#     drivers, so this hook never sees them at all).
#   Every gsd-core call passes a BARE NUMBER, so ownership resolves from the cwd's origin and they
#   stay silent on the operator's own repos — the identical shape probe [44] already pins for
#   /dhx:review. Probes [50]-[53] pin these as permanent teeth: if they ever red, gsd-inbox and
#   gsd-ship are broken. Corollary worth stating: triaging an inbox on a repo you maintain that is
#   NOT under OWN_OWNERS will deny. That is the ownership list being too narrow, not the verb set
#   being too wide — widen OWN_OWNERS in a reviewable commit, do not re-narrow the verbs.
# ALSO NOT matched (token-anchoring, as before): `gh issue list`, `gh issue create-else`,
# `mygh issue comment`.
#
# ACCEPTED FALSE POSITIVE — RE-PRICED 2026-08-25, the original pricing was wrong.
# Stated 2026-08-03 as: a doc whose prose carries a covered verb at line-start AND a foreign
# `github.com/<owner>/` URL now denies. **The AND was never in the code.** The verb arm above
# requires no URL at all — the URL-bearing condition belongs to the `gh api` arm — so the real
# surface is every command that merely CONTAINS a covered verb, mid-line included (live since
# 565b9c4) and heredoc bodies included (visible since the 2026-08-03 parse fix). The 2026-08-03
# clause "no complaint on record" is also retired: it was measured twice in one session on
# 2026-08-24, the second time on the probe written to characterise the first, so the defect
# briefly made itself unprobeable.
# STILL ACCEPTED, and now for a stated reason rather than a mis-priced one. What turned those
# two matches into DENIES was the ownership rung reading a local path (fixed above), not the
# verb match; with that fixed, a doc-authoring command whose cwd is an own repo resolves the
# own owner and stays SILENT. What remains is a doc that ALSO quotes a foreign
# `github.com/<owner>/` URL — that resolves foreign on the deliberately-loose positional rung
# and denies. Over-matching is the correct direction on an irreversible outward write.
# REJECTED FIX, so nobody reaches for it again: stripping quoted heredoc bodies from $CMD
# before the greps (proposed in reports/2026-08-24-gh-write-deny-false-positives-…md § 1b on
# the argument that a quoted heredoc is inert). It is not inert —
#   `cat <<'X' >/tmp/f; bash /tmp/f`  and  `tee >(bash) <<'X'`
# both execute the body in the same command, so an allowlist keyed on the heredoc's opener
# cannot prove the compound command inert, and a strip would hide an invocation that really
# runs. A sound version needs shell tokenization, which HP-037 scoped out and which
# docs/backlog.md `command-substitution-blind-spot` already records as refused.
# THE MITIGATION IS NOW IN THE DENY REASON, not just in the sibling skill: an author who is
# writing a document rather than making a call is told to assemble the verb tokens from shell
# variables (as tests/probes/probe-gh-issue-write.sh does) or to use the Write/Edit tool.
# Do NOT re-narrow the verb set and do NOT reinstate the truncating parse.

set -euo pipefail

# Owners whose repos are exempt — the operator's own namespace. Hardcoded on purpose:
# an env var or a dotfile allowlist would be settable by the model it gates, which is
# soft mode with extra steps. Widening this list is a reviewable commit.
OWN_OWNERS="0xdhx"

INPUT=$(cat)

# jq absent -> defensive no-op (cannot parse stdin)
if ! command -v jq >/dev/null 2>&1; then exit 0; fi

# Parse cwd + command from PreToolUse stdin JSON.
# TWO INDEPENDENT READS — do NOT "simplify" this back to `jq … | @tsv` + `read`. That was
# the shipped idiom from 565b9c4 until 2026-08-03 and it broke the matcher two ways, both
# measured (not theorised) and both silent:
#   1. `@tsv` escapes a real newline/tab into the TWO characters `\`+`n` / `\`+`t`. The
#      character immediately preceding a line-start `gh` therefore became the letter `n`
#      (or `t` under tab indentation) — which IS `[[:alnum:]_]`, so the `(^|[^[:alnum:]_])`
#      anchor below could never match and every covered verb at the start of a continuation
#      line was SILENTLY ALLOWED. Note the predicate is the escaped whitespace char, not
#      "multi-line": `cd /tmp && gh pr edit` on line 2, and a SPACE-indented line-2 call,
#      both matched correctly even before the fix.
#   2. Tab is IFS-*whitespace*, so `read` collapses a leading empty field: an empty `.cwd`
#      shifted the whole command into $CWD and left $CMD empty — MATCHED=0, allow again.
# `$(…)` strips trailing newlines only; interior newlines survive, which is exactly what
# the anchor needs. Same reasoning, same fix, as dhx/dhx-read-dedup.sh:120 (which abandoned
# @tsv for the field-collapse half in its own header note).
# Sibling with the identical defect, fixed in the same commit: dhx/dhx-worktree-bash-guard.sh.
CWD=$(jq -r '.cwd // ""'                <<<"$INPUT" 2>/dev/null || true)
CMD=$(jq -r '.tool_input.command // ""' <<<"$INPUT" 2>/dev/null || true)

# --- Match: gh issue|pr MUTATION verb (token-anchored) OR gh api write-method to an
#     issue/PR thread OR a gh api graphql MUTATION (widened 2026-08-03 — see header) ---
# Widened 2026-09-25 (fix 1 of reports/2026-09-25-guard-false-positive-census.md), each shape
# measured SILENT against the prior hook (probe [89]-[105] BITE arms):
#   - a repo flag BETWEEN `gh` and the subcommand (`gh --repo o/r issue …`, `gh -R o/r pr …`) —
#     gh accepts it (verified live), and the old anchor needed `gh issue` adjacent;
#   - api method as `--method=X` or attached `-XPOST` (was space-separated only);
#   - api IMPLICIT POST: gh api sends POST whenever a field flag (-f/-F/--field/--raw-field/
#     --input) is present without an explicit GET — no method token at all;
#   - an api endpoint ENDING at `issues`/`pulls` (the issue-create endpoint), not only `…/`.
# STATED RESIDUAL: the GET exemption reads the whole command, so a `-X GET` anywhere (another
#   invocation, body prose) suppresses implicit-POST detection. Scoping it per invocation needs
#   the shell tokenizer this repo refused (docs/backlog.md `command-substitution-blind-spot`).
# NOT widened: `gh issue delete|lock|unlock|transfer`, `gh pr lock` — each needs maintainer
#   rights on the target, so a foreign one fails at GitHub; an own one is silent anyway.
MATCHED=0
MATCH_ARM=""
Q="[\"']"
REPOFLAG='([[:space:]]+(-R[[:space:]]*|--repo([[:space:]]+|=))[^[:space:]]+)*'
FIELDFLAG='(^|[[:space:]])(-f|-F|--field|--raw-field|--input)([[:space:]]|=|$)|(^|[[:space:]])-[fF][A-Za-z0-9_]+='
if grep -qE "(^|[^[:alnum:]_])gh${REPOFLAG}[[:space:]]+(issue[[:space:]]+(create|comment|edit|close|reopen)|pr[[:space:]]+(comment|edit|review|close|reopen|merge|ready))([[:space:]]|\$)" <<< "$CMD"; then
  MATCHED=1; MATCH_ARM=verb
elif grep -qE '(^|[^[:alnum:]_])gh[[:space:]]+api([[:space:]]|$)' <<< "$CMD" \
     && grep -qE "(^|[^[:alnum:]_])repos/[^[:space:]/]+/[^[:space:]/]+/(issues|pulls)([/?[:space:]\"']|\$)" <<< "$CMD" \
     && { grep -qiE "(-X[[:space:]]*|--method([[:space:]]+|=))${Q}?(POST|PATCH|PUT|DELETE)([^[:alnum:]]|\$)" <<< "$CMD" \
          || { grep -qE "$FIELDFLAG" <<< "$CMD" \
               && ! grep -qiE "(-X[[:space:]]*|--method([[:space:]]+|=))${Q}?GET([^[:alnum:]]|\$)" <<< "$CMD"; }; }; then
  MATCHED=1; MATCH_ARM=api
elif grep -qE '(^|[^[:alnum:]_])gh[[:space:]]+api[[:space:]]+graphql([[:space:]]|$)' <<< "$CMD" \
     && grep -qE '(^|[^[:alnum:]_])mutation([^[:alnum:]_]|$)' <<< "$CMD"; then
  MATCHED=1; MATCH_ARM=graphql
fi
[ "$MATCHED" = "1" ] || exit 0

# --- Resolve the target owners: the UNION of every source (2026-09-25) ---
# Each rung below APPENDS to $OWNERS; none short-circuits another. Until 2026-09-25 this was a
# precedence ladder — each later rung ran only `if [ -z "$OWNER" ]`, and each rung took only
# its FIRST match — so an own-looking hit on an early rung hid every foreign signal after it.
# Verified holes that shape had (all now denied, probe [89]-[101]): `--repo=` and attached
# `-R` never parsed at all; `GH_REPO` was never read; an own `--repo` in one call exempted a
# foreign `--repo` in the next call of the same command; an own positional URL exempted a
# foreign-origin cwd. Appending can only add denies, never remove one.
OWNERS=""
# 1. explicit repo flags — EVERY occurrence, every spelling gh accepts: `--repo o/r`,
#    `--repo=o/r`, `-R o/r`, `-Ro/r`, quoted or not. A `HOST/OWNER/REPO` value resolves the
#    host as the owner and so denies (fail-closed; the value form is rare and the deny names it).
#    The owner is taken by STRIPPING the flag prefix, never by a trailing character class:
#    `[A-Za-z0-9_.-]+/$` also swallows an attached `-R` (the class contains `-`), turning
#    `-R0xdhx/…` into owner `-R0xdhx` — measured, probe [109], and it had made [90] pass by
#    accident rather than by parse.
OWNERS+=$'\n'$(grep -oE "(--repo([[:space:]]+|=)|(^|[[:space:]])-R[[:space:]]*)${Q}?[A-Za-z0-9_.-]+/" <<< "$CMD" 2>/dev/null \
          | sed -E "s/^.*(--repo([[:space:]]+|=)|-R[[:space:]]*)${Q}?//; s|/\$||" || true)
# 1b. GH_REPO — gh's own override, read from BOTH places it can come from: an assignment in
#     the command (`GH_REPO=o/r gh …`, `export GH_REPO=o/r`) and the environment this hook
#     inherits, which is the environment the tool call's gh would inherit too.
OWNERS+=$'\n'$(grep -oE "(^|[^[:alnum:]_])GH_REPO=${Q}?[A-Za-z0-9_.-]+/" <<< "$CMD" 2>/dev/null \
          | grep -oE '[A-Za-z0-9_.-]+/$' | tr -d '/' || true)
if [ -n "${GH_REPO:-}" ]; then OWNERS+=$'\n'"${GH_REPO%%/*}"; fi
# 2. gh api path shape: repos/<owner>/<name>/… — SCOPED TO THE api ARM (2026-08-25).
#    This rung reads a path, and a path is only an ownership signal on the arm that
#    matched ON a path. It used to run for every arm, which broke BOTH ways and both
#    were measured, not theorised:
#      - FALSE DENY: a purely local file write whose command merely contained
#        `repos/cross-repo/scripts/…` — a directory under ~/repos, never a GitHub
#        account — resolved OWNER=cross-repo, missed OWN_OWNERS and denied a write
#        whose real destination was an own repo. Twice in one session, the second time
#        on the probe written to characterise the first.
#      - FALSE ALLOW (the worse half, and the one nobody had found): a FOREIGN
#        `issue comment` from a FOREIGN checkout whose --body prose mentioned
#        `repos/0xdhx/…` resolved an OWN owner out of the prose and was SILENTLY
#        ALLOWED. Same failure mode the positional-URL rung was added for on
#        2026-08-02 ("a FOREIGN target resolved to an OWN owner and the deny silently
#        no-opped"), living on a different rung.
#    Strict no-op for the api arm: that arm already REQUIRES a literal
#    `repos/<o>/<r>/(issues|pulls)/`, so every command it matched resolves the same
#    owner as before. The issue/pr verbs take a number, a URL or --repo — never a
#    filesystem path — so nothing legitimate is lost on the verb arm.
#    STATED RESIDUAL: a foreign target supplied DYNAMICALLY (e.g. a `$(cat …)` whose
#    file happens to live under a `repos/` directory) denied here by accident before
#    and now falls to the cwd-origin rung. That coverage was incidental — the same
#    call with the file anywhere outside `repos/` already allowed — and this guard is
#    documented blind to `$(…)` anyway (docs/backlog.md `command-substitution-blind-spot`).
if [ "$MATCH_ARM" = "api" ]; then
  OWNERS+=$'\n'$(grep -oE '(^|[^[:alnum:]_])repos/[A-Za-z0-9_.-]+/' <<< "$CMD" 2>/dev/null \
            | sed -E 's|.*repos/||; s|/$||' || true)
fi
# 3. positional target URL: https://github.com/<owner>/<repo>/...
#    Added 2026-08-02. Without this branch a positional issue/PR URL resolved NOTHING
#    here and fell through to the cwd's origin — so from a fork checkout (origin
#    0xdhx/...) a FOREIGN target resolved to an OWN owner and the deny silently
#    no-opped. That was a live bypass of the hard deny, not a theoretical one; a revise
#    worktree IS such a cwd. Must precede the cwd fallback.
#    Deliberately loose: any github.com/<owner>/<repo> in the command counts, including
#    one quoted inside --body. That over-matches (a foreign link in prose denies a write
#    aimed at the cwd's own repo) and over-matching is the correct direction — the deny
#    message already tells the operator to pass --repo explicitly, which outranks this.
OWNERS+=$'\n'$(grep -oE 'github\.com/[A-Za-z0-9_.-]+/' <<< "$CMD" 2>/dev/null \
            | sed -E 's|.*github\.com/||; s|/$||' || true)
# 4. the cwd's origin remote — ALWAYS joins (2026-09-25; was a fallback). A bare issue number
#    targets this repo, and a flag or URL that only APPEARS in body prose cannot be told from a
#    real one without tokenizing, so the cwd is evidence even when other rungs resolved.
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
  ORIGIN=$(git -C "$CWD" remote get-url origin 2>/dev/null || true)
  # git@github.com:owner/repo.git | https://github.com/owner/repo(.git)
  OWNERS+=$'\n'$(sed -E 's|^[^:]+://[^/]+/||; s|^[^@]+@[^:]+:||; s|/.*$||' <<< "$ORIGIN" 2>/dev/null || true)
fi

# Own-owner target -> silent allow, ONLY when every resolved owner is own. No marker, no
# bypass, no friction (the upstream discipline is about OTHER maintainers' repos). GitHub
# owners are case-insensitive, so the comparison is too. $OWNER ends up as the FIRST foreign
# owner (named in the deny and the audit line), or empty when nothing resolved at all.
OWNER=""
RESOLVED=0
while IFS= read -r o; do
  [ -n "$o" ] || continue
  RESOLVED=1
  is_own=0
  for own in $OWN_OWNERS; do [ "${o,,}" = "${own,,}" ] && is_own=1; done
  if [ "$is_own" = 0 ] && [ -z "$OWNER" ]; then OWNER="$o"; fi
done <<< "$OWNERS"
if [ "$RESOLVED" = 1 ] && [ -z "$OWNER" ]; then exit 0; fi

# --- Gated-path check: fresh /dhx:upstream marker OR AUDITED deliberate-bypass window ---
# The bypass branch requires POSITIVE EVIDENCE that the audited script ran for THIS session
# inside the TTL -- a marker mtime is not that evidence. Before 2026-09-20 this branch read
# the marker's mtime alone, and `touch` is in the settings allow list while
# $CLAUDE_CODE_SESSION_ID is exported into every tool subprocess (HP-043) and the marker
# directory path is printed verbatim in this gate's own deny message. So the window could be
# opened by a one-token command that wrote nothing to the audit log and named nothing
# recognisable in the transcript: of the three properties dhx-upstream-bypass.sh claims --
# LOUD, LOGGED, SHORT -- only SHORT actually survived.
# Now BOTH must hold: the per-session marker is fresh AND the audit log's last line for this
# session is inside the same window. The script writes both, in that order; `touch` writes
# neither. This does not make the hatch harder to open on purpose -- nothing can, there being
# no human-only channel in this session model -- it makes a defection leave a record in the
# file that gets reviewed, which is the whole security argument.
# TIMESTAMP SOURCE is the log line's own `date -Is` field, NOT the log file's mtime: mtime
# is a property of the last write by ANY session, so a peer session opening its own window
# would refresh it for everyone.
# FAIL-CLOSED throughout: log unreadable, no line for this session, an unparseable timestamp,
# or a future-dated one -> the branch does not allow, and the deny below routes as usual.
# The `find ... -mmin` form is LOAD-BEARING and must not become a relative `-newermt`: this
# machine's `find` is a bfs shim where a relative `-newermt` exits 1 with no output, which
# reads as a clean miss (global CLAUDE.md; docs/troubleshooting.md).
# STATED RESIDUAL -- the 5-min SKILL marker branch above is still mtime-only and has the
# same touch-ability. Lower stake, deliberately left: it attests that the gated pre-flight
# ran, and the pre-flight is the thing a defector would be skipping anyway. The bypass marker
# is the one with a self-service door and an explicit audit claim attached to it.
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
MARKER_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/dhx-tools"
BYPASS_TTL_SEC=60
if [ -n "$SESSION_ID" ]; then
  MARKER="$MARKER_DIR/.upstream-marker-$SESSION_ID"
  BYPASS="$MARKER_DIR/.upstream-bypass-$SESSION_ID"
  AUDIT="$MARKER_DIR/upstream-bypass.log"
  # Skill marker: 5-min TTL, mtime-only (see the stated residual above).
  if [ -f "$MARKER" ] && [ -n "$(find "$MARKER" -mmin -5 2>/dev/null)" ]; then exit 0; fi
  # Bypass window: 60s TTL, marker AND audit line.
  if [ -f "$BYPASS" ] && [ -n "$(find "$BYPASS" -mmin -1 2>/dev/null)" ] && [ -r "$AUDIT" ]; then
    # Read the LAST audit event for this session and require it to be an OPEN.
    # Two event kinds name a session: an opening (`session=<id>`, written by
    # dhx-upstream-bypass.sh) and a consume (`consumed_by=<id>`, written below). Matching
    # only openings would make the consume unenforceable -- the opening line stays inside
    # its own TTL for the rest of the 60s, so re-touching the marker would reopen the
    # window on a line that had already been spent. Measured, not theorised: probe [35d]
    # was red for exactly this before the check became last-event-wins.
    # awk compares WHOLE TAB-SEPARATED FIELDS, so a session id that is a strict prefix of
    # another cannot match it, and no part of the id is ever treated as a regex -- which a
    # `grep -E` alternation over an interpolated id would have done.
    # awk absent, or no event for this session -> empty -> deny (fail-closed).
    LAST_EVENT=$(awk -F'\t' -v s="$SESSION_ID" '
      { hit = 0
        for (i = 1; i <= NF; i++) {
          if      ($i == "session="     s) { hit = 1; kind = "open" }
          else if ($i == "consumed_by=" s) { hit = 1; kind = "consume" }
        }
        if (hit) last = kind "\t" $1 }
      END { if (last != "") print last }' "$AUDIT" 2>/dev/null || true)
    LAST_KIND=${LAST_EVENT%%$'\t'*}
    LAST_LINE=${LAST_EVENT#*$'\t'}
    [ "$LAST_KIND" = "open" ] || LAST_LINE=""
    if [ -n "$LAST_LINE" ]; then
      LAST_TS=$LAST_LINE
      LAST_EPOCH=$(date -d "$LAST_TS" +%s 2>/dev/null || true)
      NOW_EPOCH=$(date +%s)
      if [ -n "$LAST_EPOCH" ] && [ "$LAST_EPOCH" -le "$NOW_EPOCH" ] \
         && [ "$((NOW_EPOCH - LAST_EPOCH))" -lt "$BYPASS_TTL_SEC" ]; then
        # CONSUME the window. Before 2026-09-20 the gate only READ the marker, so one
        # opening bought every covered write that fit inside 60 seconds -- while the script
        # and this header both described it as "one command's worth". Removing the marker
        # here makes the single-use claim true rather than aspirational: a second write needs
        # a second opening, which needs a second audit line naming its own reason.
        # FIELD NAME IS `consumed_by=`, NOT `session=`, and that is load-bearing. The audit
        # check above matches a tab-bounded `session=<id>`; a consume line carrying that field
        # would itself satisfy the check, so re-touching the marker after a consume would
        # reopen the window on the gate's own bookkeeping. Do not rename this field.
        rm -f "$BYPASS" 2>/dev/null || true
        printf '%s\tevent=consume\tconsumed_by=%s\tarm=%s\towner=%s\n' \
          "$(date -Is)" "$SESSION_ID" "$MATCH_ARM" "${OWNER:-<unresolved>}" \
          >> "$AUDIT" 2>/dev/null || true
        exit 0
      fi
    fi
  fi
fi

# --- Deny (structured, exit 0 — see "Emit shape" in the header) ---
TARGET="${OWNER:-<unresolved owner>}"
REASON="DENIED: this is an irreversible write to a foreign upstream repo ($TARGET) running outside the /dhx:upstream gated pre-flight, which protects upstream credibility with a 7-stage discipline (pristine fetch, fork audit, self-shim audit, redaction sweep, search corpus, evidence inventory, atomic wire-up). A bare call skips all of it, and the write cannot be taken back. Take one of these routes: (1) a NEW issue -> '/dhx:upstream <report-path>'; (2) anything on an EXISTING issue -> '/dhx:upstream reply <issue-url-or-number>' — that mode covers posting a comment, amending a comment you already posted, and editing the issue body, so an edit is NOT a reason to reach for the bypass; (3) anything on an EXISTING PR of yours — response comment, retitle, body edit, or correcting an already-published comment -> '/dhx:upstream revise <pr-url>'. The skill owns the current route list and the current rule for when an edit is preferred over a follow-up; read it there rather than inferring either from this message, which deliberately names no driver scripts and restates no doctrine. (4) deliberate one-off, audited + single-use 60s window -> 'bash \"\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/dhx-tools/dhx-upstream-bypass.sh\" --reason \"<why the gated path does not fit>\"' then re-run this command. That opening is spent by the first write it lets through, so a second write needs a second opening with its own stated reason. NOT ACTUALLY MAKING A CALL? This gate greps the whole command string, so a command that merely AUTHORS OR QUOTES A DOCUMENT containing one of the covered verbs matches too, heredoc bodies included — nothing upstream is written by such a command. Assemble the verb tokens from shell variables, or write the file with the Write/Edit tool instead of a shell heredoc, and this deny disappears. Own-repo writes (owner in the hook's OWN_OWNERS list) are never gated — but EVERY owner the command names must be yours: each --repo / -R / GH_REPO, each github.com URL (body prose included), and the origin of the directory you run it from. If this target IS yours, either the owner did not resolve (pass '--repo <owner>/<name>' explicitly; a graphql mutation on a node ID resolves no owner at all, so it always lands here) or something else in the command names a foreign owner — drop the foreign mention, or run from a checkout whose origin is yours."
MSG="Blocked: upstream write to $TARGET outside /dhx:upstream. Use '/dhx:upstream reply <issue>' or '/dhx:upstream <report-path>' — or run dhx-tools/dhx-upstream-bypass.sh --reason \"...\" for a deliberate one-off."

if DENY_JSON=$(jq -cn --arg r "$REASON" --arg m "$MSG" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r},systemMessage:$m}' 2>/dev/null) \
   && printf '%s\n' "$DENY_JSON"; then
  exit 0
fi

# Emit failed (jq/printf) — fall CLOSED. exit 2 blocks via stderr (HP-009); the explicit
# stderr line is what carries the reason, since stdout JSON is discarded on exit 2.
echo "BLOCKED (fallback): upstream gh write to $TARGET outside the /dhx:upstream gated pre-flight, and the structured deny could not be emitted. Use '/dhx:upstream reply <issue>' or '/dhx:upstream <report-path>', or dhx-tools/dhx-upstream-bypass.sh --reason \"...\"." >&2
exit 2
