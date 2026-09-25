#!/bin/bash
# probe-cc-stderr-classifier-net.sh
#
# SAFE_FOR_LIVE: yes  (read-only. Static census of in-repo probe sources plus a
#                      read-only grep/jq of the resolved live settings.json.
#                      Spawns no Claude Code child, writes nothing anywhere.)
# RUNTIME: ~2s
#
# CC-STDERR-EXEMPT: this probe IS the net. It classifies probe SOURCE TEXT and
#   permission-rule strings, never a Claude Code child's output; it spawns no
#   child at all.
#   Convention: tests/probes/README.md § "A classifier's INPUT is a surface too".
#
# THE NET FOR "a probe that classifies a CC child by grepping its output".
#
# WHY A NET AND NOT JUST A FIX. On 2026-09-18 three natural-heal watchdogs
# reported `timeout_124` on every rc=0 cell, 3/3. Nothing was wrong with the
# probes' logic: Claude Code lints the settings.json it is handed and echoes each
# questionable rule VERBATIM to stderr, the operator's live settings carry
# `Bash(timeout * gh *)`, and the literal word `timeout` therefore landed inside
# the string the classifier read. The classifier — the TOOTH — was fine. Its
# INPUT was contaminated, which neither layer of a guard inspects.
#
# `lib/cc-cell-stderr.sh` fixes the three. This file is the layer above: it
# decides WHICH probes have the shape at all, and refuses to let one exist
# unclassified. See tests/probes/README.md § "A guard has two layers, and either
# can be a spelling" — the population is the net, and a population defined by
# grepping for `claude -p` is a SPELLING. Measured while writing this probe: that
# spelling both over-counts (4 files match on a COMMENT and spawn no child) and
# under-counts (5 files reach a CC binary as `$CC_BIN` / `resolve-cc-binary` /
# `claude --version` and match none of it).
#
# SO THE NET IS DELIBERATELY OVER-INCLUSIVE AND FAILS CLOSED. It nets on every
# spelling by which a file in tests/probes/ can reach a Claude Code binary, and
# then requires each candidate to CLASSIFY ITSELF with exactly one tag:
#
#   # CC-STDERR: filtered           routes its capture through the filter
#   # CC-STDERR-EXEMPT: <why>       a config echo cannot reach its classifier,
#                                   stated as a claim WITH its measurement
#   # CC-STDERR-UNMEASURED: <what>  same mechanism, a surface not yet measured
#
# An untagged candidate is a RED for a human to triage, never a silent pass.
#
# WHAT THIS PROBE CAN AND CANNOT CATCH — stated rather than implied, because an
# overclaimed guard is the failure this repo keeps finding:
#   CAN  a new probe of this shape written with no tag (§ 2, fail-closed)
#   CAN  a `filtered` probe that stops sourcing or calling the filter (§ 3)
#   CAN  a live permission rule that a classifier in this tree matches (§ 5) —
#        the behavioural cell, generated from BOTH the live settings and the
#        regexes actually present in the tree, not from a hardcoded example
#   CAN  a new declared-open exposure landing untriaged (§ 4, asserted count)
#   CANT a `filtered` probe that calls the filter and DISCARDS the result. That
#        inversion is invisible to static text. It is covered instead by
#        probe-cc-binary-resolution.sh § 5, which drives the filter's BEHAVIOUR
#        on a verbatim live advisory with a positive control.
#
#        .planning/backlog/2026-09-18-probes-that-classify-a-cc-child-by-grepping-stderr-inherit-the-operators-settings-as-an-input-surface.md
#
# Run: bash tests/probes/probe-cc-stderr-classifier-net.sh
set -uo pipefail

PROBE_ID="probe-cc-stderr-classifier-net"
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/cc-cell-stderr.sh
source "$HERE/lib/cc-cell-stderr.sh"

