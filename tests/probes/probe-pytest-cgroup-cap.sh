#!/usr/bin/env bash
# probe-pytest-cgroup-cap.sh
#
# Deterministic regression probe for dhx/dhx-pytest-cgroup-cap.sh (DHX-7
# mid-session pytest OOM cap). Covers, with NO real systemd-run invocation:
#   - classifier — pytest-as-command (positive) vs pytest-as-argument (negative)
#   - rewrite shape — systemd-run --user --scope + MemoryMax + MemorySwapMax=0,
#     the ORIGINAL command preserved inside `bash -c '…'`, NO RuntimeMaxSec by
#     default (memory-only)
#   - quoting — a single-quoted -k expression survives (rewrite parses + the
#     reconstructed inner argv is byte-identical to the original)
#   - config — DHX_PYTEST_CAP_MEM overrides the ceiling; DHX_PYTEST_CAP_RUNTIME
#     opts a runtime cap back in
#   - fail-open — empty command / bad JSON / already-wrapped / host lacks
#     systemd-run  → emits {} (run unchanged)
#
# The cap actually FIRING (exit 137 on a real memory-hungry pytest) is the
# companion e2e probe (probe-pytest-cgroup-cap-e2e.sh, SAFE_FOR_LIVE: no).
#
# Backs:
#   - docs/decisions.md — 2026-06-30 DHX-7 mid-session pytest cgroup-cap row
#   - docs/hook-patterns.md — HP-003 (PreToolUse:Bash fires for subagent calls),
#     HP-041 (updatedInput rewrite), HP-045 (cgroup MemoryMax → 137)
#   - .planning/backlog/shipped/2026-06-30-test-gate-cgroup-cap-mid-session-pytest-oom-design.md
#
# Run: bash tests/probes/probe-pytest-cgroup-cap.sh
#
# SAFE_FOR_LIVE: yes  (no real systemd-run: a PATH stub satisfies the
#                      availability check so only the rewritten STRING is
#                      asserted, never executed; fixtures + stub bins live under
#                      a per-run mktemp dir; never reads/writes live ~/.cache/dhx,
#                      ~/.claude, or any user systemd state.)
# RUNTIME: ~1s

set -u

