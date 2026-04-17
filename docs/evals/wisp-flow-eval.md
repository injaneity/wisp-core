# Wisp Flow Eval v0.1

## Purpose

This eval defines the intended product behavior for Wisp.

**v0.1 architecture alignment:** this eval now assumes an **object-centric** product architecture, where scratchpad items, tasks, task threads, and wiki notes are first-class state objects. It should no longer be interpreted as a transcript-centric chat eval.

Wisp is **not** a general chatbot. It is a personal information system with three surfaces:

1. **Scratchpad inbox** — a low-friction text box for dumping raw information
2. **Structured memory** — wiki notes for durable knowledge and tasks for actionable items
3. **Task threads** — the main query and execution surface for work-in-progress

The goal of this eval is to shape implementation toward that flow and away from a bloated, generic chat loop.

---

## Product definition

### 1) Scratchpad inbox

The user can dump arbitrary information into a single text box:
- ideas
- copied text
- reminders
- observations
- meeting notes
- rough todos
- partial facts

The inbox is intentionally messy. Wisp must not require up-front structure.

### 2) Structured memory

Wisp may asynchronously transform inbox material into:
- **wiki notes** for durable, reusable knowledge
- **tasks** for actionable intent

Wisp should be conservative. Not every item deserves promotion.

### 3) Task threads

Every task is also a thread. The user should be able to open a task and ask things like:
- what do we know relevant to this?
- what should I do next?
- draft a message for this
- what is blocked here?
- when and where is this?

Task threads should pull in relevant wiki knowledge without drifting into unrelated context.

---

## Canonical end-to-end flow

### Step 1 — Capture
The user dumps raw information into the scratchpad.

Expected behavior:
- preserve the raw information
- accept messy input without complaint
- avoid forcing categorization during capture

### Step 2 — Background organization
Wisp periodically reviews scratchpad items and decides whether to:
- keep them in scratchpad
- move durable facts into wiki notes
- create tasks
- do both
- merge into existing notes or tasks
- link items together

### Step 3 — Task formation
If an item implies action, Wisp may create a task with:
- title
- optional due date
- optional due time
- optional place
- source links
- related wiki note links

Inference should be grounded. Unsupported metadata should be left blank.

### Step 4 — Task execution interface
The user interacts primarily through task threads.

A task thread should:
- answer scoped questions about the task
- use linked wiki context when helpful
- stay relevant to the task
- support execution help such as drafting or summarizing

### Step 5 — Continuous cleanup
Repeated cleanup runs should:
- reduce clutter
- improve structure
- avoid churn
- avoid duplication
- preserve provenance
- remain mostly idempotent after the first useful reorganization

---

## Non-goals

This eval explicitly does **not** optimize Wisp for:
- generic freeform chat quality
- broad assistant personality
- open-ended agent tool demos
- turning every note into a task
- inventing calendar metadata when unsupported
- storing every raw item as a permanent wiki note

---

## Core behavioral contract

### Rule 1 — Never lose information
Every user-provided fact must remain represented in at least one of:
- scratchpad
- wiki
- task
- task thread history

### Rule 2 — Don’t over-structure
Not every scratchpad item should become a wiki note or task.

### Rule 3 — Promote durable knowledge
Stable facts should move to the wiki.

### Rule 4 — Promote actionable intent
Actionable items should become tasks.

### Rule 5 — Infer conservatively
Date, time, and place may be inferred if reasonably grounded. Otherwise omit them.

### Rule 6 — Preserve provenance
Wiki notes and tasks should link back to source scratchpad items when possible.

### Rule 7 — Task threads are the primary work surface
Task-thread responses should stay scoped and grounded in task + linked wiki state.

### Rule 8 — Cleanup should be idempotent
Repeated cleanup runs should not keep creating duplicates or rewriting stable objects.

---

## Canonical state model

### Scratchpad item
```json
{
  "id": "sp_001",
  "text": "jane from acme said infra migration target is q3. follow up next tuesday",
  "created_at": "2026-04-17T10:00:00Z",
  "status": "active",
  "source_type": "manual",
  "linked_note_ids": ["note_acme"],
  "linked_task_ids": ["task_followup_jane"]
}
```

### Wiki note
```json
{
  "id": "note_acme",
  "title": "Acme migration",
  "path": "companies/acme/migration.md",
  "tags": ["company", "project"],
  "summary": "Acme's infra migration is targeting Q3 with budget uncertainty.",
  "body": "...",
  "source_ids": ["sp_001"]
}
```

### Task
```json
{
  "id": "task_followup_jane",
  "title": "Follow up with Jane about Acme infra migration",
  "status": "open",
  "due_date": "2026-04-21",
  "due_time": null,
  "place": null,
  "source_ids": ["sp_001"],
  "related_note_ids": ["note_acme", "note_jane"],
  "thread_id": "thread_task_followup_jane",
  "last_activity_at": "2026-04-17T10:05:00Z"
}
```

### Task thread
```json
{
  "id": "thread_task_followup_jane",
  "task_id": "task_followup_jane",
  "messages": [
    {"role": "user", "text": "What do we already know relevant to this?"},
    {
      "role": "assistant",
      "text": "Jane leads the migration, the target is Q3, and budget approval is still pending.",
      "citations_note_ids": ["note_acme"]
    }
  ]
}
```

