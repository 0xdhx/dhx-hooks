#!/usr/bin/env bash
# probe-milestone-close-vocab-parity.sh
#
# Cross-repo drift probe — asserts hooks-repo dhx-milestone-close-blocker-check.sh
# stays in sync with the canonical urgency vocabulary and the rendered header shapes
# produced by ~/.claude/dhx-tools/backlog-regen.cjs.
#
# Drift modes prevented (D1..D5):
#   D1 — hook's URGENCY_MILESTONE_CLOSE constant diverges from the token regen
#        actually groups on (rename / value-change in either file)
#   D2 — 'milestone-close' stops being a canonical urgency value (vocab removed,
#        renamed, or restructured) — asserted through regen's own diagnostics
#   D3 — hook's awk header pattern stops matching the header regen actually renders
#        (D-08 dual-form invariant regression)
#   D4 — regen stops rendering both the bare AND em-dash header forms
#   D5 — soft-skip discipline: regen-cjs / node / git absent in this env is
#        non-fatal; emit WARN + exit 0 so sandboxed test envs stay green.
#
# SAFE_FOR_LIVE: yes (runs backlog-regen.cjs in its --emit print-only mode and the
# hook in a read-only Stop invocation, both against a git-init'd mktemp fixture; no
# writes outside the fixture, no live cache mutation; soft-skips with WARN if
# dhx-tools, node, or git is absent)
#
# Run: bash tests/probes/probe-milestone-close-vocab-parity.sh
#
# ---------------------------------------------------------------------------
# 2026-08-27 — DE-PINNED from backlog-regen.cjs's SOURCE TEXT.
#
# Sections 2 and 4 used to grep the peer generator's JavaScript:
#     grep -qE "[\`'\"]Milestone Close — \\\$\{headerFor"      # the em-dash branch
#     awk '/^const CANONICAL_URGENCY = new Set\(\[/ …'         # the vocab Set block
# Measured 2026-08-20: renaming the helper `headerFor` -> `headerLabel` — a PURE
# RENAME with zero behavioural change — reds this probe and blocks every hooks-repo
# commit. backlog-regen.cjs is symlinked into ~/repos/<skills-monorepo>/scripts/, a peer WORKING
# TREE, so nothing need be committed anywhere for that to happen. This probe was the
# clearest instance of the class; the originating brief expected it to be the hardest
# to de-pin, on the assumption no runnable seam existed.
#
# A seam does exist: `backlog-regen.cjs --emit <root>` prints the document a regen
# would write and writes NOTHING (its own header documents this as the side-effect-
# free generation mode). So the contract can be asserted against rendered OUTPUT.
#
# NARROW PROJECTION IS THE POINT, not "runtime instead of source". Running a whole
# CLI and asserting on everything it emits would re-couple just as tightly — an
# unrelated new deprecation warning on stderr would red a clean-stderr assertion
# while the milestone-close contract stood untouched. So:
#   * stderr is asserted ONLY for the presence/absence of the specific unknown-urgency
#     diagnostic, never for global cleanliness;
#   * stdout is asserted ONLY for the Milestone Close header and its row count;
#   * the hook's OWN awk pattern is extracted and applied to the header regen really
#     rendered, and the real hook is then run against that document.
#
# That last step fixes a defect this probe already had: Section 3 extracted
# HOOK_PATTERN and then ignored it, running a hardcoded awk regex against hardcoded
# fixture strings. It could not fail if the hook's pattern changed — a tautology, not
# a test. The renderer and the hook's matcher are now proven to agree end to end.
#
# WHAT WAS GIVEN UP, stated rather than glossed: the identifier `CANONICAL_URGENCY`,
# its `new Set([...])` representation, the existence of a helper named `headerFor`,
# and the template-literal implementation of the header are no longer asserted. Those
# are peer-owned implementation choices this repo does not consume. What it consumes —
# which token groups, which headers render, whether the hook matches them — is
# asserted more strictly than before.
# ---------------------------------------------------------------------------

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK_SH="$REPO_ROOT/dhx/dhx-milestone-close-blocker-check.sh"
REGEN_CJS="${DHX_TOOLS:-$HOME/.claude/dhx-tools}/backlog-regen.cjs"

CANONICAL_TOKEN='milestone-close'          # the urgency value that must group
HOOK_CONSTANT_NAME='URGENCY_MILESTONE_CLOSE'
HOOK_CONSTANT_VALUE='milestone-close'

PASS=0
FAIL=0
check() {
  if [ "$2" = "1" ]; then echo "OK   $1"; PASS=$((PASS+1))
  else echo "FAIL $1" >&2; FAIL=$((FAIL+1)); fi
}

# --- Section 0: hook source exists ---
if [ ! -r "$HOOK_SH" ]; then
  echo "FAIL hook not readable: $HOOK_SH" >&2
  exit 1
