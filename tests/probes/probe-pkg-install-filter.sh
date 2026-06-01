#!/usr/bin/env bash
#
# probe-pkg-install-filter.sh — regression probe for the package-install
#   output-reducer (dhx/dhx-pkg-install-filter.sh + dhx/dhx-pkg-install-summarize.sh).
#
# SAFE_FOR_LIVE: yes
#
# Invariants exercised (the reducer's behavioral contract):
#   1. SUMMARIZER (rc==0 compactor, stdin fixtures): keeps the success summary,
#      collapses npm `warn deprecated` / yarn `warning` to a count, drops
#      progress/funding/fetch noise, ALWAYS emits a positive PASS signal, and
#      tail-dumps unrecognized success output (never silent).
#   2. REWRITER (PreToolUse JSON in, decision out): fires only on a single clean
#      install-class invocation; emits {} (no-op) for non-installs, run scripts,
#      compound/piped/redirected commands, output-shaping flags, and self-refs.
#   3. HYBRID END-TO-END contract (the load-bearing guarantees):
#      a. SUCCESS  -> output is COMPACTED (summary kept, noise gone), exit 0.
#      b. FAILURE  -> output is BYTE-IDENTICAL to the raw failure (full
#         passthrough, HP-040 cause never eaten) AND the runner's exit code is
#         PRESERVED through the wrapper.
#
# Backs: docs/decisions.md 2026-05-31 package-install output-reducer row (HP-040 cause-eating + HP-041 updatedInput).
# Mirrors the forgefinder ff-test-output-filter.test.js assertion template (17 cases).
#
# How to run: bash tests/probes/probe-pkg-install-filter.sh
# Output: OK/FAIL per assertion + "N passed, M failed" summary; non-zero on any fail.
#
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FILTER="$ROOT/dhx/dhx-pkg-install-filter.sh"
SUMMARIZE="$ROOT/dhx/dhx-pkg-install-summarize.sh"

PASS=0; FAIL=0
ck() { if [ "$1" -eq 0 ]; then printf 'OK   %s\n' "$2"; PASS=$((PASS+1)); else printf 'FAIL %s\n' "$2"; FAIL=$((FAIL+1)); fi; }

