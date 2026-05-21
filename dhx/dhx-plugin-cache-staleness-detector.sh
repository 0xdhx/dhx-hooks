#!/usr/bin/env bash
# Patterns: HP-017, HP-025, HP-020
# dhx-plugin-cache-staleness-detector.sh — SessionStart cache-staleness detector (Phase 10.1)
#
# Scope:
#   Compare mtime of $CACHE_ROOT/dhx/<version>/hooks/hooks.json candidates to
#   the live $LIVE_MANIFEST mtime via `stat -c %Y`. Emit structured stderr
#   advisory per stale candidate. Read-only stat boundary — never opens cache
#   content (Hn() resolver scope per CONTEXT.md D-01 trust boundary).
#
# Registration (per D-17 cross-AI review — locked 2026-05-13):
#   DISPATCHER-ONLY via session-start.sh; NOT a separate plugin-manifest entry.
#   Research finding (claude-code-guide agent a7b1eaf927f2e02ad): CC's
#   in-matcher hooks array execution order is UNDOCUMENTED across all event
#   classes; dispatcher chain enforces order via shell sequential execution.
#
# Out of scope (handled elsewhere):
#   - km registry corruption → Phase 10's dhx-plugin-registry-heal.sh
#   - silent cache content rewriting → CC's Hn() resolver (NOT this hook)
#   - event-class membership diff → out of scope per 10.1-SPEC.md § Boundaries
#   - mid-session detection → deferred to statusline-tier follow-up brief (D-15)
#
# Silent on happy path. No stdin parsing (filesystem state, not session context).
# PREFIX_MODE and CC_VERSION baked at install time via Plan 2 sed-rewrite (D-02/D-21 `|` delimiter).
set -uo pipefail

LIVE_MANIFEST="${DHX_CACHE_STALENESS_LIVE_MANIFEST:-$HOME/repos/hooks/dhx-plugin/plugins/dhx/hooks/hooks.json}"
CACHE_ROOT="${DHX_CACHE_STALENESS_CACHE_ROOT:-$HOME/.claude/plugins/cache/dhx-local}"

# D-13 / Z3 cache-dir-missing branch: fresh-install state — no glob expansion,
# no candidates, no stale comparisons. Silent exit 0.
if [[ ! -d "$CACHE_ROOT/dhx" ]]; then
  exit 0
fi

# Live manifest must exist to compare against; if missing, silent exit (nothing
# to compare). Same posture as heal-hook's settings-missing branch.
live_mtime=$(stat -c %Y "$LIVE_MANIFEST" 2>/dev/null) || exit 0
[[ -n "$live_mtime" ]] || exit 0

# Resolved at install time via sed (D-02 with D-21 `|` delimiter):
#   WARN  → REJECT | WARN | WARN_INCONCLUSIVE
#   2.1.146 (Claude Code)   → literal CC version captured from 10.1-D-01-RESULT.md
emit_advisory() {
  local cache_path=$1
  local cache_mtime=$2
  local live_mtime=$3
  case "WARN" in
    REJECT)
      echo "dhx-plugin-cache-staleness: REJECT: $cache_path mtime=$cache_mtime older than live mtime=$live_mtime" >&2
      ;;
    WARN)
      echo "dhx-plugin-cache-staleness: WARN: $cache_path mtime=$cache_mtime older than live mtime=$live_mtime (informational on CC 2.1.146 (Claude Code) per empirical probe; run \`claude plugin install\` to refresh)" >&2
      ;;
    WARN_INCONCLUSIVE)
      echo "dhx-plugin-cache-staleness: WARN: $cache_path mtime=$cache_mtime older than live mtime=$live_mtime (probe inconclusive; safe default)" >&2
      ;;
  esac
}

# D-24 shopt save/restore around the smallest scope that needs nullglob.
# Defends error paths that bypass an explicit `shopt -u nullglob` (Codex C-09).
_saved=$(shopt -p nullglob || true)
shopt -s nullglob
# D-08 sort -V iteration: 0.1.10 sorts AFTER 0.1.9 (semantic, not lexicographic).
cache_candidates=$(printf '%s\n' "$CACHE_ROOT"/dhx/*/hooks/hooks.json | sort -V)
eval "$_saved"
unset _saved

stale=0
while IFS= read -r cache_manifest; do
  [[ -n "$cache_manifest" && -f "$cache_manifest" ]] || continue
  cache_mtime=$(stat -c %Y "$cache_manifest" 2>/dev/null) || continue
  if (( cache_mtime < live_mtime )); then
    emit_advisory "$cache_manifest" "$cache_mtime" "$live_mtime"
    stale=1
  fi
done <<< "$cache_candidates"

(( stale )) && exit 1
exit 0
