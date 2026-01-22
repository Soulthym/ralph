#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(pwd)"
MAX_ITERATIONS=10

RALPH_FILE="$ROOT_DIR/.agents/RALPH.md"
DESCRIPTION_FILE="$ROOT_DIR/.agents/DESCRIPTION.md"
TASKS_FILE="$ROOT_DIR/.agents/TASKS.md"

mkdir -p "$ROOT_DIR/.agents/notes"
mkdir -p "$ROOT_DIR/.agents/contexts"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required; install jq to run this script." >&2
  exit 1
fi

SELECTED_MODEL=""
USER_PROMPT=""
ITERATION_SET="false"
PROMPT_ARGS=()
MODEL_PROVIDED_BY_ARG="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --)
      shift
      if [[ $# -gt 0 ]]; then
        PROMPT_ARGS+=("$@")
      fi
      break
      ;;
    --model|-m)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for $1" >&2
        exit 1
      fi
      SELECTED_MODEL="$2"
      MODEL_PROVIDED_BY_ARG="true"
      shift 2
      ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ && "$ITERATION_SET" == "false" ]]; then
        MAX_ITERATIONS="$1"
        ITERATION_SET="true"
        shift
      else
        PROMPT_ARGS+=("$@")
        break
      fi
      ;;
  esac
done

