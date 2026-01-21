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
- Before marking a task complete, run tests present in the CI if any, otherwise run available test commands.
- Before marking a task complete, run formatters/linters if the project has them configured.
- When you finish a task, remove it from TASKS.md and write a concise summary of what you did in the notes file.
- Once the TASKS.md has no tasks left, output on a single line: "DONE"

Task format (for .agents/TASKS.md)
```
Task: <summary>
Slug: <slug-for-notes-file>
Notes:
- .agents/notes/<slug>-notes.md
```
EOF
fi

if [[ ! -f "$DESCRIPTION_FILE" ]]; then
  touch "$DESCRIPTION_FILE"
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
  ((ITERATION++))
  if [[ -n "$USER_PROMPT" ]]; then
    PROMPT="$(cat "$RALPH_FILE")"$'\n\n'"$(cat "$DESCRIPTION_FILE")"$'\n\n'"$USER_PROMPT"
  else
    PROMPT="$(cat "$RALPH_FILE")"$'\n\n'"$(cat "$DESCRIPTION_FILE")"$'\n\n'"$(cat "$TASKS_FILE")"
  fi

  STATUS="UNFINISHED"
  while IFS= read -r line; do
    printf "%s\n" "$line"
    if [[ "$line" == "DONE" ]]; then
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
