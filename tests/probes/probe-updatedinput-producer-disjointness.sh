#!/usr/bin/env bash
# probe-updatedinput-producer-disjointness.sh
#
# Backs the 2026-08-23 decisions.md row "PreToolUse:Bash updatedInput producers
# made structurally disjoint (head-anchored classifiers + compound bail widened
# to bare `&`, `(`, `)` and NEWLINE)" and
# closes acceptance criterion 2 of
# `.planning/backlog/shipped/2026-08-18-pretooluse-bash-updatedinput-producer-race.md`.
#
# THE PREMISE THIS GUARDS
# -----------------------
# CC resolves competing `hookSpecificOutput.updatedInput` returns from
# same-matcher PreToolUse hooks in COMPLETION ORDER — the last hook process to
# finish wins, nondeterministically. Verified by direct source read of the CC
# 2.1.241 bundle: the PreToolUse runner consumes per-hook async generators via an
# unbounded `Promise.race` merge (`rOi`, called with no concurrency argument) and
# both consumers do a bare reassignment per `hookUpdatedInput` event. Manifest
# order in hooks.json decides NOTHING for spawned command hooks, so "documented
# precedence via ordering" is not an available remedy. Full chain with symbols:
# the brief's § Resolution of the semantics (2026-08-23).
#
# And because `updatedInput` REPLACES the whole tool-input object rather than
# merging (HP-041), the losing producer's rewrite does not degrade — it vanishes
# wholesale, silently. A memory cap losing that race to an output reducer means a
# runaway pytest runs UNCAPPED with no signal that anything was dropped.
#
# The remedy shipped is STRUCTURAL, not a pairwise yield: every producer
# classifies at the COMMAND HEAD, so two producers can only collide if they claim
# the same head. No hook carries knowledge of any other hook. This probe is what
# keeps that true.
#
# INVARIANT: no single Bash command may draw an `updatedInput` rewrite from more
# than one hook registered on the PreToolUse:Bash matcher. If this reds, the
# completion-order race is LIVE again for the named command — fix the classifier
# that over-matched; do not delete the corpus row.
#
# WHAT IT DOES
# ------------
# 1. Enumerates the PreToolUse:Bash hooks FROM the plugin manifest at runtime
#    (never a hardcoded producer list), so a future third rewriter is swept in
#    automatically the moment it is registered — under ANY matcher style that
#    routes Bash calls: exact `"Bash"`, an alternation member (`"Bash|BashOutput"`,
#    `"Edit|Bash"`), a matcher-less entry, or `"*"`. Exact-string matching alone
#    was a round-3 false-green; see the selector comment below. Decision-only
#    guards cost nothing here: they simply never emit `updatedInput`.
# 2. Feeds each corpus command to EVERY enumerated hook as a real PreToolUse
#    payload on stdin, and records which ones claim it. The HOOK is the unit under
#    test — the classifiers are never re-implemented here, because a copied regex
#    would drift from the thing it claims to describe. No hook is excluded on any
#    heuristic: an earlier version enrolled only hooks whose OWN source spelled
#    `updatedInput` on a non-comment line, and adversarial review broke it by
#    registering a rewriter that emitted through a sourced helper — the split
#    classed it decision-only, and the probe went green while an all-hooks run
#    found five real `pnpm`/`yarn` overlaps. Enrollment by source-text heuristic is
#    therefore banned here; the only cost it ever bought was ~1.7s.
# 3. FAILS on any command claimed by two or more producers.
#
# The corpus carries every command measured OVERLAPPING on 2026-08-23, in three
# families. All three are the SAME root cause wearing different clothes: the two
# classifiers disagreed about where a command head is.
#   (A) separator disagreement — `pip install six & pytest`. is_pytest split
#       segments on bare `&`/`(`/`)`; the reducer's compound bail-list carried
#       `&&` but not `&`. Realistic, and the reducer's rewrite of such a command
#       was independently wrong (it summarized pytest's output as install noise).
#   (B) install token in ARGUMENT position — `pytest tests/ pip install`,
#       `pytest --rootdir=/x/npm i`. The reducer matched an install token
#       anywhere space/slash-anchored while the cap matched only at segment
#       heads, so any pytest-headed command carrying such a token drew both.
#   (C) NEWLINE as a separator — `$'pytest\npip install six'`. Found by
#       adversarial review OF the (A)+(B) fix, which is the point worth
#       remembering: head-anchoring alone did not close the class, because
#       `grep -E` anchors `^` at every LINE start, not at the start of the
#       string. A head-anchored matcher therefore still claimed an install on
#       line 2 of a command whose real head was `pytest`. ~Half of all Bash tool
#       calls in the operator's transcript corpus are multi-line, so this was a
#       mainstream shape held disjoint only by the coincidence that nobody had
#       yet split an install and a pytest across two lines of one call.
#
# LIVENESS: a disjointness assertion passes trivially if nothing produces at all
# (a fail-open host, a broken classifier, a renamed script). So the probe also
# asserts that every hook whose own source identifies it as a rewriter actually
# produced at least once. This is a per-hook check and deliberately not a count:
# a bare `>= 2` threshold clears with three rewriters registered and one failing
# open silently, which is precisely the case the rule exists for. A vacuous green
# would be worse than a red.
#
# Static source-text capability survives HERE and only here — as the roster for
# this assertion, never as an enrollment filter for the sweep above. The failure
# modes it must be read against are distinct: a source-identified rewriter that
# emits nothing is either failing open on this host, OR is a newly registered
# producer for which nobody has added corpus rows yet. The second case is meant
# to hard-red: rows are the deliverable, not an optional extra.
#
# Run: bash tests/probes/probe-updatedinput-producer-disjointness.sh

