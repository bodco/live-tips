# live-tips module: Meeting Sheet (Pacenote 0.10.0)

Read by the sweep subagent together with `sweep.md`, at every prep (a prep ahead, the first sweep, a refresh and a
prepare during the call). The Pacenote app prepares every call as a **Meeting Sheet**; the skill writes the same
file, so the app and the recorder read a Cowork prep the same way. The contract is shared with the app: blocks,
presets and readiness rules live in `rules/meeting-sheet.yaml`, the schema in the app's DEVELOPMENT.md ("Meeting
Sheet (0.10.0)"). If this module and the rules differ, the rules win: say so in one line.

## What to write

Besides the files of `sweep.md` (brief, cards, facts, outline for a presentation), write
`<transcript name>.sheet.json` (a prep ahead: `prep-<yyyy-MM-dd-HHmm>-<slug>.sheet.json`, copied at the start like
the others). The brief stays the readable copy for the loop; the sheet is the structured source of truth: the
recorder takes from it the questions (checklist and "Ask now"), red lines, facts with source numbers, the best
outcome check and, without `slides.json`, the slides. Facts and cards you also put into `facts.json` / `cards.json`
for the same sheet fact get `"sheet_fact": "<fact id>"`, so the recorder shows them once.

## Shape (schema `pacenote.sheet/1`)

```json
{"schema": "pacenote.sheet/1", "id": "sheet-<slug>-<yyyyMMddHHmm>", "title": "Meeting Sheet: Emily Parker",
 "meeting_ref": {"start": "2026-11-13T16:00:00+02:00", "end": "2026-11-13T16:45:00+02:00", "event_id": "..."},
 "mode": "quick", "preset": "sales_intro", "language": "en", "route": "skill", "call_type": "auto", "audience": "client",
 "project": {"slug": "lumenfield", "root": "<project_root>"},
 "participants": {"ours": [{"name": "Mike Carter"}], "theirs": [{"name": "Emily Parker", "role": "VP Operations", "company": "Lumenfield"}]},
 "goal": "Agree on a pilot scope",
 "blocks": [{"id": "b-company", "type": "company", "title": "Company", "visible": true, "only_if_data": false,
             "order": 2, "edited_by_user": false,
             "facts": [{"id": "f-company-size", "label": "Team size", "text": "About 120 people",
                        "source_ids": ["s1"], "locator": {"quote": "a team of about 120", "page": 3},
                        "checked_at": "2026-11-12", "status": "found", "origin": "model"}]}],
 "sources": [{"id": "s1", "n": 1, "type": "file", "path": "<project_root>/research/lumenfield-notes.pdf",
              "title": "Lumenfield notes", "size_tokens": 4200, "chars": 16000, "access": "ok", "used": "full",
              "auto": false, "modified_at": "2026-11-10"}],
 "built_at": "2026-11-12T21:40:00+02:00", "versions": [{"n": 1, "built_at": "2026-11-12T21:40:00+02:00", "route": "skill"}]}
```

- **Preset and blocks.** Pick the preset by the call: Sales intro (`sales_intro`), Upsell, Repeat call, Client sync,
  Internal or presentation, Stand-up, Interview, Blank (ids and block lists in `rules/meeting-sheet.yaml >
  presets`). Use the block types of `rules/meeting-sheet.yaml > blocks` only (header, my_focus, company, signals,
  tech_stack, fit, contact, qualification with `method` bant by default, history, project_context, agenda,
  action_items, questions, best_outcome, red_lines, structure_roles, overview, gaps, the standup_* and interview_*
  blocks). A block with `only_if_data: true` and nothing found is left out.
- **Agenda and questions are separate blocks.** `agenda` is the checklist of topics; `questions` are the questions
  for the call (each fact one question). Both reach the live window.
- **Every fact** has `source_ids` (the source ids, never inside the text), a `locator` (a short exact `quote`, and
  `page`, `slide`, `line`, `cell` or the exact `url` of a sub-page when known), `checked_at` and a `status`:
  `found`, `not_found` (write "Not found" rather than guess), `needs_check` (no source you could open confirms it),
  `conflict`, `stale`, `edited`. `origin` is `model` for what you wrote. Qualification: exactly one fact per
  criterion with `value.key` (Budget, Authority, Need, Timeline for BANT) and `value.level` green, yellow, red or
  unknown; an unknown or red Budget also gets a question in `questions`.
- **Sources.** One entry per source you read or tried, numbered `n` from 1 in the order they first appear: types
  `file`, `folder_file`, `gdoc`, `gsheet`, `gslides`, `drive_file`, `notion`, `web`, `web_page` (one per page read,
  with its own `uri`), `linkedin`, `linkedin_manual`, `text`, `prev_call`, `tracker`, `web_search`, `crm`,
  `project_state` (config, decisions, Current State), `digest`, `transcript`. Each has `access`
  (`ok`, `denied`, `unsupported`, `pending`) with `access_reason` and `fix_action` when not ok, and `used`
  (`full`, `summarized`, `truncated`, `skipped`, `not_used`) with a `reason` when not full. A source you could not
  open is listed, never left out silently.
- **Conflicts.** Only attribute blocks (company, contact, tech_stack, project_context, qualification,
  interview_candidate, signals, header, fit): the same label, different values, different sources. When both sources
  are dated and differ, the newer is `found` and the older `stale` with `conflict_with` pointing at the newer fact;
  otherwise both are `conflict`, each with `conflict_with` pointing at the other. A fact whose sources are all older
  than 6 months is `stale`.
- **LinkedIn and the web.** Read a public page only within robots.txt; never collect emails or phone numbers; never
  crawl lists of people. A profile behind a sign-in wall is a source with `access: pending` and `fix_action:
  open_in_browser` (the PM can capture it in the Pacenote browser) or `paste_text`.
- **Readiness.** Leave `readiness` out (or copy it when the app's CLI is at hand:
  `python -m livetips_m0.sheet readiness --sheet <file>` in the app's engine folder fills it). The app computes it
  on open.
- **Refresh and prepare during the call.** Read the existing sheet first. Keep every fact with `status: edited` or
  `origin: user` and every block with `edited_by_user: true` exactly as they are. Write the previous file as
  `<name>.sheet.v<N>.json`, add a `versions` entry and `refreshed_at`; during a call add the transcript so far as a
  source of type `transcript`. Write the new sheet to `<name>.sheet.new.json` and rename it over the current one in
  the same step as the brief (`sweep.md`, "Prepare during the call"); a failed run leaves the current sheet as it was.
- Invented names only in examples; no em dash in any text; the language of the facts is the sheet's `language`.
