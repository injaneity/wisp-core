# Wisp Ideal Use-Case Plan

This is a product and architecture plan for moving Wisp toward the intended flow defined in `docs/evals/wisp-flow-eval.md`.

It is intentionally **non-invasive**: this document does not modify the current core source code. It describes what should change next so implementation can converge on the desired product behavior.

---

## 1. Current shape vs target shape

### Current shape in this repo
From the current code and prompts:
- `src/wisp.swift` is centered on an **interactive chat loop** with full session replay.
- `prompts/prompt.md` frames Wisp as a **wiki librarian**.
- `prompts/ingest.md` and `prompts/query.md` define **wiki ingest/query** flows.
- There is **no first-class task object model** yet.
- There is **no scratchpad inbox abstraction** yet.
- There is **no explicit task-thread surface** yet.

### Target shape
Wisp should become a system with three first-class surfaces:
1. **scratchpad inbox**
2. **structured memory** = wiki + tasks
3. **task threads** as the primary query/work surface

That means the core interaction model should stop being “chat with a wiki agent” and become “capture → organize → act”.

---

## 2. Product principles to preserve

These are the principles the implementation should optimize for.

### A. Capture first
The scratchpad must accept raw text with minimal friction.

### B. Structure later
Organization happens asynchronously or in explicit cleanup passes.

### C. Durable facts go to wiki
The wiki stores reusable knowledge, not every transient thought.

### D. Actionable items become tasks
Tasks should hold action, optional metadata, provenance, and links to relevant knowledge.

### E. Task threads are the main interface
Users should mostly work inside task threads rather than asking broad freeform questions against a huge transcript.

### F. Provenance matters
Structured objects should retain source links back to scratchpad items.

### G. Low churn
Repeated cleanup should settle into stable objects instead of endlessly rewriting them.

---

## 3. Recommended conceptual model

## 3.1 Scratchpad inbox
Introduce a first-class scratchpad store.

### Scratchpad item fields
- `id`
- `text`
- `created_at`
- `status` (`active`, `linked`, `archived`)
- `source_type` (optional: manual, paste, imported)
- `linked_note_ids`
- `linked_task_ids`

### Why
Right now, raw user input mainly exists as transcript messages. That is too chat-centric and makes later organization brittle.

The scratchpad should be a persistent inbox distinct from chat history.

---

## 3.2 Task model
Introduce first-class tasks as independent objects.

### Task fields
- `id`
- `title`
- `status`
- `due_date` optional
- `due_time` optional
- `place` optional
- `source_ids`
- `related_note_ids`
- `thread_id`
- `last_activity_at`

### Why
The eval depends on task creation, linking, and thread-scoped work. Without explicit task objects, these behaviors will stay bolted onto generic chat state.

---

## 3.3 Task threads
Each task should own a thread.

### Thread responsibilities
- answer task-scoped questions
- draft outputs for the task
- summarize what is known
- update task state from user messages
- pull only relevant wiki context

### Why
This gives Wisp a stable unit of work and avoids broad chat drift.

---

## 3.4 Wiki model
The wiki should continue as durable knowledge, but its role becomes clearer:
- stable facts
- people/projects/companies/research
- context that tasks can link into

The wiki should no longer carry the whole product alone.

---

## 4. Recommended interaction redesign

## 4.1 Replace “chat first” with “inbox first”
Preferred UX surfaces:
- **scratchpad textbox** for dumping information
- **task list** for actionables
- **task thread view** for ongoing work
- **wiki view** for durable knowledge browsing

General chat should become secondary.

## 4.2 Treat cleanup as a system operation
Instead of asking the model to behave like a chat assistant every turn, define explicit cleanup passes that operate over scratchpad state.

Cleanup can:
- promote durable facts to wiki
- create or merge tasks
- link tasks to notes
- archive or retain scratchpad items

