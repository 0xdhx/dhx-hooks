#!/usr/bin/env bash
# Patterns: HP-017
# dhx-cache-probe-marker.sh — Phase 10.1 empirical-arm marker fixture (D-16).
#
# Probe-only fixture: NEVER registered in the live plugin manifest. Committed
# (not created on demand) so the operator can re-run the empirical-arm
# sandboxed-CC sequence to disambiguate an INCONCLUSIVE result without
# re-authoring the marker.
#
# Fires when CC's resolver reads a cache hooks.json into which the operator has
# jq-injected a benign event-class entry pointing at this script (D-03 surgical
# cache mutation). A FIRED line in the log is the primary observable signal
# (D-04); its presence/absence drives the D-05 3-state classification.
#
# Writes a single timestamped line to
# ${DHX_CACHE_PROBE_MARKER_LOG:-/tmp/dhx-cache-probe-marker.log}.
set -uo pipefail

LOG="${DHX_CACHE_PROBE_MARKER_LOG:-/tmp/dhx-cache-probe-marker.log}"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "[$TS] dhx-cache-probe-marker FIRED pid=$$ cc_pid=$PPID" >> "$LOG"
exit 0
