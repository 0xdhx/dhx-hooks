#!/usr/bin/env bash
# probe-dirty-tree-attribution-gate.sh — dirty-tree attribution allowlist gate +
# strict fail-open wrapper regression probe.
# SAFE_FOR_LIVE: yes
#
# Exercises: (1) a non-allowlisted repo emits the pre-enrichment bare-count line
# BYTE-IDENTICAL with NO helper invocation; (2) helper absent / hung / malformed /
# `--version`-rc-nonzero / zero-byte each degrade to the byte-identical bare line
# SILENTLY (the TRANSIENT class); (3) the three PERMANENT degrades each earn the
# bare line PLUS exactly one factual notice line — exit 3 (dhx-who serialization
# canary), protocol mismatch, and over-cap payload; (4) the enriched path emits the
# payload INSTEAD of the bare line and passes --repo <toplevel> + --self
# <session_id> (HP-015); (5) clean-tree and DHX_SKIP_DIRTY_CHECK=1 paths stay
# silent exit-0; (6) no banned action verb and no relative-age token reaches stdout
# in any scenario; (7) the OUTCOME LOG (2026-09-18): one TSV line per allowlisted run
# with the right outcome for every exit path, stdout byte-identical with and without it,
# fail-open on an unwritable path, rotation past 1 MiB, and hermetic — off under any
# seam, with a positive control that the default path IS written when no seam is set.
# Control-tested 2026-09-18 via DHX_DIRTY_TREE_HOOK_UNDER_TEST (null mutant GREEN):
# hermetic branch removed → RED · payload/version 124 split collapsed → RED each ·
# rotation removed → RED · ok-line dropped → RED · a log that echoes to stdout → RED.
#
# The transient/permanent split is the load-bearing invariant here, not an
# implementation detail: both defective guards fused a transient cause with a
# permanent one in a single `||`, so the permanent cause inherited the transient
# one's silence. The ANTI-NOISE arms (timeout, zero-byte, helper-absent,
# non-allowlisted) are what prove silence was not traded for spam.
# Backs: docs/decisions.md 2026-07-28 dirty-tree attribution enrichment row
#        + 2026-07-30 non-silent-degrade row + 2026-09-18 outcome-log section.
# Run: bash tests/probes/probe-dirty-tree-attribution-gate.sh
#
# All fixtures live in mktemp; the helper is always a local stub (the hook's
# DHX_DIRTY_TREE_WHO / _ALLOWLIST / _WHO_TIMEOUT seams) — the live transcript
# store, live pid-files, and the real dhx-who are never touched.
# DHX_DIRTY_TREE_HOOK_UNDER_TEST overrides the hook path (control-testing seam).
set -uo pipefail

HOOK="${DHX_DIRTY_TREE_HOOK_UNDER_TEST:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/dhx/dhx-dirty-tree.sh}"

PASS=0; FAIL=0
ok()  { echo "OK   $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; FAIL=$((FAIL+1)); }
check_eq() { # label, got, want
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected [$3], got [$2]"; fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# Defence in depth for the OUTCOME LOG: even a hook whose hermetic branch is broken (a
# mutant, a regression) writes its default log under $TMP, never the operator's real one.
export XDG_STATE_HOME="$TMP/state"

# ---- fixture repos ---------------------------------------------------------
REPO="$TMP/fixture-repo"
git init -q "$REPO"
git -C "$REPO" -c user.email=p@e -c user.name=p commit -q --allow-empty -m init
echo tracked > "$REPO/a.txt"
git -C "$REPO" add a.txt
git -C "$REPO" -c user.email=p@e -c user.name=p commit -q -m add
echo changed > "$REPO/a.txt"          # 1 modified
echo new > "$REPO/b.txt"              # 1 untracked
REPO_TOP=$(git -C "$REPO" rev-parse --show-toplevel)
BARE="Working tree has 2 uncommitted changes (1 modified, 1 untracked)"

CLEAN="$TMP/clean-repo"
git init -q "$CLEAN"
git -C "$CLEAN" -c user.email=p@e -c user.name=p commit -q --allow-empty -m init
CLEAN_TOP=$(git -C "$CLEAN" rev-parse --show-toplevel)

STDIN_JSON=$(printf '{"cwd":"%s","session_id":"probe-uuid-1234"}' "$REPO")

# ---- helper stubs ----------------------------------------------------------
CALLLOG="$TMP/calls.log"

mk_stub() { # name, payload-mode
  local f="$TMP/stub-$1.sh"
  cat > "$f" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLLOG"
if [ "\${1:-}" = "--version" ]; then
  case "$2" in
    wrongver) echo "dhx-who protocol 2"; exit 0 ;;
    verfail)  echo "helper blew up before printing a version"; exit 7 ;;
    *)        echo "dhx-who protocol 1"; exit 0 ;;
  esac
