#!/bin/bash
# probe-draft-buffer-gate-key-parity.sh — buffer↔gate marker-key source parity.
#
# Backs the 2026-06-13 current-session-stamp retirement (hooks docs/decisions.md
# row; cross-repo docs/prompts/done/2026-06-13-retire-current-session-stamp-prompt.md).
# Asserts the cross-process INVARIANT documented at the two key-derivation sites:
#   scripts/dhx-draft-buffer.sh  (WRITER) — builds draft-buffer-<id>.json where
#       <id> = resolve_session_id  (env $CLAUDE_CODE_SESSION_ID, else pid-file .sessionId)
#   dhx/dhx-gsd-canonical-mirror-gate.sh (READER) — builds draft-buffer-<id>.json
#       where <id> = its hook-stdin .session_id
# If the two <id> sources disagree, an operator-authorized edit silently fails to
# suppress the gate (the exact 2026-06-13 break this migration closed).
#
# WHAT THIS PROBE PROVES (hermetic) vs WHAT THE DOC PROVES (empirical):
#   - Probe (here): the MECHANISM. Fed a single id S, the buffer's written marker is
#     the one the gate validates (positive), and a different id does NOT match
#     (negative, session-scoped). Plus resolve_session_id's env-primary + pid-file
#     fallback, and a regression guard that the buffer no longer reads the retired
#     .current-session.id stamp.
#   - Doc (decisions.md + the INVARIANT comments): the CC-internal EQUALITY
#     $CLAUDE_CODE_SESSION_ID == hook-stdin .session_id (incl. bridged sessions, where
#     it is the local UUID, never bridgeSessionId). Verified 2026-06-13 against the
#     UserPromptSubmit registry + transcript records + pid-file — NOT hermetically
#     re-derivable (it would need a live bridged session), so THIS hermetic probe
#     assumes it via the shared-S construction. DIRECTLY CAPTURED 2026-07-15 on a
#     real bridged session (bridgeSessionId `session_*` flavor, 0 transcript
#     bridge-session entries) and now guarded, in any live session's run, by the
#     live-observer companion probe-session-id-env-stdin-parity.sh (env ==
#     registry-captured real stdin == pid-file .sessionId, ≠ bridgeSessionId). See
#     docs/decisions.md 2026-07-15 escape-valve-under-bridge capture row + HP-043.
#
# Run: bash tests/probes/probe-draft-buffer-gate-key-parity.sh
# Exit: 0 all pass; 1 any fail; 0-with-SKIP when the shared resolver lib is absent
#       (skills repo not mounted — e.g. fresh hooks checkout / CI).
#
# All fixtures live under one mktemp -d (sandbox HOME + sandbox dhx-shared symlink +
# DHX_DRAFT_BUFFER_DIR/DHX_BACKUP_META overrides for the gate). The live
# ~/.cache/dhx/, ~/.claude/, and the operator's session state are never touched.

# SAFE_FOR_LIVE: yes  (mktemp sandbox HOME + dhx-shared symlink + DHX_DRAFT_BUFFER_DIR/DHX_BACKUP_META overrides; never reads/writes live ~/.cache/dhx/ or ~/.claude/)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUFFER="$REPO_ROOT/scripts/dhx-draft-buffer.sh"
GATE="$REPO_ROOT/dhx/dhx-gsd-canonical-mirror-gate.sh"

# Resolve the installed shared lib the way the buffer does (tier-1 CLAUDE_CONFIG_DIR,
# tier-2 $HOME/.claude literal). SKIP cleanly if the skills repo isn't mounted.
LIB="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/dhx-shared/lib/session-identity.sh"
[ -r "$LIB" ] || LIB="$HOME/.claude/dhx-shared/lib/session-identity.sh"
[ -r "$LIB" ] || { echo "SKIP: shared resolver lib absent ($LIB) — skills repo not mounted"; exit 0; }
SHARED_REAL="$(readlink -f "$(dirname "$(dirname "$LIB")")")"   # …/dhx-shared

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0
assert() {
  local name="$1"; shift
  if "$@"; then echo "OK   $name"; PASS=$((PASS + 1))
  else echo "FAIL $name"; FAIL=$((FAIL + 1)); fi
}

echo "=== draft-buffer ↔ gate marker-key parity (tmpdir-isolated) ==="

# Sandbox HOME with a dhx-shared symlink so the buffer can source the resolver, and
# a redirected ~/.cache/dhx so the buffer's hardcoded marker dir lands in the sandbox.
HOME_SB="$TMPDIR/home"
mkdir -p "$HOME_SB/.claude" "$HOME_SB/.cache/dhx"
ln -s "$SHARED_REAL" "$HOME_SB/.claude/dhx-shared"