PASS=0
FAIL=0
ok()   { printf 'OK   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
chk()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

# Every spelling by which a file under tests/probes/ can reach a CC binary.
# Over-inclusive ON PURPOSE: a false candidate costs one tag, a missed one is
# an unguarded classifier nobody ever looks at.
NET_RE='claude -p|claude --print|claude --version|claude --debug-file|\$CC_BIN|resolve-cc-binary|resolve_cc_binary'
TAG_RE='^# CC-STDERR(-EXEMPT|-UNMEASURED)?:'

# Pinned floors. A count that DROPS means the net stopped finding things.
FLOOR_CANDIDATES=21
EXPECT_UNMEASURED=0

# ---------------------------------------------------------------------------
echo "### 1. the net discovers candidates"
# ---------------------------------------------------------------------------
CANDIDATES=()
while IFS= read -r f; do
  [ -n "$f" ] && CANDIDATES+=("$f")
done < <(grep -lE "$NET_RE" "$HERE"/*.sh "$HERE"/lib/*.sh 2>/dev/null | sort)

N=${#CANDIDATES[@]}
echo "     net matched $N file(s) under tests/probes/"
if [ "$N" -ge "$FLOOR_CANDIDATES" ]; then
  ok "candidate count $N >= pinned floor $FLOOR_CANDIDATES"
else
  bad "candidate count $N < pinned floor $FLOOR_CANDIDATES — the net stopped finding files it used to find; do NOT lower the floor without explaining where they went"
fi

# ---------------------------------------------------------------------------
echo "### 2. fail-closed: every candidate classifies itself"
# ---------------------------------------------------------------------------
FILTERED=(); EXEMPT=(); UNMEASURED=(); UNTAGGED=()
for f in "${CANDIDATES[@]}"; do
  ntag=$(grep -cE "$TAG_RE" "$f")
  if [ "$ntag" -eq 0 ]; then
    UNTAGGED+=("$(basename "$f")"); continue
  fi
  if [ "$ntag" -gt 1 ]; then
    bad "$(basename "$f") carries $ntag CC-STDERR tags — exactly one is allowed"
    continue
  fi
  tag=$(grep -oE "$TAG_RE" "$f" | head -1)
  case "$tag" in
    '# CC-STDERR-EXEMPT:')     EXEMPT+=("$f") ;;
    '# CC-STDERR-UNMEASURED:') UNMEASURED+=("$f") ;;
    '# CC-STDERR:')            FILTERED+=("$f") ;;
    *)                         bad "$(basename "$f") unrecognized tag '$tag'" ;;
  esac
done

if [ "${#UNTAGGED[@]}" -eq 0 ]; then
  ok "all $N candidates carry exactly one CC-STDERR tag"
else
  for u in "${UNTAGGED[@]}"; do
    bad "UNTAGGED candidate: $u — it reaches a Claude Code binary and has not"
    printf '     stated whether a settings-lint line can reach its classifier.\n'
    printf '     Add one of: `# CC-STDERR: filtered`, `# CC-STDERR-EXEMPT: <measurement>`,\n'
    printf '     `# CC-STDERR-UNMEASURED: <what is open>`. See tests/probes/README.md.\n'
  done
fi
echo "     filtered=${#FILTERED[@]}  exempt=${#EXEMPT[@]}  unmeasured=${#UNMEASURED[@]}  untagged=${#UNTAGGED[@]}"

# ---------------------------------------------------------------------------
echo "### 3. every 'filtered' candidate still sources AND calls the filter"
# ---------------------------------------------------------------------------
# Deletion-resistant, NOT inversion-resistant — see the header. The inversion is
# covered by probe-cc-binary-resolution.sh § 5.
for f in "${FILTERED[@]}"; do
  b=$(basename "$f")
  if grep -qF 'lib/cc-cell-stderr.sh' "$f"; then
    ok "$b sources lib/cc-cell-stderr.sh"
  else
    bad "$b is tagged 'filtered' but does not source lib/cc-cell-stderr.sh"
  fi
  nstrip=$(grep -cE '[^_a-z]strip_cc_config_advisories|^strip_cc_config_advisories' "$f")
  if [ "$nstrip" -ge 1 ]; then
    ok "$b calls strip_cc_config_advisories ($nstrip site(s))"
  else
    bad "$b is tagged 'filtered' but never calls strip_cc_config_advisories"
  fi
done

# An exemption is a CLAIM, not an opt-out: it must carry prose, not a bare tag.
for f in "${EXEMPT[@]}" "${UNMEASURED[@]}"; do
  b=$(basename "$f")
  start=$(grep -nE "$TAG_RE" "$f" | head -1 | cut -d: -f1)
  body=$(awk -v s="$start" 'NR>=s && /^#/ {print; next} NR>=s {exit}' "$f")
  words=$(printf '%s' "$body" | wc -w)
  if [ "$words" -ge 25 ]; then
    ok "$b exemption states its reasoning ($words words)"
  else
    bad "$b exemption is $words words — an exemption states the measurement that shows a config echo cannot match its classifier, not the author's confidence"
  fi
done

# ---------------------------------------------------------------------------
echo "### 4. declared-open exposures are triaged, not accumulated"
# ---------------------------------------------------------------------------
for f in "${UNMEASURED[@]}"; do
  printf '     OPEN: %s\n' "$(basename "$f")"
done
chk "UNMEASURED count is the pinned $EXPECT_UNMEASURED (a new one must be triaged, not merged)" \
    "${#UNMEASURED[@]}" "$EXPECT_UNMEASURED"

# ---------------------------------------------------------------------------
echo "### 5. behavioural: today's LIVE settings vs the classifiers in this tree"
# ---------------------------------------------------------------------------
# Generated from both sides, never from a hardcoded example: every permission
# rule in the resolved live settings, crossed with every classifier regex
# actually present in a filtered probe. A rule whose TEXT matches a classifier
# is a live hazard; the filter must drop the advisory line that quotes it.
SETTINGS=$(readlink -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" 2>/dev/null || true)
if [ -z "$SETTINGS" ] || [ ! -r "$SETTINGS" ]; then
  echo "     SKIP: settings.json not resolvable/readable — nothing measured (this is not a pass)"
else
  echo "     settings: $SETTINGS"
  RULES=()
  if command -v jq >/dev/null 2>&1; then
    while IFS= read -r r; do
      [ -n "$r" ] && RULES+=("$r")
    done < <(jq -r '[.permissions // {} | to_entries[] | select(.value | type == "array") | .value[]] | .[]' "$SETTINGS" 2>/dev/null)
  fi
  if [ "${#RULES[@]}" -eq 0 ]; then
    bad "read 0 permission rules from $SETTINGS — the scan did not run, which is NOT evidence of no hazard"
  else
    ok "read ${#RULES[@]} permission rule(s) from the live settings"

    # Classifier regexes actually present in the filtered probes: named
    # `*_RE='...'` assignments plus inline `grep -qiE '...'` literals.
    CLASSIFIERS=()
    for f in "${FILTERED[@]}"; do
      while IFS= read -r re; do
        [ -n "$re" ] && CLASSIFIERS+=("$re")
      done < <(
        sed -n "s/^[A-Z_]*_RE='\(.*\)'$/\1/p" "$f"
        sed -n "s/.*grep -q[iEF]* *'\([^']*\)'.*/\1/p" "$f"
      )
    done
    echo "     harvested ${#CLASSIFIERS[@]} classifier regex(es) from ${#FILTERED[@]} filtered probe(s)"
    [ "${#CLASSIFIERS[@]}" -ge 1 ] \
      && ok "classifier harvest is non-empty" \
      || bad "harvested 0 classifiers from the filtered probes — this cell measured nothing"

    HAZARDS=0
    DEFENDED=0
    for rule in "${RULES[@]}"; do
      for re in "${CLASSIFIERS[@]}"; do
        grep -qiE -- "$re" <<< "$rule" 2>/dev/null || continue
        HAZARDS=$((HAZARDS + 1))
        printf '     HAZARD: rule %-24s matches classifier /%.46s/\n' "\`$rule\`" "$re"
        # The line Claude Code emits about that rule (shape pinned verbatim in
        # probe-cc-binary-resolution.sh § 5).
        adv="Permission allow rule ($SETTINGS): $rule has a wildcard before the rest of the command, so it also matches any options inserted at that position and approves them without a prompt."
        cleaned=$(strip_cc_config_advisories "$adv")
        if [ -n "$cleaned" ]; then
          bad "the advisory quoting \`$rule\` SURVIVED the filter — a classifier in this tree will read it as a failure"
        elif grep -qiE -- "$re" <<< "$adv" 2>/dev/null; then
          DEFENDED=$((DEFENDED + 1))   # positive control held: raw matched, cleaned is empty
        else
          bad "positive control did not hold for \`$rule\`: the RAW advisory did not match the classifier it was selected by"
        fi
      done
    done
    echo "     live hazards: $HAZARDS  (all defended: $DEFENDED)"
    chk "every live hazard is defended by the filter" "$DEFENDED" "$HAZARDS"
    if [ "$HAZARDS" -eq 0 ]; then
      printf '     NOTE today'"'"'s settings contain no rule matching any classifier in this tree.\n'
      printf '          That is an ACCIDENT of regex specificity, not a policy, and it is one\n'
      printf '          settings edit from being false. The filter is what holds regardless.\n'
    fi
  fi
fi

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
