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

# --- /dhx:schedule liveness reference beat (cross-repo phase 40, D-03/D-22/D-28) ----------
# Reuses $SID/$INPUT already in hand — no second jq call. One ~200-byte write; no lock, no
# directory scan (scans belong to the health verb alone); every failure path silent.
_SCH_HB_DIR="$HOME/.cache/dhx/hooks/session-start"
# printf '%s', never echo — echo appends a newline, the hasher hashes it, and this digest
# would then never equal the Node side's for the same session.
# Digest chain: sha256sum, then shasum -a 256 (macOS) — the dhx/poll-guard.sh SESSION_HASH
# precedent. Inlined (no sourced lib) so this file stays a single self-contained unit. Both
# the SESSION key and the EVENT key go through it; neither tool present -> empty -> the
# guarded beat block below skips, fail-open, exactly as an empty key always did.
_dhx_digest16() {
  if command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum 2>/dev/null | cut -c1-16
  elif command -v shasum >/dev/null 2>&1; then printf '%s' "$1" | shasum -a 256 2>/dev/null | cut -c1-16
  fi
}
_SCH_HB_KEY=$(_dhx_digest16 "$SID") || _SCH_HB_KEY=""
# The literal string `unknown` must never become a session key.
[ "$SID" = "unknown" ] && _SCH_HB_KEY=""
# The EVENT digest: the RAW payload this dispatcher already holds. `$(cat)` above already
# stripped trailing newlines — that is the canonicalisation, and the Node side strips
# identically. Never compare beat timestamps: hooks on one event run concurrently, so a
# healthy leg's beat can legitimately be older than this one.
#
# THIS VALUE IS FORWARDED TO THE SCHEDULE CHILD (see its dispatch line below) rather than
# recomputed there. An earlier revision of this comment claimed the two sides agree "without
# any inter-hook communication, which the execution model forbids" — that sentence was
# inherited verbatim from dhx-session-registry-prompt.sh and is FALSE here. It is true of the
# PROMPT leg, whose two sides are separately registered hooks that genuinely cannot talk. This
# leg's schedule side is this dispatcher's own CHILD, in this process (hooks.json registers
# only this dispatcher for SessionStart), so handing it the value is parent-to-child, not the
# forbidden channel. Correcting the sentence matters because the false premise is what made a
# second, independent hash in the child look necessary.
_SCH_EV_KEY=$(_dhx_digest16 "$INPUT") || _SCH_EV_KEY=""
if [ -n "$_SCH_HB_KEY" ]; then
  mkdir -p "$_SCH_HB_DIR" 2>/dev/null
  _SCH_HB_F="$_SCH_HB_DIR/$_SCH_HB_KEY.json"
  _SCH_HB_N=0
  [ -f "$_SCH_HB_F" ] && _SCH_HB_N=$(sed -n 's/.*"count"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$_SCH_HB_F" 2>/dev/null)
  case "$_SCH_HB_N" in ''|*[!0-9]*) _SCH_HB_N=0 ;; esac
  # D-28: BOTH identities — the one from stdin and the one visible in this process's
  # environment — so a later plan can OBSERVE whether they agree instead of assuming it.
  _SCH_ENV_KEY=$(_dhx_digest16 "${CLAUDE_CODE_SESSION_ID:-}") || _SCH_ENV_KEY=""
  printf '{"last_fire_at":"%s","count":%d,"event_hash":"%s","session_hash_stdin":"%s","session_hash_env":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$((_SCH_HB_N+1))" "$_SCH_EV_KEY" "$_SCH_HB_KEY" "$_SCH_ENV_KEY" \
    > "$_SCH_HB_F.tmp.$$" 2>/dev/null \
    && mv -f "$_SCH_HB_F.tmp.$$" "$_SCH_HB_F" 2>/dev/null \
    || rm -f "$_SCH_HB_F.tmp.$$" 2>/dev/null
fi
# --- end /dhx:schedule beat ---------------------------------------------------------------

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
# Pending `/dhx:vet` closure offers: surfaces rows the vet close-offer UAQ wrote and
# never got an answer for (a residual row IS an unanswered question — both answers
# remove it). Sits here, between the watch digest and the skill-desc audit, because it
# is the same "direct ask on the user" tier per the D-11 ordering rationale in
# dhx-watch-digest.sh. Empty stdout on the clean path (the common case). The action it
# surfaces is a RE-VET, never a close command — see the INVARIANT block in the worker.
printf '%s' "$INPUT" | bash /home/dhx/.claude/hooks/dhx-vet-closures.sh || true
# Due /dhx:schedule commitments as session context. Plain text only — a JSON child would
# corrupt the dispatcher's concatenated stdout (see dhx/dhx-vitals-banner.sh). Empty on the
# clean path, and empty until the renderer's session-start mode lands in a later cross-repo
# plan, which is a designed graceful absence rather than a gap. Sits in the same D-11
# "direct ask on the user" tier as the vet-closure offers above.
printf '%s' "$INPUT" | DHX_SCHEDULE_EVENT_HASH="$_SCH_EV_KEY" bash /home/dhx/.claude/hooks/dhx-schedule-context.sh || true
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