fi
case "$2" in
  zerobyte)  : ;;   # protocol-clean helper, empty payload
  good)
    printf '[shared-tree state] fixture-repo: 2 uncommitted (1 modified, 1 untracked). Snapshot 07-28 00:00Z\n'
    printf 'peer "probe peer" (CCS a) - LIVE, session busy; last observed edit 07-28 00:00Z\n'
    printf '  M a.txt (mtime 07-28 00:00Z)\n'
    ;;
  hang)      sleep 60 ;;
  malformed) printf 'not a payload at all\n' ;;
  exit3)     exit 3 ;;
  oversize)  printf '[shared-tree state] '; head -c 20000 /dev/zero | tr '\0' x; printf '\n' ;;
esac
exit 0
EOF
  chmod +x "$f"
  echo "$f"
}

S_GOOD=$(mk_stub good good)
S_HANG=$(mk_stub hang hang)
S_MALF=$(mk_stub malformed malformed)
S_WVER=$(mk_stub wrongver wrongver)
S_EX3=$(mk_stub exit3 exit3)
S_BIG=$(mk_stub oversize oversize)
S_VFAIL=$(mk_stub verfail verfail)
S_ZERO=$(mk_stub zerobyte zerobyte)

run_hook() { # stdin-json, then env overrides as leading VAR=val words via env
  printf '%s' "$1" | bash "$HOOK"
}

# ---- 1. non-allowlisted repo: bare line, zero helper invocations -----------
: > "$CALLLOG"
OUT=$(DHX_DIRTY_TREE_ALLOWLIST="/nonexistent-shared-tree" DHX_DIRTY_TREE_WHO="$S_GOOD" \
      run_hook "$STDIN_JSON")
check_eq "non-allowlisted repo emits byte-identical bare line" "$OUT" "$BARE"
if [ ! -s "$CALLLOG" ]; then ok "non-allowlisted repo never invokes the helper"; \
  else bad "helper was invoked for a non-allowlisted repo: $(cat "$CALLLOG")"; fi

# ---- 2. helper absent -------------------------------------------------------
OUT=$(DHX_DIRTY_TREE_ALLOWLIST="$REPO_TOP" DHX_DIRTY_TREE_WHO="$TMP/no-such-helper" \
      run_hook "$STDIN_JSON")
check_eq "helper absent degrades to bare line" "$OUT" "$BARE"

# ---- 3. helper hung: timeout fires ------------------------------------------
T0=$SECONDS
OUT=$(DHX_DIRTY_TREE_ALLOWLIST="$REPO_TOP" DHX_DIRTY_TREE_WHO="$S_HANG" \
      DHX_DIRTY_TREE_WHO_TIMEOUT=1 run_hook "$STDIN_JSON")
ELAPSED=$((SECONDS - T0))
check_eq "helper hung degrades to bare line" "$OUT" "$BARE"
if [ "$ELAPSED" -le 5 ]; then ok "hung helper bounded by timeout (${ELAPSED}s)"; \
  else bad "hook blocked ${ELAPSED}s despite 1s timeout"; fi
