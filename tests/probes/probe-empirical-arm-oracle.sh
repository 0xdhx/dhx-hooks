#!/usr/bin/env bash
# SAFE_FOR_LIVE: yes  (drives lib/empirical-arm-classify.sh on heredoc fixtures under
#   a mktemp root; runs run-empirical-arm.sh only up to its pre-flight / step-5 exits
#   with a STUB `claude` first on PATH and TMPDIR inside the root, so no Claude Code
#   child is ever spawned and the arm's own HOME/CLAUDE_CONFIG_DIR swap lands in the
#   root. Never touches live ~/.claude, ~/.ccs or the plugin cache.)
#
# Regression probe for the D-01 empirical arm's ORACLE (2026-09-19, H5 fork A1).
#
# THE DEFECT. `run-empirical-arm.sh` classified REFUTE from two signals — marker
# absent + SessionStart control fired — and printed its Stop-dispatch trace (8c)
# as advisory prose. Run without credentials, CC dispatches SessionStart, then
# ends the turn at `Could not resolve authentication method` BEFORE any Stop hook
# runs; the cache-only marker therefore CANNOT fire, and the arm still said
# `Suggested: REFUTE` (H5 run 1 on CC 2.1.278: 0 `Hook Stop (Stop)` lines).
# Vacuous-oracle class — the verdict was unreachable by the thing it claimed to
# measure.
#
# Arms:
#   1. fixtures — debug-file excerpts in the 2.1.278 line shape (H5 runs 1 and 2)
#   2. arm_stop_dispatched counts exactly the `[DEBUG] "Hook Stop (Stop) …` lines:
#      0 on the unauthenticated log, 6 on the authenticated one (5 error + 1 success); a SubagentStop
#      line and a permission-rule ECHO whose rule text spells the Stop line (the
#      one settings-text carrier that reaches the debug file — H3) count 0
#   3. arm_auth_failed: yes on run-1 shape, no on run-2 shape
#   4. NEGATIVE CONTROL — the pre-fix two-signal rule, reproduced inline, says
#      REFUTE on the run-1 inputs; the oracle says INCONCLUSIVE and names auth
#   5. POSITIVE — run-2 inputs (Stop lines present) → REFUTE with the exact write-result args
#   6. AFFIRM — a marker line wins regardless of the Stop count
#   7. control absent → INCONCLUSIVE carrying `--control-hook-fired no`
#   8. CREDENTIAL GATE — with the three credential vars unset the arm exits 2
#      before provisioning a sandbox; with a dummy value it passes the gate and
#      reaches its step-5 exit 3 (stub `claude` installs nothing) — the
#      discriminating pair, so the gate is shown to key on the variables
#   9. WIRING — the arm sources the lib, calls arm_classify, carries no inline
#      REFUTE assignment, and is tagged `# CC-STDERR-EXEMPT:` exactly once
#
# Backs docs/decisions.md 2026-09-19 "prompt-type Stop hooks block for real on
# 2.1.278; the D-01 arm needs credentials" row.
#
# Run: bash tests/probes/probe-empirical-arm-oracle.sh
set -uo pipefail

PROBE_ID="probe-empirical-arm-oracle"
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
ARM="$HERE/run-empirical-arm.sh"
LIB="$HERE/lib/empirical-arm-classify.sh"

