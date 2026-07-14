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
# AND errexit-safe — `printf '%s\n' "$UNCAPTURED" | grep -cE '<bullet-shape>' || true`.
# `printf` does not append a phantom newline for empty input; the grep counts only
# classifier bullets; the trailing `|| true` neutralizes grep's rc=1-on-zero-matches
# so a future `set -e` cannot crash the hook.
# Fix B (defense-in-depth): `[ "${COUNT:-0}" -le 0 ] && exit 0` numeric guard.
#
# 2026-07-14 — the bullet shape is now `^[[:space:]]*[-*+][[:space:]]+` (ERE), adopted
# verbatim from dhx-assessed-guard.sh:52. The prior `^- ` was BOTH indent-blind AND
# separator-blind: `classify_deferred_lines` matches `/^[ \t]*-[ \t]/` and emits the
# bullet with its ORIGINAL indent preserved (`print first_line`), so an indented bullet
# ("  - item") or a tab-separated one ("-\titem") counted 0 — and Fix B's `-le 0` guard
# then exited the hook SILENTLY on a genuine unassessed item. The defense-in-depth guard
# was the bypass. Section 13 is the behavioral leg that would have caught it.
#
# Backs: docs/decisions.md Phase 20 row (count-bug fix) + 2026-07-14 bullet-shape row.

# 10a. Static: Fix A formula present verbatim (bullet-shape-aware + D-10 `|| true`).
if grep -qF "printf '%s\n' \"\$UNCAPTURED\" | grep -cE '^[[:space:]]*[-*+][[:space:]]+' || true" "$HOOK"; then
  check "hook count formula is errexit-safe Fix A (printf|grep -cE bullet-shape|| true)" 1
else
  check "hook count formula missing errexit-safe Fix A — count-bug not fixed" 0
fi

# 10b. Static: the old buggy echo|wc -l formula is gone.
if grep -qF 'echo "$UNCAPTURED" | wc -l' "$HOOK"; then
  check "old buggy 'echo \$UNCAPTURED | wc -l' formula still present — must be removed" 0
else
  check "old buggy 'echo \$UNCAPTURED | wc -l' formula removed" 1
fi

# 10b'. Static: the indent-blind `grep -c '^- '` shape is gone from BOTH count sites.
#       It is the 2026-07-14 silent-bypass shape — an anchored literal-space match against
#       a producer that emits indented and tab-separated bullets. Zero occurrences allowed.
INDENT_BLIND=$(grep -cF "grep -c '^- '" "$HOOK" || true)
if [[ "${INDENT_BLIND:-0}" -eq 0 ]]; then
  check "indent-blind \`grep -c '^- '\` count shape removed from both paths" 1
else
  check "indent-blind \`grep -c '^- '\` still present ($INDENT_BLIND site(s)) — silent-bypass shape" 0
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

# 10g. Behavioral: the count formula the HOOK actually runs must honor the producer's
#      bullet grammar on EVERY axis `classify_deferred_lines` accepts (`/^[ \t]*-[ \t]/`):
#      leading indent AND a tab as the post-dash separator. Extracted live from the hook
#      so this cannot drift from the shipped formula — a hard-coded regex here would pass
#      while the hook stayed broken, which is exactly how the 2026-07-14 bypass survived.
#
#      This is the leg that would have caught it: pre-fix, `^- ` scored indented=0 and
#      tab=0, the `-le 0` guard fired, and the Stop hook exited silently on a genuine
#      unassessed deferred item.
HOOK_BULLET_RE=$(grep -oE "grep -cE '[^']+'" "$HOOK" | head -1 | sed -E "s/^grep -cE '//; s/'$//")
if [[ -z "$HOOK_BULLET_RE" ]]; then
  check "could not extract the hook's live bullet-count regex — count formula shape changed" 0
