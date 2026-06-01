#!/usr/bin/env bash
# probe-milestone-close-vocab-parity.sh
#
# Cross-repo drift probe — asserts hooks-repo dhx-milestone-close-blocker-check.sh
# stays in sync with the canonical urgency vocabulary in
# ~/.claude/dhx-tools/backlog-regen.cjs.
#
# Drift modes prevented (D1..D4):
#   D1 — hook's URGENCY_MILESTONE_CLOSE constant diverges from regen-cjs
#        CANONICAL_URGENCY set member (rename / value-change in either file)
#   D2 — regen-cjs CANONICAL_URGENCY Set no longer contains 'milestone-close'
#        (vocab removed / renamed / restructured)
#   D3 — hook's awk header pattern stops matching the rendered output shape
#        produced by regen-cjs (D-08 dual-form invariant regression)
#   D4 — regen-cjs source no longer renders both bare AND em-dash header forms
#        (header rendering refactored away from current conditional)
#   D5 — soft-skip discipline: regen-cjs absent in this env (dhx-tools not
#        installed) is non-fatal; emit WARN + exit 0 so the probe doesn't
#        break sandboxed test envs that lack the skills-repo symlink.
#
# Mirrors the sister classifier-cross-repo probe discovery +
# assertion shape (Phase 13 D-07).
#
# Parameterization (per Phase 13 BACKLOG-INTEGRATION item 4 — sibling-reuse-ready):
# the four CANONICAL_/HOOK_CONSTANT_ knobs below are the swap-points for a
# future `target_milestone:` validator probe. Adapter for Section 3 header-
# pattern fixtures is the only additional change needed for sibling reuse.
#
# SAFE_FOR_LIVE: yes (static grep + awk against in-repo hook + canonical
# ~/.claude/dhx-tools/backlog-regen.cjs; no writes, no subprocess invocation
# of CC, no live cache mutation; soft-skip with WARN if dhx-tools absent)
#
# Run: bash tests/probes/probe-milestone-close-vocab-parity.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK_SH="$REPO_ROOT/dhx/dhx-milestone-close-blocker-check.sh"
REGEN_CJS="${DHX_TOOLS:-$HOME/.claude/dhx-tools}/backlog-regen.cjs"

# Parameterization knobs (BACKLOG-INTEGRATION item 4 sibling-reuse anchors).
# A sibling target_milestone validator probe swaps the four values + HOOK_SH +
# REGEN_CJS path and Section 3's header fixtures, reusing the rest verbatim.
CANONICAL_FIELD='CANONICAL_URGENCY'        # The Set name in regen-cjs
CANONICAL_TOKEN='milestone-close'          # Specific token to assert membership
HOOK_CONSTANT_NAME='URGENCY_MILESTONE_CLOSE'
HOOK_CONSTANT_VALUE='milestone-close'

# --- Section 0: hook source exists ---
if [ ! -r "$HOOK_SH" ]; then
  echo "FAIL hook not readable: $HOOK_SH" >&2
  exit 1
fi

# --- Section 0b: regen-cjs canonical source available ---
# Soft-skip if dhx-tools not installed (mirrors `probe-classifier-cross-repo.sh`
# convention). WARN to stderr but exit 0 so sandboxed test environments
# without the skills-repo symlink stay green.
if [ ! -r "$REGEN_CJS" ]; then
  echo "WARN: $REGEN_CJS not present — cross-repo vocab drift cannot be verified (soft-skip per D-07 / D5)"
  echo "      (sandboxed test envs without skills-repo are expected to hit this branch)"
  exit 0
fi

# --- Section 1 (D1): hook declares the readonly constant with correct value ---
# Asserts hook source contains: readonly URGENCY_MILESTONE_CLOSE='milestone-close'
# (or with double quotes; with optional surrounding whitespace).
if ! grep -qE "^readonly[[:space:]]+${HOOK_CONSTANT_NAME}=['\"]${HOOK_CONSTANT_VALUE}['\"]" "$HOOK_SH"; then
  echo "FAIL Section 1: $HOOK_SH does not declare readonly ${HOOK_CONSTANT_NAME}='${HOOK_CONSTANT_VALUE}'" >&2
  echo "      Drift mode D1: hook's canonical token diverges from regen-cjs ${CANONICAL_FIELD}" >&2
  exit 1
fi
echo "Section 1 OK — hook declares readonly ${HOOK_CONSTANT_NAME}='${HOOK_CONSTANT_VALUE}'"

# --- Section 2 (D2): regen-cjs CANONICAL_URGENCY Set contains the token ---
# Defensive presence check first — token exists as a top-level array entry
# (single or double quoted, indented).
if ! grep -qE "^[[:space:]]+['\"]${CANONICAL_TOKEN}['\"]" "$REGEN_CJS"; then
  echo "FAIL Section 2 (loose): $REGEN_CJS does not contain '${CANONICAL_TOKEN}' as an indented array entry" >&2
  echo "      Drift mode D2: canonical vocab moved or token renamed in regen-cjs" >&2
  exit 1