PASS=0
FAIL=0
ok()  { printf 'OK   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

ROOT=$(mktemp -d -t "$PROBE_ID-XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

# shellcheck source=lib/empirical-arm-classify.sh
source "$LIB"

# ---------------------------------------------------------------------------
echo "### 1. fixtures (2.1.278 debug-file line shape, from H5 runs 1 and 2)"
# ---------------------------------------------------------------------------
SB='/tmp/claude-lane-0/dhx-cache-probe-FIXTUR/home'
UNAUTH="$ROOT/debug-unauth.log"
AUTH="$ROOT/debug-auth.log"
cat > "$UNAUTH" <<EOF
2026-09-20T01:43:15.001Z [DEBUG] Read hooks.json for plugin dhx (enabled=true): $REPO/dhx-plugin/plugins/dhx/hooks/hooks.json
2026-09-20T01:43:15.002Z [DEBUG] Registered 49 hooks from 1 plugins
2026-09-20T01:43:16.100Z [DEBUG] "Hook SessionStart:startup (SessionStart) error:\nbash: $SB/.claude/hooks/dhx-vitals-banner.sh: No such file or directory"
2026-09-20T01:43:16.400Z [DEBUG] "Hook SessionStart:startup (SessionStart) success:\n⚠ session-start child cc-circuit-breakers failed (rc=2)"
2026-09-20T01:43:19.000Z [DEBUG] [engine] turn 1 start
2026-09-20T01:43:19.100Z [DEBUG] "Hook UserPromptSubmit (UserPromptSubmit) error:\nbash: $SB/.claude/hooks/dhx-routing.sh: No such file or directory"
2026-09-20T01:43:19.382Z [ERROR] API error (attempt 1/11): Could not resolve authentication method. Expected one of apiKey, authToken, credentials, config, or profile to be set.
2026-09-20T01:43:19.390Z [DEBUG] [engine] turn 1 end (turns=1 usage in=0 out=0 api=0ms)
2026-09-20T01:43:19.500Z [DEBUG] "Hook SessionEnd (SessionEnd) error:\nbash: $SB/.claude/hooks/dhx-session-end.sh: No such file or directory"
EOF
{
  sed -n '1,6p' "$UNAUTH" | sed 's/01:43:1/01:46:5/'
  echo '2026-09-20T01:46:57.700Z [DEBUG] [engine] turn 1 end (turns=1 usage in=12 out=9 api=2388ms stop=end_turn resultLen=39)'
  for h in dhx-deferred-check dhx-test-gate dhx-milestone-close-blocker-check dhx-restart-plugins-stop dhx-execute-stop-review; do
    printf '2026-09-20T01:46:57.783Z [DEBUG] "Hook Stop (Stop) error:\\nbash: %s/.claude/hooks/%s.sh: No such file or directory"\n' "$SB" "$h"
  done
  echo '2026-09-20T01:46:57.800Z [DEBUG] "Hook Stop (Stop) success:\n"'
  echo '2026-09-20T01:46:58.000Z [DEBUG] "Hook SessionEnd (SessionEnd) error:\nbash: x: No such file or directory"'
} > "$AUTH"
# Distractors: a SubagentStop dispatch line, and the H3 carrier — a permission
# rule whose TEXT spells the Stop line, echoed verbatim on load.
DISTRACT="$ROOT/debug-distractors.log"
cat > "$DISTRACT" <<'EOF'
2026-09-20T01:46:50.000Z [DEBUG] Applying permission update: Adding 1 allow rule(s) to destination 'localSettings': ["Bash([DEBUG] \"Hook Stop (Stop) error: *)"]
2026-09-20T01:46:57.783Z [DEBUG] "Hook SubagentStop (SubagentStop) error:\nbash: x: No such file or directory"
2026-09-20T01:46:57.784Z [DEBUG] Hook Stop (Stop) error: not quoted, not a dispatch line
EOF
MARKER_ABSENT="$ROOT/marker-absent.log"       # never created
MARKER_FIRED="$ROOT/marker-fired.log"
echo '[2026-09-20T01:47:18Z] dhx-cache-probe-marker FIRED pid=1 cc_pid=2' > "$MARKER_FIRED"
chk "fixture: unauthenticated log has 0 verbatim Stop lines" "$(grep -c '"Hook Stop (Stop) ' "$UNAUTH")" 0
chk "fixture: authenticated log has 6 verbatim Stop lines (5 error + 1 success)" "$(grep -c '"Hook Stop (Stop) ' "$AUTH")" 6
chk "fixture: both logs carry the SessionStart error line (the old control's carrier)" \
    "$(cat "$UNAUTH" "$AUTH" | grep -c 'Hook SessionStart:startup (SessionStart) error:')" 2
chk "fixture: the rule-echo distractor spells the Stop line inside rule text (positive control for arm 2)" \
    "$(grep -c 'Hook Stop (Stop) error:' "$DISTRACT")" 2

# ---------------------------------------------------------------------------
echo "### 2. arm_stop_dispatched counts only the anchored 2.1.278 dispatch line"
# ---------------------------------------------------------------------------
chk "unauthenticated log → 0" "$(arm_stop_dispatched "$UNAUTH")" 0
chk "authenticated log → 6" "$(arm_stop_dispatched "$AUTH")" 6
chk "SubagentStop + rule-echo + unquoted distractors → 0" "$(arm_stop_dispatched "$DISTRACT")" 0
chk "missing file → 0, no error" "$(arm_stop_dispatched "$ROOT/nope.log" 2>&1)" 0

# ---------------------------------------------------------------------------
echo "### 3. arm_auth_failed"
# ---------------------------------------------------------------------------
chk "unauthenticated log → yes" "$(arm_auth_failed "$UNAUTH")" yes
chk "authenticated log → no"    "$(arm_auth_failed "$AUTH")" no
chk "arm_marker_fired absent → no"  "$(arm_marker_fired "$MARKER_ABSENT")" no
chk "arm_marker_fired present → yes" "$(arm_marker_fired "$MARKER_FIRED")" yes

# ---------------------------------------------------------------------------
echo "### 4. NEGATIVE CONTROL — the pre-fix two-signal rule vs the oracle, run-1 inputs"
# ---------------------------------------------------------------------------
# The rule the arm carried until 2026-09-19, verbatim in substance: it never
# looked at the Stop trace. If this ever stops saying REFUTE the fixture no
# longer reproduces the defect and arm 4 is measuring nothing.
legacy_classify() {  # <marker> <control>
  if [ "$1" = yes ]; then echo AFFIRM
  elif [ "$1" = no ] && [ "$2" = yes ]; then echo REFUTE
  else echo INCONCLUSIVE; fi
}
m=$(arm_marker_fired "$MARKER_ABSENT"); st=$(arm_stop_dispatched "$UNAUTH"); au=$(arm_auth_failed "$UNAUTH")
chk "pre-fix rule on run-1 inputs (marker=no, control=yes) → REFUTE  [the vacuous verdict]" "$(legacy_classify "$m" yes)" REFUTE
arm_classify "$m" yes "$st" "$au"
chk "oracle on the same inputs → INCONCLUSIVE" "$CLASS_VERDICT" INCONCLUSIVE
chk "oracle args carry inconclusive + control yes" "$CLASS_ARGS" "--cache-read-path inconclusive --control-hook-fired yes"
case "$CLASS_LABEL" in *authenticate*) ok "oracle label names the auth failure as the cause" ;; *) bad "oracle label does not name auth: $CLASS_LABEL" ;; esac
arm_classify no yes 0 no
chk "0 Stop lines without an auth line → still INCONCLUSIVE (Stop simply never dispatched)" "$CLASS_VERDICT" INCONCLUSIVE
case "$CLASS_LABEL" in *"0 Stop-dispatch lines"*) ok "label names the 0 Stop-dispatch count" ;; *) bad "label does not name the Stop count: $CLASS_LABEL" ;; esac

