#!/usr/bin/env bash
# probe-read-guard-model-set-pin.sh
#
# Pins the model set that gates CC's native read-before-edit block, so a change
# to that set surfaces MECHANICALLY instead of waiting to be rediscovered.
#
# WHY A PIN AND NOT A BEHAVIOUR RE-RUN. The thing that can change is a literal
# in the CC bundle. Measuring it costs a fixed-string scan of the binary
# (~0.1s, read-only). Re-measuring the BEHAVIOUR costs three `claude -p` turns
# (~90-180s + API spend) in the sibling watchdog
# `probe-read-guard-native-enforcement-tripwire.sh`. So this probe is the cheap
# standing trigger and the tripwire is what you run once this one reds — at
# which point there is finally something new to measure. A "remember to
# re-check on the next CC bump" note is not a mechanism; this is.
#
# THE FACT BEING PINNED (HP-058, root-caused 2026-08-29 at CC 2.1.251). CC's
# hard `File has not been read yet.` block is the else-branch of a conjunction.
# One conjunct tests the session model against a hardcoded set:
#
#   var R = new Set(["claude-opus-4-6","claude-haiku-4-5","claude-opus-4-5",
#                    "claude-opus-4-1","claude-opus-4-0","claude-sonnet-4-5",
#                    "claude-sonnet-4-0","claude-3-7-sonnet","claude-3-5-sonnet",
#                    "claude-3-5-haiku"]);
#   function z$e(e){ return R.has(fn(e)) }
#
# A model INSIDE R keeps the guard. A model OUTSIDE it has the guard SKIPPED.
# The 5-family is absent, so on this machine's configured model the block does
# not fire at all — see docs/decisions.md 2026-08-29 row.
#
# `R` is hardcoded, so EVERY NEW MODEL SHIPS OUTSIDE THE GUARD BY DEFAULT and
# each CC release can move the boundary in either direction. That is what makes
# a cached verdict dangerous and this probe worth its runtime.
#
# KEY ON THE STRING LITERALS, NEVER THE MINIFIED SYMBOL (load-bearing). The
# bundle is minified and identifiers are regenerated every build — `z$e`, `R`
# and `fn` are NOT stable across releases and a probe anchored on them would
# red on cosmetic rebuilds while missing real set changes. Model ids are stable
# strings. This probe extracts the comma-joined run of `"claude-*"` literals
# containing a known ordered anchor PAIR, and compares the SORTED set, so a pure
# reordering inside the set does not red.
#
# Assertions:
#   [1] the CC bundle for the running version is locatable and readable
#   [2] EXACTLY ONE DISTINCT candidate id-run contains the anchor pair (an
#       ambiguous anchor must red, never silently pick the first match).
#       DISTINCT, not raw: from 2.1.270 the bundle payload is embedded TWICE
#       in the ~409MB binary (byte-identical copies, every literal at a fixed
#       +178,229,248-byte shift; the 40KB windows around both `gf` sets hash
#       equal). Two byte-identical runs are one set seen twice, not an
#       ambiguity — so identical runs collapse before counting, while two
#       DIFFERENT runs carrying the pair still red. Raw count is printed.
#   [3] the extracted set equals PINNED_SET  — the boundary has not moved
#   [4] no 5-family id has entered the set   — the sharp escalation: the guard
#       would now apply to the models this machine actually runs
#   [5] RED-TEST: a deliberately perturbed set does NOT compare equal to the pin,
#       proving the comparator is live rather than vacuously passing
#
# On a red: re-run the tripwire to re-measure the real behaviour, update
# HP-058 + the memory `reference-cc-native-read-block-vs-dhx-advisory`, then
# re-pin PINNED_SET below and stamp PINNED_AGAINST.
#
# Run: bash tests/probes/probe-read-guard-model-set-pin.sh
#
# SAFE_FOR_LIVE: yes   (read-only: greps the installed CC binary; touches no
#                       live config, no repo state, spawns no subprocess)
# RUNTIME: ~4-8s    (one regex scan of the bundle — ~214MB through 2.1.269,
#                    ~409MB from 2.1.270 with its doubled payload; a fixed-string
#                    scan of the same file is ~0.1s, the -P run is the cost of
#                    tolerating reordering. Still far cheaper than the tripwire's
#                    3 API turns.)
set -uo pipefail

# Sorted, space-separated. Re-pin ONLY after re-measuring with the tripwire.
PINNED_SET="claude-3-5-haiku claude-3-5-sonnet claude-3-7-sonnet claude-haiku-4-5 claude-opus-4-0 claude-opus-4-1 claude-opus-4-5 claude-opus-4-6 claude-sonnet-4-0 claude-sonnet-4-5"
PINNED_AGAINST="2.1.251"
# Last re-verified unchanged (set identical, only the bundle layout moved): 2.1.270, 2026-09-13.
# The ordered LEADING PAIR of the set. A single id is NOT discriminating: five
# separate id-runs in the 2.1.251 bundle contain 'claude-3-5-haiku' (model
# registries and alias tables list it too). This pair occurs exactly once. A
# reordering inside the set breaks the anchor and reds via [2] rather than
# silently mismatching, which is the safe direction to fail.
ANCHOR_PAIR='"claude-opus-4-6","claude-haiku-4-5"'

