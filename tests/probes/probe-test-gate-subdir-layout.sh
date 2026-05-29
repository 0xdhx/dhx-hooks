#!/usr/bin/env bash
# probe-test-gate-subdir-layout.sh
#
# Regression probe for dhx/dhx-test-gate.sh subdir / monorepo layout handling.
# Backs docs/decisions.md 2026-05-29 row ("subdir/monorepo test-layout contract
# fix") and reports/done/2026-05-29-dhx-test-gate-subdir-test-layout-contract-gap.md.
#
# Covers:
#   - #1 auto-discovery: no root pytest config + a SINGLE unambiguous subdir
#     config (pytest.ini / pyproject[tool.pytest] / setup.cfg / tox.ini) →
#     gate runs the runner from that config dir (= pytest rootdir).
#   - ambiguity guard: ≥2 subdir configs → no anchor, fail open to repo-root
#     invocation (today's behavior) + log line.
#   - #2/#4 faithful cwd: when `target` is a directory, the gate cd's to the
#     config rootdir (walking up from target) and passes the remainder as a
#     RELATIVE arg — reproducing `cd <config-dir> && pytest <rel>`.
#   - target-is-file/nodeid: unchanged append-as-arg, cwd = repo root.
#   - #5 cache alignment: the --last-failed branch keys on the EFFECTIVE
#     rootdir's .pytest_cache, not the repo-root cache.
#   - regression: a normal root-layout pytest repo is unaffected (cwd = root,
#     no discovery, no cd).
#
# INVARIANT: the gate runs the project's tests with the project's config — i.e.
# from pytest's rootdir, so addopts/markers load, cwd lands on sys.path (via
# `python -m`), and .pytest_cache resolves correctly. A subdir config must NOT
# be silently skipped (which would run a broader/wrong selection from the root).
#
# Mechanism note (corrects the source report): `import <toplevel>` resolves
# because the gate runs `python -m pytest`, and `-m` inserts cwd at sys.path[0]
# — NOT because rootdir is added to sys.path (pytest docs: rootdir "is not used
# to modify Python's import path"). Hence the anchor is the config dir (cwd),
# not the raw target dir.
#
# Run: bash tests/probes/probe-test-gate-subdir-layout.sh
#
# SAFE_FOR_LIVE: yes  (pure detection/cwd logic — no systemd-run, no cgroup; a
#                      stubbed python records argv + cwd. Fully isolated via
#                      mktemp + HOME / TMPDIR / CLAUDE_PROJECT_DIR overrides.)
# RUNTIME: ~3s

set -u

HOOK="/home/dhx/repos/hooks/dhx/dhx-test-gate.sh"
TMP=$(mktemp -d /tmp/probe-test-gate-subdir.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
HOOK_OUT=""
HOOK_EXIT=0

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

# new_project NAME — bare project dir (NO root config); echoes absolute path.
new_project() {
  local proj="$TMP/$1"
  mkdir -p "$proj/.claude/hooks/logs" "$proj/.venv/bin"
  echo "$proj"
}

# stub_python PROJ EXIT BODY — install $PROJ/.venv/bin/python as a bash stub.
#   --version → exit 0 (cascade ambient-pytest probe)
#   else      → record argv (printf %q) to .runner-argv.log, record cwd to
#               .runner-cwd.log, emit BODY, exit EXIT.
stub_python() {
  local proj="$1" code="$2" body="${3:-}"
  cat > "$proj/.venv/bin/python" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"--version"*) echo "pytest 0.0.0 (probe stub)"; exit 0 ;;
esac
printf '%q ' "\$0" "\$@" >> "$proj/.runner-argv.log"
printf '\n' >> "$proj/.runner-argv.log"
pwd >> "$proj/.runner-cwd.log"
cat <<'BODY'
$body
BODY
exit $code
EOF
  chmod +x "$proj/.venv/bin/python"
}

run_hook() {
  local proj="$1" sid="$2"
  HOOK_EXIT=0
  HOOK_OUT=$(env \
    "HOME=$TMP" "TMPDIR=$TMP" "CLAUDE_PROJECT_DIR=$proj" \
    bash "$HOOK" <<< "{\"session_id\":\"$sid\",\"stop_hook_active\":false}" 2>&1) || HOOK_EXIT=$?
}

set_source_flag() { touch "$TMP/claude-source-dirty-$1.flag"; }
clear_state()     { rm -f "$TMP"/claude-source-dirty-*.flag "$TMP"/claude-stop-*.count; }

last_cwd() { tail -n 1 "$1/.runner-cwd.log" 2>/dev/null; }

