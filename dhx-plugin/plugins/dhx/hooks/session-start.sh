#!/usr/bin/env bash
# dhx-plugin session-start dispatcher — invoked by plugin hooks.json.
# Logs probe + dispatches to the canonical dhx scripts in ~/.claude/hooks/.
# Receives the same stdin JSON CC hands the hook (session_id, source, etc.).
# Silent on happy path for both children; logs probe on every fire.

set -uo pipefail

INPUT=$(cat)
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
SID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null || echo unknown)
SRC=$(echo "$INPUT" | jq -r '.source // "unknown"' 2>/dev/null || echo unknown)
echo "[$TS] dhx-plugin-dispatch session=$SID source=$SRC" >> /tmp/dhx-plugin-probe.log

# Dispatch to canonical scripts. Hand each its own stdin copy.
# Run each even if one fails — they are independent.
printf '%s' "$INPUT" | bash /home/dhx/.claude/hooks/dhx-health-check.sh || true
printf '%s' "$INPUT" | bash /home/dhx/.claude/hooks/dhx-dirty-tree.sh || true
# Phase 16 (REQ-DRIFT-ACTION-01/02): actionable drift surface; reads ~/.cache/dhx/gsd-drift-first-seen.json
printf '%s' "$INPUT" | bash /home/dhx/.claude/hooks/dhx-gsd-drift-surface.sh || true
# Heal plugin registry drift (HP-025 companion) — runs BEFORE stale-worktree-sweep
# so the heal establishes a valid baseline before downstream checks touch state.
# No stdin needed; heal is filesystem-only (reads cache, writes installed_plugins.json).
bash /home/dhx/.claude/hooks/dhx-plugin-registry-heal.sh < /dev/null || true
# (dhx-plugin-cache-staleness-detector.sh RETIRED from dispatch 2026-06-11. The
# cache it watched is metadata-only — HP-020 confirms CC executes the live source
# manifest AND ${CLAUDE_PLUGIN_ROOT} resolves to the live source dir, so a stale
# cache can never mean "undeployed". The per-session WARN was noise about a
# non-issue (and recurred on every hooks.json mtime bump). Script + probe kept as
# the platform-behavior guard. See docs/decisions.md 2026-06-11 retirement row.)
printf '%s' "$INPUT" | bash /home/dhx/.claude/hooks/dhx-stale-worktree-sweep.sh || true
# Watch-health computer (cross-repo D-08/D-10/D-22a): recompute the precomputed
# health verdict cache BEFORE the digest banner reads it, so the banner consumes a
# fresh cache in the same session. The explicit `[ -e … ]` existence test guarantees
# a graceful no-op when the cross-repo installer hasn't provisioned the symlink yet
# (a bare `node <absent-symlink>` would exit non-zero); >/dev/null 2>&1 || true keeps
# it silent + non-blocking regardless. Filesystem/network-only; no stdin needed.
[ -e ~/.claude/dhx-tools/dhx-watch-health.cjs ] && node ~/.claude/dhx-tools/dhx-watch-health.cjs >/dev/null 2>&1 || true
printf '%s' "$INPUT" | bash /home/dhx/.claude/hooks/dhx-watch-digest.sh || true
# Skill-description delta auditor (SPEC: cross-repo docs/prompts/2026-07-17-skill-
# description-token-contract-SPEC.md §4.5/§4.6): consumes the skills-side collector
# via the dhx-tools provisioning path. Empty stdout when clean (zero tokens); one
# compact block per new/changed budget violation; fail-open with a consecutive-
# failures counter — never blocks session start. The [ -e ] shape isn't needed here:
# the chain script itself no-ops when its worker symlink is unprovisioned.
printf '%s' "$INPUT" | bash /home/dhx/.claude/hooks/dhx-skill-desc-audit.sh || true
# NOTE: cross-repo vitals do NOT belong here. The dispatcher's children emit PLAIN
# stdout (→ model context only); the badge OSC is unrenderable from a hook. The
# vitals BANNER is a SEPARATE SessionStart hook emitting a JSON {systemMessage}
# (dhx-vitals-banner.sh, registered in hooks.json), and the BADGE is a shell precmd
# (cross-repo dotfiles/dhx-vitals-badge.sh). See docs/decisions.md 2026-06-04 +
# cross-repo docs/research/2026-06-04-hook-cannot-emit-osc-badge.md.
# RAT-06 (STATUSLINE-RAT-06): CC-version-drift check. Network-only (npm view via
# detached worker); no stdin needed. Mirrors registry-heal / staleness-detector dispatch.
node /home/dhx/.claude/hooks/cc-check-update.js < /dev/null || true
# Fleet CC version-LOCK guard (defense-in-depth for the 2026-05-31 unrequested
# `claude update` 2.1.153->2.1.159 incident). Sibling to cc-check-update.js above:
# that hook WARNS on drift from npm-latest; this one ENFORCES the pin by repointing
# ~/.local/bin/claude back to ~/.ccs/shared/cc-pinned-version on drift (effective
# NEXT launch — can't swap the already-running process). Cross-repo-owned
# (scripts/fleet/cc-version-guard.sh), provisioned into ~/.claude/dhx-tools/ by
# cross-repo's install-dhx-tools.sh — hence the [ -e ] existence guard: a graceful
# no-op when cross-repo hasn't provisioned the symlink yet, identical shape to
# dhx-watch-health.cjs above. Filesystem-only (< /dev/null, no stdin). Fail-open
# (the guard's own `set +e` + trailing || true). stderr advisory stays VISIBLE on
# drift; SILENT + zero-stdout on the on-pin happy path (no context cost). Placed
# after the critical health/heal/worktree hooks — belt-and-suspenders, not
# critical-path. See docs/decisions.md 2026-06-02 cc-version-guard wiring row.
[ -e ~/.claude/dhx-tools/cc-version-guard.sh ] && bash ~/.claude/dhx-tools/cc-version-guard.sh < /dev/null || true
# Phase 14 (DETECT-01): warn when cross-repo PRIMARY is off main.
printf '%s' "$INPUT" | bash /home/dhx/.claude/hooks/dhx-off-main-detector.sh || true

exit 0
