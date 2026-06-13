#!/usr/bin/env bash
# scripts/dhx-draft-buffer.sh — operator marker-file writer for ~/.cache/dhx/draft-buffer-${session_id}.json.
# Subcommands: add <rel-path> [--reason X] [--expires Nh] | clear | show
# Hides the marker JSON shape from operators (D-13). Backs Phase 16 REQ-DRIFT-ACTION-03 annotation contract.
# The marker is the runtime escape valve for dhx-gsd-canonical-mirror-gate.sh (single [ -f ... ] test on hot path).
# Durable audit trail lives in CONTEXT.md frontmatter draft_against_live_fork_tracked_files: (D-15).
# Exit codes: 0 happy path; 1 on setup failure (missing session file, missing jq, invalid path arg, path-dialect rejection).
#
# Dialect contract (per D-23 — see 'Dialect contract' subsection in the body):
#   Accepts 3 input dialects: canonical 'gsd-core/...', absolute '$HOME/.claude/gsd-core/...', bare 'workflows/...'.
#   Rejects: absolute paths outside $HOME/.claude/; any '..' traversal segment.
#   Stores canonical 'gsd-core/...' form exclusively in the marker paths[] array.
set -uo pipefail

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq required but not found in PATH." >&2
  exit 1
fi

mkdir -p "$HOME/.cache/dhx" 2>/dev/null || {
  echo "ERROR: failed to create ~/.cache/dhx directory." >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat >&2 <<'EOF'
Usage: scripts/dhx-draft-buffer.sh <add|clear|show> [args]
  add <rel-path> [--reason "<text>"] [--expires <Nh>]
  clear
  show
Path dialects accepted: 'gsd-core/X', '$HOME/.claude/gsd-core/X', 'X' (bare).
Schema documented in docs/hook-dev-guide.md § Marker File Schemas.
EOF
}

