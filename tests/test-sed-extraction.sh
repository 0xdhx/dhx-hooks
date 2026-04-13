#!/usr/bin/env bash
# test-sed-extraction.sh — Regression tests for line-anchored sed extraction
# Covers patterns from reports/2026-04-12-context-tag-corpus-analysis.md
# Run: bash tests/test-sed-extraction.sh
# Exit: 0 = all pass, 1 = any failure

set -euo pipefail

# shellcheck source=tests/lib.sh
source "$(dirname "$0")/lib.sh"

FIXTURES_DIR="$(cd "$(dirname "$0")/fixtures" && pwd)"

# ---------------------------------------------------------------------------
# Test 1 (P0): Extract each of 6 standard tags from well-formed file
# ---------------------------------------------------------------------------

test_01_wellformed_all_tags() {
  echo "Test 1: Extract all 6 standard tags from wellformed.md"
  local f="$FIXTURES_DIR/wellformed.md"

  local domain_out decisions_out specifics_out code_ctx_out canonical_out deferred_out
  domain_out=$(extract_tag "$f" "domain")
  decisions_out=$(extract_tag "$f" "decisions")
  specifics_out=$(extract_tag "$f" "specifics")
  code_ctx_out=$(extract_tag "$f" "code_context")
  canonical_out=$(extract_tag "$f" "canonical_refs")
  deferred_out=$(extract_tag "$f" "deferred")

  # Each section is non-empty
  assert_contains "1a: domain section non-empty" "$domain_out" "Baseball statistics"
  assert_contains "1b: decisions section non-empty" "$decisions_out" "PostgreSQL"
  assert_contains "1c: specifics section non-empty" "$specifics_out" "ERA"
  assert_contains "1d: code_context section non-empty" "$code_ctx_out" "src/api"
  assert_contains "1e: canonical_refs section non-empty" "$canonical_out" "api-spec.md"
  assert_contains "1f: deferred section non-empty" "$deferred_out" "WAR calculation"

  # No cross-contamination: decisions should not contain deferred content
  assert_not_contains "1g: decisions not contaminated by deferred" "$decisions_out" "WAR calculation"
  # deferred should not contain decisions content
  assert_not_contains "1h: deferred not contaminated by decisions" "$deferred_out" "PostgreSQL"
}

# ---------------------------------------------------------------------------
# Test 2 (P0): Extract missing tag returns empty, no error
# ---------------------------------------------------------------------------

test_02_missing_canonical() {
  echo "Test 2: Extract canonical_refs from missing-canonical.md"
  local f="$FIXTURES_DIR/missing-canonical.md"

  local out
  out=$(extract_tag "$f" "canonical_refs")

  assert_empty "2a: missing canonical_refs returns empty" "$out"
  # Other tags still work
  local deferred_out
  deferred_out=$(extract_tag "$f" "deferred")
  assert_contains "2b: deferred still extractable" "$deferred_out" "OCR pipeline"
}

# ---------------------------------------------------------------------------
# Test 3 (P0): Extract empty deferred section — tag lines returned, no bullets
# ---------------------------------------------------------------------------

test_03_empty_deferred() {
  echo "Test 3: Extract empty deferred section from empty-deferred.md"
  local f="$FIXTURES_DIR/empty-deferred.md"

  local out
  out=$(extract_tag "$f" "deferred")

  # Tag lines should be present (sed range matches)
  assert_contains "3a: tag open line present" "$out" "<deferred>"
  assert_contains "3b: tag close line present" "$out" "</deferred>"

  # No bullet items in the body
  local bullet_count
  bullet_count=$(echo "$out" | grep -cE '^\s*- ' || true)
  if [ "$bullet_count" -eq 0 ]; then
    PASS=$((PASS + 1))
    echo "  PASS: 3c: no bullet items in empty deferred"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: 3c: no bullet items in empty deferred (found $bullet_count bullets)"
  fi
}

# ---------------------------------------------------------------------------
# Test 4 (P0): Backtick collision — the critical regression test
# ---------------------------------------------------------------------------

