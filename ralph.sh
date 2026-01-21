#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(pwd)"
MAX_ITERATIONS=10

RALPH_FILE="$ROOT_DIR/.agents/RALPH.md"
DESCRIPTION_FILE="$ROOT_DIR/.agents/DESCRIPTION.md"
TASKS_FILE="$ROOT_DIR/.agents/TASKS.md"

mkdir -p "$ROOT_DIR/.agents/notes"

if [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]]; then
  MAX_ITERATIONS="$1"
  shift
fi

USER_PROMPT=""
if [[ $# -gt 0 ]]; then
  USER_PROMPT="$*"
elif [[ ! -t 0 ]]; then
  USER_PROMPT="$(cat)"
fi

if [[ ! -f "$RALPH_FILE" ]]; then
  cat > "$RALPH_FILE" << 'EOF'
# RALPH.md

Rules
- Read the .agents/TASKS.md file, pick an unfinished task if any, otherwise pick the most important task and start working on it.
- Each task must have a Slug. Choose a short, unique slug and write it into its corresponding TASKS.md if missing.
- Notes live at .agents/notes/<slug>-notes.md.
- Maintain the current task notes file yourself. Add concise insights when they help future iterations, or things you may need later.
- If the task is unfinished but you're running out of context, mark it as WIP in TASKS.md, leave remaining instructions and useful context in the notes file.
- Follow existing code style, naming conventions, and architectural patterns in the project.
- Work on a git branch named with the task slug prefixed by the conventional commit type (e.g., feat-<slug>, fix-<slug>, refactor-<slug>, docs-<slug>, test-<slug>, chore-<slug>).
- Make the smallest change necessary to complete the task. Avoid unnecessary refactoring unless it's part of the task.
- If you make a non-obvious technical decision, document the reasoning in the notes file.
- After every meaningful change (new function, bug fix, refactor, etc.), run linters, formatters, and type checking if the project has them configured. Fix any issues before marking a task complete.
- After every meaningful change, run tests if available. Fix any failures before marking a task complete.
- Commit frequently using conventional commit format (e.g., feat:, fix:, refactor:, docs:, test:, chore:). Each logical change should be its own commit. Do not push. Use --no-gpg-sign when committing.
- When you finish a task, remove it from TASKS.md and write a concise summary of what you did in the notes file.
- Once the TASKS.md has no tasks left, output on a single line: "<status>DONE</status>"

Task format (for .agents/TASKS.md)
```
Task: <summary>
Slug: <slug-for-notes-file>
Notes:
- .agents/notes/<slug>-notes.md
```
EOF
fi

if [[ ! -f "$DESCRIPTION_FILE" ]] || [[ ! -s "$DESCRIPTION_FILE" ]]; then
  echo "Analyzing codebase to generate project description..."
  DESCRIPTION_PROMPT="Analyze this codebase and write a concise project description (1-2 paragraphs). Include: what the project does, main technologies used, and key components. Output only the description text, nothing else."
  if [[ -n "$USER_PROMPT" ]]; then
    DESCRIPTION_PROMPT="$DESCRIPTION_PROMPT"$'\n\n'"Additional context from user: $USER_PROMPT"
  fi
  printf "%s" "$DESCRIPTION_PROMPT" | opencode run > "$DESCRIPTION_FILE"
fi

if [[ ! -f "$TASKS_FILE" ]]; then
  cat > "$TASKS_FILE" << 'EOF'
# TASKS.md
# Task format:
# Task: <summary>
# Slug: <slug-for-notes-file>
# Notes:
# - .agents/notes/<slug>-notes.md
# (blank line between tasks)
EOF
fi

ITERATION=0
while true; do
  ((ITERATION++)) || true
  if [[ -n "$USER_PROMPT" ]]; then
    PROMPT="$(cat "$RALPH_FILE")"$'\n\n'"$(cat "$DESCRIPTION_FILE")"$'\n\n'"$USER_PROMPT"
  else
    PROMPT="$(cat "$RALPH_FILE")"$'\n\n'"$(cat "$DESCRIPTION_FILE")"$'\n\n'"$(cat "$TASKS_FILE")"
  fi

  STATUS="UNFINISHED"
  while IFS= read -r line; do
    printf "%s\n" "$line"
    # Strip whitespace before comparing
    LINE_TRIMMED=$(echo "$line" | xargs)
    if [[ "$LINE_TRIMMED" == "<status>DONE</status>" ]]; then
      STATUS="DONE"
    fi
  done < <(printf "%s" "$PROMPT" | opencode run)

  if [[ "$STATUS" == "DONE" ]]; then
    break
  fi

  if [[ "$ITERATION" -ge "$MAX_ITERATIONS" ]]; then
    echo "Reached maximum iterations ($MAX_ITERATIONS)"
    break
  fi
done