HOOK="/home/dhx/repos/hooks/dhx/dhx-pytest-cgroup-cap.sh"
TMP=$(mktemp -d /tmp/probe-pytest-cgroup-cap.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

# --- Stub PATH where dhx_cgroup_available() returns true (no real systemd). ---
AVAIL_BIN="$TMP/avail-bin"
mkdir -p "$AVAIL_BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$AVAIL_BIN/systemd-run"
printf '#!/usr/bin/env bash\nexit 0\n' > "$AVAIL_BIN/systemctl"
chmod +x "$AVAIL_BIN/systemd-run" "$AVAIL_BIN/systemctl"

# --- Stub PATH WITHOUT systemd-run (mirrors host tools, omits the one binary)
# so dhx_cgroup_available() returns false → fail-open. ---
NO_SYSTEMD_BIN="$TMP/no-systemd-bin"
mkdir -p "$NO_SYSTEMD_BIN"
for tool in jq bash sh sed grep tr cat env dirname printf head tail awk cut; do
  resolved=$(command -v "$tool" 2>/dev/null) || continue
  ln -sf "$resolved" "$NO_SYSTEMD_BIN/$tool"
done   # deliberately NOT linking systemd-run

# run_hook CMD_JSON [extra-env KEY=VAL ...] — fires the hook with the AVAIL stub
# prepended to PATH; captures HOOK_OUT. The first arg is a full stdin JSON string.
HOOK_OUT=""
run_hook() {
  local json="$1"; shift
  local env_args=("PATH=$AVAIL_BIN:$PATH")
  [ "$#" -gt 0 ] && env_args+=("$@")
  HOOK_OUT=$(printf '%s' "$json" | env "${env_args[@]}" bash "$HOOK" 2>/dev/null)
}

# extract the rewritten command (empty if {} / no rewrite)
rewritten_cmd() { jq -r '.hookSpecificOutput.updatedInput.command // empty' <<< "$HOOK_OUT" 2>/dev/null; }

assert_rewritten() {  # LABEL  ORIGINAL_CMD
  local label="$1" orig="$2" rc
  rc=$(rewritten_cmd)
  if [ -z "$rc" ]; then
    echo "FAIL $label (expected a rewrite, got: $HOOK_OUT)"; FAIL=$((FAIL+1)); return
  fi
  local ok=1
  grep -Eq 'systemd-run --user --scope' <<< "$rc" || ok=0
  grep -Eq 'MemoryMax=' <<< "$rc"                  || ok=0
  grep -Eq 'MemorySwapMax=0' <<< "$rc"             || ok=0
  grep -Fq "bash -c '" <<< "$rc"                   || ok=0
  grep -Fq "$orig" <<< "$rc"                       || ok=0
  if [ "$ok" -eq 1 ]; then echo "OK   $label"; PASS=$((PASS+1))
  else echo "FAIL $label (rewrite missing an expected token): $rc"; FAIL=$((FAIL+1)); fi
}

assert_noop() {  # LABEL
  local label="$1"
  if [ "$HOOK_OUT" = "{}" ]; then echo "OK   $label"; PASS=$((PASS+1))
  else echo "FAIL $label (expected {}, got: $HOOK_OUT)"; FAIL=$((FAIL+1)); fi
}

# ----------------------------------------------------------------------------
# Positive — pytest is the command being run → rewrite.
# ----------------------------------------------------------------------------
run_hook '{"tool_input":{"command":"pytest"}}';                         assert_rewritten "[1] bare pytest" "pytest"
run_hook '{"tool_input":{"command":"pytest tests/ -n4"}}';              assert_rewritten "[2] pytest + xdist args" "pytest tests/ -n4"
run_hook '{"tool_input":{"command":"python -m pytest tests/test_x.py"}}'; assert_rewritten "[3] python -m pytest" "python -m pytest tests/test_x.py"
run_hook '{"tool_input":{"command":"python3 -m pytest"}}';              assert_rewritten "[4] python3 -m pytest" "python3 -m pytest"
run_hook '{"tool_input":{"command":".venv/bin/python -m pytest"}}';     assert_rewritten "[5] venv python -m pytest" ".venv/bin/python -m pytest"
run_hook '{"tool_input":{"command":".venv/bin/pytest -q"}}';            assert_rewritten "[6] path-prefixed pytest" ".venv/bin/pytest -q"
run_hook '{"tool_input":{"command":"uv run pytest -q"}}';               assert_rewritten "[7] uv run pytest" "uv run pytest -q"
run_hook '{"tool_input":{"command":"poetry run pytest"}}';              assert_rewritten "[8] poetry run pytest" "poetry run pytest"
run_hook '{"tool_input":{"command":"uv run python -m pytest"}}';        assert_rewritten "[9] uv run python -m pytest" "uv run python -m pytest"
run_hook '{"tool_input":{"command":"cd sub && pytest tests/"}}';        assert_rewritten "[10] cd subdir && pytest" "cd sub && pytest tests/"
run_hook '{"tool_input":{"command":"PYTHONPATH=. pytest"}}';            assert_rewritten "[11] env-prefixed pytest" "PYTHONPATH=. pytest"

# ----------------------------------------------------------------------------
# Negative — pytest appears only as an argument / substring → no-op.
# ----------------------------------------------------------------------------
run_hook '{"tool_input":{"command":"pip install pytest"}}';             assert_noop "[12] pip install pytest"
run_hook '{"tool_input":{"command":"pip install pytest-xdist"}}';       assert_noop "[13] pip install pytest-xdist"
run_hook '{"tool_input":{"command":"grep pytest foo.txt"}}';            assert_noop "[14] grep pytest"
run_hook '{"tool_input":{"command":"echo run pytest now"}}';            assert_noop "[15] echo pytest"
run_hook '{"tool_input":{"command":"cat pytest.ini"}}';                 assert_noop "[16] cat pytest.ini"
run_hook '{"tool_input":{"command":"git commit -m \"fix pytest flake\""}}'; assert_noop "[17] pytest in commit msg"
run_hook '{"tool_input":{"command":"npm test"}}';                       assert_noop "[18] npm test"
run_hook '{"tool_input":{"command":"make test"}}';                      assert_noop "[19] make test (Makefile-indirect — fail-safe uncapped)"

# ----------------------------------------------------------------------------
# Quoting — single-quoted -k expression survives the rewrite intact.
# ----------------------------------------------------------------------------
run_hook "{\"tool_input\":{\"command\":\"pytest -k 'foo or bar'\"}}"
RC=$(rewritten_cmd)
if [ -n "$RC" ] && bash -n <<< "$RC" 2>/dev/null; then
  echo "OK   [20] quoted -k expr → rewrite is syntactically valid"; PASS=$((PASS+1))
else
  echo "FAIL [20] quoted -k expr rewrite failed to parse: $RC"; FAIL=$((FAIL+1))
fi
# A non-pytest command that merely contains an uppercase PYTEST token in an
# argument is not rewritten (sanity — argv round-trip under a real cap is proven
# by the e2e probe).
run_hook '{"tool_input":{"command":"printf %s PYTEST_MARKER_42"}}'
assert_noop "[21] non-pytest printf is not rewritten (sanity)"

# ----------------------------------------------------------------------------
# Config — memory override + runtime opt-in.
# ----------------------------------------------------------------------------
run_hook '{"tool_input":{"command":"pytest"}}' "DHX_PYTEST_CAP_MEM=2G"
RC=$(rewritten_cmd)
if grep -Eq 'MemoryMax=2G' <<< "$RC"; then echo "OK   [22] DHX_PYTEST_CAP_MEM=2G honored"; PASS=$((PASS+1))
else echo "FAIL [22] mem override not applied: $RC"; FAIL=$((FAIL+1)); fi

run_hook '{"tool_input":{"command":"pytest"}}'
RC=$(rewritten_cmd)
if grep -Eq 'RuntimeMaxSec' <<< "$RC"; then echo "FAIL [23] default must NOT set RuntimeMaxSec: $RC"; FAIL=$((FAIL+1))
else echo "OK   [23] memory-only by default (no RuntimeMaxSec)"; PASS=$((PASS+1)); fi

run_hook '{"tool_input":{"command":"pytest"}}' "DHX_PYTEST_CAP_RUNTIME=30"
RC=$(rewritten_cmd)
if grep -Eq 'RuntimeMaxSec=30s' <<< "$RC"; then echo "OK   [24] DHX_PYTEST_CAP_RUNTIME=30 opts a runtime cap in"; PASS=$((PASS+1))
else echo "FAIL [24] runtime opt-in not applied: $RC"; FAIL=$((FAIL+1)); fi

# ----------------------------------------------------------------------------
# Fail-open.
# ----------------------------------------------------------------------------
run_hook '{"tool_input":{"command":""}}';                               assert_noop "[25] empty command → {}"
run_hook 'not valid json at all';                                       assert_noop "[26] bad JSON → {}"
run_hook '{"tool_input":{"command":"systemd-run --user --scope -- pytest"}}'; assert_noop "[27] already cgroup-wrapped → {}"
run_hook '{"tool_input":{"command":"MemoryMax-mention pytest"}}';       assert_noop "[28] MemoryMax substring bypass → {}"

# Host lacks systemd-run → even a real pytest command is left unchanged.
HOOK_OUT=$(printf '%s' '{"tool_input":{"command":"pytest"}}' \
  | env "PATH=$NO_SYSTEMD_BIN" bash "$HOOK" 2>/dev/null)
assert_noop "[29] no systemd-run on PATH → fail-open {}"

# ----------------------------------------------------------------------------
# Per-project .claude/test-gate.json memory_max (2026-08-07 — DHX-7 deferral
# closed). Resolution key is stdin `.cwd` ONLY. The config is REPO-CONTROLLED
# and therefore untrusted: strictly validated, clamped to the ceiling, and a bad
# value falls back to the DEFAULT (never to an uncapped {} — a hostile config
# must not be able to un-cap the command).
# ----------------------------------------------------------------------------
PROJ="$TMP/proj"; mkdir -p "$PROJ/.claude"
cfg_run() {  # CONFIG_JSON_OR_EMPTY  → sets RC to the rewritten command
  if [ -n "$1" ]; then printf '%s' "$1" > "$PROJ/.claude/test-gate.json"
  else rm -f "$PROJ/.claude/test-gate.json"; fi
  run_hook "{\"tool_input\":{\"command\":\"pytest\"},\"cwd\":\"$PROJ\"}"
  RC=$(rewritten_cmd)
}
assert_mem() {  # LABEL  EXPECTED_MEM
  if grep -Eq "MemoryMax=$2( |\$)" <<< "$RC"; then echo "OK   $1"; PASS=$((PASS+1))
  else echo "FAIL $1 (expected MemoryMax=$2): $RC"; FAIL=$((FAIL+1)); fi
}

cfg_run '';                       assert_mem "[30] no project config → 12G default" "12G"
cfg_run '{"memory_max":"2G"}';    assert_mem "[31] config LOWERS the cap (2G)" "2G"
cfg_run '{"memory_max":"12G"}';   assert_mem "[32] config at the ceiling is honored" "12G"
cfg_run '{"memory_max":"64G"}';   assert_mem "[33] over-ceiling config is CLAMPED, not honored" "12G"
cfg_run '{"memory_max":"infinity"}'; assert_mem "[34] 'infinity' rejected → default" "12G"
cfg_run '{"memory_max":8}';       assert_mem "[35] non-string memory_max rejected → default" "12G"
cfg_run 'not json';               assert_mem "[36] unparseable config rejected → default" "12G"

# INJECTION BOUNDARY (the security assertion — the factory's tokens are flattened
# into a command STRING, so an unvalidated value is arbitrary command injection).
cfg_run '{"memory_max":"4G; touch '"$TMP"'/PWNED; echo"}'
if grep -Fq 'PWNED' <<< "$RC"; then
  echo "FAIL [37] injection-shaped memory_max reached the command: $RC"; FAIL=$((FAIL+1))
else echo "OK   [37] injection-shaped memory_max never reaches the command"; PASS=$((PASS+1)); fi
[ -e "$TMP/PWNED" ] && { echo "FAIL [37b] injection MARKER was created"; FAIL=$((FAIL+1)); } \
                    || { echo "OK   [37b] no injection marker created"; PASS=$((PASS+1)); }

# Trusted operator env outranks the untrusted config and is NOT ceiling-bound.
printf '%s' '{"memory_max":"2G"}' > "$PROJ/.claude/test-gate.json"
run_hook "{\"tool_input\":{\"command\":\"pytest\"},\"cwd\":\"$PROJ\"}" "DHX_PYTEST_CAP_MEM=16G"
RC=$(rewritten_cmd);              assert_mem "[38] trusted env outranks config, unbounded" "16G"

# --- DHX-7c: signed-64-bit overflow must not defeat the ceiling clamp ----------
# Regression lock for the 2026-08-11 find. Bash arithmetic is signed 64-bit and
# wraps SILENTLY, so the pre-fix `_mem_bytes` turned a repo-controlled value into a
# negative or zero byte count that passed `<= ceiling` and RAISED the cap:
#   "99999999999G" -> -3306282043331051520   "17179869184G" -> 0
# Both must now clamp to the 12G ceiling. [39a] is the exact reported exploit;
# [39b] is the zero-wrap variant (a different arithmetic path to the same bypass);
# [39c] is the plain over-ceiling case that needs NO overflow at all — the control
# proving the clamp itself works; [39d] pins that the suffixless path (which failed
# safe only by accident, via `[`'s "integer expression expected") is now handled
# deliberately rather than incidentally.
cfg_run '{"memory_max":"99999999999G"}'
assert_mem "[39a] signed-64 wrap NEGATIVE cannot raise the cap → clamped" "12G"
cfg_run '{"memory_max":"17179869184G"}'
assert_mem "[39b] signed-64 wrap to ZERO cannot raise the cap → clamped" "12G"
cfg_run '{"memory_max":"999G"}'
assert_mem "[39c] plain over-ceiling value → clamped (no overflow needed)" "12G"
cfg_run '{"memory_max":"99999999999999999999"}'
assert_mem "[39d] suffixless over-int64 literal → clamped, not honored" "12G"

# In-range values must be BYTE-IDENTICAL to pre-fix behavior. This is the
# acceptance criterion that matters: DHX-7b exists because a legitimate "8G" was
# ignored and OOM-killed three real pytest runs at 86%, surfacing as a bare
# "Terminated". A validator fix that rejects a good value repeats that incident
# with the sign flipped. "8G" was statforge's shipped value through 2026-08-14
# (now 12G); it stays a below-ceiling in-range check.
cfg_run '{"memory_max":"8G"}'
assert_mem "[39e] in-range 8G (statforge's pre-12G value) unchanged by the fix" "8G"
cfg_run '{"memory_max":"1K"}'
assert_mem "[39f] smallest suffixed value still honored" "1K"

# ----------------------------------------------------------------------------
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