if [[ ${#PROMPT_ARGS[@]} -gt 0 ]]; then
  USER_PROMPT="${PROMPT_ARGS[*]}"
elif [[ ! -t 0 ]]; then
  USER_PROMPT="$(cat)"
fi

select_model() {
  local state_dir model_state_file selection
  local -a recent_models favorite_models all_models ordered_models remaining_models
  declare -A seen

  state_dir="${XDG_STATE_HOME:-$HOME/.local/state}"
  model_state_file="$state_dir/opencode/model.json"

  recent_models=()
  favorite_models=()
  if [[ -f "$model_state_file" ]]; then
    mapfile -t recent_models < <(jq -r '.recent[]? | "\(.providerID)/\(.modelID)"' "$model_state_file")
    mapfile -t favorite_models < <(jq -r '.favorite[]? | "\(.providerID)/\(.modelID)"' "$model_state_file")
  fi

  mapfile -t all_models < <(opencode models)

  ordered_models=()
  for model in "${recent_models[@]}"; do
    if [[ -n "$model" && -z "${seen[$model]+x}" ]]; then
      ordered_models+=("$model")
      seen["$model"]=1
    fi
  done

  for model in "${favorite_models[@]}"; do
    if [[ -n "$model" && -z "${seen[$model]+x}" ]]; then
      ordered_models+=("$model")
      seen["$model"]=1
    fi
  done

  remaining_models=()
  for model in "${all_models[@]}"; do
    if [[ -n "$model" && -z "${seen[$model]+x}" ]]; then
      remaining_models+=("$model")
      seen["$model"]=1
    fi
  done

  if [[ ${#remaining_models[@]} -gt 0 ]]; then
    mapfile -t remaining_models < <(printf '%s\n' "${remaining_models[@]}" | sort)
    ordered_models+=("${remaining_models[@]}")
  fi

  if [[ ${#ordered_models[@]} -eq 0 ]]; then
    echo "No models available; check opencode configuration." >&2
    exit 1
  fi

  selection=$(printf '%s\n' "${ordered_models[@]}" | fzf --prompt="Select model: ")
  if [[ -z "$selection" ]]; then
    echo "No model selected; exiting." >&2
    exit 1
  fi
  printf '%s' "$selection"
}

if [[ -z "$SELECTED_MODEL" ]]; then
  if ! command -v fzf >/dev/null 2>&1; then
    echo "fzf is required for model selection; install fzf or pass --model to skip the menu." >&2
    exit 1
  fi
  SELECTED_MODEL="$(select_model)"
fi

MODEL_ARGS=()
if [[ -n "$SELECTED_MODEL" ]]; then
  if [[ "$MODEL_PROVIDED_BY_ARG" == "false" ]]; then
    echo "Using model: $SELECTED_MODEL" >&2
  fi
  MODEL_ARGS=(--model "$SELECTED_MODEL")
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
- When you finish a task: remove it from TASKS.md, write a concise summary in the notes file, then output "<status>TASK_COMPLETE</status>" three times, each on its own line.
- Once the TASKS.md has no tasks left (after completing the final task's notes), output "<status>DONE</status>" three times, each on its own line.

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

if [[ ! -f "$DESCRIPTION_FILE" ]] || [[ ! -s "$DESCRIPTION_FILE" ]]; then
  echo "Analyzing codebase to generate project description..."
  DESCRIPTION_PROMPT="Analyze this codebase and write a concise project description (1-2 paragraphs). Include: what the project does, main technologies used, and key components. Output only the description text, nothing else."
  if [[ -n "$USER_PROMPT" ]]; then
    DESCRIPTION_PROMPT="$DESCRIPTION_PROMPT"$'\n\n'"Additional context from user: $USER_PROMPT"
  fi
  printf "%s" "$DESCRIPTION_PROMPT" | opencode run "${MODEL_ARGS[@]}" > "$DESCRIPTION_FILE"
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

WIP_FILE="$ROOT_DIR/.agents/WIP.md"

update_status_from_text() {
  local lower
  lower="${1,,}"
  if [[ "$lower" == *"<status>task_complete</status>"* ]]; then
    STATUS="TASK_COMPLETE"
  elif [[ "$lower" == *"<status>done</status>"* ]]; then
    STATUS="DONE"
  fi
}

append_text_chunk() {
  local chunk="$1"
  if [[ -n "$chunk" ]]; then
    TEXT_BUFFER+="$chunk"
    update_status_from_text "$TEXT_BUFFER"
  fi
}

flush_text_lines() {
  local line
  while [[ "$TEXT_BUFFER" == *$'\n'* ]]; do
    line="${TEXT_BUFFER%%$'\n'*}"
    printf "%s\n" "$line"
    update_status_from_text "$line"
    TEXT_BUFFER="${TEXT_BUFFER#*$'\n'}"
  done
}

flush_text_remaining() {
  if [[ -n "$TEXT_BUFFER" ]]; then
    printf "%s\n" "$TEXT_BUFFER"
    update_status_from_text "$TEXT_BUFFER"
    TEXT_BUFFER=""
  fi
}

ITERATION=0
while true; do
  ((ITERATION++)) || true

  if [[ -n "$USER_PROMPT" ]]; then
    PROMPT="$(cat "$RALPH_FILE")"$'\n\n'"$(cat "$DESCRIPTION_FILE")"$'\n\n'"$USER_PROMPT"
  else
    PROMPT="$(cat "$RALPH_FILE")"$'\n\n'"$(cat "$DESCRIPTION_FILE")"$'\n\n'"$(cat "$TASKS_FILE")"
  fi

  STATUS="UNFINISHED"
  TEXT_BUFFER=""
  declare -A PRINTED_PARTS=()
  CONTEXT_DATE=$(date +%Y-%m-%d-%H-%M-%S)
  # Create context file with date-only name, will rename after iteration
  TEMP_CONTEXT_FILE="$ROOT_DIR/.agents/contexts/${CONTEXT_DATE}-context.json"

  # Run opencode with JSON output to capture full context
  while IFS= read -r line; do
    # Append raw JSON to context file
    printf "%s\n" "$line" >> "$TEMP_CONTEXT_FILE"

    # Parse JSON to extract text for display and status check
    EVENT_TYPE=$(echo "$line" | jq -r '.type // empty' 2>/dev/null) || true
    if [[ "$EVENT_TYPE" == "text" ]]; then
      PART_ID=$(echo "$line" | jq -r '.part.id // empty' 2>/dev/null) || true
      TEXT_DELTA=$(echo "$line" | jq -r '.part.delta // .delta // empty' 2>/dev/null) || true
      if [[ -n "$TEXT_DELTA" ]]; then
        append_text_chunk "$TEXT_DELTA"
        flush_text_lines
      else
        TEXT=$(echo "$line" | jq -r '.part.text // empty' 2>/dev/null) || true
        if [[ -n "$TEXT" ]]; then
          if [[ -n "$PART_ID" ]]; then
            if [[ -z "${PRINTED_PARTS[$PART_ID]+x}" ]]; then
              PRINTED_PARTS["$PART_ID"]=1
              append_text_chunk "$TEXT"
              flush_text_lines
            fi
          else
            append_text_chunk "$TEXT"
            flush_text_lines
          fi
        fi
      fi
    elif [[ "$EVENT_TYPE" == "tool_use" ]]; then
      flush_text_lines
      # Display tool usage for visibility
      TOOL=$(echo "$line" | jq -r '.part.tool // empty' 2>/dev/null) || true
      TITLE=$(echo "$line" | jq -r '.part.state.title // empty' 2>/dev/null) || true
      if [[ -n "$TOOL" ]]; then
        printf "[%s] %s\n" "$TOOL" "$TITLE"
      fi
    fi
    flush_text_lines
  done < <(printf "%s" "$PROMPT" | opencode run "${MODEL_ARGS[@]}" --format json)

  flush_text_remaining

  # Read slug from WIP.md (written by ralph during the iteration)
  CONTEXT_SLUG=""
  if [[ -f "$WIP_FILE" ]]; then
    CONTEXT_SLUG=$(cat "$WIP_FILE" | xargs)
  fi
  if [[ -z "$CONTEXT_SLUG" ]]; then
    CONTEXT_SLUG="unknown"
  fi

  # Rename context file with correct slug
  CONTEXT_FILE="$ROOT_DIR/.agents/contexts/${CONTEXT_SLUG}-${CONTEXT_DATE}-context.json"
  mv "$TEMP_CONTEXT_FILE" "$CONTEXT_FILE"

  # Commit the context file
  git add "$CONTEXT_FILE"
  git commit --no-gpg-sign -m "chore: add context ${CONTEXT_SLUG}-${CONTEXT_DATE}-context.json" || true

  if [[ "$STATUS" == "DONE" ]]; then
    break
  fi

  if [[ "$ITERATION" -ge "$MAX_ITERATIONS" ]]; then
    echo "Reached maximum iterations ($MAX_ITERATIONS)"
    break
  fi
done
