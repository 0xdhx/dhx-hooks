#!/usr/bin/env bash
# dhx-subagent-stop-sync-probe-marker.sh — SubagentStop hook
# Patterns: HP-009, HP-021
# File-gated live-capture marker for sync+bg SubagentStop reliability.
# Production no-op when ${XDG_RUNTIME_DIR:-/tmp}/dhx-subagent-stop-sync-probe/
# is absent. Arming-mode captures full SubagentStop stdin payload + metadata
# sidecar to capture-${ARM}-${RUN_ID}.json for cross-version watchdog use.
#
# DOES NOT emit hookSpecificOutput envelope (writes file only) — see
# docs/decisions.md 2026-05-08 SubagentStop output-channel correction row (171).
# Exits 0 unconditionally (advisory hook per HP-009).
#
# Operator runbook (live-capture arming):
#   1. install -d -m 700 ${XDG_RUNTIME_DIR:-/tmp}/dhx-subagent-stop-sync-probe   # D-14
#   2. echo "sync $(uuidgen)" > ${XDG_RUNTIME_DIR:-/tmp}/dhx-subagent-stop-sync-probe/flag
#      (or "bg <uuid>" for the bg arm)
#   3. In a fresh CC session, dispatch the matching agent shape
#   4. Run tests/probes/probe-subagent-stop-sync.sh; observe capture
#   5. rm -rf ${XDG_RUNTIME_DIR:-/tmp}/dhx-subagent-stop-sync-probe (disarm)

# WR-04: symmetric `set -uo pipefail` discipline with the probe (D-25 brief).
# Catches unset-var typos and pipefail leakage in the jq pipelines. We do NOT
# add `set -e` — the marker is advisory (HP-009) and must exit 0 unconditionally;
# `set -e` would let intermediate non-fatal command failures propagate and
# drop the silent-no-op contract. New failure paths added below are wrapped
# in explicit `|| exit 0` where pipefail could otherwise propagate non-zero.
set -uo pipefail

# IN-01: hoist the production no-op check BEFORE stdin read. Production
# state is "probe dir absent" — the no-op path runs on every SubagentStop.
# Reading + jq-validating stdin in production is wasted work per CLAUDE.md
# "Keep hooks fast". The trade-off is losing D-17 jq-stdin validation in the
# production path, but that's semantically correct: D-17 distinguishes
# "fired but malformed" from "did not fire" — and production no-op IS the
# "did not fire" case (probe is not armed, no capture is expected, no
# distinction to draw). D-17 stdin validation still gates the arming-mode
# capture path below, where the distinction matters.
PROBE_DIR="${XDG_RUNTIME_DIR:-/tmp}/dhx-subagent-stop-sync-probe"
[[ ! -d "$PROBE_DIR" ]] && exit 0

INPUT=$(cat)

if ! command -v jq >/dev/null 2>&1; then exit 0; fi

# D-17: defensive stdin validation BEFORE envelope wrap. Distinguishes
# "marker fired but stdin malformed" from "marker did not fire" (latter shows
# up as missing capture file at probe wait-loop classification step).
if ! echo "$INPUT" | jq -e . >/dev/null 2>&1; then
  echo "WARN: marker received non-JSON stdin; exiting silently" >&2
  exit 0
fi

# DHX_PROBE_FORCE_RED=broken-marker file-sentinel (D-05 (b)): file-based
# sentinel works across CC's hook subprocess boundary (env vars do not reliably
# propagate per HP-011). Probe touches $PROBE_DIR/force-red-broken-marker
# before arming; marker checks for it and exits early without writing capture.
[[ -f "$PROBE_DIR/force-red-broken-marker" ]] && exit 0

# No agent_type filter (D-04 (c)) — RUN_ID propagation is the discriminator.

FLAG_FILE="$PROBE_DIR/flag"
[[ ! -s "$FLAG_FILE" ]] && exit 0

# Flag content: "$ARM $RUN_ID" (D-03)
read -r ARM RUN_ID < "$FLAG_FILE"
[[ -z "$ARM" || -z "$RUN_ID" ]] && exit 0
case "$ARM" in
  sync|bg) ;;
  *) exit 0 ;;
esac

# D-13 symmetry (WR-01): mirror probe-side RUN_ID validation in the marker so
# T-09-01 path-escape mitigation isn't probe-side-only. Marker fires on every
# armed SubagentStop independently of the probe; without this check, an
# operator-typo flag like `echo "sync ../foo" > flag` would land the capture
# file outside the per-process scratch dir before the probe could refuse it.
# Allowed character class matches uuidgen output and basic identifier shapes.
if [[ ! "$RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "WARN: marker received malformed RUN_ID; exiting silently" >&2
  exit 0
fi

CAPTURE_FILE="$PROBE_DIR/capture-${ARM}-${RUN_ID}.json"

# Idempotency: don't overwrite existing capture (RUN_ID is one-shot per arm)
[[ -s "$CAPTURE_FILE" ]] && exit 0

# Metadata sidecar (D-04 (b))
CAPTURED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MARKER_VERSION=1
# D-16: wrap claude --version in 1s timeout with "unknown" fallback so marker
# never blocks SubagentStop on slow/unavailable claude binary.
CC_VERSION=$(timeout 1s claude --version 2>/dev/null | awk '{print $1}' || echo "unknown")
[[ -n "$CC_VERSION" ]] || CC_VERSION="unknown"

# D-12: atomic capture write — write to mktemp temp path, then mv to final.
# Prevents probe wait-loop (`[[ -s "$CAPTURE_FILE" ]]`) from observing a
# partially-written file (which would misclassify as
# "captured-payload-not-json" via jq -e at probe classification step).
CAPTURE_TMP="$(mktemp "${CAPTURE_FILE}.tmp.XXXXXX")"

# Wrap full stdin payload + metadata in single envelope (D-04 (b))
# Use --argjson for marker_version (numeric); --arg for strings
# WR-02: gate the atomic mv on jq's exit status. The mv is filesystem-atomic
# but content-atomicity (D-12's stated intent) requires jq to have succeeded.
# If jq fails mid-stream (signal, OOM, etc.) the partial bytes already in
# $CAPTURE_TMP would be promoted to the canonical name on an unconditional
# mv, defeating D-12 — the probe wait-loop would then observe a non-empty
# but malformed file and classify as ambiguous_malformed_capture (exit 2).
# D-17 stdin-validate guards against bad input but not jq runtime failure.
if echo "$INPUT" | jq \
  --arg captured_at "$CAPTURED_AT" \
  --argjson marker_version "$MARKER_VERSION" \
  --arg run_id "$RUN_ID" \
  --arg arm "$ARM" \
  --arg cc_version "$CC_VERSION" \
  '{payload: ., metadata: {captured_at: $captured_at, marker_version: $marker_version, run_id: $run_id, arm: $arm, cc_version: $cc_version}}' \
  > "$CAPTURE_TMP" 2>/dev/null
then
  mv "$CAPTURE_TMP" "$CAPTURE_FILE"
else
  rm -f "$CAPTURE_TMP"
fi

exit 0
