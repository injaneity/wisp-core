# Query

Triggered when the user asks a question or asks about a topic.

## Retrieval

The wiki has three levels of detail. Move through them in order — escalate only when the current level doesn't fully answer the query.

**Level 1 — Clusters**
`rg` key terms from the question against `clusters/`. Read matching cluster files. If the synthesis answers the query, stop here.

**Level 2 — Frontmatter**
Read `schema.md` first and expand the query through both canonical short tags and their aliases. Then `rg` those terms against `.md` notes across the wiki root, excluding `schema.md` and `clusters/`. Read frontmatter only (first 20 lines per file). For each candidate note: title, one_liner, date_added, and mention count (how many clusters referenced this note's tags). Sort by mention count desc, then date_added desc.

**Level 3 — Full content**
Read full content of selected pages only — the minimum needed to answer well, max 5. Prefer higher mention count and more recent date_added.

## Workflow

1. Read `schema.md`
2. Run Level 1 — if sufficient, answer and go to step 6
3. Run Level 2 — select candidates
4. Run Level 3 — read selected pages in full
5. Synthesise answer
6. If the answer is worth preserving as reusable knowledge, write it as a new note somewhere sensible under the wiki root following the ingest note format (read `[WISP_REPO_ROOT]/prompts/ingest.md` for format details)

## Never

- Read the full wiki before acting
- Read full page content without first checking clusters and frontmatter
