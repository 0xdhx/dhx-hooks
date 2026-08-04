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
#   1. `/dhx:upstream <report-path>`  — new issue (run.sh writes the marker at Stage 7)
#   2. `/dhx:upstream reply <issue>`  — comment    (run-comment.sh, identical marker)
#   3. `/dhx:upstream revise <pr>`     — PR comment (post-pr-comment.sh), retitle
#                                        (edit-pr-title.sh, RV7) and published-comment
#                                        correction (edit-pr-comment.sh, RV9.5). NO marker on
#                                        any of them — the child-process invisibility below is
#                                        the mechanism, and all three drivers landed BEFORE the
#                                        verb widening precisely so it would deny into a
#                                        sanctioned route rather than into the bypass.
#   4. `dhx-upstream-bypass.sh --reason "<why>"` — deliberate, audited, 60s window
# Own-owner writes (see OWN_OWNERS) never reach the gate at all — silent allow.
#
# --- Ownership scoping (the no-friction-on-my-own-repos rule) ---
# The upstream discipline protects credibility with OTHER projects' maintainers; it has
# nothing to say about the operator filing an issue on their own repo. Target owner is
# resolved from `--repo/-R <owner>/<name>`, else the `repos/<owner>/<name>/` path of a
# `gh api` call, else the cwd's `origin` remote. Owner in OWN_OWNERS -> silent allow.
# UNRESOLVABLE owner -> deny (fail-closed: ambiguity on an outward write defaults to the
# gate, and the bypass script is the documented door).
#
# --- Marker contract (unchanged, verified 2026-07-21) ---
# `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/dhx-tools/.upstream-marker-<session-id>`, written
# by run.sh (create path) and run-comment.sh (reply path) at Stage 7 start, both deleted
# on EXIT by file-and-wire.sh / comment-and-wire.sh. (Line pins removed 2026-08-02 — the
# four they carried had all drifted; resolve these by content.) 5-min TTL — do NOT
# extend it; a long TTL rots hard mode back into soft. The bypass marker is a SEPARATE
# path (`.upstream-bypass-<session-id>`, 60s TTL) so the audit trail stays distinguishable.
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
# ACCEPTED FALSE POSITIVE (stated up front rather than discovered later, 2026-08-03). Once
# the stdin parse stopped truncating at the first escaped newline, a command that merely
# CONTAINS a covered verb at the start of a line became visible to the matcher — including
# one inside a heredoc body. So writing a doc/report whose prose has a covered verb at
# line-start AND any foreign `github.com/<owner>/` URL anywhere in the same command now
# DENIES. That is this repo's own upstream reports, near enough exactly. It is accepted, for
# the reason the positional-URL rung above already states: over-matching is the correct
# direction on an irreversible outward write, and the cost is one `dhx-upstream-bypass.sh`
# invocation against a write that cannot be taken back. Two facts bound it: the SAME false
# positive has been live for every mid-line occurrence since 565b9c4 with no report or
# backlog row complaining, and the no-URL case still resolves to the cwd's own origin and
# stays silent. If this ever does become friction, narrow the URL rung — do NOT re-narrow
# the verb set or reinstate the truncating parse.

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
MATCHED=0
if grep -qE '(^|[^[:alnum:]_])gh[[:space:]]+(issue[[:space:]]+(create|comment|edit|close|reopen)|pr[[:space:]]+(comment|edit|review|close|reopen|merge|ready))([[:space:]]|$)' <<< "$CMD"; then
  MATCHED=1
elif grep -qE '(^|[^[:alnum:]_])gh[[:space:]]+api([[:space:]]|$)' <<< "$CMD" \
     && grep -qE '(-X|--method)[[:space:]]+(POST|PATCH|PUT|DELETE)([[:space:]]|$)' <<< "$CMD" \
     && grep -qE '(^|[^[:alnum:]_])repos/[^[:space:]/]+/[^[:space:]/]+/(issues|pulls)/' <<< "$CMD"; then
  MATCHED=1
elif grep -qE '(^|[^[:alnum:]_])gh[[:space:]]+api[[:space:]]+graphql([[:space:]]|$)' <<< "$CMD" \
     && grep -qE '(^|[^[:alnum:]_])mutation([^[:alnum:]_]|$)' <<< "$CMD"; then
  MATCHED=1
