#!/usr/bin/env bash
# dhx-gsd-secret-guard-watch.sh — SessionStart child. Watches the ONE third-party guard
# the secret-file class depends on, and speaks ONCE PER NEW STATE (not once per session).
# Patterns: HP-009 (exit 2 blocks / exit 1 does not — this never blocks, always exits 0),
#           HP-012 (settings.json registration hot-reloads, so the live file is the truth)
#
# --- Why this file exists ---
# Two guards split the credential surface and only one of them is ours:
#   dhx-key-read-guard.js   — SSH private keys + AWS credentials, on Read|Grep|Bash.
#                             Ours, sha-pinned, deliberately detached from /gsd:update.
#   gsd-secret-read-guard.js — the SECRET-FILE class, on Read|Grep|Bash. GSD's. Vendored
#                             by /gsd:update, which replaces it wholesale, and registered
#                             in the live settings.json rather than the dhx plugin manifest.
# The permissions deny list names the secret-file class on the READ tool only, and since
# CC 2.1.273 removed the `denyRulesUnjudged` circuit a Read() deny is defeated by a path
# the model builds at runtime anyway. So on the BASH path — `cat`, `grep`, a heredoc, a
# subshell — the GSD guard is not the belt-and-braces layer. It is the only layer.
# Nothing watched whether it still existed, was still registered, or still fired.
#
# `scripts/vendor-dhx-key-read-guard.py` asserts a sha, but asserts it about the parser it
# COPIED, at the moment of copying: provenance of the copy, not liveness of the original.
# A guard deleted or narrowed by a later /gsd:update passes that assertion trivially,
# because the assertion is not running.
#
# --- What this checks, and what each check can actually fail ---
#   1. PRESENT     — the guard file exists. /gsd:update dropping it is the loud case.
#   2. REGISTERED  — the live settings.json (resolved through $CLAUDE_CONFIG_DIR, never
#                    the possibly-inactive ~/.claude copy) still routes PreToolUse to it.
#   3. MATCHER     — the matcher still covers Bash. This is the QUIET case and the reason
#                    a presence check alone would not have been enough: a matcher narrowed
#                    from `Read|Grep|Bash` to `Read` leaves the file present, the sha
#                    unchanged, every disk-level check green, and the Bash path bare.
#   4. SHA         — the bytes match the recorded baseline. A changed sha is not by itself
#                    a defect; it means "third-party security code changed under you, go
#                    re-run the behavioural probe and re-record deliberately".
#   5. INTERPRETERS — every absolute `/.../bin/node` pinned anywhere in the live settings
#                    file still exists and is executable. The GSD hooks hard-pin nvm
#                    versions (v22.22.2, v24.14.1 as of 2026-09-20); `nvm uninstall` or an
#                    `nvm prune` removes the directory and every hook registered through it
#                    STOPS EXECUTING SILENTLY. Nothing else watches this.
#                    SCOPE NOTE, because this is wider than the file name suggests: the
#                    interpreter is a precondition for the very guard this file watches —
#                    it is invoked through `gsd-node-runner.sh <abs-node> <guard>` — so the
#                    check would be needed here even if it covered nothing else. Having read
#                    the settings file already for check 2, enumerating the rest is free.
#                    MATCHED ANYWHERE IN THE COMMAND, not just at the front: the secret
#                    guard's own node path is the runner's FIRST ARGUMENT, not the command's
#                    first token, so a leading-token scan would miss precisely the one that
#                    matters most here.
#
# --- What this CANNOT check, stated so the green is not over-read ---
# None of the four proves CC actually ROUTES a PreToolUse event into the guard in this
# process. Registration is a declaration; routing is behaviour. Only firing the guard and
# observing the refusal covers that, which is tests/probes/probe-gsd-secret-guard-watch.sh
# § LIVE BEHAVIOURAL arms — and even those prove the guard refuses WHEN INVOKED, not that
# CC invokes it. A sha match proves bytes, never wiring. Do not let this child retire the
# behavioural probe.
#
# --- Once per NEW STATE, not once per session ---
# The state digest covers presence + registration + matcher + sha. A `mkdir` on the digest
# is the atomic test-and-set (same idiom as the dispatcher's child-failure first-sight).
# A steady bad state therefore speaks once and then stops, and a RETURN to a previously
# seen state is silent too — which is correct: the operator already saw that state, and a
# watcher that re-narrates every session is a watcher that gets suppressed.
# The GOOD state is recorded but never spoken.
#
# Suppression: DHX_SKIP_GSD_GUARD_WATCH=1
# Fixture hooks (probe-only): DHX_GSD_GUARD_PATH, DHX_GSD_GUARD_BASELINE,
#                             DHX_GSD_GUARD_SETTINGS, DHX_HOOKS_CACHE_DIR

set -uo pipefail   # NOT -e: a watcher must never break the dispatcher chain

[ "${DHX_SKIP_GSD_GUARD_WATCH:-0}" = "1" ] && exit 0
cat >/dev/null 2>&1   # drain stdin; nothing here is session-scoped
command -v jq >/dev/null 2>&1 || exit 0

GUARD="${DHX_GSD_GUARD_PATH:-$HOME/.claude/hooks/gsd-secret-read-guard.js}"
BASELINE="${DHX_GSD_GUARD_BASELINE:-$HOME/repos/hooks/config/gsd-secret-guard-baseline.json}"
SETTINGS="${DHX_GSD_GUARD_SETTINGS:-$(readlink -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" 2>/dev/null)}"
CACHE_ROOT="${DHX_HOOKS_CACHE_DIR:-$HOME/.cache/dhx/hooks}"

