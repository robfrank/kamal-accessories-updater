#!/bin/bash
#
# Test runner for Kamal Accessories Updater
# Runs all test suites and reports results
#

set -e

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Test suite tracking
SUITES_RUN=0
SUITES_PASSED=0
SUITES_FAILED=0

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Kamal Accessories Updater - Test Suite${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Run unit tests
echo -e "${YELLOW}► Running unit tests...${NC}"
SUITES_RUN=$((SUITES_RUN + 1))

if bash "$SCRIPT_DIR/test-utils.sh"; then
    echo ""
    SUITES_PASSED=$((SUITES_PASSED + 1))
else
    echo ""
    SUITES_FAILED=$((SUITES_FAILED + 1))
fi

# Run integration tests
echo -e "${YELLOW}► Running integration tests...${NC}"
SUITES_RUN=$((SUITES_RUN + 1))

if bash "$SCRIPT_DIR/test-integration.sh"; then
    echo ""
    SUITES_PASSED=$((SUITES_PASSED + 1))
else
    echo ""
    SUITES_FAILED=$((SUITES_FAILED + 1))
fi

# Print final summary
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Final Test Summary${NC}"
echo -e "${BLUE}========================================${NC}"
echo "Test Suites:"
echo "  Total:   $SUITES_RUN"
echo -e "  ${GREEN}Passed:  $SUITES_PASSED${NC}"

if [ $SUITES_FAILED -gt 0 ]; then
    echo -e "  ${RED}Failed:  $SUITES_FAILED${NC}"
    echo ""
    echo -e "${RED}❌ Some tests failed!${NC}"
    exit 1
else
    echo "  Failed:  $SUITES_FAILED"
    echo ""
    echo -e "${GREEN}✅ All test suites passed!${NC}"
    exit 0
fi
