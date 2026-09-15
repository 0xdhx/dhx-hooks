#!/usr/bin/env bash
# probe-watch-digest-scan.sh — the digest SCAN contract of dhx-watch-digest.sh
# Test groups: S (scan logic), R (render), T (system signal)
#
# A separate file from the original scaffold probe-watch-digest.sh, which is left byte-identical
# on purpose: the brief this backs (2026-09-14 watch-digest per-line jq fan-out) names that probe
# "stays green unmodified" as its AC-2 instrument, and the close-gate reviewer (round 1) held it
# to the letter. The scaffold carries zero assertions; this file carries the scan contract.
#
# Backs docs/decisions.md 2026-09-14 "watch-digest single jq pass" row. The digest scan was
# rewritten from a per-line double `jq` spawn (>=3,600 processes to surface zero rows) to ONE
# `jq -Rs` pass. These assertions pin the scan's OBSERVABLE contract so the pass can never
# drift from what the old loop rendered: exact stdout bytes for every row class, the
# `digest_corrupt` count, the pointer write, and the boundary cases the exact digit-string
# pointer compare must get right (equality, adjacency, leading zeros, int64 max, 20-digit
# ids, a trailing-newline id, unterminated final lines, pointer 0).
#
# The emitted-line SHAPE is a cross-repo contract (see the surfacer header's INVARIANT block);
# the cross-repo consumer probe asserts lead tokens by `grep -F`. This probe asserts the full
# rendered bytes locally so a scan regression has a LOCAL signal.
#
# SAFE_FOR_LIVE: yes   (per-test mktemp_state registry with trap cleanup; DHX_WATCH_DIR +
#                       DHX_WATCH_HEALTH_CACHE pointed at the fixture; no live writes)
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SURFACER="$REPO/dhx/dhx-watch-digest.sh"
PASS=0
FAIL=0