### State ownership
- Scratchpad state is the capture layer.
- Wiki state is durable knowledge.
- Task state is operational work state.
- Task-thread state is the primary conversational surface.
- Full conversational transcript replay is **not** the canonical architecture for this eval.

---

## Allowed action model

The eval assumes implementations can be mapped onto a small action surface.

### Scratchpad actions
- `scratchpad.retain(item_id)`
- `scratchpad.archive(item_id)`
- `scratchpad.link(item_id, target_id)`

### Wiki actions
- `wiki.create(...)`
- `wiki.update(note_id, ...)`
- `wiki.merge(note_a, note_b)`

### Task actions
- `task.create(...)`
- `task.update(task_id, ...)`
- `task.merge(task_a, task_b)`
- `task.link(task_id, note_id)`

### Thread actions
- `thread.reply(task_id, message, citations)`
- `thread.update_task(task_id, patch)`
- `thread.append_user_message(task_id, text)`
- `thread.append_system_context(task_id, citations)`

The eval is compatible with richer implementations, but submissions should be reducible to these actions.

---

## What the eval measures

### A. Inbox routing
Given each scratchpad item, did Wisp correctly choose:
- scratchpad only
- wiki
- task
- wiki + task

### B. Structure quality
When Wisp created or updated wiki notes/tasks, were they:
- merged correctly
- non-duplicative
- sensibly titled
- source-linked

### C. Metadata discipline
Did Wisp correctly extract date/time/place, and leave them blank when unsupported?

### D. Cleanup quality
Did background organization reduce mess without losing information or causing churn?

### E. Task-thread usefulness
Can a user ask a task question and get a grounded, scoped answer that uses relevant wiki context?

### F. Task-thread state mutation
When a user updates a task inside its thread, does Wisp update task state cleanly without spawning duplicate tasks or losing provenance?

---

## Scoring

Suggested weighted score:
- **20% inbox triage**
- **20% structure quality**
- **15% task creation + metadata**
- **15% cleanup behavior**
- **30% task-thread behavior**

### Sub-metrics

#### Inbox triage
- route precision / recall
- info-loss rate
- over-structuring rate

#### Wiki structure
- merge/create accuracy
- duplicate avoidance
- title + summary quality
- source-link completeness

#### Task structure
- task creation precision / recall
- title quality
- due date exact match
- due time exact match
- place exact match
- unsupported-field hallucination rate

#### Cleanup
- idempotence
- churn rate
- duplicate reduction
- scratchpad compression without loss

#### Task-thread behavior
- answer correctness
- groundedness
- scope control
- citation correctness
- useful next-step support
- clean task-state mutation from thread updates

---

## Hard fail conditions

A scenario should incur severe penalty if the system:
- loses user information
- invents due date, time, or place unsupported by the input
- creates duplicate tasks or notes unnecessarily
- answers task-thread queries with irrelevant context
- mutates stable objects on every cleanup tick
- turns nearly every scratchpad item into a task
- creates a new task when a task-thread update should have patched the existing task

---

## Eval suites

### Suite 1 — Inbox routing
Tests whether loose info is routed correctly:
- note vs task vs both vs neither
- ambiguity preservation
- avoidance of unnecessary structure

### Suite 2 — Structure building
Tests quality of created wiki notes and tasks:
- merge vs create
- duplicate avoidance
- titles and summaries
- source linking

### Suite 3 — Metadata extraction
Tests date/time/place inference:
- grounded extraction
- omission under uncertainty
- normalization

### Suite 4 — Background cleanup
Tests asynchronous organization:
- incremental promotion
- deduplication
- archive/retain decisions
- idempotence

### Suite 5 — Task-thread interaction
Tests the main work surface:
- scoped answers
- use of related wiki notes
- next-step reasoning
- drafting help
- task state updates when appropriate

---

## Runner protocol

Each benchmark case defines:
- an initial state
- a sequence of events
- gold routing and state expectations
- optional thread-answer expectations
- optional thread-update expectations
- hard fail conditions

The runner should:
1. load the case
2. initialize scratchpad/wiki/tasks
3. feed events in order
4. capture produced actions, final state, thread answers, and task patches emitted from thread activity
5. score deterministic fields first
6. use rubric-based judging only for fuzzy text fields

### Event types
- `scratchpad_add`
- `cleanup_tick`
- `thread_query`
- `thread_user_update`

### Recommended output capture
- action log
- final scratchpad state
- final wiki state
- final task state
- thread replies
- task patches emitted during threads

---

## Scenario design philosophy

The benchmark scenarios are intentionally small but compositional.

They should force the implementation toward:
- inbox-first UX
- async cleanup
- conservative structure
- task creation from actionable intent
- task-centric querying
- low duplication
- low hallucination
- provenance-preserving organization

They should push away from:
- generic chatbot loops
- massive transcript replay as the only memory strategy
- uncontrolled tool chatter
- always-on over-automation

---

## Included v0 benchmark pack

The initial benchmark pack contains 11 scenarios:
1. pure knowledge
2. pure todo
3. knowledge + task
4. ambiguous thought
5. merge into existing wiki note
6. merge into existing task
7. full metadata extraction
8. no metadata extraction
9. cleanup promotion + idempotence
10. task-thread relevant-context QA
11. task-thread user update patches task state

See `evals/wisp_flow_v0/`.