fi

# --- Section 0b: soft-skip when the runtime this probe needs is absent (D5) ---
for dep in node git jq; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    echo "WARN: $dep not available — rendered-output differential cannot run (soft-skip per D-07 / D5)"
    exit 0
  fi
done
if [ ! -r "$REGEN_CJS" ]; then
  echo "WARN: $REGEN_CJS not present — cross-repo vocab drift cannot be verified (soft-skip per D-07 / D5)"
  echo "      (sandboxed test envs without skills-repo are expected to hit this branch)"
  exit 0
fi

# --- Section 1 (D1): hook declares the readonly constant with the correct value ---
# This is an IN-REPO text pin and stays one: the file belongs to this repo, so a red
# here is always actionable by whoever is committing.
if ! grep -qE "^readonly[[:space:]]+${HOOK_CONSTANT_NAME}=['\"]${HOOK_CONSTANT_VALUE}['\"]" "$HOOK_SH"; then
  check "Section 1 (D1): hook declares readonly ${HOOK_CONSTANT_NAME}='${HOOK_CONSTANT_VALUE}'" 0
  echo "      Drift mode D1: hook's canonical token diverges from the token regen groups on" >&2
  exit 1
fi
check "Section 1 (D1): hook declares readonly ${HOOK_CONSTANT_NAME}='${HOOK_CONSTANT_VALUE}'" 1

# --- Fixture -----------------------------------------------------------------
# backlog-regen enumerates the git-TRACKED brief set by design, so the fixture must
# be a real repo with the briefs committed; an untracked brief is skipped silently
# and every assertion below would go vacuous.
FIX=$(mktemp -d /tmp/probe-mc-vocab.XXXXXX)
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/.planning/backlog"
git -C "$FIX" init -q .
git -C "$FIX" config user.email probe@localhost
git -C "$FIX" config user.name probe

write_brief() { # write_brief <file> <title> <target_milestone> [<extra frontmatter line>]
  cat > "$FIX/.planning/backlog/$1" <<EOF
---
created: 2026-08-27T00:00:00.000Z
title: $2
target_milestone: $3
status: captured
${4:-}
---

## Problem
Probe fixture.
EOF
}

# A SECOND group is required: renderDocument suppresses ALL headers when there is
# exactly one group and no defects (the singleGroup rule). With one brief the header
# under test would never render and D3/D4 would pass vacuously.
write_brief 2026-08-27-mc.md    "Milestone close fixture" next     "urgency: ${CANONICAL_TOKEN}"
write_brief 2026-08-27-plain.md "Plain fixture"           unscoped ""

set_state() { # set_state <current-milestone-line-or-empty>
  { printf -- '---\nstatus: milestone-shipped\n---\n\n# State\n\n'
    [ -n "${1:-}" ] && printf '%s\n' "$1"; } > "$FIX/.planning/STATE.md"
  git -C "$FIX" add -A >/dev/null 2>&1
  git -C "$FIX" commit -qm sync >/dev/null 2>&1 || true
}

emit_stdout() { node "$REGEN_CJS" --emit "$FIX" 2>/dev/null; }
emit_stderr() { node "$REGEN_CJS" --emit "$FIX" 2>&1 >/dev/null; }

# --- Section 2 (D2): 'milestone-close' is canonical AND groups, behaviourally ---
#
# Two observations, both narrow. First, regen's unknown-urgency diagnostic names the
# offending brief; it must NOT name our milestone-close brief. Second — the half that
# actually matters to the hook — the brief must land under a Milestone Close header.
# The negative arm uses a deliberately bogus token so the diagnostic is proven to fire
# at all; without it, a regen that had lost the diagnostic entirely would pass the
# positive arm silently.

set_state ""
if grep -q "unknown urgency \"${CANONICAL_TOKEN}\"" < <(emit_stderr); then
  check "Section 2 (D2): '${CANONICAL_TOKEN}' is accepted as canonical urgency" 0
  echo "      Drift mode D2: regen no longer recognises the token the hook keys on" >&2
else
  check "Section 2 (D2): '${CANONICAL_TOKEN}' is accepted as canonical urgency (no unknown-urgency diagnostic)" 1
fi

# Negative arm — the diagnostic must fire for a token that really is unknown.
write_brief 2026-08-27-mc.md "Milestone close fixture" next "urgency: definitely-not-canonical"
set_state ""
if grep -q 'unknown urgency "definitely-not-canonical"' < <(emit_stderr); then
  check "Section 2 negative control: an unknown urgency IS diagnosed (the check is live)" 1
else
  check "Section 2 negative control FAILED: no diagnostic for a bogus urgency — the positive arm above is vacuous" 0
fi

