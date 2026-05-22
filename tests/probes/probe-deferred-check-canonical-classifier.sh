#!/usr/bin/env bash
# probe-deferred-check-canonical-classifier.sh
#
# Regression probe for dhx/dhx-deferred-check.sh canonical-classifier sourcing.
#
# Invariant: the hook MUST source the canonical classifier from
# ~/.claude/dhx-tools/dhx-classify-deferred.sh (skills repo) and MUST NOT
# re-implement the marker filter inline. Inline duplication is the precise
# silent-divergence failure mode the skills-repo audit (260427-2d4) surfaced —
# 4 markers on the hook side vs 5 on the skill side, prefix-only on the hook
# vs prefix-or-end-of-bullet on the skill, with no static check to catch the
# drift. This probe is the static check.
#
# Sister probe: ~/repos/skills/tests/probe-classifier-cross-repo.sh runs the
# same kind of structural assertion from the skills-repo side. Either probe
# alone would catch reintroduction of inline filters; the pair makes the
# invariant visible from both repos' test suites.
#
# Backs: docs/decisions.md 2026-04-27 cross-repo classifier sync row.
# Parent report: reports/done/2026-04-27-cross-repo-classifier-sync-handoff.md
#
# Run: bash tests/probes/probe-deferred-check-canonical-classifier.sh

# SAFE_FOR_LIVE: yes   (static grep + sourcing test against in-repo classifier; mktemp fixture for source-test)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$REPO_ROOT/dhx/dhx-deferred-check.sh"
CLASSIFIER="${DHX_TOOLS:-$HOME/.claude/dhx-tools}/dhx-classify-deferred.sh"

for f in "$HOOK" "$CLASSIFIER"; do
  if [[ ! -r "$f" ]]; then
    echo "FAIL required file not readable: $f"
    exit 1
  fi
done

PASS=0
FAIL=0

check() {
  local label="$1"
  local ok="$2"
  if [[ "$ok" == "1" ]]; then
    echo "OK   $label"
    PASS=$((PASS+1))
  else
    echo "FAIL $label"
    FAIL=$((FAIL+1))
  fi
}

# --- Section 1: hook sources the canonical classifier ---

# 1. The hook contains a `.` or `source` directive pointing at dhx-classify-deferred.sh
if grep -qE '(^|[[:space:]])(\.|source)[[:space:]]+("?\$\{?DHX_TOOLS\}?|"?\$\{?HOME\}?/\.claude/dhx-tools|~/\.claude/dhx-tools|"\$DHX_CLASSIFIER")' "$HOOK" \
   && grep -q 'dhx-classify-deferred\.sh' "$HOOK"; then
  check "hook sources canonical classifier (~/.claude/dhx-tools/dhx-classify-deferred.sh)" 1
else
  check "hook does NOT source canonical classifier — drift mode reintroduced" 0
fi

# 2. The hook calls classify_deferred_lines (marker filter)
if grep -q 'classify_deferred_lines' "$HOOK"; then
  check "hook calls classify_deferred_lines" 1
else
  check "hook missing classify_deferred_lines call" 0
fi

# 2b. The hook calls auto_silence_deferred_lines (durable-home filter).
#     Added 2026-05-02 with the cross-repo extraction — locks the second
#     half of the pipeline. Inline reintroduction of REQ-ID / dated-filename
#     cross-references in the hook is the precise drift this asserts against.
if grep -q 'auto_silence_deferred_lines' "$HOOK"; then
  check "hook calls auto_silence_deferred_lines" 1
else
  check "hook missing auto_silence_deferred_lines call — inline auto-silence drift" 0
fi

# --- Section 2: hook does NOT inline the marker filter ---

# 3. No inline `grep -v '\[captured` chains. The canonical classifier handles
#    all 5 markers — any inline grep -v on a marker name is the drift shape.
inline_count=$(grep -cE "grep -v '\\\\\[(captured|existing|assessed|tracked|note)" "$HOOK" || true)
if [[ "$inline_count" == "0" ]]; then
  check "hook contains no inline marker grep filters (0 \`grep -v '\\[<marker>'\` chains)" 1