test_04_backtick_collision() {
  echo "Test 4: Backtick collision — backticked tag in prose does not shift sed range"
  local f="$FIXTURES_DIR/backtick-collision.md"

  local out
  out=$(extract_tag "$f" "deferred")

  # The real deferred item should be present
  assert_contains "4a: real deferred item present" "$out" "Wire up cross-reference validation"

  # The decisions section content must NOT leak into the extraction.
  # "D-01" and "D-02" appear in the decisions section above the backticked `<deferred>`.
  # If the sed range started at the backtick line, decisions content would appear here.
  assert_not_contains "4b: D-01 from decisions not in deferred" "$out" "D-01"
  assert_not_contains "4c: decisions PostgreSQL not in deferred" "$out" "D-02: See"

  # Verify the extraction starts at the actual <deferred> tag line
  local first_content_line
  first_content_line=$(echo "$out" | head -1)
  if echo "$first_content_line" | grep -qE '^[[:space:]]*<deferred>[[:space:]]*$'; then
    PASS=$((PASS + 1))
    echo "  PASS: 4d: extraction starts at actual <deferred> tag line"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: 4d: extraction starts at actual <deferred> tag line"
    echo "        First line: $first_content_line"
  fi
}

# ---------------------------------------------------------------------------
# Test 5 (P1): English word "deferred" in prose does not cause false match
# ---------------------------------------------------------------------------

test_05_word_deferred() {
  echo "Test 5: English word 'deferred' in prose does not shift sed range"
  local f="$FIXTURES_DIR/word-deferred.md"

  local out
  out=$(extract_tag "$f" "deferred")

  # Real deferred item present
  assert_contains "5a: real deferred item present" "$out" "dead-letter queue"

  # Specifics prose with "deferred to v2" must not be in the extraction
  assert_not_contains "5b: specifics prose not in deferred" "$out" "deferred to v2"
  assert_not_contains "5c: specifics prose not in deferred" "$out" "deferred to late 2026"
}

# ---------------------------------------------------------------------------
# Test 6 (P1): Narrative cross-reference to "Deferred Ideas section" in prose
# ---------------------------------------------------------------------------

test_06_narrative_crossref() {
  echo "Test 6: Narrative cross-reference 'See the Deferred Ideas section' does not shift range"
  local f="$FIXTURES_DIR/narrative-crossref.md"

  local out
  out=$(extract_tag "$f" "deferred")

  # Real deferred item present
  assert_contains "6a: real deferred item present" "$out" "player-level efficiency breakdown"

  # Decisions prose cross-reference must not bleed into extraction
  assert_not_contains "6b: decisions prose not in deferred" "$out" "Deferred Ideas section"
}

# ---------------------------------------------------------------------------
# Test 7 (P1): Header-fallback — empty tag + ## Deferred Ideas header with bullets
# ---------------------------------------------------------------------------

test_07_header_fallback_empty_tag() {
  echo "Test 7: Header-fallback — empty <deferred> tag + ## Deferred Ideas header"
  local f="$FIXTURES_DIR/header-deferred.md"

  # Tag extraction should return no bullets
  local tag_out
  tag_out=$(extract_tag "$f" "deferred")
  local bullet_count
  bullet_count=$(echo "$tag_out" | grep -cE '^\s*- ' || true)
  if [ "$bullet_count" -eq 0 ]; then
    PASS=$((PASS + 1))
    echo "  PASS: 7a: tag extraction has no bullets (gap trigger condition)"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: 7a: tag extraction has no bullets (found $bullet_count)"
  fi

  # Header-fallback pattern (same as the patch in dhx-deferred-check.sh)
  local md_deferred
  md_deferred=$(sed -n '/^##.*[Dd]eferred/,/^##[^#]/p' "$f" 2>/dev/null \
    | grep -E '^\s*- ')

  assert_contains "7b: header-fallback finds 'Resume from partial state'" "$md_deferred" "Resume from partial state"
  assert_contains "7c: header-fallback finds 'Save partial output'" "$md_deferred" "Save partial output"
  assert_contains "7d: header-fallback finds 'Auto-cancel on timeout'" "$md_deferred" "Auto-cancel on timeout"

  local item_count
  item_count=$(echo "$md_deferred" | grep -cE '^\s*- ' || true)
  if [ "$item_count" -eq 3 ]; then
    PASS=$((PASS + 1))
    echo "  PASS: 7e: header-fallback finds exactly 3 items"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: 7e: header-fallback finds exactly 3 items (found $item_count)"
  fi
}

# ---------------------------------------------------------------------------
# Test 8 (P1): No <deferred> tag at all — tag empty, header-fallback finds items
# ---------------------------------------------------------------------------

