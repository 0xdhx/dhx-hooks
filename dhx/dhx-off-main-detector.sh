#!/usr/bin/env bash
# dhx-off-main-detector.sh — SessionStart hook
# Patterns: HP-009, HP-015, HP-017
# Phase 14 DETECT-01 — cross-repo shared-tree off-main warning layer.
# Warns once per boot when cross-repo PRIMARY checkout is off main.
# Debounced via /tmp atomic marker. Non-blocking (exit 0 always).
# First hook to source dhx-shared/lib/git-safe.sh.

set -uo pipefail

PRIMARY="$HOME/repos/cross-repo"
REQUIRED_BRANCH="main"

# D-3: Literal-first + fail-silent source. cc-switcher breaks the 3-tier;
# only the literal $HOME/.claude/dhx-shared symlink resolves.
SRC="$HOME/.claude/dhx-shared/lib/git-safe.sh"
[[ -f "$SRC" ]] || exit 0
# shellcheck source=/dev/null
source "$SRC" 2>/dev/null || exit 0
git_safe_require_version "1.1" 2>/dev/null || exit 0

# D-8: Predicate FIRST; short-circuit when not exit-20. Debounces warnings,
# not checks. D-11: no errexit brackets around the predicate call;
# `set -uo pipefail` alone is sufficient for rc capture.
is_primary_off_main "$PRIMARY" "$REQUIRED_BRANCH" 2>/dev/null
rc=$?
[[ "$rc" -eq "$GIT_SAFE_EX_OFF_MAIN" ]] || exit 0

# D-6: Atomic per-boot debounce — single-syscall atomic create; only the
# winning racer emits. Runs AFTER the short-circuit (D-8).
MARKER_KEY=$(printf '%s' "$PRIMARY" | md5sum | cut -d' ' -f1)
MARKER="/tmp/dhx-off-main-warn-${MARKER_KEY}"
mkdir "$MARKER" 2>/dev/null || exit 0

# D-11: Literal heredoc (`<<'EOF'`) — no interpolation. 'main' baked in
# as a string literal. Closes T-14-04 output-injection surface.
cat <<'EOF'
WARNING: cross-repo primary checkout is OFF 'main'. Write surfaces
(capture driver, /dhx:report, upstream wiring) will refuse to commit until the
primary is restored. To recover, see cross-repo CLAUDE.md "Concurrent sessions
(shared working trees)": fast-forward main with a pointer-only branch -f, then
isolate the feature branch via git worktree add. Do NOT 'git checkout main' on
the primary — that moves the shared HEAD for every concurrent session.
EOF

exit 0
