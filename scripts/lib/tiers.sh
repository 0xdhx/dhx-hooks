#!/usr/bin/env bash
# scripts/lib/tiers.sh — derives bash arrays from tiers.json (D-02, D-21).
# Source this file: `source scripts/lib/tiers.sh`
# Exports: CRITICAL=(...), ADVISORY=(...)
# Source of truth: scripts/lib/tiers.json (Phase 5 statusline reads via require()).

_tiers_json="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tiers.json"
if [[ ! -f "$_tiers_json" ]]; then
  echo "tiers.sh: tiers.json missing at $_tiers_json" >&2
  return 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "tiers.sh: jq not on PATH" >&2
  return 1
fi

mapfile -t CRITICAL < <(jq -r '.critical[]' "$_tiers_json")
mapfile -t ADVISORY < <(jq -r '.advisory[]' "$_tiers_json")
export CRITICAL ADVISORY
