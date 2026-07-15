#!/bin/bash
# Probe: the hardcoded gsd-runtime path constants track the live gsd install
# dir name. Six surfaces hardcode it:
#   - dhx/statusline-wrapper.js          GSD_LIVE_ROOT / GSD_FORK_ROOT (drift detection)
#   - dhx/dhx-health-check.sh            symlink-checklist `for item in ...` loop
#   - dhx/dhx-gsd-canonical-mirror-gate.sh  GSD_LIVE_ROOT write-protection subtree
#   - dhx/dhx-gsd-drift-surface.sh       cp repair-command paths
#   - scripts/dhx-gsd-triad.sh           LIVE_ROOT/CANONICAL_ROOT defaults + rel-strip dialect
#   - scripts/dhx-draft-buffer.sh        canonical path-dialect normalizer
# The first two were fixed 2026-06-05 (the user-visible follow-ups); the latter
# four are the silently-broken tail migrated by the 2026-06-05 follow-up brief.
#
# Failure mode this guards (observed 2026-06-05): `@opengsd/gsd-core@1.3.1`
# renamed `~/.claude/get-shit-done/` -> `~/.claude/gsd-core/` and migrated the
# fork mirror to `gsd-local-patches/gsd-core/`. The stale `get-shit-done`
# literals were SILENT — health-check counted a permanently-missing dir (false
# `patches:DRIFT 1 broken symlink`), and scanRecursive(missing dir) returned
# gsd_mtime/count=0 so the statusline gsd drift trigger never fired (dead, no
# error). A future rename does the same. This is NOT hermetically guardable from
# the consumer side — the existing probe-gsd-fork-aware-drift.sh exercises the
# mechanism with OVERRIDE roots, so it can't catch a stale DEFAULT.
#
# Static checks (always run): the source literals name `gsd-core`, not the
# retired `get-shit-done`. Live-resolve checks (only when gsd is installed):
# the named live root + fork mirror actually exist — catches the NEXT rename
# (source still names the old dir, live dir moved -> red).
#
# Backs decisions.md 2026-06-05 "gsd-core 1.3.1 rename — hooks follow-ups" row
# AND the 2026-06-05 "gsd-core runtime-surface migration tail" row (4 surfaces).
# Run: bash tests/probes/probe-gsd-roots-resolve.sh
# SAFE_FOR_LIVE: yes   (grep-only against in-repo source + read-only dir-exists checks on live ~/.claude; no writes)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WRAPPER="$REPO_ROOT/dhx/statusline-wrapper.js"
HEALTH="$REPO_ROOT/dhx/dhx-health-check.sh"

pass=0
fail=0
assert() {
  local name="$1" cond="$2"
  if eval "$cond"; then echo "OK   $name"; pass=$((pass+1));
  else echo "FAIL $name"; fail=$((fail+1)); fi
}

# --- Static: source literals name the live gsd dir, not the retired name ---
LIVE_LINE="$(grep -nE 'const GSD_LIVE_ROOT' "$WRAPPER" || true)"
FORK_LINE="$(grep -nE 'const GSD_FORK_ROOT' "$WRAPPER" || true)"
HEALTH_LOOP="$(grep -nE '^for item in .* hooks ' "$HEALTH" || true)"

assert "statusline GSD_LIVE_ROOT names 'gsd-core'"            "echo \"\$LIVE_LINE\" | grep -q \"'gsd-core'\""
assert "statusline GSD_LIVE_ROOT drops retired 'get-shit-done'" "! echo \"\$LIVE_LINE\" | grep -q 'get-shit-done'"
assert "statusline GSD_FORK_ROOT names 'gsd-local-patches','gsd-core'" "echo \"\$FORK_LINE\" | grep -q \"'gsd-local-patches', 'gsd-core'\""
assert "statusline GSD_FORK_ROOT drops retired 'get-shit-done'" "! echo \"\$FORK_LINE\" | grep -q 'get-shit-done'"
assert "health-check checklist names 'gsd-core'"              "echo \"\$HEALTH_LOOP\" | grep -q 'gsd-core'"
assert "health-check checklist drops retired 'get-shit-done'" "! echo \"\$HEALTH_LOOP\" | grep -q 'get-shit-done'"

# --- Static: the 2026-06-05 tail — four runtime surfaces. Target the SPECIFIC
#     load-bearing literal on each, never the whole file: the gate + triad carry
#     intentional "renamed get-shit-done → gsd-core" rename-note comments, so a
#     whole-file negative grep would false-fail. The staleness these guard is
#     SILENT — the gate would guard a missing dir (write-protection gap), the
#     triad/draft-buffer/drift-surface would resolve wrong paths with no error. ---
GATE="$REPO_ROOT/dhx/dhx-gsd-canonical-mirror-gate.sh"
DRIFT_SURFACE="$REPO_ROOT/dhx/dhx-gsd-drift-surface.sh"
TRIAD="$REPO_ROOT/scripts/dhx-gsd-triad.sh"
DRAFT_BUFFER="$REPO_ROOT/scripts/dhx-draft-buffer.sh"