# ANTI-NOISE ARM (2026-07-30 ruling): a timeout is TRANSIENT — a per-run race on
# a fleet whose legitimate cold range (3.5-6.3s) sits close under the 8s bound.
# It must stay silent even though protocol/ceiling now speak.
check_eq "timeout stays silent — no degrade notice (transient)" \
  "$(echo "$OUT" | wc -l | tr -d ' ')" "1"

# ---- 4. malformed payload ----------------------------------------------------
OUT=$(DHX_DIRTY_TREE_ALLOWLIST="$REPO_TOP" DHX_DIRTY_TREE_WHO="$S_MALF" \
      run_hook "$STDIN_JSON")
check_eq "malformed payload degrades to bare line" "$OUT" "$BARE"

# ---- 5. wrong protocol version: degrade + SPEAK, payload never requested -----
# PERMANENT arm (2026-07-30): a helper that answered with a protocol this hook
# does not speak never self-heals — it earns one notice line.
: > "$CALLLOG"
OUT=$(DHX_DIRTY_TREE_ALLOWLIST="$REPO_TOP" DHX_DIRTY_TREE_WHO="$S_WVER" \
      run_hook "$STDIN_JSON")
check_eq "wrong protocol version first line is the bare count" \
  "$(echo "$OUT" | head -1)" "$BARE"
if grep -q 'protocol mismatch' <<<"$(sed -n 2p <<<"$OUT")"; then \
  ok "wrong protocol version emits the mismatch notice"; \
  else bad "protocol-mismatch notice missing/wrong: [$(echo "$OUT" | sed -n 2p)]"; fi
if grep -qF 'dhx-who protocol 2' <<<"$(sed -n 2p <<<"$OUT")"; then \
  ok "mismatch notice reports the OBSERVED protocol string"; \
  else bad "notice omits observed string: [$(echo "$OUT" | sed -n 2p)]"; fi
check_eq "wrong protocol version emits exactly two lines" \
  "$(echo "$OUT" | wc -l | tr -d ' ')" "2"
check_eq "wrong version stops at --version (no payload call)" "$(cat "$CALLLOG")" "--version"

# ---- 5b. --version probe FAILS (rc!=0): transient, stays silent --------------
# This is the split that matters: the old guard fused rc!=0 with a wrong string
# in one ||, so protocol drift inherited the silence of a broken probe.
OUT=$(DHX_DIRTY_TREE_ALLOWLIST="$REPO_TOP" DHX_DIRTY_TREE_WHO="$S_VFAIL" \
      run_hook "$STDIN_JSON")
check_eq "--version rc!=0 stays silent (transient, no notice)" "$OUT" "$BARE"

# ---- 6. exit 3: the loud canary degrade --------------------------------------
OUT=$(DHX_DIRTY_TREE_ALLOWLIST="$REPO_TOP" DHX_DIRTY_TREE_WHO="$S_EX3" \
      run_hook "$STDIN_JSON")
check_eq "exit-3 first line is the bare count" "$(echo "$OUT" | head -1)" "$BARE"
if grep -q "canary failed (helper exit 3" <<<"$(sed -n 2p <<<"$OUT")"; then \
  ok "exit-3 second line is the factual canary notice"; \
  else bad "exit-3 canary line missing/wrong: [$(echo "$OUT" | sed -n 2p)]"; fi
check_eq "exit-3 emits exactly two lines" "$(echo "$OUT" | wc -l | tr -d ' ')" "2"

# ---- 7. good payload: emitted INSTEAD of bare line, correct argv --------------
: > "$CALLLOG"
OUT=$(DHX_DIRTY_TREE_ALLOWLIST="$REPO_TOP" DHX_DIRTY_TREE_WHO="$S_GOOD" \
      run_hook "$STDIN_JSON")
check_eq "enriched path first line is the payload header" \
  "$(echo "$OUT" | head -1 | cut -c1-19)" "[shared-tree state]"
if grep -qF "$BARE" <<<"$OUT"; then \
  bad "enriched path also emitted the bare line (payload must replace it)"; \
  else ok "enriched path emits payload instead of bare line"; fi