ok() { echo "OK   $1: $2"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1: $2"; FAIL=$((FAIL + 1)); }

# Temp-dir registry for trap-based cleanup
TEMP_DIRS=()
cleanup() {
  for d in "${TEMP_DIRS[@]}"; do
    [ -d "$d" ] && rm -rf "$d"
  done
}
trap cleanup EXIT

mktemp_state() {
  local d
  d=$(mktemp -d -t watch-digest-probe-XXXXXX)
  TEMP_DIRS+=("$d")
  echo "$d"
}

# run_surfacer <fixture-dir> -> stdout; rc in $RC. Same stdin the dispatcher hands it,
# health cache at a nonexistent path so those sections are inert, watchlist absent unless
# the fixture wrote one. LC_ALL pinned: the surfacer truncates summaries by `${#SUMMARY}`,
# which counts characters under a UTF-8 locale and bytes under C — the S1 quirky row carries
# multibyte characters, so an unpinned locale would move the `...` cut.
RC=0
run_surfacer() {
  local out
  out=$(printf '{"session_id":"x","source":"resume"}' \
    | LC_ALL=C.UTF-8 DHX_WATCH_DIR="$1" DHX_WATCH_HEALTH_CACHE="$1/no-health-cache.json" bash "$SURFACER")
  RC=$?
  printf '%s' "$out"
}

# row <id-json> <tag> <url> <type> <summary> <triage-json> [<emitted_at>]
row() {
  printf '{"entry_id":%s,"emitted_at":"%s","watchlist_id":"a","url":"%s","tag":"%s","event_type":"%s","event_summary":"%s","event_payload":{},"triage_hint":%s}\n' \
    "$1" "${7-}" "$3" "$2" "$4" "$5" "$6"
}

assert_eq() {  # <group.id> <desc> <expected> <actual>
  if [ "$3" = "$4" ]; then ok "$1" "$2"; else
    fail "$1" "$2"
    printf '     expected: %s\n     actual:   %s\n' "$(printf '%s' "$3" | head -c 400 | tr '\n' '|')" "$(printf '%s' "$4" | head -c 400 | tr '\n' '|')"
  fi
}

# lines <l1> <l2> ... -> the lines joined by newline, no trailing newline. Every rendered
# summary line ends in ONE trailing space ("${SUMMARY}" ${REL} with REL empty), so each
# expected line is its own quoted argument — a bare multi-line string literal loses that
# trailing space to editors that trim whitespace.
lines() { local IFS=$'\n'; printf '%s' "$*"; }

# ── S1: the negative-control fixture — every row class, exact bytes, corrupt count, pointer ──
# 12 physical lines, 9 classes, pointer 100. Order matters: the render is file order.
S1=$(mktemp_state)
printf '100' > "$S1/pointer.txt"
{
  row '"98"'  t98  https://github.com/o/r/issues/98  new_comment  "seen 98"            null
  row '"99"'  t99  https://github.com/o/r/issues/99  new_comment  "seen 99"            '"maintainer_activity"'
  row '"100"' t100 https://github.com/o/r/issues/100 state_change "seen 100 == pointer" '"state_transition"'
  printf '\n'
  row null    t1   https://github.com/o/r/issues/1   ack          "ack: t1 -> awaiting_them" null
  printf '{not json\n'
  row '"abc"' t2   https://github.com/o/r/issues/2   new_comment  "garbage id"         null
  row 3.5     t3   https://github.com/o/r/issues/3   new_comment  "float id"           null
  row '"101"' t101 https://github.com/o/r/issues/101 new_comment  "first new"          '"maintainer_activity"'
  # quirky: odd whitespace, key order reversed, unicode + escapes, >120-char summary
  printf '{  "triage_hint" : "system_issue",\t"event_summary":"quirky \\u00e9 \\"q\\" \\/ tab\\there — %s",  "event_type":"label_change" , "tag":"t102","url":"https://github.com/o/r/pull/102",   "watchlist_id":"a","emitted_at":"","entry_id":"102","event_payload":{"k":[1,{"z":null}],"big":1789437635329000006,"f":1.0,"e":1e3}}\n' "$(printf 'x%.0s' $(seq 1 120))"
  row '"104"' t104 https://github.com/o/r/issues/104 state_change "out of order 104 before 103" '"state_transition"'
  row '"103"' t103 https://github.com/o/r/issues/103 new_comment  "no emitted_at"      null
} > "$S1/digest.jsonl"
# emitted_at is empty on every row so the relative-time suffix is deterministic (absent).
EXPECT_S1=$(lines \
  '[!] digest_corrupt · skipped 3 unparseable line(s)' \
  '[M] t101 · #101 · new_comment' \
  '    "first new" ' \
  '[!] t102 · #102 · label_change' \
  '    "quirky é "q" / tab	here — xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx..." ' \
  '[S] t104 · #104 · state_change' \
  '    "out of order 104 before 103" ' \
  '    t103 · #103 · new_comment' \
  '    "no emitted_at" ')
OUT=$(run_surfacer "$S1")
assert_eq S1.a "12-line fixture renders exact bytes (corrupt=3, 4 surfaced in file order, quirky row compacted)" "$EXPECT_S1" "$OUT"
assert_eq S1.b "exit 0" 0 "$RC"
assert_eq S1.c "pointer advances to max surfaced id (104), not the last row (103)" 104 "$(cat "$S1/pointer.txt")"
# Second run: nothing new, the null-id ack does not re-warn, the pointer is not rewritten.
OUT=$(run_surfacer "$S1")
assert_eq S1.d "second run is silent (null-id ack never re-warns digest_corrupt)" "[!] digest_corrupt · skipped 3 unparseable line(s)" "$OUT"
assert_eq S1.e "pointer unchanged on second run" 104 "$(cat "$S1/pointer.txt")"

# ── S2: pointer-compare boundaries (pointer 100) ──
S2=$(mktemp_state)
printf '100' > "$S2/pointer.txt"
{
  row '"100"'  eq   u/100 x "equal to pointer"       null   # dropped
  row '"0100"' eqz  u/100 x "equal, leading zero"    null   # dropped (0100 == 100)
  row '"101"'  adj  u/101 x "pointer plus one"       null   # surfaced
  row '"0099"' lz   u/99  x "leading zero below"     null   # dropped
  row '"0101"' lzu  u/101 x "leading zero above"     null   # surfaced (as 0101; bash -gt sees 101)
  row '"9223372036854775807"' max u/max x "int64 max" null  # surfaced; pointer lands here
  row '"20"'   low  u/20  x "well below"             null   # dropped
} > "$S2/digest.jsonl"
EXPECT_S2=$(lines \
  '    adj · #101 · x' \
  '    "pointer plus one" ' \
  '    lzu · #101 · x' \
  '    "leading zero above" ' \
  '    max · #max · x' \
  '    "int64 max" ')
OUT=$(run_surfacer "$S2")
assert_eq S2.a "equality / adjacency / leading zeros both sides / int64 max" "$EXPECT_S2" "$OUT"
assert_eq S2.b "pointer lands on int64 max" 9223372036854775807 "$(cat "$S2/pointer.txt")"

# ── S3: pointer 0 surfaces everything numeric; id "0" and "000" do not (0 <= 0) ──
S3=$(mktemp_state)
printf '0' > "$S3/pointer.txt"
{
  row '"0"'   z   u/0 x "zero"        null
  row '"000"' zz  u/0 x "zero padded" null
  row '"1"'   one u/1 x "one"         null
  row 7       num u/7 x "bare number" null   # a JSON number id is text "7" to the scan
} > "$S3/digest.jsonl"
EXPECT_S3=$(lines \
  '    one · #1 · x' \
  '    "one" ' \
  '    num · #7 · x' \
  '    "bare number" ')
OUT=$(run_surfacer "$S3")
assert_eq S3.a "pointer 0: ids 0/000 dropped, 1 and bare-number 7 surfaced" "$EXPECT_S3" "$OUT"
assert_eq S3.b "pointer -> 7" 7 "$(cat "$S3/pointer.txt")"

# ── S4: id classes that must be CORRUPT (present, not a digit string) vs SILENT (null-ish) ──
S4=$(mktemp_state)
printf '100' > "$S4/pointer.txt"
{
  row '"123\n"' nl   u/1 x "trailing newline in id" null   # corrupt (\z anchor); the OLD loop
                                                          # surfaced this via $() newline-strip —
                                                          # accepted divergence, no producer emits it
  row '"12\n3"' inl  u/1 x "internal newline"       null   # corrupt
  row true      tr   u/1 x "boolean true"           null   # corrupt
  row '"1e3"'   exp  u/1 x "exponent string"        null   # corrupt
  row '"-5"'    neg  u/1 x "negative"               null   # corrupt
  row '{"a":1}' obj  u/1 x "object id"              null   # corrupt
  row false     fa   u/1 x "boolean false"          null   # SILENT (// empty)
  row '""'      es   u/1 x "empty string"           null   # SILENT
  printf '{"tag":"absent","url":"u/1","event_type":"x","event_summary":"no entry_id key"}\n'   # SILENT
  printf '42\n'          # valid JSON, not an object: SILENT (old: .entry_id errored -> empty)
  printf '[1,2]\n'       # same
  printf 'null\n'        # same
  row '"200"'   ok   u/200 x "one real row so the block renders" null
} > "$S4/digest.jsonl"
EXPECT_S4=$(lines \
  '[!] digest_corrupt · skipped 6 unparseable line(s)' \
  '    ok · #200 · x' \
  '    "one real row so the block renders" ')
OUT=$(run_surfacer "$S4")
assert_eq S4.a "6 garbage-id shapes counted corrupt; false/\"\"/absent/non-object silent" "$EXPECT_S4" "$OUT"
assert_eq S4.b "pointer -> 200" 200 "$(cat "$S4/pointer.txt")"

# ── S5: record framing — an unterminated final line is invisible, valid or not ──
S5=$(mktemp_state)
printf '100' > "$S5/pointer.txt"
{ row '"101"' a u/101 x "terminated" null; printf '{"entry_id":"102","tag":"b","url":"u/102","event_type":"x","event_summary":"NO trailing newline"}'; } > "$S5/digest.jsonl"
OUT=$(run_surfacer "$S5")
assert_eq S5.a "unterminated VALID last line: not surfaced, not corrupt" "$(lines '    a · #101 · x' '    "terminated" ')" "$OUT"
assert_eq S5.b "pointer stops at 101 (never advanced by a half-framed record)" 101 "$(cat "$S5/pointer.txt")"
S5b=$(mktemp_state)
printf '100' > "$S5b/pointer.txt"
{ row '"101"' a u/101 x "terminated" null; printf '{"entry_id":"102","tag":"b"'; } > "$S5b/digest.jsonl"
OUT=$(run_surfacer "$S5b")
assert_eq S5.c "unterminated INVALID last line (mid-append): not counted corrupt" "$(lines '    a · #101 · x' '    "terminated" ')" "$OUT"
# Then the append completes: the row is read whole next session.
printf ',"url":"u/102","event_type":"x","event_summary":"now complete"}\n' >> "$S5b/digest.jsonl"
OUT=$(run_surfacer "$S5b")
assert_eq S5.d "completed row surfaces on the next run" "$(lines '    b · #102 · x' '    "now complete" ')" "$OUT"
assert_eq S5.e "pointer -> 102" 102 "$(cat "$S5b/pointer.txt")"

# ── S6: no digest / empty digest / missing pointer ──
S6=$(mktemp_state)
OUT=$(run_surfacer "$S6")
assert_eq S6.a "no digest, no pointer, no watchlist: silent" "" "$OUT"
assert_eq S6.b "exit 0" 0 "$RC"
[ -e "$S6/pointer.txt" ] && fail S6.c "pointer must not be created when nothing surfaced" || ok S6.c "pointer not created when nothing surfaced"
: > "$S6/digest.jsonl"
OUT=$(run_surfacer "$S6")
assert_eq S6.d "empty digest: silent" "" "$OUT"
row '"5"' m u/5 x "missing pointer = 0" null > "$S6/digest.jsonl"
OUT=$(run_surfacer "$S6")
assert_eq S6.e "missing pointer treated as 0: row surfaces" "$(lines '    m · #5 · x' '    "missing pointer = 0" ')" "$OUT"
assert_eq S6.f "pointer created at 5" 5 "$(cat "$S6/pointer.txt")"

# ── T1: system signal — a broken jq must stay LOUD (every line counted corrupt), never silent ──
T1=$(mktemp_state)
printf '100' > "$T1/pointer.txt"
{ row '"101"' a u/101 x "would surface" null; row '"102"' b u/102 x "would surface" null; } > "$T1/digest.jsonl"
mkdir -p "$T1/bin"; printf '#!/bin/sh\nexit 3\n' > "$T1/bin/jq"; chmod +x "$T1/bin/jq"
OUT=$(printf '{}' | PATH="$T1/bin:$PATH" DHX_WATCH_DIR="$T1" DHX_WATCH_HEALTH_CACHE="$T1/none" bash "$SURFACER"); RC=$?
assert_eq T1.a "jq exits 3: both lines counted corrupt, nothing surfaced" "[!] digest_corrupt · skipped 2 unparseable line(s)" "$OUT"
assert_eq T1.b "pointer untouched" 100 "$(cat "$T1/pointer.txt")"
# Close-review round-1 Q1 finding, discharged in-arc: the old `while read` never saw an
# unterminated last line, so under a broken jq it was not counted either. Count only
# LF-terminated lines.
printf '{"entry_id":"103","tag":"c","url":"u/103","event_type":"x","event_summary":"no LF"}' >> "$T1/digest.jsonl"
OUT=$(printf '{}' | PATH="$T1/bin:$PATH" DHX_WATCH_DIR="$T1" DHX_WATCH_HEALTH_CACHE="$T1/none" bash "$SURFACER"); RC=$?
assert_eq T1.c "jq exits 3 + unterminated last line: still 2, the tail is not a line" "[!] digest_corrupt · skipped 2 unparseable line(s)" "$OUT"
# Round-2 Q1: a tail ending in a NUL byte. `$(tail -c1)` drops a trailing NUL, which made the
# LF check read the file as terminated and count the tail. The byte is now read via od.
printf '\0' >> "$T1/digest.jsonl"
OUT=$(printf '{}' | PATH="$T1/bin:$PATH" DHX_WATCH_DIR="$T1" DHX_WATCH_HEALTH_CACHE="$T1/none" bash "$SURFACER" 2>/dev/null); RC=$?
assert_eq T1.d "jq exits 3 + NUL-ending tail: still 2 (last byte read via od, not \$())" "[!] digest_corrupt · skipped 2 unparseable line(s)" "$OUT"

# ── R1: the scan must not disturb the non-digest blocks (watchlist-derived), D-11 order ──
R1=$(mktemp_state)
printf '100' > "$R1/pointer.txt"
{ printf '{not json\n'; row '"101"' t101 https://github.com/o/r/issues/101 new_comment "delta" '"maintainer_activity"'; } > "$R1/digest.jsonl"
printf '{"schema_version":1,"items":[{"id":"o-r-1","url":"https://github.com/o/r/issues/1","tag":"claude-code","status":"active","action_state":"awaiting_us","snooze_until":null,"last_seen_labels":["bug"]},{"id":"o-r-7","url":"https://github.com/o/r/issues/7","tag":"gsd-core","status":"active","action_state":"awaiting_them","last_seen_state":"closed","snooze_until":null}]}' > "$R1/watchlist.json"
EXPECT_R1=$(lines \
  '⚠ Action required (1):' \
  '    claude-code · bug · https://github.com/o/r/issues/1' \
  '      › /dhx:watch ack o-r-1 · snooze o-r-1 8h' \
  '⚠ 1 item(s) closed upstream, still active locally — enable config.auto_close_on_upstream_close to auto-close, or close manually.' \
  '[!] digest_corrupt · skipped 1 unparseable line(s)' \
  '[M] t101 · #101 · new_comment' \
  '    "delta" ')
OUT=$(run_surfacer "$R1")
assert_eq R1.a "action-required -> drift -> corrupt -> delta, in D-11 order, exact bytes" "$EXPECT_R1" "$OUT"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