[ -r "$BASELINE" ] || exit 0   # no baseline -> nothing to compare against; silent
EXPECT_SHA=$(jq -r '.sha256_16 // empty' "$BASELINE" 2>/dev/null || true)
BASENAME=$(jq -r '.guard_basename // empty' "$BASELINE" 2>/dev/null || true)
[ -n "$EXPECT_SHA" ] && [ -n "$BASENAME" ] || exit 0

# 1. present + 4. sha
PRESENT=no; SHA=none
if [ -f "$GUARD" ]; then
  PRESENT=yes
  if command -v sha256sum >/dev/null 2>&1; then SHA=$(sha256sum "$GUARD" 2>/dev/null | cut -c1-16)
  elif command -v shasum  >/dev/null 2>&1; then SHA=$(shasum -a 256 "$GUARD" 2>/dev/null | cut -c1-16)
  fi
  [ -n "$SHA" ] || SHA=unreadable
fi

# 2. registered + 3. matcher. Read the LIVE settings file, and read the MATCHERS of the
# entries that actually name this guard — not merely whether the string occurs somewhere.
MATCHER=""
if [ -n "${SETTINGS:-}" ] && [ -r "$SETTINGS" ]; then
  MATCHER=$(jq -r --arg b "$BASENAME" '
      [ .hooks.PreToolUse // [] | .[]
        | select( any(.hooks[]?.command // ""; contains($b)) )
        | .matcher // "*" ] | unique | join(",")' "$SETTINGS" 2>/dev/null || true)
fi
REGISTERED=no; [ -n "$MATCHER" ] && REGISTERED=yes

# Bash coverage: `*` counts (it matches every tool), otherwise the token must appear.
COVERS_BASH=no
case "$MATCHER" in
  *'*'*)    COVERS_BASH=yes ;;
  *Bash*)   COVERS_BASH=yes ;;
esac

# 5. pinned interpreters. Any absolute path ending in /bin/node, wherever it appears in a
# registered hook command. Sorted+deduped so the state digest is stable across jq ordering.
MISSING_NODES=""
if [ -n "${SETTINGS:-}" ] && [ -r "$SETTINGS" ]; then
  for n in $(jq -r '[.hooks[]?[]?.hooks[]?.command // ""] | join("\n")' "$SETTINGS" 2>/dev/null \
               | grep -oE '/[^"'"'"'[:space:]]*/bin/node' | sort -u); do
    [ -x "$n" ] || MISSING_NODES="$MISSING_NODES $n"
  done
fi
MISSING_NODES="${MISSING_NODES# }"

HEALTHY=no
if [ "$PRESENT" = yes ] && [ "$REGISTERED" = yes ] && [ "$COVERS_BASH" = yes ] \
   && [ "$SHA" = "$EXPECT_SHA" ] && [ -z "$MISSING_NODES" ]; then HEALTHY=yes; fi

# --- once per NEW state ---
STATE="present=$PRESENT;registered=$REGISTERED;matcher=$MATCHER;bash=$COVERS_BASH;sha=$SHA;nodes=$MISSING_NODES"
if command -v sha256sum >/dev/null 2>&1; then STATE_KEY=$(printf '%s' "$STATE" | sha256sum | cut -c1-16)
else STATE_KEY=$(printf '%s' "$STATE" | cksum | tr -d ' /'); fi
SEEN_DIR="$CACHE_ROOT/gsd-secret-guard-watch"
mkdir -p "$SEEN_DIR" 2>/dev/null || exit 0
mkdir "$SEEN_DIR/$STATE_KEY" 2>/dev/null || exit 0   # state already seen -> silent
[ "$HEALTHY" = yes ] && exit 0                       # good state: recorded, never spoken

# --- speak (stderr; the dispatcher captures and replays it) ---
{
  echo "GSD secret-read guard — state changed, and it is the only cover for the secret-file class on the Bash path."
  [ "$PRESENT"    = no  ] && echo "  ABSENT:       $GUARD does not exist. /gsd:update most likely removed it."
  [ "$PRESENT"    = yes ] && [ "$REGISTERED" = no ] && \
    echo "  UNREGISTERED: the file exists but no PreToolUse entry in ${SETTINGS:-<unresolved settings>} names it."
  [ "$REGISTERED" = yes ] && [ "$COVERS_BASH" = no ] && \
    echo "  BASH UNCOVERED: registered on matcher '$MATCHER', which does not include Bash. The file and its sha look fine; the Bash path is not guarded."
  [ "$PRESENT" = yes ] && [ "$SHA" != "$EXPECT_SHA" ] && [ "$SHA" != unreadable ] && \
    echo "  SHA CHANGED:  $SHA, baseline $EXPECT_SHA. Third-party security code changed under you."
  [ -n "$MISSING_NODES" ] && \
    echo "  INTERPRETER GONE: $MISSING_NODES -- pinned in the live settings file but not executable. Every hook registered through it, security guards included, silently stops running. Usual cause: nvm uninstall or nvm prune."
  echo "  Consequence: secret-file reads issued through Bash (cat, grep, a heredoc, a subshell) are unguarded. dhx-key-read-guard.js still covers SSH keys and AWS credentials; it does NOT cover the secret-file class."
  echo "  The permissions deny list is not a fallback here: it names that class on the Read tool only, and since CC 2.1.273 a Read() deny is defeated by a runtime-constructed path."
  echo "  Do: bash ~/repos/hooks/tests/probes/probe-gsd-secret-guard-watch.sh   (fires the LIVE guard; a sha match proves bytes, not that it still refuses)"
  echo "  Then re-record deliberately: ~/repos/hooks/config/gsd-secret-guard-baseline.json"
  echo "  Silent from here until the state changes again."
} >&2
exit 0