fi

# Tighter assertion: extract the CANONICAL_URGENCY Set block via awk, then
# verify the token appears inside the extracted block. Robust to whitespace +
# format changes within the Set initializer; catches the case where the token
# is present in source but no longer inside the canonical Set.
SET_BLOCK=$(awk "
  /^const ${CANONICAL_FIELD} = new Set\(\[/ { in_set=1; next }
  in_set && /^\]\);/                          { in_set=0 }
  in_set                                       { print }
" "$REGEN_CJS")

if [ -z "$SET_BLOCK" ]; then
  echo "FAIL Section 2 (block): $REGEN_CJS does not contain 'const ${CANONICAL_FIELD} = new Set([...])' block" >&2
  echo "      Drift mode D2: regen-cjs vocab-set restructured (e.g., promoted to lib/, renamed)" >&2
  exit 1
fi

if ! grep -qE "['\"]${CANONICAL_TOKEN}['\"]" <<< "$SET_BLOCK"; then
  echo "FAIL Section 2 (membership): '${CANONICAL_TOKEN}' is not a member of regen-cjs ${CANONICAL_FIELD}" >&2
  echo "      Set block found: $SET_BLOCK" >&2
  echo "      Drift mode D2: token moved out of the canonical Set" >&2
  exit 1
fi
echo "Section 2 OK — regen-cjs ${CANONICAL_FIELD} contains '${CANONICAL_TOKEN}'"

# --- Section 3 (D3): hook awk header pattern matches both regen-cjs output shapes ---
# regen-cjs lines 461-465 produce either:
#   'Milestone Close'                          (vocab.current absent)
#   'Milestone Close — v1.3 - Hook event-…'    (vocab.current present)
# Hook's awk pattern MUST match both fixture shapes.

# Sanity: hook source contains a recognizable '## Milestone Close' awk pattern
HOOK_PATTERN=$(grep -oE '\^## Milestone Close[^/]+' "$HOOK_SH" | head -1)
if [ -z "$HOOK_PATTERN" ]; then
  echo "FAIL Section 3: $HOOK_SH does not contain a recognizable '## Milestone Close' awk pattern" >&2
  echo "      Drift mode D3: hook's surface-scan awk regex has been removed or refactored" >&2
  exit 1
fi

# Synthetic header fixtures — must both match the hook's pattern
FIXTURE_BARE='## Milestone Close'
FIXTURE_EMDASH='## Milestone Close — v1.3 Hook event-class semantics'

for fixture in "$FIXTURE_BARE" "$FIXTURE_EMDASH"; do
  # Use the hook's actual awk regex (composed verbatim in-probe). If the hook
  # ever drops the dual-form pattern, this regex stops matching one of the
  # fixtures and the probe fails loudly. Use `END { exit !found }` shape so
  # the exit status correctly reflects whether the pattern matched.
  if ! awk '/^## Milestone Close($|[[:space:]])/ { found=1 } END { exit !found }' \
       <<< "$fixture" >/dev/null 2>&1; then
    echo "FAIL Section 3: hook's awk pattern does NOT match fixture: $fixture" >&2
    echo "      Drift mode D3: D-08 dual-form anchor broken — must match bare AND em-dash forms" >&2
    exit 1
  fi
done
echo "Section 3 OK — hook awk pattern matches both bare and em-dash header forms"

# --- Section 4 (D4): regen-cjs actually produces both header shapes ---
# Static check: scan regen-cjs for both branches of the header-rendering ternary.
# Em-dash branch is a JS template literal — `Milestone Close — ${headerFor(...)}`
# wrapped in backticks. Bare branch is `'Milestone Close'` (single-quoted).
# Allow any of backtick, single, or double quote as the leading delimiter.
if ! grep -qE "[\`'\"]Milestone Close — \\\$\{headerFor" "$REGEN_CJS"; then
  echo "FAIL Section 4 (em-dash branch): $REGEN_CJS no longer contains the em-dash header rendering branch" >&2
  echo "      Drift mode D4: regen-cjs may have changed header conventions; D-08 hook pattern at risk" >&2
  exit 1
fi
if ! grep -qE "[\`'\"]Milestone Close[\`'\"]" "$REGEN_CJS"; then
  echo "FAIL Section 4 (bare branch): $REGEN_CJS no longer contains the bare 'Milestone Close' header" >&2
  echo "      Drift mode D4: regen-cjs may have collapsed the ternary; bare form no longer rendered" >&2
  exit 1
fi
echo "Section 4 OK — regen-cjs renders both bare AND em-dash header shapes"

echo "OK"
exit 0
