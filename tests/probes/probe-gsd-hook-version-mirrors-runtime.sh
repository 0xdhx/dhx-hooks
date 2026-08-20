#!/bin/bash
# Probe: dhx/statusline-wrapper.js `// gsd-hook-version:` marker MIRRORS the live
# gsd-core release version (~/.claude/gsd-core/VERSION). It is a reconciliation-
# lineage stamp, NOT a wrapper-content version — bumped only by /dhx:sym gsd-update
# step 9, never hand-incremented on a wrapper feature edit.
#
# Failure mode this guards (observed 2026-06-15): four successive sessions
# hand-bumped the marker on wrapper feature commits (36a59f7 -> 1.4.3,
# 24e4005 -> 1.4.4, ba63737 -> 1.4.5, 5bcce1f -> 1.4.6), treating it as a
# monotonic content version (24e4005 msg: "catches the version up to the live
# wrapper behavior"). The numbers tracked real gsd-core releases by COINCIDENCE
# (gsd-core was advancing through the same 1.4.x line) until 1.4.6 overshot —
# gsd-core's latest is 1.4.5, no 1.4.6 exists — surfacing the drift. The marker
# carried two silently-aliased meanings (lineage stamp vs content version) that
# only de-aliased once a hand-bump outran the real release. Canonical semantics:
# decisions.md 2026-05-09 ("tracks gsd canonical-version reconciliation lineage…
# NOT dhx-internal mod version; bumping here would falsify the lineage").
#
# Static checks (always run): the marker exists + carries the inline "do NOT
# hand-bump" guard comment naming /dhx:sym gsd-update (locks the guard so a
# future edit can't silently drop it). Live-resolve check (only when gsd-core is
# installed): marker == live VERSION — catches the NEXT hand-bump at pre-commit,
# before the next gsd-update would otherwise be the first to notice.
#
# Backs decisions.md 2026-06-15 "gsd-hook-version marker drift — revert + guard" row.
# Run: bash tests/probes/probe-gsd-hook-version-mirrors-runtime.sh
# SAFE_FOR_LIVE: yes   (grep-only against in-repo wrapper + read-only cat of live ~/.claude/gsd-core/VERSION; no writes)
# LIVE_RUNTIME: yes  (reds on EVERY gsd-core release by design (reconciliation forcing-function); cleared by a one-line marker bump)
# LIVE_SUBJECT: dhx/statusline-wrapper.js
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WRAPPER="$REPO_ROOT/dhx/statusline-wrapper.js"

pass=0
fail=0
assert() {
  local name="$1" cond="$2"
  if eval "$cond"; then echo "OK   $name"; pass=$((pass+1));
  else echo "FAIL $name"; fail=$((fail+1)); fi
}

# --- Static: the marker exists and carries the inline anti-hand-bump guard ---
MARKER_VER="$(grep -m1 -E '^// gsd-hook-version:' "$WRAPPER" | sed -E 's|^// gsd-hook-version:[[:space:]]*||' || true)"
assert "wrapper carries a gsd-hook-version marker"                "[ -n \"\$MARKER_VER\" ]"
assert "inline guard comment present (do NOT hand-bump)"          "grep -qi 'do NOT hand-bump' \"\$WRAPPER\""
assert "inline guard names the canonical bumper (sym gsd-update)" "grep -q 'sym gsd-update' \"\$WRAPPER\""

# --- Live-resolve: only when gsd-core is installed (VERSION is the marker) ---
LIVE_VERSION_FILE="$HOME/.claude/gsd-core/VERSION"
if [[ -f "$LIVE_VERSION_FILE" ]]; then
  LIVE_VER="$(tr -d '[:space:]' < "$LIVE_VERSION_FILE")"
  assert "marker ($MARKER_VER) == live gsd-core VERSION ($LIVE_VER)" "[ \"\$MARKER_VER\" = \"\$LIVE_VER\" ]"
else
  echo "SKIP live-mirror check — gsd-core not installed (no $LIVE_VERSION_FILE)"
fi

echo ""
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
