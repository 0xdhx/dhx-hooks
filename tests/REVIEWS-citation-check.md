---
reviewers: [gemini, codex]
reviewed_at: 2026-04-13T11:55:00Z
plan_reviewed: tests/PLAN-test-citation-check.md
---

# Cross-AI Review — Citation Check Test Plan

## Gemini Review

### Summary
The test plan provides excellent coverage across core logic gates, regex pattern matching, and exclusion rules. It correctly identifies the hook's "fail-open" nature and categorizes tests into logical priority tiers. The inclusion of "Known False Positives" (P2) demonstrates a mature understanding of the hook's limitations, ensuring that the test suite acts as a baseline for future tuning rather than a barrier to deployment.

### Strengths
- **Synthetic Payload Accuracy:** Using `make_stop_json` ensures tests interact with the hook exactly as the host application does.
- **Code-Stripping Validation:** Tiers P0 and P1 explicitly test the hook's ability to ignore data inside code fences, which is the most likely source of false positives in technical conversations.
- **Heuristic Boundary Testing:** Cases 16-18 correctly exercise the logic where the number of URLs is weighed against the number of claims, which is the most complex part of the decision logic.
- **Fail-Open Verification:** Case 23 (Malformed JSON) and Case 5 (Missing `jq`) ensure the hook does not accidentally block the user if the environment or input is unexpected.

### Concerns
- **Global vs. Contextual Citation (LOW):** The hook counts total URLs in the message to decide whether to block. A test case where "Claim A" is cited but "Claim B" (different line) is not might be "allowed" if `URL_COUNT >= CLAIM_COUNT`. While acceptable for a heuristic, the tests should explicitly document this behavior.
- **Line-Ending Sensitivity (MEDIUM):** `wc -l` and `grep -c .` can behave differently depending on whether the last line of a message has a trailing newline. If the synthetic JSON generator doesn't append a newline to `last_assistant_message`, counts might be off by one.
- **Regex Portability (MEDIUM):** The hook uses `grep -P` (Perl-compatible regex). While standard on Linux (GNU grep), it fails on macOS (BSD grep). Since the environment is specified as Linux, this is a minor risk, but the test suite should ideally check for `grep -P` availability or use a wrapper.
- **Greedy Multi-line Code Fences (LOW):** The `awk` script for stripping code blocks assumes standard ``` markers. It might struggle with nested fences or non-standard formatting.

### Suggestions
- Add "Insufficient Citations" case: 3 distinct claims (1 year, 1 stat, 1 attribution) and only 1 URL.
- Boundary test for length gate: 79 chars vs 81 chars.
- Verify `reason` string contains line numbers and claim snippets.
- Add escaped character test (single quotes, backticks in claim text).

### Risk Assessment: LOW
The hook is advisory and fail-open. The test plan covers all critical failure modes.

---

## Codex (GPT-5.4) Review

### Summary
The plan is directionally solid: it covers the main allow/block branches, exercises each detection family, and includes a few realistic false-positive and robustness scenarios. The biggest weakness is that several tests are specified at the behavior level while the hook actually makes line-oriented, Bash-specific decisions, so the suite may miss regressions in newline handling, code-fence stripping, `jq` failure behavior, and the mismatch between the comment about "nearby URL" and the implementation, which only counts URLs globally and excludes lines containing a URL before claim aggregation.

### Strengths
- Covers the primary gates first: loop prevention, empty/missing message, short responses, and missing `jq`.
- Tests each of the four detection buckets separately, important because they are implemented independently.
- Includes mixed-pattern coverage, which helps verify claim aggregation and summary formatting.
- Calls out known false positives explicitly instead of pretending the heuristic is precise.
- Distinguishes `allow` from `block` using the actual contract the hook exposes: exit `0` plus optional JSON stdout.

### Concerns
- **HIGH:** "Adjacent URL" is underspecified relative to the implementation. The code does not implement a true 2-line proximity window; it filters out claim lines containing a URL, then later compares total URL count against total claim count globally. A test called "year claim with adjacent URL" may pass or fail depending on line layout.
- **HIGH:** No test verifies multiline behavior. Detection uses `grep -nP` line by line, so line breaks materially affect outcomes. This is one of the main decision boundaries.
- **HIGH:** Malformed JSON: `jq -r '.last_assistant_message // empty'` on malformed JSON may emit errors to stderr and return nonzero. The suite should verify fail-open includes stdout empty and no garbage in `MSG`.
- **MEDIUM:** Code-heavy gate only loosely tested. The implementation skips when fences >= 2 AND total lines < 20 — does not actually measure "60% code."
- **MEDIUM:** No boundary test at 79 vs 80 characters for the length gate.
- **MEDIUM:** No test exercises unbalanced code fences. `awk` toggle will drop everything after unmatched opening fence — realistic assistant output failure.
- **MEDIUM:** Version-number exclusion test doesn't exercise the actual exclusion branch (year regex requires trigger words).
- **MEDIUM:** Named-study detection too narrowly tested. `the\s+\w+\s+(report|study|...)` won't match multi-word names ("The State of AI report").

### Suggestions
- Add boundary tests: 79 chars → allow, 80 chars with claim → block.
- Add multiline citation-window tests (URL on same line, next line, two lines later, unrelated elsewhere).
- Add code-fence boundary tests (< 20 lines, >= 20 lines, unbalanced fence).
- Test inline code backticks (only fenced code is stripped).
- Strengthen version exclusion: "The tool was released in 2024 as v2.1.91", "HTTP/2 was released in 2015".
- Test bullets/headings: `# Released in 2020`, `- Exit code 65%`.
- Malformed input variants: completely invalid JSON, wrong type (`last_assistant_message: 123`), embedded newlines/quotes.
- Make `assert_blocks` parse stdout with `jq` not grep — avoids brittle whitespace issues.
- Make `make_stop_json` use `jq -n --arg msg "$msg"` — shell interpolation is unsafe with quotes/newlines.
- Capture and assert stderr behavior explicitly.
- Test `head -5` truncation doesn't break JSON formatting.

### Risk Assessment: MEDIUM
Good enough to catch obvious breakage, not enough to validate shell-specific decision boundaries. Highest risk is false confidence from tests named around intended semantics that the script doesn't truly implement.

---

## Consensus Summary

### Agreed Strengths
- Correct testing methodology (synthetic JSON via stdin, exit code + stdout assertions)
- Good priority tiering (P0 gates before P1 edge cases before P2 robustness)
- Known false positives explicitly documented rather than ignored
- Fail-open verification included

### Agreed Concerns
1. **No boundary tests for the 80-char length gate** (both reviewers, MEDIUM)
2. **URL-vs-claim comparison is global, not per-line proximity** — tests named "adjacent URL" don't match what the code does (Codex HIGH, Gemini LOW)
3. **No multiline/line-break sensitivity tests** — the hook is fundamentally line-oriented but tests don't exercise this (Codex HIGH)
4. **Code-fence stripping edge cases missing** — unbalanced fences, nested fences (both reviewers, MEDIUM)
5. **Malformed JSON fail-open needs tighter verification** — stderr behavior, garbage assignment (Codex HIGH, Gemini implicit)

### Divergent Views
- **Risk assessment:** Gemini says LOW (advisory hook, fail-open), Codex says MEDIUM (false confidence from semantic-named tests that don't match implementation). Codex's concern is more actionable — the tests should prove what the code does, not what it intends.
- **Scope:** Gemini focuses on the test plan as written, Codex digs into implementation-vs-test alignment gaps. Codex's approach is more thorough for a shell hook where bash semantics matter.
