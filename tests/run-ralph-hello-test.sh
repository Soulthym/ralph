#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$SCRIPT_DIR/ralph-hello"
RALPH_SCRIPT="$SCRIPT_DIR/../ralph.sh"
LOG_FILE="$SCRIPT_DIR/ralph-hello-test.log"
MODEL="opencode/grok-code"
PROMPT="read README and say hello"
USE_MOBILE=false

cleanup() {
  rm -rf "$TEST_DIR"
  rm -f "$LOG_FILE"
}

# Cleanup on exit (unless --keep is passed)
KEEP=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep)
      KEEP=true
      shift
      ;;
    --mobile)
      USE_MOBILE=true
      shift
      ;;
    *)
      break
      ;;
  esac
done
if [[ "$USE_MOBILE" == "true" ]]; then
  RALPH_SCRIPT="$SCRIPT_DIR/../ralph-mobile.sh"
fi
if [[ "$KEEP" == "false" ]]; then
  trap cleanup EXIT
fi

# Setup test directory
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"

mkdir -p "$TEST_DIR/.agents/notes"
mkdir -p "$TEST_DIR/.agents/contexts"

cat > "$TEST_DIR/README.md" << 'EOF'
# ralph
EOF

cat > "$TEST_DIR/.agents/DESCRIPTION.md" << 'EOF'
Minimal test repo for ralph hello prompt.
EOF

cat > "$TEST_DIR/.agents/TASKS.md" << 'EOF'
# TASKS.md
# Task format:
# Task: <summary>
# Slug: <slug-for-notes-file>
# Notes:
# - .agents/notes/<slug>-notes.md
# (blank line between tasks)
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

if [[ "$USE_MOBILE" == "true" ]]; then
  echo "Running ralph mobile..."
else
  echo "Running ralph..."
fi
"$RALPH_SCRIPT" -m "$MODEL" 1 "$PROMPT" 2>&1 | tee "$LOG_FILE"

if [[ "$KEEP" == "true" ]]; then
  echo ""
  echo "Test directory kept at: $TEST_DIR"
  echo "Log file: $LOG_FILE"
fi