# Gate: the GSD_LIVE_ROOT assignment (not the rename-note comment).
GATE_ROOT_LINE="$(grep -nE '^GSD_LIVE_ROOT=' "$GATE" || true)"
assert "gate GSD_LIVE_ROOT names 'gsd-core'"                "echo \"\$GATE_ROOT_LINE\" | grep -q 'gsd-core'"
assert "gate GSD_LIVE_ROOT drops retired 'get-shit-done'"   "! echo \"\$GATE_ROOT_LINE\" | grep -q 'get-shit-done'"

# Gate prefix-managed arms (2026-07-15 widen): the case arms MUST track
# gsd-core's GSD_PREFIX_MANAGED_DIRS contract (gsd-tools.cjs — agents/skills/
# commands iterated with startsWith('gsd-')). A dropped or renamed arm silently
# reopens the agents/-blind-spot class: the write passes the case-check with no
# error. Grep the case-arm PATTERNS (quoted literals), not comments.
for dir in agents skills commands; do
  GATE_ARM_COUNT="$(grep -cF "\"\$HOME/.claude/$dir/gsd-\"*" "$GATE" || true)"
  assert "gate guards prefix-managed arm '$dir/gsd-*'" "[ \"$GATE_ARM_COUNT\" -ge 1 ]"
done

# Drift-surface: the cp repair-command printf line.
DRIFT_CP_LINE="$(grep -nF 'printf '\''  cp ~/.claude/' "$DRIFT_SURFACE" || true)"
assert "drift-surface cp command names 'gsd-core'"          "echo \"\$DRIFT_CP_LINE\" | grep -q 'gsd-core'"
assert "drift-surface cp command drops 'get-shit-done'"     "! echo \"\$DRIFT_CP_LINE\" | grep -q 'get-shit-done'"

# Triad: the root defaults AND the rel-strip dialect (both load-bearing per D-32).
TRIAD_ROOT_LINES="$(grep -nE '^(LIVE_ROOT|CANONICAL_ROOT)=' "$TRIAD" || true)"
TRIAD_STRIP_NEW="$(grep -cF 'rel#gsd-core/' "$TRIAD" || true)"
TRIAD_STRIP_OLD="$(grep -cF 'rel#get-shit-done/' "$TRIAD" || true)"
assert "triad LIVE/CANONICAL roots name 'gsd-core'"         "echo \"\$TRIAD_ROOT_LINES\" | grep -q 'gsd-core'"
assert "triad roots drop retired 'get-shit-done'"           "! echo \"\$TRIAD_ROOT_LINES\" | grep -q 'get-shit-done'"
assert "triad rel-strip dialect is 'gsd-core/' (both sites)" "[ \"\$TRIAD_STRIP_NEW\" -eq 2 ]"
assert "triad rel-strip drops 'get-shit-done/'"             "[ \"\$TRIAD_STRIP_OLD\" -eq 0 ]"

# Draft-buffer: fully migrated — no rename-note comment, so whole-file is valid.
DRAFT_PREPEND="$(grep -cF 'gsd-core/$input' "$DRAFT_BUFFER" || true)"
assert "draft-buffer prepends canonical 'gsd-core/'"        "[ \"\$DRAFT_PREPEND\" -ge 1 ]"
assert "draft-buffer drops retired 'get-shit-done'"         "! grep -q 'get-shit-done' \"$DRAFT_BUFFER\""

# --- Live-resolve: only when gsd is installed (manifest is a stable marker) ---
LIVE_ROOT="$HOME/.claude/gsd-core"
FORK_PARENT="$HOME/.claude/gsd-local-patches"
FORK_ROOT="$FORK_PARENT/gsd-core"

if [[ -e "$HOME/.claude/gsd-file-manifest.json" ]]; then
  assert "live gsd runtime dir resolves ($LIVE_ROOT)" "[[ -d \"$LIVE_ROOT\" ]]"
  # Prefix-managed arms point at a real population (catches a gsd-side layout
  # move: arm still matches the OLD path while the live files migrated →
  # gate silently guards nothing there). agents/ and skills/ are always
  # populated on an installed gsd; commands/ is profile-staged (may be empty),
  # so it gets no live-population assertion.
  assert "live agents/gsd-* population exists" "compgen -G \"$HOME/.claude/agents/gsd-*\" >/dev/null"
  assert "live skills/gsd-* population exists" "compgen -G \"$HOME/.claude/skills/gsd-*\" >/dev/null"
  # Fork mirror is optional infrastructure; only assert if the fork tree exists.
  if [[ -d "$FORK_PARENT" ]]; then
    assert "live fork mirror resolves ($FORK_ROOT)" "[[ -d \"$FORK_ROOT\" ]]"
  else
    echo "SKIP live fork-mirror check — gsd-local-patches/ absent (no fork system)"
  fi
else
  echo "SKIP live-resolve checks — gsd not installed (no ~/.claude/gsd-file-manifest.json)"
fi

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