if grep -qF -- "--repo $REPO_TOP --self probe-uuid-1234" "$CALLLOG"; then \
  ok "helper invoked with --repo <toplevel> --self <session_id>"; \
  else bad "helper argv wrong: $(cat "$CALLLOG")"; fi

# ---- 8. oversize payload: degrade + SPEAK, never truncates ---------------------
# PERMANENT arm (2026-07-30): an over-cap payload discards the one thing the
# design says is NOT re-derivable (the owner map), and persists while the tree
# stays this dirty. Derive the expected byte count from the stub itself so the
# assertion proves the notice reports the ACTUAL size, not a constant.
EXPECT_BIG=$(bash "$S_BIG" --repo "$REPO_TOP" 2>/dev/null | wc -c | tr -d ' ')
OUT=$(DHX_DIRTY_TREE_ALLOWLIST="$REPO_TOP" DHX_DIRTY_TREE_WHO="$S_BIG" \
      run_hook "$STDIN_JSON")
check_eq "oversize payload first line is the bare count" \
  "$(echo "$OUT" | head -1)" "$BARE"
if grep -qF "$EXPECT_BIG bytes vs 16384 limit" <<<"$(sed -n 2p <<<"$OUT")"; then \
  ok "over-cap notice reports actual bytes vs the cap ($EXPECT_BIG > 16384)"; \
  else bad "over-cap notice missing/wrong: [$(echo "$OUT" | sed -n 2p)]"; fi
if grep -q 'discarded whole, not truncated' <<<"$(sed -n 2p <<<"$OUT")"; then \
  ok "over-cap notice states the payload was discarded, not truncated"; \
  else bad "over-cap notice omits the discard-vs-truncate fact"; fi
check_eq "oversize payload emits exactly two lines" \
  "$(echo "$OUT" | wc -l | tr -d ' ')" "2"

# ---- 8b. zero-byte payload: transient, stays silent ---------------------------
# A protocol-clean helper that printed nothing is indistinguishable from a
# partial write under the documented two-file skew (F3) — same transient class.
OUT=$(DHX_DIRTY_TREE_ALLOWLIST="$REPO_TOP" DHX_DIRTY_TREE_WHO="$S_ZERO" \
      run_hook "$STDIN_JSON")
check_eq "zero-byte payload stays silent (transient, no notice)" "$OUT" "$BARE"

# ---- 8c. ANTI-NOISE: expected absence never speaks ----------------------------
# The arm that proves silence was not traded for spam. A not-installed helper and
# a non-allowlisted repo are EXPECTED absence, not breakage.
OUT=$(DHX_DIRTY_TREE_ALLOWLIST="$REPO_TOP" DHX_DIRTY_TREE_WHO="$TMP/no-such-helper" \
      run_hook "$STDIN_JSON")
check_eq "helper absent emits no notice (expected absence)" "$OUT" "$BARE"
OUT=$(DHX_DIRTY_TREE_ALLOWLIST="/nonexistent-shared-tree" DHX_DIRTY_TREE_WHO="$S_WVER" \
      run_hook "$STDIN_JSON")
check_eq "non-allowlisted repo emits no notice even on a bad helper" "$OUT" "$BARE"

# ---- 9. clean tree stays silent even when allowlisted --------------------------
OUT=$(DHX_DIRTY_TREE_ALLOWLIST="$CLEAN_TOP" DHX_DIRTY_TREE_WHO="$S_GOOD" \
      run_hook "$(printf '{"cwd":"%s"}' "$CLEAN")")
check_eq "clean tree emits nothing" "$OUT" ""

# ---- 10. suppression env still silent -------------------------------------------
OUT=$(DHX_SKIP_DIRTY_CHECK=1 DHX_DIRTY_TREE_ALLOWLIST="$REPO_TOP" \
      DHX_DIRTY_TREE_WHO="$S_GOOD" run_hook "$STDIN_JSON")
check_eq "DHX_SKIP_DIRTY_CHECK=1 emits nothing" "$OUT" ""