else
  FLUSH_C=$(printf '%s\n' "- flush-left bullet"          | grep -cE "$HOOK_BULLET_RE" || true)
  INDENT_C=$(printf '%s\n' "  - indented bullet"          | grep -cE "$HOOK_BULLET_RE" || true)
  TAB_C=$(printf -- '-\ttab-separated bullet\n'           | grep -cE "$HOOK_BULLET_RE" || true)
  EMPTY_C=$(printf '%s\n' ""                              | grep -cE "$HOOK_BULLET_RE" || true)
  WS_C=$(printf '%s\n' "   "                              | grep -cE "$HOOK_BULLET_RE" || true)

  if [[ "$FLUSH_C" == "1" && "$INDENT_C" == "1" && "$TAB_C" == "1" ]]; then
    check "behavioral: hook's live count regex honors the producer's bullet grammar (flush/indent/tab all → 1)" 1
  else
    check "behavioral: hook count regex is bullet-shape-blind — flush=$FLUSH_C indent=$INDENT_C tab=$TAB_C (expected 1/1/1). An unmarked deferred item in a shape the classifier EMITS counts 0 → the \`-le 0\` guard exits the Stop hook SILENTLY." 0
  fi

  # The D-01/D-10 phantom-count property must survive the shape widening.
  if [[ "$EMPTY_C" == "0" && "$WS_C" == "0" ]]; then
    check "behavioral: widened bullet shape preserves D-01 phantom-count guard (empty=0, whitespace=0)" 1
  else
    check "behavioral: widened bullet shape REGRESSED D-01 — empty=$EMPTY_C whitespace=$WS_C (expected 0/0)" 0
  fi
fi

# --- Section 11: header-fallback count is empty/whitespace-safe (WR-03) ---
#
# Phase 20 code-review follow-up (20-REVIEW.md WR-03): check_header_fallback()
# retained the same `echo "$MD_DEFERRED" | wc -l` formula the main UNCAPTURED path
# fixed in D-01 — a sibling code path with the identical phantom-count bug. A
# whitespace-only classifier result passes the `-n "$MD_DEFERRED"` guard and
# `echo|wc -l` returns 1, producing a phantom "1 deferred item(s) found under
# markdown headers" warning. The fix mirrors D-01: bullet-shape-aware errexit-safe
# count + a positive-count guard before emitting. The whitespace→0 behavioral
# primitive is already proven in 10d/10e (same formula); 11a-c lock the fallback.
#
# Backs: docs/decisions.md Phase 20 code-review-follow-up row (WR-03).

# 11a. Static: header-fallback uses the safe printf|grep -cE formula, same bullet shape
#      as the main path (2026-07-14 — the indent/separator-blind `^- ` was cloned here
#      by WR-03, so the silent bypass existed in BOTH paths).
if grep -qF "printf '%s\n' \"\$MD_DEFERRED\" | grep -cE '^[[:space:]]*[-*+][[:space:]]+' || true" "$HOOK"; then
  check "header-fallback count formula is errexit-safe (printf|grep -cE bullet-shape|| true)" 1
else
  check "header-fallback count formula missing safe form — WR-03 not fixed" 0
fi

# 11b. Static: the old buggy echo|wc -l formula is gone from the header-fallback.
if grep -qF 'echo "$MD_DEFERRED" | wc -l' "$HOOK"; then
  check "old buggy 'echo \$MD_DEFERRED | wc -l' header-fallback formula still present" 0
else
  check "old buggy 'echo \$MD_DEFERRED | wc -l' header-fallback formula removed" 1
fi

# 11c. Static: a positive-count guard now exists in BOTH paths (main + fallback).
GUARD_COUNT=$(grep -cE '\[ "\$\{COUNT:-0\}" -le 0 \] && exit 0' "$HOOK" || true)
if [[ "${GUARD_COUNT:-0}" -ge 2 ]]; then
  check "positive-count guard present in both main + header-fallback paths (>=2)" 1
else
  check "header-fallback missing positive-count guard (found $GUARD_COUNT, expected >=2)" 0
fi

# --- Section 12: header-fallback pipelines through BOTH stages (2026-05-27) ---
#
# Pre-2026-05-27 the header-fallback ran Stage 1 only (classify_deferred_lines)
# while the main UNCAPTURED path ran Stage 1 + Stage 2 (auto_silence_deferred_lines).
# Consequence: an item under an UNTAGGED `## Deferred` header whose only
# durable-home signal is a Stage-2 signal (resolvable REQ-ID or dated `.md`
# citation) — but which carries no Stage-1-recognizable marker — was silenced
# by the main path but surfaced as a false positive by the header-fallback.
#
# Backs: docs/decisions.md 2026-05-27 header-fallback Stage 2 parity row.
# Parent brief: .planning/backlog/2026-05-22-deferred-check-header-fallback-missing-stage2-autosilence.md

