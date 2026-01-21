#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPH_FILE="$ROOT_DIR/.agents/RALPH.md"
DESCRIPTION_FILE="$ROOT_DIR/.agents/DESCRIPTION.md"
TASKS_FILE="$ROOT_DIR/.agents/TASKS.md"

USER_PROMPT=""
if [[ $# -gt 0 ]]; then
  USER_PROMPT="$*"
elif [[ ! -t 0 ]]; then
  USER_PROMPT="$(cat)"
fi

if [[ ! -f "$RALPH_FILE" ]]; then
  echo "Missing $RALPH_FILE" >&2
  exit 1
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

while true; do
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
done