S="parity-probe-$$"
REL="gsd-core/probe/parity-fixture.md"
GATEFILE="$HOME_SB/.claude/$REL"                       # under sandbox GSD_LIVE_ROOT
MARKER="$HOME_SB/.cache/dhx/draft-buffer-${S}.json"

BACKUP_META_FIXTURE="$TMPDIR/backup-meta.json"
jq -n --arg p "$REL" '{version:1, files:[$p]}' > "$BACKUP_META_FIXTURE"

# ---- WRITER: buffer resolves the session id from $CLAUDE_CODE_SESSION_ID and writes
#      the marker. HOME + CLAUDE_CONFIG_DIR point at the sandbox (lib + marker dir). ----
ADD_OUT=$(HOME="$HOME_SB" CLAUDE_CONFIG_DIR="$HOME_SB/.claude" CLAUDE_CODE_SESSION_ID="$S" \
  bash "$BUFFER" add "$REL" --reason "parity probe" --expires 1h 2>&1)
assert "[writer] buffer 'add' exits 0" bash -c '[ "$1" = "0" ]' _ "$?"
assert "[writer] marker written at resolver-keyed filename draft-buffer-<S>.json" \
  test -f "$MARKER"
assert "[writer] marker .session_id == resolved id S" \
  bash -c '[ "$(jq -r .session_id "$1")" = "$2" ]' _ "$MARKER" "$S"

run_gate() {  # $1=session_id $2=file_path → sets EC
  local sid="$1" file="$2" envelope
  envelope=$(jq -n --arg sid "$sid" --arg file "$file" \
    '{session_id:$sid, tool_name:"Edit", cwd:"/tmp", tool_input:{file_path:$file}}')
  printf '%s' "$envelope" | \
    HOME="$HOME_SB" DHX_DRAFT_BUFFER_DIR="$HOME_SB/.cache/dhx" DHX_BACKUP_META="$BACKUP_META_FIXTURE" \
    bash "$GATE" >/dev/null 2>&1
  EC=$?
}

# ---- POSITIVE: gate keyed by the SAME id S finds the buffer-written marker → exit 0. ----
run_gate "$S" "$GATEFILE"
assert "[parity+] gate with matching session_id finds buffer marker → exit 0 (suppressed)" \
  bash -c '[ "$1" = "0" ]' _ "$EC"

# ---- NEGATIVE: gate keyed by a DIFFERENT id does NOT find the marker → blocks (exit 2). ----
run_gate "${S}-WRONG" "$GATEFILE"
assert "[parity-] gate with different session_id does NOT match marker → exit 2 (session-scoped)" \
  bash -c '[ "$1" = "2" ]' _ "$EC"

# ---- RESOLVER unit: env-primary returns $CLAUDE_CODE_SESSION_ID verbatim. ----
# (This is the link that makes the buffer's key equal the gate's stdin id in prod.)
RID=$(CLAUDE_CODE_SESSION_ID="env-id-xyz" bash -c '. "$1"; resolve_session_id' _ "$LIB")
assert "[resolver] env primary: resolve_session_id == \$CLAUDE_CODE_SESSION_ID" \
  bash -c '[ "$1" = "env-id-xyz" ]' _ "$RID"

# ---- RESOLVER unit: pid-file fallback (env unset) reads .sessionId via the seam. ----
FIX_PF="$TMPDIR/fixture-pidfile.json"
jq -n '{pid:999, sessionId:"pidfile-id-abc", cwd:"/x"}' > "$FIX_PF"
RID2=$(env -u CLAUDE_CODE_SESSION_ID SI_SESSION_PIDFILE="$FIX_PF" \
  bash -c '. "$1"; resolve_session_id' _ "$LIB")
assert "[resolver] pid-file fallback: resolve_session_id reads .sessionId" \
  bash -c '[ "$1" = "pidfile-id-abc" ]' _ "$RID2"

# ---- REGRESSION guard: the buffer must no longer read the retired stamp, and must
#      source the shared resolver. Locks the retirement (no silent revert to the stamp). ----
assert "[regress] buffer no longer reads .current-session.id" \
  bash -c '! grep -q "current-session.id" "$1"' _ "$BUFFER"
assert "[regress] buffer sources session-identity.sh" \
  bash -c 'grep -q "session-identity.sh" "$1"' _ "$BUFFER"

echo "---"
echo "$PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
