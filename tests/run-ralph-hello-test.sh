#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$SCRIPT_DIR/ralph-hello"
RALPH_SCRIPT="$SCRIPT_DIR/../ralph.sh"
RALPH_MOBILE_SCRIPT="$SCRIPT_DIR/../ralph-mobile.sh"
LOG_FILE="$SCRIPT_DIR/ralph-hello-test.log"
MODEL="opencode/grok-code"
PROMPT="read README and say hello"

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
mkdir -p "$TEST_DIR"

cat > "$TEST_DIR/README.md" << 'EOF'
# ralph
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

# Run ralph.sh
echo "Running ralph..."
"$RALPH_SCRIPT" -m "$MODEL" 1 "$PROMPT" 2>&1 | tee "$LOG_FILE"

rm -rf "$TEST_DIR/.agents"

# Run ralph-mobile.sh
echo "Running ralph mobile..."
"$RALPH_MOBILE_SCRIPT" -m "$MODEL" 1 "$PROMPT" 2>&1 | tee -a "$LOG_FILE"

if [[ "$KEEP" == "true" ]]; then
  echo ""
  echo "Test directory kept at: $TEST_DIR"
  echo "Log file: $LOG_FILE"
fi
