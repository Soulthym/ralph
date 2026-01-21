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
