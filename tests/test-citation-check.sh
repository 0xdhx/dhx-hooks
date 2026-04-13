#!/usr/bin/env bash
# test-citation-check.sh — Regression tests for dhx-citation-check.sh
# Implements the revised test plan from tests/PLAN-test-citation-check.md
# Incorporates all 10 review items from tests/REVIEWS-citation-check.md
# Run: bash tests/test-citation-check.sh
# Exit: 0 = all pass, 1 = any failure

set -euo pipefail

# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

# ---------------------------------------------------------------------------
# stderr capture (review item 10 — Codex suggestion)
# Run from repo root so dhx/dhx-citation-check.sh is resolvable
# ---------------------------------------------------------------------------

if [ ! -f "dhx/dhx-citation-check.sh" ]; then
  echo "ERROR: Run from repo root (dhx/dhx-citation-check.sh not found)" >&2
  exit 1
fi

STDERR_FILE=$(mktemp)
trap 'rm -f "$STDERR_FILE"' EXIT

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

# make_stop_json <message> [stop_hook_active]
# Uses jq -n --arg for safe quoting (review item 7) — handles quotes/newlines correctly.
make_stop_json() {
  jq -n \
    --arg msg "$1" \
    --argjson active "${2:-false}" \
    '{
      cwd: "/tmp/test",
      hook_event_name: "Stop",
      last_assistant_message: $msg,
      permission_mode: "default",
      session_id: "test-session",
      stop_hook_active: $active,
      transcript_path: "/tmp/test.jsonl"
    }'
}

# run_hook <json_payload> — captures stdout; stderr goes to $STDERR_FILE
run_hook() {
  local output
  output=$(echo "$1" | bash dhx/dhx-citation-check.sh 2>"$STDERR_FILE")
  echo "$output"
}

# assert_allows <test_name> <json_payload>
assert_allows() {
  local output
  output=$(run_hook "$2")
  assert_empty "$1" "$output"
}