# SAFE_FOR_LIVE: yes   (read-only: drives the in-repo hooks as subshells with
#   synthetic stdin and cwd=/tmp; the two producers only PRINT a rewritten command
#   string and never execute it; no fixtures, no repo/config/cache writes)
# LIVE_RUNTIME: no   (verdict depends only on in-repo hook sources + the in-repo
#   plugin manifest; no gsd-core surface is read, so an upstream install cannot
#   flip it)

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
MANIFEST="$ROOT/dhx-plugin/plugins/dhx/hooks/hooks.json"

PASS=0; FAIL=0
ck() { if [ "$1" -eq 0 ]; then printf 'OK   %s\n' "$2"; PASS=$((PASS+1)); else printf 'FAIL %s\n' "$2"; FAIL=$((FAIL+1)); fi; }
die() { printf 'FAIL %s\n' "$1"; echo "0 passed, 1 failed"; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required to enumerate the manifest"
[ -f "$MANIFEST" ] || die "plugin manifest not found: $MANIFEST"

# --- Enumerate producers from the manifest -----------------------------------
# Registered command strings look like:
#   bash "$HOME/.claude/hooks/<script>"          -> $ROOT/dhx/<script>
#   bash "${CLAUDE_PLUGIN_ROOT}/hooks/<script>"  -> $ROOT/dhx-plugin/plugins/dhx/hooks/<script>
# Resolving to the IN-REPO source (not the ~/.claude symlink) keeps the probe
# hermetic and makes it test what is committed, not what happens to be installed.
# MATCHER SELECTION — mirrors CC's OWN routing routine, not the manifest's syntax.
# ------------------------------------------------------------------------------
# The routine is a five-function cluster (read from CC 2.1.281, 2026-09-23; first
# derived from 2.1.241, restructured by 2.1.273). Minified names change every build,
# so they are given as ROLES — tests/probes/lib/cc-matcher-routing-fingerprint.py
# resolves each by literal anchor and `--raw <build>` prints the current text:
#   caller      keeps a hook when `tool_name === void 0 || !matcher ||
#               router(tool_name, normalizer(event, matcher), PERMISSIVE.has(event),
#                      aliases, void 0, tool_input)` — and PERMISSIVE CONTAINS
#               "PreToolUse", so the comma/space branch is always live here.
#   normalizer  strips a trailing [1m]/[2m] for Pre/PostModelSwitch only.
#   router      (tool, matcher, permissive, aliases, _, tool_input):
#
#     if (!matcher || matcher === "*") return true;
#     let members = splitter(matcher, permissive, aliases), fam = alias(tool, _, tool_input);
#     if (members !== void 0) return members.includes(tool) || fam.some(f => members.includes(f));
#     try { let re = new RegExp(matcher); if (re.test(tool)) return true;
#           /* + family names, name variants, tool_input-derived names */ return false }
#     catch { return false }
#
#   splitter    if (!(permissive ? /^[a-zA-Z0-9_|, -]+$/ : /^[a-zA-Z0-9_|]+$/).test(m)) return;
#               return m.split(permissive ? /[|,]/ : "|").map(s => s.trim())
#                       .filter(Boolean).flatMap(s => <alias-expand>(s, aliases));
#   alias       the tool's family names (hookMatcherFamilyNames) or an input-derived name.
#
# Any change to that cluster reds probe-cc-matcher-routing-fingerprint.sh, which is the
# cue to re-read it and re-check the two properties below.
#
# Two properties any selector here MUST reproduce, both of which cost us a review
# round when guessed instead of read:
#   1. The "simple" fast path splits on `|` AND `,`, and TRIMS each member — so
#      "Bash, Edit" and "Bash | Edit" both route Bash.
#   2. Anything not matching that character class falls through to an UNANCHORED
#      `new RegExp(matcher).test("Bash")`. So ".*", "Bash.*", "^Bash$", "Ba.h" and
#      "(Bash|Edit)" all route Bash — and CC's own diagnostics RECOMMEND the regex
#      style ("To match all tools from this server, use `mcp__...__.*`"), so this
#      is the encouraged form, not an exotic one.
#
# THE LESSON, earned across three review rounds and stated once: every "the probe
# sweeps it in automatically" claim is really a claim about the ENUMERATION, and an
# enumeration narrower than the platform's own routing is a FALSE GREEN. Audit what
# CC routes — from CC source — never what the manifest string looks like. Two
# earlier selectors (exact-equality, then hand-rolled alternation) each shipped a
# demonstrable false green for exactly this reason.
#
# Conservative by construction: the splitter additionally alias-expands each member,
# the simple path also accepts the tool's family names, and the regex path also tests
# family names, name variants and tool_input-derived names. All of these can only
# WIDEN what CC routes, never narrow it, so
# mirroring the core without alias expansion under-enrolls at worst — and this
# probe's failure direction for under-enrollment is a missed sweep, so if a live
# alias-routed rewriter ever appears, widen this to match.
BASH_MATCHER_FILTER='
def routes_bash($m):
  if $m == "" or $m == "*" then true
  elif ($m | test("^[a-zA-Z0-9_|, -]+$")) then
    ([$m | splits("[|,]")]
       | map(sub("^\\s+";"") | sub("\\s+$";""))
       | map(select(length > 0))
       | index("Bash")) != null
  else (try ("Bash" | test($m)) catch false)
  end;
.hooks.PreToolUse[]
  | select(routes_bash(.matcher // ""))
  | .hooks[].command'

mapfile -t RAW < <(jq -r "$BASH_MATCHER_FILTER" "$MANIFEST")
[ "${#RAW[@]}" -gt 0 ]; ck $? "manifest: PreToolUse:Bash matcher registers at least one hook"

# Pin the selector against a synthetic manifest covering EVERY routing form found
# in CC's router, so the round-3/round-4 regressions cannot come back silently. Fed on
# stdin, never written to disk (SAFE_FOR_LIVE: no fixtures).
#
# This fixture must DISCRIMINATE, which the first version of it did not: it carried
# only the three styles the then-current selector already handled, so it stayed
# green against a selector that was broken for ten other forms. Every row below is
# a form CC's router was verified to route (or refuse), so a narrowing edit to the filter
# reds here instead of silently shrinking the sweep.
SEL_GOT=$(jq -r "$BASH_MATCHER_FILTER" <<'FIXTURE_JSON' | tr '\n' ' '
{"hooks":{"PreToolUse":[
  {"matcher":"Bash",            "hooks":[{"command":"exact.sh"}]},
  {"matcher":"Bash|BashOutput", "hooks":[{"command":"alt-head.sh"}]},
  {"matcher":"Edit|Bash",       "hooks":[{"command":"alt-tail.sh"}]},
  {"matcher":"Bash||Edit",      "hooks":[{"command":"alt-empty.sh"}]},
  {"matcher":"Bash, Edit",      "hooks":[{"command":"comma.sh"}]},
  {"matcher":"Edit , Bash",     "hooks":[{"command":"comma-space.sh"}]},
  {"matcher":"Bash | Edit",     "hooks":[{"command":"pipe-space.sh"}]},
  {                             "hooks":[{"command":"nomatcher.sh"}]},
  {"matcher":"*",               "hooks":[{"command":"wildcard.sh"}]},
  {"matcher":".*",              "hooks":[{"command":"regex-any.sh"}]},
  {"matcher":"Bash.*",          "hooks":[{"command":"regex-prefix.sh"}]},
  {"matcher":"^Bash$",          "hooks":[{"command":"regex-anchored.sh"}]},
  {"matcher":"(Bash|Edit)",     "hooks":[{"command":"regex-group.sh"}]},
  {"matcher":"Ba.h",            "hooks":[{"command":"regex-dot.sh"}]},
  {"matcher":"Edit|Write",      "hooks":[{"command":"NOPE-unrelated.sh"}]},
  {"matcher":"BashOutput",      "hooks":[{"command":"NOPE-bashoutput.sh"}]},
  {"matcher":"bash",            "hooks":[{"command":"NOPE-lowercase.sh"}]}
]}}
FIXTURE_JSON
)
SEL_WANT="exact.sh alt-head.sh alt-tail.sh alt-empty.sh comma.sh comma-space.sh pipe-space.sh nomatcher.sh wildcard.sh regex-any.sh regex-prefix.sh regex-anchored.sh regex-group.sh regex-dot.sh "
[ "$SEL_GOT" = "$SEL_WANT" ]; ck $? "matcher selector mirrors CC's matcher router: pipe/comma/space alternation + matcher-less + wildcard + regex enroll; BashOutput/Edit|Write/bash do not"
[ "$SEL_GOT" = "$SEL_WANT" ] || printf '       want: %s\n       got:  %s\n' "$SEL_WANT" "$SEL_GOT"

HOOKS=(); NAMES=()
for entry in "${RAW[@]}"; do
  script=$(printf '%s' "$entry" | sed -E 's/.*hooks\/([^"]+)".*/\1/')
  case "$entry" in
    *'CLAUDE_PLUGIN_ROOT'*) path="$ROOT/dhx-plugin/plugins/dhx/hooks/$script" ;;
    *)                      path="$ROOT/dhx/$script" ;;
  esac
  # A manifest entry whose script is missing from the repo is drift, not a skip:
  # the probe would otherwise silently stop covering a live producer.
  [ -f "$path" ]; ck $? "manifest entry resolves to an in-repo script: $script"
  HOOKS+=("$path"); NAMES+=("$script")
done
echo "     (enumerated ${#HOOKS[@]} PreToolUse:Bash hooks from the manifest)"

# --- Corpus ------------------------------------------------------------------
# Every install-class head from the reducer's is_install and every pytest head
# from the cap's is_pytest (bare, path-prefixed, env-prefixed), the `uv`
# collision candidates that share a head token between `uv pip install` and
# `uv run pytest`, compound forms, and the 17 measured 2026-08-23 overlaps.
CORPUS=(
  # --- install-class heads: bare ---
  "npm install" "npm i" "npm ci" "npm add left-pad"
  "pnpm install" "pnpm add left-pad"
  "yarn" "yarn install" "yarn add left-pad"
  "pip install six" "pip3 install six" "uv pip install six"
  "python -m pip install six" "python3 -m pip install six" "python3.12 -m pip install six"
  # --- install-class heads: path-prefixed ---
  "/usr/local/bin/npm install" "/home/u/.venv/bin/pip install six"
  "./venv/bin/pip install six" "../env/bin/pip3 install ruff"
  "/opt/py/bin/python3 -m pip install six"
  # --- pytest heads: bare / path-prefixed / runner-prefixed ---
  "pytest" "pytest tests/" "pytest --co -q"
  "python -m pytest" "python3 -m pytest tests/" "python3.12 -m pytest"
  "poetry run pytest" "uv run pytest" "uv run python -m pytest"
  "/home/u/.venv/bin/pytest" "./venv/bin/pytest tests/" "poetry run /x/bin/pytest"
  # --- the uv head collision: `uv pip install` vs `uv run pytest` ---
  "uv pip install pytest" "uv pip install pytest-xdist" "uv run pytest tests/"
  # --- env-assignment prefixes (both classifiers strip these) ---
  "FOO=bar pip install six" "FOO=bar pytest" "FOO=bar BAZ=qux python -m pytest"
  "FOO=bar pytest pip install"
  # --- compound forms: the reducer bails, the cap wraps the whole thing ---
  "pip install -e . && pytest" "pip install six; pytest" "pytest && pip install six"
  "npm install | tee log" "pip install six > out.txt"
  "(pip install six)" "(pytest)"
  # --- MEASURED OVERLAP family (A): bare & / ( ) separator disagreement ---
  "pip install six & pytest"
  "pytest & pip install six"
  "npm install & pytest"
  "pip install -e . & pytest tests/"
  "pip install six ( pytest )"
  # --- MEASURED OVERLAP family (B): install token in ARGUMENT position ---
  "pytest -k pip install"
  "pytest tests/ pip install"
  "pytest --deselect tests/x.py pip install"
  "pytest -p no:cacheprovider pip install"
  "python -m pytest pip install"
  "uv run pytest pip install"
  "pytest --rootdir=/x/npm i"
  "pytest /x/npm i"
  "pytest /x/yarn add"
  "pytest tests/ npm ci"
  "pytest --basetemp=/tmp/pip install"
  # --- MEASURED OVERLAP family (C): NEWLINE as a separator ---
  # A newline separates commands exactly like `;`, and `grep -E` anchors `^` at
  # every LINE start rather than the start of the string — so a head-anchored
  # matcher will happily claim an install on line 2 of a command whose real head
  # is something else. Found by adversarial review of the head-anchoring change
  # itself; ~half of all Bash tool calls in the operator's transcript corpus are
  # multi-line, so this is a mainstream shape, not an exotic one.
  "pytest
pip install six"
  "pip install -e .
pytest"
  "npm install
pytest tests/"
  "pip install -r requirements.txt
python -m pytest tests/"
  "uv pip install pytest
uv run pytest"
  "set -e
pip install six
pytest"
  "export FOO=1
npm ci
pytest"
  "   pip install six
   pytest"
  # --- cd-compound heads (RETIRED producer, kept as negative rows) ---
  # dhx-cd-compound-read-allow.sh rewrote `cd <abs>; grep ... <rel>` and pipe-consuming grep
  # segments until 2026-09-04, when it was retired (docs/decisions.md row of that date). Its
  # rows stay in the corpus as shapes NO surviving producer may claim: a future rewriter that
  # starts matching a `cd` head would have to collide with the other two here to be caught.
  "cd /etc; grep -n root passwd"
  "cd /etc && grep -n root passwd"
  "cd /usr; grep -rn bin share"
  "cd /etc; grep -n root passwd; pytest"
  "cd /etc; grep -n root passwd && pip install six"
  "cd /etc; grep -n root passwd | tee log"
  "cd /etc; pytest tests/"
  "cd /etc; pip install six"
  "cd /etc; npm install"
  "cd /tmp; grep -n x .env"
  # --- neither should fire ---
  "echo pip install six" "grep pytest dhx/" "cat pytest.ini"
  "npm test" "npm run install" "pip download six"
  "git commit -m \"pip install and pytest\""
  "pytest -k 'pip install'"
)

# --- Drive every command through every hook ----------------------------------
# Process-count discipline: this loop is |CORPUS| x |HOOKS| hook invocations, and
# the suite runner caps each probe at 30s (D-16). A `jq` spawn per payload plus
# one per result put an early version at 26s standalone — inside the cap alone,
# over it under load, which surfaces as exit 124 and reads as a FAILED probe.
# So: all payloads are built in ONE jq call up front, and the result test is a
# shell pattern match rather than a jq parse. The hooks emit compact JSON, so a
# literal `"updatedInput"` substring is exactly as decisive as a jq lookup and
# costs no process.
#
# Measured on this box (32 cores): 3.8s idle, 5.9s under 8-core load, and 22.7s
# under FULL 32-core saturation — inside the cap in every case, but only ~24%
# headroom in the pathological one. `run-probes.sh` is serial, so the saturated
# case needs an unrelated concurrent build to arrive. If this probe ever reports
# exit 124, suspect host load before suspecting the corpus.
mapfile -t PAYLOADS < <(printf '%s\0' "${CORPUS[@]}" | jq -Rc --slurp '
  split("\u0000")[:-1][] |
  {tool_name:"Bash",cwd:"/tmp",tool_input:{command:.,timeout:600000,description:"disjointness probe"}}')
[ "${#PAYLOADS[@]}" -eq "${#CORPUS[@]}" ]; ck $? "payload builder produced one payload per corpus command (${#PAYLOADS[@]}/${#CORPUS[@]})"

# EVERY enumerated hook is driven over EVERY corpus row. No enrollment filter.
# The obvious cost control — skip hooks whose own source never spells
# `updatedInput` outside a comment — is the one thing this probe must not do: a
# rewriter emitting through a sourced helper reads as decision-only under that
# heuristic, and adversarial review demonstrated exactly that, going green on a
# registered producer whose `pnpm`/`yarn` handling overlapped in five places.
# Measured apples-to-apples with the one-shot payload builder below, the split
# bought ~1.9-2.1s against ~3.8s for the full sweep, under a 30s cap. That is
# 1.7s for a known false-green path.
declare -A PRODUCED_BY=()   # script name -> 1 if it ever produced
OVERLAP_ROWS=()
for n in "${!CORPUS[@]}"; do
  cmd="${CORPUS[$n]}"
  payload="${PAYLOADS[$n]}"
  claimers=()
  for i in "${!HOOKS[@]}"; do
    out=$(printf '%s' "$payload" | bash "${HOOKS[$i]}" 2>/dev/null)
    case "$out" in
      *'"updatedInput"'*)
        claimers+=("${NAMES[$i]}")
        PRODUCED_BY["${NAMES[$i]}"]=1
        ;;
    esac
  done
  if [ "${#claimers[@]}" -ge 2 ]; then
    OVERLAP_ROWS+=("$cmd  <-  ${claimers[*]}")
  fi
done

# --- The load-bearing assertion ----------------------------------------------
echo "=== disjointness: ${#CORPUS[@]} commands x ${#HOOKS[@]} manifest-enumerated hooks ==="
if [ "${#OVERLAP_ROWS[@]}" -eq 0 ]; then
  ck 0 "no command draws an updatedInput rewrite from two or more producers"
else
  ck 1 "${#OVERLAP_ROWS[@]} command(s) claimed by 2+ producers — the completion-order race is LIVE:"
  printf '       %s\n' "${OVERLAP_ROWS[@]}"
fi

# --- Liveness: every CAPABLE producer must actually have produced -------------
# Without this a fail-open host, a renamed script, or a classifier that stopped
# matching entirely would render the assertion above vacuously green.
#
# The check is per-hook, NOT a count. A bare `>= 2` threshold was the first
# design and it dies at exactly the moment the rule starts mattering: with three
# rewriters registered, two producing and the third failing open silently still
# clears a `>= 2` bar, so the probe reports green while concealing every overlap
# the silent one would have had. Demonstrated in review, 2026-08-23.
#
# The ROSTER for this assertion is derived statically from each enumerated script
# (a non-comment line mentioning `updatedInput`), so there is still no hardcoded
# producer list. Scope discipline matters: this heuristic decides only WHO MUST
# HAVE SPOKEN, never who gets driven — the sweep above drives all of them. A
# producer that assembles the key name dynamically or emits through a sourced
# helper is therefore still fully swept for overlaps; it merely escapes the
# liveness requirement, which under-asserts rather than false-greens.
CAPABLE=(); SILENT=()
for i in "${!HOOKS[@]}"; do
  awk '/updatedInput/ && $0 !~ /^[[:space:]]*#/ {found=1} END{exit !found}' "${HOOKS[$i]}" || continue
  CAPABLE+=("${NAMES[$i]}")
  [ -n "${PRODUCED_BY[${NAMES[$i]}]:-}" ] || SILENT+=("${NAMES[$i]}")
done

# The floor of 2 is the CURRENT producer count, not a law. It catches a producer
# silently disappearing (renamed, unregistered, deleted) — which is exactly the
# vacuous-green case — so it is not decoration. But if a producer is ever
# deliberately retired down to one, this reds for a legitimate reason, and a bare
# red with no explanation is how a correct assertion gets deleted by a hurried
# reader. Say so out loud.
[ "${#CAPABLE[@]}" -ge 2 ]; ck $? "liveness: at least 2 hooks are capable of producing updatedInput (${#CAPABLE[@]}: ${CAPABLE[*]:-none})"
[ "${#CAPABLE[@]}" -ge 2 ] || {
  echo "       Either a producer vanished (renamed/unregistered/deleted — investigate),"
  echo "       or one was DELIBERATELY retired. If retired: update this floor in the same"
  echo "       commit as the retirement. Do not delete the assertion — it is the only"
  echo "       thing standing between a vanished producer and a vacuous green."
}

if [ "${#SILENT[@]}" -eq 0 ]; then
  ck 0 "liveness: every capable producer actually produced (${#CAPABLE[@]}/${#CAPABLE[@]})"
else
  ck 1 "liveness: ${#SILENT[@]} capable producer(s) emitted NOTHING across the whole corpus — disjointness above is VACUOUS for them:"
  printf '       %s\n' "${SILENT[@]}"
  echo "       Two distinct causes, and they need different fixes:"
  echo "       (1) FAILING OPEN — an established producer stopped classifying, or its"
  echo "           host precondition is absent. For dhx-pytest-cgroup-cap.sh that is"
  echo "           usually missing cgroup support (check: . dhx/dhx-cgroup-cap.sh;"
  echo "           dhx_cgroup_available). A host that cannot run the cap cannot prove"
  echo "           the cap is disjoint."
  echo "       (2) NO CORPUS ROWS — a newly registered rewriter whose command shapes"
  echo "           nobody has added to CORPUS yet. This red is INTENTIONAL and the fix"
  echo "           is rows, not an exemption: an unexercised producer is swept for"
  echo "           overlaps only on shapes someone wrote down."
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
