# live-tips module: Fallback: Notion

Read only when live-transcriber cannot start and the call is recorded with Notion AI Meeting Notes.

## Fallback: Notion (Mac offline or live-transcriber broken)

If live-transcriber cannot start and the user records the call with Notion AI Meeting
Notes, ask for the Notion meeting page link and read the transcript from Notion instead:

- LOCAL Notion MCP `get-block-children`. The page has 2-3 top-level wrapper blocks
  (summary, notes, transcript) shown as `paragraph` with `has_children: true` and empty
  text; the transcript wrapper's children are one `paragraph` per utterance, created in
  time order (verified 2026-10-07). Find it by content, or poll twice: the one that grows.
- Read with `start_cursor` = last seen block id. The cursor is INCLUSIVE: the first result
  is the last seen block; if its text changed, the new part counts as new.
- No speaker labels, and Notion rendered Ukrainian speech as rough English on 2026-10-07:
  tips from this source are less precise; say so once.
- Poll every 20-30 s (sleep via Bash between calls). If even the local Notion MCP is
  unavailable, use hosted `notion-fetch` with `include_transcript: true` every 60 s and warn
  that this re-reads the whole transcript each time and is expensive.

Everything else (speech, brief, triggers, tip diet and rates, wrap-up) is the same, except Step 5: the
Notion meeting page already holds the real transcript, so do not create a second page; write
the "Підсумок (Live Tips)" section into it. Only offer to set its `Project`, `Workspace` and
`Date` if they are empty.
