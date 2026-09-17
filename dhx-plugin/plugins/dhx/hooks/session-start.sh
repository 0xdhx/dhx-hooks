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

# --- /dhx:schedule context child: RUNS HERE, EMITS BELOW (2026-09-14) -------------------
# The child runs IMMEDIATELY after the reference record and BEFORE every sibling, but its
# stdout is captured and printed later, at the position the D-11 tier ordering gives it.
# Why run-early: the reference record above is deliberately the first thing this dispatcher
# does, so a crash anywhere later still leaves "I fired" evidence. The health verb pairs that
# record against the one the renderer writes; while this child has not run, the session looks
# byte-for-byte like a dead leg. That window used to be every sibling between here and the
# emit line — 5-30 s healthy, 200 s degraded, and ONE sibling (dhx-watch-digest.sh) was ~10 s
# of it — and CC terminates a still-running SessionStart hook when the session exits, so a
# session quitting inside the window left reference-without-schedule and scored DEAD on a leg
# that never got its turn (8/8 all-time unpaired occurrences ended 5-32 s after the fire;
# 0/568 paired ones ever ended before their record). The child itself is ~0.06 s, so the
# window is now its own runtime. Never move the reference record DOWN to meet it: that turns
# every mid-dispatch exit into a zero-record miss the health verb cannot see.
# Why capture rather than print here: CC discards a cancelled hook's output wholesale, so
# buffering costs nothing on the delivery axis, keeps the context block's line order exactly
# as before, and hands the child a pipe to THIS process instead of CC's — a closed CC pipe
# can no longer SIGPIPE the child mid-record. Only stdout is captured; stderr passes through.
# BOTH correlation values are forwarded, for one reason: this leg's two sides are a parent and
# its child in ONE PROCESS, not two independently registered hooks, so the child never has to
# re-derive what the parent already computed and validated. `_SCH_EV_KEY` is the event digest
# (2026-08-22). `_SCH_HB_KEY` is the SESSION key, added 2026-09-03 — and it is the more
# load-bearing of the two: the health classifier groups the reference and schedule trees per
# session by DIRECTORY key, and that directory is this variable. A child that re-parses its own
# stdin copy and comes up empty writes under no key at all, which is exactly the shape measured
# on 2026-09-03 — the renderer emitted the user's due block and wrote nothing, so a leg that had
# DELIVERED scored DEAD. Forwarding an EMPTY value is correct and expected when `$SID` was
# absent or `unknown`: the shim refuses anything that is not a 16-hex digest, and the renderer
# then falls back to its own derivation, and failing that stays silent rather than speak
# unaccountably. See cross-repo f7aa48df5 and its design doc § 3b.
# Probe: tests/probes/probe-schedule-wiring.sh [B15] kills this dispatcher the instant the
# first sibling starts and requires both records — the pre-2026-09-14 order fails it.
_SCH_CTX_OUT=$(printf '%s' "$INPUT" | DHX_SCHEDULE_EVENT_HASH="$_SCH_EV_KEY" DHX_SCHEDULE_SESSION_KEY="$_SCH_HB_KEY" bash /home/dhx/.claude/hooks/dhx-schedule-context.sh || true)
# --- end /dhx:schedule context child ------------------------------------------------------

