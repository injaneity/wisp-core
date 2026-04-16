# Ingest

This is triggered when the user sends information (text, document, URL, etc.) that can be considered knowledge.

## Page Format

Every wiki note must begin with exactly this frontmatter — no extra fields, no missing fields:

```
---
title: <string>
tags: [<tag>, <tag>]
one_liner: <single sentence>
date_added: YYYY-MM-DD
---
```

- `one_liner` — one specific sentence capturing the document's core claim; generic summaries are not acceptable
- `tags` — drawn strictly from the canonical short tags in `schema.md`; max 4; only create **with user permission**.
- `date_added` — set at ingest and never changed

## Capability Rule

- Only claim to have read, scraped, extracted, or parsed information that you actually obtained with the available tools.
- Do not invent a scraping pipeline, browser, reader, extractor, or fetch capability that is not present in the runtime.
- If the input can be reasonably understood from the raw material the user provided, synthesize it normally.
- If the input cannot be reliably synthesized with the available tools, preserve it instead of bluffing: write the user input verbatim into a note and mark clearly that it was stored without full extraction.
- Only attempt heavier extraction beyond the provided input when both are true:
  1. the user explicitly asked for it
  2. the required tool is actually available

## Schema Rule

- `schema.md` uses `short-tag: alias, alias, alias` format
- Always write the short canonical tag into note frontmatter
- Use aliases only for understanding and retrieval, never as the stored tag value

## Full Document

1. Read `schema.md`
2. Read the document or the exact input that is actually available
3. Assign tags (1-4, vocabulary only), write `one_liner`, set `date_added`
4. Write the note to a sensible `.md` path under the wiki root
5. Do not write into `clusters/`

If you cannot reliably extract the full document contents, do this instead:
1. Read `schema.md`
2. Classify the input from what is actually available
3. Write a note whose body preserves the original input verbatim
4. State in the note that the source was stored without full extraction

## Loose Information (note, quote, stat, observation)

1. `rg` the subject against titles and one_liners across `.md` notes under the wiki root
2. If a matching page exists: rewrite the full page, appending under `## Notes` as `- [YYYY-MM-DD] <text>`
3. If no match: create a stub page with frontmatter + content under `## Notes`, follow cluster rules above

## Fallback Format

When you must preserve raw input instead of synthesizing a full document, prefer a body like:

```md
## Notes

- [YYYY-MM-DD] raw input preserved because full extraction was not possible with the available tools.

## Source Material

<verbatim user input here>
```

Be explicit rather than pretending the source was fully read.
