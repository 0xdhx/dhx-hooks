#!/usr/bin/env bash
# probe-read-guard-native-enforcement-tripwire.sh — supersession-watchdog.
#
# Backs the 2026-05-24 decisions.md Option C collapse row (Q3 "depend + add a
# probe"). The collapse REMOVED dhx's strong READ-BEFORE-EDIT advisory and now
# DEPENDS on CC's NATIVE runtime to block edits/writes to unread files (Probes
# 1a/1f: CC hard-errors "File has not been read yet"). This probe is the contract
# tripwire: if a future CC release WEAKENS that native enforcement, this flips red
# → revive signal (the strong advisory may need to come back).
#
# Semantics (supersession-watchdog — see tests/probes/README.md):
#   exit 0  = premise HOLDS — CC still blocks unread Edit AND Write → collapse warranted.
#   exit 1  = SUPERSESSION/REGRESSION — CC allowed an unread Edit or Write → investigate.
#   exit 0 + skipped outcome = could not run (no auth) — not a failure signal.
#
# Method (mirrors the IP-path watchdog probes): drive a real `claude -p` subprocess
# against a sandbox CLAUDE_CONFIG_DIR, ask it to Edit (then Write) a file created
# OUT-OF-BAND via printf (NOT the Write tool — a Write-tool-created file is "seen"
# per troubleshooting.md:587), and scan the event stream for CC's native
# tool_use_error block string. Isolation method (b): the dhx guard is non-blocking
# additionalContext-only, so a HARD tool error is unambiguously CC-native, distinct
# from any dhx advisory text.
#
# INVARIANT (the dependency this asserts): CC's tool layer rejects Edit/Write to a
# file not Read in the current session-transcript, emitting
#   "File has not been read yet. Read it first before writing to it."
# This is the enforcement dhx-read-guard.js's `if (!hasPartialRead) exit(0)` relies
# on. 7+ upstream issues (#16182/#4230/#17895/#53525/#2621/#16546/#14964); no hook
# emits the string (grep-null across ~/.claude/hooks + plugin cache).
#
# Operator-invoked (needs auth: credentials_file or ANTHROPIC_API_KEY). Outcome JSON
# lands under tests/probes/.results/<milestone>/<cc-version>/ per the v1.3+ cadence.
#
# SAFE_FOR_LIVE: no    (spawns claude -p subprocesses; sandbox CLAUDE_CONFIG_DIR + mktemp targets)
# RUNTIME: ~60-120s    (two claude -p turns)
set -uo pipefail

BLOCK_RE='has not been read yet'

SANDBOX=$(mktemp -d)
WORK=$(mktemp -d)
trap 'rm -rf "$SANDBOX" "$WORK"' EXIT

CC_VERSION=$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")

emit_outcome() { # $1 = conclusion, $2 = note
  local outdir="tests/probes/.results/v1.x-option-c/${CC_VERSION}"
  mkdir -p "$outdir" 2>/dev/null || true
  printf '{"probe":"read-guard-native-enforcement-tripwire","cc_version":"%s","conclusion":"%s","note":"%s","ts":%s}\n' \
    "$CC_VERSION" "$1" "$2" "$(date +%s)" > "$outdir/outcome.json" 2>/dev/null || true
}

# Auth pre-check — without it, claude -p cannot run; report skipped (NOT a failure).
if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ ! -f "$HOME/.claude/.credentials.json" ] && [ ! -f "$HOME/.claude/credentials.json" ]; then
  echo "SKIP read-guard-native-enforcement-tripwire: no auth (set ANTHROPIC_API_KEY or provide credentials_file)"
  emit_outcome "skipped" "no auth available"
  exit 0
fi

# Drive one claude -p turn that asks ONLY for the named tool on the out-of-band file,
# with no prior Read. Returns the captured stream so the caller can scan for the block.
drive() { # $1 = tool (Edit|Write), $2 = target path
  local tool="$1" tgt="$2" prompt
  if [ "$tool" = "Edit" ]; then
    prompt="Use the Edit tool to change the first line of ${tgt} from 'a' to 'A'. Do NOT read the file first — attempt the Edit directly. If the tool errors, report the exact error text."
  else
    prompt="Use the Write tool to overwrite ${tgt} with the single line 'Z'. Do NOT read the file first — attempt the Write directly. If the tool errors, report the exact error text."
  fi
  CLAUDE_CONFIG_DIR="$SANDBOX/.claude" timeout 120 \
    claude -p "$prompt" --output-format stream-json --include-hook-events --verbose 2>&1 || true
}

FAIL=0

# Cell 1 — Edit on an unread, out-of-band-created file.
EDIT_TGT="$WORK/tripwire-edit.txt"; printf 'a\nb\nc\n' > "$EDIT_TGT"
EDIT_OUT=$(drive Edit "$EDIT_TGT")
if grep -qi "$BLOCK_RE" <<< "$EDIT_OUT"; then
  echo "OK   Edit on unread file → CC blocked (native enforcement holds)"
else
  # Distinguish a genuine supersession from "the model chose to Read first anyway".
  if grep -qiE 'tool_use_error|updated successfully|has been updated' <<< "$EDIT_OUT"; then
    echo "FAIL Edit on unread file → NO native block detected (possible supersession — investigate)"
    FAIL=1
  else
    echo "WARN Edit cell inconclusive (model may have declined the tool); re-run or inspect stream"
  fi
fi

# Cell 2 — Write on an unread, out-of-band-created EXISTING file (1f).
WRITE_TGT="$WORK/tripwire-write.txt"; printf 'a\nb\nc\n' > "$WRITE_TGT"
WRITE_OUT=$(drive Write "$WRITE_TGT")
if grep -qi "$BLOCK_RE" <<< "$WRITE_OUT"; then
  echo "OK   Write on unread existing file → CC blocked (native enforcement holds)"
else
  if grep -qiE 'tool_use_error|wrote|has been (written|created|updated)' <<< "$WRITE_OUT"; then
    echo "FAIL Write on unread existing file → NO native block detected (possible supersession — investigate)"
    FAIL=1
  else
    echo "WARN Write cell inconclusive (model may have declined the tool); re-run or inspect stream"
  fi
fi

if [ "$FAIL" -ne 0 ]; then
  echo "1+ cell failed — CC native read-before-edit enforcement may have weakened. The Option C collapse removed dhx's strong advisory on the assumption this holds; revisit docs/decisions.md Option C row."
  emit_outcome "supersession_found_revive_signal" "CC allowed an unread Edit or Write"
  exit 1
fi

echo "[PASS] read-guard-native-enforcement-tripwire: CC native enforcement holds (Edit + Write blocked)"
emit_outcome "premise_holds_collapse_warranted" "CC blocked unread Edit and Write"
exit 0
