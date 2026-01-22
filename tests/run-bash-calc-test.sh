#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$SCRIPT_DIR/bash-calc"
RALPH_SCRIPT="$SCRIPT_DIR/../ralph-mobile.sh"
LOG_FILE="$SCRIPT_DIR/bash-calc-test.log"

cleanup() {
  rm -rf "$TEST_DIR"
  rm -f "$LOG_FILE"
}

# Cleanup on exit (unless --keep is passed)
KEEP=false
if [[ "${1:-}" == "--keep" ]]; then
  KEEP=true
fi
if [[ "$KEEP" == "false" ]]; then
  trap cleanup EXIT
fi

# Setup test directory
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR/.agents/notes"
mkdir -p "$TEST_DIR/.agents/contexts"

# Create DESCRIPTION.md
cat > "$TEST_DIR/.agents/DESCRIPTION.md" << 'EOF'
A simple CLI calculator written in Bash.
EOF

# Create PLAN.md
cat > "$TEST_DIR/.agents/PLAN.md" << 'EOF'
# Bash Calculator Plan

Build a simple CLI calculator in Bash that:
- Accepts two numbers and an operator as arguments
- Supports +, -, *, /, % (modulo) operations
- Handles division by zero gracefully
- Handles modulo by zero gracefully
- Returns proper exit codes (0 for success, non-zero for errors)
- Includes a test script to verify functionality

Usage: `./calc.sh <num1> <operator> <num2>`
Example: `./calc.sh 5 + 3` → outputs `8`
EOF

# Create TASKS.md
cat > "$TEST_DIR/.agents/TASKS.md" << 'EOF'
# TASKS.md

Task: Create the calculator script
Status: TODO
Slug: calc-script
Notes:
- .agents/notes/calc-script-notes.md

Task: Create test script for calculator
Status: TODO
Slug: calc-tests
Notes:
- .agents/notes/calc-tests-notes.md
EOF

# Initialize isolated git repo
cd "$TEST_DIR"
export GIT_DIR="$TEST_DIR/.git"
export GIT_WORK_TREE="$TEST_DIR"
git init
git config user.email "test@test.com"
git config user.name "Test"
git add -A
git commit --no-gpg-sign -m "chore: initial commit"
git checkout -b dev
git checkout -b dev-auto

# Run ralph (output to both terminal and log file)
echo "Running ralph mobile..."
"$RALPH_SCRIPT" -m "opencode/gpt-5.2-codex" 5 2>&1 | tee "$LOG_FILE"

# Verify results
echo ""
echo "=== Verification ==="

PASS_COUNT=0
FAIL_COUNT=0

check_result() {
  local desc="$1"
  local expected="$2"
  local actual="$3"
  
  # Normalize: remove trailing zeros after decimal point and trailing dot
  local norm_expected=$(echo "$expected" | sed 's/\.0*$//' | sed 's/\.\([0-9]*[1-9]\)0*$/.\1/')
  local norm_actual=$(echo "$actual" | sed 's/\.0*$//' | sed 's/\.\([0-9]*[1-9]\)0*$/.\1/')
  
  if [[ "$norm_actual" == "$norm_expected" ]]; then
    echo "PASS: $desc (expected '$expected', got '$actual')"
    ((PASS_COUNT++)) || true
  else
    echo "FAIL: $desc (expected '$expected', got '$actual')"
    ((FAIL_COUNT++)) || true
  fi
}

check_error() {
  local desc="$1"
  local exit_code="$2"
  
  if [[ "$exit_code" -ne 0 ]]; then
    echo "PASS: $desc (non-zero exit code: $exit_code)"
    ((PASS_COUNT++)) || true
  else
    echo "FAIL: $desc (expected non-zero exit code, got 0)"
    ((FAIL_COUNT++)) || true
  fi
}

if [[ -f "$TEST_DIR/calc.sh" ]]; then
  echo "PASS: calc.sh created"
  ((PASS_COUNT++)) || true
  chmod +x "$TEST_DIR/calc.sh"
  
  # Test addition
  result=$("$TEST_DIR/calc.sh" 2 + 3 2>/dev/null || echo "ERROR")
  check_result "2 + 3 = 5" "5" "$result"
  
  # Test subtraction
  result=$("$TEST_DIR/calc.sh" 10 - 4 2>/dev/null || echo "ERROR")
  check_result "10 - 4 = 6" "6" "$result"
  
  # Test multiplication
  result=$("$TEST_DIR/calc.sh" 6 '*' 7 2>/dev/null || echo "ERROR")
  check_result "6 * 7 = 42" "42" "$result"
  
  # Test division
  result=$("$TEST_DIR/calc.sh" 20 / 4 2>/dev/null || echo "ERROR")
  check_result "20 / 4 = 5" "5" "$result"
  
  # Test modulo (optional - may not be implemented)
  result=$("$TEST_DIR/calc.sh" 17 % 5 2>/dev/null || echo "ERROR")
  if [[ "$result" == "ERROR" ]] || [[ "$result" == *"Invalid"* ]]; then
    echo "SKIP: Modulo not implemented"
  else
    check_result "17 % 5 = 2" "2" "$result"
  fi
  
  # Test division by zero (should fail with non-zero exit)
  "$TEST_DIR/calc.sh" 5 / 0 >/dev/null 2>&1 || div_zero_exit=$?
  check_error "Division by zero returns error" "${div_zero_exit:-0}"
  
  # Test modulo by zero (optional - only if modulo is implemented)
  if [[ "$result" != "ERROR" ]] && [[ "$result" != *"Invalid"* ]]; then
    "$TEST_DIR/calc.sh" 5 % 0 >/dev/null 2>&1 || mod_zero_exit=$?
    check_error "Modulo by zero returns error" "${mod_zero_exit:-0}"
  fi
  
else
  echo "FAIL: calc.sh not created"
  ((FAIL_COUNT++)) || true
fi

echo ""
echo "=== Summary ==="
echo "PASSED: $PASS_COUNT"
echo "FAILED: $FAIL_COUNT"

if [[ "$KEEP" == "true" ]]; then
  echo ""
  echo "Test directory kept at: $TEST_DIR"
  echo "Log file: $LOG_FILE"
fi

# Exit with failure if any tests failed
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