# assert_blocks <test_name> <json_payload> [expected_reason_fragment]
# Uses jq to parse stdout (review item 6) — robust against whitespace variations.
assert_blocks() {
  local output decision
  output=$(run_hook "$2")
  decision=$(echo "$output" | jq -r '.decision // empty' 2>/dev/null)
  if [ "$decision" = "block" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $1 -- decision=block"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $1 -- expected decision=block"
    echo "        Actual output:"
    echo "$output" | head -5 | sed 's/^/          /'
  fi
  if [ -n "${3:-}" ]; then
    local reason
    reason=$(echo "$output" | jq -r '.reason // empty' 2>/dev/null)
    assert_contains "$1 -- reason contains '$3'" "$reason" "$3"
  fi
}

# assert_stderr_empty <test_name>
# Checks that $STDERR_FILE is empty after the previous run_hook call.
assert_stderr_empty() {
  if [ ! -s "$STDERR_FILE" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $1"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $1"
    echo "        stderr was:"
    head -3 "$STDERR_FILE" | sed 's/^/          /'
  fi
}

# assert_stderr_nonempty <test_name>
# Checks that $STDERR_FILE has content (jq error expected).
assert_stderr_nonempty() {
  if [ -s "$STDERR_FILE" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $1"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $1 -- expected stderr to be non-empty"
  fi
}

# pad_to <length> <base_text>
# Pads base_text with trailing spaces to exactly <length> chars.
pad_to() {
  local len=$1 base="$2"
  printf "%-${len}s" "$base"
}

# ---------------------------------------------------------------------------
# P0 — Core gates (must pass or hook is broken)
# ---------------------------------------------------------------------------

test_01_loop_prevention() {
  echo "Test 1: Loop prevention (stop_hook_active=true with uncited year)"
  local msg json
  msg="Python was released in 1991 by Guido van Rossum. It has grown to become one of the most popular programming languages in the world."
  json=$(make_stop_json "$msg" true)
  assert_allows "1: loop prevention — stop_hook_active=true" "$json"
  assert_stderr_empty "1: stderr clean on allow"
}

test_02_empty_message() {
  echo "Test 2: Empty last_assistant_message"
  local json
  json=$(make_stop_json "")
  assert_allows "2: empty message -> allow" "$json"
}

test_03_missing_message() {
  echo "Test 3: Missing last_assistant_message key"
  local json
  json=$(jq -n '{cwd:"/tmp/test",hook_event_name:"Stop",permission_mode:"default",session_id:"test-session",stop_hook_active:false,transcript_path:"/tmp/test.jsonl"}')
  assert_allows "3: missing message key -> allow" "$json"
}

test_04_length_boundary() {
  echo "Test 4: 80-char length gate boundary (review items — Gemini MEDIUM, Codex MEDIUM)"
  # Gate condition: if [ "${#MSG}" -lt 80 ]; then exit 0; fi
  # So exactly 80 chars passes the gate and can block.

  # 79-char message: "Python in 1991" (14 chars) padded to 79 with spaces
  local msg79 msg80 msg81 json79 json80 json81
  msg79=$(pad_to 79 "Python in 1991")
  msg80=$(pad_to 80 "Python in 1991")
  msg81=$(pad_to 81 "Python in 1991")

  # Sanity check lengths
  if [ "${#msg79}" -ne 79 ] || [ "${#msg80}" -ne 80 ] || [ "${#msg81}" -ne 81 ]; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: 4 -- length setup error: got ${#msg79}, ${#msg80}, ${#msg81}"
    return
  fi

  json79=$(make_stop_json "$msg79")
  json80=$(make_stop_json "$msg80")
  json81=$(make_stop_json "$msg81")

  assert_allows "4a: 79-char message with 'in 1991' -> allow (under gate)" "$json79"
  assert_blocks "4b: 80-char message with 'in 1991' -> block (at boundary)" "$json80"
  assert_blocks "4c: 81-char message with 'in 1991' -> block (over boundary)" "$json81"
}

# ---------------------------------------------------------------------------
# P0 — Detection patterns (must fire on obvious cases)
# ---------------------------------------------------------------------------

test_05_uncited_year() {
  echo "Test 5: Uncited year in >80-char message"
  local msg json
  msg="Python was released in 1991 by Guido van Rossum. It has grown to become one of the most popular programming languages in the world."
  json=$(make_stop_json "$msg")
  assert_blocks "5: uncited year -> block" "$json" "1991"
}

test_06_uncited_statistic() {
  echo "Test 6: Uncited statistic (percentage)"
  local msg json
  msg="JavaScript is used by approximately 65% of all developers worldwide, making it the most popular language by a significant margin."
  json=$(make_stop_json "$msg")
  assert_blocks "6: uncited statistic 65% -> block" "$json" "65%"
}

test_07_attribution_phrase() {
  echo "Test 7: Attribution phrase without URL"
  local msg json
  msg="According to recent research, microservices architectures reduce deployment frequency by an average of 200 times compared to monolithic systems."
  json=$(make_stop_json "$msg")
  assert_blocks "7: attribution phrase -> block" "$json"
}

test_08_named_study() {
  echo "Test 8: Named study/report without URL"
  local msg json
  msg="The DORA report found that elite performers deploy 973 times more frequently than low performers across the entire industry."
  json=$(make_stop_json "$msg")
  assert_blocks "8: named study -> block" "$json"
}

test_09_multiple_patterns() {
  echo "Test 9: Multiple claim patterns combined"
  local msg json
  msg="Founded in 2004, Facebook reached 1 billion users. According to the company's annual report, revenue exceeded \$86 billion."
  json=$(make_stop_json "$msg")
  assert_blocks "9: multiple patterns -> block" "$json"
  # Verify claim count >= 2 in the reason
  local output reason
  output=$(run_hook "$json")
  reason=$(echo "$output" | jq -r '.reason // empty' 2>/dev/null)
  # reason includes "N claims" — verify N >= 2
  local claim_count
  claim_count=$(echo "$reason" | grep -oP '\d+ claims' | grep -oP '\d+' || echo "0")
  if [ "${claim_count:-0}" -ge 2 ]; then
    PASS=$((PASS + 1))
    echo "  PASS: 9b: claim count >= 2 ($claim_count)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: 9b: expected claim count >= 2, got: $claim_count"
  fi
}

# ---------------------------------------------------------------------------
# P1 — Exclusion gates
# ---------------------------------------------------------------------------

test_10_code_heavy() {
  echo "Test 10: Code-heavy response (2 fences, <20 lines) -> allow"
  # The hook gates on CODE_FENCE_COUNT >= 2 AND TOTAL_LINES < 20
  # Claims inside the fenced code should be stripped before analysis
  local msg json
  msg=$'Here is the fix:\n```python\n# Released in 2020\nversion = \'3.9\'\nprint(f\'42% complete\')\n```'
  json=$(make_stop_json "$msg")
  assert_allows "10: code-heavy (2 fences, <20 lines) -> allow" "$json"
}

test_11_cited_response() {
  echo "Test 11: Cited response (URL present with claim) -> allow"
  # URL on same line as claim: grep -vP 'https?://' filters the claim line
  local msg json
  msg="Python was released in 1991 (https://python.org/history). It supports multiple paradigms and is widely used."
  json=$(make_stop_json "$msg")
  assert_allows "11: claim with same-line URL -> allow (claim line filtered)" "$json"
}

test_12_version_numbers() {
  echo "Test 12: Version numbers exclude year pattern"
  # "released in 2024 as v2.1.91" -> grep -vP 'v\d+\.' filters the line
  local msg json
  msg="The tool was released in 2024 as v2.1.91 and has been stable since deployment and continuous use."
  json=$(make_stop_json "$msg")
  assert_allows "12: version exclusion (v\\d+\\. on same line) -> allow" "$json"
}

test_12b_http2_known_behavior() {
  echo "Test 12b: HTTP/2 known behavior — not excluded by v\\d+\\. pattern"
  # "HTTP/2 was released in 2015" — HTTP/ is not v\d+\., so it's NOT filtered
  # This documents the baseline: HTTP/2 triggers the year pattern -> block
  local msg json
  msg="HTTP/2 was released in 2015 and improved multiplexing significantly for the web protocol."
  json=$(make_stop_json "$msg")
  assert_blocks "12b: HTTP/2 not v\\d+\\. -> block (known behavior)" "$json"
}

test_13_short_response() {
  echo "Test 13: Short response (<80 chars) -> allow"
  local msg json
  msg="I'll look into that for you."
  json=$(make_stop_json "$msg")
  assert_allows "13: short meta-response -> allow" "$json"
}

test_14_code_with_stats() {
  echo "Test 14: Code with stats (fenced code stripped before analysis)"
  # Claim is inside fenced code block; awk strips it -> allow
  local msg json
  msg=$'The function returns exit code 42% through the error handler.\n```bash\nexit 42\n```'
  json=$(make_stop_json "$msg")
  # After code strip, only "The function returns exit code 42% through the error handler."
  # BUT that line has a stat (42%). Let's check: grep -vP '^\s*[-*]?\s*(Exit|Return|...)' excludes it
  # Actually "exit code 42%" — "Exit" exclusion matches "exit code" line. Let's verify:
  assert_allows "14: code with stats stripped -> allow" "$json"
}

# ---------------------------------------------------------------------------
# P1 — Line-oriented behavior (review item 2 — Codex HIGH)
# ---------------------------------------------------------------------------

test_15_year_split_across_newline() {
  echo "Test 15: Year split across newline -> allow"
  # "released in\n2020..." — trigger word and year on DIFFERENT lines
  # grep -nP requires the full pattern on one line -> no match -> allow
  local msg json
  msg=$'released in\n2020 by Guido van Rossum and the Python Software Foundation and wider'
  json=$(make_stop_json "$msg")
  assert_allows "15: year split across newline -> allow (grep -nP is line-oriented)" "$json"
}

test_16_claim_line_no_url_url_elsewhere() {
  echo "Test 16: Claim on line 1 (no URL), URL on line 2, URL_COUNT < CLAIM_COUNT -> block"
  # 3 claims on different lines, only 1 URL on last line -> URL_COUNT < CLAIM_COUNT
  local msg json
  msg=$'Python was released in 1991. Statistics show 65% usage. Market share grew 40%.\nhttps://example.com'
  json=$(make_stop_json "$msg")
  assert_blocks "16: 3 claims, 1 URL on different line -> block (global count check)" "$json"
}

test_17_claim_and_url_same_line() {
  echo "Test 17: Claim and URL on same line -> allow (claim line filtered)"
  # grep -vP 'https?://' removes lines containing a URL *before* claim counting
  # So the year claim on that line is never counted
  local msg json
  msg="Python was released in 1991 (https://python.org/history) and has become very popular among developers."
  json=$(make_stop_json "$msg")
  assert_allows "17: claim+URL same line -> allow (claim line filtered by grep -vP)" "$json"
}

# ---------------------------------------------------------------------------
# P1 — Global URL-vs-claim count semantics (tests renamed from original P1 edge cases)
# ---------------------------------------------------------------------------

test_18_more_urls_than_claims() {
  echo "Test 18: Global URL count > claim count -> allow"
  local msg json
  msg="Released in 2020 (https://blog.example.com). Updated in 2022 (https://blog.example.com/v2). Stats show 99% adoption (https://stats.example.com)."
  json=$(make_stop_json "$msg")
  assert_allows "18: 3 claims, 3 URLs (URLs >= claims) -> allow" "$json"
}

test_19_equal_urls_and_claims() {
  echo "Test 19: Global URL count == claim count -> allow"
  # 1 year claim, 1 URL — equal counts, URL_COUNT >= CLAIM_COUNT -> allow
  local msg json
  msg="Python was released in 1991 (https://python.org/history). It supports multiple paradigms effectively."
  json=$(make_stop_json "$msg")
  assert_allows "19: 1 claim, 1 URL (equal) -> allow" "$json"
}

test_20_fewer_urls_than_claims() {
  echo "Test 20: Global URL count < claim count -> block"
  # 3 claims on separate lines, 1 URL on its own line -> URL_COUNT(1) < CLAIM_COUNT(3)
  # IMPORTANT: claims and URL must be on DIFFERENT lines. If URL is on same line as a
  # claim, grep -vP 'https?://' removes that claim line before counting.
  local msg json
  msg=$'Released in 2020.\nUpdated in 2022.\nStats show 99% adoption.\nSee https://example.com for details about this system.'
  json=$(make_stop_json "$msg")
  assert_blocks "20: 3 claims on separate lines, 1 URL -> block" "$json"
}

# ---------------------------------------------------------------------------
# P1 — Edge cases (unbalanced fence, inline backtick)
# ---------------------------------------------------------------------------

test_21_unbalanced_fence() {
  echo "Test 21: Unbalanced opening code fence -> allow"
  # Message starts with ``` but never closes
  # awk sets skip=1 on the fence line, never resets -> MSG_NO_CODE is empty -> exit 0
  local msg json
  msg=$'```bash\nsome code here with released in 2020 and 65% stats and more padding text'
  json=$(make_stop_json "$msg")
  assert_allows "21: unbalanced opening fence -> allow (MSG_NO_CODE empty)" "$json"
}

test_22_inline_backtick() {
  echo 'Test 22: Inline backtick with year -> block (awk only strips ``` fences)'
  # Inline backticks like `released in 2020` are NOT stripped by the awk fence stripper
  # (awk only processes triple-backtick fences). The year pattern is visible -> block.
  local msg json
  # Build the message using printf to avoid shell backtick interpretation
  msg=$(pad_to 80 'The library `released in 2020` was updated')
  json=$(make_stop_json "$msg")
  assert_blocks "22: inline backtick year not stripped -> block" "$json"
}

# ---------------------------------------------------------------------------
# P2 — Robustness
# ---------------------------------------------------------------------------

test_23_malformed_json_invalid() {
  echo "Test 23a: Completely invalid JSON -> allow, stdout empty, stderr has jq error"
  local output
  # Pipe invalid JSON directly (not via make_stop_json)
  > "$STDERR_FILE"
  output=$(echo '{broken json' | bash dhx/dhx-citation-check.sh 2>"$STDERR_FILE")
  assert_empty "23a: malformed JSON -> stdout empty" "$output"
  assert_stderr_nonempty "23a: malformed JSON -> stderr has jq error"
}

test_23b_wrong_type() {
  echo "Test 23b: Wrong type (last_assistant_message: 123) -> allow"
  # jq -r on integer 123 produces "123" (3 chars) which is < 80 -> length gate -> allow
  local json output
  json=$(jq -n '{cwd:"/tmp/test",hook_event_name:"Stop",last_assistant_message:123,permission_mode:"default",session_id:"test-session",stop_hook_active:false,transcript_path:"/tmp/test.jsonl"}')
  output=$(run_hook "$json")
  assert_empty "23b: integer message -> allow (jq -r produces '123', len=3 < 80)" "$output"
}

test_23c_embedded_quotes() {
  echo "Test 23c: Embedded quotes/backticks in message -> allow (jq --arg handles quoting)"
  # Message with single quotes and backticks that would break naive shell interpolation
  local msg json
  msg="He said 'it's fine' and \`echo hello\` is valid. No factual claims here at all."
  json=$(make_stop_json "$msg")
  assert_allows "23c: embedded quotes/backticks -> allow (no claims, jq --arg safe)" "$json"
}

test_24_very_long_response() {
  echo "Test 24: Very long response (10000 chars) with buried stat -> block"
  # Generate 10000-char string with stat buried mid-way
  local prefix suffix stat_claim msg json
  prefix=$(printf '%*s' 5000 '' | tr ' ' 'x')
  stat_claim=" Statistics show 42% adoption rate for this framework. "
  suffix=$(printf '%*s' $((10000 - 5000 - ${#stat_claim})) '' | tr ' ' 'y')
  msg="${prefix}${stat_claim}${suffix}"
  json=$(make_stop_json "$msg")
  assert_blocks "24: 10000-char response with buried stat -> block" "$json"
}

test_25_unicode_content() {
  echo "Test 25: Unicode content without English trigger word -> allow"
  # Note: if the message contains 'in 2020' (the English word "in"), the hook
  # will fire on \b(in)\s+2020\b even in otherwise-German text.
  # This test uses a message with NO English trigger word before the year.
  local msg json
  msg="Veröffentlicht 2020. 日本語テスト. Dies ist nur Fülltext für die Antwort zum Testen der Verarbeitung."
  json=$(make_stop_json "$msg")
  assert_allows "25: unicode without English trigger word -> allow" "$json"
}

# ---------------------------------------------------------------------------
# P2 — Known false positives (document behavior, don't fix)
# ---------------------------------------------------------------------------

test_26_common_knowledge_date() {
  echo "Test 26: Common knowledge date -> block (known false positive)"
  # The hook cannot distinguish common knowledge — documents baseline behavior
  local msg json
  msg="The internet was created in 1969 with ARPANET. This is widely documented in computer science textbooks and historical records."
  json=$(make_stop_json "$msg")
  assert_blocks "26: common knowledge date 'in 1969' -> block (known false positive)" "$json"
}

test_27_historical_fact_in_analysis() {
  echo "Test 27: Historical fact in analysis -> block (borderline false positive)"
  local msg json
  msg="The company was founded in 2015 and has since grown rapidly. Based on our analysis of their codebase, the architecture is solid."
  json=$(make_stop_json "$msg")
  assert_blocks "27: 'founded in 2015' -> block (documents baseline; may be verifiable)" "$json"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

echo "=== citation-check regression tests ==="
echo ""

echo "--- P0: Core gates ---"
test_01_loop_prevention
echo ""
test_02_empty_message
echo ""
test_03_missing_message
echo ""
test_04_length_boundary
echo ""

echo "--- P0: Detection patterns ---"
test_05_uncited_year
echo ""
test_06_uncited_statistic
echo ""
test_07_attribution_phrase
echo ""
test_08_named_study
echo ""
test_09_multiple_patterns
echo ""

echo "--- P1: Exclusion gates ---"
test_10_code_heavy
echo ""
test_11_cited_response
echo ""
test_12_version_numbers
echo ""
test_12b_http2_known_behavior
echo ""
test_13_short_response
echo ""
test_14_code_with_stats
echo ""

echo "--- P1: Line-oriented behavior ---"
test_15_year_split_across_newline
echo ""
test_16_claim_line_no_url_url_elsewhere
echo ""
test_17_claim_and_url_same_line
echo ""

echo "--- P1: Global URL-vs-claim count ---"
test_18_more_urls_than_claims
echo ""
test_19_equal_urls_and_claims
echo ""
test_20_fewer_urls_than_claims
echo ""

echo "--- P1: Edge cases ---"
test_21_unbalanced_fence
echo ""
test_22_inline_backtick
echo ""

echo "--- P2: Robustness ---"
test_23_malformed_json_invalid
echo ""
test_23b_wrong_type
echo ""
test_23c_embedded_quotes
echo ""
test_24_very_long_response
echo ""
test_25_unicode_content
echo ""

echo "--- P2: Known false positives ---"
test_26_common_knowledge_date
echo ""
test_27_historical_fact_in_analysis
echo ""

print_results