assert_exit() {
  local expected="$1" label="$2"
  if [ "$HOOK_EXIT" -eq "$expected" ]; then echo "OK   $label (exit $HOOK_EXIT)"; PASS=$((PASS+1))
  else echo "FAIL $label (expected exit $expected, got $HOOK_EXIT)"; echo "     out: $(tail -n3 <<<"$HOOK_OUT")"; FAIL=$((FAIL+1)); fi
}

assert_cwd() {
  local proj="$1" expected="$2" label="$3" got
  got=$(last_cwd "$proj")
  if [ "$got" = "$expected" ]; then echo "OK   $label (cwd=$got)"; PASS=$((PASS+1))
  else echo "FAIL $label (expected cwd '$expected', got '$got')"; FAIL=$((FAIL+1)); fi
}

assert_log() {
  local proj="$1" pat="$2" label="$3"
  if grep -qF -- "$pat" "$proj/.claude/hooks/logs/test-gate.log" 2>/dev/null; then echo "OK   $label"; PASS=$((PASS+1))
  else echo "FAIL $label (log missing '$pat')"; FAIL=$((FAIL+1)); fi
}

assert_argv_has()    { if grep -qF -- "$2" "$1/.runner-argv.log" 2>/dev/null; then echo "OK   $3"; PASS=$((PASS+1)); else echo "FAIL $3 (argv missing '$2'); argv=$(cat "$1/.runner-argv.log" 2>/dev/null)"; FAIL=$((FAIL+1)); fi; }
assert_argv_lacks()  { if grep -qF -- "$2" "$1/.runner-argv.log" 2>/dev/null; then echo "FAIL $3 (argv unexpectedly has '$2'); argv=$(cat "$1/.runner-argv.log" 2>/dev/null)"; FAIL=$((FAIL+1)); else echo "OK   $3"; PASS=$((PASS+1)); fi; }

# ----------------------------------------------------------------------------
# S1 — auto-discovery: single subdir pytest.ini, no root config → cwd = subdir.
# ----------------------------------------------------------------------------
clear_state
PROJ=$(new_project s1)
mkdir -p "$PROJ/tts-service"
printf '[pytest]\naddopts = -q\n' > "$PROJ/tts-service/pytest.ini"
stub_python "$PROJ" 0 ""
set_source_flag s1
run_hook "$PROJ" s1
assert_exit 0 "[1] auto-discovery single subdir config → exit 0"
assert_cwd "$PROJ" "$PROJ/tts-service" "[1] runner ran from the discovered config dir"
assert_log "$PROJ" "Subdir pytest config discovered at tts-service" "[1] log records discovery"

# ----------------------------------------------------------------------------
# S2 — ambiguity: two subdir configs → no anchor, run from repo root, log it.
# ----------------------------------------------------------------------------
clear_state
PROJ=$(new_project s2)
mkdir -p "$PROJ/svc-a" "$PROJ/svc-b"
printf '[pytest]\n' > "$PROJ/svc-a/pytest.ini"
printf '[pytest]\n' > "$PROJ/svc-b/pytest.ini"
stub_python "$PROJ" 0 ""
set_source_flag s2
run_hook "$PROJ" s2
assert_exit 0 "[2] ambiguous subdir configs → exit 0 (fail open)"
assert_cwd "$PROJ" "$PROJ" "[2] ran from repo root (no anchor on ambiguity)"
assert_log "$PROJ" "Multiple subdir pytest configs" "[2] log records ambiguity"

# ----------------------------------------------------------------------------
# S3 — target is a dir BELOW its rootdir → cd to rootdir, pass relative arg.
#      target=tts-service/tests, config at tts-service/pytest.ini.
# ----------------------------------------------------------------------------
clear_state
PROJ=$(new_project s3)
mkdir -p "$PROJ/tts-service/tests"
printf '[pytest]\n' > "$PROJ/tts-service/pytest.ini"
echo '{"target": "tts-service/tests"}' > "$PROJ/.claude/test-gate.json"
stub_python "$PROJ" 0 ""
set_source_flag s3
run_hook "$PROJ" s3
assert_exit 0 "[3] target dir below rootdir → exit 0"
assert_cwd "$PROJ" "$PROJ/tts-service" "[3] cd'd to the pytest rootdir (config dir), not the raw target"
assert_argv_has  "$PROJ" " tests " "[3] passed the remainder as a relative arg"
assert_argv_lacks "$PROJ" "tts-service/tests" "[3] did NOT pass the root-relative target path"

