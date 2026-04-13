# Test Plan: dhx-citation-check.sh

**Target:** `dhx/dhx-citation-check.sh`
**Pattern:** Mirrors `tests/test-sed-extraction.sh` — uses `tests/lib.sh` assertions, fixture-driven, priority-tiered.
**Run:** `bash tests/test-citation-check.sh`
**Estimated size:** ~400 lines (30+ tests, helper functions, results reporter)

---

## Approach

Pipe synthetic Stop hook JSON payloads through the hook via stdin. Assert on:
- Exit code (0 = allow, 0 + JSON stdout = block)
- stdout content (empty = allow, `{"decision": "block", ...}` = block)
- Block reason text (when blocking)

Stderr is captured separately (review item 10) to verify that malformed input
emits jq errors to stderr but does NOT produce blocking stdout.

### Test helper

```bash
STDERR_FILE=$(mktemp)
trap 'rm -f "$STDERR_FILE"' EXIT

# run_hook <json_payload> — captures exit code and stdout, stderr goes to $STDERR_FILE
run_hook() {
  local output exit_code
  output=$(echo "$1" | bash dhx/dhx-citation-check.sh 2>"$STDERR_FILE")
  exit_code=$?
  echo "$output"
  return $exit_code
}

# assert_allows <test_name> <json_payload>
assert_allows() {
  local output
  output=$(run_hook "$2")
  assert_empty "$1" "$output"
}

# assert_blocks <test_name> <json_payload> [expected_reason_fragment]
# Uses jq to parse stdout (review item 6) — robust against whitespace.
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
# Checks that $STDERR_FILE is empty (no jq errors or other noise).
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

# pad_to <length> <base_text> — pads base_text with trailing spaces to exact length
pad_to() {
  local len=$1 base="$2"
  printf "%-${len}s" "$base"
}
```

### Fixture builder

```bash
# make_stop_json <message> [stop_hook_active]
# Uses jq -n --arg for safe quoting (review item 7) — no shell interpolation hazards.
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
```

Note: `make_stop_json` already specifies `jq -n --arg msg "$1"` — this is the safe quoting
path that handles single quotes, newlines, and special characters correctly.

---

## Test Cases

### P0 — Core gates (must pass or hook is broken)

| # | Name | Input | Expected | Tests |
|---|------|-------|----------|-------|
| 1 | Loop prevention | `stop_hook_active: true`, message with uncited year | Allow (exit 0, no stdout) | HP-002 |
| 2 | Empty message | `last_assistant_message: ""` | Allow | Null guard |
| 3 | Missing message | No `last_assistant_message` key | Allow | jq `// empty` fallback |
| 4a | 79-char boundary | 79-char message containing "in 1991" | Allow (under length gate) | Boundary: `< 80` |
| 4b | 80-char boundary | 80-char message containing "in 1991" | Block (at gate boundary, gate is `< 80`) | Boundary: at limit |
| 4c | 81-char boundary | 81-char message containing "in 1991" | Block (over gate) | Boundary: over limit |
| 5 | No jq available | (skip if jq present — document as manual test) | Allow (exit 0) | Fail-open |

Note on 79/80/81 boundary (review items 1 — Gemini MEDIUM, Codex MEDIUM): The gate
condition is `if [ "${#MSG}" -lt 80 ]; then exit 0; fi`. So exactly 80 chars passes the
gate and can be blocked. Build each test string so `${#msg}` is exactly the target length.

### P0 — Detection patterns (must fire on obvious cases)

| # | Name | Input message | Expected | Tests |
|---|------|--------------|----------|-------|
| 6 | Uncited year | "Python was released in 1991 by Guido van Rossum. It has grown to become one of the most popular programming languages in the world." | Block, reason mentions "1991" | Pattern 1 |
| 7 | Uncited statistic | "JavaScript is used by approximately 65% of all developers worldwide, making it the most popular language by a significant margin." | Block, reason mentions "65%" | Pattern 2 |
| 8 | Attribution phrase | "According to recent research, microservices architectures reduce deployment frequency by an average of 200 times compared to monolithic systems." | Block, reason mentions "according to" or "200" | Pattern 3 |
| 9 | Named study | "The DORA report found that elite performers deploy 973 times more frequently than low performers across the entire industry." | Block, reason mentions "report" or "973" | Pattern 4 |
| 10 | Multiple patterns | "Founded in 2004, Facebook reached 1 billion users. According to the company's annual report, revenue exceeded $86 billion." | Block, claim count >= 2 | Combined |

### P1 — Exclusion gates (must NOT fire on these)

| # | Name | Input message | Expected | Tests |
|---|------|--------------|----------|-------|
| 11 | Code-heavy response | 2 fences, <20 lines, year claim inside code | Allow | Code fence gate + strip |
| 12 | Cited response | "Python was released in 1991 (https://python.org/history). It supports multiple paradigms." (padded >80) | Allow | URL-count gate |
| 13 | Version numbers (strengthened) | "The tool was released in 2024 as v2.1.91 and has been stable since deployment." | Allow | Pattern 1 exclusion via `v\d+\.` on same line |
| 13b | HTTP/2 known behavior | "HTTP/2 was released in 2015 and improved multiplexing significantly for the web." (padded >80) | Block (known: "HTTP/2" is not `v\d+\.`) | Documents baseline behavior |
| 14 | Meta-conversation | "I'll look into that for you." (< 80 chars) | Allow | Length gate |
| 15 | Code with stats | "The function returns exit code 42% through the error handler.\n\`\`\`bash\nexit 42\n\`\`\`" | Allow | Code strip before analysis |