# And a non-canonical token must NOT group under Milestone Close.
if grep -qE '^## Milestone Close' < <(emit_stdout); then
  check "Section 2 negative control: a non-canonical urgency does NOT create a Milestone Close group" 0
else
  check "Section 2 negative control: a non-canonical urgency does NOT create a Milestone Close group" 1
fi

# Restore the canonical brief for everything below.
write_brief 2026-08-27-mc.md "Milestone close fixture" next "urgency: ${CANONICAL_TOKEN}"

# --- Section 3+4 (D3/D4): both header forms render, and the HOOK matches both ---
#
# The hook's awk pattern is extracted from the hook and applied to the header regen
# ACTUALLY rendered — not to a hand-written fixture string. Then the real hook is run
# against the real document. Renderer and matcher are proven to agree, which is the
# contract; neither half proves it alone.

# Anchor on the awk regex DELIMITERS, not on the bare text. The previous form
# (`grep -oE '\^## Milestone Close[^/]+'`) matched the hook's own HEADER COMMENT — which
# quotes the pattern in backticks — and ran past the closing backtick into prose, so the
# "extracted pattern" was never the code. Requiring a leading `/` selects the live awk
# regex and nothing else. Caught 2026-08-27 the first time the extracted value was
# actually USED instead of being extracted and discarded.
HOOK_PATTERN=$(grep -oE '/\^## Milestone Close[^/]*/' "$HOOK_SH" | head -1 | sed 's|^/||; s|/$||')
if [ -z "$HOOK_PATTERN" ]; then
  check "Section 3 (D3): hook contains a recognizable '## Milestone Close' awk pattern" 0
  echo "      Drift mode D3: hook's surface-scan awk regex has been removed or refactored" >&2
  exit 1
fi
check "Section 3 (D3): extracted hook awk pattern: $HOOK_PATTERN" 1

assert_form() { # assert_form <label> <state-line> <expected-header-regex>
  local label="$1" state_line="$2" expect="$3" doc header

  set_state "$state_line"
  doc="$FIX/.planning/BACKLOG.md"
  emit_stdout > "$doc"

  header=$(grep -E '^## Milestone Close' "$doc" | head -1)
  if [ -z "$header" ]; then
    check "D4 $label: regen renders a Milestone Close header" 0
    return
  fi
  check "D4 $label: regen renders '$header'" 1

  # The rendered header must be the SHAPE this form is supposed to produce. Without
  # this the bare and em-dash cells would be indistinguishable and D4 would only ever
  # prove that *some* header rendered.
  if grep -qE "$expect" < <(printf '%s' "$header"); then
    check "D4 $label: rendered header matches the expected $label shape" 1
  else
    check "D4 $label: rendered header '$header' is not the expected $label shape" 0
  fi

  # The hook's OWN pattern, against the header regen really produced.
  if printf '%s\n' "$header" | awk -v pat="$HOOK_PATTERN" '$0 ~ pat { found=1 } END { exit !found }'; then
    check "D3 $label: hook's own awk pattern matches the rendered header" 1
  else
    check "D3 $label: hook's awk pattern does NOT match the rendered header — D-08 dual-form anchor broken" 0
  fi

  # End to end: the real hook, against the real document.
  local verdict
  verdict=$(printf '{"cwd":"%s","stop_hook_active":false}' "$FIX" \
            | bash "$HOOK_SH" 2>/dev/null | jq -r '.decision // empty' 2>/dev/null)
  if [ "$verdict" = "block" ]; then
    check "E2E $label: hook BLOCKS on the rendered document" 1
  else
    check "E2E $label: hook did not block (decision='${verdict:-none}') — renderer and hook disagree" 0
  fi
}

# Bare form: no current milestone declared, so the header carries no version suffix.
assert_form "bare"    ""                                                    '^## Milestone Close$'
# Em-dash form: a current milestone is declared, so the version is appended.
assert_form "em-dash" '**Current milestone:** v1.3 — Hook event-class semantics' '^## Milestone Close — v1\.3'

# --- Section 5: end-to-end negative control ---
#
# Drop the urgency flag and the hook must STOP blocking. Without this every E2E cell
# above would pass against a hook that blocks unconditionally — which is exactly how a
# blocker regression would look from the outside.
write_brief 2026-08-27-mc.md "Milestone close fixture" next ""
set_state ""
emit_stdout > "$FIX/.planning/BACKLOG.md"
verdict=$(printf '{"cwd":"%s","stop_hook_active":false}' "$FIX" \
          | bash "$HOOK_SH" 2>/dev/null | jq -r '.decision // empty' 2>/dev/null)
if [ -z "$verdict" ]; then
  check "Section 5 negative control: no milestone-close item → hook does NOT block" 1
else
  check "Section 5 negative control FAILED: hook blocked with no milestone-close item (decision='$verdict')" 0
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