# 12a. Static: check_header_fallback() body contains the second-stage call.
#      `auto_silence_deferred_lines "$file"` is uniquely the fallback shape —
#      the main UNCAPTURED path uses `"$LATEST"` for the same call, so this
#      string only appears inside check_header_fallback (or in this comment).
HF_BODY=$(awk '/^check_header_fallback\(\) \{/{f=1} f{print} f && /^\}$/{f=0; exit}' "$HOOK")
if [[ -z "$HF_BODY" ]]; then
  check "could not extract check_header_fallback body — assertion shape changed" 0
else
  if echo "$HF_BODY" | grep -q 'classify_deferred_lines' \
     && echo "$HF_BODY" | grep -qE 'auto_silence_deferred_lines[[:space:]]+"\$file"'; then
    check "check_header_fallback pipelines through both stages (classify_deferred_lines + auto_silence_deferred_lines \"\$file\")" 1
  else
    check "check_header_fallback missing two-stage pipeline — Stage 2 not wired" 0
  fi
fi

# 12b. Behavioral: untagged `## Deferred` header with a Stage-2-only-silenceable
#      item (REQ-ID resolvable in REQUIREMENTS.md, no Stage-1 marker) — the
#      two-stage pipeline must silence it; the single-stage pipeline would NOT.
TMP_FIXTURE_HF=$(mktemp -d /tmp/probe-deferred-hf-stage2.XXXXXX)
trap 'rm -rf "$TMP_FIXTURE" "$TMP_FIXTURE_HF"' EXIT

mkdir -p "$TMP_FIXTURE_HF/.planning/phases/01-stage2-test"
mkdir -p "$TMP_FIXTURE_HF/.planning/backlog"
# Stage-2 corpus: REQ-V2-FALLBACK defined in REQUIREMENTS.md (bold body def
# anchor — the auto_silence rid_def_pat shape), and a dated backlog brief
# whose basename matches a citation we'll put in the fixture.
cat > "$TMP_FIXTURE_HF/.planning/REQUIREMENTS.md" <<'EOF'
# Requirements

**REQ-V2-FALLBACK** — fallback Stage-2 silencing target for the header-fallback probe.
EOF
touch "$TMP_FIXTURE_HF/.planning/backlog/2026-05-22-stage2-fallback-target.md"

# Fixture CONTEXT.md: NO <deferred> tags (header-fallback is the only path that fires);
# `## Deferred` header with three bullets — REQ-ID-only-resolvable, dated-filename-only-
# resolvable, and one unmarked bullet that should survive (no Stage-2 anchor at all).
HF_CTX="$TMP_FIXTURE_HF/.planning/phases/01-stage2-test/01-CONTEXT.md"
cat > "$HF_CTX" <<'EOF'
# Phase 01 — Stage2 fallback test

## Deferred

- Item resolvable only via REQ-V2-FALLBACK (no Stage-1 marker)
- Item resolvable only via 2026-05-22-stage2-fallback-target.md (no Stage-1 marker)
- Real unassessed bullet with no durable-home signal at all

## Next Section
EOF

