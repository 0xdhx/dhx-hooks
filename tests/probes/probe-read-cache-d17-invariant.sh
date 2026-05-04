#!/bin/bash
# probe-read-cache-d17-invariant.sh (SCHEMA-01; READ-FUT-01)
#
# SAFE_FOR_LIVE: yes
# RUNTIME: ~1s
#
# Scans ~/.cache/dhx/read-cache.jsonl for D-17 forbidden combo: partial:true + source:"write".
# Per dhx/dhx-read-guard.js:38-46 — writers MUST NOT emit this combo.
#   exit 0 = no violations (D-17 invariant holds; READ-FUT-01 closes as not-needed)
#   exit 1 = violations found (schema migration warranted; READ-FUT-01-IMPL scheduled v1.3)
#   exit 2 = scan error (jq invocation failed)
#
# Backs:
#   - .planning/REQUIREMENTS.md SCHEMA-01 (READ-FUT-01 probe-as-decision)
#   - dhx/dhx-read-guard.js:38-46 (D-17 PARTIAL+WRITE INVARIANT comment)
#   - .planning/phases/06-*/06-CONTEXT.md SCHEMA matrix protocol + D-23 (cross-AI review)
#
# D-23 (cross-AI review 2026-05-03): counts violations via `jq -s '[...] | length'`
# array-length, NOT a jq-pipe-into-grep-c counting pattern. The pipeline pattern
# under `set -uo pipefail` captures grep-c exit (returns 1 on zero matches) →
# false "scan error" branch on empty cache. Verified via spike. This
# implementation tests jq exit DIRECTLY.
set -uo pipefail

CACHE="$HOME/.cache/dhx/read-cache.jsonl"

if [[ ! -f "$CACHE" ]]; then
  echo "[skip] cache absent: $CACHE"
  exit 0
fi

# D-23: single jq invocation; -s slurps all lines into an array; length returns 0 cleanly on empty.
# jq exit captured DIRECTLY (no pipeline confusion).
set +e
violations=$(jq -s '[.[] | select(.partial == true and .source == "write")] | length' "$CACHE" 2>/dev/null)
jq_rc=$?
set +e

if [[ "$jq_rc" -ne 0 ]]; then
  echo "[error] jq scan failed on $CACHE (jq_rc=$jq_rc)"
  exit 2
fi

# violations is now a clean integer (0 on empty cache, count on populated cache)
total=$(wc -l < "$CACHE" 2>/dev/null || echo 0)

if [[ "$violations" -gt 0 ]]; then
  echo "FAIL: $violations D-17 invariant violations in $CACHE (out of $total entries)"
  echo "Forbidden combo: partial:true + source:\"write\". Schema migration (READ-FUT-01-IMPL) warranted."
  exit 1
fi

echo "OK: D-17 invariant holds across $total entries (no partial:true + source:\"write\" combos found)"
exit 0