### P1 — Line-oriented behavior (review item 2 — Codex HIGH)

The hook uses `grep -nP` line by line. Line breaks materially affect outcomes. These tests
document the hook's actual line-oriented semantics.

| # | Name | Input message | Expected | Tests |
|---|------|--------------|----------|-------|
| 16a | Year split across newline | "released in\n2020 by Guido" padded >80 | Allow (neither line matches `(in\|since\|...) 2020`) | grep -nP requires trigger word and year on same line |
| 16b | Claim line without URL, URL on different line | Claim on line 1 (no URL), URL on line 2, URL_COUNT < CLAIM_COUNT | Block (global URL count check fails) | Documents global-not-proximity semantics |
| 16c | Claim and URL on same line | "Python was released in 1991 (https://python.org/history)." on one line, padded >80, no other claims | Allow (grep -vP 'https?://' filters the claim line) | Same-line URL removes the claim |

### P1 — Global URL-vs-claim count semantics (review items 2, 3 — Codex HIGH, Gemini LOW)

Tests 17-19 document that the hook compares total URL count globally against total claim
count. The variable names in tests 16-18 from the original plan reflected "adjacent URL"
language that didn't match the implementation. These are renamed to reflect global counting.

| # | Name | Input message | Expected | Tests |
|---|------|--------------|----------|-------|
| 17 | More URLs than claims | 1 year claim, 3 URLs in message | Allow (URL_COUNT >= CLAIM_COUNT) | Global URL >= claims |
| 18 | Equal URLs and claims | 1 year claim, 1 URL in message | Allow (URL_COUNT == CLAIM_COUNT) | Boundary: equal counts |
| 19 | Fewer URLs than claims | 3 year/stat claims, 1 URL in message | Block (URL_COUNT < CLAIM_COUNT) | Boundary: fewer URLs |

### P1 — Edge cases

| # | Name | Input message | Expected | Tests |
|---|------|--------------|----------|-------|
| 20 | Unbalanced opening fence | Message starts with ``` but never closes (padded >80) | Allow (awk sets skip=1, never resets, MSG_NO_CODE is empty -> exit 0) | review item 4 — Codex MEDIUM |
| 21 | Inline backtick with year | "The library `released in 2020` was updated..." padded >80 | Block (awk only strips ``` fences, not inline `; year visible in MSG_NO_CODE) | review item 8 — Codex MEDIUM |

### P2 — Robustness

| # | Name | Input message | Expected | Tests |
|---|------|--------------|----------|-------|
| 22 | Malformed JSON — invalid | `{broken json` on stdin | Allow (exit 0, stdout empty, stderr has jq error) | review item 5a — Codex HIGH |
| 23 | Malformed JSON — wrong type | `jq -n '{last_assistant_message: 123}'` | Allow (jq -r produces "123", length 3 < 80) | review item 5b — Codex HIGH |
| 24 | Malformed JSON — embedded quotes | Message value with single quotes and backticks | Allow (jq --arg handles quoting) | review item 5c |
| 25 | Very long response | 10000-char response with one uncited stat buried mid-text | Block | grep handles large input |
| 26 | Unicode content | "Veröffentlicht in 2020. 日本語テスト." | Allow (patterns are English) | No crash on non-ASCII |

### P2 — Known false positives (document, don't block)

These are cases where the hook fires but arguably shouldn't. Documenting them establishes
the baseline false-positive rate for future tuning.

| # | Name | Input message | Expected (current) | Ideal | Notes |
|---|------|--------------|-------------------|-------|-------|
| 27 | Common knowledge date | "The internet was created in 1969 with ARPANET. This is widely documented in computer science textbooks and historical records." | Block (fires on "in 1969") | Allow | Cannot distinguish common knowledge — semantic gap |
| 28 | Historical fact in analysis | "The company was founded in 2015 and has since grown rapidly. Based on our analysis of their codebase, the architecture is solid." | Block (fires on "founded in 2015") | Depends on context | Borderline — could be verifiable |

---

## Helper specification notes

### assert_blocks uses jq parsing (review item 6 — Codex suggestion)

`assert_blocks` must use `jq -e '.decision' <<< "$output"` (or equivalent) instead of
`grep '"decision": "block"'` for JSON field checks. This is more robust against whitespace
variations in jq output formatting.

### stderr capture (review item 10 — Codex suggestion)

`run_hook` must redirect stderr to `$STDERR_FILE` (`2>"$STDERR_FILE"`). Tests involving
malformed JSON must assert that stdout is empty AND check `$STDERR_FILE` to verify jq
errors appear there (not in stdout). Normal allow/block tests should use `assert_stderr_empty`
to confirm stderr is clean on happy-path inputs.

---

## Implementation notes

- **File:** `tests/test-citation-check.sh`
- **Source:** `tests/lib.sh` for assertions
- **No fixtures directory needed** — payloads are built inline via `make_stop_json`
- **Pre-commit:** Add to the same gate as `test-sed-extraction.sh` once stable
- **Estimated size:** ~400 lines (30+ tests, helper functions, results reporter)
