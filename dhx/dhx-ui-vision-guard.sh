#!/usr/bin/env bash
# dhx-ui-vision-guard.sh — PreToolUse hook (Agent matcher)
# Patterns: HP-011
# Ensures z-gsdui project skill exists when GSD UI subagents spawn.
# Creates design-vision-authority rules as a side effect so subagents
# discover them during project skill scan.
# Also injects advisory context about DESIGN-VISION.md into the parent.
#
# Fires: PreToolUse on Agent tool
# Gate: subagent_type is gsd-ui-researcher or gsd-ui-checker
# Side effect: creates .claude/skills/z-gsdui/ if DESIGN-VISION.md exists

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then exit 0; fi

AGENT_TYPE=$(echo "$INPUT" | jq -r '.tool_input.subagent_type // empty')

# Gate: only GSD UI subagents
case "$AGENT_TYPE" in
  gsd-ui-researcher|gsd-ui-checker) ;;
  *) exit 0 ;;
esac

# Find project root — walk up from cwd looking for CLAUDE.md or .git
PROJECT_ROOT=""
DIR="$(pwd)"
while [ "$DIR" != "/" ]; do
  if [ -f "$DIR/CLAUDE.md" ] || [ -d "$DIR/.git" ]; then
    PROJECT_ROOT="$DIR"
    break
  fi
  DIR="$(dirname "$DIR")"
done

[ -z "$PROJECT_ROOT" ] && exit 0

# Check if DESIGN-VISION.md exists (standard locations)
VISION_FILE=""
for candidate in "$PROJECT_ROOT/docs/design/DESIGN-VISION.md" \
                 "$PROJECT_ROOT/docs/DESIGN-VISION.md" \
                 "$PROJECT_ROOT/DESIGN-VISION.md"; do
  if [ -f "$candidate" ]; then
    VISION_FILE="$candidate"
    break
  fi
done

# No DESIGN-VISION.md — nothing to enforce
[ -z "$VISION_FILE" ] && exit 0

# Check if DESIGN-VISION.md has locked values (filled table rows, not just comments)
# A locked value is a table row with a pipe-delimited hex code
HAS_LOCKED=$(grep -cP '^\|[^|]+\|[^|]*#[0-9a-fA-F]{3,8}' "$VISION_FILE" 2>/dev/null || echo "0")
[ "$HAS_LOCKED" -eq 0 ] && exit 0

# Side effect: create z-gsdui if it doesn't exist
ZGSDUI_DIR="$PROJECT_ROOT/.claude/skills/z-gsdui"
if [ ! -f "$ZGSDUI_DIR/rules/design-vision-authority.md" ]; then
  mkdir -p "$ZGSDUI_DIR/rules"

  cat > "$ZGSDUI_DIR/SKILL.md" << 'SKILL_EOF'
---
name: z-gsdui
description: Design system authority rules for GSD UI subagents (gsd-ui-researcher, gsd-ui-checker). Not user-invoked — provides rules that subagents read during project skill discovery.
---
This skill provides design system override rules for GSD UI workflow subagents. It is not directly invoked. Subagents read `rules/*.md` during their project skill scan.
SKILL_EOF

  cat > "$ZGSDUI_DIR/rules/design-vision-authority.md" << 'RULES_EOF'
# Design Vision Authority

When `docs/design/DESIGN-VISION.md` exists with locked token values (filled table rows, not HTML comments):

## Typography Override
**Do not apply generic font-size or font-weight limits.** The project's locked type scale is canonical.
- Validate phase typography **against DESIGN-VISION.md locked values**, not against abstract thresholds
- Phase UI-SPECs should **map elements to existing locked values** and declare only genuinely new additions
- A phase that uses 7 locked sizes from DESIGN-VISION.md is compliant; 2 unlocked sizes need justification

## Color Override
If DESIGN-VISION.md declares a semantic color palette, validate phase colors against those tokens. New semantic colors require justification but are not blocked by count alone.

## General Principle
DESIGN-VISION.md represents accumulated, user-approved design decisions. Phase-level specs inherit from it — they do not re-derive or override. When a checker dimension rule conflicts with a locked DESIGN-VISION.md value, the locked value wins.
RULES_EOF
fi

# Inject advisory context for the parent orchestrator
cat << ENDJSON
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "DESIGN VISION ACTIVE: DESIGN-VISION.md has ${HAS_LOCKED} locked token value(s). The z-gsdui project skill is in place — the ${AGENT_TYPE} subagent will discover design-vision-authority rules during its project skill scan. If constructing the agent prompt, consider adding DESIGN-VISION.md to the files_to_read list so the agent can reference locked values directly."
  }
}
ENDJSON

exit 0