# ----------------------------------------------------------------------------
# S4 — target dir == config dir → cd, no extra target arg.
# ----------------------------------------------------------------------------
clear_state
PROJ=$(new_project s4)
mkdir -p "$PROJ/tts-service"
printf '[pytest]\n' > "$PROJ/tts-service/pytest.ini"
echo '{"target": "tts-service"}' > "$PROJ/.claude/test-gate.json"
stub_python "$PROJ" 0 ""
set_source_flag s4
run_hook "$PROJ" s4
assert_exit 0 "[4] target dir == rootdir → exit 0"
assert_cwd "$PROJ" "$PROJ/tts-service" "[4] cd'd to the config dir"
assert_argv_lacks "$PROJ" " tts-service " "[4] no redundant target arg when target == rootdir"

# ----------------------------------------------------------------------------
# S5 — target dir with NO config anywhere above → cd to the target dir itself.
# ----------------------------------------------------------------------------
clear_state
PROJ=$(new_project s5)
mkdir -p "$PROJ/mytests"
echo '{"target": "mytests"}' > "$PROJ/.claude/test-gate.json"
stub_python "$PROJ" 0 ""
set_source_flag s5
run_hook "$PROJ" s5
assert_exit 0 "[5] target dir, no config above → exit 0"
assert_cwd "$PROJ" "$PROJ/mytests" "[5] cd'd to the target dir (canonical cd <dir> && runner)"

# ----------------------------------------------------------------------------
# S6 — target is a file/node-id (not a dir) → append as arg, cwd = repo root.
# ----------------------------------------------------------------------------
clear_state
PROJ=$(new_project s6)
printf '[tool.pytest.ini_options]\n' > "$PROJ/pyproject.toml"   # root config
echo '{"target": "tests/test_x.py::test_foo"}' > "$PROJ/.claude/test-gate.json"
stub_python "$PROJ" 0 ""
set_source_flag s6
run_hook "$PROJ" s6
assert_exit 0 "[6] file/node-id target → exit 0"
assert_cwd "$PROJ" "$PROJ" "[6] ran from repo root for a file/node-id target"
assert_argv_has "$PROJ" "tests/test_x.py::test_foo" "[6] appended the node-id as an arg"

# ----------------------------------------------------------------------------
# S7 — #5 cache alignment. Auto-discovered subdir; the --last-failed branch must
#      key on the SUBDIR's .pytest_cache, not the repo-root one.
#   7a: subdir has .pytest_cache, root does NOT → --last-failed taken.
#   7b: stale root .pytest_cache, subdir has none → full suite (no --last-failed).
# ----------------------------------------------------------------------------
clear_state
PROJ=$(new_project s7a)
mkdir -p "$PROJ/svc/.pytest_cache"
printf '[pytest]\n' > "$PROJ/svc/pytest.ini"
stub_python "$PROJ" 0 "no tests ran"
set_source_flag s7a
run_hook "$PROJ" s7a
assert_exit 0 "[7a] subdir cache present → exit 0"
assert_argv_has "$PROJ" "--last-failed" "[7a] cache probe keyed on the subdir rootdir cache"

clear_state
PROJ=$(new_project s7b)
mkdir -p "$PROJ/.pytest_cache"            # stale root cache
mkdir -p "$PROJ/svc"
printf '[pytest]\n' > "$PROJ/svc/pytest.ini"
stub_python "$PROJ" 0 ""
set_source_flag s7b
run_hook "$PROJ" s7b
assert_exit 0 "[7b] stale root cache, subdir none → exit 0"
assert_argv_lacks "$PROJ" "--last-failed" "[7b] stale root cache did NOT trigger --last-failed (probe on rootdir)"

# ----------------------------------------------------------------------------
# S8 — regression: root-layout pytest repo is unaffected (cwd = root, no cd).
# ----------------------------------------------------------------------------
clear_state
PROJ=$(new_project s8)
printf '[tool.pytest.ini_options]\n' > "$PROJ/pyproject.toml"
stub_python "$PROJ" 0 ""
set_source_flag s8
run_hook "$PROJ" s8
assert_exit 0 "[8] root-layout repo → exit 0"
assert_cwd "$PROJ" "$PROJ" "[8] ran from repo root (no subdir anchoring)"
if grep -qF "Subdir pytest config discovered" "$PROJ/.claude/hooks/logs/test-gate.log" 2>/dev/null; then
  echo "FAIL [8] root layout incorrectly triggered subdir discovery"; FAIL=$((FAIL+1))
else
  echo "OK   [8] root layout did not trigger subdir discovery"; PASS=$((PASS+1))
fi

# ----------------------------------------------------------------------------
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