fi
[ "$MATCHED" = "1" ] || exit 0

# --- Resolve the target owner (ownership scoping) ---
# 1. explicit --repo / -R <owner>/<name>
OWNER=$(grep -oE '(--repo|-R)[[:space:]]+[\"'"'"']?[A-Za-z0-9_.-]+/' <<< "$CMD" 2>/dev/null \
          | head -1 | grep -oE '[A-Za-z0-9_.-]+/$' | tr -d '/' || true)
# 2. gh api path shape: repos/<owner>/<name>/…
if [ -z "$OWNER" ]; then
  OWNER=$(grep -oE '(^|[^[:alnum:]_])repos/[A-Za-z0-9_.-]+/' <<< "$CMD" 2>/dev/null \
            | head -1 | sed -E 's|.*repos/||; s|/$||' || true)
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
if [ -z "$OWNER" ]; then
  OWNER=$(grep -oE 'github\.com/[A-Za-z0-9_.-]+/' <<< "$CMD" 2>/dev/null \
            | head -1 | sed -E 's|.*github\.com/||; s|/$||' || true)
fi
# 4. fall back to the cwd's origin remote
if [ -z "$OWNER" ] && [ -n "$CWD" ] && [ -d "$CWD" ]; then
  ORIGIN=$(git -C "$CWD" remote get-url origin 2>/dev/null || true)
  # git@github.com:owner/repo.git | https://github.com/owner/repo(.git)
  OWNER=$(sed -E 's|^[^:]+://[^/]+/||; s|^[^@]+@[^:]+:||; s|/.*$||' <<< "$ORIGIN" 2>/dev/null || true)
fi

# Own-owner target -> silent allow. No marker, no bypass, no friction (the upstream
# discipline is about OTHER maintainers' repos; own-repo filings carry no such surface).
if [ -n "$OWNER" ]; then
  for own in $OWN_OWNERS; do
    [ "$OWNER" = "$own" ] && exit 0
  done
fi

# --- Gated-path check: fresh /dhx:upstream marker OR fresh deliberate-bypass marker ---
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
MARKER_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/dhx-tools"
if [ -n "$SESSION_ID" ]; then
  MARKER="$MARKER_DIR/.upstream-marker-$SESSION_ID"
  BYPASS="$MARKER_DIR/.upstream-bypass-$SESSION_ID"
  # Skill marker: 5-min TTL. Bypass marker: 60s TTL (deliberate, single-command window).
  if [ -f "$MARKER" ] && [ -n "$(find "$MARKER" -mmin -5 2>/dev/null)" ]; then exit 0; fi
  if [ -f "$BYPASS" ] && [ -n "$(find "$BYPASS" -mmin -1 2>/dev/null)" ]; then exit 0; fi
fi

# --- Deny (structured, exit 0 — see "Emit shape" in the header) ---
TARGET="${OWNER:-<unresolved owner>}"
REASON="DENIED: this is an irreversible write to a foreign upstream repo ($TARGET) running outside the /dhx:upstream gated pre-flight, which protects upstream credibility with a 7-stage discipline (pristine fetch, fork audit, self-shim audit, redaction sweep, search corpus, evidence inventory, atomic wire-up). A bare gh call skips all of it, and the write cannot be taken back. Take one of these paths: (1) new issue -> '/dhx:upstream <report-path>'; (2) reply on an existing issue -> '/dhx:upstream reply <issue-url-or-number>'; (3) anything on an EXISTING PR of yours — response comment, retitle, or correcting an already-published comment -> '/dhx:upstream revise <pr-url>', whose RV7/RV9/RV9.5 steps call the sanctioned drivers under dhx-tools/dhx-upstream/ (edit-pr-title.sh, edit-pr-comment.sh, post-pr-comment.sh); prefer posting a follow-up over editing published text, which rewrites what a maintainer may already have read; (4) deliberate one-off, audited + 60s window -> 'bash \"\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/dhx-tools/dhx-upstream-bypass.sh\" --reason \"<why the gated path does not fit>\"' then re-run this command. Own-repo writes (owner in the hook's OWN_OWNERS list) are never gated; if this target IS yours, the owner did not resolve — pass '--repo <owner>/<name>' explicitly (a graphql mutation on a node ID resolves no owner at all, so it always lands here)."
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