# ---- 11. wording guard over every captured output --------------------------------
ALL_OUT="$TMP/all-out.txt"
for stub in "$S_GOOD" "$S_MALF" "$S_EX3" "$S_WVER" "$S_BIG" "$S_VFAIL" "$S_ZERO" \
            "$TMP/no-such-helper"; do
  DHX_DIRTY_TREE_ALLOWLIST="$REPO_TOP" DHX_DIRTY_TREE_WHO="$stub" \
    run_hook "$STDIN_JSON" >> "$ALL_OUT"
done
if grep -Eiq 'abandoned|cleanup candidate|\bstale\b|safe to remove' "$ALL_OUT"; then \
  bad "banned action-suggestive vocabulary reached stdout"; \
  else ok "no banned action verb in any hook-owned output"; fi
if grep -Eq '[0-9]+ ?(s|m|h|d|min|mins|minutes|hours|days) ago' "$ALL_OUT"; then \
  bad "relative-age token reached stdout"; \
  else ok "no relative-age token in any hook-owned output"; fi

# ---- 12. OUTCOME LOG (2026-09-18): every allowlisted run is counted -------------
# The silent degrades stay silent to the session but not to the operator: one TSV
# line per allowlisted run, successes included (a rate needs its denominator).
LOGF="$TMP/who-outcomes.tsv"; : > "$LOGF"
last_outcome() { tail -1 "$LOGF" 2>/dev/null | cut -f3; }
logged() { # label, stub, want-outcome, [timeout]
  local n0; n0=$(wc -l < "$LOGF" 2>/dev/null || echo 0)
  DHX_DIRTY_TREE_LOG="$LOGF" DHX_DIRTY_TREE_ALLOWLIST="$REPO_TOP" DHX_DIRTY_TREE_WHO="$2" \
    DHX_DIRTY_TREE_WHO_TIMEOUT="${4:-8}" run_hook "$STDIN_JSON" >/dev/null
  check_eq "outcome log: $1 appends exactly one line" \
    "$(( $(wc -l < "$LOGF" 2>/dev/null || echo 0) - n0 ))" "1"
  check_eq "outcome log: $1 → $3" "$(last_outcome)" "$3"
}
logged "good payload" "$S_GOOD" ok
check_eq "outcome log: ok line carries toplevel, bytes and session id" \
  "$(tail -1 "$LOGF" | cut -f2,6)" "$REPO_TOP	probe-uuid-1234"
if [ "$(tail -1 "$LOGF" | cut -f5)" -gt 0 ]; then ok "outcome log: ok line records payload bytes"; \
  else bad "outcome log: ok line has no byte count: [$(tail -1 "$LOGF")]"; fi
if tail -1 "$LOGF" | cut -f4 | grep -Eq '^[0-9]+$'; then ok "outcome log: elapsed ms is an integer"; \
  else bad "outcome log: elapsed ms malformed: [$(tail -1 "$LOGF")]"; fi
S_VHANG="$TMP/stub-version-hang.sh"
printf '#!/usr/bin/env bash\nsleep 60\n' > "$S_VHANG"; chmod +x "$S_VHANG"
logged "hung --version" "$S_VHANG" version-timeout 1
logged "exit 3" "$S_EX3" canary
logged "oversize" "$S_BIG" over-cap
logged "zero-byte" "$S_ZERO" empty
logged "malformed" "$S_MALF" malformed
logged "wrong protocol" "$S_WVER" protocol-mismatch
logged "--version rc!=0" "$S_VFAIL" version-fail
logged "helper absent" "$TMP/no-such-helper" helper-absent
# The PAYLOAD run timing out (version answers, payload hangs) is the one a hot
# tree actually hits — distinct from a hung --version.
logged "payload timeout" "$S_HANG" timeout 1
S_RC5="$TMP/stub-rc5.sh"
printf '#!/usr/bin/env bash\n[ "${1:-}" = "--version" ] && { echo "dhx-who protocol 1"; exit 0; }\nexit 5\n' > "$S_RC5"
chmod +x "$S_RC5"
logged "other nonzero exit" "$S_RC5" exit-5
N=$(wc -l < "$LOGF")
DHX_DIRTY_TREE_LOG="$LOGF" DHX_DIRTY_TREE_ALLOWLIST="/nonexistent-shared-tree" \
  DHX_DIRTY_TREE_WHO="$S_GOOD" run_hook "$STDIN_JSON" >/dev/null
