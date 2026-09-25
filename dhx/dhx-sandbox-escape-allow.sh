#!/usr/bin/env bash
# dhx-sandbox-escape-allow.sh — PreToolUse:Bash hook
# Patterns: HP-041, HP-050
# Auto-approves the sandbox-escape retry (tool_input.dangerouslyDisableSandbox == true)
# ONLY for anchored trusted command shapes below. Everything else emits no decision and
# falls through to the normal permission prompt. NEVER default-allow (fail-open footgun:
# anthropics/claude-code#28812).
#
# Replaces the blanket allow rule `Bash(dangerouslyDisableSandbox:true)` (2026-07-13):
# the blanket form silently unsandboxed ANY command — prompt-injection/supply-chain
# exposure on a rig that scrapes untrusted HTML. Shapes here are the tight variant.
#
# Shape additions route through /dhx:hooks modify (this is a security allowlist — gate
# logic, full engage protocol). Detection/recommendation of new shapes belongs to the
# /dhx:permissions session audit (lane pending: skills-repo docs/prompts/ handoff).
# Design notes + citations:
#   the cross-repo knowledge base
set -euo pipefail

INPUT=$(cat)

# Only act on escape retries; plain sandboxed calls pass through untouched.
DDS=$(printf '%s' "$INPUT" | jq -r '.tool_input.dangerouslyDisableSandbox // false')
[ "$DDS" = "true" ] || exit 0

CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
[ -n "$CMD" ] || exit 0

# Reject multi-line commands outright: shapes are line-anchored EREs and grep matches
# per LINE, so a payload could smuggle past on line 1 with the trusted shape on line 2.
case "$CMD" in *$'\n'*) exit 0 ;; esac

# Metacharacter guard: chaining, substitution, pipes, redirection, quotes can smuggle a
# second command inside an approved prefix — always fall through to the human prompt.
# Consequence: shapes can never contain these; compound commands stay prompted by design.
# Here-strings per HP-028 (no printf|grep -q SIGPIPE+pipefail shape).
if grep -qE '\$\(|`|;|&&|\|\||[|&<>"'"'"']' <<< "$CMD"; then
  exit 0
fi

# --- Trusted shapes (anchored ERE; one per line; additions via /dhx:hooks modify) ---
SHAPES=(
  '^ssh n95 [A-Za-z0-9 _./=:@,+-]+$'                    # 2026-07-13 remote scrape ops on own tailnet host
  '^git push (origin|n95)( [A-Za-z0-9_./:+-]+)*$'       # 2026-07-13 push to known remotes (deny rules still veto --force)
)

for re in "${SHAPES[@]}"; do
  if grep -qE "$re" <<< "$CMD"; then
    jq -n '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",permissionDecisionReason:"trusted sandbox-escape shape"}}'
    exit 0
  fi
done

exit 0  # no decision -> normal permission flow
