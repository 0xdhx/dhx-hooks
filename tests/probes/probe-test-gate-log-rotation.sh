#!/usr/bin/env bash
# probe-test-gate-log-rotation.sh
#
# Invariant: dhx/dhx-test-gate.sh's opt-in project log is SELF-CAPPING. log()
# rewrites $LOG_FILE to its last LOG_KEEP_LINES lines before appending whenever
# the file exceeds LOG_MAX_BYTES, and leaves an under-threshold log untouched.
# Before 2026-09-20 nothing truncated it and acme-app's had reached 1.38 MB.
#
# Backs:
#   - docs/decisions.md — 2026-09-20 test-gate log rotation + ignore contract row
#   - .planning/todos/completed/2026-09-20-test-gate-log-unbounded-and-unignored.md
#
# Run: bash tests/probes/probe-test-gate-log-rotation.sh
#
# SAFE_FOR_LIVE: yes  (every path the hook touches is redirected into one
#                      `mktemp -d` tree: CLAUDE_PROJECT_DIR is the fixture
#                      project, TMPDIR is the fixture's own tmp so the counter
#                      file and the rotation staging file land there too, and
#                      the fixture carries no test runner — the hook exits at
#                      the no-source-flag branch without spawning anything.
#                      Never reads or writes a live repo, ~/.claude, or
#                      ~/.cache/dhx.)
# LIVE_RUNTIME: no    (verdict depends only on this repo's dhx/ source; no
#                      gsd-core install can flip it)
# HERMETIC_TIER: yes  (three hook firings against file fixtures; ~1s)
# RUNTIME: ~1s
# (No LIVE_SUBJECT: that key declares which staged files a LIVE_RUNTIME=yes
#  probe should gate. This probe is hermetic, so it carries none — matching the
#  other seven LIVE_RUNTIME: no probes.)
#
# NEGATIVE CONTROLS RUN 2026-09-20 via DHX_TEST_GATE_HOOK_UNDER_TEST (the test
# of the test — measured, not claimed). Every mutant was diffed against a
# pristine base and carried EXACTLY ONE hunk; the NULL mutant (an unmutated
# copy) ran first and came back 13/13, so a crashed harness could not be read
# as "every mutant survived":
#   0. NULL (unmutated copy): 13 passed, 0 failed.
#   1. `-gt` -> `-lt` in log()'s threshold test (INVERTED, not deleted — every
#      token, symbol and structure still in place): [2] [3] [4] [5] RED **and**
#      control cells [7] [8] RED. Caught from both directions.
#   2. rotation block deleted entirely: [2] [3] [4] [5] RED; [7] [8] green
#      (correctly — a deleted rotation cannot rewrite an under-threshold log).
#   3. `tail -n "$LOG_KEEP_LINES"` -> `tail -n 10`: [3] RED, [5] RED. [2] and
#      [4] stayed GREEN, which is why the retained COUNT and the retained
#      BOUNDARY line are asserted against literals rather than "it shrank".
#   4. hook replaced by /bin/true (dead harness): [0a] [0b] RED and [1] RED with
#      PROBE ERROR — no assertion reports success against a subject that never ran.
#
# What this run corrected, recorded because the next author will reach for the
# same fixture: the control cell was FIRST written with a 50-line under-threshold
# seed, and against mutant 1 it stayed GREEN. `tail -n 2000` of a 50-line file is
# a no-op, so the inverted hook rewrote it to byte-identical content and the cell
# passed while detecting nothing — a hollow guard of exactly the shape
# tests/probes/README.md § "A guard has two layers" describes. The seed is now
# over KEEP_LINES and under MAX_BYTES so the rewrite is VISIBLE, and the cell
# asserts that precondition rather than trusting it.

set -u

# Control-testing seam (same shape as DHX_DIRTY_TREE_HOOK_UNDER_TEST): points
# the probe at a mutant copy so the negative controls recorded above can be
# re-run. Defaults to the live hook; never set in normal operation.
HOOK="${DHX_TEST_GATE_HOOK_UNDER_TEST:-/home/dhx/repos/hooks/dhx/dhx-test-gate.sh}"

command -v jq >/dev/null 2>&1 || { echo "PROBE ERROR: jq not found — the hook fails open before log() reaches the rotation branch"; exit 1; }
[ -x "$HOOK" ] || { echo "PROBE ERROR: hook not executable at $HOOK"; exit 1; }

