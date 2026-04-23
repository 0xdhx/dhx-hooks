#!/usr/bin/env bash
# tests/lib.sh — Shared test helpers for the hooks test suite.
#
# Dual-purpose:
#   1. Sourced by automated test suites (tests/test-sed-extraction.sh etc.)
#      to share assertion helpers and extraction functions.
#   2. Interactive diagnostic tool — source this file in a shell session to
#      get extract_tag and header_fallback_filtered as standalone commands:
#
#      source tests/lib.sh
#      extract_tag /path/to/real-context.md deferred
#      header_fallback_filtered /path/to/real-context.md

# ---------------------------------------------------------------------------
# Counter state (reset by sourcing — each test file owns its own pass/fail)
# ---------------------------------------------------------------------------

PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Production extraction functions
# These mirror the patterns used in dhx/dhx-deferred-check.sh and
# dhx/dhx-context-gate.sh. Keep in sync with the production hooks.
# ---------------------------------------------------------------------------

# extract_tag <file> <tagname>
# Line-anchored sed extraction — matches only lines where the tag occupies
# the entire line (optionally with surrounding whitespace). Backticked
# cross-references and domain XML tags in prose are not matched.
extract_tag() {
  local file="$1" tag="$2"
  sed -n "/^[[:space:]]*<${tag}>[[:space:]]*$/,/^[[:space:]]*<\/${tag}>[[:space:]]*$/p" "$file" 2>/dev/null
}

# header_fallback_filtered <file>
# Extracts unresolved deferred items from a "## Deferred" markdown header
# section, then filters out items already marked resolved via lifecycle markers.
# Used as fallback when the <deferred> tag section is empty or missing.
header_fallback_filtered() {
  local file="$1"
  sed -n '/^##[^#].*[Dd]eferred/,/^##[^#]/p' "$file" 2>/dev/null \
    | grep -E '^\s*- ' \
    | grep -v '\[captured' \
    | grep -v '\[existing' \
    | grep -v '\[assessed' \
    | grep -v '\[tracked' \
    | grep -v '^\s*-\s*~~' \
    || true
}

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------

assert_contains() {
  local test_name="$1" actual="$2" expected="$3"
  if echo "$actual" | grep -qF "$expected"; then
    PASS=$((PASS + 1))
    echo "  PASS: $test_name"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $test_name"
    echo "        Expected to contain: $expected"
    echo "        Actual output:"
    echo "$actual" | head -5 | sed 's/^/          /'
  fi
}

assert_empty() {
  local test_name="$1" actual="$2"
  if [ -z "$actual" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $test_name"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $test_name"
    echo "        Expected empty, got:"
    echo "$actual" | head -5 | sed 's/^/          /'
  fi
}

assert_not_contains() {
  local test_name="$1" actual="$2" forbidden="$3"
  if echo "$actual" | grep -qF "$forbidden"; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $test_name"
    echo "        Expected NOT to contain: $forbidden"
    echo "        Actual output:"
    echo "$actual" | head -5 | sed 's/^/          /'
  else
    PASS=$((PASS + 1))
    echo "  PASS: $test_name"
  fi
}

assert_line_count() {
  local test_name="$1" actual="$2" expected_count="$3"
  local actual_count
  actual_count=$(echo "$actual" | grep -c . || true)
  if [ "$actual_count" -eq "$expected_count" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $test_name"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $test_name"
    echo "        Expected $expected_count non-empty lines, got $actual_count"
    echo "$actual" | head -5 | sed 's/^/          /'
  fi
}

# ---------------------------------------------------------------------------
# Results reporter
# ---------------------------------------------------------------------------

print_results() {
  echo "=== Results: $PASS passed, $FAIL failed ==="
  [ "$FAIL" -eq 0 ]
}