# --- child-failure first-sight surface (2026-09-14) -------------------------------------
# Every child below is `|| true`d so one failure cannot stop its siblings — and that, plus
# the fact that a SessionStart hook's stderr at exit 0 reaches neither the context nor a
# person who is looking (measured 2026-09-14: the session that shipped this started on the
# old heal body, its REJECT went to stderr, and the context carried only stdout; HP-038 is
# the PostToolUse twin), is how dhx-plugin-registry-heal.sh exited 1 with a REJECT on EVERY
# SessionStart from 2026-05-13 to 2026-09-14 and nobody saw it. A
# hook that fails deterministically must reach a person exactly once, not never and not
# every session. _dhx_child runs a child with its stderr captured, replays that stderr
# unchanged (children's own advisories keep whatever surface they had), and on rc != 0
# digests (label, rc, first stderr line) into a signature and claims it as a marker
# DIRECTORY `<label>.<sig>` under the same cache root the schedule beat uses — `mkdir` is
# the atomic test-and-set, so of N dispatchers racing on the same first sight exactly one
# prints (the close-gate reviewer measured the earlier read-compare-write shape printing
# twice under a synchronized race, 2026-09-14). A NEW signature prints the two lines below on
# stdout (→ model context, once); a signature already claimed stays silent — including one
# that was seen, replaced by another message, and came back; rc 0 removes every marker for
# the label so a fixed-then-broken-again child surfaces again. Fail-open on every path: no
# digest tool / unwritable cache → the child still ran and the surface just skips.
# NOT wrapped: the schedule-context child (its stdout is captured by design, above) and
# dhx-watch-health.cjs (explicitly silenced, by design). Probe: tests/probes/
# probe-session-start-child-failure-surface.sh.
_DHX_CF_DIR="${DHX_HOOKS_CACHE_DIR:-$HOME/.cache/dhx/hooks}/session-start-child-failures"
_dhx_child() {
  local label=$1; shift
  local errf rc first sig
  errf=$(mktemp "${TMPDIR:-/tmp}/dhx-child-err.XXXXXX" 2>/dev/null) || { "$@" || true; return 0; }
  "$@" 2>"$errf"
  rc=$?
  [ -s "$errf" ] && cat "$errf" >&2
  if [ "$rc" -ne 0 ]; then
    first=$(head -n1 "$errf" 2>/dev/null | cut -c1-160)
    sig=$(_dhx_digest16 "$label rc=$rc $first") || sig=""
    # mkdir of the marker is the whole test-and-set: it succeeds for exactly one caller.
    if [ -n "$sig" ] && mkdir -p "$_DHX_CF_DIR" 2>/dev/null \
       && mkdir "$_DHX_CF_DIR/$label.$sig" 2>/dev/null; then
      printf '⚠ session-start child %s failed (rc=%s)%s\n' "$label" "$rc" "${first:+: $first}"
      printf '  › repeats of this exact failure stay silent until it changes or the child succeeds\n'
    fi
  elif [ -n "$label" ]; then
    rm -rf "$_DHX_CF_DIR/$label".* 2>/dev/null
  fi
  rm -f "$errf" 2>/dev/null
  return 0
}
# --- end child-failure first-sight surface -----------------------------------------------

