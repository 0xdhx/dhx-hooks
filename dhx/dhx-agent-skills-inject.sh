#!/usr/bin/env bash
# dhx-agent-skills-inject.sh — SubagentStart hook (matcher ^gsd-)
# Patterns: HP-065
#
# Delivers a project's configured gsd `agent_skills` to EVERY gsd-* subagent, however it
# was dispatched. gsd-core appends the <agent_skills> block only from its workflow
# templates; a hand-written Agent(subagent_type="gsd-…") prompt never gets it, and the
# agent-side self-load its definitions instruct ran 0 times in 743 reviewer / executor /
# verifier runs since it shipped (measured 2026-09-25, cross-repo
# docs/research/2026-09-25-gsd-subagent-skill-delivery-reach.md).
#
# Mechanism: SubagentStart `hookSpecificOutput.additionalContext` lands in the subagent's
# context before its first prompt (HP-065). It cannot see or change the dispatch — chosen
# over a PreToolUse `updatedInput` rewrite, whose whole-object replace silently changed a
# spawn's subagent_type in a live probe. It cannot see the prompt either, so a
# workflow-spawned agent gets the bodies here AND a pointer block in its prompt; the
# closing line tells it not to Read the pointed-at paths again.
#
# Outcomes (one JSONL line each in $DHX_STATE/agent-skills-inject.jsonl):
#   injected         bodies injected
#   none             the project configures nothing for this type — silent
#   could-not-answer resolution failed / degraded / a skill unreadable — the subagent is
#                    TOLD so (never silence: "could not look" must not read as "nothing
#                    configured", the class this hook exists to carry)
#   skip             not a gsd-* type, or unparseable payload — silent, fail-open
#
# Never blocks (SubagentStart cannot), always exits 0.
# Decision: docs/decisions.md 2026-09-25 SubagentStart agent-skills injector row.

INPUT="$(cat)"
STATE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/dhx-state"
LOG="$STATE_DIR/agent-skills-inject.jsonl"
GSD_TOOLS="${DHX_AGENT_SKILLS_GSD_TOOLS:-$HOME/.claude/gsd-core/bin/gsd-tools.cjs}"

command -v jq >/dev/null 2>&1 || exit 0

AGENT_TYPE="$(printf '%s' "$INPUT" | jq -r '.agent_type // empty' 2>/dev/null)"
AGENT_ID="$(printf '%s' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null)"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$CWD" ] && [ -d "$CWD" ] || CWD="$(pwd)"

log() { # outcome detail skills
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  jq -cn --arg ts "$(date -u +%FT%TZ)" --arg t "$AGENT_TYPE" --arg id "$AGENT_ID" \
    --arg cwd "$CWD" --arg o "$1" --arg d "${2:-}" --arg s "${3:-}" \
    '{ts:$ts,agent_type:$t,agent_id:$id,cwd:$cwd,outcome:$o,detail:$d,skills:$s}' \
    >> "$LOG" 2>/dev/null || true
}

emit() { # additionalContext text
  jq -cn --arg c "$1" '{hookSpecificOutput:{hookEventName:"SubagentStart",additionalContext:$c}}'
}

