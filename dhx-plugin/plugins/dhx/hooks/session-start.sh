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
# Root honours DHX_HOOKS_CACHE_DIR (the Node reader's HOOKS_CACHE_ENV) so a probe can drive
# this into a fixture tree; the literal default is the reader's default, byte for byte.
_SCH_HB_DIR="${DHX_HOOKS_CACHE_DIR:-$HOME/.cache/dhx/hooks}/session-start"
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
# RECORD LAYOUT (schema_version 2 — cross-repo docs/research/2026-08-23-dhx-schedule-beat-record-
# layout-and-gc-design.md §1-§2): one directory per session, one IMMUTABLE file per occurrence,
#   <root>/session-start/<session16>/<event16|none>.<fired_ms>.<pid>.<nonce>.json
# Never overwritten, no `count` field — "how many" is the cardinality of the directory, and
# repeated byte-identical events (startup|resume|clear|compact) are MEANT to produce N files
# sharing one <event16>. The name is for uniqueness only; dating is the record's `fired_at`.
# Field names/types must pass the Node side's `validateRecord` exactly (the schedule-only
# `result`/`due_hash` fields are deliberately absent on a reference record).
#
# _dhx_sch_record IS the whole transaction: mkdir -p the session dir, printf to a `.tmp.$$`
# sibling, rename. It is called a second time on failure because the schedule driver's GC
# quarantines an idle session directory by RENAMING it away — a writer that had already opened
# its temp file inside then loses the rename target; re-running the three steps recreates the
# directory, and the orphaned temp dies with the quarantine. That retry is what makes the
# GC's directory removal lossless.
_dhx_sch_record() {
  mkdir -p "$_SCH_REC_DIR" 2>/dev/null || return 1
  printf '{"schema_version":2,"kind":"%s","leg":"%s","fired_at":"%s","event_hash":%s,"session_hash_stdin":"%s","session_hash_env":"%s"}\n' \
    "$_SCH_KIND" "$_SCH_LEG" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_SCH_EV_JSON" "$_SCH_HB_KEY" "$_SCH_ENV_KEY" \
    > "$_SCH_REC_F.tmp.$$" 2>/dev/null \
    && mv -f "$_SCH_REC_F.tmp.$$" "$_SCH_REC_F" 2>/dev/null && return 0
  rm -f "$_SCH_REC_F.tmp.$$" 2>/dev/null
  return 1
}
if [ -n "$_SCH_HB_KEY" ]; then
  _SCH_LEG=session-start
  # D-28: BOTH identities — the one from stdin and the one visible in this process's
  # environment — so a later plan can OBSERVE whether they agree instead of assuming it.
  _SCH_ENV_KEY=$(_dhx_digest16 "${CLAUDE_CODE_SESSION_ID:-}") || _SCH_ENV_KEY=""
  # `kind:"undigested"` (event_hash null, file part `none`) keeps the printf total. In
  # practice the session key and the event key share one digest chain, so an empty event
  # key with a non-empty session key does not occur — the arm exists so no shape is unwritable.
  if [ -n "$_SCH_EV_KEY" ]; then
    _SCH_KIND=event; _SCH_EV_JSON='"'"$_SCH_EV_KEY"'"'; _SCH_EV_NAME="$_SCH_EV_KEY"
  else
    _SCH_KIND=undigested; _SCH_EV_JSON=null; _SCH_EV_NAME=none
  fi
  # Epoch ms for the file name; BSD date prints `%3N` literally, so anything not all-digits
  # falls back to whole seconds padded with 000. Nonce $RANDOM covers pid reuse.
  _SCH_MS=$(date +%s%3N 2>/dev/null)
  case "$_SCH_MS" in ''|*[!0-9]*) _SCH_MS="$(date +%s)000" ;; esac
  _SCH_REC_DIR="$_SCH_HB_DIR/$_SCH_HB_KEY"
  _SCH_REC_F="$_SCH_REC_DIR/$_SCH_EV_NAME.$_SCH_MS.$$.$RANDOM.json"
  _dhx_sch_record || _dhx_sch_record || true
fi
# --- end /dhx:schedule beat ---------------------------------------------------------------

# Dispatch to canonical scripts. Hand each its own stdin copy.
# Run each even if one fails — they are independent.
printf '%s' "$INPUT" | bash /home/dhx/.claude/hooks/dhx-health-check.sh || true
printf '%s' "$INPUT" | bash /home/dhx/.claude/hooks/dhx-dirty-tree.sh || true
# Function-level grep address-space cap (successor to the retired PreToolUse:Bash
# rewriter dhx-grep-vsz-cap.sh — DHX-8b, HP-057): appends a `grep` wrapper to
# $CLAUDE_ENV_FILE, which this dispatcher inherits from CC and its children see.
# < /dev/null: the hook ignores stdin (no JSON parsing). Silent on happy path.
bash /home/dhx/.claude/hooks/dhx-grep-fn-cap.sh < /dev/null || true
# Phase 16 (REQ-DRIFT-ACTION-01/02): actionable drift surface; reads ~/.cache/dhx/gsd-drift-first-seen.json
printf '%s' "$INPUT" | bash /home/dhx/.claude/hooks/dhx-gsd-drift-surface.sh || true
# ROADMAP Progress-table Status vocabulary check (2026-08-30). Per-repo, one read
# of one file; silent unless this repo's ROADMAP carries a Status cell outside the
# set both readers recognize. Sits beside the drift surface above because both are
# GSD-planning-artifact advisories. Skips linked worktrees (duplicate copies that
# converge on merge) and non-data rows (milestone-RANGE summaries neither parser
# reads). Fleet sweep is a CLI, deliberately not this hook:
#   node ~/repos/hooks/scripts/lib/roadmap-status-vocab.js --fleet
# Suppression DHX_SKIP_ROADMAP_VOCAB=1. Fail-open on every path.
printf '%s' "$INPUT" | node /home/dhx/.claude/hooks/dhx-roadmap-status-vocab.js || true
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
