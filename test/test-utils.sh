#!/bin/bash
#
# Unit tests for utility functions
#

set -e

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Source utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../src/utils.sh"

# Test helper functions
assert_equals() {
    local expected="$1"
    local actual="$2"
    local test_name="$3"

    TESTS_RUN=$((TESTS_RUN + 1))

    if [ "$expected" = "$actual" ]; then
        echo -e "${GREEN}✓${NC} $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $test_name"
        echo "  Expected: $expected"
        echo "  Actual:   $actual"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_true() {
    local test_name="$1"
    TESTS_RUN=$((TESTS_RUN + 1))

    echo -e "${GREEN}✓${NC} $test_name"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

assert_false() {
    local test_name="$1"
    TESTS_RUN=$((TESTS_RUN + 1))

    echo -e "${RED}✗${NC} $test_name"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

# Test: is_semantic_version
echo "Testing is_semantic_version..."

if is_semantic_version "1.0.0"; then
    assert_true "is_semantic_version recognizes 1.0.0"
else
    assert_false "is_semantic_version recognizes 1.0.0"
fi

if is_semantic_version "v2.5.3"; then
    assert_true "is_semantic_version recognizes v2.5.3"
else
    assert_false "is_semantic_version recognizes v2.5.3"
fi

if is_semantic_version "1.0"; then
    assert_true "is_semantic_version recognizes 1.0"
else
    assert_false "is_semantic_version recognizes 1.0"
fi

if is_semantic_version "2025.10.5"; then
    assert_true "is_semantic_version recognizes 2025.10.5"
else
    assert_false "is_semantic_version recognizes 2025.10.5"
fi

if ! is_semantic_version "latest"; then
    assert_true "is_semantic_version rejects 'latest'"
else
    assert_false "is_semantic_version rejects 'latest'"
fi

if ! is_semantic_version "main"; then
    assert_true "is_semantic_version rejects 'main'"
else
    assert_false "is_semantic_version rejects 'main'"
fi

if ! is_semantic_version "alpine"; then
    assert_true "is_semantic_version rejects 'alpine'"
else
    assert_false "is_semantic_version rejects 'alpine'"
fi

# Test: normalize_version
echo ""
echo "Testing normalize_version..."

result=$(normalize_version "v1.0.0")
assert_equals "1.0.0" "$result" "normalize_version removes 'v' prefix"

result=$(normalize_version "2.5.3")
assert_equals "2.5.3" "$result" "normalize_version leaves version without 'v' unchanged"

# Test: compare_versions
echo ""
echo "Testing compare_versions..."

result=$(compare_versions "1.0.0" "1.0.0")
assert_equals "0" "$result" "compare_versions: 1.0.0 = 1.0.0"

result=$(compare_versions "2.0.0" "1.0.0")
assert_equals "1" "$result" "compare_versions: 2.0.0 > 1.0.0"

result=$(compare_versions "1.0.0" "2.0.0")
assert_equals "-1" "$result" "compare_versions: 1.0.0 < 2.0.0"

result=$(compare_versions "1.2.0" "1.1.0")
assert_equals "1" "$result" "compare_versions: 1.2.0 > 1.1.0"

result=$(compare_versions "1.0.1" "1.0.0")
assert_equals "1" "$result" "compare_versions: 1.0.1 > 1.0.0"

result=$(compare_versions "v1.5.0" "v1.4.9")
assert_equals "1" "$result" "compare_versions: v1.5.0 > v1.4.9"

result=$(compare_versions "2.0" "1.9.9")
assert_equals "1" "$result" "compare_versions: 2.0 > 1.9.9"

result=$(compare_versions "10.0.0" "9.0.0")
assert_equals "1" "$result" "compare_versions: 10.0.0 > 9.0.0"

result=$(compare_versions "1.10.0" "1.9.0")
assert_equals "1" "$result" "compare_versions: 1.10.0 > 1.9.0"

# Print summary
echo ""
echo "========================================"
echo "Test Summary:"
echo "  Total:   $TESTS_RUN"
echo -e "  ${GREEN}Passed:  $TESTS_PASSED${NC}"
if [ $TESTS_FAILED -gt 0 ]; then
    echo -e "  ${RED}Failed:  $TESTS_FAILED${NC}"
    exit 1
else
    echo "  Failed:  $TESTS_FAILED"
    echo ""
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
fi