PASSED=0
FAILED=0
_assert() { # $1 label, $2 expected, $3 actual
  if [[ "$2" == "$3" ]]; then
    echo "OK   $1"; PASSED=$((PASSED + 1))
  else
    echo "FAIL $1"; echo "       expected: $2"; echo "       actual:   $3"
    FAILED=$((FAILED + 1))
  fi
}

CC_VERSION=$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")

# Locate the bundle. NOT via `command -v claude` — on this machine that resolves
# to a cap wrapper shell script, not the binary carrying the literals.
BIN=""
for cand in "${CLAUDE_CODE_EXECPATH:-}" "$HOME/.local/share/claude/versions/$CC_VERSION"; do
  [[ -n "$cand" && -f "$cand" && -r "$cand" ]] && { BIN="$cand"; break; }
done

if [[ -z "$BIN" ]]; then
  # A machine without this install layout must SKIP, not red — an unlocatable
  # bundle is "not measured", which is never evidence the set is unchanged.
  echo "SKIP read-guard-model-set-pin: CC bundle not locatable (CLAUDE_CODE_EXECPATH unset and ~/.local/share/claude/versions/${CC_VERSION:-?} absent) — not a failure, nothing was measured"
  echo "---"
  echo "0 passed, 0 failed (skipped)"
  exit 0
fi
_assert "[1] CC bundle located and readable" "yes" "yes"

# Extract every comma-joined run of quoted claude-* ids (2+ ids), then keep the
# runs containing the anchor. GNU grep -P explicitly: the bash `grep` here is a
# wrapper over ugrep with a different engine.
RUNS=$(/bin/grep -aoP '"claude-[a-z0-9.\-]+"(?:,"claude-[a-z0-9.\-]+")+' "$BIN" 2>/dev/null || true)
MATCHING_RAW=$(printf '%s\n' "$RUNS" | /bin/grep -F "$ANCHOR_PAIR" || true)
RAW_COUNT=$(printf '%s' "$MATCHING_RAW" | /bin/grep -c . || true)
# Collapse byte-identical runs (doubled bundle payload, see header [2]) — only
# DISTINCT runs can be ambiguous.
MATCHING=$(printf '%s\n' "$MATCHING_RAW" | /bin/grep . | sort -u || true)
MATCH_COUNT=$(printf '%s' "$MATCHING" | /bin/grep -c . || true)

_assert "[2] exactly one distinct id-run carries the anchor pair (raw occurrences: $RAW_COUNT)" "1" "$MATCH_COUNT"
if [[ "$MATCH_COUNT" != "1" ]]; then
  echo "       anchor is ambiguous or absent — refusing to guess which run is the guard's set."
  echo "       Anchor pair: $ANCHOR_PAIR"
  echo "       Dump the candidate runs with the grep -aoP idiom used for RUNS in this file (add -b for byte offsets),"
  echo "       read the code around each for the 'new Set([...])' + '.has(' guard shape, then pick the run that is the guard set and re-anchor."
  echo "---"
  echo "$PASSED passed, $FAILED failed"
  exit 1
fi

OBSERVED_SET=$(printf '%s' "$MATCHING" | tr ',' '\n' | tr -d '"' | sort | tr '\n' ' ' | sed 's/ *$//')

_assert "[3] guard model set matches the pin (pinned against $PINNED_AGAINST, running ${CC_VERSION:-unknown})" \
  "$PINNED_SET" "$OBSERVED_SET"

# [4] The sharp one. A 5-family id entering the set means the guard now applies
# to the models this machine runs, which reverses the 2026-08-29 finding.
FIVE_FAMILY=$(printf '%s\n' $OBSERVED_SET | /bin/grep -E '^claude-(opus|sonnet|haiku|fable)-5' | tr '\n' ' ' | sed 's/ *$//' || true)
_assert "[4] no 5-family id inside the guard set (guard still skipped for current models)" "" "$FIVE_FAMILY"

# [5] Red-test. Perturb the observed set through the SAME normalisation and assert
# it stops matching. Without this, an extraction that silently degraded to
# emitting the pinned string would pass [3] forever.
PERTURBED=$(printf '%s\n' $OBSERVED_SET "claude-opus-5" | sort | tr '\n' ' ' | sed 's/ *$//')
if [[ "$PERTURBED" == "$PINNED_SET" ]]; then
  _assert "[5] red-test: perturbed set is rejected by the comparator" "differs" "identical"
else
  _assert "[5] red-test: perturbed set is rejected by the comparator" "differs" "differs"
fi

if [[ "$FAILED" -ne 0 ]]; then
  echo ""
  echo "The read-before-edit guard boundary MOVED. This probe only detects it; it does not"
  echo "know the new behaviour. Next steps, in order:"
  echo "  1. set -a; . ~/.env-keys; set +a; bash tests/probes/probe-read-guard-native-enforcement-tripwire.sh"
  echo "  2. update HP-058 (docs/hook-patterns.md) + memory reference-cc-native-read-block-vs-dhx-advisory"
  echo "  3. re-pin PINNED_SET / PINNED_AGAINST in this file"
  if [[ -n "$FIVE_FAMILY" ]]; then
    echo ""
    echo "  [4] fired: a 5-family id ($FIVE_FAMILY) is now INSIDE the set. CC has re-armed the"
    echo "  native block for this machine's models — the docs/decisions.md 2026-08-29 row and"
    echo "  the Option C 'premise not in force' conclusion are both stale."
  fi
fi

echo "---"
echo "$PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]] || exit 1
exit 0
