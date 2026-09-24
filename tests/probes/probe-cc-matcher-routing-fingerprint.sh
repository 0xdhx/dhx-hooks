#!/usr/bin/env bash
# probe-cc-matcher-routing-fingerprint.sh
#
# SAFE_FOR_LIVE: yes   (reads ~/.local/share/claude/versions/* as bytes, never executes them;
#   hermetic cells run on the committed fixture and mktemp copies; --record appends one row to
#   config/cc-matcher-routing.tsv and is operator-invoked only)
# LIVE_RUNTIME: yes  (a CC install that changes the matcher routing cluster flips section C with the repo unchanged)
# LIVE_SUBJECT: tests/probes/probe-updatedinput-producer-disjointness.sh tests/probes/lib/cc-matcher-routing-fingerprint.py config/cc-matcher-routing.tsv
#
# 1. Invariant: the routine Claude Code routes a hook matcher through — the five-function
#    cluster that tests/probes/probe-updatedinput-producer-disjointness.sh mirrors as
#    BASH_MATCHER_FILTER — is byte-identical, after identifier normalization, to the one last
#    ACCEPTED in config/cc-matcher-routing.tsv. A CC release that changes it reds here, which is
#    the cue to re-derive the mirror; a release that leaves it alone passes with no source read.
#    This replaces the by-hand symbol hunt the 2026-09-19 (2.1.278) and 2026-09-23 (2.1.281)
#    adoption passes each repeated.
# 2. Backs: .planning/backlog/2026-08-24-disjointness-probe-enumeration-residuals.md — the
#    2026-09-19 operator ruling (land the H4 normalizer as this probe; positive controls = the
#    2.1.273 diff + a one-token mutant) — and the docs/decisions.md 2026-09-23 row for this probe.
#    Seed: reports/2026-09-19-h4-matcher-routing-fingerprint-cc-2.1.278/.
# 3. Run:    bash tests/probes/probe-cc-matcher-routing-fingerprint.sh
#    Record: bash tests/probes/probe-cc-matcher-routing-fingerprint.sh --record
#            (appends the newest installed build's row — do this for a CHANGED sha only after
#            re-deriving BASH_MATCHER_FILTER against `lib/... --norm <build>`)
#
# WHAT IT DOES NOT CLAIM: it resolves the cluster from literal anchors (see the lib's header).
# A routing change made OUTSIDE these five functions — a new caller that bypasses them, a
# widening applied before the caller — is invisible here. Differential verification of
# BASH_MATCHER_FILTER itself is the brief's criterion 1 and is NOT this probe.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$REPO/tests/probes/lib/cc-matcher-routing-fingerprint.py"
LEDGER="${CC_MRF_LEDGER:-$REPO/config/cc-matcher-routing.tsv}"
FIX="$REPO/tests/probes/fixtures/cc-matcher-routing/2.1.281.raw.js"
VERSIONS_DIR="${CC_VERSIONS_DIR:-$HOME/.local/share/claude/versions}"
# Seams for section D, which re-runs this file's section C against SYNTHETIC version dirs:
# CC_MRF_ONLY_LIVE=1 runs section C alone; CC_MRF_LEDGER points --record at a scratch copy.
ONLY_LIVE="${CC_MRF_ONLY_LIVE:-0}"

