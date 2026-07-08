#!/usr/bin/env bash
# dhx-memory-scope-guard.sh — PreToolUse hook (Write matcher)
# Patterns: HP-046, HP-047
#
# Write-time front-stop for the per-project auto-memory store. When a NEW memory
# file is born under an instance's memory dir, inject the earns-its-slot / scope-
# home checklist (non-blocking additionalContext), and ESCALATE to `ask` when the
# content trips a strong cross-cutting tell — the wrong-home / "memory@3" class
# that `/dhx:doctor memory` only catches at AUDIT time. Never hard-blocks.
#
# Why: a cross-cutting CC-daemon runbook sat MIS-HOMED in a per-project store
# ~12 days until caught by hand (2026-07-08). doctor is the audit-time back-stop;
# this is the write-time front-stop (the pair mirrors the global CLAUDE.md
# "Right store, not just worth storing" clause). The scope JUDGMENT ("is this
# cross-cutting?") is NOT mechanically decidable — the hook REMINDS (always) and
# ASKS (on strong tells); it never decides, never blocks.
#
# Fires ONLY on a genuinely new memory FILE: tool=Write, path under */.ccs/*/
# memory/*.md, basename != MEMORY.md, and the target does not yet exist (the
# wrong-home moment is BIRTH). Edits to existing memories + MEMORY.md pointer
# updates are out of scope — an existing memory already cleared the bar once.
#
# Output schema (PreToolUse, CC 2.1.197 — HP-046): additionalContext-only for
# the reminder (no permission opinion), permissionDecision:ask for the escalation.

INPUT=$(cat)

command -v jq >/dev/null 2>&1 || exit 0

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')
[ "$TOOL" = "Write" ] || exit 0

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')

# Path gate: a memory FILE under an instance's (symlink) OR the resolved (shared)
# memory dir — both contain "/.ccs/" … "/memory/" and end in .md. A repo's own
# src/memory/ dir lacks the /.ccs/ component, so it does not trip.
case "$FILE_PATH" in
  */.ccs/*/memory/*.md) ;;
  *) exit 0 ;;
esac

# MEMORY.md is the index (pointer discipline), not a memory file — out of scope.
case "$(basename "$FILE_PATH")" in
  MEMORY.md) exit 0 ;;
esac

# Birth only. An overwrite/update of an existing memory already passed the bar.
[ -e "$FILE_PATH" ] && exit 0

CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // empty')

# --- Cross-cutting tells (high-precision; bias toward NOT firing `ask`) -------
TELL=""

# (a) Self-declared external home — the strongest signal (a memory that names its
#     own canonical home elsewhere is admitting it is mis-homed here).
if grep -qiE 'canonical home|durable home|belongs in|its home is|home is a' <<< "$CONTENT"; then
  TELL="self-declared external home"
fi

# (b) Cross-repo path / wikilink to the cross-repo knowledge base.
if [ -z "$TELL" ] && grep -qiE 'cross-repo|\[\[reference_cross-repo' <<< "$CONTENT"; then
  TELL="cross-repo reference"
fi

# (c) >=2 DISTINCT CC/tool-internals tokens = a cross-tool-internals fact, not a
#     project fact. (The motivating daemon-storm memory trips this hard.) The
#     >=2 floor keeps a lone common word like "daemon" from over-firing.
if [ -z "$TELL" ]; then
  cc_hits=$(grep -oiE 'CLAUDE_CONFIG_DIR|claude agents|agent-view|daemon|control\.sock|bridgeSessionId|supervisor|--keep-workers|hookSpecificOutput|PreToolUse|SessionStart|permissionDecision' <<< "$CONTENT" \
    | tr 'A-Z' 'a-z' | sort -u | wc -l)
  if [ "$cc_hits" -ge 2 ]; then
    TELL="$cc_hits distinct CC/tool-internals terms"
  fi
fi

BAR='Memory earns-its-slot bar — before this lands, confirm ALL: (1) a future session would ERR without it; (2) still TRUE later; (3) NOT cheaply recoverable from code/git/docs/CLAUDE.md; (4) RIGHT STORE — about THIS project, not a cross-cutting fact (CC/tool internals, vendor/API policy, another project'"'"'s domain) whose home is a cross-repo doc / owning skill / vendor docs; (5) prefer UPDATING an existing memory. If it anchors a gsd-core FACT, stamp verified_against: {runtime: gsd-core@<ver>} (block form). If (4) fails, write it to its canonical home instead — do NOT store it here.'

if [ -n "$TELL" ]; then
  REASON="This new memory looks CROSS-CUTTING ($TELL) — per-project memory is likely the WRONG home. A cross-cutting fact belongs in a cross-repo doc / the owning skill / vendor docs, not this per-project store (the wrong-home / memory@3 class /dhx:doctor memory flags only at audit time). Confirm it is genuinely project-specific, or cancel and write it to its canonical home. $BAR"
  jq -n --arg r "$REASON" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
else
  jq -n --arg c "$BAR" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$c}}'
fi

exit 0