## 4.3 Make task threads retrieval-scoped
When inside a task thread, retrieval order should be:
1. task object
2. task thread history
3. linked wiki notes
4. optionally closely related tasks
5. only then anything broader

This is much closer to the desired product than replaying a giant conversation transcript.

---

## 5. Recommended policy layer

Before implementation detail, define explicit policies.

### Policy 1 — promotion policy
For each scratchpad item, classify into:
- keep in scratchpad
- wiki
- task
- wiki + task

### Policy 2 — metadata policy
Only infer date/time/place when there is enough grounding.

### Policy 3 — merge policy
Prefer updating an existing note/task over creating duplicates.

### Policy 4 — task-thread retrieval policy
Use linked notes first; avoid unrelated global retrieval.

### Policy 5 — cleanup idempotence policy
A cleanup pass should not keep mutating stable objects.

These policies should be explicit and testable against the eval.

---

## 6. Recommended implementation sequence

A staged rollout is safer than rewriting everything at once.

### Phase 0 — eval-first design
Already started:
- `docs/evals/wisp-flow-eval.md`
- `docs/evals/wisp-flow-schema.json`
- `evals/wisp_flow_v0/`
- `evals/wisp_flow_runner.py`

Goal: keep product intent fixed while architecture changes.

### Phase 1 — build an adapter/prototype outside the current core loop
Implement a separate prototype that can:
- ingest scratchpad events
- maintain scratchpad/wiki/task objects
- answer task-thread queries
- export eval submissions

This avoids contaminating the current core while policy is still in flux.

### Phase 2 — establish persistent object stores
Define storage layout for:
- scratchpad items
- tasks
- task threads
- wiki links/provenance

At this stage, file formats matter more than UI.

### Phase 3 — introduce cleanup engine
Build a background organizer over scratchpad state.

### Phase 4 — introduce task-thread execution surface
Let users open a task and interact with it directly.

### Phase 5 — de-emphasize transcript replay
Once scratchpad/tasks/wiki/thread state are first-class, reduce reliance on giant full-session replay.

---

## 7. Recommended storage shape

This is only a proposal, but it matches the eval well.

### Scratchpad
- `scratchpad/items/<id>.json`

### Tasks
- `tasks/<id>.json`

### Task threads
- `tasks/threads/<task_id>.jsonl`

### Wiki
- continue using markdown notes

### Links / provenance
Either embedded in task/note objects or maintained in a lightweight index.

---

## 8. What should *not* be done yet

To stay aligned with the eval, avoid these premature moves:
- adding more generic chat features
- relying on one giant conversational memory transcript as the main state model
- building broad autonomous agent loops before the object model exists
- introducing many tools before policy is stable
- making every scratchpad item immediately structured

---

## 9. How to use the runner during design

The small runner should become the design loop.

Recommended workflow:
1. implement or prototype behavior outside core runtime
2. export a submission artifact
3. score it with `evals/wisp_flow_runner.py`
4. inspect which product policy failed
5. revise policy/object model
6. only then port stable behavior into core runtime

This keeps implementation pressure aligned with the intended UX.

---

## 10. Practical next steps

### Immediate
- create an external prototype adapter that emits eval submissions
- decide the canonical task object schema
- decide the scratchpad persistence format
- define task-thread retrieval order

### Soon after
- add more benchmark cases around:
  - thread updates (`I emailed her just now`)
  - blocked tasks
  - partial dates (`sometime next week`)
  - duplicate cleanup
  - note/task cross-linking

### Later
- add a second-stage judge for nuanced thread quality and groundedness
- map the winning prototype flow into the core runtime

---

## 11. Success condition

We should consider Wisp aligned with the ideal use case when it reliably supports this flow:
- user dumps messy information into a scratchpad
- background cleanup turns stable facts into wiki notes
- actionable items become linked tasks
- each task acts as a thread with scoped retrieval from relevant wiki notes
- repeated cleanup reduces clutter without loss or churn

That is the product to optimize for.