# ========================================================================
# Dialect contract (D-23) — see CLI doc string above for summary.
# normalize_rel_path() input arms:
#   (a) Starts with literal "gsd-core/"           → accept as-is
#   (b) Starts with "$HOME/.claude/gsd-core/"     → strip "$HOME/.claude/" prefix
#   (c) No leading "/", no ".." segment, NOT (a)       → prepend "gsd-core/"
# Rejected (exit 1 with stderr error):
#   (d) Absolute path NOT under "$HOME/.claude/"
#   (e) Any segment ".." anywhere in the path
# Output: canonical "gsd-core/..." form on stdout (no trailing newline if used in $())
# ========================================================================
normalize_rel_path() {
  local input="$1"

  # Arm (e): reject ".." anywhere — segment-level traversal guard
  case "$input" in
    *..*)
      echo "ERROR: relative path traversal rejected: $input" >&2
      return 1
      ;;
  esac

  # Arm (d): absolute path NOT under $HOME/.claude/ → reject
  if [[ "$input" == /* ]]; then
    if [[ "$input" != "$HOME/.claude/"* ]]; then
      echo "ERROR: absolute path outside \$HOME/.claude/ rejected: $input" >&2
      return 1
    fi
    # Edge: under $HOME/.claude/ but NOT in gsd-core/ subtree
    if [[ "$input" != "$HOME/.claude/gsd-core/"* ]]; then
      echo "ERROR: path under \$HOME/.claude/ but not in gsd-core/ subtree: $input" >&2
      return 1
    fi
    # Arm (b): absolute under $HOME/.claude/gsd-core/ → strip prefix
    printf '%s' "${input#$HOME/.claude/}"
    return 0
  fi

  # Arm (a): canonical form "gsd-core/..." → accept as-is
  case "$input" in
    gsd-core/*)
      printf '%s' "$input"
      return 0
      ;;
  esac

  # Arm (c): bare relative path → prepend "gsd-core/"
  printf '%s' "gsd-core/$input"
  return 0
}

# ---------------------------------------------------------------------------
# Subcommand parse (validate BEFORE touching the session-id file so no-args / unknown
# subcommand → Usage cleanly, independent of CC session presence)
# ---------------------------------------------------------------------------
SUBCMD="${1:-}"
case "$SUBCMD" in
  add|clear|show)
    shift
    ;;
  '')
    usage
    exit 1
    ;;
  *)
    echo "ERROR: unknown subcommand: $SUBCMD" >&2
    usage
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# Session-id resolution (2026-06-13: per-session via the shared resolver, NOT the
# retired SessionStart cwd stamp under <cfg>/projects/<encoded-cwd>/). The stamp was
# a single slot keyed by (config-dir, cwd) — last-writer-wins under same-cwd
# concurrency (R-2) AND never refreshed for bridged sessions — so it froze on the
# multi-concurrent + bridge host this marker must work on. See hooks
# docs/decisions.md 2026-06-13 rows + docs/troubleshooting.md (frozen-stamp section).
# ---------------------------------------------------------------------------
# Source path: CCS points $CLAUDE_CONFIG_DIR at an instance dir with NO dhx-shared,
# so fall back to the $HOME/.claude/dhx-shared literal (the install symlink target).
LIB="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/dhx-shared/lib/session-identity.sh"
[ -r "$LIB" ] || LIB="$HOME/.claude/dhx-shared/lib/session-identity.sh"
# shellcheck source=/dev/null
[ -r "$LIB" ] && . "$LIB"
if ! command -v resolve_session_id >/dev/null 2>&1; then
  echo "ERROR: session-identity resolver unavailable ($LIB). Cannot resolve session." >&2
  exit 1
fi

# INVARIANT (cross-process, cross-repo — buffer↔gate marker-key parity):
#   resolve_session_id here (via $CLAUDE_CODE_SESSION_ID, else pid-file .sessionId)
#   MUST equal the value dhx-gsd-canonical-mirror-gate.sh reads from its hook stdin
#   as `.session_id`. Both sides then build $DRAFT_BUFFER_DIR/draft-buffer-<id>.json.
#   If they diverge, an operator-authorized edit silently fails to suppress the gate
#   (the exact 2026-06-13 break this migration closes). Parity holds because CC stamps
#   ONE session UUID into both the tool-subprocess env (CLAUDE_CODE_SESSION_ID) and the
#   hook envelope (.session_id) — including bridged sessions, where it is the local
#   UUID, never bridgeSessionId (verified 2026-06-13 against the UserPromptSubmit
#   registry + transcript records + pid-file). Enforced by
#   tests/probes/probe-draft-buffer-gate-key-parity.sh.
# WR-04: strip stray whitespace/CR before the marker filename is built (defense — a
# session UUID carries none, but never let one reach draft-buffer-<sid>\r.json, a name
# the gate can never reconstruct). The metachar guard then mirrors the gate's own
# session-id sanitization (T-16-06).
SESSION_ID="$(resolve_session_id | tr -d '[:space:]')"
if [ -z "$SESSION_ID" ]; then
  echo "ERROR: could not resolve live session id (no \$CLAUDE_CODE_SESSION_ID, no readable pid-file). Run inside a Claude Code session." >&2
  exit 1
fi
case "$SESSION_ID" in
  *[/\\]*|*..*)
    echo "ERROR: session_id contains path metacharacters: $SESSION_ID" >&2
    exit 1
    ;;
esac

MARKER="$HOME/.cache/dhx/draft-buffer-${SESSION_ID}.json"

# ---------------------------------------------------------------------------
# Subcommand dispatch
# ---------------------------------------------------------------------------
case "$SUBCMD" in
  add)
    if [ $# -lt 1 ]; then
      echo "ERROR: 'add' requires a <rel-path> argument." >&2
      usage
      exit 1
    fi
    REL_INPUT="$1"
    shift

    REASON="unspecified (operator did not annotate)"
    EXPIRES_HOURS="24"

    # Position-agnostic flag parsing
    while [ $# -gt 0 ]; do
      case "$1" in
        --reason)
          if [ $# -lt 2 ]; then
            echo "ERROR: --reason requires a value." >&2
            exit 1
          fi
          REASON="$2"
          shift 2
          ;;
        --expires)
          if [ $# -lt 2 ]; then
            echo "ERROR: --expires requires a value (e.g., 24h)." >&2
            exit 1
          fi
          if [[ ! "$2" =~ ^[1-9][0-9]*h$ ]]; then
            echo "ERROR: --expires must be a positive integer followed by 'h' (e.g., 24h), got: $2" >&2
            exit 1
          fi
          EXPIRES_HOURS="${2%h}"
          shift 2
          ;;
        *)
          echo "ERROR: unknown flag for 'add': $1" >&2
          usage
          exit 1
          ;;
      esac
    done

    NORM=$(normalize_rel_path "$REL_INPUT") || exit 1

    # Uses GNU date -d; portable across WSL2/Linux (project requirement); not POSIX-portable.
    EXPIRES_ISO=$(date -u -d "+${EXPIRES_HOURS} hours" +%Y-%m-%dT%H:%M:%SZ)

    # Optional context_md_anchor — populate if $PWD is inside .planning/phases/<phase>/ AND a *-CONTEXT.md exists there
    CONTEXT_MD_ANCHOR=""
    case "$PWD" in
      */.planning/phases/*)
        # Find the deepest .planning/phases/<phase>/ ancestor
        ANCESTOR="$PWD"
        while [ "$ANCESTOR" != "/" ]; do
          PARENT="$(dirname "$ANCESTOR")"
          if [[ "$PARENT" == */.planning/phases ]]; then
            # ANCESTOR is the phase dir
            CONTEXT_CANDIDATE=$(ls "$ANCESTOR"/*-CONTEXT.md 2>/dev/null | head -1 || true)
            if [ -n "$CONTEXT_CANDIDATE" ]; then
              # Compute repo-root-relative path
              REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
              if [ -n "$REPO_ROOT" ] && [[ "$CONTEXT_CANDIDATE" == "$REPO_ROOT/"* ]]; then
                CONTEXT_MD_ANCHOR="${CONTEXT_CANDIDATE#$REPO_ROOT/}"
              else
                CONTEXT_MD_ANCHOR="$CONTEXT_CANDIDATE"
              fi
            fi
            break
          fi
          ANCESTOR="$PARENT"
        done
        ;;
    esac

    # Read existing paths[] if marker exists; build the dedup'd new set
    EXISTING_PATHS_JSON='[]'
    if [ -f "$MARKER" ] && jq -e . "$MARKER" >/dev/null 2>&1; then
      EXISTING_PATHS_JSON=$(jq -c '.paths // []' "$MARKER" 2>/dev/null || echo '[]')
    fi

    NEW_PATHS_JSON=$(echo "$EXISTING_PATHS_JSON" | jq -c --arg p "$NORM" '
      if (index([$p]) // null) != null then .
      elif (. | index($p)) != null then .
      else . + [$p] end
    ')

    # Atomic temp+rename write per S3 pattern
    TMP="$MARKER.tmp.$$"
    if [ -n "$CONTEXT_MD_ANCHOR" ]; then
      jq -n \
        --arg sid "$SESSION_ID" \
        --argjson paths "$NEW_PATHS_JSON" \
        --arg expires "$EXPIRES_ISO" \
        --arg reason "$REASON" \
        --arg anchor "$CONTEXT_MD_ANCHOR" \
        '{session_id:$sid, paths:$paths, expires_at:$expires, reason:$reason, context_md_anchor:$anchor}' \
        > "$TMP" || { rm -f "$TMP"; echo "ERROR: jq failed to build marker JSON." >&2; exit 1; }
    else
      jq -n \
        --arg sid "$SESSION_ID" \
        --argjson paths "$NEW_PATHS_JSON" \
        --arg expires "$EXPIRES_ISO" \
        --arg reason "$REASON" \
        '{session_id:$sid, paths:$paths, expires_at:$expires, reason:$reason}' \
        > "$TMP" || { rm -f "$TMP"; echo "ERROR: jq failed to build marker JSON." >&2; exit 1; }
    fi
    mv "$TMP" "$MARKER"

    echo "Added $NORM → $MARKER (expires $EXPIRES_ISO; reason: $REASON)" >&2
    exit 0
    ;;

  clear)
    if [ -f "$MARKER" ]; then
      rm -f "$MARKER"
      echo "Cleared marker at $MARKER" >&2
    else
      echo "No marker present at $MARKER (already clear)" >&2
    fi
    exit 0
    ;;

  show)
    if [ -f "$MARKER" ]; then
      jq . "$MARKER"
      # Validity summary line — graceful degrade on missing expires_at
      EXP=$(jq -r '.expires_at // empty' "$MARKER" 2>/dev/null)
      if [ -n "$EXP" ]; then
        # Uses GNU date -d; portable across WSL2/Linux (project requirement); not POSIX-portable.
        EXP_EPOCH=$(date -u -d "$EXP" +%s 2>/dev/null || echo 0)
        NOW=$(date -u +%s)
        if [ "$EXP_EPOCH" -gt "$NOW" ]; then
          echo "# marker valid: expires_at $EXP (valid as of $(date -u +%Y-%m-%dT%H:%M:%SZ))" >&2
        else
          echo "# marker expired: expires_at $EXP (now $(date -u +%Y-%m-%dT%H:%M:%SZ))" >&2
        fi
      fi
    else
      echo "No marker present at $MARKER" >&2
    fi
    exit 0
    ;;
esac