check_eq "outcome log: a non-allowlisted repo logs nothing" "$(wc -l < "$LOGF")" "$N"

# The log is not a voice: stdout is byte-identical with and without it.
for stub in "$S_GOOD" "$S_EX3" "$S_BIG" "$S_ZERO"; do
  A=$(DHX_DIRTY_TREE_ALLOWLIST="$REPO_TOP" DHX_DIRTY_TREE_WHO="$stub" run_hook "$STDIN_JSON")
  B=$(DHX_DIRTY_TREE_LOG="$LOGF" DHX_DIRTY_TREE_ALLOWLIST="$REPO_TOP" DHX_DIRTY_TREE_WHO="$stub" \
      run_hook "$STDIN_JSON")
  check_eq "outcome log leaves stdout byte-identical ($(basename "$stub"))" "$B" "$A"
done
# Fail-open: an unwritable log costs the line, never the output or the exit code.
OUT=$(DHX_DIRTY_TREE_LOG="/proc/no-such-dir/x.tsv" DHX_DIRTY_TREE_ALLOWLIST="$REPO_TOP" \
      DHX_DIRTY_TREE_WHO="$S_GOOD" run_hook "$STDIN_JSON"); RC=$?
check_eq "unwritable log: exit 0" "$RC" "0"
check_eq "unwritable log: payload still emitted" "$(echo "$OUT" | head -1 | cut -c1-19)" "[shared-tree state]"
# Rotation past 1 MiB keeps the log bounded.
RLOG="$TMP/rot.tsv"; head -c 1100000 /dev/zero | tr '\0' x > "$RLOG"
DHX_DIRTY_TREE_LOG="$RLOG" DHX_DIRTY_TREE_ALLOWLIST="$REPO_TOP" DHX_DIRTY_TREE_WHO="$S_GOOD" \
  run_hook "$STDIN_JSON" >/dev/null
check_eq "rotation: the full log moved to .1" "$(stat -c %s "$RLOG.1" 2>/dev/null)" "1100000"
check_eq "rotation: the fresh log holds just this run" "$(wc -l < "$RLOG" | tr -d ' ')" "1"

# Hermetic default. POSITIVE CONTROL first: with NO seam, a fake HOME whose
# default-allowlisted ~/repos/skills is the dirty repo logs helper-absent to the
# default path — so the negative below is not vacuous.
FH="$TMP/fakehome"; mkdir -p "$FH/repos"
git clone -q "$REPO" "$FH/repos/skills" 2>/dev/null
echo dirty > "$FH/repos/skills/c.txt"
DEF="$FH/.local/state/dhx/dirty-tree-who.tsv"
( unset XDG_STATE_HOME DHX_DIRTY_TREE_LOG DHX_DIRTY_TREE_WHO DHX_DIRTY_TREE_ALLOWLIST
  printf '{"cwd":"%s"}' "$FH/repos/skills" | HOME="$FH" bash "$HOOK" >/dev/null )
check_eq "hermetic control: no seam → default log written" "$(cut -f3 "$DEF" 2>/dev/null)" "helper-absent"
# NEGATIVE: a helper seam without DHX_DIRTY_TREE_LOG never touches the default log.
( unset XDG_STATE_HOME DHX_DIRTY_TREE_LOG DHX_DIRTY_TREE_ALLOWLIST
  printf '{"cwd":"%s"}' "$FH/repos/skills" | HOME="$FH" DHX_DIRTY_TREE_WHO="$S_GOOD" \
    bash "$HOOK" >/dev/null )
check_eq "hermetic: a WHO seam without the log seam writes no default log" "$(wc -l < "$DEF" | tr -d ' ')" "1"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