test_08_no_deferred_tag() {
  echo "Test 8: No <deferred> tag — extraction empty, header-fallback finds items"
  local f="$FIXTURES_DIR/no-deferred-tag.md"

  local out
  out=$(extract_tag "$f" "deferred")

  assert_empty "8a: extraction returns empty when no tag present" "$out"

  # Header-fallback pattern
  local md_deferred
  md_deferred=$(sed -n '/^##.*[Dd]eferred/,/^##[^#]/p' "$f" 2>/dev/null \
    | grep -E '^\s*- ')

  assert_contains "8b: header-fallback finds WebSocket item" "$md_deferred" "WebSocket"
  assert_contains "8c: header-fallback finds team-level item" "$md_deferred" "team-level"

  local item_count
  item_count=$(echo "$md_deferred" | grep -cE '^\s*- ' || true)
  if [ "$item_count" -eq 2 ]; then
    PASS=$((PASS + 1))
    echo "  PASS: 8d: header-fallback finds exactly 2 items"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: 8d: header-fallback finds exactly 2 items (found $item_count)"
  fi
}

# ---------------------------------------------------------------------------
# Test 9 (P1): Custom tag extraction uses same line-anchored pattern
# ---------------------------------------------------------------------------

test_09_custom_tags() {
  echo "Test 9: Custom tag extraction — same pattern works for arbitrary [a-z_]+ tag names"
  local f="$FIXTURES_DIR/custom-tags.md"

  local research_out cbb_out
  research_out=$(extract_tag "$f" "research_directives")
  cbb_out=$(extract_tag "$f" "cbb_title_gaps")

  assert_contains "9a: research_directives non-empty" "$research_out" "100 citations"
  assert_contains "9b: research_directives contains ML/NLP" "$research_out" "ML/NLP"
  assert_contains "9c: cbb_title_gaps non-empty" "$cbb_out" "2019-2020 tournament"
  assert_contains "9d: cbb_title_gaps contains mid-major" "$cbb_out" "mid-major"

  # No cross-contamination
  assert_not_contains "9e: research_directives not contaminated by cbb" "$research_out" "tournament bracket"
  assert_not_contains "9f: cbb_title_gaps not contaminated by research" "$cbb_out" "100 citations"
}

# ---------------------------------------------------------------------------
# Test 10 (P2): Domain XML tags in prose do not cause false matches
# ---------------------------------------------------------------------------

test_10_domain_xml() {
  echo "Test 10: Domain XML tags in prose (<play>, <v>, <hitseason>) do not cause false matches"
  local f="$FIXTURES_DIR/domain-xml.md"

  local out
  out=$(extract_tag "$f" "deferred")

  assert_contains "10a: real deferred item present" "$out" "multi-season batch imports"
  assert_not_contains "10b: play tag not in deferred" "$out" "play"
  assert_not_contains "10c: hitseason not in deferred" "$out" "hitseason"
  assert_not_contains "10d: decisions prose not in deferred" "$out" "D-01"
}

# ---------------------------------------------------------------------------
# Test 11 (P2): Variable section ordering — extraction is order-independent
# ---------------------------------------------------------------------------

test_11_reordered_sections() {
  echo "Test 11: Variable section ordering — extraction is order-independent"
  local f="$FIXTURES_DIR/reordered-sections.md"

  local deferred_out code_ctx_out
  deferred_out=$(extract_tag "$f" "deferred")
  code_ctx_out=$(extract_tag "$f" "code_context")

  assert_contains "11a: deferred section extractable in non-standard order" "$deferred_out" "Wikidata"
  assert_contains "11b: code_context extractable before specifics" "$code_ctx_out" "src/knowledge"

  # Ensure no cross-contamination
  assert_not_contains "11c: deferred not contaminated by code_context" "$deferred_out" "src/knowledge"
  assert_not_contains "11d: code_context not contaminated by deferred" "$code_ctx_out" "Wikidata"
}

# ---------------------------------------------------------------------------
# Test 12 (P2): HTML meta tags inside fenced code block do not cause false matches
# ---------------------------------------------------------------------------

test_12_html_in_code() {
  echo "Test 12: HTML tags in fenced code block do not cause false matches"
  local f="$FIXTURES_DIR/html-in-code.md"

  local out
  out=$(extract_tag "$f" "deferred")

  assert_contains "12a: real deferred item present" "$out" "side-by-side diff view"
  assert_not_contains "12b: meta tag not in deferred" "$out" "meta"
  assert_not_contains "12c: viewport not in deferred" "$out" "viewport"
  assert_not_contains "12d: link tag not in deferred" "$out" "link rel"
}

# ---------------------------------------------------------------------------
# Test 13 (P3): HTML comment containing tag name — anchored sed skips comment
# ---------------------------------------------------------------------------

