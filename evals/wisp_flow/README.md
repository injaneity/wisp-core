# Wisp Flow Eval

This eval pack matches the simplified Wisp product model:
- markdown workspace rooted at `wikiRoot`
- notes and tasks are markdown files
- shared prelude for every file
- tasks are a special kind of file
- sections are the main semantic units inside files
- primary tool surface: `read`, `edit`, `bash`, `note`, `task`

## What it scores

Each case evaluates a submission on three axes:

1. **Tool use**
   - did Wisp use the right high-level action (`note`, `task`, `edit`, `read`)?
   - did it avoid obviously wrong actions?

2. **Workspace outcome**
   - were the right files created or updated?
   - do notes/tasks have the required prelude?
   - do task files contain task-specific fields?
   - did Wisp avoid duplicates when an existing file should have been updated?

3. **Final reply**
   - does the answer mention the important facts or outcome?
   - is it aligned with the expected operation?

## Submission model

The runner expects a JSON file shaped like `evals/wisp_flow_submission.template.json`.

By default, the harness writes submissions under `evals/runs/`, which is gitignored.

For each case result, provide:
- `case_id`
- `tool_calls`: ordered list of tool calls with at least a `name`
- `final_reply`: final assistant text
- `workspace.files`: final markdown files as `{ path, content }`

The runner compares only the final workspace, tool usage, and final reply. It does not depend on the old scratchpad-routing or cleanup-tick model.

## Notes

- `relative:*` date markers are resolved relative to the case timestamp.