TMP=$(mktemp -d /tmp/probe-test-gate-log-rotation.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

chk() {  # chk LABEL GOT WANT
  if [ "$2" = "$3" ]; then
    echo "OK   $1"
    PASS=$((PASS + 1))
  else
    echo "FAIL $1 — got '$2', want '$3'"
    FAIL=$((FAIL + 1))
  fi
}

# The values the hook compiles in. Asserted against the source below so this
# probe reds if the constants move without the expectations moving with them.
KEEP_LINES=2000
MAX_BYTES=262144

src_keep=$(grep -m1 '^LOG_KEEP_LINES=' "$HOOK" | cut -d= -f2)
src_max=$(grep -m1 '^LOG_MAX_BYTES=' "$HOOK" | cut -d= -f2)
chk "[0a] hook's LOG_KEEP_LINES matches this probe's expectation" "$src_keep" "$KEEP_LINES"
chk "[0b] hook's LOG_MAX_BYTES matches this probe's expectation" "$src_max" "$MAX_BYTES"

# seed_log FILE N [PAD] — writes N numbered lines. PAD sets the line width so a
# fixture can be over-threshold in BYTES (long pad) or under-threshold in bytes
# while still over KEEP_LINES in LINES (short pad) — the second shape is what
# gives the control cell teeth against an inverted threshold test.
PAD_LONG="................................................................."
PAD_SHORT="......"
seed_log() {
  local file="$1" n="$2" pad="${3:-$PAD_LONG}" i
  : > "$file"
  for ((i = 1; i <= n; i++)); do
    printf '[2026-09-20T00:00:00Z] seed line %06d %s\n' "$i" "$pad" >> "$file"
  done
}

# fire_hook PROJ — runs the hook against PROJ with a minimal Stop payload,
# every temp path redirected into the fixture. Echoes the hook's exit status.
fire_hook() {
  local proj="$1" rc=0
  mkdir -p "$proj/tmp"
  ( cd "$proj" && CLAUDE_PROJECT_DIR="$proj" TMPDIR="$proj/tmp" \
      bash "$HOOK" <<< '{"session_id":"probe","stop_hook_active":false}' \
  ) >/dev/null 2>&1 || rc=$?
  echo "$rc"
}

# ---------------------------------------------------------------------------
# Cell 1 — over-threshold log IS rotated
# ---------------------------------------------------------------------------
echo "--- over-threshold ---"

PROJ_BIG="$TMP/big"
mkdir -p "$PROJ_BIG/.claude/hooks/logs"
LOG_BIG="$PROJ_BIG/.claude/hooks/logs/test-gate.log"
seed_log "$LOG_BIG" 4000 "$PAD_LONG"

seed_bytes=$(stat -c %s "$LOG_BIG")
seed_lines=$(wc -l < "$LOG_BIG")
if [ "$seed_bytes" -le "$MAX_BYTES" ]; then
  echo "PROBE ERROR: seed is $seed_bytes bytes, not over the $MAX_BYTES threshold — fixture does not exercise the branch"
  exit 1
fi

rc_big=$(fire_hook "$PROJ_BIG")

# [1] LIVENESS — prove the hook ran before judging what it produced. A dead
# harness (or an early abort) appends nothing, and every assertion below would
# then be measuring the seed. This is the only cell that can distinguish the
# two, so it reports PROBE ERROR rather than a satisfied assertion.
if ! grep -q 'session=probe' "$LOG_BIG"; then
  echo "FAIL [1] PROBE ERROR: hook wrote no 'session=probe' entry (exit $rc_big) — it did not run to log(); remaining assertions would measure the seed"
  FAIL=$((FAIL + 1))
  echo
  echo "$PASS passed, $FAIL failed"
  exit 1
fi
echo "OK   [1] hook ran — wrote its own entry (exit $rc_big)"
PASS=$((PASS + 1))

post_bytes=$(stat -c %s "$LOG_BIG")
post_lines=$(wc -l < "$LOG_BIG")

# [2] the file shrank
chk "[2] rotated log is smaller than the seed ($post_bytes < $seed_bytes)" \
    "$([ "$post_bytes" -lt "$seed_bytes" ] && echo yes || echo no)" "yes"

# [3] retained EXACTLY KEEP_LINES of history plus the hook's own two entries.
# Asserted against a literal, not against another read of the same file: a
# "smaller than seed" check alone passes for tail -n 10 just as well.
chk "[3] line count is KEEP_LINES + the 2 entries this firing wrote" \
    "$post_lines" "$((KEEP_LINES + 2))"

# [4] the result is under the cap
chk "[4] rotated log is at or under LOG_MAX_BYTES" \
    "$([ "$post_bytes" -le "$MAX_BYTES" ] && echo yes || echo no)" "yes"

# [5] the retained window is the TAIL of the seed, not the head. The boundary
# line is computable from the fixture, so it is asserted as a literal.
want_first=$(printf '[2026-09-20T00:00:00Z] seed line %06d %s' \
  "$((seed_lines - KEEP_LINES + 1))" "................................................................." )
chk "[5] first retained line is the seed's (N-KEEP_LINES+1)th, i.e. the tail was kept" \
    "$(head -n 1 "$LOG_BIG")" "$want_first"

# [6] the newest entry is the hook's last log call this firing, so the append
# happened AFTER the rewrite rather than being rotated away with it.
chk "[6] last line is this firing's final entry" \
    "$(tail -n 1 "$LOG_BIG" | grep -c 'No source files written this turn')" "1"

# ---------------------------------------------------------------------------
# Cell 2 — POSITIVE CONTROL: under-threshold log is NOT rewritten
# ---------------------------------------------------------------------------
echo "--- under-threshold (control) ---"

# The seed is deliberately OVER KEEP_LINES while UNDER MAX_BYTES (short lines).
# A 50-line control would be worthless here: `tail -n 2000` of a 50-line file is
# a no-op, so an INVERTED threshold test would rewrite it to byte-identical
# content and the cell would pass while reporting nothing. Measured 2026-09-20:
# with a 50-line seed the inversion mutant left [7] and [8] green; with this one
# it reds [7]. The control only controls when the rewrite would be VISIBLE.
PROJ_SMALL="$TMP/small"
mkdir -p "$PROJ_SMALL/.claude/hooks/logs"
LOG_SMALL="$PROJ_SMALL/.claude/hooks/logs/test-gate.log"
seed_log "$LOG_SMALL" $((KEEP_LINES + 500)) "$PAD_SHORT"

small_seed_lines=$(wc -l < "$LOG_SMALL")
small_seed_bytes=$(stat -c %s "$LOG_SMALL")
if [ "$small_seed_bytes" -gt "$MAX_BYTES" ]; then
  echo "PROBE ERROR: control seed is $small_seed_bytes bytes, over the threshold — it does not control anything"
  exit 1
fi
if [ "$small_seed_lines" -le "$KEEP_LINES" ]; then
  echo "PROBE ERROR: control seed is $small_seed_lines lines, not over KEEP_LINES — a rewrite would be invisible and the cell could not catch an inverted threshold"
  exit 1
fi

rc_small=$(fire_hook "$PROJ_SMALL")

if ! grep -q 'session=probe' "$LOG_SMALL"; then
  echo "FAIL [7] PROBE ERROR: hook wrote no entry to the control log (exit $rc_small) — cell did not run"
  FAIL=$((FAIL + 1))
else
  # [7] every seeded line survives — an under-threshold log keeps its whole
  # history, so the count is seed + the 2 entries this firing wrote.
  chk "[7] control: all seeded lines retained (no rewrite)" \
      "$(wc -l < "$LOG_SMALL")" "$((small_seed_lines + 2))"

  # [8] and the head is untouched: line 1 is still the seed's line 1.
  chk "[8] control: first line is still the seed's line 1" \
      "$(head -n 1 "$LOG_SMALL")" \
      "$(printf '[2026-09-20T00:00:00Z] seed line %06d %s' 1 "$PAD_SHORT")"
fi

# ---------------------------------------------------------------------------
# Cell 3 — the opt-out: no logs dir means no log file, and no rotation code path
# ---------------------------------------------------------------------------
echo "--- no opt-in ---"

PROJ_NONE="$TMP/none"
mkdir -p "$PROJ_NONE"
rc_none=$(fire_hook "$PROJ_NONE")

chk "[9] no .claude/hooks/logs/ — hook still exits 0 (fail-open contract)" "$rc_none" "0"
chk "[10] no .claude/hooks/logs/ — hook created no log file" \
    "$([ -e "$PROJ_NONE/.claude/hooks/logs/test-gate.log" ] && echo created || echo absent)" "absent"

# [11] the staging file is transient — nothing is left behind in TMPDIR.
chk "[11] rotation left no staging file behind" \
    "$(find "$PROJ_BIG/tmp" -name 'dhx-test-gate-rotate.*' 2>/dev/null | wc -l)" "0"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