# Dispatch to canonical scripts. Hand each its own stdin copy.
# Run each even if one fails — they are independent (_dhx_child always returns 0).
printf '%s' "$INPUT" | _dhx_child health-check bash /home/dhx/.claude/hooks/dhx-health-check.sh
printf '%s' "$INPUT" | _dhx_child dirty-tree bash /home/dhx/.claude/hooks/dhx-dirty-tree.sh
# Function-level grep address-space cap (successor to the retired PreToolUse:Bash
# rewriter dhx-grep-vsz-cap.sh — DHX-8b, HP-057): appends a `grep` wrapper to
# $CLAUDE_ENV_FILE, which this dispatcher inherits from CC and its children see.
# < /dev/null: the hook ignores stdin (no JSON parsing). Silent on happy path.
_dhx_child grep-fn-cap bash /home/dhx/.claude/hooks/dhx-grep-fn-cap.sh < /dev/null
# Phase 16 (REQ-DRIFT-ACTION-01/02): actionable drift surface; reads ~/.cache/dhx/gsd-drift-first-seen.json
printf '%s' "$INPUT" | _dhx_child gsd-drift-surface bash /home/dhx/.claude/hooks/dhx-gsd-drift-surface.sh
# ROADMAP Progress-table Status vocabulary check (2026-08-30). Per-repo, one read
# of one file; silent unless this repo's ROADMAP carries a Status cell outside the
# set both readers recognize. Sits beside the drift surface above because both are
# GSD-planning-artifact advisories. Skips linked worktrees (duplicate copies that
# converge on merge) and non-data rows (milestone-RANGE summaries neither parser
# reads). Fleet sweep is a CLI, deliberately not this hook:
#   node ~/repos/hooks/scripts/lib/roadmap-status-vocab.js --fleet
# Suppression DHX_SKIP_ROADMAP_VOCAB=1. Fail-open on every path.
printf '%s' "$INPUT" | _dhx_child roadmap-status-vocab node /home/dhx/.claude/hooks/dhx-roadmap-status-vocab.js
# Heal plugin registry drift (HP-025 companion) — runs BEFORE stale-worktree-sweep
# so the heal establishes a valid baseline before downstream checks touch state.
# No stdin needed; heal is filesystem-only (reads settings, writes known_marketplaces.json;
# the installed_plugins.json path was retired Phase 6). Healthy-first since 2026-09-14.
# Since 2026-09-15 the launch wrappers run the same heal BEFORE Claude Code starts
# (dhx/dhx-prelaunch.sh) — the only caller that helps a launch whose registry keeps this plugin
# from loading. This copy covers a registry corrupted mid-session: repaired on /clear.
_dhx_child registry-heal bash /home/dhx/.claude/hooks/dhx-plugin-registry-heal.sh < /dev/null
# km acceptance (2026-09-15): once per installed Claude Code version, a DETACHED sandboxed run
# proves CC still accepts what registry-heal writes (CC 2.1.272 silently rejected the heal's
# output while every jq-level check stayed green). Exits 1 only when a stored result failed,
# which _dhx_child surfaces once. docs/decisions.md 2026-09-15 pre-launch row;
# tests/probes/probe-km-acceptance-trigger.sh.
_dhx_child km-acceptance bash /home/dhx/.claude/hooks/dhx-km-acceptance.sh < /dev/null
# (dhx-plugin-cache-staleness-detector.sh RETIRED from dispatch 2026-06-11. The
# cache it watched is metadata-only — HP-020 confirms CC executes the live source
# manifest AND ${CLAUDE_PLUGIN_ROOT} resolves to the live source dir, so a stale
# cache can never mean "undeployed". The per-session WARN was noise about a
# non-issue (and recurred on every hooks.json mtime bump). Script + probe kept as
# the platform-behavior guard. See docs/decisions.md 2026-06-11 retirement row.)
printf '%s' "$INPUT" | _dhx_child stale-worktree-sweep bash /home/dhx/.claude/hooks/dhx-stale-worktree-sweep.sh
# Watch-health computer (cross-repo D-08/D-10/D-22a): recompute the precomputed
# health verdict cache BEFORE the digest banner reads it, so the banner consumes a
# fresh cache in the same session. The explicit `[ -e … ]` existence test guarantees
# a graceful no-op when the cross-repo installer hasn't provisioned the symlink yet
# (a bare `node <absent-symlink>` would exit non-zero); >/dev/null 2>&1 || true keeps
# it silent + non-blocking regardless. Filesystem/network-only; no stdin needed.
[ -e ~/.claude/dhx-tools/dhx-watch-health.cjs ] && node ~/.claude/dhx-tools/dhx-watch-health.cjs >/dev/null 2>&1 || true
printf '%s' "$INPUT" | _dhx_child watch-digest bash /home/dhx/.claude/hooks/dhx-watch-digest.sh
# Pending `/dhx:vet` closure offers: surfaces rows the vet close-offer UAQ wrote and
# never got an answer for (a residual row IS an unanswered question — both answers
# remove it). Sits here, between the watch digest and the skill-desc audit, because it
# is the same "direct ask on the user" tier per the D-11 ordering rationale in
# dhx-watch-digest.sh. Empty stdout on the clean path (the common case). The action it
# surfaces is a RE-VET, never a close command — see the INVARIANT block in the worker.
printf '%s' "$INPUT" | _dhx_child vet-closures bash /home/dhx/.claude/hooks/dhx-vet-closures.sh
# Due /dhx:schedule commitments as session context — EMITTED here, RUN above (see the
# "/dhx:schedule context child" block directly under the reference record). Plain text only —
# a JSON child would corrupt the dispatcher's concatenated stdout (see dhx/dhx-vitals-banner.sh).
# Empty on the clean path, and empty until the renderer's session-start mode lands in a later
# cross-repo plan, which is a designed graceful absence rather than a gap. Sits in the same D-11
# "direct ask on the user" tier as the vet-closure offers above. `$( )` stripped the child's
# trailing newlines; exactly one is restored.
if [ -n "$_SCH_CTX_OUT" ]; then printf '%s\n' "$_SCH_CTX_OUT"; fi
# Skill-description delta auditor (SPEC: cross-repo docs/prompts/2026-07-17-skill-
# description-token-contract-SPEC.md §4.5/§4.6): consumes the skills-side collector
# via the dhx-tools provisioning path. Empty stdout when clean (zero tokens); one
# compact block per new/changed budget violation; fail-open with a consecutive-
# failures counter — never blocks session start. The [ -e ] shape isn't needed here:
# the chain script itself no-ops when its worker symlink is unprovisioned.
printf '%s' "$INPUT" | _dhx_child skill-desc-audit bash /home/dhx/.claude/hooks/dhx-skill-desc-audit.sh
# NOTE: cross-repo vitals do NOT belong here. The dispatcher's children emit PLAIN
# stdout (→ model context only); the badge OSC is unrenderable from a hook. The
# vitals BANNER is a SEPARATE SessionStart hook emitting a JSON {systemMessage}
# (dhx-vitals-banner.sh, registered in hooks.json), and the BADGE is a shell precmd
# (cross-repo dotfiles/dhx-vitals-badge.sh). See docs/decisions.md 2026-06-04 +
# cross-repo docs/research/2026-06-04-hook-cannot-emit-osc-badge.md.
# RAT-06 (STATUSLINE-RAT-06): CC-version-drift check. Network-only (npm view via
# detached worker); no stdin needed. Mirrors registry-heal / staleness-detector dispatch.
_dhx_child cc-check-update node /home/dhx/.claude/hooks/cc-check-update.js < /dev/null
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
[ -e ~/.claude/dhx-tools/cc-version-guard.sh ] && _dhx_child cc-version-guard bash ~/.claude/dhx-tools/cc-version-guard.sh < /dev/null || true
# Fleet CC version-CHANGE observer (2026-09-17). The deliberate OPPOSITE disposition to
# the pin-LOCK guard directly above: the guard speaks only on drift-from-pin and is
# correctly SILENT on an ordinary intended bump, so a bump landed and nothing surfaced
# the backlog briefs whose trigger_when keys on a CC version change (cross-repo
# 2026-08-23-cc-version-bump-has-no-trigger-firing-path: 2.1.235 -> 2.1.241 across five
# days, six patch bumps, nothing fired — including a /dhx:vet pass auditing those exact
# triggers). This one is loud exactly once per CHANGE, naming those briefs. Cross-repo-
# owned (scripts/fleet/cc-version-observer.sh), provisioned into ~/.claude/dhx-tools/ by
# cross-repo's install-dhx-tools.sh — hence the [ -e ] guard, same shape as the sibling
# above. Filesystem-only (< /dev/null). Fail-open (the observer's own `set +e` + trailing
# || true). stdout is PRESERVED and is the deliverable — under SessionStart the notice
# lands in session context; _dhx_child captures stderr only, so wrapping costs it nothing.
# Silent on no-change and on first-run baseline init; the stamp
# (~/.local/state/dhx/cc-version-seen) is written only AFTER the notice emits, so a change
# is announced once rather than once per session. That stamp is machine-wide: the first
# lane to start after a bump consumes the notice and the others stay silent — accepted,
# see .planning/backlog/2026-09-17-cc-version-observer-notice-reaches-one-lane-only.md.
# See docs/decisions.md 2026-09-17 cc-version-observer wiring row.
[ -e ~/.claude/dhx-tools/cc-version-observer.sh ] && _dhx_child cc-version-observer bash ~/.claude/dhx-tools/cc-version-observer.sh < /dev/null || true
# CC permission circuit-breaker DRIFT MONITOR (2026-09-04). Sibling to the version guard
# above: that one asserts WHICH build runs; this one asserts that the build's bypass-immune
# registry and permission reducer still match config/cc-circuit-breakers.txt. It exists
# because 2.1.259 added a bypassImmune circuit that nothing local could see until a prompt
# storm hit, and 2.1.260 removed it again — a set-drift diff names such a change at the
# first session start on the new build. Runs HERE, not in CI: the hosted runner has no
# ~/.local/share/claude/versions/ and would pass vacuously. Cached per executable identity,
# so repeat starts cost one stat per build. Silent on match; stderr advisory on drift or on
# an EMPTY extraction (exit 2 — an anchor stopped matching is not a clean result). Fail-open
# via the trailing || true. See docs/decisions.md 2026-09-04 row.
[ -e /home/dhx/repos/hooks/scripts/verify-cc-circuit-breakers.sh ] && _dhx_child cc-circuit-breakers bash /home/dhx/repos/hooks/scripts/verify-cc-circuit-breakers.sh < /dev/null || true
# SSH key-coverage audit (2026-09-15). Sibling to the circuit-breaker monitor above —
# same "is the security posture still what we think it is" tier. It exists because the
# same-day narrowing replaced the `Read(~/.ssh/id_*)` deny glob with EXACT names (the
# glob swallowed `id_ed25519.pub` and CC's matcher has no carve-out), which leaves one
# residual: a key minted later is covered by no deny rule until someone adds one. This
# is that residual's detector, so the gap cannot depend on anyone remembering. Locates
# private keys by inference only (a `*.pub` whose sibling exists, an `IdentityFile`
# target) and NEVER opens one. Silent unless a key is missing a layer; fail-open, and
# exits 0 even on a finding so it never trips the child-failure surface above.
# No stdin needed (filesystem-only). See docs/decisions.md 2026-09-15 rows;
# tests/probes/probe-dhx-key-coverage-audit.sh.
_dhx_child key-coverage bash /home/dhx/.claude/hooks/dhx-key-coverage-audit.sh < /dev/null
# Phase 14 (DETECT-01): warn when cross-repo PRIMARY is off main.
printf '%s' "$INPUT" | _dhx_child off-main-detector bash /home/dhx/.claude/hooks/dhx-off-main-detector.sh

exit 0
