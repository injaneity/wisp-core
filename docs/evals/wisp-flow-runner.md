# Wisp Flow Runner

This is a small deterministic scorer for the Wisp flow eval.

## Purpose

The runner is intentionally narrow. It does **not** execute Wisp itself and it does **not** depend on the current core chat loop.

Instead, it scores a submission artifact that represents what a candidate implementation produced for each benchmark case.

This lets us:
- evaluate the target product behavior before rewriting core flows
- compare alternate implementations or policies
- keep the eval stable while the internal architecture changes

---

## Submission format

The runner expects a JSON file with this top-level shape:

```json
{
  "results": [
    {
      "case_id": "case_001_pure_knowledge",
      "routing": {
        "sp_001": ["wiki"]
      },
      "final_state": {
        "scratchpad": [],
        "wiki": [
          {
            "id": "note_acme_migration",
            "title": "Acme migration",
            "path": "companies/acme/migration.md",
            "tags": ["company", "project"],
            "summary": "Acme's migration is targeting Q3 and budget approval is pending.",
            "body": "...",
            "source_ids": ["sp_001"]
          }
        ],
        "tasks": [],
        "task_threads": []
      },
      "thread_replies": [],
      "task_patches": [],
      "cleanup_ticks": [
        {"tick_id": "tick_001", "mutation_count": 1}
      ],
      "hard_fail_markers": []
    }
  ]
}
```

## Fields used by the runner

### `case_id`
Must match one of the case ids in `evals/wisp_flow_v0/`.

### `routing`
Maps scratchpad item ids to one or more targets:
- `scratchpad`
- `wiki`
- `task`

### `final_state`
Contains the final scratchpad/wiki/task state after all events in the case.

If your implementation has first-class thread objects, you can also include `task_threads`.

### `thread_replies`
Optional array of:

```json
{
  "query_event_id": "q_010_1",
  "text": "...",
  "citations_note_ids": ["note_acme_migration"]
}
```

### `task_patches`
Optional array used for thread-driven task state mutations:

```json
{
  "event_id": "u_011_1",
  "task_id": "task_followup_jane",
  "patch": {
    "status": "in_progress",
    "last_activity_at": "2026-04-17T11:00:00Z"
  }
}
```

The current runner checks that a patch entry exists for cases with `thread_update_expectations`, and scores the resulting final task state.

### `cleanup_ticks`
Optional array used for cleanup idempotence scoring:

```json
{
  "tick_id": "tick_009_first",
  "mutation_count": 3
}
```

### `hard_fail_markers`
Optional array of explicit hard-fail strings if the adapter already knows it violated a severe constraint.

### `lost_information`
Optional boolean. If true, the runner applies a hard-fail penalty.

---

## What the runner scores today

Deterministic checks only:
- routing
- scratchpad expectations
- wiki note expectations
- task expectations
- simple cleanup expectations
- thread answer containment and citations
- thread-driven task state updates

It also resolves symbolic dates like:
- `relative:tomorrow`
- `relative:friday`
- `relative:next_tuesday`

using the earliest timestamp in the case.

---

## What it does not score yet

This small runner does not yet do rubric-based judging for:
- summary quality
- nuanced groundedness
- subtle scope drift
- semantic usefulness of drafts
- whether a task patch was the *best* patch, beyond the deterministic fields checked

Those can be added later as a second-stage judge.

---

## Usage

Score all cases:

```bash
python3 evals/wisp_flow_runner.py submission.json
```

Score one case:

```bash
python3 evals/wisp_flow_runner.py submission.json --case case_003_knowledge_plus_task --verbose
```

Use a different case directory:

```bash
python3 evals/wisp_flow_runner.py submission.json --cases-dir evals/wisp_flow_v0
```

---

## Recommended workflow

1. Keep the benchmark cases stable.
2. Implement candidate behavior in an adapter or prototype.
3. Export the adapter's results into the submission format.
4. Run the scorer.
5. Use failures to refine policy and object model before touching core runtime behavior.
