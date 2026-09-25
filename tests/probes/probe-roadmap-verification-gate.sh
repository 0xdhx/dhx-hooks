#!/usr/bin/env bash
# Probe: dhx-roadmap-verification-gate.sh — ROADMAP-[x] flip requires VERIFICATION.md.
#
# Invariant: a PreToolUse Write|Edit that flips a GSD phase to `- [x]` in
# .planning/ROADMAP.md is BLOCKED (exit 2) when that phase's dir under
# .planning/phases/ has no *-VERIFICATION.md (gsd-verifier did not run), and is
# ALLOWED (exit 0) when the artifact exists, when the edit is not a flip, when the
# target is not ROADMAP.md, for synthetic 999.* phases, and under the suppression
# env. Boundary-guarded so "Phase 1" never satisfies against "Phase 10"/"Phase 11"
# (D-31 anchor — the regex is lifted verbatim from the skills-repo sibling probe
# tests/probe-phase-verification-completeness.sh; this asserts the live-hook half).
#
#        Coupling: ~/repos/cross-repo/docs/coupling/2026-06-18-roadmap-verification-gate-probe.md
#
# How to run: bash tests/probes/probe-roadmap-verification-gate.sh
#
# SAFE_FOR_LIVE: yes   (every case builds a throwaway mktemp .planning tree and pipes
#                       a synthetic stdin envelope at the hook; the hook only READS
#                       that tree + the fixture file_path — never the live repo, the
#                       live .planning/, or ~/.claude state)
# RUNTIME: ~1s

set -uo pipefail

PROBE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$PROBE_DIR/../.." && pwd)
HOOK="$REPO_ROOT/dhx/dhx-roadmap-verification-gate.sh"

PASS=0
FAIL=0
ok()  { echo "OK   $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; FAIL=$((FAIL+1)); }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq absent — hook fails open by contract; cannot exercise behavior"
  echo "0 passed, 0 failed"
  exit 0
fi
[ -x "$HOOK" ] || { echo "FATAL: hook not executable: $HOOK" >&2; exit 99; }

TMP=$(mktemp -d) || { echo "FATAL: mktemp failed" >&2; exit 99; }
trap 'rm -rf "$TMP"' EXIT

# mkcase <space-separated phase dirs> — builds a fresh .planning tree, echoes ROADMAP path.
# Pass dirs WITH a trailing '+' to also drop a VERIFICATION.md inside (e.g. "09-foo+ 10-bar").
# Each call gets its OWN mktemp dir: mkcase runs inside $(...), a subshell, so a parent-scope
# counter would never advance here and every case would collide in one tree.
mkcase() {
  local root; root="$(mktemp -d -p "$TMP")/.planning"
  mkdir -p "$root/phases"
  local spec d dir
  for spec in $1; do
    case "$spec" in
      *+) dir="${spec%+}"; mkdir -p "$root/phases/$dir"; : > "$root/phases/$dir/${dir%%-*}-VERIFICATION.md" ;;
      *)  dir="$spec";     mkdir -p "$root/phases/$dir" ;;
    esac
  done
  : > "$root/ROADMAP.md"
  echo "$root/ROADMAP.md"
}

# run_edit <roadmap> <old_string> <new_string> [env]   -> sets RC
run_edit() {
  local roadmap="$1" old="$2" new="$3" env="${4:-}"
  local payload; payload=$(jq -n --arg f "$roadmap" --arg o "$old" --arg n "$new" \
    '{tool_name:"Edit",tool_input:{file_path:$f,old_string:$o,new_string:$n},session_id:"probe"}')
  RC=0; env $env bash "$HOOK" <<<"$payload" >/dev/null 2>&1 || RC=$?
}
# run_write <roadmap> <content> <ondisk> [env]   -> sets RC (writes <ondisk> to the file first)
run_write() {
  local roadmap="$1" content="$2" ondisk="$3" env="${4:-}"
  printf '%s\n' "$ondisk" > "$roadmap"
  local payload; payload=$(jq -n --arg f "$roadmap" --arg c "$content" \
    '{tool_name:"Write",tool_input:{file_path:$f,content:$c},session_id:"probe"}')
  RC=0; env $env bash "$HOOK" <<<"$payload" >/dev/null 2>&1 || RC=$?
}

# 1. Edit flip, VERIFICATION absent -> DENY (exit 2)
rm="$(mkcase "09-foo")"
run_edit "$rm" "- [ ] Phase 9: Foo" "- [x] Phase 9: Foo"
[ "$RC" -eq 2 ] && ok "Edit flip + no VERIFICATION.md -> deny (exit 2)" \
                || bad "Edit flip + no VERIFICATION.md should deny, got rc=$RC"

# 2. Edit flip, VERIFICATION present -> ALLOW (exit 0)
rm="$(mkcase "09-foo+")"
run_edit "$rm" "- [ ] Phase 9: Foo" "- [x] Phase 9: Foo"
[ "$RC" -eq 0 ] && ok "Edit flip + VERIFICATION.md present -> allow (exit 0)" \
                || bad "Edit flip + VERIFICATION.md should allow, got rc=$RC"