else
  check "hook contains $inline_count inline marker grep filters — should source classify_deferred_lines" 0
fi

# --- Section 3: header comment lists all 5 canonical markers ---

CANONICAL_MARKERS=$(grep '^CLASSIFY_DEFERRED_MARKERS=' "$CLASSIFIER" | sed -E 's/^[^"]+"([^"]+)"$/\1/' | tr '|' ' ')
if [[ -z "$CANONICAL_MARKERS" ]]; then
  check "could not extract CLASSIFY_DEFERRED_MARKERS from canonical script" 0
else
  all_present=1
  missing=""
  for m in $CANONICAL_MARKERS; do
    if ! grep -q "\[${m}" "$HOOK"; then
      all_present=0
      missing="$missing $m"
    fi
  done
  if [[ "$all_present" == "1" ]]; then
    check "header comment mentions all canonical markers: $CANONICAL_MARKERS" 1
  else
    check "header comment missing markers:$missing (canonical: $CANONICAL_MARKERS)" 0
  fi
fi

# --- Section 4: header comment documents the prefix-or-end-of-bullet rule ---

# The skills-repo cross-repo probe (Section 4) asserts exactly this phrasing.
# Mirroring it here makes the invariant testable from the hooks-repo side too.
if grep -qE 'end-of-bullet|prefix or end' "$HOOK"; then
  check "hook header documents prefix-or-end-of-bullet recognition rule" 1
else
  check "hook header missing prefix-or-end-of-bullet rule documentation" 0
fi

# --- Section 5: behavioral smoke — sourcing the canonical script + filtering works ---

