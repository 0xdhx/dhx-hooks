#!/usr/bin/env bash
# pre-tool-use-gh-issue-write.sh — PreToolUse:Bash matcher (Phase 7 — REQ-UPSTR-01)
# Patterns: HP-049 (structured PreToolUse surface / exit-0 JSON), HP-009 (exit 2
#           blocks / exit 1 does not), HP-043 ($CLAUDE_CODE_SESSION_ID in tool subprocs)
#
# HARD-DENY (D-12 landed 2026-07-21; was soft-warn 2026-07-10..2026-07-21): blocks a
# FOREIGN-repo `gh issue create` / `gh issue comment` / `gh api …POST` on an issue or PR
# thread when it runs outside the /dhx:upstream gated pre-flight. Upstream writes are
# irreversible and one-shot; a soft warning could only ever inform the SECOND call
# (PreToolUse `additionalContext` on an `allow` reaches the model alongside the tool
# result — structurally too late). See docs/decisions.md 2026-07-21 row.
#
# Three ways past this gate, in order of preference:
#   1. `/dhx:upstream <report-path>`  — new issue (run.sh writes the marker at Stage 7)
#   2. `/dhx:upstream reply <issue>`  — comment    (run-comment.sh, identical marker)
#   3. `dhx-upstream-bypass.sh --reason "<why>"` — deliberate, audited, 60s window
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
# by run.sh:921 (create path) and run-comment.sh:427 (reply path) at Stage 7 start, both
# deleted on EXIT by file-and-wire.sh:203 / comment-and-wire.sh:143. 5-min TTL — do NOT
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
# COVERED:
#   - `gh issue create --title x --body y`            (canonical create)
#   - `gh issue comment 123 --body y`                 (canonical comment / reply path)
#   - `gh api repos/o/r/issues/1/comments -X POST`    (raw-API detour; also --method POST,
#     and the `pulls` variant — zero legitimate consumers across the skills-monorepo
#     dhx skills and the cross-repo script trees as of 2026-07-21, so it costs nothing)
#   - `bash -c '…'` wrappers, pipes, leading/trailing whitespace
# NOT COVERED — deliberate non-goals, each with a live legitimate consumer that a deny
# would break (do NOT "close the gap" without reading these first):
#   - `gh pr comment` — /dhx:upstream revise step RV-4 posts one as a top-level model call
#     and writes NO marker (its own AskUserQuestion is the gate — see skills
#     dhx/upstream/references/upstream-pr-revise.md), and /dhx:review posts own-repo PR
#     review bodies with it (dhx/review/references/review-code-output.md).
#   - `gh pr create` — /dhx:upstream's PR path runs it inside run-pr.sh behind 10 gates,
#     and /gsd-ship uses it routinely on own repos.
#   - raw `curl` POSTs to api.github.com — unbounded shape; not worth the false-positive
#     surface for a detour nothing in the toolchain takes.
#   Precedent for pinning a known gap at the widening site rather than closing it:
#   reports/2026-07-08-worktree-bash-guard-gap-is-loadbearing-for-deliberate-cross-tree-writes.md
# ALSO NOT matched (token-anchoring, as before): `gh issue list`, `gh issue create-else`,
# `mygh issue comment`.

set -euo pipefail

# Owners whose repos are exempt — the operator's own namespace. Hardcoded on purpose:
# an env var or a dotfile allowlist would be settable by the model it gates, which is
# soft mode with extra steps. Widening this list is a reviewable commit.
OWN_OWNERS="0xdhx"

INPUT=$(cat)

# jq absent -> defensive no-op (cannot parse stdin)
if ! command -v jq >/dev/null 2>&1; then exit 0; fi

# Parse cwd + command from PreToolUse stdin JSON
IFS=$'\t' read -r CWD CMD < <(jq -r '[.cwd // "", .tool_input.command // ""] | @tsv' <<<"$INPUT" 2>/dev/null || echo $'\t')

# --- Match: gh issue create|comment (token-anchored) OR gh api POST to an issue/PR thread ---
MATCHED=0
if grep -qE '(^|[^[:alnum:]_])gh[[:space:]]+issue[[:space:]]+(create|comment)([[:space:]]|$)' <<< "$CMD"; then
  MATCHED=1
elif grep -qE '(^|[^[:alnum:]_])gh[[:space:]]+api([[:space:]]|$)' <<< "$CMD" \
     && grep -qE '(-X|--method)[[:space:]]+POST([[:space:]]|$)' <<< "$CMD" \
     && grep -qE '(^|[^[:alnum:]_])repos/[^[:space:]/]+/[^[:space:]/]+/(issues|pulls)/' <<< "$CMD"; then
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
# 3. fall back to the cwd's origin remote
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
REASON="DENIED: this is an irreversible write to a foreign upstream repo ($TARGET) running outside the /dhx:upstream gated pre-flight, which protects upstream credibility with a 7-stage discipline (pristine fetch, fork audit, self-shim audit, redaction sweep, search corpus, evidence inventory, atomic wire-up). A bare gh call skips all of it, and the write cannot be taken back. Take one of these paths: (1) new issue -> '/dhx:upstream <report-path>'; (2) reply on an existing issue -> '/dhx:upstream reply <issue-url-or-number>'; (3) deliberate one-off, audited + 60s window -> 'bash \"\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/dhx-tools/dhx-upstream-bypass.sh\" --reason \"<why the gated path does not fit>\"' then re-run this command. Own-repo writes (owner in the hook's OWN_OWNERS list) are never gated; if this target IS yours, the owner did not resolve — pass '--repo <owner>/<name>' explicitly."
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