# ---------------------------------------------------------------------------
echo "### 5. POSITIVE — run-2 inputs (Stop dispatched) → REFUTE"
# ---------------------------------------------------------------------------
st=$(arm_stop_dispatched "$AUTH"); au=$(arm_auth_failed "$AUTH")
arm_classify "$m" yes "$st" "$au"
chk "oracle → REFUTE" "$CLASS_VERDICT" REFUTE
chk "REFUTE args are the write-result args" "$CLASS_ARGS" "--cache-read-path no --control-hook-fired yes"
case "$CLASS_LABEL" in *"6 source Stop hook(s) dispatched"*) ok "label carries the dispatched count" ;; *) bad "label lacks the count: $CLASS_LABEL" ;; esac
arm_classify no yes 1 no
chk "exactly 1 Stop line is enough (>= 1)" "$CLASS_VERDICT" REFUTE

# ---------------------------------------------------------------------------
echo "### 6. AFFIRM — marker wins"
# ---------------------------------------------------------------------------
arm_classify "$(arm_marker_fired "$MARKER_FIRED")" yes 6 no
chk "marker + Stop → AFFIRM" "$CLASS_VERDICT" AFFIRM
chk "AFFIRM args" "$CLASS_ARGS" "--cache-read-path yes --control-hook-fired yes"
arm_classify yes no 0 no
chk "marker without control → still AFFIRM (marker is the primary observable, D-04)" "$CLASS_VERDICT" AFFIRM
chk "…and the args report control no" "$CLASS_ARGS" "--cache-read-path yes --control-hook-fired no"

