#!/usr/bin/env bash
# probe-backlog-vocab-check.sh
#
# Regression probe for dhx/dhx-backlog-vocab-check.sh.
#
# Invariants:
#   1. Non-canonical target_milestone in a top-level .planning/backlog/*.md
#      brief fires a dual-channel advisory and exits 0:
#        - stderr ⚠ headline + indented detail (terminal-visible per HP-038)
#        - stdout JSON {hookSpecificOutput:{hookEventName:"PostToolUse",
#          additionalContext:<full advisory text>}} (Claude-inline-visible
#          per HP-039)
#   2. Canonical target_milestone (declared version, unscoped, next+N, post-N)
#      is silent on BOTH stdout and stderr and exits 0.
#   3. Writes outside .planning/backlog/ are skipped silently (both channels)
#      by the path gate.
#   4. Writes into terminal subdirs (rejected/, shipped/, superseded/) are
#      skipped silently (both channels) — re-classifying a brief must NOT
#      fire the gate even when the brief carries a non-canonical literal.
#
# write-time advisory row + .planning/backlog/2026-05-09-backlog-target-
# milestone-validation-hook.md + reports/2026-05-09-backlog-target-milestone-
# validation-hook.md.
#
# Run: bash tests/probes/probe-backlog-vocab-check.sh

# SAFE_FOR_LIVE: yes  (runs entirely in mktemp; no live planning-tree mutation)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$REPO_ROOT/dhx/dhx-backlog-vocab-check.sh"
REGEN="${DHX_TOOLS:-$HOME/.claude/dhx-tools}/backlog-regen.cjs"

for f in "$HOOK" "$REGEN"; do
  if [[ ! -r "$f" ]]; then
    echo "FAIL required file not readable: $f"
    exit 1
  fi
done

PASS=0
FAIL=0

check() {
  local label="$1"
  local ok="$2"
  if [[ "$ok" == "1" ]]; then
    echo "OK   $label"
    PASS=$((PASS+1))
  else
    echo "FAIL $label"
    FAIL=$((FAIL+1))
  fi
}

# --- Fixture: throwaway repo with a declared v1.0 milestone ---
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/.planning/backlog/rejected"
cat > "$TMP/.planning/MILESTONES.md" <<'EOF'
# Milestones

## v1.0 — Foundations
shipped
EOF
cat > "$TMP/.planning/STATE.md" <<'EOF'
**Current milestone:** v1.0 — Foundations
EOF
( cd "$TMP" && git init -q && git add -A && git commit -q -m init ) >/dev/null 2>&1

emit_input() {
  local path="$1"
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$path"
}

run_hook() {
  local path="$1"
  local stderr_file stdout_file
  stderr_file=$(mktemp)
  stdout_file=$(mktemp)
  local rc
  emit_input "$path" | bash "$HOOK" >"$stdout_file" 2>"$stderr_file"
  rc=$?
  STDERR=$(cat "$stderr_file")
  STDOUT=$(cat "$stdout_file")
  rm -f "$stderr_file" "$stdout_file"
  RC=$rc
}

# --- Scenario 1: non-canonical target_milestone fires advisory ---
BAD="$TMP/.planning/backlog/2026-05-27-bad.md"
cat > "$BAD" <<'EOF'
---
created: 2026-05-27
title: Bad
target_milestone: v9.99
status: captured
---
body
EOF
run_hook "$BAD"
if [[ "$RC" == "0" ]]; then
  check "non-canonical brief: exit 0 (advisory, not blocking)" 1
else
  check "non-canonical brief: exit 0 (got $RC)" 0
fi
if [[ "$STDERR" == *"⚠ backlog-vocab"* ]] && [[ "$STDERR" == *"non-canonical"* ]] && [[ "$STDERR" == *"2026-05-27-bad.md"* ]]; then
  check "non-canonical brief: stderr carries ⚠ advisory + basename + 'non-canonical'" 1
else
  check "non-canonical brief: stderr missing expected advisory shape — got: $STDERR" 0
fi
# stdout JSON additionalContext envelope (HP-039 — Claude-inline-visible channel)
if printf '%s' "$STDOUT" | jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' >/dev/null 2>&1 \
   && printf '%s' "$STDOUT" | jq -e '.hookSpecificOutput.additionalContext | tostring | contains("⚠ backlog-vocab")' >/dev/null 2>&1 \
   && printf '%s' "$STDOUT" | jq -e '.hookSpecificOutput.additionalContext | tostring | contains("2026-05-27-bad.md")' >/dev/null 2>&1; then
  check "non-canonical brief: stdout JSON hookSpecificOutput.additionalContext carries advisory (HP-039)" 1
else
  check "non-canonical brief: stdout JSON missing/malformed — got: $STDOUT" 0
fi

# --- Scenario 2: canonical target_milestone is silent ---
GOOD="$TMP/.planning/backlog/2026-05-27-good.md"
cat > "$GOOD" <<'EOF'
---
created: 2026-05-27
title: Good
target_milestone: v1.0
status: captured
---
body
EOF
run_hook "$GOOD"
if [[ "$RC" == "0" ]] && [[ -z "$STDERR" ]] && [[ -z "$STDOUT" ]]; then
  check "canonical brief: silent on both channels + exit 0" 1
else
  check "canonical brief: expected silent exit 0, got rc=$RC stderr='$STDERR' stdout='$STDOUT'" 0
fi

# --- Scenario 3: non-backlog path is skipped by path gate ---
OTHER="$TMP/some/random/file.js"
mkdir -p "$(dirname "$OTHER")"
echo "console.log('x')" > "$OTHER"
run_hook "$OTHER"
if [[ "$RC" == "0" ]] && [[ -z "$STDERR" ]] && [[ -z "$STDOUT" ]]; then
  check "non-backlog path: silent on both channels + exit 0 (path gate early-exit)" 1
else
  check "non-backlog path: expected silent exit 0, got rc=$RC stderr='$STDERR' stdout='$STDOUT'" 0
fi

# --- Scenario 4: terminal subdir (rejected/) skipped even with bad value ---
REJ="$TMP/.planning/backlog/rejected/2026-05-27-bad-rejected.md"
cat > "$REJ" <<'EOF'
---
created: 2026-05-27
title: Rejected bad
target_milestone: v9.99
status: captured
---
body
EOF
run_hook "$REJ"
if [[ "$RC" == "0" ]] && [[ -z "$STDERR" ]] && [[ -z "$STDOUT" ]]; then
  check "rejected/ subdir: silent on both channels + exit 0 (re-classification must not fire)" 1
else
  check "rejected/ subdir: expected silent exit 0, got rc=$RC stderr='$STDERR' stdout='$STDOUT'" 0
fi

# Defense-in-depth: also verify shipped/ and superseded/ skip silently when bad.
for sub in shipped superseded; do
  mkdir -p "$TMP/.planning/backlog/$sub"
  TPATH="$TMP/.planning/backlog/$sub/2026-05-27-bad.md"
  cat > "$TPATH" <<'EOF'
---
target_milestone: v9.99
status: captured
---
EOF
  run_hook "$TPATH"
  if [[ "$RC" == "0" ]] && [[ -z "$STDERR" ]] && [[ -z "$STDOUT" ]]; then
    check "$sub/ subdir: silent on both channels + exit 0" 1
  else
    check "$sub/ subdir: expected silent exit 0, got rc=$RC stderr='$STDERR' stdout='$STDOUT'" 0
  fi
done

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]