test_13_comment_tag() {
  echo "Test 13: HTML comment <!-- <deferred> --> does not start sed range"
  local f="$FIXTURES_DIR/comment-tag.md"

  local out
  out=$(extract_tag "$f" "deferred")

  assert_contains "13a: real deferred item present" "$out" "coach preference learning"
  assert_not_contains "13b: HTML comment line not in extraction" "$out" "<!--"

  # Verify extraction starts at the actual <deferred> tag, not the comment
  local first_line
  first_line=$(echo "$out" | head -1)
  if echo "$first_line" | grep -qE '^[[:space:]]*<deferred>[[:space:]]*$'; then
    PASS=$((PASS + 1))
    echo "  PASS: 13c: extraction starts at actual <deferred> tag line"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: 13c: extraction starts at actual <deferred> tag line"
    echo "        First line: $first_line"
  fi
}

# ---------------------------------------------------------------------------
# Test 14: All-resolved items inside <deferred> tag with ## Deferred Ideas header
#          Header-fallback with filters should find 0 unfiltered items
# ---------------------------------------------------------------------------

test_14_header_fallback_all_resolved() {
  echo "Test 14: Header-fallback with filters — all-resolved items produce 0 results"
  local f="$FIXTURES_DIR/header-deferred-resolved.md"

  local filtered
  filtered=$(header_fallback_filtered "$f")

  assert_empty "14a: all-resolved items produce empty after filter chain" "$filtered"
}

# ---------------------------------------------------------------------------
# Test 15: Mixed resolved/unresolved under header with empty tag
#          Header-fallback with filters should find exactly 2 unresolved items
# ---------------------------------------------------------------------------

test_15_header_fallback_mixed() {
  echo "Test 15: Header-fallback with filters — mixed items produce exactly 2 unresolved"
  local f="$FIXTURES_DIR/header-deferred-mixed.md"

  local filtered
  filtered=$(header_fallback_filtered "$f")

  assert_line_count "15a: mixed fixture has exactly 2 unresolved items after filters" "$filtered" 2
  assert_contains "15b: unresolved item B present" "$filtered" "Unresolved item B"
  assert_contains "15c: unresolved item D present" "$filtered" "Unresolved item D"
}

# ---------------------------------------------------------------------------
# Test 16: No <deferred> tag, all items resolved under ## Deferred header
#          Header-fallback with filters should find 0 items
# ---------------------------------------------------------------------------

test_16_no_tag_all_resolved() {
  echo "Test 16: Header-fallback with filters — no tag, all resolved items produce 0 results"
  local f="$FIXTURES_DIR/no-deferred-tag-resolved.md"

  local filtered
  filtered=$(header_fallback_filtered "$f")

  assert_empty "16a: no-tag all-resolved fixture produces empty after filter chain" "$filtered"
}

# ---------------------------------------------------------------------------
# Test 17: Regression — existing header-deferred.md (all unresolved) still produces 3 items
# ---------------------------------------------------------------------------

test_17_regression_header_deferred_unresolved() {
  echo "Test 17: Regression — header-deferred.md (all unresolved) still produces 3 items after filters"
  local f="$FIXTURES_DIR/header-deferred.md"

  local filtered
  filtered=$(header_fallback_filtered "$f")

  assert_line_count "17a: unresolved header-deferred.md still produces 3 items after filters" "$filtered" 3
}

# ---------------------------------------------------------------------------
# Test 18: Regression — existing no-deferred-tag.md (all unresolved) still produces 2 items
# ---------------------------------------------------------------------------

test_18_regression_no_deferred_tag_unresolved() {
  echo "Test 18: Regression — no-deferred-tag.md (all unresolved) still produces 2 items after filters"
  local f="$FIXTURES_DIR/no-deferred-tag.md"

  local filtered
  filtered=$(header_fallback_filtered "$f")

  assert_line_count "18a: unresolved no-deferred-tag.md still produces 2 items after filters" "$filtered" 2
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

echo "=== sed extraction regression tests ==="
echo ""

test_01_wellformed_all_tags
echo ""
test_02_missing_canonical
echo ""
test_03_empty_deferred
echo ""
test_04_backtick_collision
echo ""
test_05_word_deferred
echo ""
test_06_narrative_crossref
echo ""
test_07_header_fallback_empty_tag
echo ""
test_08_no_deferred_tag
echo ""
test_09_custom_tags
echo ""
test_10_domain_xml
echo ""
test_11_reordered_sections
echo ""
test_12_html_in_code
echo ""
test_13_comment_tag
echo ""
test_14_header_fallback_all_resolved
echo ""
test_15_header_fallback_mixed
echo ""
test_16_no_tag_all_resolved
echo ""
test_17_regression_header_deferred_unresolved
echo ""
test_18_regression_no_deferred_tag_unresolved
echo ""

print_results