# ---------------------------------------------------------------------------
echo "### 7. control absent → INCONCLUSIVE"
# ---------------------------------------------------------------------------
arm_classify no no 6 no
chk "marker no + control no + Stop 6 → INCONCLUSIVE" "$CLASS_VERDICT" INCONCLUSIVE
chk "args carry control no" "$CLASS_ARGS" "--cache-read-path inconclusive --control-hook-fired no"
arm_classify no no 0 yes
chk "nothing fired → INCONCLUSIVE" "$CLASS_VERDICT" INCONCLUSIVE
arm_classify no yes garbage no
chk "non-numeric Stop count is treated as 0 → INCONCLUSIVE, never REFUTE" "$CLASS_VERDICT" INCONCLUSIVE

# ---------------------------------------------------------------------------
echo "### 8. CREDENTIAL GATE — the arm refuses before provisioning a sandbox"
# ---------------------------------------------------------------------------
STUB="$ROOT/stubbin"; mkdir -p "$STUB"
cat > "$STUB/claude" <<'EOF'
#!/usr/bin/env bash
# stub: answers --version; installs nothing; never spawns a session
case "${1:-}" in --version) echo "0.0.0 (stub)";; esac
exit 0
EOF
chmod +x "$STUB/claude"
export TMPDIR="$ROOT/tmp"; mkdir -p "$TMPDIR"
out=$(cd "$REPO" && PATH="$STUB:$PATH" env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN \
      bash "$ARM" 2>"$ROOT/gate.err"); rc=$?
chk "no credential → exit 2" "$rc" 2
case "$(cat "$ROOT/gate.err")" in *"no credential"*) ok "stderr names the missing credential" ;; *) bad "stderr does not name the credential: $(head -c 300 "$ROOT/gate.err")" ;; esac
case "$out" in *"=== 1. Sandbox"*) bad "a sandbox was provisioned before the gate" ;; *) ok "no sandbox banner — refused before provisioning" ;; esac
chk "no sandbox directory created under TMPDIR" "$(find "$TMPDIR" -maxdepth 1 -name 'dhx-cache-probe-*' | wc -l)" 0
# Discriminating pair: a (dummy) credential passes the gate and the arm proceeds
# to its step-5 exit 3 — the stub installed no cache manifest.
out=$(cd "$REPO" && PATH="$STUB:$PATH" ANTHROPIC_API_KEY=probe-dummy-not-a-key \
      bash "$ARM" 2>"$ROOT/pass.err"); rc=$?
chk "dummy credential → passes the gate, reaches step 5 (exit 3: no cache hooks.json)" "$rc" 3
case "$out" in *"=== 1. Sandbox"*) ok "sandbox banner printed — the gate keyed on the variable, not on the rest of pre-flight" ;; *) bad "no sandbox banner with a credential set" ;; esac
chk "the arm's sandbox landed under the probe's TMPDIR (cleaned by trap)" "$(find "$TMPDIR" -maxdepth 1 -name 'dhx-cache-probe-*' | wc -l)" 1
unset TMPDIR

# ---------------------------------------------------------------------------
echo "### 9. WIRING — the arm uses the lib and carries the measured tag"
# ---------------------------------------------------------------------------
chk "arm sources lib/empirical-arm-classify.sh" "$(grep -cE '^source .*lib/empirical-arm-classify.sh"?$' "$ARM")" 1
chk "arm calls arm_classify with four observations" "$(grep -cE '^arm_classify "\$MARKER_FIRED" "\$CONTROL_FIRED" "\$STOPS_DISPATCHED" "\$AUTH_FAILED"' "$ARM")" 1
chk "arm carries no inline REFUTE assignment (the pre-fix rule is gone)" "$(grep -c 'CLASS_LABEL="REFUTE' "$ARM")" 0
chk "arm is tagged # CC-STDERR-EXEMPT: exactly once" "$(grep -c '^# CC-STDERR-EXEMPT:' "$ARM")" 1
chk "arm no longer carries # CC-STDERR-UNMEASURED:" "$(grep -c '^# CC-STDERR-UNMEASURED:' "$ARM")" 0
chk "lib pins the anchored Stop regex" "$(grep -c "^ARM_STOP_RE='\\\\\[DEBUG\\\\\] \"Hook Stop \\\\(Stop\\\\) (success|error):'" "$LIB")" 1

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