# JSON PreToolUse payload for a Bash command.
j() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(jq -Rn --arg c "$1" '$c')"; }
# Rewritten command (empty string if the hook emitted {}).
rewrite_of() { j "$1" | bash "$FILTER" | jq -r '.hookSpecificOutput.updatedInput.command // empty'; }
decision_of() { j "$1" | bash "$FILTER" | jq -r '.hookSpecificOutput.permissionDecision // "NOOP"'; }
has()  { grep -qF -- "$2" <<<"$1"; }   # literal substring present
hasnt() { ! grep -qF -- "$2" <<<"$1"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Fake package-manager binary that cats a fixture file and exits a chosen code,
# ignoring its args — lets the end-to-end test run the rewritten wrapper without
# touching the network. Echoes the bin dir to prepend to PATH.
make_fake_bin() { # $1=binname  $2=fixture-file  $3=exit-code
  local bin; bin=$(mktemp -d)
  printf '#!/usr/bin/env bash\ncat %q\nexit %s\n' "$2" "$3" > "$bin/$1"
  chmod +x "$bin/$1"
  printf '%s' "$bin"
}

# ============================ (1) SUMMARIZER ===============================
echo "=== summarizer: npm small install (already terse — both lines kept) ==="
NPM_SMALL=$'added 2 packages, and audited 3 packages in 401ms\n\nfound 0 vulnerabilities'
out=$(printf '%s\n' "$NPM_SMALL" | bash "$SUMMARIZE")
has "$out" "PASS:";                       ck $? "npm-small: announces PASS"
has "$out" "added 2 packages";            ck $? "npm-small: keeps the added/audited summary"
has "$out" "found 0 vulnerabilities";     ck $? "npm-small: keeps the vulnerabilities line"

echo "=== summarizer: npm large install (collapse deprecations, drop funding) ==="
NPM_LARGE=$'npm warn deprecated rimraf@3.0.2: no longer supported\nnpm warn deprecated inflight@1.0.6: leaks memory\nnpm warn deprecated glob@7.2.3: no longer supported\n\nadded 215 packages, and audited 216 packages in 12s\n\n47 packages are looking for funding\n  run `npm fund` for details\n\nfound 0 vulnerabilities'
out=$(printf '%s\n' "$NPM_LARGE" | bash "$SUMMARIZE")
has "$out" "added 215 packages";          ck $? "npm-large: keeps the summary line"
has "$out" "found 0 vulnerabilities";     ck $? "npm-large: keeps the vulnerabilities line"
has "$out" "npm warn deprecated (x3)";    ck $? "npm-large: collapses 3 deprecations to a count"
hasnt "$out" "rimraf@3.0.2";              ck $? "npm-large: individual deprecated lines NOT surfaced"
hasnt "$out" "looking for funding";       ck $? "npm-large: funding noise dropped"
hasnt "$out" "npm fund";                  ck $? "npm-large: 'run npm fund' noise dropped"

echo "=== summarizer: pip install (keep Successfully, drop Collecting/cached) ==="
PIP_OK=$'Collecting six\n  Using cached six-1.17.0-py2.py3-none-any.whl.metadata (1.7 kB)\nUsing cached six-1.17.0-py2.py3-none-any.whl (11 kB)\nInstalling collected packages: six\nSuccessfully installed six-1.17.0'
out=$(printf '%s\n' "$PIP_OK" | bash "$SUMMARIZE")
has "$out" "Successfully installed six-1.17.0"; ck $? "pip: keeps Successfully installed"
hasnt "$out" "Collecting six";            ck $? "pip: drops Collecting"
hasnt "$out" "Using cached";              ck $? "pip: drops Using cached"
hasnt "$out" "Installing collected packages"; ck $? "pip: drops Installing collected packages"

echo "=== summarizer: pip WARNING kept ==="
PIP_WARN=$'Collecting six\nWARNING: You are using pip version 24.0; however, version 25.0 is available.\nSuccessfully installed six-1.17.0'
out=$(printf '%s\n' "$PIP_WARN" | bash "$SUMMARIZE")
has "$out" "WARNING: You are using pip";  ck $? "pip: keeps ^WARNING: advisory"
has "$out" "Successfully installed";      ck $? "pip: still keeps Successfully installed"

echo "=== summarizer: unrecognized success output -> raw tail, never silent ==="
WEIRD=$'some unmodeled tool output\nthat matches no summary shape\nfinal line'
out=$(printf '%s\n' "$WEIRD" | bash "$SUMMARIZE")
has "$out" "no recognized summary line";  ck $? "unrecognized: warns + dumps raw tail"
has "$out" "final line";                  ck $? "unrecognized: surfaces the raw tail content"

echo "=== summarizer: empty input -> explicit message, never silent ==="
out=$(printf '' | bash "$SUMMARIZE")
has "$out" "no output";                   ck $? "empty: explicit 'no output' message"

# ============================ (2) REWRITER ================================
echo "=== rewriter: fires on a bare install, with the hybrid wrapper shape ==="
rw=$(rewrite_of "npm install")
[ -n "$rw" ];                             ck $? "npm install: emits a rewrite (not {})"
has "$rw" "dhx-pkg-install-summarize.sh"; ck $? "npm install: routes success through the summarizer"
has "$rw" 'exit $rc';                     ck $? "npm install: preserves the runner exit code"
has "$rw" '2>&1';                         ck $? "npm install: merges stderr into the capture"
has "$rw" 'if [ "$rc" -eq 0 ]';           ck $? "npm install: branches on exit code (hybrid)"
has "$rw" 'else cat "$T"';                ck $? "npm install: failure branch cats the full capture"
[ "$(decision_of "npm install")" = "allow" ]; ck $? "npm install: permissionDecision allow"

echo "=== rewriter: candidates across managers ==="
for c in "npm i" "npm ci" "pnpm install" "pnpm add lodash" "yarn" "yarn add react" \
         "pip install requests" "pip3 install -r requirements.txt" \
         "python3 -m pip install six" "uv pip install ruff" \
         "/home/u/.venv/bin/pip install six" "./venv/bin/pip install -r reqs.txt" \
         "../env/bin/pip3 install ruff" "/opt/py/bin/python3 -m pip install six" \
         "/usr/local/bin/npm install"; do
  [ "$(decision_of "$c")" = "allow" ]; ck $? "candidate fires (path-prefixed ok): $c"
done

echo "=== rewriter: bypass / no-op cases (emit {}) ==="
for c in "ls -la" "npm test" "npm run build" "npm run install" "pip download six" \
         "npm install foo | tail -5" "npm install > out.txt" "cd app && npm install" \
         "npm install --silent" "pip install --dry-run six" "pip install --help" \
         "npm install --json" "echo \$(npm install)" \
         "/opt/py/bin/python3 script.py" "/home/u/.venv/bin/pip download six"; do
  [ "$(decision_of "$c")" = "NOOP" ]; ck $? "bypass no-op: $c"
done
# Idempotency: an already-wrapped command must not double-wrap.
rw=$(rewrite_of "npm install")
[ "$(decision_of "$rw")" = "NOOP" ];      ck $? "idempotent: already-wrapped command not re-wrapped"

# ============================ (3) HYBRID END-TO-END =======================
echo "=== end-to-end: SUCCESS path compacts; exit 0 ==="
printf '%s\n' "$NPM_LARGE" > "$TMP/npm-large.txt"
OKBIN=$(make_fake_bin npm "$TMP/npm-large.txt" 0)
rw=$(rewrite_of "npm install")
e2e=$(PATH="$OKBIN:$PATH" bash -c "$rw" 2>&1); rc=$?
[ "$rc" -eq 0 ];                          ck $? "e2e-success: wrapper exits 0"
has "$e2e" "PASS:";                       ck $? "e2e-success: PASS header present"
has "$e2e" "added 215 packages";          ck $? "e2e-success: summary line surfaced"
has "$e2e" "npm warn deprecated (x3)";    ck $? "e2e-success: deprecations collapsed end-to-end"
hasnt "$e2e" "looking for funding";       ck $? "e2e-success: funding noise removed end-to-end"

echo "=== end-to-end: FAILURE path is byte-identical full passthrough; exit preserved (HP-040) ==="
NPM_404=$'npm error code E404\nnpm error 404 Not Found - GET https://registry.npmjs.org/@scope%2fpkg - Not found\nnpm error 404  \x27@scope/pkg@*\x27 is not in this registry.\nnpm error A complete log of this run can be found in: /home/x/.npm/_logs/debug-0.log'
printf '%s\n' "$NPM_404" > "$TMP/npm-404.txt"
FAILBIN=$(make_fake_bin npm "$TMP/npm-404.txt" 1)
rw=$(rewrite_of "npm install @scope/pkg")
PATH="$FAILBIN:$PATH" bash -c "$rw" > "$TMP/e2e-fail.out" 2>&1; rc=$?
[ "$rc" -eq 1 ];                          ck $? "e2e-failure: runner exit code 1 preserved"
diff -q "$TMP/npm-404.txt" "$TMP/e2e-fail.out" >/dev/null; ck $? "e2e-failure: output BYTE-IDENTICAL to raw failure (cause not eaten)"
out=$(cat "$TMP/e2e-fail.out")
hasnt "$out" "PASS:";                     ck $? "e2e-failure: summarizer NOT applied on failure"
has "$out" "npm error 404";               ck $? "e2e-failure: the 404 cause survives intact"

echo "=== end-to-end: native-build failure (THE TRAP) — full passthrough, exit 1 ==="
PIP_WHEEL=$'Collecting cffi\n  Building wheel for cffi (pyproject.toml): started\n  gcc -pthread -B /usr/bin ... cffi/_cffi_backend.c\n  cffi/_cffi_backend.c:15:10: fatal error: ffi.h: No such file or directory\n     15 | #include <ffi.h>\n        |          ^~~~~~~\n  compilation terminated.\n  error: command \x27gcc\x27 failed with exit code 1\nERROR: Failed building wheel for cffi'
printf '%s\n' "$PIP_WHEEL" > "$TMP/pip-wheel.txt"
WHEELBIN=$(make_fake_bin pip "$TMP/pip-wheel.txt" 1)
rw=$(rewrite_of "pip install cffi")
PATH="$WHEELBIN:$PATH" bash -c "$rw" > "$TMP/e2e-wheel.out" 2>&1; rc=$?
[ "$rc" -eq 1 ];                          ck $? "e2e-trap: pip wheel-build failure exit 1 preserved"
diff -q "$TMP/pip-wheel.txt" "$TMP/e2e-wheel.out" >/dev/null; ck $? "e2e-trap: full traceback BYTE-IDENTICAL (ffi.h cause + summary both survive)"

echo "=== end-to-end: exit code other than 1 also preserved ==="
printf 'boom\n' > "$TMP/boom.txt"
B7=$(make_fake_bin npm "$TMP/boom.txt" 7)
rw=$(rewrite_of "npm ci")
PATH="$B7:$PATH" bash -c "$rw" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 7 ];                          ck $? "e2e: arbitrary exit code 7 preserved through wrapper"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
