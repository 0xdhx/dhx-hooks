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
#   exit 0 + premise_holds        = BOTH cells saw CC's native block → collapse warranted.
#   exit 1 + supersession_found   = CC ALLOWED an unread Edit or Write → investigate/revive.
#   exit 0 + skipped              = could not produce a trustworthy result (no auth, auth
#                                   failure in the subprocess, or the model declined the
#                                   tool) — NOT a failure signal, and NOT a pass.
#
# FALSE-PASS GUARD (load-bearing — 2026-05-24): premise_holds is emitted ONLY when
# BOTH cells definitively observed CC's block. An inconclusive cell (subprocess
# auth failure, or the model declining the tool) can NEVER roll up to premise_holds
# — it degrades to `skipped`. A watchdog that silently false-passes is worse than
# useless: it would report "CC enforcement holds" without having tested anything,
# masking a real supersession. The original cell logic only tracked FAIL, so two
# inconclusive cells printed [PASS] — fixed by requiring PASS_COUNT==2.
#
# AUTH (the subtlety the original missed): `drive()` runs `claude -p` under a
# SANDBOX CLAUDE_CONFIG_DIR for isolation. A fresh config dir is LOGGED OUT — the
# subprocess returns 401 "authentication_failed" — UNLESS ANTHROPIC_API_KEY is in
# the env (inherited by the subprocess regardless of config dir). So this probe
# requires ANTHROPIC_API_KEY; without it, it emits `skipped` (a sandboxed claude -p
# cannot authenticate, and there is no SAFE workaround — see below).
#
# WHY NOT SEED OAUTH CREDENTIALS (rejected — 2026-05-24, measured): copying a live
# ~/.claude/.credentials.json into the sandbox so the subprocess "inherits" OAuth was
# tried and is UNSAFE. A copied credential authenticated once, then the identical
# copy 401'd minutes later — the signature of OAuth refresh-token rotation: the
# sandboxed claude consumes the refresh token, rotates it, writes the new one to the
# throwaway sandbox (lost), and the provider invalidates the old one — leaving the
# SOURCE credential file stale. Copying live OAuth creds into a disposable dir can
# invalidate the source credential. (This also explains the sibling IP-path probes'
# README D-18c `auth_failure`-with-credentials_file note — same root cause: a
# credentials_file is not a safe subprocess-auth path; only ANTHROPIC_API_KEY is.)
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
# Operator-invoked. Auth: ANTHROPIC_API_KEY (required — see AUTH note above).
# Outcome JSON lands under tests/probes/.results/<milestone>/<cc-version>/.
#
# SAFE_FOR_LIVE: no    (spawns claude -p subprocesses; sandbox CLAUDE_CONFIG_DIR + mktemp targets)
# RUNTIME: ~60-120s    (two claude -p turns)
set -uo pipefail

BLOCK_RE='has not been read yet'
# Subprocess could not authenticate / was rate-or-credit-blocked → the run is
# inconclusive, never a pass and never a supersession. Covers the observed 401
# stream ("authentication_failed" / "Invalid authentication credentials" /
# "Failed to authenticate") plus logged-out and credit/expiry variants.
AUTH_FAIL_RE='Not logged in|Please run /login|Invalid API key|invalid x-api-key|authentication_error|authentication_failed|Invalid authentication credentials|Failed to authenticate|api_error_status":401|Credit balance is too low|OAuth token has expired'

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

# Auth pre-check — a sandboxed `claude -p` can only authenticate via an inherited
# ANTHROPIC_API_KEY (a credentials_file is unsafe to seed — see AUTH note in the
# header). No API key → emit skipped immediately rather than spawn a subprocess that
# will only 401 through its retry loop.
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "SKIP read-guard-native-enforcement-tripwire: no ANTHROPIC_API_KEY (a sandboxed claude -p cannot auth via OAuth credentials_file safely — re-run with an API key)"
  emit_outcome "skipped" "no ANTHROPIC_API_KEY (credentials_file is not a safe sandbox-auth path)"
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
PASS_COUNT=0
INCONCLUSIVE=0

# Classify one cell's captured stream. Sets PASS_COUNT / FAIL / INCONCLUSIVE.
# Order matters: auth-failure is checked FIRST so a logged-out subprocess can never
# be misread as a block (pass) or an allow (supersession).
check_cell() { # $1 = label, $2 = output, $3 = allow-regex (cell-specific success strings)
  local label="$1" out="$2" allow_re="$3"
  if grep -qiE "$AUTH_FAIL_RE" <<< "$out"; then
    echo "SKIP $label → subprocess could not authenticate (logged out / invalid key / credit) — inconclusive"
    INCONCLUSIVE=1
    return
  fi
  if grep -qi "$BLOCK_RE" <<< "$out"; then
    echo "OK   $label → CC blocked (native enforcement holds)"
    PASS_COUNT=$((PASS_COUNT + 1))
    return
  fi
  if grep -qiE "$allow_re" <<< "$out"; then
    echo "FAIL $label → NO native block detected (possible supersession — investigate)"
    FAIL=1
    return
  fi
  echo "WARN $label inconclusive (model may have declined the tool); re-run or inspect stream"
  INCONCLUSIVE=1
}

# Cell 1 — Edit on an unread, out-of-band-created file.
EDIT_TGT="$WORK/tripwire-edit.txt"; printf 'a\nb\nc\n' > "$EDIT_TGT"
check_cell "Edit on unread file" "$(drive Edit "$EDIT_TGT")" 'updated successfully|has been updated'

# Cell 2 — Write on an unread, out-of-band-created EXISTING file (1f).
WRITE_TGT="$WORK/tripwire-write.txt"; printf 'a\nb\nc\n' > "$WRITE_TGT"
check_cell "Write on unread existing file" "$(drive Write "$WRITE_TGT")" 'wrote|has been (written|created|updated)'

# --- Roll-up. premise_holds requires BOTH cells to have observed CC's block. ---
if [ "$FAIL" -ne 0 ]; then
  echo "1+ cell failed — CC native read-before-edit enforcement may have weakened. The Option C collapse removed dhx's strong advisory on the assumption this holds; revisit docs/decisions.md Option C row."
  emit_outcome "supersession_found_revive_signal" "CC allowed an unread Edit or Write"
  exit 1
fi

if [ "$PASS_COUNT" -eq 2 ]; then
  echo "[PASS] read-guard-native-enforcement-tripwire: CC native enforcement holds (Edit + Write blocked)"
  emit_outcome "premise_holds_collapse_warranted" "CC blocked unread Edit and Write"
  exit 0
fi

# Neither a clean double-block nor a supersession → inconclusive. Do NOT claim
# premise_holds (the false-PASS guard). Exit 0 (not a failure), but record skipped.
echo "SKIP read-guard-native-enforcement-tripwire: inconclusive — ${PASS_COUNT}/2 cells saw CC's block (auth failure or model declined the tool). No trustworthy baseline produced; re-run with working auth."
emit_outcome "skipped" "inconclusive: ${PASS_COUNT}/2 cells blocked (auth-fail or tool declined)"
exit 0
