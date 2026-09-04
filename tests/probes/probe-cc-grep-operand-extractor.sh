#!/usr/bin/env bash
# SAFE_FOR_LIVE: yes
# probe-cc-grep-operand-extractor.sh
#
# 1. Invariant: CC's grep-family path-operand extractor — the code that decides WHICH operands
#    a `grep`/`rg` segment is charged with reading — behaves as the committed 2.1.259 fixture
#    records, and the claims that retired dhx-cd-compound-read-allow.sh hold against BOTH the
#    fixture and the newest INSTALLED build:
#      (a) on 2.1.259 a ` -- -` marker appended AFTER the pattern does NOT suppress rg's `["."]`
#          default — it adds two operands (`--`, `-`) and keeps the `.` (ARM 2 was
#          classifier-inert on the build it was written for; 2.1.261 already differs — census);
#      (b) a non-recursive grep with no operand extracts `[]` — nothing to suppress (ARM 2 had
#          no domain there);
#      (c) post-pattern options (`-A12`, `--include=*.sh`) are extracted AS OPERANDS — the two
#          upstream shapes recorded as hook-unfixable.
#    The hook that answered this circuit is retired: this probe also pins that the stub is
#    inert and unregistered, and that the disjointness corpus no longer counts it a producer.
# 2. Backs: docs/decisions.md "dhx-cd-compound-read-allow — RETIRED" row (2026-09-04) + HP-060.
# 3. Run: bash tests/probes/probe-cc-grep-operand-extractor.sh
#
# Two oracles, deliberately separate (the 2026-09-04 prompt § 3.2):
#   FIXTURE  tests/fixtures/cc/2.1.259-grep-operand-extractor.js — the extractor lifted
#            verbatim from 2.1.259, committed so the evidence keeps running after that build
#            is uninstalled. These cells never touch an installed binary.
#   LIVE     the newest build under ~/.local/share/claude/versions/, resolved at run time and
#            named in the output. The functions are located by STRUCTURAL anchors — real flag
#            names in the option Sets, the stable `rg:(e)=>NAME(e,new Set([...]),["."])` call
#            site — never by minified identifiers, which churn every build. An anchor that
#            stops matching FAILS LOUDLY; a probe that extracts nothing and passes is how the
#            retired hook's premise survived 169 green cells.
#            Vectors that differ from the fixture are a DRIFT CENSUS (NOTE lines + one OK that
#            the census ran), not failures: the extractor is upstream's to change. Only the
#            retirement's load-bearing claims (a)–(c) are asserted on the live build.
#
# The execution-fidelity cells at the end are kept on purpose and labelled NON-LOAD-BEARING:
# they prove ` -- -` does not change what RUNS, which is true, and which is exactly the claim
# that stood in for "does not change what the CLASSIFIER sees" for a day. Never again.
#
# Read-only: reads the fixture, the installed executables (grep -aob + tail/head seeks), the
# stub, the manifest, the disjointness probe and SAFE_FOR_LIVE.md. Writes only under mktemp.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE="$REPO/tests/fixtures/cc/2.1.259-grep-operand-extractor.js"
STUB="$REPO/dhx/dhx-cd-compound-read-allow.sh"
PLUGIN_HOOKS="$REPO/dhx-plugin/plugins/dhx/hooks/hooks.json"
DISJOINT_PROBE="$REPO/tests/probes/probe-updatedinput-producer-disjointness.sh"
VERSIONS_DIR="${CC_VERSIONS_DIR:-$HOME/.local/share/claude/versions}"

