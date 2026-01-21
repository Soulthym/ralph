#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(pwd)"
MAX_ITERATIONS=10

RALPH_FILE="$ROOT_DIR/.agents/RALPH.md"
DESCRIPTION_FILE="$ROOT_DIR/.agents/DESCRIPTION.md"
TASKS_FILE="$ROOT_DIR/.agents/TASKS.md"

mkdir -p "$ROOT_DIR/.agents/notes"
mkdir -p "$ROOT_DIR/.agents/contexts"

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
- Read all relevant .md files in .agents/ (TASKS.md, WIP.md, PLAN.md if it exists) to understand the current state.
- Pick an unfinished task if any, otherwise pick the most important task. Mark it as WIP before starting work and write the slug to .agents/WIP.md.
- Each task must have a Slug. Choose a short, unique slug and write it into its corresponding TASKS.md if missing.
- Notes live at .agents/notes/<slug>-notes.md.
- Maintain the current task notes file yourself. Add concise insights when they help future iterations, or things you may need later.
- If the task is unfinished but you're running out of context, mark it as WIP in TASKS.md, leave remaining instructions and useful context in the notes file.
- Follow existing code style, naming conventions, and architectural patterns in the project.
- Before starting work, fetch first, then ensure dev and dev-auto branches exist (create them if missing). Pull dev and merge it into dev-auto. Review any changes before proceeding.
- After reviewing changes, update or create the relevant .agents/notes files with context for future reference.
- If you have questions, write them in .agents/QUESTIONS.md and reference any relevant .agents/notes files.
- Work on a git branch named with the task slug prefixed by the conventional commit type (e.g., feat-<slug>, fix-<slug>, refactor-<slug>, docs-<slug>, test-<slug>, chore-<slug>).
- Make the smallest change necessary to complete the task. Avoid unnecessary refactoring unless it's part of the task.
- If you make a non-obvious technical decision, document the reasoning in the notes file.
- After every meaningful change (new function, bug fix, refactor, etc.), run linters, formatters, and type checking if the project has them configured. Fix any issues before marking a task complete.
- After every meaningful change, run tests if available. Fix any failures before marking a task complete.
- Commit frequently using conventional commit format (e.g., feat:, fix:, refactor:, docs:, test:, chore:). Each logical change should be its own commit. Do not push. Use --no-gpg-sign when committing.
- Once your task is complete, pull the dev-auto branch and merge your branch into dev-auto.
- When you finish a task, remove it from TASKS.md and write a concise summary of what you did in the notes file.
- Once the TASKS.md has no tasks left, output on a single line: "<status>DONE</status>"

Task format (for .agents/TASKS.md)
```
Task: <summary>
Status: <TODO|WIP|DONE>
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

  # Read the slug from WIP.md (written by ralph when picking a task)
  CONTEXT_SLUG=""
  WIP_FILE="$ROOT_DIR/.agents/WIP.md"
  if [[ -f "$WIP_FILE" ]]; then
    CONTEXT_SLUG=$(cat "$WIP_FILE" | xargs)
  fi
  if [[ -z "$CONTEXT_SLUG" ]]; then
    CONTEXT_SLUG="prompt"
  fi

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
  CONTEXT_DATE=$(date +%Y-%m-%d-%H-%M-%S)
  CONTEXT_FILE="$ROOT_DIR/.agents/contexts/${CONTEXT_SLUG}-${CONTEXT_DATE}-context.json"

  while IFS= read -r line; do
    if [[ "$line" == data:* ]]; then
      DATA="${line#data:}"

      # Append raw JSON to context file
      printf "%s\n" "$DATA" >> "$CONTEXT_FILE"

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
            # Strip whitespace before comparing
            TEXT_TRIMMED=$(echo "$TEXT" | xargs)
            if [[ "$TEXT_TRIMMED" == "<status>DONE</status>" ]]; then
              STATUS="DONE"
            fi
          fi
        elif [[ "$PART_SESSION" == "$SESSION_ID" && "$PART_TYPE" == "tool" ]]; then
          # Display tool usage for visibility
          TOOL=$(echo "$DATA" | jq -r '.properties.part.tool // empty' 2>/dev/null) || true
          TITLE=$(echo "$DATA" | jq -r '.properties.part.state.title // empty' 2>/dev/null) || true
          TOOL_STATUS=$(echo "$DATA" | jq -r '.properties.part.state.status // empty' 2>/dev/null) || true
          if [[ -n "$TOOL" && "$TOOL_STATUS" == "completed" ]]; then
            printf "[%s] %s\n" "$TOOL" "$TITLE"
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