# Run the header-fallback pipeline shape (sed extraction + both stages) the same
# way the hook does. Sourcing the canonical classifier mirrors how the hook
# composes the pipeline.
HF_RESULT=$(bash -c '
  . "'"$CLASSIFIER"'"
  sed -n "/^##[^#].*[Dd]eferred/,/^##[^#]/p" "'"$HF_CTX"'" \
    | classify_deferred_lines \
    | auto_silence_deferred_lines "'"$HF_CTX"'"
')

survived_hf=$(printf '%s\n' "$HF_RESULT" | grep -c '^- ' || true)
if [[ "$survived_hf" == "1" ]] && printf '%s\n' "$HF_RESULT" | grep -q "Real unassessed bullet"; then
  check "header-fallback two-stage: Stage-2-only items silenced (REQ-ID + dated filename); 1 unmarked bullet survives" 1
else
  check "header-fallback two-stage failure — $survived_hf bullet(s) survived (expected 1: only the unmarked bullet). Output: $HF_RESULT" 0
fi

# 12c. Negative control: confirm Stage 1 ALONE would have left both Stage-2-only
#      items un-silenced — establishes that the silencing in 12b comes from
#      Stage 2 specifically (the bug surface), not coincidental Stage 1 behavior.
HF_STAGE1_ONLY=$(bash -c '
  . "'"$CLASSIFIER"'"
  sed -n "/^##[^#].*[Dd]eferred/,/^##[^#]/p" "'"$HF_CTX"'" \
    | classify_deferred_lines
')
survived_stage1=$(printf '%s\n' "$HF_STAGE1_ONLY" | grep -c '^- ' || true)
if [[ "$survived_stage1" == "3" ]]; then
  check "negative control: Stage 1 alone leaves all 3 bullets unsilenced — Stage 2 is what silences the REQ-ID + dated-filename items" 1
else
  check "negative control failed: Stage 1 alone produced $survived_stage1 bullets (expected 3) — fixture or classifier drift. Output: $HF_STAGE1_ONLY" 0
fi

# --- Section 13: end-to-end — an INDENTED unmarked bullet must BLOCK (2026-07-14) ---
#
# The bypass this section exists to prevent, in full:
#
#   $UNCAPTURED = "  - Indented deferred item, unmarked, genuine future work"
#     :232  [ -z "$UNCAPTURED" ] && exit 0     → passes (output is NON-empty)
#     :239  COUNT=$(… | grep -c '^- ')         → 0     ← indent-blind
#     :242  [ "${COUNT:-0}" -le 0 ] && exit 0  → FIRES → hook exits SILENTLY
#
# `classify_deferred_lines` matches `/^[ \t]*-[ \t]/` (indent-tolerant) and emits the
# surviving bullet with its ORIGINAL indent preserved. The hook counted with `^- `
# (indent-intolerant). The two disagreed, and Fix B's defense-in-depth numeric guard
# absorbed the disagreement — turning a safety net INTO a live bypass of the shipped
# Stop-hook backstop, on a genuine unassessed item.
#
# Sections 10a/10g pin the formula and its shape. THIS section proves the user-visible
# contract: the hook actually emits `decision: block`. A static pin alone re-freezes
# whatever string is there; the behavioral leg is what makes the probe a test.
#
# Backs: docs/decisions.md 2026-07-14 bullet-shape row.
# Source: docs/prompts/done/2026-07-14-deferred-check-indent-blind-count-prompt.md

TMP_FIXTURE_E2E=$(mktemp -d /tmp/probe-deferred-e2e-indent.XXXXXX)
trap 'rm -rf "$TMP_FIXTURE" "$TMP_FIXTURE_HF" "$TMP_FIXTURE_E2E"' EXIT

mkdir -p "$TMP_FIXTURE_E2E/.planning/phases/01-indent-bypass"
E2E_CTX="$TMP_FIXTURE_E2E/.planning/phases/01-indent-bypass/01-CONTEXT.md"

# No STATE.md → PHASE_ALLOWLIST stays empty → the hook takes the unfiltered
# `ls -t | head -1` discovery path and lands on this CONTEXT.md.
#
# Bullet shapes below are BOTH legal producer output (classify_deferred_lines accepts
# `/^[ \t]*-[ \t]/`), carry NO silencing marker, and have NO Stage-2 durable-home signal
# (no resolvable REQ-ID, no dated .md citation) — so both MUST survive to the count.
run_e2e_hook() {
  local ctx_body="$1"
  cat > "$E2E_CTX" <<EOF
# Phase 01 — indent bypass e2e

<deferred>
$ctx_body
</deferred>
EOF
  jq -n --arg c "$TMP_FIXTURE_E2E" '{cwd: $c, stop_hook_active: false}' \
    | bash "$HOOK" 2>/dev/null || true
}

# 13a. Behavioral e2e: a single INDENTED unmarked bullet must produce decision:block.
E2E_INDENT=$(run_e2e_hook '  - Indented deferred item, unmarked, genuine future work')
if printf '%s' "$E2E_INDENT" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  check "e2e: indented unmarked deferred bullet → decision:block (silent-bypass closed)" 1
else
  check "e2e: indented unmarked deferred bullet did NOT block — hook exited silently on a genuine unassessed item. Hook output: [${E2E_INDENT:-<empty>}]" 0
fi

# 13b. Behavioral e2e: the block message must report a NON-ZERO item count. Guards the
#      half-fix where the shape widens but the count line still under-reports.
E2E_COUNT=$(printf '%s' "$E2E_INDENT" | jq -r '.reason // ""' 2>/dev/null \
  | grep -oE '[0-9]+ unassessed item' | grep -oE '^[0-9]+' || true)
if [[ "${E2E_COUNT:-0}" -ge 1 ]]; then
  check "e2e: block message reports COUNT >= 1 for the indented bullet (got $E2E_COUNT)" 1
else
  check "e2e: block message reported COUNT=${E2E_COUNT:-0} (expected >=1) — count line under-reports" 0
fi

# 13c. Behavioral e2e: TAB-after-dash is the second axis of the same bug. The classifier
#      accepts `-\titem`; a literal-space count shape (`^[[:space:]]*- `) still scores it 0.
#      This is why the fix adopts dhx-assessed-guard.sh:52's `[[:space:]]+` character class
#      rather than a literal space.
E2E_TAB=$(run_e2e_hook "$(printf -- '-\tTab-separated deferred item, unmarked, genuine future work')")
if printf '%s' "$E2E_TAB" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  check "e2e: tab-after-dash unmarked deferred bullet → decision:block (separator axis closed)" 1
else
  check "e2e: tab-after-dash unmarked bullet did NOT block — separator-blind count. Hook output: [${E2E_TAB:-<empty>}]" 0
fi

# 13d. Negative control: an indented bullet carrying a silencing marker must NOT block.
#      Without this, 13a-13c could pass on a hook that blocks unconditionally — the widened
#      count must still respect the marker protocol, not merely count more things. Both
#      marker positions are exercised (prefix and end-of-bullet).
#
# FIXTURE NOTE — the end-of-bullet variant carries a deliberate blank line before
# `</deferred>`. That is NOT cosmetic, and it is not this hook's bug:
# classify_deferred_lines treats ANY non-blank line as a continuation line of the open
# bullet (awk `{ if (have_bullet) last_body = $0 }`), so the `</deferred>` CLOSING TAG is
# swallowed as the final bullet's logical last line — and the end-of-bullet marker check
# (`last_body ~ end_marker_re`) then tests the TAG instead of the marker. Net effect: an
# end-of-bullet marker on the LAST bullet of a <deferred> block does not silence unless a
# blank line separates it from the tag. That is a live producer-side (skills-owned) false
# POSITIVE — orthogonal to the false NEGATIVE this section covers, and out of scope here
# (the classifier is probe-pinned and skills-owned; see the prompt's "Do NOT change the
# emit shape of classify_deferred_lines from this repo").
# Filed: ~/repos/skills/reports/2026-07-14-classify-deferred-closing-tag-eats-end-of-bullet-marker.md
# Blank-lining the fixture isolates THIS section to the count-shape change under test;
# without it the control fails for a reason that has nothing to do with the count.
# When that fix lands, DROP the blank line here — the control gets strictly stronger.
E2E_MARKED_PREFIX=$(run_e2e_hook '  - [captured: backlog] Indented deferred item')
if [[ -z "$E2E_MARKED_PREFIX" ]]; then
  check "negative control: indented bullet with PREFIX marker → no block (marker protocol intact)" 1
else
  check "negative control FAILED: prefix-marked indented bullet still blocked — widened count over-matches. Output: [$E2E_MARKED_PREFIX]" 0
fi

E2E_MARKED_END=$(run_e2e_hook '  - Indented deferred item [captured: backlog]
')
if [[ -z "$E2E_MARKED_END" ]]; then
  check "negative control: indented bullet with END-OF-BULLET marker → no block (marker protocol intact)" 1
else
  check "negative control FAILED: end-marked indented bullet still blocked — widened count over-matches. Output: [$E2E_MARKED_END]" 0
fi

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]