# 3. Edit non-flip (already [x] in old_string) -> ALLOW even with no VERIFICATION
rm="$(mkcase "09-foo")"
run_edit "$rm" "- [x] Phase 9: Foo old" "- [x] Phase 9: Foo new"
[ "$RC" -eq 0 ] && ok "Edit non-flip (was already [x]) -> allow (exit 0)" \
                || bad "Edit non-flip should allow, got rc=$RC"

# 4. Non-ROADMAP target -> ALLOW (basename gate, before any phase logic)
rm="$(mkcase "09-foo")"
notes="$(dirname "$rm")/NOTES.md"
run_edit "$notes" "- [ ] Phase 9: Foo" "- [x] Phase 9: Foo"
[ "$RC" -eq 0 ] && ok "Non-ROADMAP file (NOTES.md) -> allow (exit 0)" \
                || bad "Non-ROADMAP file should allow, got rc=$RC"

# 5. Boundary guard: flipping Phase 1 must check phase 1's OWN dir, not be satisfied
#    by Phase 10's VERIFICATION.  dir 01 has no VERIFICATION; dir 10 has one.
rm="$(mkcase "01-a 10-b+")"
run_edit "$rm" "- [ ] Phase 1: A" "- [x] Phase 1: A"
[ "$RC" -eq 2 ] && ok "Boundary: flip Phase 1 not satisfied by Phase 10's VERIFICATION -> deny" \
                || bad "Boundary 1-vs-10 should deny phase 1, got rc=$RC"

# 6. Boundary guard, inverse: flipping Phase 10 (has VERIFICATION) -> ALLOW, and the
#    unflipped Phase 1 (no VERIFICATION) must NOT be dragged in.
rm="$(mkcase "01-a 10-b+")"
run_edit "$rm" "- [ ] Phase 10: B" "- [x] Phase 10: B"
[ "$RC" -eq 0 ] && ok "Boundary: flip only Phase 10 (verified); Phase 1 not implicated -> allow" \
                || bad "Boundary 10-only flip should allow, got rc=$RC"

# 7. Boundary guard, sub-phase: "Phase 11" must not match "Phase 11.1".
#    dir 11 has VERIFICATION, dir 11.1 does not; flip Phase 11 only -> ALLOW.
rm="$(mkcase "11-x+ 11.1-y")"
run_edit "$rm" "- [ ] Phase 11: X" "- [x] Phase 11: X"
[ "$RC" -eq 0 ] && ok "Boundary: flip Phase 11 not confused with Phase 11.1 -> allow" \
                || bad "Boundary 11-vs-11.1 should allow phase 11, got rc=$RC"

# 8. Synthetic 999.* phase is skipped -> ALLOW even on flip + no VERIFICATION
rm="$(mkcase "999.1-scratch")"
run_edit "$rm" "- [ ] Phase 999.1: scratch" "- [x] Phase 999.1: scratch"
[ "$RC" -eq 0 ] && ok "Synthetic 999.1 phase skipped -> allow (exit 0)" \
                || bad "999.1 phase should be skipped, got rc=$RC"

# 9. Write whole-file flip, VERIFICATION absent -> DENY
rm="$(mkcase "09-foo")"
run_write "$rm" "# Roadmap"$'\n'"- [x] Phase 9: Foo" "# Roadmap"$'\n'"- [ ] Phase 9: Foo"
[ "$RC" -eq 2 ] && ok "Write flip (vs on-disk) + no VERIFICATION.md -> deny (exit 2)" \
                || bad "Write flip should deny, got rc=$RC"

# 10. Write whole-file, phase already [x] on disk and stays [x] -> ALLOW (not a flip)
rm="$(mkcase "09-foo")"
run_write "$rm" "# Roadmap"$'\n'"- [x] Phase 9: Foo" "# Roadmap"$'\n'"- [x] Phase 9: Foo"
[ "$RC" -eq 0 ] && ok "Write non-flip (already [x] on disk) -> allow (exit 0)" \
                || bad "Write non-flip should allow, got rc=$RC"

# 11. Suppression env -> ALLOW even on a deny-worthy flip
rm="$(mkcase "09-foo")"
run_edit "$rm" "- [ ] Phase 9: Foo" "- [x] Phase 9: Foo" "DHX_SKIP_ROADMAP_VERIFICATION_GATE=1"
[ "$RC" -eq 0 ] && ok "DHX_SKIP_ROADMAP_VERIFICATION_GATE=1 -> allow (exit 0)" \
                || bad "Suppression env should allow, got rc=$RC"

# 12. No sibling phases/ dir (non-GSD ROADMAP.md) -> ALLOW
solo="$TMP/solo"; mkdir -p "$solo"; : > "$solo/ROADMAP.md"
run_edit "$solo/ROADMAP.md" "- [ ] Phase 9: Foo" "- [x] Phase 9: Foo"
[ "$RC" -eq 0 ] && ok "ROADMAP.md with no sibling phases/ dir -> allow (exit 0)" \
                || bad "ROADMAP without phases/ should allow, got rc=$RC"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