pass=0; fail=0
ok()  { echo "OK   $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; fail=$((fail+1)); }
note(){ echo "NOTE $1"; }
ck()  { if [ "$1" -eq 0 ]; then ok "$2"; else bad "$2"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
command -v node >/dev/null 2>&1 || { bad "node is required (fixture and live cells are JS)"; echo "---"; echo "$pass passed, $fail failed"; exit 1; }

# --- The vector table: label | family | argv (JSON) | expected (2.1.259) ------------------------
# Expected values are what the fixture MUST produce; they are the measured 2026-09-04 outputs.
VECTORS='[
 ["rg pipeline filter, no operand",           "rg",   ["-v","zzz"],                       ["."]],
 ["rg + ARM 2 marker after the pattern",      "rg",   ["-v","zzz","--","-"],              ["--","-","."]],
 ["grep NON-recursive, no operand",           "grep", ["-n","zzz"],                       []],
 ["grep NON-recursive + ARM 2 marker",        "grep", ["-n","zzz","--","-"],              ["--","-"]],
 ["grep -rn bundle, no operand",              "grep", ["-rn","zzz"],                      ["."]],
 ["grep post-pattern -A12 read as a path",    "grep", ["pat","-A12","file"],              ["-A12","file"]],
 ["grep post-pattern --include= as a path",   "grep", ["-rn","pat","--include=*.sh","dir"], ["--include=*.sh","dir"]],
 ["rg marker BEFORE the pattern",             "rg",   ["-v","--","zzz","-"],              ["-"]],
 ["rg with a real file operand",              "rg",   ["-n","pat","src/a.py"],            ["src/a.py"]]
]'
printf '%s' "$VECTORS" > "$TMP/vectors.json"

# run_vectors <module-path> → one line per vector: <idx>\t<label>\t<got-json>
cat > "$TMP/run.js" <<'EOF'
const [,, modPath, vecPath] = process.argv;
const m = require(modPath);
const vectors = JSON.parse(require("fs").readFileSync(vecPath, "utf8"));
vectors.forEach(([label, fam, argv], i) => {
  let got;
  try { got = JSON.stringify(fam === "rg" ? m.rg(argv) : m.grepFamily(argv)); }
  catch (e) { got = "THREW:" + e.message; }
  process.stdout.write(`${i}\t${label}\t${got}\n`);
});
EOF

echo "--- 1. FIXTURE (2.1.259, committed — independent of any installed build) ---"
[ -f "$FIXTURE" ]; ck $? "fixture present at tests/fixtures/cc/2.1.259-grep-operand-extractor.js"
grep -q '^// SHA-256:' "$FIXTURE"; ck $? "fixture records its source executable SHA-256"
grep -q 'function Rst(e,n,r=\[\]){' "$FIXTURE"; ck $? "fixture carries the verbatim 2.1.259 extractor head"
FIX_OUT=$(node "$TMP/run.js" "$FIXTURE" "$TMP/vectors.json" 2>&1)
i=0
while IFS=$'\t' read -r idx label got; do
  want=$(jq -c ".[$idx][3]" "$TMP/vectors.json")
  if [ "$got" = "$want" ]; then ok "fixture: $label -> $got"; else bad "fixture: $label -> $got (want $want)"; fi
  i=$((i+1))
done <<< "$FIX_OUT"
[ "$i" -eq 9 ]; ck $? "fixture ran all 9 vectors"

# INVARIANT (the ARM 2 falsification): the rg marker cell must show `.` SURVIVING the marker.
printf '%s\n' "$FIX_OUT" | awk -F'\t' '$1==1' | grep -q '"\."\]$'
ck $? "fixture: \`--\` after the pattern never suppresses rg's \`.\` default (ARM 2 falsified)"

echo "--- 2. LIVE drift extractor (newest installed build, structural anchors) ---"
LIVE=""
if [ -d "$VERSIONS_DIR" ]; then
  LIVE=$(ls -1 "$VERSIONS_DIR" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
fi
if [ -z "$LIVE" ] || [ ! -f "$VERSIONS_DIR/$LIVE" ]; then
  note "no installed build under $VERSIONS_DIR — live cells skipped (fixture cells above still stand)"
else
  EXE="$VERSIONS_DIR/$LIVE"
  echo "     oracle build: $LIVE ($(stat -c%s "$EXE" 2>/dev/null || echo ?) bytes)"
  # Anchors — each must occur EXACTLY once, or the extraction is not trustworthy.
  a1=$(command grep -ac '"--exclude-dir","--include-dir"' "$EXE"); [ "$a1" = 1 ]; ck $? "anchor: grep-family option set occurs exactly once (got $a1)"
  a2=$(command grep -ac '"-T","--type-not"' "$EXE");               [ "$a2" = 1 ]; ck $? "anchor: rg option set occurs exactly once (got $a2)"
  RGLINE=$(command grep -aoh 'rg:(e)=>[A-Za-z0-9_$]*(e,new Set(\["-e","--regexp","-f","--file","-t"[^]]*\]),\["."\])' "$EXE" | head -1)
  [ -n "$RGLINE" ]; ck $? "anchor: rg call site \`rg:(e)=>NAME(e,new Set([...]),[\".\"])\` located"
  CALLEE=$(printf '%s' "$RGLINE" | sed -E 's/^rg:\(e\)=>([A-Za-z0-9_$]+)\(.*/\1/')
  RGSET=$(printf '%s' "$RGLINE" | sed -E 's/^[^[]*(\[[^]]*\]).*/\1/')
  ROFF=$(command grep -aob "function $CALLEE(" "$EXE" | head -1 | cut -d: -f1)
  [ -n "$ROFF" ]; ck $? "extractor function \`$CALLEE\` located by the rg call site (offset ${ROFF:-none})"
  GOFF=$(command grep -aob '"--exclude-dir","--include-dir"' "$EXE" | head -1 | cut -d: -f1)
  if [ -n "$ROFF" ] && [ -n "$GOFF" ] && [ "$GOFF" -gt "$ROFF" ]; then
    # Span: from the extractor's head through the grep-family arrow function that contains
    # the grep anchor. The arrow's end is the balanced `}` after the anchor.
    SPAN_LEN=$((GOFF - ROFF + 1200))
    tail -c +$((ROFF + 1)) "$EXE" | head -c "$SPAN_LEN" | tr -d '\000' > "$TMP/span.raw"
    node - "$TMP/span.raw" "$CALLEE" "$RGSET" "$TMP/live.js" <<'EOF'
const fs = require("fs");
const [,, rawPath, callee, rgSet, outPath] = process.argv;
let raw = fs.readFileSync(rawPath, "utf8");
const anchor = raw.indexOf('"--exclude-dir","--include-dir"');
if (anchor < 0) { console.error("anchor lost inside span"); process.exit(2); }
// Walk back from the anchor to the `=(e)=>{` that opens the grep-family arrow, then to the
// identifier before it; walk forward to that arrow's balanced close.
const openIdx = raw.lastIndexOf("=(e)=>{", anchor);
if (openIdx < 0) { console.error("grep-family arrow head not found"); process.exit(2); }
const nameMatch = raw.slice(0, openIdx).match(/([A-Za-z0-9_$]+)$/);
if (!nameMatch) { console.error("grep-family arrow name not found"); process.exit(2); }
const astName = nameMatch[1];
let depth = 0, end = -1;
for (let i = openIdx + 6; i < raw.length; i++) {
  const c = raw[i];
  if (c === "{") depth++;
  else if (c === "}") { depth--; if (depth === 0) { end = i; break; } }
}
if (end < 0) { console.error("grep-family arrow not closed inside span"); process.exit(2); }
// The span must begin at the extractor head and end at the arrow's close. Rewrite the
// leading `var X=`/`,X=` so the whole thing is one statement list.
let span = raw.slice(0, end + 1);
span = span.replace(/(\}|^)(var |,)([A-Za-z0-9_$]+)=\(e\)=>\{/g, (m, pre, kw, nm) => `${pre}var ${nm}=(e)=>{`);
const src = `${span};\nvar __rg=(e)=>${callee}(e,new Set(${rgSet}),["."]);\nreturn {grepFamily:${astName}, rg:__rg, extractOperands:${callee}, names:{callee:"${callee}", ast:"${astName}"}};`;
let mod;
try { mod = new Function(src)(); }
catch (e) { console.error("span does not evaluate: " + e.message); process.exit(2); }
fs.writeFileSync(outPath, `module.exports = (${new Function(src).toString()})();\n`);
process.stdout.write(`${mod.names.callee}\t${mod.names.ast}\n`);
EOF
    rc=$?
    if [ $rc -eq 0 ] && [ -s "$TMP/live.js" ]; then
      ok "live extractor evaluates (callee=$CALLEE)"
      LIVE_OUT=$(node "$TMP/run.js" "$TMP/live.js" "$TMP/vectors.json" 2>&1)
      drift=0; n=0
      while IFS=$'\t' read -r idx label got; do
        want=$(jq -c ".[$idx][3]" "$TMP/vectors.json")
        n=$((n+1))
        if [ "$got" = "$want" ]; then ok "live $LIVE agrees with fixture: $label -> $got"
        else drift=$((drift+1)); note "live $LIVE DIFFERS from 2.1.259 fixture: $label -> $got (fixture $want)"; fi
      done <<< "$LIVE_OUT"
      [ "$n" -eq 9 ]; ck $? "live: drift census ran over all 9 vectors ($drift differ from the 2.1.259 fixture)"
      # The load-bearing claims, asserted on the LIVE build regardless of the census. (a) is
      # deliberately NOT asserted live: measured 2026-09-04, 2.1.261's extractor already treats
      # a post-pattern marker differently from 2.1.259 (["--","-"] vs ["--","-","."]) — the
      # census line above records that, and the retirement rests on the fixture, where the
      # hook was built and claimed to work. What must still hold live is the default itself:
      printf '%s\n' "$LIVE_OUT" | awk -F'\t' '$1==0 && $3=="[\".\"]" {f=1} END{exit !f}'
      ck $? "live: (a) a pipeline rg with no operand still extracts [\".\"] — the default-operand mechanism is present"
      printf '%s\n' "$LIVE_OUT" | awk -F'\t' '$1==2' | grep -q $'\t\[\]$'
      ck $? "live: (b) non-recursive grep with no operand extracts [] — nothing for ARM 2 to suppress"
      printf '%s\n' "$LIVE_OUT" | awk -F'\t' '$1==5' | grep -q '"-A12"'
      ck $? "live: (c) post-pattern -A12 is still read as a path operand (upstream shape, hook-unfixable)"
    else
      bad "live extractor could not be evaluated from $LIVE (rc=$rc) — anchors need re-deriving; NOT a clean result"
    fi
  else
    bad "live: extractor head / grep anchor ordering unexpected (ROFF=${ROFF:-none} GOFF=${GOFF:-none})"
  fi
fi

echo "--- 3. the hook is RETIRED: inert stub, unregistered, out of the producer roster ---"
payload() { jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c,timeout:600000,description:"probe"}}'; }
for c in "cd $REPO; grep -n foo docs/backlog.md" "ls | rg -v 'zzz' | head -3" "cd /etc; grep -n root passwd"; do
  out=$(payload "$c" | bash "$STUB" 2>&1); rc=$?
  [ $rc -eq 0 ] && [ -z "$out" ]; ck $? "stub is silent and exit 0 on: $c"
done
out=$(printf 'not json' | bash "$STUB" 2>&1); [ $? -eq 0 ] && [ -z "$out" ]; ck $? "stub is silent and exit 0 on malformed stdin"
grep -q '^# Patterns: HP-012' "$STUB"; ck $? "stub declares HP-012 (the reason it still exists)"
grep -q 'RETIRED 2026-09-04' "$STUB"; ck $? "stub header names the retirement date"
! grep -q 'sets `k`' "$STUB"; ck $? "stub header does not restate the false \`-- -\` mechanism"
! grep -q 'cd-compound-read-allow' "$PLUGIN_HOOKS"; ck $? "plugin hooks.json no longer registers the hook"
grep -q 'RETIRED producer' "$DISJOINT_PROBE"; ck $? "disjointness corpus keeps the cd shapes as NEGATIVE rows (retired producer)"
if [ -L "$HOME/.claude/hooks/dhx-cd-compound-read-allow.sh" ]; then
  [ "$(readlink -f "$HOME/.claude/hooks/dhx-cd-compound-read-allow.sh")" = "$(readlink -f "$STUB")" ]
  ck $? "installed symlink (still present until registrations drain) resolves to the inert stub"
else
  note "installed symlink already removed (post-drain state)"
fi
grep -q 'probe-cc-grep-operand-extractor.sh' "$REPO/tests/probes/SAFE_FOR_LIVE.md"; ck $? "SAFE_FOR_LIVE.md carries this probe's row"
! grep -q 'probe-dhx-cd-compound-read-allow.sh' "$REPO/tests/probes/SAFE_FOR_LIVE.md"; ck $? "SAFE_FOR_LIVE.md no longer lists the retired probe name"

echo "--- 4. execution fidelity (NON-LOAD-BEARING — proves what RUNS, never what the classifier sees) ---"
eqx() {
  local a b ra rb
  a=$(cd "$REPO" && eval "$1" 2>&1); ra=$?
  b=$(cd "$REPO" && eval "$2" 2>&1); rb=$?
  if [ "$a" = "$b" ] && [ "$ra" -eq "$rb" ]; then ok "$3"; else bad "$3 (rc $ra vs $rb)"; fi
}
eqx "ls | grep -H 'docs'"     "ls | grep -H 'docs' -- -"     "grep -H: \` -- -\` is execution-identical (and classifier-inert, see § 1)"
eqx "ls | grep 'zzznomatch'"  "ls | grep 'zzznomatch' -- -"  "no-match exit code preserved by \` -- -\`"
if command -v rg >/dev/null 2>&1; then
  eqx "ls | rg -v 'docs' | head -3" "ls | rg -v 'docs' -- - | head -3" "rg -v: \` -- -\` is execution-identical (and adds two classifier operands, see § 1)"
fi

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