# Source the classifier in a subshell and verify it filters a synthetic deferred
# block correctly: 5 markers (prefix + end-of-bullet) silenced, plain bullet survives.
RESULT=$(bash -c '
  . "'"$CLASSIFIER"'"
  cat <<EOF | classify_deferred_lines
- [captured] should be silenced
- [existing: foo.md] should be silenced
- [assessed: reviewed] should be silenced
- [tracked: REQ-01] should be silenced
- [note] should be silenced
- Long bullet body with end marker [note: trailing]
- Long bullet body with end marker [captured: end]
- ~~strikethrough should be silenced~~
- None
- Real unassessed bullet that should survive
EOF
')

surviving_count=$(echo "$RESULT" | sed '/^$/d' | wc -l | tr -d ' ')
if [[ "$surviving_count" == "1" ]]; then
  check "smoke test: 1 of 10 synthetic bullets survives canonical filter" 1
else
  check "smoke test: $surviving_count bullets survived (expected 1) — output: $RESULT" 0
fi

if echo "$RESULT" | grep -q "Real unassessed bullet that should survive"; then
  check "smoke test: surviving bullet is the unmarked one" 1
else
  check "smoke test: wrong bullet survived — output: $RESULT" 0
fi

# --- Section 6: HP-028 round-2 — auto-silence pipelines collapsed ---
#
# Pre-2026-05-02 the auto-silence loop was inline in the hook (lines 183/195)
# and used `grep -rl … | head -1 | grep -q .` / `find … | head -1 | grep -q .`
# shapes — `head -1` is the early-exit reader that can SIGPIPE the upstream
# `grep -rl` / `find` under pipefail. Round-2 sweep collapsed each into a
# single short-circuiting command with no multi-stage pipeline:
#   grep -rq "$rid" "$DIR" 2>/dev/null
#   [ -n "$(find "$DIR" -name "$bname" -print -quit 2>/dev/null)" ]
#
# As of 2026-05-02 the auto-silence body lives in `auto_silence_deferred_lines`
# inside the canonical classifier (~/.claude/dhx-tools/dhx-classify-deferred.sh).
# Sections 6.1/6.2 still assert the hook stays free of broken shapes; 6.3/6.4
# follow the collapsed forms to their new home in the canonical script. The
# variable name pivots from `$CWD` to `$project_root` because the helper
# resolves the project root from its `$1` (a CONTEXT.md path) by walking
# parents to find `.planning/`. The bug class (SIGPIPE under pipefail) is
# identical in both locations.

# 6.1 No `head -1 | grep -q` pipelines (the broken shape) outside comments.
#     Strip lines whose first non-space character is `#` so the round-2 commit
#     comment that documents the prior shape doesn't trip the regex.
if grep -vE '^[[:space:]]*#' "$HOOK" | grep -qE 'head -1[[:space:]]*\|[[:space:]]*grep -q'; then
  check "no 'head -1 | grep -q' pipelines remain in hook (HP-028 round-2)" 0
else
  check "no 'head -1 | grep -q' pipelines remain in hook (HP-028 round-2)" 1
fi

# 6.2 No `grep -rl … |` pipelines targeting the backlog (the broken shape
#     for the pre-extraction line 183) outside comments.
if grep -vE '^[[:space:]]*#' "$HOOK" | grep -qE 'grep -rl .*\.planning/backlog'; then
  check "no 'grep -rl … .planning/backlog' pipeline remains in hook" 0
else
  check "no 'grep -rl … .planning/backlog' pipeline remains in hook" 1
fi

# 6.3 Canonical script's backlog containment uses a `grep -rqE` short-circuit form.
#     The pattern arg evolved 2026-05-22: bare-substring "$rid" → definition-
#     anchored "$rid_def_pat" (the auto_silence_deferred_lines false-positive
#     fix — an artifact-name fragment appearing in REQUIREMENTS.md prose must no
#     longer bare-substring-match and silence a marker-less deferred bullet). The
#     HP-028 invariant this section guards is unchanged: still a single
#     short-circuiting `-q` command, no `grep -rl … | head -1` pipeline.
#     See ~/repos/skills/reports/done/2026-05-22-classify-deferred-auto-silence-false-positive.md
if grep -qE 'grep -rqE[[:space:]]+"\$rid_def_pat"[[:space:]]+"\$project_root/\.planning/backlog/"' "$CLASSIFIER"; then
  check "backlog containment in canonical script uses definition-anchored 'grep -rqE \$rid_def_pat' short-circuit form" 1
else
  check "backlog containment in canonical script does NOT use definition-anchored 'grep -rqE \$rid_def_pat' — form missing/regressed" 0
fi

# 6.4 Canonical script's todos basename lookup uses `find -print -quit` short-circuit form.
if grep -qE 'find[[:space:]]+"\$project_root/\.planning/todos"[[:space:]]+-name[[:space:]]+"\$bname"[[:space:]]+-print[[:space:]]+-quit' "$CLASSIFIER"; then
  check "todos basename lookup in canonical script uses 'find … -print -quit' (collapsed form)" 1
else
  check "todos basename lookup in canonical script does not use 'find … -print -quit' — collapsed form missing" 0
fi

# --- Section 7: behavioral smoke for the collapsed forms ---
#
# Build a synthetic .planning/backlog tree with $rid early in the listing and
# verify `grep -rq` detects it; build a synthetic .planning/todos tree with
# $bname present and verify `find -print -quit` detects it. These exercise
# the exact idioms the hook now uses, not the hook's full Stop pipeline.
TMP_FIXTURE=$(mktemp -d /tmp/probe-deferred-collapse.XXXXXX)
trap 'rm -rf "$TMP_FIXTURE"' EXIT

mkdir -p "$TMP_FIXTURE/.planning/backlog"
# Multiple files in the backlog; $rid only present in one. grep -rq must
# short-circuit on first match without piping to head.
for i in $(seq 1 20); do
  printf 'unrelated content %d\n' "$i" > "$TMP_FIXTURE/.planning/backlog/item-$i.md"
done
echo 'tracked under REQ-V2-004 with extra context' > "$TMP_FIXTURE/.planning/backlog/has-rid.md"

if grep -rq "REQ-V2-004" "$TMP_FIXTURE/.planning/backlog/" 2>/dev/null; then
  check "smoke: 'grep -rq REQ-V2-004' detects match in synthetic backlog" 1
else
  check "smoke: 'grep -rq REQ-V2-004' missed the match — collapse form broken" 0
fi

# Negative case: rid absent → no match.
if grep -rq "DOES-NOT-EXIST-99" "$TMP_FIXTURE/.planning/backlog/" 2>/dev/null; then
  check "smoke: 'grep -rq' false-positive on absent rid" 0
else
  check "smoke: 'grep -rq' correctly returns no match for absent rid" 1
fi

mkdir -p "$TMP_FIXTURE/.planning/todos"
touch "$TMP_FIXTURE/.planning/todos/2026-04-15-some-todo.md"
touch "$TMP_FIXTURE/.planning/todos/2026-04-20-target-todo.md"
touch "$TMP_FIXTURE/.planning/todos/2026-04-25-other-todo.md"

# Positive: target file detected via find -print -quit.
HIT=$(find "$TMP_FIXTURE/.planning/todos" -name "2026-04-20-target-todo.md" -print -quit 2>/dev/null)
if [ -n "$HIT" ]; then
  check "smoke: 'find … -print -quit' detects matching basename" 1
else
  check "smoke: 'find … -print -quit' missed the match — collapse form broken" 0
fi

# Negative: absent basename → empty result.
MISS=$(find "$TMP_FIXTURE/.planning/todos" -name "nonexistent.md" -print -quit 2>/dev/null)
if [ -z "$MISS" ]; then
  check "smoke: 'find … -print -quit' correctly returns empty for absent basename" 1
else
  check "smoke: 'find … -print -quit' false-positive on absent basename: $MISS" 0
fi

# --- Section 8: block-message drops the inline marker legend (SC#3 / D-06) ---
#
# REVERSAL of e2bd3df (2026-05-02): the 6-marker inline legend was removed
# from the Stop block message (Phase 20, D-06) — it re-printed ~565 chars on
# every Stop block (~127K effective tok/7d) for operators who already know the
# markers. Section 8 was inverted from "asserts each marker is PRESENT" to:
#   (a) NO inline marker enumeration survives in the MSG body,
#   (b) the one-line pointer replacement IS present, and
#   (c) HP-009 survives — the hook still emits the decision:block JSON AND the
#       uncaptured-items count line (legend removal must not collaterally drop
#       the blocking path; that would silently stop blocking session-end).
# Marker syntax stays discoverable at /dhx:defer-review or /dhx:capture.
#
# Backs: docs/decisions.md Phase 20 block-message legend-removal row
#        (cites e2bd3df reversal + exact old/new char + approx token counts).
MSG_BLOCK=$(awk '/^MSG="/{f=1} f{print} f && /"$/ && !/^MSG="/{f=0}' "$HOOK")
if [[ -z "$MSG_BLOCK" ]]; then
  check "could not extract MSG= block from hook — assertion shape changed" 0
else
  # 8a. The inline marker legend is gone — no [<marker>…] enumeration in MSG.
  legend_count=$(echo "$MSG_BLOCK" | grep -cE '\[(captured|existing|assessed|tracked|note|preserved-in)[]:]' || true)
  if [[ "$legend_count" == "0" ]]; then
    check "MSG block no longer enumerates the inline marker legend (0 markers)" 1
  else
    check "MSG block still enumerates $legend_count marker(s) — legend not removed" 0
  fi

  # 8b. The one-line pointer replacement is present.
  if echo "$MSG_BLOCK" | grep -qF 'See /dhx:defer-review or /dhx:capture for marker syntax.'; then
    check "MSG block carries the one-line marker-syntax pointer (replacement landed)" 1
  else
    check "MSG block missing the 'See /dhx:defer-review or /dhx:capture' pointer" 0
  fi

  # 8c. HP-009 survives — the uncaptured-items count line is intact.
  if echo "$MSG_BLOCK" | grep -qF 'DEFERRED ITEM REVIEW — ${COUNT} unassessed item(s)'; then
    check "MSG block retains the uncaptured-items count line (HP-009 listing)" 1
  else
    check "MSG block dropped the count line — HP-009 uncaptured listing lost" 0
  fi
fi

# 8d. HP-009 survives — the hook still emits the decision:block JSON. This is
#     the safety-critical assertion: a legend-removal edit must NOT collaterally
#     drop the blocking path. The hook blocks via {"decision":"block"} JSON +
#     exit 0 (NOT exit 2) per HP-009 — assert the JSON literal, never exit 2.
if grep -qF '{"decision": "block", "reason": $msg}' "$HOOK"; then
  check "hook still emits decision:block JSON (HP-009 blocking path survives)" 1
else
  check "hook dropped decision:block JSON — Stop blocking silently broken" 0
fi

# --- Section 9: hook funnels SILENCED-marker hash through canonical extractor ---
#
# Invariant: the hook's SILENCED-marker path computation MUST route through
# silenced_marker_path_from_file (or silenced_marker_extract_block + silenced_marker_path)
# from ~/.claude/dhx-tools/dhx-silenced-marker.sh. The earlier shape — inline
# sed-extraction of the <deferred> block (with boundary tags captured) fed into
# silenced_marker_path — produced a different byte sequence than the writer
# (defer-review.md Step 4a, which uses the helper's awk extraction without
# boundary tags). Hash divergence meant the writer's marker filename never
# matched the hook's recomputation, breaking the 10-min suppression contract
# end-to-end (skills-repo CR-01).
#
# This section is the local backing probe for the 2026-05-09 decisions row
# documenting the migration. Sister assertion: skills-repo
# tests/probe-deferred-silence-e2e.sh:81-83 detects the same migration via the
# HOOK_USES_CANONICAL gate (warn-skip vs full PROBE_MODE).
#
# Backs: docs/decisions.md 2026-05-09 silenced-marker canonical-extractor row.

SILENCED_HELPER="${DHX_TOOLS:-$HOME/.claude/dhx-tools}/dhx-silenced-marker.sh"
if [[ ! -r "$SILENCED_HELPER" ]]; then
  check "silenced-marker helper unreadable at $SILENCED_HELPER — symlink missing?" 0
else
  if grep -q "dhx-silenced-marker.sh" "$HOOK"; then
    check "hook sources dhx-silenced-marker.sh" 1
  else
    check "hook missing dhx-silenced-marker.sh source — SILENCED contract bypassed" 0
  fi

  if grep -qE "silenced_marker_path_from_file|silenced_marker_extract_block" "$HOOK"; then
    check "hook funnels through canonical extractor (silenced_marker_path_from_file or silenced_marker_extract_block)" 1
  else
    check "hook calls silenced_marker_path directly — bypasses canonical extractor (CR-01 drift shape)" 0
  fi

  # No inline <deferred> sed-extraction feeding the marker hash. The line 183
  # sed extraction (DEFERRED=...) for the classification pipeline is allowed —
  # it does NOT feed the SILENCED hash. The forbidden shape is a sed extraction
  # captured into a variable like *BLOCK_TEXT* / *DEFERRED_BLOCK* whose result
  # is then passed to silenced_marker_path. Static guard: assert no variable
  # named DEFERRED_BLOCK_TEXT (the pre-migration shape) re-enters the hook.
  if grep -qE "^[[:space:]]*DEFERRED_BLOCK_TEXT=" "$HOOK"; then
    check "hook reintroduced inline DEFERRED_BLOCK_TEXT extraction — pre-migration drift shape" 0
  else
    check "hook contains no DEFERRED_BLOCK_TEXT inline extraction (pre-migration shape absent)" 1
  fi
fi

# --- Section 10: count formula is empty/whitespace-safe (SC#1 / D-01 / D-10) ---
#
# Bug history: line ~218 used `COUNT=$(echo "$UNCAPTURED" | wc -l | tr -d ' ')`.
# `echo` appends a phantom newline, so empty input → 1 and whitespace-only
# input (e.g. "   ", which passes the line-215 `-z` guard) → 1 too — a phantom
# "1 unassessed item(s)" Stop block on a CONTEXT.md with zero real deferrals.
# See reports/done/2026-05-12-dhx-deferred-check-fires-on-empty-uncaptured.md.
#
# Fix A (D-01 + D-10 errexit-safety): the count formula is bullet-shape-aware
# AND errexit-safe — `printf '%s\n' "$UNCAPTURED" | grep -c '^- ' || true`.
# `printf` does not append a phantom newline for empty input; `grep -c '^- '`
# counts only classifier bullets; the trailing `|| true` neutralizes grep's
# rc=1-on-zero-matches so a future `set -e` cannot crash the hook.
# Fix B (defense-in-depth): `[ "${COUNT:-0}" -le 0 ] && exit 0` numeric guard.
#
# Backs: docs/decisions.md Phase 20 row (count-bug fix).

# 10a. Static: Fix A formula present verbatim (bullet-shape-aware + D-10 `|| true`).
if grep -qF "printf '%s\n' \"\$UNCAPTURED\" | grep -c '^- ' || true" "$HOOK"; then
  check "hook count formula is errexit-safe Fix A (printf|grep -c '^- '|| true)" 1
else
  check "hook count formula missing errexit-safe Fix A — count-bug not fixed" 0
fi

# 10b. Static: the old buggy echo|wc -l formula is gone.
if grep -qF 'echo "$UNCAPTURED" | wc -l' "$HOOK"; then
  check "old buggy 'echo \$UNCAPTURED | wc -l' formula still present — must be removed" 0
else
  check "old buggy 'echo \$UNCAPTURED | wc -l' formula removed" 1
fi

# 10c. Static: Fix B numeric guard present.
if grep -qE '\[ "\$\{COUNT:-0\}" -le 0 \] && exit 0' "$HOOK"; then
  check "hook has Fix B numeric guard ([ \"\${COUNT:-0}\" -le 0 ] && exit 0)" 1
else
  check "hook missing Fix B numeric guard — defense-in-depth absent" 0
fi

# 10d. Behavioral: EMPTY input → count 0 (the formula primitive the hook uses).
#      `-z` already short-circuits empty at line 215, but the count must still
#      be structurally 0 if the formula is ever reached with empty input.
EMPTY_COUNT=$(printf '%s\n' "" | grep -c '^- ' || true)
if [[ "${EMPTY_COUNT:-X}" == "0" ]]; then
  check "behavioral: empty \$UNCAPTURED → count 0 (no phantom item)" 1
else
  check "behavioral: empty \$UNCAPTURED → count $EMPTY_COUNT (expected 0)" 0
fi

# 10e. Behavioral: WHITESPACE-ONLY input → count 0 (THE load-bearing case).
#      A non-empty string of blanks passes the `-z` guard and reaches the count
#      line; the old echo|wc -l returned 1 here (the phantom block). The new
#      formula must return 0. Test both a blanks string and a lone newline.
WS_COUNT=$(printf '%s\n' "   " | grep -c '^- ' || true)
NL_COUNT=$(printf '%s\n' "
" | grep -c '^- ' || true)
if [[ "${WS_COUNT:-X}" == "0" && "${NL_COUNT:-X}" == "0" ]]; then
  check "behavioral: whitespace-only \$UNCAPTURED → count 0 (phantom block fixed)" 1
else
  check "behavioral: whitespace-only \$UNCAPTURED → blanks=$WS_COUNT newline=$NL_COUNT (expected 0/0)" 0
fi

# 10f. Behavioral: real bullet input → count reflects actual bullet count.
REAL_COUNT=$(printf '%s\n' "- first bullet
- second bullet" | grep -c '^- ' || true)
if [[ "${REAL_COUNT:-X}" == "2" ]]; then
  check "behavioral: 2 real '- ' bullets → count 2 (HP-009 block still fires)" 1
else
  check "behavioral: 2 real bullets → count $REAL_COUNT (expected 2)" 0
fi

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]
