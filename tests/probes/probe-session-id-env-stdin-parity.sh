#!/bin/bash
# probe-session-id-env-stdin-parity.sh — LIVE-OBSERVER (not hermetic).
#
# Pins the CC-internal equality that probe-draft-buffer-gate-key-parity.sh
# EXPLICITLY defers (its header: the equality "is not hermetically re-derivable —
# it would need a live bridged session"):
#
#     $CLAUDE_CODE_SESSION_ID  (tool-subprocess env; == the value CC delivers to a
#       hook as stdin .session_id, including the canonical-mirror GATE reader)
#   =  the REAL hook-stdin .session_id CC delivered this session — captured by the
#       dhx-session-registry-prompt.sh UserPromptSubmit hook into
#       ~/.claude/dhx-session-registry.tsv on a real event (col 3), NOT synthetic
#   =  the pid-file .sessionId  (resolve_session_pidfile, /proc ancestry)
#   and, when the session is BRIDGED (pid-file .bridgeSessionId set), that value is
#   the LOCAL uuid, NEVER the bridgeSessionId.
#
# This is the link that makes the draft-buffer WRITER's marker key
# (resolve_session_id, env-primary) equal the canonical-mirror gate READER's
# hook-stdin .session_id — so an operator-authorized draft-buffer marker actually
# suppresses the (now block-all, 2026-07-14) gate. First DIRECTLY captured
# 2026-07-15 on a real bridged session: bridgeSessionId `session_*` flavor with 0
# transcript `bridge-session` entries — the 2026-06-13 transcript-entry
# discriminator would MISCLASSIFY it as terminal; the pid-file .bridgeSessionId
# field is the reliable cross-flavor bridge signal. See docs/decisions.md
# 2026-07-15 escape-valve-under-bridge capture row + HP-043.
#
# LIVE-OBSERVER, READ-ONLY: the equality is CC-internal, so a hermetic fixture
# cannot reproduce what CC stamps — this probe asserts only inside a live session.
# It asserts when it can (env var set AND a registry start row exists for it) and
# SKIPs cleanly (exit 0) otherwise: a fresh session with no user turn yet, a
# detached CI run, or non-Linux. The BRIDGED leg fires only when the pid-file
# actually carries a bridgeSessionId, so it is a real observation, never a fixture.
# Runs green in any live-session pre-commit; a future CC change that broke
# env==stdin (or keyed state by bridgeSessionId) would red it there.
#
# SAFE_FOR_LIVE: yes  (read-only: reads $CLAUDE_CODE_SESSION_ID, the shared session-identity resolver, ~/.claude/dhx-session-registry.tsv, and the /proc-resolved pid-file; never writes)
set -u

PASS=0; FAIL=0
assert() { local n="$1"; shift; if "$@"; then echo "OK   $n"; PASS=$((PASS+1)); else echo "FAIL $n"; FAIL=$((FAIL+1)); fi; }

echo "=== session-id env↔stdin↔pid-file parity (live-observer) ==="

# Precondition 1: env var (the gate-stdin-equivalent, per HP-043).
SID_ENV="${CLAUDE_CODE_SESSION_ID:-}"
[ -n "$SID_ENV" ] || { echo "SKIP: \$CLAUDE_CODE_SESSION_ID unset (not a live session tool subprocess)"; exit 0; }

# Precondition 2: the shared resolver (the draft-buffer writer's key source).
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
LIB="$CFG/dhx-shared/lib/session-identity.sh"; [ -r "$LIB" ] || LIB="$HOME/.claude/dhx-shared/lib/session-identity.sh"
[ -r "$LIB" ] || { echo "SKIP: session-identity resolver not found ($LIB)"; exit 0; }
# shellcheck disable=SC1090
. "$LIB"

# Precondition 3: a REAL captured hook-stdin .session_id for THIS session. The
# UserPromptSubmit registry writes to LITERAL $HOME/.claude (hook comment); col 3
# (uuid) is the real stdin .session_id CC delivered on a real event.
REG="$HOME/.claude/dhx-session-registry.tsv"
REG_UUID=""
[ -r "$REG" ] && REG_UUID=$(awk -F'\t' -v s="$SID_ENV" '$3==s{print $3; exit}' "$REG")
[ -n "$REG_UUID" ] || { echo "SKIP: no dhx-session-registry start row for $SID_ENV (no user turn captured yet)"; exit 0; }

# ── WRITER key source: resolve_session_id is env-primary → == the gate's stdin id.
# Call the sourced function in THIS shell (bash -c would not inherit it), capture,
# then compare — keeps the assert helper's subshell free of function-scope needs.
RID="$(resolve_session_id)"
assert "resolve_session_id (writer key) == \$CLAUDE_CODE_SESSION_ID" \
  bash -c '[ "$1" = "$2" ]' _ "$RID" "$SID_ENV"

# ── REAL hook-stdin .session_id (registry) == env var — THE core equality.
assert "real hook-stdin .session_id (registry) == \$CLAUDE_CODE_SESSION_ID" \
  bash -c '[ "$1" = "$2" ]' _ "$REG_UUID" "$SID_ENV"

# ── pid-file .sessionId agrees (third independent source) + BRIDGED leg.
PF="$(resolve_session_pidfile || true)"
if [ -n "$PF" ] && [ -r "$PF" ] && command -v jq >/dev/null 2>&1; then
  PF_SID=$(jq -r '.sessionId // empty' "$PF" 2>/dev/null)
  PF_BRIDGE=$(jq -r '.bridgeSessionId // empty' "$PF" 2>/dev/null)
  assert "pid-file .sessionId == \$CLAUDE_CODE_SESSION_ID" \
    bash -c '[ "$1" = "$2" ]' _ "$PF_SID" "$SID_ENV"
  if [ -n "$PF_BRIDGE" ]; then
    echo "     (session is BRIDGED — pid-file .bridgeSessionId present)"
    # // INVARIANT (HP-043): CC keys per-session state (draft-buffer markers,
    # // JSONL provenance) by the LOCAL uuid, NEVER the bridgeSessionId. If this
    # // ever flips, the draft-buffer writer and the gate reader would key off
    # // different ids and the escape valve would silently no-op.
    assert "[bridged] session_id is the LOCAL uuid, NOT bridgeSessionId" \
      bash -c '[ "$1" != "$2" ] && [ "$3" = "$1" ]' _ "$SID_ENV" "$PF_BRIDGE" "$PF_SID"
  else
    echo "     (not bridged / pid-file carries no bridgeSessionId — bridged leg not exercised this run)"
  fi
else
  echo "     (pid-file unresolved — pid-file legs skipped; env↔stdin parity still asserted above)"
fi

echo "---"
echo "$PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
