#!/usr/bin/env bash
# probe-deferred-check-canonical-classifier.sh
#
# Regression probe for dhx/dhx-deferred-check.sh canonical-classifier sourcing.
#
# Invariant: the hook MUST source the canonical classifier from
# ~/.claude/dhx-tools/dhx-classify-deferred.sh (skills repo) and MUST NOT
# re-implement the marker filter inline. Inline duplication is the precise
# silent-divergence failure mode the skills-repo audit (260427-2d4) surfaced —
# 4 markers on the hook side vs 5 on the skill side, prefix-only on the hook
# vs prefix-or-end-of-bullet on the skill, with no static check to catch the
# drift. This probe is the static check.
#
# Sister probe: ~/repos/skills/tests/probe-classifier-cross-repo.sh runs the
# same kind of structural assertion from the skills-repo side. Either probe
# alone would catch reintroduction of inline filters; the pair makes the
# invariant visible from both repos' test suites.
#
# Backs: docs/decisions.md 2026-04-27 cross-repo classifier sync row.
# Parent report: reports/done/2026-04-27-cross-repo-classifier-sync-handoff.md
#
# Run: bash tests/probes/probe-deferred-check-canonical-classifier.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$REPO_ROOT/dhx/dhx-deferred-check.sh"
CLASSIFIER="${DHX_TOOLS:-$HOME/.claude/dhx-tools}/dhx-classify-deferred.sh"

for f in "$HOOK" "$CLASSIFIER"; do
  if [[ ! -r "$f" ]]; then
    echo "FAIL required file not readable: $f"
    exit 1
  fi
done

PASS=0
FAIL=0

check() {
  local label="$1"
  local ok="$2"
  if [[ "$ok" == "1" ]]; then
    echo "OK   $label"
    PASS=$((PASS+1))
  else
    echo "FAIL $label"
    FAIL=$((FAIL+1))
  fi
}

# --- Section 1: hook sources the canonical classifier ---

# 1. The hook contains a `.` or `source` directive pointing at dhx-classify-deferred.sh
if grep -qE '(^|[[:space:]])(\.|source)[[:space:]]+("?\$\{?DHX_TOOLS\}?|"?\$\{?HOME\}?/\.claude/dhx-tools|~/\.claude/dhx-tools|"\$DHX_CLASSIFIER")' "$HOOK" \
   && grep -q 'dhx-classify-deferred\.sh' "$HOOK"; then
  check "hook sources canonical classifier (~/.claude/dhx-tools/dhx-classify-deferred.sh)" 1
else
  check "hook does NOT source canonical classifier — drift mode reintroduced" 0
fi

# 2. The hook calls classify_deferred_lines (the function exported by the canonical script)
if grep -q 'classify_deferred_lines' "$HOOK"; then
  check "hook calls classify_deferred_lines" 1
else
  check "hook missing classify_deferred_lines call" 0
fi

# --- Section 2: hook does NOT inline the marker filter ---

# 3. No inline `grep -v '\[captured` chains. The canonical classifier handles
#    all 5 markers — any inline grep -v on a marker name is the drift shape.
inline_count=$(grep -cE "grep -v '\\\\\[(captured|existing|assessed|tracked|note)" "$HOOK" || true)
if [[ "$inline_count" == "0" ]]; then
  check "hook contains no inline marker grep filters (0 \`grep -v '\\[<marker>'\` chains)" 1
else
  check "hook contains $inline_count inline marker grep filters — should source classify_deferred_lines" 0
fi

# --- Section 3: header comment lists all 5 canonical markers ---

CANONICAL_MARKERS=$(grep '^CLASSIFY_DEFERRED_MARKERS=' "$CLASSIFIER" | sed -E 's/^[^"]+"([^"]+)"$/\1/' | tr '|' ' ')
if [[ -z "$CANONICAL_MARKERS" ]]; then
  check "could not extract CLASSIFY_DEFERRED_MARKERS from canonical script" 0
else
  all_present=1
  missing=""
  for m in $CANONICAL_MARKERS; do
    if ! grep -q "\[${m}" "$HOOK"; then
      all_present=0
      missing="$missing $m"
    fi
  done
  if [[ "$all_present" == "1" ]]; then
    check "header comment mentions all canonical markers: $CANONICAL_MARKERS" 1
  else
    check "header comment missing markers:$missing (canonical: $CANONICAL_MARKERS)" 0
  fi
fi

# --- Section 4: header comment documents the prefix-or-end-of-bullet rule ---

# The skills-repo cross-repo probe (Section 4) asserts exactly this phrasing.
# Mirroring it here makes the invariant testable from the hooks-repo side too.
if grep -qE 'end-of-bullet|prefix or end' "$HOOK"; then
  check "hook header documents prefix-or-end-of-bullet recognition rule" 1
else
  check "hook header missing prefix-or-end-of-bullet rule documentation" 0
fi

# --- Section 5: behavioral smoke — sourcing the canonical script + filtering works ---

# Source the classifier in a subshell and verify it filters a synthetic deferred
# block correctly: 5 markers (prefix + end-of-bullet) silenced, plain bullet survives.
RESULT=$(bash -c '
  . "'"$CLASSIFIER"'"
  cat <<EOF | classify_deferred_lines
- [captured] should be silenced
- [existing: foo.md] should be silenced
- [assessed: reviewed] should be silenced
- [tracked: REQ-01] should be silenced
- [note] should be silenced
- Long bullet body with end marker [note: trailing]
- Long bullet body with end marker [captured: end]
- ~~strikethrough should be silenced~~
- None
- Real unassessed bullet that should survive
EOF
')

surviving_count=$(echo "$RESULT" | sed '/^$/d' | wc -l | tr -d ' ')
if [[ "$surviving_count" == "1" ]]; then
  check "smoke test: 1 of 10 synthetic bullets survives canonical filter" 1
else
  check "smoke test: $surviving_count bullets survived (expected 1) — output: $RESULT" 0
fi

if echo "$RESULT" | grep -q "Real unassessed bullet that should survive"; then
  check "smoke test: surviving bullet is the unmarked one" 1
else
  check "smoke test: wrong bullet survived — output: $RESULT" 0
fi

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]
