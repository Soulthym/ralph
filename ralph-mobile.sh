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
- Make the smallest change necessary to complete the task. Avoid unnecessary refactoring unless it's part of the task.
- If you make a non-obvious technical decision, document the reasoning in the notes file.
- Before marking a task complete, run tests present in the CI if any, otherwise run available test commands. If tests fail, fix the issues before marking complete.
- Before marking a task complete, run formatters/linters if the project has them configured. If they fail, fix the issues before marking complete.
- Commit your changes after completing each task using conventional commit format (e.g., feat:, fix:, refactor:, docs:, test:, chore:). Do not push. Use --no-gpg-sign when committing.
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

# === Start opencode server ===
SERVER_OUTPUT=$(mktemp)
opencode serve --port 0 > "$SERVER_OUTPUT" 2>&1 &
SERVER_PID=$!

cleanup() {
  kill "$SERVER_PID" 2>/dev/null || true
  rm -f "$SERVER_OUTPUT"
}
trap cleanup EXIT INT TERM

# Wait for server to start and parse port
PORT=""
for _ in {1..50}; do
  if grep -q "listening on" "$SERVER_OUTPUT" 2>/dev/null; then
    PORT=$(grep "listening on" "$SERVER_OUTPUT" | sed -E 's/.*:([0-9]+)$/\1/')
    break
  fi
  sleep 0.1
done

if [[ -z "$PORT" ]]; then
  echo "Failed to start opencode server" >&2
  cat "$SERVER_OUTPUT" >&2
  exit 1
fi

BASE_URL="http://127.0.0.1:$PORT"

# Wait for server to be ready
for _ in {1..50}; do
  if curl -s "$BASE_URL/global/health" 2>/dev/null | jq -e '.healthy' >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

# === Generate project description if needed ===
if [[ ! -f "$DESCRIPTION_FILE" ]] || [[ ! -s "$DESCRIPTION_FILE" ]]; then
  echo "Analyzing codebase to generate project description..."
  DESCRIPTION_PROMPT="Analyze this codebase and write a concise project description (1-2 paragraphs). Include: what the project does, main technologies used, and key components. Output only the description text, nothing else."
  if [[ -n "$USER_PROMPT" ]]; then
    DESCRIPTION_PROMPT="$DESCRIPTION_PROMPT"$'\n\n'"Additional context from user: $USER_PROMPT"
  fi

  # Create session for description generation
  DESC_SESSION_ID=$(curl -s -X POST "$BASE_URL/session" \
    -H "Content-Type: application/json" \
    -d '{}' | jq -r '.id')

  # JSON-escape the prompt
  ESCAPED_DESC_PROMPT=$(printf '%s' "$DESCRIPTION_PROMPT" | jq -Rs .)

  # Send prompt
  curl -s -X POST "$BASE_URL/session/$DESC_SESSION_ID/message" \
    -H "Content-Type: application/json" \
    -d "{\"parts\": [{\"type\": \"text\", \"text\": $ESCAPED_DESC_PROMPT}]}" >/dev/null &

  # Listen for SSE events and capture text output
  DESCRIPTION_TEXT=""
  while IFS= read -r line; do
    if [[ "$line" == data:* ]]; then
      DATA="${line#data:}"
      EVENT_TYPE=$(echo "$DATA" | jq -r '.type // empty' 2>/dev/null) || continue

      if [[ "$EVENT_TYPE" == "message.part.updated" ]]; then
        PART_TYPE=$(echo "$DATA" | jq -r '.properties.part.type // empty' 2>/dev/null) || continue
        PART_SESSION=$(echo "$DATA" | jq -r '.properties.part.sessionID // empty' 2>/dev/null) || continue

        if [[ "$PART_SESSION" == "$DESC_SESSION_ID" && "$PART_TYPE" == "text" ]]; then
          HAS_END=$(echo "$DATA" | jq -r '.properties.part.time.end // empty' 2>/dev/null) || continue
          if [[ -n "$HAS_END" ]]; then
            DESCRIPTION_TEXT=$(echo "$DATA" | jq -r '.properties.part.text // empty' 2>/dev/null) || continue
          fi
        fi
      fi

      if [[ "$EVENT_TYPE" == "session.idle" ]]; then
        IDLE_SESSION=$(echo "$DATA" | jq -r '.properties.sessionID // empty' 2>/dev/null) || continue
        if [[ "$IDLE_SESSION" == "$DESC_SESSION_ID" ]]; then
          break
        fi
      fi
    fi
  done < <(curl -s -N "$BASE_URL/event")

  printf "%s" "$DESCRIPTION_TEXT" > "$DESCRIPTION_FILE"
fi

# === Main loop ===
ITERATION=0
while true; do
  ((ITERATION++)) || true

  # Build prompt
  if [[ -n "$USER_PROMPT" ]]; then
    PROMPT="$(cat "$RALPH_FILE")"$'\n\n'"$(cat "$DESCRIPTION_FILE")"$'\n\n'"$USER_PROMPT"
  else
    PROMPT="$(cat "$RALPH_FILE")"$'\n\n'"$(cat "$DESCRIPTION_FILE")"$'\n\n'"$(cat "$TASKS_FILE")"
  fi

  # Create new session
  SESSION_ID=$(curl -s -X POST "$BASE_URL/session" \
    -H "Content-Type: application/json" \
    -d '{}' | jq -r '.id')

  # JSON-escape the prompt
  ESCAPED_PROMPT=$(printf '%s' "$PROMPT" | jq -Rs .)

  # Send prompt
  curl -s -X POST "$BASE_URL/session/$SESSION_ID/message" \
    -H "Content-Type: application/json" \
    -d "{\"parts\": [{\"type\": \"text\", \"text\": $ESCAPED_PROMPT}]}" >/dev/null &

  # Listen for SSE events
  STATUS="UNFINISHED"
  while IFS= read -r line; do
    if [[ "$line" == data:* ]]; then
      DATA="${line#data:}"
      EVENT_TYPE=$(echo "$DATA" | jq -r '.type // empty' 2>/dev/null) || continue

      # Handle text output
      if [[ "$EVENT_TYPE" == "message.part.updated" ]]; then
        PART_TYPE=$(echo "$DATA" | jq -r '.properties.part.type // empty' 2>/dev/null) || continue
        PART_SESSION=$(echo "$DATA" | jq -r '.properties.part.sessionID // empty' 2>/dev/null) || continue

        if [[ "$PART_SESSION" == "$SESSION_ID" && "$PART_TYPE" == "text" ]]; then
          HAS_END=$(echo "$DATA" | jq -r '.properties.part.time.end // empty' 2>/dev/null) || continue
          if [[ -n "$HAS_END" ]]; then
            TEXT=$(echo "$DATA" | jq -r '.properties.part.text // empty' 2>/dev/null) || continue
            printf "%s\n" "$TEXT"
            if [[ "$TEXT" == "DONE" ]]; then
              STATUS="DONE"
            fi
          fi
        fi
      fi

      # Session complete
      if [[ "$EVENT_TYPE" == "session.idle" ]]; then
        IDLE_SESSION=$(echo "$DATA" | jq -r '.properties.sessionID // empty' 2>/dev/null) || continue
        if [[ "$IDLE_SESSION" == "$SESSION_ID" ]]; then
          break
        fi
      fi
    fi
  done < <(curl -s -N "$BASE_URL/event")

  # Check exit conditions
  if [[ "$STATUS" == "DONE" ]]; then
    break
  fi

  if [[ "$ITERATION" -ge "$MAX_ITERATIONS" ]]; then
    echo "Reached maximum iterations ($MAX_ITERATIONS)"
    break
  fi
done