pass=0; fail=0
ok()  { echo "OK   $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; fail=$((fail+1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

ledger_sha() {  # ledger_sha <version> -> sha or ""
  awk -F'\t' -v v="$1" '!/^#/ && $1==v {print $2; exit}' "$LEDGER"
}
ledger_latest() {  # -> "<version> <sha>" of the highest recorded version
  awk -F'\t' '!/^#/ && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ {print $1" "$2}' "$LEDGER" | sort -V | tail -1
}
installed() {  # installed builds, ascending
  [ -d "$VERSIONS_DIR" ] || return 0
  find "$VERSIONS_DIR" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V
}
# fp <file> -> sets FP_RC, FP_SHA, FP_SYM, FP_ERR. The rc and a non-empty sha are both required
# before any sha is compared: an unresolved cluster must never read as "a sha that differs".
fp() {
  local out
  out=$(python3 "$LIB" "$1" 2>"$TMP/fp.err"); FP_RC=$?
  FP_SHA=$(sed -n 's/^sha256 //p' <<<"$out")
  FP_SYM=$(sed -n 's/^symbols //p' <<<"$out")
  FP_ERR=$(cat "$TMP/fp.err")
}

# --- --record -----------------------------------------------------------------------------
if [ "${1:-}" = "--record" ]; then
  NEWEST=$(installed | tail -1)
  [ -n "$NEWEST" ] || { echo "record: no installed CC build under $VERSIONS_DIR" >&2; exit 2; }
  [ -z "$(ledger_sha "$NEWEST")" ] || { echo "record: $NEWEST already recorded" >&2; exit 2; }
  fp "$VERSIONS_DIR/$NEWEST"
  [ "$FP_RC" = 0 ] && [ -n "$FP_SHA" ] || { echo "record: $NEWEST unresolved: $FP_ERR" >&2; exit 2; }
  read -r lv lsha <<<"$(ledger_latest)"
  note="probe --record"; [ "$FP_SHA" = "$lsha" ] || note="probe --record — CHANGED vs $lv, mirror re-derived"
  printf '%s\t%s\t%s\t%s\n' "$NEWEST" "$FP_SHA" "$(date +%F)" "$note" >> "$LEDGER"
  echo "recorded $NEWEST $FP_SHA ($FP_SYM)"
  exit 0
fi

if [ "$ONLY_LIVE" != 1 ]; then
echo "--- 0. harness ---"
command -v python3 >/dev/null 2>&1; r=$?; [ $r -eq 0 ] && ok "python3 available" || bad "PROBE ERROR python3 missing — nothing below can run"
[ -r "$LIB" ] && ok "lib present" || bad "PROBE ERROR lib missing: $LIB"
[ -r "$FIX" ] && ok "fixture present (2.1.281 raw cluster)" || bad "PROBE ERROR fixture missing: $FIX"
[ -r "$LEDGER" ] && ok "ledger present" || bad "PROBE ERROR ledger missing: $LEDGER"

echo "--- A. hermetic cells on the committed fixture ---"
S281=$(ledger_sha 2.1.281); S273=$(ledger_sha 2.1.273)

# NULL first: an unmutated copy must come back green, or every later "caught" is a crash.
cp "$FIX" "$TMP/base.js"
fp "$TMP/base.js"
[ "$FP_RC" = 0 ] && [ -n "$FP_SHA" ] && [ "$FP_SHA" = "$S281" ] \
  && ok "A1 NULL: fixture resolves (rc=0) to the ledger's 2.1.281 sha ${S281:0:12}… ($FP_SYM)" \
  || bad "A1 NULL: rc=$FP_RC sha='${FP_SHA:0:12}' want '${S281:0:12}' — $FP_ERR"
[ "$FP_SYM" = "S=_ho R=sAe C=deo N=eAe A=xOt" ] \
  && ok "A1b resolution names the five 2.1.281 functions by offset (S=_ho R=sAe C=deo N=eAe A=xOt)" \
  || bad "A1b resolved '$FP_SYM'"

# transform <name> <python-expr-on-s>: writes $TMP/<name>.js from base; rc!=0 if unchanged.
transform() {
  python3 - "$TMP/base.js" "$TMP/$1.js" "$2" <<'PY'
import sys
s = open(sys.argv[1], encoding='latin-1').read()
before = s
exec(sys.argv[3])
open(sys.argv[2], 'w', encoding='latin-1').write(s)
sys.exit(0 if s != before else 1)
PY
}
# mutant <name> <expr>: a transform that must differ from base by exactly ONE hunk.
mutant() {
  transform "$1" "$2" || { bad "PROBE ERROR mutant $1 changed nothing"; return 1; }
  local hunks
  hunks=$(diff "$TMP/base.js" "$TMP/$1.js" | grep -cE '^[0-9]')
  [ "$hunks" = 1 ] || { bad "PROBE ERROR mutant $1 differs from base by $hunks hunk(s), not 1"; return 1; }
}

# The historical positive control: 2.1.273's caller read `!s||!n` where 2.1.276+ reads
# `s===void 0||!n`. Re-applying that ONE token to the 2.1.281 cluster must reproduce the sha the
# H4 seed measured on the real 2.1.273 binary — the instrument discriminates a real cross-build
# change, and lands on the right one.
if mutant hist273 's = s.replace("return s===void 0||!n||", "return!s||!n||")'; then
  fp "$TMP/hist273.js"
  [ "$FP_RC" = 0 ] && [ -n "$FP_SHA" ] && [ "$FP_SHA" = "$S273" ] && [ "$FP_SHA" != "$S281" ] \
    && ok "A2 the 2.1.273 caller token re-applied reproduces the ledger's 2.1.273 sha ${S273:0:12}…" \
    || bad "A2 historical control: rc=$FP_RC sha='${FP_SHA:0:12}' want '${S273:0:12}'"
fi

if mutant router1 's = s.replace("n===\"*\"", "n===\"?\"")'; then
  fp "$TMP/router1.js"
  [ "$FP_RC" = 0 ] && [ -n "$FP_SHA" ] && [ "$FP_SHA" != "$S281" ] && [ "$FP_SHA" != "$S273" ] \
    && ok "A3 one-token router mutant (n===\"*\" -> n===\"?\") resolves AND changes the sha" \
    || bad "A3 router mutant: rc=$FP_RC sha='${FP_SHA:0:12}' (must resolve and differ)"
fi

# Rename invariance: the five names are what a re-minification changes; the sha must not move.
transform renamed 'import re
for a,b in [("_ho","QQa"),("sAe","QQb"),("deo","QQc"),("eAe","QQd"),("xOt","QQe")]:
    s = re.sub(r"(?<![\w$.])"+re.escape(a)+r"(?![\w$])", b, s)' || bad "PROBE ERROR rename transform changed nothing"
fp "$TMP/renamed.js"
[ "$FP_RC" = 0 ] && [ "$FP_SHA" = "$S281" ] && [ "$FP_SYM" = "S=QQa R=QQb C=QQc N=QQd A=QQe" ] \
  && ok "A4 all five functions renamed: same sha, resolved under the new names ($FP_SYM)" \
  || bad "A4 rename: rc=$FP_RC sha='${FP_SHA:0:12}' sym='$FP_SYM'"

# Name collision (measured: 2.1.278 carries two unrelated `function H2e(`): a same-named decoy
# ahead of the router must not be picked, and a spread-free hookMatcherFamilyNames method must
# not be taken for the alias anchor.
{ printf 'function sAe(e){return e}\nvar o={hookMatcherFamilyNames(_){return[]}};\n'; cat "$TMP/base.js"; } > "$TMP/decoy.js"
fp "$TMP/decoy.js"
[ "$FP_RC" = 0 ] && [ "$FP_SHA" = "$S281" ] \
  && ok "A5 same-named router decoy + non-spread alias decoy ahead of the cluster: same sha" \
  || bad "A5 decoys: rc=$FP_RC sha='${FP_SHA:0:12}' — $FP_ERR"

# A hijacked anchor must fail LOUDLY: a decoy carrying the splitter's literal ternary ahead of the
# real one makes S resolve to the decoy, which the router does not call — the coherence gate.
{ printf 'function ZZs(e,n,r){if(!(n?/^[a-zA-Z0-9_|, -]+$/:/^[a-zA-Z0-9_|]+$/).test(e))return}\n'; cat "$TMP/base.js"; } > "$TMP/hijack.js"
fp "$TMP/hijack.js"
[ "$FP_RC" = 2 ] && [ -z "$FP_SHA" ] && grep -q '^UNRESOLVED router' <<<"$FP_ERR" \
  && ok "A6 hijacked splitter anchor: exit 2 UNRESOLVED router (coherence gate), no sha printed" \
  || bad "A6 hijack: rc=$FP_RC sha='${FP_SHA:0:12}' err='$FP_ERR'"

if mutant noalias 's = s.replace("w=xOt(e,g,h)", "w=xOtZ(e,g,h)")'; then
  fp "$TMP/noalias.js"
  [ "$FP_RC" = 2 ] && [ -z "$FP_SHA" ] && grep -q '^UNRESOLVED router' <<<"$FP_ERR" \
    && ok "A7 router no longer calls the resolved alias helper: exit 2, no sha" \
    || bad "A7 coherence: rc=$FP_RC sha='${FP_SHA:0:12}' err='$FP_ERR'"
fi

if mutant noanchor 's = s.replace("!==\"PreModelSwitch\"&&", "!==\"PreModelSwap\"&&")'; then
  fp "$TMP/noanchor.js"
  [ "$FP_RC" = 2 ] && [ -z "$FP_SHA" ] && grep -q '^UNRESOLVED normalizer anchor' <<<"$FP_ERR" \
    && ok "A8 normalizer anchor gone: exit 2 UNRESOLVED, never a sha" \
    || bad "A8 anchor: rc=$FP_RC sha='${FP_SHA:0:12}' err='$FP_ERR'"
fi

cat "$TMP/base.js" "$TMP/base.js" > "$TMP/double.js"
fp "$TMP/double.js"
[ "$FP_RC" = 0 ] && [ "$FP_SHA" = "$S281" ] \
  && ok "A9 bundle embedded twice (2.1.270+ shape): same sha" \
  || bad "A9 doubled: rc=$FP_RC sha='${FP_SHA:0:12}'"

: > "$TMP/empty.js"
fp "$TMP/empty.js"
[ "$FP_RC" = 2 ] && [ -z "$FP_SHA" ] && ok "A10 empty input: exit 2, no sha" || bad "A10 empty: rc=$FP_RC"

echo "--- B. ledger ---"
rows=$(awk -F'\t' '!/^#/ && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+$/' "$LEDGER")
bad_rows=$(awk -F'\t' '!/^#/ && $1!="version" && NF>0 && ($1 !~ /^[0-9]+\.[0-9]+\.[0-9]+$/ || $2 !~ /^[0-9a-f]{64}$/ || NF!=4)' "$LEDGER")
[ -n "$rows" ] && [ -z "$bad_rows" ] && ok "every row is <x.y.z> TAB <64-hex> TAB <date> TAB <source>" || bad "malformed ledger row(s): $bad_rows"
dups=$(cut -f1 <<<"$rows" | sort | uniq -d)
[ -z "$dups" ] && ok "one row per version" || bad "duplicate version rows: $dups"
[ -n "$S273" ] && [ -n "$S281" ] && [ "$S273" != "$S281" ] \
  && ok "the 2.1.273 row differs from the 2.1.281 row (the recorded cross-build change the control reproduces)" \
  || bad "ledger lost its 2.1.273 / 2.1.281 control rows"

echo "--- D. section C's own verdicts, against SYNTHETIC version dirs ---"
# The live cell is the one that reds in anger, and on a quiet release cycle it only ever runs
# green — so its red paths are exercised here, on every run, instead of first in production.
live() {  # live <versions-dir> [--record] -> sets LV_RC, LV_OUT
  LV_OUT=$(CC_MRF_ONLY_LIVE=1 CC_VERSIONS_DIR="$1" CC_MRF_LEDGER="$TMP/ledger.tsv" bash "$0" "${@:2}" 2>&1); LV_RC=$?
}
# D's scratch ledger holds the FIXTURE's rows only, never the live tail: D asserts against the
# 2.1.281 fixture, so a live `--record` of any later build must not move D's "latest recorded".
awk -F'\t' '/^#/ || $1=="version" || $1=="2.1.273" || $1=="2.1.281"' "$LEDGER" >"$TMP/ledger.tsv"
cp "$TMP/ledger.tsv" "$TMP/ledger.orig"
mkdir -p "$TMP/v1" "$TMP/v2" "$TMP/v3" "$TMP/v4" "$TMP/v5"
cp "$TMP/base.js" "$TMP/v1/9.9.9"
live "$TMP/v1"
[ "$LV_RC" = 0 ] && grep -q '^OK   9.9.9: routing cluster matches the latest recorded build 2.1.281' <<<"$LV_OUT" && grep -q 'NOTE 9.9.9 is unrecorded' <<<"$LV_OUT" \
  && ok "D1 unrecorded newest build, unchanged cluster: pass + record NOTE" || { bad "D1 rc=$LV_RC (child output below)"; sed "s/^/     | /" <<<"$LV_OUT"; }
cp "$TMP/router1.js" "$TMP/v2/9.9.9"
live "$TMP/v2"
[ "$LV_RC" = 1 ] && grep -q '^FAIL 9.9.9: routing cluster CHANGED vs the latest recorded build 2.1.281' <<<"$LV_OUT" && grep -q '^     [<>]' <<<"$LV_OUT" \
  && ok "D2 unrecorded newest build, ONE token changed: exit 1 CHANGED, with the normalized diff" || { bad "D2 rc=$LV_RC (child output below)"; sed "s/^/     | /" <<<"$LV_OUT"; }
cp "$TMP/router1.js" "$TMP/v3/2.1.281"
live "$TMP/v3"
[ "$LV_RC" = 1 ] && grep -q '^FAIL 2.1.281: routing cluster CHANGED vs its own row' <<<"$LV_OUT" \
  && ok "D3 a RECORDED version whose bytes now hash differently: exit 1 against its own row" || { bad "D3 rc=$LV_RC (child output below)"; sed "s/^/     | /" <<<"$LV_OUT"; }
cp "$TMP/noanchor.js" "$TMP/v4/9.9.9"
live "$TMP/v4"
[ "$LV_RC" = 1 ] && grep -q '^FAIL 9.9.9: routing cluster UNRESOLVED' <<<"$LV_OUT" \
  && ok "D4 newest build whose anchor moved: exit 1 UNRESOLVED (never a pass, never a CHANGED)" || { bad "D4 rc=$LV_RC (child output below)"; sed "s/^/     | /" <<<"$LV_OUT"; }
live "$TMP/v5"
[ "$LV_RC" = 0 ] && grep -q '^SKIP no installed CC build' <<<"$LV_OUT" && grep -q '^0 passed, 0 failed$' <<<"$LV_OUT" \
  && ok "D5 no installed build: SKIP line, zero passes counted (a vacant live cell is not a pass)" || { bad "D5 rc=$LV_RC (child output below)"; sed "s/^/     | /" <<<"$LV_OUT"; }
live "$TMP/v1" --record
r1=$LV_RC; row=$(awk -F'\t' '$1=="9.9.9"' "$TMP/ledger.tsv")
live "$TMP/v1" --record
[ "$r1" = 0 ] && [ "$(cut -f2 <<<"$row")" = "$S281" ] && [ "$LV_RC" = 2 ] && grep -q 'already recorded' <<<"$LV_OUT" \
  && cmp -s <(head -n -1 "$TMP/ledger.tsv") "$TMP/ledger.orig" \
  && ok "D6 --record appends exactly one row with the resolved sha, refuses a second, touches no other line" \
  || bad "D6 record rc=$r1 row='$row' second rc=$LV_RC"
fi

echo "--- C. installed builds vs the ledger ---"
mapfile -t BUILDS < <(installed)
if [ "${#BUILDS[@]}" -eq 0 ]; then
  echo "SKIP no installed CC build under $VERSIONS_DIR — live cell NOT run (not a pass)"
else
  read -r LATEST_V LATEST_SHA <<<"$(ledger_latest)"
  NEWEST="${BUILDS[-1]}"
  for v in "${BUILDS[@]}"; do
    want=$(ledger_sha "$v")
    if [ -z "$want" ]; then
      [ "$v" = "$NEWEST" ] || { echo "     $v: unrecorded and not the newest — skipped"; continue; }
      want="$LATEST_SHA"; basis="the latest recorded build $LATEST_V"
    else
      basis="its own row"
    fi
    fp "$VERSIONS_DIR/$v"
    if [ "$FP_RC" != 0 ] || [ -z "$FP_SHA" ]; then
      bad "$v: routing cluster UNRESOLVED — ${FP_ERR:-no output}. An anchor moved: re-derive the lib's anchors from the new bundle before trusting any verdict."
    elif [ "$FP_SHA" = "$want" ]; then
      ok "$v: routing cluster matches $basis (${FP_SHA:0:12}…, $FP_SYM)"
      [ "$basis" = "its own row" ] || echo "     NOTE $v is unrecorded — \`bash $0 --record\` adds its row"
    else
      bad "$v: routing cluster CHANGED vs $basis (${want:0:12}… -> ${FP_SHA:0:12}…). Re-derive BASH_MATCHER_FILTER in probe-updatedinput-producer-disjointness.sh against the new routine, then \`bash $0 --record\`. Diff vs the fixture:"
      diff <(python3 "$LIB" --norm "$FIX" | tr ';' '\n') <(python3 "$LIB" --norm "$VERSIONS_DIR/$v" | tr ';' '\n') | sed 's/^/     /' | head -30
    fi
  done
fi

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