cannot_answer() { # reason
  log could-not-answer "$1" "${2:-}"
  emit "[dhx agent-skills] Could not load the agent skills this project may configure for ${AGENT_TYPE}: $1
This is NOT the same as none being configured. Before starting, run \`gsd_run query agent-skills ${AGENT_TYPE}\` from ${CWD} and Read every SKILL.md it lists."
  exit 0
}

case "$AGENT_TYPE" in
  gsd-*) ;;
  *) exit 0 ;;
esac

[ -f "$GSD_TOOLS" ] || cannot_answer "gsd-tools not found at $GSD_TOOLS"

RAW="$(cd "$CWD" && timeout 8 node "$GSD_TOOLS" query agent-skills "$AGENT_TYPE" --json 2>/dev/null)"
RC=$?
[ "$RC" -eq 0 ] || cannot_answer "agent-skills query exited $RC"
printf '%s' "$RAW" | jq -e 'type=="object"' >/dev/null 2>&1 || cannot_answer "agent-skills query returned no JSON object"

CONFIGURED="$(printf '%s' "$RAW" | jq -r '.configured')"
COUNT="$(printf '%s' "$RAW" | jq -r '.skills_count')"
DEGRADED="$(printf '%s' "$RAW" | jq -r '.degraded')"
NWARN="$(printf '%s' "$RAW" | jq -r '(.warnings // []) | length')"

[ "$DEGRADED" = "false" ] || cannot_answer "config resolution degraded ($(printf '%s' "$RAW" | jq -r '.reason // "no reason"'))"
case "$CONFIGURED:$COUNT" in
  false:0) log none; exit 0 ;;
  true:0)  cannot_answer "configured but no skill resolved ($(printf '%s' "$RAW" | jq -r '(.warnings // []) | join("; ")'))" ;;
  true:[1-9]*) ;;
  *) cannot_answer "unexpected query shape (configured=$CONFIGURED skills_count=$COUNT)" ;;
esac

# Relative refs are project-root-relative: the nearest ancestor holding .planning/config.json.
ROOT="$CWD"
while [ "$ROOT" != "/" ] && [ ! -f "$ROOT/.planning/config.json" ]; do ROOT="$(dirname "$ROOT")"; done
[ -f "$ROOT/.planning/config.json" ] || cannot_answer "no .planning/config.json above $CWD"

BODY=""
NAMES=""
PROBLEMS=""
while IFS= read -r line; do
  case "$line" in
    "- @"*)
      ref="${line#- @}"
      case "$ref" in /*) path="$ref" ;; *) path="$ROOT/$ref" ;; esac
      name="$(basename "$(dirname "$path")")"
      if [ -r "$path" ]; then
        # Strip a leading YAML frontmatter block; keep the body verbatim.
        text="$(awk 'NR==1 && $0=="---" {fm=1; next} fm && $0=="---" {fm=0; next} !fm' "$path")"
        BODY+=$'\n\n'"## Skill: ${name}  (${ref})"$'\n'"${text}"
        NAMES+="${NAMES:+,}$name"
      else
        PROBLEMS+="${PROBLEMS:+; }unreadable: $ref"
      fi
      ;;
    "- Load the "*)
      BODY+=$'\n\n'"${line#- }"
      NAMES+="${NAMES:+,}directive"
      ;;
  esac
done < <(printf '%s' "$RAW" | jq -r '.block // ""')

# gsd-core's skills_count counts CONFIGURED paths, not resolved ones (1.14.0: a missing skill
# reports skills_count 1 with block "" plus WARNINGs) — so the refs actually listed are the
# only trustworthy answer, and an empty list under configured=true is could-not-answer.
[ -n "$NAMES" ] || cannot_answer "configured, but no skill resolved ($(printf '%s' "$RAW" | jq -r '(.warnings // []) | join("; ")')${PROBLEMS:+; $PROBLEMS})"

NOTICE=""
OUTCOME="injected"
if [ -n "$PROBLEMS" ]; then
  # Partial: deliver what resolved, and say plainly what did not.
  OUTCOME="partial"
  NOTICE=$'\n\n'"[dhx agent-skills] Some configured skills could NOT be loaded (${PROBLEMS}). Run \`gsd_run query agent-skills ${AGENT_TYPE}\` from ${CWD} and Read the ones missing above."
fi

log "$OUTCOME" "warnings=$NWARN${PROBLEMS:+; $PROBLEMS}" "$NAMES"
emit "<agent_skills_loaded by=\"dhx SubagentStart hook\" agent=\"${AGENT_TYPE}\">
The user-configured skills for ${AGENT_TYPE} in this project are loaded below. They are ALREADY in your context: do not Read their paths again, even if an <agent_skills> block in your prompt lists them. Apply them throughout your task.${BODY}${NOTICE}
</agent_skills_loaded>"
exit 0
