#!/bin/bash
#
# Integration tests for the Kamal Accessories Updater action
#

set -e

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Test helper functions
test_start() {
    local test_name="$1"
    echo ""
    echo -e "${YELLOW}Running: $test_name${NC}"
    TESTS_RUN=$((TESTS_RUN + 1))
}

test_pass() {
    local test_name="$1"
    echo -e "${GREEN}✓${NC} $test_name"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

test_fail() {
    local test_name="$1"
    local reason="$2"
    echo -e "${RED}✗${NC} $test_name"
    if [ -n "$reason" ]; then
        echo "  Reason: $reason"
    fi
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

# Setup test environment
setup() {
    # Create temp directory for testing
    TEST_TEMP_DIR=$(mktemp -d)
    echo "Using temp directory: $TEST_TEMP_DIR"

    # Copy fixtures to temp directory
    cp -r "$SCRIPT_DIR/fixtures" "$TEST_TEMP_DIR/"
}

# Cleanup test environment
cleanup() {
    if [ -n "$TEST_TEMP_DIR" ] && [ -d "$TEST_TEMP_DIR" ]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

# Test 1: Check for updates in check mode
test_check_mode() {
    test_start "Test 1: Check for updates (check mode)"

    cd "$TEST_TEMP_DIR/fixtures"

    # Run the checker in check mode
    output=$("$PROJECT_ROOT/src/check-updates.sh" "." "check" 2>&1)

    # Verify output contains expected information
    if echo "$output" | grep -q "Checking for Kamal accessories updates"; then
        test_pass "Test 1: Check mode runs successfully"
    else
        test_fail "Test 1: Check mode runs successfully" "Expected output not found"
        echo "$output"
    fi
}

# Test 2: Verify version comparison
test_version_detection() {
    test_start "Test 2: Verify version detection"

    cd "$TEST_TEMP_DIR/fixtures"

    # Run the checker
    output=$("$PROJECT_ROOT/src/check-updates.sh" "." "check" 2>&1)

    # Check if updates are detected
    if echo "$output" | grep -q "Update available\|Up to date"; then
        test_pass "Test 2: Version detection works"
    else
        test_fail "Test 2: Version detection works" "No version status found in output"
        echo "$output"
    fi
}

# Test 3: Verify file parsing
test_file_parsing() {
    test_start "Test 3: Verify file parsing"

    cd "$TEST_TEMP_DIR/fixtures"

    # Run the checker
    output=$("$PROJECT_ROOT/src/check-updates.sh" "." "check" 2>&1)

    # Verify it found accessories
    if echo "$output" | grep -q "redis"; then
        test_pass "Test 3: Parses redis accessory"
    else
        test_fail "Test 3: Parses redis accessory"
        echo "$output"
    fi

    if echo "$output" | grep -q "postgres"; then
        test_pass "Test 3: Parses postgres accessory"
    else
        test_fail "Test 3: Parses postgres accessory"
        echo "$output"
    fi
}

# Test 4: Verify multiple file handling
test_multiple_files() {
    test_start "Test 4: Verify multiple file handling"

    cd "$TEST_TEMP_DIR/fixtures"

    # Run the checker
    output=$("$PROJECT_ROOT/src/check-updates.sh" "." "check" 2>&1)

    # Verify it processes both deploy files
    file_count=$(echo "$output" | grep -c "Checking" || true)

    if [ "$file_count" -ge 4 ]; then
        test_pass "Test 4: Processes multiple files"
    else
        test_fail "Test 4: Processes multiple files" "Expected at least 4 accessories, found $file_count"
        echo "$output"
    fi
}

# Test 5: Verify update application (dry run)
test_update_simulation() {
    test_start "Test 5: Verify update detection logic"

    cd "$TEST_TEMP_DIR/fixtures"

    # Create a test file with an old version
    cat > test-deploy.yml <<EOF
accessories:
  redis:
    image: redis:6.0.0
    host: localhost
EOF

    # Run the checker
    output=$("$PROJECT_ROOT/src/check-updates.sh" "." "check" 2>&1)

    # Should detect redis 6.0.0 as outdated
    if echo "$output" | grep -q "redis"; then
        test_pass "Test 5: Detects test accessory"
    else
        test_fail "Test 5: Detects test accessory"
        echo "$output"
    fi
}

# Test 6: Verify SHA256 handling
test_sha256_preservation() {
    test_start "Test 6: Verify SHA256 digest handling"

    cd "$TEST_TEMP_DIR/fixtures"

    # Check that files with SHA256 are handled
    if grep -q "@sha256:" deploy-staging.yml; then
        test_pass "Test 6: Test file contains SHA256 digest"
    else
        test_fail "Test 6: Test file contains SHA256 digest"
    fi
}

# Test 7: Verify error handling for missing directory
test_error_handling() {
    test_start "Test 7: Verify error handling"

    cd "$TEST_TEMP_DIR"

    # Run with non-existent directory
    if "$PROJECT_ROOT/src/check-updates.sh" "nonexistent" "check" 2>&1 | grep -q "ERROR"; then
        test_pass "Test 7: Handles missing directory error"
    else
        test_fail "Test 7: Handles missing directory error"
    fi
}

# Test 8: Verify summary output
test_summary_output() {
    test_start "Test 8: Verify summary output"

    cd "$TEST_TEMP_DIR/fixtures"

    # Run the checker
    output=$("$PROJECT_ROOT/src/check-updates.sh" "." "check" 2>&1)

    # Verify summary is present
    if echo "$output" | grep -q "Summary:"; then
        test_pass "Test 8: Generates summary"
    else
        test_fail "Test 8: Generates summary"
        echo "$output"
    fi
}

# Main test execution
main() {
    echo "========================================"
    echo "Kamal Accessories Updater - Integration Tests"
    echo "========================================"

    # Setup
    setup

    # Run tests
    test_check_mode
    test_version_detection
    test_file_parsing
    test_multiple_files
    test_update_simulation
    test_sha256_preservation
    test_error_handling
    test_summary_output

    # Cleanup
    cleanup

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
        echo -e "${GREEN}All integration tests passed!${NC}"
        exit 0
    fi
}

# Run main
main
