#!/usr/bin/env bash
# probe-dirty-tree-attribution-gate.sh — dirty-tree attribution allowlist gate +
# strict fail-open wrapper regression probe.
# SAFE_FOR_LIVE: yes
#
# Exercises: (1) a non-allowlisted repo emits the pre-enrichment bare-count line
# BYTE-IDENTICAL with NO helper invocation; (2) helper absent / hung / malformed /
# wrong-version / oversize each degrade to the byte-identical bare line; (3) helper
# exit 3 (dhx-who serialization canary) earns the bare line PLUS one factual canary
# line — the one loud degrade; (4) the enriched path emits the payload INSTEAD of
# the bare line and passes --repo <toplevel> + --self <session_id> (HP-015);
# (5) clean-tree and DHX_SKIP_DIRTY_CHECK=1 paths stay silent exit-0; (6) no banned
# action verb and no relative-age token reaches stdout in any scenario.
# Backs: docs/decisions.md 2026-07-28 dirty-tree attribution enrichment row.
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
    wrongver) echo "dhx-who protocol 2" ;;
    *)        echo "dhx-who protocol 1" ;;
  esac
  exit 0
fi
case "$2" in
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

# ---- 4. malformed payload ----------------------------------------------------
OUT=$(DHX_DIRTY_TREE_ALLOWLIST="$REPO_TOP" DHX_DIRTY_TREE_WHO="$S_MALF" \
      run_hook "$STDIN_JSON")
check_eq "malformed payload degrades to bare line" "$OUT" "$BARE"

# ---- 5. wrong protocol version: degrade, payload never requested -------------
: > "$CALLLOG"
OUT=$(DHX_DIRTY_TREE_ALLOWLIST="$REPO_TOP" DHX_DIRTY_TREE_WHO="$S_WVER" \
      run_hook "$STDIN_JSON")
check_eq "wrong protocol version degrades to bare line" "$OUT" "$BARE"
check_eq "wrong version stops at --version (no payload call)" "$(cat "$CALLLOG")" "--version"

# ---- 6. exit 3: the loud canary degrade --------------------------------------
OUT=$(DHX_DIRTY_TREE_ALLOWLIST="$REPO_TOP" DHX_DIRTY_TREE_WHO="$S_EX3" \
      run_hook "$STDIN_JSON")
check_eq "exit-3 first line is the bare count" "$(echo "$OUT" | head -1)" "$BARE"
if echo "$OUT" | sed -n 2p | grep -q "canary failed (helper exit 3"; then \
  ok "exit-3 second line is the factual canary notice"; \
  else bad "exit-3 canary line missing/wrong: [$(echo "$OUT" | sed -n 2p)]"; fi
check_eq "exit-3 emits exactly two lines" "$(echo "$OUT" | wc -l | tr -d ' ')" "2"

# ---- 7. good payload: emitted INSTEAD of bare line, correct argv --------------
: > "$CALLLOG"
OUT=$(DHX_DIRTY_TREE_ALLOWLIST="$REPO_TOP" DHX_DIRTY_TREE_WHO="$S_GOOD" \
      run_hook "$STDIN_JSON")
check_eq "enriched path first line is the payload header" \
  "$(echo "$OUT" | head -1 | cut -c1-19)" "[shared-tree state]"
if echo "$OUT" | grep -qF "$BARE"; then \
  bad "enriched path also emitted the bare line (payload must replace it)"; \
  else ok "enriched path emits payload instead of bare line"; fi
if grep -qF -- "--repo $REPO_TOP --self probe-uuid-1234" "$CALLLOG"; then \
  ok "helper invoked with --repo <toplevel> --self <session_id>"; \
  else bad "helper argv wrong: $(cat "$CALLLOG")"; fi

# ---- 8. oversize payload -------------------------------------------------------
OUT=$(DHX_DIRTY_TREE_ALLOWLIST="$REPO_TOP" DHX_DIRTY_TREE_WHO="$S_BIG" \
      run_hook "$STDIN_JSON")
check_eq "oversize payload degrades to bare line (never truncates)" "$OUT" "$BARE"

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
for stub in "$S_GOOD" "$S_MALF" "$S_EX3" "$TMP/no-such-helper"; do
  DHX_DIRTY_TREE_ALLOWLIST="$REPO_TOP" DHX_DIRTY_TREE_WHO="$stub" \
    run_hook "$STDIN_JSON" >> "$ALL_OUT"
done
if grep -Eiq 'abandoned|cleanup candidate|\bstale\b|safe to remove' "$ALL_OUT"; then \
  bad "banned action-suggestive vocabulary reached stdout"; \
  else ok "no banned action verb in any hook-owned output"; fi
if grep -Eq '[0-9]+ ?(s|m|h|d|min|mins|minutes|hours|days) ago' "$ALL_OUT"; then \
  bad "relative-age token reached stdout"; \
  else ok "no relative-age token in any hook-owned output"; fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
